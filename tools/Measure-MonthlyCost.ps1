<#
.SYNOPSIS  Measures this month's Anonymail usage and forecasts the monthly cost against the A$5 target.
.DESCRIPTION
    Collects MEASURED values (not assumptions):
      * Automation job minutes — for this account AND every Automation account in the subscription,
        because the 500 free minutes are shared per subscription.
      * Functions on-demand executions and execution units (Flex Consumption metrics).
      * Storage transactions and used capacity.
      * Log Analytics ingestion.
      * Actual month-to-date cost for the resource group (Cost Management).
    Then projects to a full month and applies unit rates. The default rates are PLACEHOLDERS in A$:
    replace them with current rates for your region from the Azure pricing pages / calculator (AUD).
.EXAMPLE   ./tools/Measure-MonthlyCost.ps1 -OutFile docs/measurements/2026-11.json
#>
param(
    [string]$ConfigPath,
    [double]$TargetAud = 5.0,
    # ---- placeholder unit rates (A$) — VERIFY before publishing an estimate ----
    [double]$AutomationPerMinute = 0.0031,
    [int]$AutomationFreeMinutes = 500,
    [double]$FunctionsPerGbSecond = 0.000040,
    [double]$FunctionsPerMillionExecutions = 0.62,
    [int]$FunctionsFreeGbSeconds = 100000,
    [int]$FunctionsFreeExecutions = 250000,
    [double]$BlobPer10kTransactions = 0.085,   # priced as hot write ops (conservative; Functions host leases land here)
    [double]$QueuePer10kTransactions = 0.065,
    [double]$TablePer10kTransactions = 0.0006,
    [double]$StoragePerGbMonth = 0.07,
    [double]$LogsPerGb = 4.50,
    [double]$LogsFreeGbAvailable = 5.0,       # reduce if other workspaces on the billing account use it
    [string]$OutFile
)
. "$PSScriptRoot/../scripts/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }
$state = Get-DeployState
Use-Subscription $cfg
$rg = $cfg.ResourceGroup

$now = [DateTime]::UtcNow
$monthStart = [DateTime]::new($now.Year, $now.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
$daysInMonth = [DateTime]::DaysInMonth($now.Year, $now.Month)
$elapsedDays = [Math]::Max(($now - $monthStart).TotalDays, 0.5)
$scale = $daysInMonth / $elapsedDays
$start = $monthStart.ToString('o'); $end = $now.ToString('o')

function Get-JobMinutes([string]$Group, [string]$Account) {
    $jobs = Invoke-Az automation job list -g $Group --automation-account-name $Account
    $mins = 0; $count = 0
    foreach ($j in $jobs) {
        if (-not $j.startTime) { continue }
        $s = [DateTime]::Parse($j.startTime).ToUniversalTime()
        if ($s -lt $monthStart) { continue }
        $e = if ($j.endTime) { [DateTime]::Parse($j.endTime).ToUniversalTime() } else { $now }
        $mins += [Math]::Ceiling(($e - $s).TotalMinutes); $count++
    }
    @{ minutes = $mins; jobs = $count }
}

function Get-MetricTotal([string]$ResourceId, [string]$Metric, [string]$Aggregation = 'Total') {
    $m = Invoke-Az monitor metrics list --resource $ResourceId --metric $Metric --start-time $start --end-time $end --interval P1D --aggregation $Aggregation
    $vals = foreach ($ts in $m.value[0].timeseries) { foreach ($d in $ts.data) { $d[$Aggregation.ToLower()] } }
    if ($Aggregation -eq 'Average') { ($vals | Where-Object { $_ } | Measure-Object -Maximum).Maximum } else { ($vals | Measure-Object -Sum).Sum }
}

Write-Step 'Automation (shared 500 free minutes per subscription)'
Invoke-Az extension add --name automation --upgrade --yes | Out-Null
$ours = Get-JobMinutes $rg $state.automationAccountName
$all = 0
foreach ($aa in (Invoke-Az automation account list)) { $all += (Get-JobMinutes $aa.resourceGroup $aa.name).minutes }
Write-Ok "Anonymail: $($ours.jobs) jobs, $($ours.minutes) min so far; subscription total: $all min"

Write-Step 'Functions'
$fnId = (Invoke-Az functionapp show -n $state.functionAppName -g $rg).id
$execs = [double](Get-MetricTotal $fnId 'OnDemandFunctionExecutionCount')
$unitsMbMs = [double](Get-MetricTotal $fnId 'OnDemandFunctionExecutionUnits')
$gbs = $unitsMbMs / 1024 / 1000
Write-Ok "$execs executions, $([Math]::Round($gbs,1)) GB-s so far"

Write-Step 'Storage'
$stId = (Invoke-Az storage account show -n $state.storageAccountName -g $rg).id
$tx = @{}
foreach ($svc in 'blob', 'queue', 'table') { $tx[$svc] = [double](Get-MetricTotal "$stId/${svc}Services/default" 'Transactions') }
$capGb = [double](Get-MetricTotal $stId 'UsedCapacity' 'Average') / 1GB
Write-Ok "blob $($tx.blob), queue $($tx.queue), table $($tx.table) transactions so far; $([Math]::Round($capGb,4)) GB used"

Write-Step 'Log Analytics'
$ws = (Invoke-Az resource list -g $rg --resource-type Microsoft.OperationalInsights/workspaces)[0]
$wsd = Invoke-Az monitor log-analytics workspace show --ids $ws.id
$q = Invoke-Az monitor log-analytics query -w $wsd.customerId --analytics-query "Usage | where TimeGenerated >= startofmonth(now()) and IsBillable == true | summarize GB = sum(Quantity) / 1024"
$logGb = if ($q -and $q[0].GB) { [double]$q[0].GB } else { 0 }
Write-Ok "$([Math]::Round($logGb,4)) GB billable ingestion so far"

Write-Step 'Actual month-to-date cost (Cost Management; may lag up to ~24h)'
$scope = "/subscriptions/$($cfg.SubscriptionId)/resourceGroups/$rg"
$body = @{ type = 'ActualCost'; timeframe = 'MonthToDate'; dataset = @{ granularity = 'None'; aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } } } }
$tmp = New-TemporaryFile; $body | ConvertTo-Json -Depth 6 | Set-Content $tmp
$actual = $null
try {
    $cm = Invoke-Az rest --method post --url "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01" --body "@$tmp" --headers Content-Type=application/json
    if ($cm.properties.rows.Count) { $actual = @{ amount = $cm.properties.rows[0][0]; currency = $cm.properties.rows[0][1] } }
} catch { Write-Warn2 "Cost Management query failed: $_" } finally { Remove-Item $tmp }
if ($actual) { Write-Ok "$([Math]::Round($actual.amount, 2)) $($actual.currency) month to date" }

# ---- projection ----
$p = @{
    automationMinutes = $ours.minutes * $scale
    subscriptionAutomationMinutes = $all * $scale
    functionExecutions = $execs * $scale
    functionGbSeconds = $gbs * $scale
    blobTransactions = $tx.blob * $scale
    queueTransactions = $tx.queue * $scale
    tableTransactions = $tx.table * $scale
    storageGb = $capGb
    logGb = $logGb * $scale
}
$otherMinutes = [Math]::Max($p.subscriptionAutomationMinutes - $p.automationMinutes, 0)
$freeLeft = [Math]::Max($AutomationFreeMinutes - $otherMinutes, 0)
$cost = [ordered]@{
    automation = [Math]::Max($p.automationMinutes - $freeLeft, 0) * $AutomationPerMinute
    functions  = [Math]::Max($p.functionGbSeconds - $FunctionsFreeGbSeconds, 0) * $FunctionsPerGbSecond +
                 [Math]::Max($p.functionExecutions - $FunctionsFreeExecutions, 0) / 1e6 * $FunctionsPerMillionExecutions
    storage    = ($p.blobTransactions * $BlobPer10kTransactions + $p.queueTransactions * $QueuePer10kTransactions +
                  $p.tableTransactions * $TablePer10kTransactions) / 1e4 + $p.storageGb * $StoragePerGbMonth
    logs       = [Math]::Max($p.logGb - $LogsFreeGbAvailable, 0) * $LogsPerGb
}
$total = ($cost.Values | Measure-Object -Sum).Sum

Write-Step "Projected full month (x$([Math]::Round($scale,2)) of $([Math]::Round($elapsedDays,1)) days measured; placeholder A$ rates)"
'{0,-12} {1,10}' -f 'Component', 'A$' | Write-Host
foreach ($k in $cost.Keys) { '{0,-12} {1,10:N2}' -f $k, $cost[$k] | Write-Host }
'{0,-12} {1,10:N2}' -f 'TOTAL', $total | Write-Host
Write-Host ("Automation free minutes left for Anonymail after other accounts: {0:N0} of {1}" -f $freeLeft, $AutomationFreeMinutes)
if ($total -gt $TargetAud) {
    Write-Host "Forecast exceeds A`$$TargetAud. Document the cause (largest component above) and reduce limits or revise the implementation before release." -ForegroundColor Red
} else { Write-Host "Forecast within the A`$$TargetAud target." -ForegroundColor Green }

if ($OutFile) {
    @{ measuredAt = $end; elapsedDays = $elapsedDays; projected = $p; costAud = $cost; totalAud = $total; actualMonthToDate = $actual; rates = $PSBoundParameters } |
        ConvertTo-Json -Depth 6 | Set-Content $OutFile -Encoding utf8
    Write-Ok "Saved $OutFile"
}
