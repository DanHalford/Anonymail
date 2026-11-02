<#
.SYNOPSIS  Checks tools, sign-in and subscription before setup. Makes no changes.
#>
param([string]$ConfigPath)
. "$PSScriptRoot/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }

Write-Step 'Tools'
$tools = @{ az = 'Azure CLI'; node = 'Node.js 20+'; npm = 'npm'; func = 'Azure Functions Core Tools 4' }
foreach ($t in $tools.Keys) {
    if (Get-Command $t -ErrorAction SilentlyContinue) { Write-Ok $tools[$t] } else { throw "$($tools[$t]) ($t) is required." }
}
if (-not (Get-Module -ListAvailable ExchangeOnlineManagement)) {
    Write-Warn2 'ExchangeOnlineManagement module not installed locally; needed for step 3 (ScopedRoleGroup) and removal. Install-Module ExchangeOnlineManagement -Scope CurrentUser'
}
Invoke-Az bicep version | Out-Null; Write-Ok 'Bicep'

Write-Step 'Azure sign-in and subscription'
Use-Subscription $cfg
$sub = Invoke-Az account show
Write-Ok "Subscription: $($sub.name) ($($sub.id))"
if ($sub.name -match 'trial|free trial|visual studio|msdn|developer|sponsorship') {
    Write-Warn2 'This looks like a trial/developer/credit-based subscription. The baseline targets standard pay-as-you-go.'
}

Write-Step 'Administrator roles (setup only — ordinary users need none)'
$me = Invoke-Az ad signed-in-user show
$assignments = Invoke-Az role assignment list --assignee $me.id --scope "/subscriptions/$($cfg.SubscriptionId)" --include-inherited
if ($assignments | Where-Object { $_.roleDefinitionName -in @('Owner', 'User Access Administrator', 'Role Based Access Control Administrator') }) {
    Write-Ok 'Can create role assignments on the subscription'
} else { Write-Warn2 'Owner (or Contributor + User Access Administrator) is needed to create the resource group role assignments.' }
Write-Host '  Entra: Application Administrator (app registration) and Privileged Role Administrator or Global Administrator (admin consent, app-role grants).'
Write-Host '  Exchange: Organization Management (role group, management scope).'

Write-Step 'Cost hygiene checks'
$defender = Invoke-Az security pricing show --name StorageAccounts 2>$null
if ($defender -and $defender.pricingTier -eq 'Standard') {
    Write-Warn2 'Microsoft Defender for Storage is enabled at subscription level and is billed per storage account. Exclude the Anonymail account or account for it in the cost estimate.'
} else { Write-Ok 'Defender for Storage not enabled on the subscription' }
Write-Host '  Shared free allowances (Automation 500 min, Functions grant, 5 GB log ingestion) are consumed by other workloads in this subscription/billing account. tools/Measure-MonthlyCost.ps1 reports current usage.'

Write-Step 'Domains'
foreach ($d in $cfg.AliasDomains) { Write-Host "  Confirm '$d' is an Authoritative accepted domain in Exchange Online (Get-AcceptedDomain)." }
Write-Host "`nPrerequisites checked." -ForegroundColor Green
