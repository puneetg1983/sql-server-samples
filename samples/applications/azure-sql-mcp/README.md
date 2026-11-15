![](../../../media/solutions-microsoft-logo-small.png)

# Hosted SQL MCP in Connector Namespace -- use an existing database

Deploy Microsoft's SQL MCP server (Data API builder) in **Azure Connector Namespace**, then connect Azure SRE Agent to your **existing SQL database**. Based on [Power Azure SRE Agent with the tools it needs](https://devblogs.microsoft.com/azure-sdk/power-azure-sre-agent-with-connector-namespace/).

**This sample creates MCP hosting, not SQL.** It does not create a SQL server/database, seed application data, change SQL administrators, execute SQL grants or open firewall rules. Your DBA controls the reader and which existing objects DAB exposes.

## What can connect?

| Existing database | Authentication | Network requirement |
|---|---|---|
| Azure SQL Database | Managed identity recommended; dedicated SQL login where permitted | An endpoint reachable from the hosted service with approved firewall access |
| SQL Server on an Azure VM | Dedicated SQL login; managed identity only with configured SQL Server 2022+ Entra support | Reachable TCP endpoint and trusted SQL TLS certificate |
| On-premises SQL Server, including Azure Arc-enabled servers | Dedicated SQL login; Entra configurations require separate verification | Reachable TCP endpoint and trusted SQL TLS certificate; **Arc does not tunnel SQL traffic** |

**Preview boundary:** the catalog documents Azure SQL. SQL VM/on-premises connections use DAB's SQL Server driver but have not been end-to-end validated with this hosted catalog runtime. They are candidate configurations, not a certification of every SQL version or authentication mode.

[Connector Namespace documentation](https://learn.microsoft.com/azure/connector-namespace/connector-namespace-hosted-mcp) lists VNet/private-endpoint support as future work and does not recommend the preview for production. **Private-only SQL is not supported by this sample's documented hosting path.** Existing VPN, peering or Arc enrollment alone does not connect the hosted service to your network. Confirm capabilities with the service team before proceeding; do not expose private SQL to make this sample work.

## 1. Configure the existing database

Prerequisites: Azure Developer CLI (`azd`), hosting deployment permissions, an existing SQL database, a DBA-approved dedicated reader, and an approved SQL network path. The signed-in deployer's object ID is used only for the MCP access policy, never to change your SQL administrator.

Clone this repository and open `samples/applications/azure-sql-mcp`. Review `dab-config.json` before deployment:

- It uses the hosted server's `SQL_CONNECTION_STRING`, not a checked-in credential.
- The default `Tables` entity exposes **`sys.tables` metadata only**, with `object_id` as its key. It creates no SQL objects. Results are limited by the reader's SQL metadata visibility; an empty list is not proof of connectivity to application data.
- To expose an existing business or diagnostic table/view, replace or add an entity's `source.object` and `source.type`. Views need stable unique `key-fields`. Grant `read` only on explicitly approved entities and matching SQL permissions.
- REST, GraphQL and write/procedure tools are disabled. This is **not** the separate custom `sre_sql` diagnostics package: it installs no blocking views or stored procedures.

For example, an existing, DBA-approved view might be configured as:

```json
"OrderStatus": {
  "source": {
    "object": "reporting.OrderStatus",
    "type": "view",
    "key-fields": ["OrderId"]
  },
  "permissions": [
    { "role": "anonymous", "actions": [{ "action": "read" }] }
  ]
}
```

`anonymous` is the DAB entity role used by this hosted configuration; **the Connector Namespace still enforces inbound Entra authentication and MCP access policies**. Do not deploy the config as an unprotected standalone endpoint.

## 2. Deploy MCP hosting

```bash
azd auth login
azd init
azd up
```

Choose **Use code in the current directory** in `azd init`, and an environment name such as `mcp-existing-sql`. Choose a supported preview region: **West Central US, Central US, East Asia or North Europe** (check current availability).

| Parameter | What to supply |
|---|---|
| `environmentName` / subscription / `location` | New hosting environment name and target subscription/region; these do not select or move SQL |
| `connectorNamespaceIdentityType` | Defaults to **UserAssigned**. To select SystemAssigned, change the infrastructure parameter before deployment |
| `connectorNamespaceLocation` | Defaults to `location`; use a supported hosting region |
| `sqlConnectionString` | Enter your existing database connection string at the **secure infrastructure prompt**; never an administrator credential |

Use the server's normal certificate-matching DNS name and actual SQL TCP port. Include **`Encrypt=True;TrustServerCertificate=False`**. The template accepts your connection string; it does not repair DNS, certificates or routing. Azure SQL private DNS hostnames do not circumvent the private-network limitation.

**Azure SQL, user-assigned managed identity (default):**

```text
Server=tcp:orders-sql.database.windows.net,1433;Database=Orders;Authentication=Active Directory Managed Identity;User Id=__SQL_IDENTITY_CLIENT_ID__;Encrypt=True;TrustServerCertificate=False;
```

The template substitutes `__SQL_IDENTITY_CLIENT_ID__` with the new identity's client ID. For **SystemAssigned**, omit the entire `User Id` setting. Use managed identity against a SQL VM only if that server's Entra authentication and external login are already configured; Arc enrollment by itself is insufficient.

**Dedicated SQL login (Azure SQL where allowed, SQL VM or on-premises candidate):**

```text
Server=tcp:sql01.contoso.com,1433;Database=Orders;User ID=sre_mcp_reader;Password="<reader-password>";Encrypt=True;TrustServerCertificate=False;
```

Use SqlClient connection-string quoting for passwords containing delimiters; do not paste a password into shared documentation or shell arguments. SQL-login mode does not use the namespace identity for SQL, though the namespace still has an identity for hosting.

**Secrets:** `sqlConnectionString` is an ARM secure parameter and is never a deployment output. It is passed to hosted MCP configuration. Treat that resource configuration and local `.azure` environment state as sensitive: limit Azure read access and file access, do not commit or publish them, and follow your credential-rotation policy. Base64 configuration is not encryption. A new secure parameter can prompt again on redeployment; supply it through an approved secret process.

The PowerShell alternative, `./deploy.ps1 -EnvironmentName mcp-existing-sql`, invokes the same azd flow; it does not run an independent SQL provisioning path.

### Resources created

Dedicated resource group, Log Analytics, Application Insights, Connector Namespace, optional user-assigned identity, hosted `mcp-sql` config, and a deployer MCP access policy. **No `Microsoft.Sql/*`, Arc or network resources are deployed.** SQL need not live in the hosting resource group/subscription.

Deployment prints the MCP endpoint and SQL identity name/object ID. **Host deployment is not proof of SQL connectivity or grants.** The post-provision hook only reports outputs; it does not run SQL or generate a secret-bearing DAB file.

## 3. Authorize the reader and verify

Your DBA must review the DAB entities and authorize the selected reader in the existing target database. No automatic administrator access, `db_datareader`/`db_datawriter` membership or database-wide grants are applied.

For Azure SQL managed identity, connect as an appropriately authorized administrator **to the target database**, replacing the names below with the `SQL_IDENTITY_NAME` output and an existing approved object:

```sql
CREATE USER [<SQL_IDENTITY_NAME>] FROM EXTERNAL PROVIDER;
GRANT SELECT, VIEW DEFINITION ON OBJECT::[reporting].[OrderStatus]
    TO [<SQL_IDENTITY_NAME>];
```

These are examples, not automatically executed commands. If a user already exists, verify its identity rather than recreating or repurposing it. Name resolution can require directory permissions for the SQL server identity; follow [Azure SQL managed identity guidance](https://learn.microsoft.com/azure/azure-sql/database/authentication-azure-ad-user-assigned-managed-identity). For the default `sys.tables` entity, metadata visibility follows the reader's permissions on existing objects; there is no blanket metadata grant in this sample.

For SQL-login mode, have the DBA provision a dedicated login and matching database user, then grant access only to the configured objects. For SQL Server Entra mode, the DBA must provision the external server login/database user using that server's supported configuration. Neither of these is created by the template.

Optional smoke test from VS Code: **MCP: Add Server > HTTP**, enter `MCP_ENDPOINT_URL`, start it and complete Microsoft sign-in using the authorized deployer account. Invoke `describe_entities`, then read one approved entity using `read_records`. Check the expected database data; empty metadata results are not proof of cross-session diagnostic visibility. Confirm that write tools are absent. Failures require correcting identity, SQL permissions, config, TLS or network access; do not broaden permissions to make a test pass.

## 4. Connect Azure SRE Agent

In the SRE Agent portal, **Builder > Connectors > Add connector > MCP server**, use:

| Setting | Value |
|---|---|
| Connection type | Streamable HTTP |
| URI | `MCP_ENDPOINT_URL` from deployment |
| Authentication | Managed identity |
| Microsoft Entra token scope | `https://apihub.azure.com/.default` |

Before testing, find the **SRE connector's managed identity** in Azure and copy its tenant ID and principal/object ID. In [Connector Namespace](https://connectors.azure.com), open your namespace, select **MCP Connectors > sql-mcp > Access Policies > Add Access Policy**, and authorize that tenant/principal. This inbound identity is separate from the hosted server's SQL reader identity.

Return to SRE Agent, test the connection, select read-only tools, add the connector and wait for **Connected**. Ask:

> Discover my SQL connector's configured entities and read the approved entity. Do not modify SQL. Explain when evidence or permissions are insufficient.

Connector Namespace hosts DAB; DAB's configuration specifies the existing SQL objects; SQL grants restrict downstream access. There is no arbitrary-SQL troubleshooting tool or automatic remediation in this sample.

## Cleanup and validation

`azd down --purge` removes the dedicated hosting resources, **not the existing SQL database**. Verify scope before deleting: never add existing SQL/shared resources to the sample resource group. DBA-managed users and grants remain and need separate DBA review.

Local checks compile Bicep and verify no SQL provisioning, secure connection handling, read-only config and reporting-only hooks. Run `python -m unittest discover -s tests` from this directory (Python 3 and Azure CLI/Bicep required). Hosted deployment and existing Azure SQL/VM/on-premises runtime combinations have **not** been tested by this fork. SQL readiness must be verified in your environment.

## References

- [Azure SDK Blog walkthrough](https://devblogs.microsoft.com/azure-sdk/power-azure-sre-agent-with-connector-namespace/)
- [Connector Namespace hosted servers and preview limitations](https://learn.microsoft.com/azure/connector-namespace/connector-namespace-hosted-mcp)
- [SQL MCP / Data API builder](https://learn.microsoft.com/azure/data-api-builder/mcp/overview)
- [Configure DAB entities](https://learn.microsoft.com/azure/data-api-builder/configuration/entities)
- [SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connector)
