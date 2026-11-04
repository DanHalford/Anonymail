<#
.SYNOPSIS  Creates/updates the single-tenant Entra app registration (SPA + API). Idempotent.
.DESCRIPTION
    * Single tenant (AzureADMyOrg) — only your organisation's users can obtain tokens.
    * Exposes delegated scope Aliases.Manage; v2 access tokens; security-group claims.
    * SPA redirect URIs: the Static Web App hostname (after step 2) plus any CustomDomains and DevOrigins.
    * Requests delegated Graph User.Read (sign-in) and Mail.ReadBasic (the SPA lists the signed-in
      user's own mail folders for the "Deliver to" picker; it can't read message content).
    * Grants tenant-wide admin consent so users are not prompted.
    No Entra ID P1/P2 feature is used. Re-run after step 2 to add the production redirect URI
    (step 2 does this automatically).
#>
param([string]$ConfigPath)
. "$PSScriptRoot/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }
$state = Get-DeployState
Use-Subscription $cfg

Write-Step "App registration '$($cfg.AppDisplayName)'"
$app = (Invoke-Graph GET "/applications?`$filter=displayName eq '$($cfg.AppDisplayName)'").value | Select-Object -First 1
if (-not $app) {
    $app = Invoke-Graph POST '/applications' @{ displayName = $cfg.AppDisplayName; signInAudience = 'AzureADMyOrg' }
    Write-Ok "Created appId $($app.appId)"
} else { Write-Ok "Found appId $($app.appId)" }

$scope = $app.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'Aliases.Manage' }
$scopeId = if ($scope) { $scope.id } else { [guid]::NewGuid().ToString() }

$redirects = [System.Collections.Generic.List[string]]::new()
if ($state.staticWebAppHostname) { $redirects.Add("https://$($state.staticWebAppHostname)/") }
foreach ($o in @(Get-CustomOrigins $cfg) + @($cfg.DevOrigins | Where-Object { $_ })) { $redirects.Add($o.TrimEnd('/') + '/') }

Invoke-Graph PATCH "/applications/$($app.id)" @{
    identifierUris        = @("api://$($app.appId)")
    groupMembershipClaims = 'SecurityGroup'
    spa                   = @{ redirectUris = @($redirects) }
    api                   = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @(@{
            id = $scopeId; value = 'Aliases.Manage'; type = 'User'; isEnabled = $true
            adminConsentDisplayName = 'Manage your Anonymail aliases'
            adminConsentDescription = 'Allows the signed-in user to create, list and remove aliases on their own mailbox.'
            userConsentDisplayName  = 'Manage your Anonymail aliases'
            userConsentDescription  = 'Create, list and remove aliases on your own mailbox.'
        })
    }
} | Out-Null

# Second PATCH: the app requests its own scope (+ Graph User.Read for sign-in, Mail.ReadBasic for the folder picker).
$graphScopes = (Invoke-Graph GET "/servicePrincipals(appId='$GraphAppId')?`$select=oauth2PermissionScopes").oauth2PermissionScopes
$graphAccess = foreach ($name in 'User.Read', 'Mail.ReadBasic') {
    $s = $graphScopes | Where-Object { $_.value -eq $name }
    if (-not $s) { throw "Graph delegated permission $name not found" }
    @{ id = $s.id; type = 'Scope' }
}
Invoke-Graph PATCH "/applications/$($app.id)" @{
    requiredResourceAccess = @(
        @{ resourceAppId = $GraphAppId; resourceAccess = @($graphAccess) }
        @{ resourceAppId = $app.appId; resourceAccess = @(@{ id = $scopeId; type = 'Scope' }) }
    )
} | Out-Null
Write-Ok "Redirect URIs: $($redirects -join ', ')"

Write-Step 'Service principal and admin consent'
$sp = (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$($app.appId)'").value | Select-Object -First 1
if (-not $sp) { $sp = Invoke-Graph POST '/servicePrincipals' @{ appId = $app.appId; tags = @('anonymail') } }
Start-Sleep -Seconds 5 # replication
Invoke-Az ad app permission admin-consent --id $app.appId | Out-Null
Write-Ok 'Admin consent granted'

$state.appId = $app.appId
$state.appObjectId = $app.id
$state.tenantId = $cfg.TenantId
Save-DeployState $state
Write-Host "`nApp registration ready: $($app.appId)" -ForegroundColor Green
