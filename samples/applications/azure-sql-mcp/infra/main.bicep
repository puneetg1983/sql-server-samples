targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@minLength(1)
@maxLength(64)
@description('Name of the environment (used to generate unique resource names).')
param environmentName string

@description('Location for hosting and monitoring resources, not the existing SQL server.')
@metadata({
  azd: {
    type: 'location'
  }
})
param location string

@description('Location for the Connector Namespace. Preview regions: westcentralus, eastasia, centralus, northeurope.')
param connectorNamespaceLocation string = location

@description('Object ID of the deployer user. Used only for the MCP access policy, not SQL administration.')
@metadata({
  azd: {
    type: 'principalId'
  }
})
param deployerPrincipalId string = deployer().objectId

@secure()
@minLength(1)
@description('Existing SQL connection string. Use TLS with certificate validation and a dedicated reader. For user-assigned managed identity, use User Id=__SQL_IDENTITY_CLIENT_ID__; the template replaces that placeholder.')
param sqlConnectionString string

@allowed([
  'SystemAssigned'
  'UserAssigned'
])
@description('Managed identity type for the Connector Namespace and hosted SQL MCP server.')
param connectorNamespaceIdentityType string = 'UserAssigned'

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var readableEnvironmentName = take(toLower(replace(replace(replace(environmentName, '_', '-'), '.', '-'), ' ', '-')), 40)
var resourceToken = take(toLower(uniqueString(subscription().id, environmentName, location)), 8)
var tags = { 'azd-env-name': environmentName }
var resourceGroupName = 'rg-${readableEnvironmentName}'
var connectorNamespaceName = 'cn-${readableEnvironmentName}-${resourceToken}'
var userAssignedIdentityName = 'id-${readableEnvironmentName}-${resourceToken}'
var logAnalyticsWorkspaceName = 'log-${readableEnvironmentName}-${resourceToken}'
var appInsightsName = 'appi-${readableEnvironmentName}-${resourceToken}'
var useUserAssignedIdentity = connectorNamespaceIdentityType == 'UserAssigned'

// Load the included DAB config and base64-encode it for the ARM API.
var dabConfigBase64 = base64(loadTextContent('../dab-config.json'))

// ---------------------------------------------------------------------------
// Resource Group
// ---------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Application Insights
// ---------------------------------------------------------------------------

module appInsights './modules/appInsights.bicep' = {
  scope: rg
  name: 'appi-${resourceToken}'
  params: {
    workspaceName: logAnalyticsWorkspaceName
    appInsightsName: appInsightsName
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Optional user-assigned managed identity
// ---------------------------------------------------------------------------

module userAssignedIdentity './modules/userAssignedIdentity.bicep' = if (useUserAssignedIdentity) {
  scope: rg
  name: 'id-${resourceToken}'
  params: {
    name: userAssignedIdentityName
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Connector Namespace
// ---------------------------------------------------------------------------

module connectorNamespace './modules/connectorNamespace.bicep' = {
  scope: rg
  name: 'cn-${resourceToken}'
  params: {
    name: connectorNamespaceName
    location: connectorNamespaceLocation
    tags: tags
    identityType: connectorNamespaceIdentityType
    userAssignedIdentityResourceId: useUserAssignedIdentity ? userAssignedIdentity!.outputs.id : ''
  }
}

var managedIdentityClientId = useUserAssignedIdentity ? userAssignedIdentity!.outputs.clientId : ''
var sqlIdentityName = useUserAssignedIdentity ? userAssignedIdentity!.outputs.name : connectorNamespace.outputs.name
var sqlIdentityPrincipalId = useUserAssignedIdentity ? userAssignedIdentity!.outputs.principalId : connectorNamespace.outputs.principalId
var dabConnectionString = replace(sqlConnectionString, '__SQL_IDENTITY_CLIENT_ID__', managedIdentityClientId)

// ---------------------------------------------------------------------------
// Hosted SQL MCP Server + Access Policy
// ---------------------------------------------------------------------------

module hostedMcpServer './modules/hostedMcpServer.bicep' = {
  scope: rg
  name: 'mcp-${resourceToken}'
  params: {
    connectorNamespaceName: connectorNamespaceName
    name: 'sql-mcp'
    deployerPrincipalId: deployerPrincipalId
    dabConfigBase64: dabConfigBase64
    sqlConnectionString: dabConnectionString
    applicationInsightsConnectionString: appInsights.outputs.connectionString
    managedIdentityClientId: managedIdentityClientId
  }
  dependsOn: [
    connectorNamespace
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('The name of the resource group.')
output RESOURCE_GROUP_NAME string = rg.name

@description('The name of the Connector Namespace.')
output CONNECTOR_NAMESPACE_NAME string = connectorNamespace.outputs.name

@description('The principal ID of the Connector Namespace system-assigned managed identity. Empty when using user-assigned identity only.')
output CONNECTOR_NAMESPACE_PRINCIPAL_ID string = connectorNamespace.outputs.principalId

@description('Managed identity name. A DBA must authorize it separately if using managed-identity SQL authentication.')
output SQL_IDENTITY_NAME string = sqlIdentityName

@description('Managed identity principal ID for DBA authorization; no SQL grants are applied by deployment.')
output SQL_IDENTITY_PRINCIPAL_ID string = sqlIdentityPrincipalId

@description('The managed identity client ID used by the hosted MCP server. Empty when using system-assigned identity.')
output SQL_IDENTITY_CLIENT_ID string = managedIdentityClientId

@description('The name of the Application Insights resource.')
output APPLICATIONINSIGHTS_NAME string = appInsights.outputs.appInsightsName

@description('The name of the Log Analytics workspace backing Application Insights.')
output LOG_ANALYTICS_WORKSPACE_NAME string = appInsights.outputs.workspaceName

@description('MCP endpoint URL — point VS Code / MCP clients here.')
output MCP_ENDPOINT_URL string = hostedMcpServer.outputs.mcpEndpointUrl
