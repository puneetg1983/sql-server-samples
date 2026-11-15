import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
if os.name == "nt" and shutil.which("git"):
    git_bash = Path(shutil.which("git")).resolve().parents[1] / "bin" / "bash.exe"
    if git_bash.exists():
        BASH = str(git_bash)


def resources(template):
    for resource in template.get("resources", []):
        yield resource
        nested = resource.get("properties", {}).get("template")
        if nested:
            yield from resources(nested)


class ExistingSqlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "main.json"
            az = shutil.which("az")
            if not az:
                raise RuntimeError("Azure CLI and Bicep are required to compile the sample.")
            command = [az, "bicep", "build", "--file", str(ROOT / "infra" / "main.bicep"),
                       "--outfile", str(output)]
            if az.lower().endswith(".cmd"):
                command = [shutil.which("cmd"), "/c", *command]
            result = subprocess.run(command, capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            cls.template = json.loads(output.read_text(encoding="utf-8-sig"))
            cls.resources = list(resources(cls.template))

    def test_existing_database_is_not_provisioned_or_changed(self):
        types = {resource["type"] for resource in self.resources}
        self.assertFalse(any(name.startswith(("Microsoft.Sql/", "Microsoft.Network/",
                                              "Microsoft.HybridCompute/")) for name in types))
        self.assertIn("Microsoft.Web/connectorGateways/mcpServerConfigs", types)
        self.assertNotIn("Microsoft.Resources/deploymentScripts", types)
        self.assertNotIn("databaseName", self.template["parameters"])
        self.assertNotIn("deployerLoginName", self.template["parameters"])
        self.assertNotIn("deployerIpAddress", self.template["parameters"])

    def test_secure_connection_reaches_host_without_outputs(self):
        self.assertEqual(self.template["parameters"]["sqlConnectionString"]["type"].lower(), "securestring")
        serialized_outputs = json.dumps(self.template["outputs"])
        self.assertNotIn("ConnectionString", serialized_outputs)
        self.assertNotIn("CONNECTION_STRING", serialized_outputs)
        hosted = next(resource for resource in self.resources
                      if resource["type"] == "Microsoft.Web/connectorGateways/mcpServerConfigs")
        configuration = hosted["properties"]["hostedMcpServer"]["configuration"]
        self.assertEqual(configuration, "[variables('hostedMcpConfiguration')]")
        self.assertIn("SQL_CONNECTION_STRING", json.dumps(self.template))
        self.assertEqual(hosted["properties"]["hostedMcpServer"]["hostedMcpServerId"], "mcp-sql")
        self.assertIn("replace(parameters('sqlConnectionString'), '__SQL_IDENTITY_CLIENT_ID__'",
                      json.dumps(self.template))
        self.assertEqual(self.template["parameters"]["connectorNamespaceIdentityType"]["defaultValue"],
                         "UserAssigned")

    def test_deployed_config_is_read_only_and_uses_existing_metadata(self):
        config = json.loads((ROOT / "dab-config.json").read_text())
        self.assertEqual(config["data-source"]["connection-string"], "@env('SQL_CONNECTION_STRING')")
        self.assertEqual(config["entities"]["Tables"]["source"],
                         {"object": "sys.tables", "type": "view", "key-fields": ["object_id"]})
        for entity in config["entities"].values():
            self.assertEqual(entity["permissions"][0]["actions"], [{"action": "read"}])
        runtime = config["runtime"]
        for surface in ("rest", "graphql"):
            self.assertFalse(runtime[surface]["enabled"])
        for tool in ("create-record", "update-record", "delete-record", "execute-entity"):
            self.assertFalse(runtime["mcp"]["dml-tools"][tool])
        expression = self.template["variables"]["dabConfigBase64"]
        reference = re.fullmatch(r"\[base64\(variables\('([^']+)'\)\)\]", expression)
        self.assertIsNotNone(reference, expression)
        self.assertEqual(json.loads(self.template["variables"][reference.group(1)]), config)

    def test_powershell_hook_reports_only_and_propagates_missing_output(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                command = """
$ErrorActionPreference='Stop'
function global:azd {
    param($operation, $action, $name)
    if ($operation -ne 'env' -or $action -ne 'get-value') { throw 'Unexpected azd operation' }
    $global:LASTEXITCODE=0
    switch ($name) {
        'MCP_ENDPOINT_URL' { 'https://example.invalid/mcp' }
        'SQL_IDENTITY_NAME' { 'reader-test' }
        'SQL_IDENTITY_PRINCIPAL_ID' { '00000000-0000-0000-0000-000000000001' }
        default { throw 'Unexpected output request' }
    }
}
"""
                if missing:
                    command += """
function global:azd { $global:LASTEXITCODE=1; return '' }
"""
                command += "& './scripts/post-provision.ps1'"
                result = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", command],
                                        cwd=ROOT, capture_output=True, text=True, timeout=30)
                if missing:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Missing deployment output", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("https://example.invalid/mcp", result.stdout)
                    self.assertIn("No SQL server", result.stdout)

    @unittest.skipUnless(BASH, "Bash is required for the POSIX hook check")
    def test_bash_hook_reports_only_and_propagates_missing_output(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                fixture = """
azd() {
    [ "$1" = env ] && [ "$2" = get-value ] || return 99
    case "$3" in
        MCP_ENDPOINT_URL) echo https://example.invalid/mcp ;;
        SQL_IDENTITY_NAME) echo reader-test ;;
        SQL_IDENTITY_PRINCIPAL_ID) echo 00000000-0000-0000-0000-000000000001 ;;
        *) return 98 ;;
    esac
}
"""
                if missing:
                    fixture = "azd() { return 1; }\n"
                fixture += ". ./scripts/post-provision.sh\n"
                result = subprocess.run([BASH, "-c", fixture], cwd=ROOT,
                                        capture_output=True, text=True, timeout=30)
                if missing:
                    self.assertNotEqual(result.returncode, 0)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("https://example.invalid/mcp", result.stdout)
                    self.assertIn("No SQL server", result.stdout)


if __name__ == "__main__":
    unittest.main()
