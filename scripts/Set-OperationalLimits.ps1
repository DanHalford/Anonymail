<#
.SYNOPSIS  Adjusts creation quotas and limits on a running deployment.
.EXAMPLE   ./Set-OperationalLimits.ps1 -CreationEnabled $false     # pause new aliases (removal + expiry continue)
.EXAMPLE   ./Set-OperationalLimits.ps1 -MaxCreationsPerMonth 100 -WorkerJobsHardLimitPerMonth 150
.NOTES     Changing app settings restarts the Function App (a few seconds). Mail delivery is unaffected.
#>
param(
    [string]$ConfigPath,
    [Nullable[bool]]$CreationEnabled,
    [Nullable[int]]$MaxActiveAliasesPerUser,
    [Nullable[int]]$MaxCreationsPerUserPerDay,
    [Nullable[int]]$MaxCreationsPerMonth,
    [Nullable[int]]$MaxAliasLifetimeDays,
    [Nullable[int]]$WorkerJobsSoftLimitPerMonth,
    [Nullable[int]]$WorkerJobsHardLimitPerMonth,
    [Nullable[int]]$WorkerMaxRuntimeMinutes,
    [Nullable[int]]$MaxOperationAttempts
)
. "$PSScriptRoot/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }
$state = Get-DeployState
Use-Subscription $cfg

$map = [ordered]@{
    CreationEnabled             = 'CREATION_ENABLED'
    MaxActiveAliasesPerUser     = 'MAX_ACTIVE_ALIASES_PER_USER'
    MaxCreationsPerUserPerDay   = 'MAX_CREATIONS_PER_USER_PER_DAY'
    MaxCreationsPerMonth        = 'MAX_CREATIONS_PER_MONTH'
    MaxAliasLifetimeDays        = 'MAX_ALIAS_LIFETIME_DAYS'
    WorkerJobsSoftLimitPerMonth = 'WORKER_JOBS_SOFT_LIMIT_PER_MONTH'
    WorkerJobsHardLimitPerMonth = 'WORKER_JOBS_HARD_LIMIT_PER_MONTH'
    WorkerMaxRuntimeMinutes     = 'WORKER_MAX_RUNTIME_MINUTES'
    MaxOperationAttempts        = 'MAX_OPERATION_ATTEMPTS'
}
$pairs = foreach ($p in $map.Keys) {
    $v = Get-Variable -Name $p -ValueOnly
    if ($null -ne $v) { "$($map[$p])=$($v.ToString().ToLowerInvariant())" }
}
if (-not $pairs) { Write-Host 'Nothing to change.'; return }
Invoke-Az functionapp config appsettings set -n $state.functionAppName -g $cfg.ResourceGroup --settings @pairs | Out-Null
$pairs | ForEach-Object { Write-Ok $_ }
Write-Host 'Also update deploy.config.psd1 so the next infrastructure deployment keeps these values.'
