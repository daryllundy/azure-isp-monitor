@minLength(3)
param prefix string
param location string = resourceGroup().location
param alertEmail string

var saName   = toLower('${prefix}sa${uniqueString(resourceGroup().id)}')
var planName = '${prefix}-func-plan'
var appName  = toLower('${prefix}-func')
var aiName   = '${prefix}-appi'
var agName   = '${prefix}-ag'
var alertName = '${prefix}-heartbeat-miss'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: saName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  kind: 'linux'
  sku: {
    name: 'Y1'       // Consumption (free/cheap)
    tier: 'Dynamic'
  }
  properties: {
    reserved: true  // Required for Linux plans
  }
}

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    reserved: true  // Required for Linux
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      cors: {
        allowedOrigins: []  // No CORS by default - add specific origins if needed
        supportCredentials: false
      }
      appSettings: [
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        // Use Managed Identity for storage access (more secure than account keys)
        { name: 'AzureWebJobsStorage__accountName', value: sa.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: 'https://${sa.name}.blob.${environment().suffixes.storage}' }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${sa.name}.queue.${environment().suffixes.storage}' }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: 'https://${sa.name}.table.${environment().suffixes.storage}' }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: appi.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appi.properties.ConnectionString }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ENABLE_ORYX_BUILD', value: 'true' }
      ]
    }
  }
}

// Grant Function App Managed Identity access to Storage Account
// Storage Blob Data Owner role
resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, func.id, 'Storage Blob Data Owner')
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor role
resource storageQueueRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, func.id, 'Storage Queue Data Contributor')
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor role
resource storageTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, func.id, 'Storage Table Data Contributor')
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Action Group with email
// NOTE: Action Groups MUST use location='global' (not regional)
resource ag 'Microsoft.Insights/actionGroups@2022-06-01' = {
  name: agName
  location: 'global'
  properties: {
    enabled: true
    groupShortName: prefix
    emailReceivers: [
      {
        name: 'primary'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Scheduled query alert: if no ping requests in last 3 minutes => fire
resource rule 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: alertName
  location: location
  properties: {
    displayName: alertName
    enabled: true
    // NOTE: property name is "scopes" (plural)
    scopes: [
      appi.id
    ]
    severity: 2
    evaluationFrequency: 'PT5M'  // 5 minutes (PT1M not supported for this query type)
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: '''
requests
| where cloud_RoleName == "${appName}"
| where name has "POST /api/ping" or name has "GET /api/ping"
| where timestamp > ago(5m)
| summarize count()'''
          timeAggregation: 'Count'
          operator: 'LessThan'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        ag.id
      ]
    }
    muteActionsDuration: 'PT5M'
    autoMitigate: false
  }
}

output functionAppName string = func.name
output functionAppUrl string = 'https://${func.properties.defaultHostName}/api/ping'
output resourceGroupName string = resourceGroup().name
