<#
.SYNOPSIS  Creates the resource group and deploys infra/main.bicep. Idempotent.
.DESCRIPTION
    Deploys: Static Web App (Free), Flex Consumption Function App (0 always-ready), Standard_LRS
    storage (tables + queue), Automation account (Basic, pay-per-minute), Log Analytics with a daily
    cap, and a monthly budget alert. Prints the tiers so nothing paid is deployed silently.
#>
param([string]$ConfigPath, [switch]$WhatIf)
. "$PSScriptRoot/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }
$state = Get-DeployState
if (-not $state.appId) { throw 'Run 1-Register-EntraApp.ps1 first.' }
Use-Subscription $cfg

Write-Step "Resource group $($cfg.ResourceGroup)"
Invoke-Az group create --name $cfg.ResourceGroup --location $cfg.Location --tags app=anonymail | Out-Null
Write-Ok 'Ready'

$l = $cfg.Limits
$params = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        namePrefix                  = @{ value = $cfg.NamePrefix }
        staticWebAppLocation        = @{ value = $cfg.StaticWebAppLocation }
        tenantId                    = @{ value = $cfg.TenantId }
        apiClientId                 = @{ value = $state.appId }
        exchangeOrganization        = @{ value = $cfg.ExchangeOrganization }
        aliasDomains                = @{ value = ($cfg.AliasDomains -join ',') }
        eligibleGroupIds            = @{ value = ($cfg.EligibleGroupIds -join ',') }
        customDomainOrigins         = @{ value = @(Get-CustomOrigins $cfg) }
        devCorsOrigins              = @{ value = @($cfg.DevOrigins) }
        creationEnabled             = @{ value = [bool]$l.CreationEnabled }
        maxActiveAliasesPerUser     = @{ value = $l.MaxActiveAliasesPerUser }
        maxCreationsPerUserPerDay   = @{ value = $l.MaxCreationsPerUserPerDay }
        maxCreationsPerMonth        = @{ value = $l.MaxCreationsPerMonth }
        maxAliasLifetimeDays        = @{ value = $l.MaxAliasLifetimeDays }
        workerJobsSoftLimitPerMonth = @{ value = $l.WorkerJobsSoftLimitPerMonth }
        workerJobsHardLimitPerMonth = @{ value = $l.WorkerJobsHardLimitPerMonth }
        workerMaxRuntimeMinutes     = @{ value = $l.WorkerMaxRuntimeMinutes }
        maxOperationAttempts        = @{ value = $l.MaxOperationAttempts }
        functionMaxInstances        = @{ value = $l.FunctionMaxInstances }
        logDailyCapGb               = @{ value = $l.LogDailyCapGb }
        budgetAmount                = @{ value = $cfg.BudgetAmount }
        budgetContactEmails         = @{ value = @($cfg.BudgetContactEmails) }
    }
}
$paramFile = Join-Path ([IO.Path]::GetTempPath()) "anonymail-params-$PID.json"
$params | ConvertTo-Json -Depth 6 | Set-Content $paramFile -Encoding utf8
$template = Join-Path $RepoRoot 'infra/main.bicep'

try {
    if ($WhatIf) {
        Write-Step 'What-if'
        & az deployment group what-if -g $cfg.ResourceGroup --template-file $template --parameters "@$paramFile"
        return
    }
    Write-Step 'Deploying infra/main.bicep (several minutes)'
    $dep = Invoke-Az deployment group create -g $cfg.ResourceGroup --name "anonymail-$(Get-Date -Format yyyyMMddHHmm)" `
        --template-file $template --parameters "@$paramFile"
} finally { Remove-Item $paramFile -ErrorAction SilentlyContinue }

$o = $dep.properties.outputs
foreach ($k in $o.Keys) { $state[$k] = $o[$k].value }
$state.resourceGroup = $cfg.ResourceGroup
Save-DeployState $state

Write-Step 'Deployed tiers (verify none are paid tiers)'
Write-Ok "Static Web App: $($state.staticWebAppName) — Free — https://$($state.staticWebAppHostname)"
Write-Ok "Function App:   $($state.functionAppName) — Flex Consumption, 0 always-ready, max $($l.FunctionMaxInstances) instances"
Write-Ok "Storage:        $($state.storageAccountName) — Standard_LRS"
Write-Ok "Automation:     $($state.automationAccountName) — Basic (pay per job minute; 500 free min/subscription/month)"
Write-Ok "Budget alert:   $($cfg.BudgetAmount)/month -> $($cfg.BudgetContactEmails -join ', ') (alerts do NOT cap spending)"

Write-Step 'Adding production redirect URIs to the app registration'
& "$PSScriptRoot/1-Register-EntraApp.ps1" @PSBoundParameters | Out-Null
foreach ($u in @("https://$($state.staticWebAppHostname)") + (Get-CustomOrigins $cfg)) { Write-Ok "$u/" }
