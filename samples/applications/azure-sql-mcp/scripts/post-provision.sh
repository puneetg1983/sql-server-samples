#!/usr/bin/env bash
set -euo pipefail

get_deployment_value() {
    local value
    value=$(azd env get-value "$1")
    if [ -z "$value" ]; then
        echo "Missing deployment output: $1" >&2
        return 1
    fi
    printf '%s' "$value"
}

ENDPOINT=$(get_deployment_value MCP_ENDPOINT_URL)
IDENTITY_NAME=$(get_deployment_value SQL_IDENTITY_NAME)
IDENTITY_PRINCIPAL=$(get_deployment_value SQL_IDENTITY_PRINCIPAL_ID)
printf 'MCP host deployed: %s\n' "$ENDPOINT"
printf 'SQL managed identity (if selected): %s\n' "$IDENTITY_NAME"
printf 'SQL managed identity object ID: %s\n' "$IDENTITY_PRINCIPAL"
echo 'No SQL server, database, data, grants, administrator or firewall was changed.'
echo 'Next: have your DBA authorize the dedicated reader and verify the configured entities.'
echo 'Then authorize the SRE Agent connector identity in the MCP access policies and test the connection.'
echo 'Host deployment is not proof of SQL connectivity or permissions. See README.md.'
