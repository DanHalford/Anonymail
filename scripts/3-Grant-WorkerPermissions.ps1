<#
.SYNOPSIS  Grants the managed identities the tenant permissions they need. Run as a tenant administrator.
.DESCRIPTION
    Function App identity (API):
      * Microsoft Graph  User.Read.All         — confirm account enabled, member (not guest), has mail
      * Microsoft Graph  GroupMember.Read.All  — eligibility group check; group addresses for uniqueness
      * Microsoft Graph  OrgContact.Read.All   — contact addresses for the alias uniqueness check
    Automation identity (Exchange worker):
      * Office 365 Exchange Online  Exchange.ManageAsApp — app-only Exchange Online PowerShell
      * An Exchange role, by ExchangeRoleMode:
          ScopedRoleGroup (default) — custom role group "Anonymail Worker" with the Mail Recipients
                                      role and a recipient write scope (ExchangeScopeFilter).
          RecipientAdministrator    — Entra role Exchange Recipient Administrator (tenant-wide; simpler).
    Ordinary users receive no Azure or admin roles.

    ScopedRoleGroup needs Exchange "organization customization", which new tenants have disabled.
    Enabling it is a one-time, irreversible, organisation-wide change (it allows custom role groups,
    scopes and policies; it does not change existing behaviour). The script will not do it unless you
    pass -EnableOrganizationCustomization. The change can take a while to apply; if role-group
    creation still fails afterwards, wait and re-run.
#>
param([string]$ConfigPath, [switch]$EnableOrganizationCustomization)
. "$PSScriptRoot/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }
$state = Get-DeployState
if (-not $state.functionPrincipalId) { throw 'Run 2-Deploy-Infrastructure.ps1 first.' }
Use-Subscription $cfg

Write-Step 'API (Function App) Graph permissions'
Grant-AppRole $state.functionPrincipalId $GraphAppId 'User.Read.All'
Grant-AppRole $state.functionPrincipalId $GraphAppId 'GroupMember.Read.All'
Grant-AppRole $state.functionPrincipalId $GraphAppId 'OrgContact.Read.All'

Write-Step 'Exchange worker (Automation) permissions'
Grant-AppRole $state.automationPrincipalId $ExchangeAppId 'Exchange.ManageAsApp'
$miSp = Invoke-Graph GET "/servicePrincipals/$($state.automationPrincipalId)?`$select=id,appId,displayName"

switch ($cfg.ExchangeRoleMode) {
    'RecipientAdministrator' {
        $roleTemplateId = '31392ffb-586c-42d1-9346-e59415a2cc4e' # Exchange Recipient Administrator
        $existing = (Invoke-Graph GET "/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($miSp.id)' and roleDefinitionId eq '$roleTemplateId'").value
        if (-not $existing) {
            Invoke-Graph POST '/roleManagement/directory/roleAssignments' @{ principalId = $miSp.id; roleDefinitionId = $roleTemplateId; directoryScopeId = '/' } | Out-Null
        }
        Write-Ok 'Exchange Recipient Administrator assigned to the Automation identity'
    }
    'ScopedRoleGroup' {
        Import-Module ExchangeOnlineManagement
        Write-Host '  Sign in to Exchange Online as an Organization Management administrator...'
        Connect-ExchangeOnline -ShowBanner:$false
        try {
            if ((Get-OrganizationConfig).IsDehydrated) {
                if (-not $EnableOrganizationCustomization) {
                    throw @"
Exchange organization customization is not enabled in this tenant, so custom role groups and
management scopes cannot be created. Choose one:
  * Re-run with -EnableOrganizationCustomization  (one-time, irreversible, organisation-wide; keeps the worker scoped), or
  * Set ExchangeRoleMode = 'RecipientAdministrator' in deploy.config.psd1 and re-run (tenant-wide recipient admin role).
"@
                }
                Write-Host '  Enabling Exchange organization customization (one-time)...'
                try {
                    Enable-OrganizationCustomization -ErrorAction Stop
                    Write-Ok 'Organization customization requested'
                } catch {
                    # Already requested on an earlier run and still applying.
                    Write-Warn2 "Enable-OrganizationCustomization: $($_.Exception.Message.Trim('|'))"
                }
            }
            $stillApplying = 'Organization customization has been requested but Exchange has not applied it yet (this can take an hour or more). Wait, then re-run this script; no other changes are needed.'
            if (-not (Get-ServicePrincipal -Identity $miSp.id -ErrorAction SilentlyContinue)) {
                New-ServicePrincipal -AppId $miSp.appId -ObjectId $miSp.id -DisplayName "Anonymail worker ($($state.automationAccountName))" -ErrorAction Stop | Out-Null
            }
            $scopeName = 'Anonymail eligible mailboxes'
            try {
                if (Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue) {
                    Set-ManagementScope -Identity $scopeName -RecipientRestrictionFilter $cfg.ExchangeScopeFilter -ErrorAction Stop
                } else {
                    New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $cfg.ExchangeScopeFilter -ErrorAction Stop | Out-Null
                }
            } catch {
                if ("$_" -match 'Enable-OrganizationCustomization') { throw $stillApplying }
                throw
            }
            $groupName = 'Anonymail Worker'
            if (-not (Get-RoleGroup -Identity $groupName -ErrorAction SilentlyContinue)) {
                New-RoleGroup -Name $groupName -Roles 'Mail Recipients' -CustomRecipientWriteScope $scopeName -ErrorAction Stop `
                    -Description 'Anonymail Automation identity: adds/removes secondary SMTP addresses on in-scope mailboxes.' | Out-Null
            }
            if (-not (Get-RoleGroupMember -Identity $groupName -ErrorAction Stop | Where-Object { $_.ExternalDirectoryObjectId -eq $miSp.id })) {
                Add-RoleGroupMember -Identity $groupName -Member $miSp.id -ErrorAction Stop
            }
            Write-Ok "Role group '$groupName' (Mail Recipients, scope: $($cfg.ExchangeScopeFilter))"
        } finally { Disconnect-ExchangeOnline -Confirm:$false | Out-Null }
    }
    default { throw "Unknown ExchangeRoleMode '$($cfg.ExchangeRoleMode)'" }
}

Write-Host "`nPermissions granted. Exchange role changes can take up to an hour to apply." -ForegroundColor Green
