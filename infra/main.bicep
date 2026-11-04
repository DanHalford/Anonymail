// Anonymail — baseline deployment (amendment v1.3).
// Everything lives in ONE resource group. No premium SKUs, no always-on compute,
// no provisioned database. See docs/cost-model.md for the cost reasoning per resource.

targetScope = 'resourceGroup'

@description('Short prefix used for resource names (3-11 lowercase letters/digits).')
@minLength(3)
@maxLength(11)
param namePrefix string = 'anonymail'

@description('Region for storage, Functions, Automation and monitoring.')
param location string = resourceGroup().location

@description('Region for the Static Web App. Free tier is only offered in a subset of regions.')
@allowed([ 'eastasia', 'westus2', 'centralus', 'eastus2', 'westeurope' ])
param staticWebAppLocation string = 'eastasia'

@description('Entra tenant ID that owns the users and mailboxes.')
param tenantId string = tenant().tenantId

@description('Application (client) ID of the Anonymail Entra app registration (SPA + API).')
param apiClientId string

@description('Exchange organisation initial domain, e.g. contoso.onmicrosoft.com.')
param exchangeOrganization string

@description('Comma-separated accepted domains that aliases may be created in.')
param aliasDomains string

@description('Comma-separated Entra security group object IDs whose members may use the service. Empty = all member users with a mailbox.')
param eligibleGroupIds string = ''

@description('Origins of custom domains bound to the Static Web App, e.g. https://anonymail.contoso.com.')
param customDomainOrigins array = []

@description('Extra CORS origins for local development, e.g. http://localhost:5173. Empty for production.')
param devCorsOrigins array = []

// ---- operational limits (all adjustable later with scripts/Set-OperationalLimits.ps1) ----
param creationEnabled bool = true
param maxActiveAliasesPerUser int = 100
param maxCreationsPerUserPerDay int = 10
param maxCreationsPerMonth int = 300
param maxAliasLifetimeDays int = 0
param workerJobsSoftLimitPerMonth int = 200
param workerJobsHardLimitPerMonth int = 250
param workerMaxRuntimeMinutes int = 5
param maxOperationAttempts int = 3

@description('Maximum Function instances. Bounds worst-case compute spend.')
@minValue(1)
param functionMaxInstances int = 2

@description('Log Analytics daily ingestion cap in GB. Bounds telemetry spend.')
param logDailyCapGb string = '0.025' // Log Analytics minimum is > 0.023

@description('ExchangeOnlineManagement module version imported into Automation.')
param exoModuleVersion string = '3.6.0'

// ---- cost alerts ----
@description('Monthly budget in the subscription billing currency (A$ for AU billing accounts).')
param budgetAmount int = 5

@description('Email addresses that receive budget alerts. Alerts notify; they do NOT cap spending.')
param budgetContactEmails array

@description('Budget start date (first day of a month).')
param budgetStartDate string = utcNow('yyyy-MM-01')

var suffix = take(uniqueString(resourceGroup().id), 6)
var storageName = toLower('${namePrefix}${suffix}st')
var queueName = 'exchange-ops'
var runbookName = 'Invoke-AnonymailWorker'
var tableNames = [ 'aliases', 'aliasindex', 'expiry', 'operations', 'mailboxes', 'usage', 'state', 'audit', 'inboxrules' ]
var tags = { app: 'anonymail', costTarget: 'AUD5-month' }

// ---------------------------------------------------------------- storage (Standard LRS)
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // identity-only access from Functions and Automation
    defaultToOAuthAuthentication: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deployContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deploy'
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource opsQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: queueName
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource tables 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = [for t in tableNames: {
  parent: tableService
  name: t
}]

// ---------------------------------------------------------------- monitoring (bounded)
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-${suffix}-log'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json(logDailyCapGb) }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-${suffix}-ai'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
    SamplingPercentage: 50
  }
}

// ---------------------------------------------------------------- Functions (Flex Consumption, no always-ready)
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${namePrefix}-${suffix}-plan'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  properties: { reserved: true }
}

resource staticSite 'Microsoft.Web/staticSites@2023-12-01' = {
  name: '${namePrefix}-${suffix}-web'
  location: staticWebAppLocation
  tags: tags
  sku: { name: 'Free', tier: 'Free' }
  properties: {
    stagingEnvironmentPolicy: 'Disabled'
    allowConfigFileUpdates: true
  }
}

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: '${namePrefix}-${suffix}-aa'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' } // pay-per-minute; first 500 job minutes/subscription/month are free
    publicNetworkAccess: true
    disableLocalAuth: true
  }
}

resource exoModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automation
  name: 'ExchangeOnlineManagement'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/ExchangeOnlineManagement/${exoModuleVersion}'
    }
  }
}

// Draft runbook; content is uploaded and published by scripts/4-Publish-Application.ps1.
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automation
  name: runbookName
  location: location
  properties: {
    runbookType: 'PowerShell'
    logProgress: false
    logVerbose: false
    description: 'Drains the exchange-ops queue and applies alias changes in Exchange Online.'
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: '${namePrefix}-${suffix}-api'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deployContainer.name}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: functionMaxInstances
        instanceMemoryMB: 512
        // alwaysReady intentionally omitted: zero always-ready instances.
      }
      runtime: { name: 'node', version: '20' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      cors: {
        allowedOrigins: concat([ 'https://${staticSite.properties.defaultHostname}' ], customDomainOrigins, devCorsOrigins)
        supportCredentials: false
      }
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'TENANT_ID', value: tenantId }
        { name: 'API_CLIENT_ID', value: apiClientId }
        { name: 'ALIAS_DOMAINS', value: aliasDomains }
        { name: 'ELIGIBLE_GROUP_IDS', value: eligibleGroupIds }
        { name: 'STORAGE_ACCOUNT_NAME', value: storage.name }
        { name: 'QUEUE_NAME', value: queueName }
        { name: 'AUTOMATION_ACCOUNT_ID', value: automation.id }
        { name: 'AUTOMATION_RUNBOOK_NAME', value: runbookName }
        { name: 'EXCHANGE_ORGANIZATION', value: exchangeOrganization }
        { name: 'CREATION_ENABLED', value: string(creationEnabled) }
        { name: 'MAX_ACTIVE_ALIASES_PER_USER', value: string(maxActiveAliasesPerUser) }
        { name: 'MAX_CREATIONS_PER_USER_PER_DAY', value: string(maxCreationsPerUserPerDay) }
        { name: 'MAX_CREATIONS_PER_MONTH', value: string(maxCreationsPerMonth) }
        { name: 'MAX_ALIAS_LIFETIME_DAYS', value: string(maxAliasLifetimeDays) }
        { name: 'WORKER_JOBS_SOFT_LIMIT_PER_MONTH', value: string(workerJobsSoftLimitPerMonth) }
        { name: 'WORKER_JOBS_HARD_LIMIT_PER_MONTH', value: string(workerJobsHardLimitPerMonth) }
        { name: 'WORKER_MAX_RUNTIME_MINUTES', value: string(workerMaxRuntimeMinutes) }
        { name: 'MAX_OPERATION_ATTEMPTS', value: string(maxOperationAttempts) }
        { name: 'EXPIRY_SCHEDULE', value: '0 0 17 * * *' } // daily, 17:00 UTC (~03:00-04:00 AEST/AEDT)
        { name: 'SWEEP_SCHEDULE', value: '0 */30 * * * *' } // safety net only; API dispatch is primary
      ]
    }
  }
}

// ---------------------------------------------------------------- role assignments (least privilege, data plane)
var roles = {
  blobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  queueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  queueMessageProcessor: '8a0f0c08-91a1-4084-bc3d-661d67233fed'
  tableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  automationOperator: 'd3881f73-407a-4167-8283-e981cbba0404'
}

var storageGrants = [
  { who: 'func', role: roles.blobDataOwner }
  { who: 'func', role: roles.queueDataContributor }
  { who: 'func', role: roles.tableDataContributor }
  { who: 'aa', role: roles.queueMessageProcessor }
  { who: 'aa', role: roles.tableDataContributor }
]

resource storageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for g in storageGrants: {
  scope: storage
  name: guid(storage.id, g.who, g.role)
  properties: {
    principalId: g.who == 'func' ? functionApp.identity.principalId : automation.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', g.role)
  }
}]

// Functions may start (not edit) runbook jobs.
resource functionStartsJobs 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: automation
  name: guid(automation.id, functionApp.id, roles.automationOperator)
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.automationOperator)
  }
}

// ---------------------------------------------------------------- cost alert (notifies only; does not cap spend)
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: '${namePrefix}-monthly'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: { startDate: budgetStartDate }
    notifications: {
      actual50: { enabled: true, operator: 'GreaterThan', threshold: 50, thresholdType: 'Actual', contactEmails: budgetContactEmails }
      actual100: { enabled: true, operator: 'GreaterThan', threshold: 100, thresholdType: 'Actual', contactEmails: budgetContactEmails }
      forecast100: { enabled: true, operator: 'GreaterThan', threshold: 100, thresholdType: 'Forecasted', contactEmails: budgetContactEmails }
    }
  }
}

output storageAccountName string = storage.name
output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output functionPrincipalId string = functionApp.identity.principalId
output automationAccountName string = automation.name
output automationPrincipalId string = automation.identity.principalId
output staticWebAppName string = staticSite.name
output staticWebAppHostname string = staticSite.properties.defaultHostname
output runbookName string = runbookName
