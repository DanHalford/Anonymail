<#
.SYNOPSIS  Verifies the deployment against the v1.3 baseline. Read-only.
.DESCRIPTION
    Automated checks: tiers (no paid hosting), cost controls, permissions, endpoints, auth enforcement.
    Then prints the manual acceptance checks (passkey sign-in, delivery during suspension) from
    docs/acceptance.md that require a real user and mailbox.
#>
param([string]$ConfigPath)
. "$PSScriptRoot/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }
$state = Get-DeployState
Use-Subscription $cfg
$rg = $cfg.ResourceGroup
$failures = 0
function Check([string]$Name, [bool]$Pass, [string]$Detail = '') {
    if ($Pass) { Write-Ok "$Name $Detail" } else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

Write-Step 'Hosting tiers'
$swa = Invoke-Az staticwebapp show -n $state.staticWebAppName -g $rg
Check 'Static Web App is Free' ($swa.sku.name -eq 'Free')
$site = Invoke-Az resource show -g $rg -n $state.functionAppName --resource-type Microsoft.Web/sites
$plan = Invoke-Az resource show --ids $site.properties.serverFarmId
Check 'Functions plan is Flex Consumption' ($plan.sku.tier -eq 'FlexConsumption')
$ready = $site.properties.functionAppConfig.scaleAndConcurrency.alwaysReady
Check 'No always-ready instances' (-not $ready -or @($ready | Where-Object { $_.instanceCount -gt 0 }).Count -eq 0)
$st = Invoke-Az storage account show -n $state.storageAccountName -g $rg
Check 'Storage is Standard_LRS' ($st.sku.name -eq 'Standard_LRS')
$others = Invoke-Az resource list -g $rg --query "[?type=='Microsoft.Sql/servers' || type=='Microsoft.Compute/virtualMachines' || type=='Microsoft.DocumentDB/databaseAccounts']"
Check 'No database server or VM in resource group' (@($others).Count -eq 0)

Write-Step 'Cost controls'
$budget = Invoke-Az consumption budget list --resource-group $rg
Check 'Budget alert exists' (@($budget).Count -gt 0) "(alerts notify; they do not cap spend)"
$ws = Invoke-Az resource list -g $rg --resource-type Microsoft.OperationalInsights/workspaces
$wsd = Invoke-Az resource show --ids $ws[0].id
Check 'Log daily cap set' ($wsd.properties.workspaceCapping.dailyQuotaGb -gt 0) "($($wsd.properties.workspaceCapping.dailyQuotaGb) GB/day)"
Check 'Log retention <= 31 days' ($wsd.properties.retentionInDays -le 31)
$settings = Invoke-Az functionapp config appsettings list -n $state.functionAppName -g $rg
$s = @{}; foreach ($i in $settings) { $s[$i.name] = $i.value }
foreach ($k in 'MAX_CREATIONS_PER_MONTH', 'WORKER_JOBS_HARD_LIMIT_PER_MONTH', 'WORKER_MAX_RUNTIME_MINUTES', 'MAX_OPERATION_ATTEMPTS') {
    Check "Limit $k" ([int]$s[$k] -gt 0) "= $($s[$k])"
}

Write-Step 'Worker'
$rb = Invoke-Az automation runbook show -g $rg --automation-account-name $state.automationAccountName -n $state.runbookName
Check 'Runbook published' ($rb.state -eq 'Published')
$mod = Invoke-Az resource show -g $rg --resource-type Microsoft.Automation/automationAccounts/modules -n "$($state.automationAccountName)/ExchangeOnlineManagement"
Check 'ExchangeOnlineManagement module imported' ($mod.properties.provisioningState -eq 'Succeeded')
$exoRoles = (Invoke-Graph GET "/servicePrincipals/$($state.automationPrincipalId)/appRoleAssignments").value
Check 'Exchange.ManageAsApp granted' (@($exoRoles).Count -gt 0)
$graphRoles = (Invoke-Graph GET "/servicePrincipals/$($state.functionPrincipalId)/appRoleAssignments").value
Check 'API Graph permissions granted' (@($graphRoles).Count -ge 3)

Write-Step 'Endpoints and authentication enforcement'
$api = "https://$($state.functionAppHostname)/api"
try { $h = Invoke-WebRequest "$api/health" -UseBasicParsing; Check 'API health' ($h.StatusCode -eq 200) } catch { Check 'API health' $false "$_" }
try { Invoke-WebRequest "$api/aliases" -UseBasicParsing | Out-Null; Check 'Anonymous request rejected' $false } catch {
    Check 'Anonymous request rejected' ([int]$_.Exception.Response.StatusCode -eq 401)
}
try { $w = Invoke-WebRequest "https://$($state.staticWebAppHostname)/config.json" -UseBasicParsing; Check 'Web config served' ($w.StatusCode -eq 200) } catch { Check 'Web config served' $false }

Write-Step 'Manual acceptance checks (docs/acceptance.md)'
@(
    '1. In a tenant WITHOUT Entra ID P1/P2 or Power Platform premium licences, sign in with a passkey (Authenticator or FIDO2 key).'
    '2. Create an alias; confirm status turns Active and a test message is delivered.'
    '3. Run scripts/Set-OperationalLimits.ps1 -CreationEnabled $false; confirm creation is refused, removal still works.'
    '4. Stop the Function App (az functionapp stop); send mail to an existing alias; confirm delivery; start it again.'
    '5. With no expiring aliases, confirm the daily expiry run started no Automation job (Automation > Jobs).'
    '6. Run tools/Measure-MonthlyCost.ps1 and record the result in the release notes.'
) | ForEach-Object { Write-Host "  $_" }

if ($failures) { Write-Host "`n$failures automated check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll automated checks passed." -ForegroundColor Green
