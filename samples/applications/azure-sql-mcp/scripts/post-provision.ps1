#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DeploymentValue([string]$Name) {
    $value = azd env get-value $Name
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "Missing deployment output: $Name"
    }
    return $value
}

$endpoint = Get-DeploymentValue 'MCP_ENDPOINT_URL'
$identityName = Get-DeploymentValue 'SQL_IDENTITY_NAME'
$identityPrincipal = Get-DeploymentValue 'SQL_IDENTITY_PRINCIPAL_ID'
Write-Host "MCP host deployed: $endpoint"
Write-Host "SQL managed identity (if selected): $identityName"
Write-Host "SQL managed identity object ID: $identityPrincipal"
Write-Host 'No SQL server, database, data, grants, administrator or firewall was changed.'
Write-Host 'Next: have your DBA authorize the dedicated reader and verify the configured entities.'
Write-Host 'Then authorize the SRE Agent connector identity in the MCP access policies and test the connection.'
Write-Host 'Host deployment is not proof of SQL connectivity or permissions. See README.md.'
