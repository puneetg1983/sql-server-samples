<#
.SYNOPSIS
    Deploy the existing-SQL Connector Namespace sample using azd.
.DESCRIPTION
    Runs the same azd flow and reporting hooks as the README. SQL credentials
    are entered through the secure infrastructure prompt, not command arguments.
    Does not execute SQL or change firewall rules.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentName,
    [string]$Location = 'eastasia'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
    throw 'Install Azure Developer CLI and run azd auth login first.'
}

Push-Location $PSScriptRoot
try {
    azd init --environment $EnvironmentName
    if ($LASTEXITCODE -ne 0) { throw 'azd initialization failed.' }
    azd env set AZURE_LOCATION $Location
    if ($LASTEXITCODE -ne 0) { throw 'Could not set the deployment region.' }
    Write-Host 'Deploying MCP hosting only. Enter the existing SQL connection string at the secure prompt.'
    azd up
    if ($LASTEXITCODE -ne 0) { throw 'azd deployment failed.' }
}
finally {
    Pop-Location
}
