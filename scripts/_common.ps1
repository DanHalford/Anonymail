# Shared helpers for the Anonymail setup scripts. Dot-source; do not run directly.
# Version 1: catch uninitialised variables, but allow optional keys on config/state/Graph
# hashtables (e.g. $state.staticWebAppHostname before step 2) to read as $null.
Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:StatePath = Join-Path $PSScriptRoot '.deploy-state.json'

function Get-DeployConfig([string]$Path = (Join-Path $PSScriptRoot 'deploy.config.psd1')) {
    if (-not (Test-Path $Path)) { throw "Config not found: $Path. Copy deploy.config.sample.psd1 to deploy.config.psd1 and edit it." }
    Import-PowerShellDataFile $Path
}

function Get-DeployState {
    if (Test-Path $script:StatePath) { Get-Content $script:StatePath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
}

function Save-DeployState([hashtable]$State) {
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $script:StatePath -Encoding utf8
}

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "  [!]  $Text" -ForegroundColor Yellow }

# Runs az and parses JSON output; throws on non-zero exit.
function Invoke-Az {
    $out = & az @args --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed:`n$out" }
    $text = ($out | Where-Object { $_ -is [string] }) -join "`n"
    if ($text.Trim().StartsWith('{') -or $text.Trim().StartsWith('[')) { $text | ConvertFrom-Json -AsHashtable } else { $text.Trim() }
}

# Microsoft Graph call using the signed-in administrator's az token. Calls Graph directly rather
# than via `az rest`, because az on Windows is a .cmd wrapper and cmd.exe mangles URLs containing
# parentheses, quotes or spaces (e.g. servicePrincipals(appId='...') or $filter expressions).
$script:GraphToken = $null
$script:GraphTokenAt = [DateTime]::MinValue
function Invoke-Graph([string]$Method, [string]$Path, $Body) {
    if (-not $script:GraphToken -or ([DateTime]::UtcNow - $script:GraphTokenAt).TotalMinutes -gt 45) {
        $script:GraphToken = Invoke-Az account get-access-token --resource-type ms-graph --query accessToken -o tsv
        $script:GraphTokenAt = [DateTime]::UtcNow
    }
    $request = @{
        Method  = $Method
        Uri     = "https://graph.microsoft.com/v1.0$Path"
        Headers = @{ Authorization = "Bearer $script:GraphToken" }
    }
    if ($null -ne $Body) {
        $request.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10))
        $request.ContentType = 'application/json'
    }
    try { Invoke-RestMethod @request }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Graph $Method $Path failed: $detail"
    }
}

function Use-Subscription($Cfg) {
    $acct = Invoke-Az account show
    if ($acct.tenantId -ne $Cfg.TenantId) { throw "az is signed in to tenant $($acct.tenantId); expected $($Cfg.TenantId). Run: az login --tenant $($Cfg.TenantId)" }
    Invoke-Az account set --subscription $Cfg.SubscriptionId | Out-Null
}

# Grants an application permission (app role) to a service principal, idempotently.
function Grant-AppRole([string]$PrincipalObjectId, [string]$ResourceAppId, [string]$RoleValue) {
    $resource = (Invoke-Graph GET "/servicePrincipals(appId='$ResourceAppId')?`$select=id,appRoles,displayName")
    $role = $resource.appRoles | Where-Object { $_.value -eq $RoleValue -and $_.allowedMemberTypes -contains 'Application' }
    if (-not $role) { throw "App role $RoleValue not found on $ResourceAppId" }
    $existing = (Invoke-Graph GET "/servicePrincipals/$PrincipalObjectId/appRoleAssignments").value |
        Where-Object { $_.appRoleId -eq $role.id -and $_.resourceId -eq $resource.id }
    if ($existing) { Write-Ok "$RoleValue already granted"; return }
    Invoke-Graph POST "/servicePrincipals/$PrincipalObjectId/appRoleAssignments" @{
        principalId = $PrincipalObjectId; resourceId = $resource.id; appRoleId = $role.id
    } | Out-Null
    Write-Ok "Granted $RoleValue ($($resource.displayName))"
}

$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
$script:ExchangeAppId = '00000002-0000-0ff1-ce00-000000000000'
