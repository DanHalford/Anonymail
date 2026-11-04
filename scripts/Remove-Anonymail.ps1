<#
.SYNOPSIS  Removes the Anonymail deployment.
.DESCRIPTION
    By default removes the Azure resource group (all resources, data and the budget), the Exchange
    role group/scope/service principal, and the Entra app registration.

    IMPORTANT: aliases are ordinary secondary SMTP addresses on users' mailboxes. Removing the
    service does NOT remove them, so mail to existing aliases keeps being delivered. To also strip
    every alias the service created, pass -RemoveAliasesFromMailboxes (runs BEFORE the data is deleted).
    That switch also deletes the "Anonymail - Move to ..." inbox rules the worker created.
.EXAMPLE   ./Remove-Anonymail.ps1 -RemoveAliasesFromMailboxes
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([string]$ConfigPath, [switch]$RemoveAliasesFromMailboxes, [switch]$KeepAppRegistration)
. "$PSScriptRoot/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }
$state = Get-DeployState
Use-Subscription $cfg

$needExo = $RemoveAliasesFromMailboxes -or $cfg.ExchangeRoleMode -eq 'ScopedRoleGroup'
if ($needExo) { Import-Module ExchangeOnlineManagement; Connect-ExchangeOnline -ShowBanner:$false }
try {
    if ($RemoveAliasesFromMailboxes) {
        Write-Step 'Removing aliases from mailboxes'
        $rows = Invoke-Az storage entity query --account-name $state.storageAccountName --table-name aliases --auth-mode login `
            --filter "status eq 'Active' or status eq 'Removing' or status eq 'RemoveFailed'" --num-results 5000
        foreach ($r in $rows.items) {
            if ($PSCmdlet.ShouldProcess("$($r.PartitionKey)", "remove smtp:$($r.RowKey)")) {
                Set-Mailbox -Identity $r.PartitionKey -EmailAddresses @{ Remove = "smtp:$($r.RowKey)" }
                Write-Ok $r.RowKey
            }
        }
        Write-Step 'Removing Anonymail folder rules from mailboxes'
        $rules = Invoke-Az storage entity query --account-name $state.storageAccountName --table-name inboxrules --auth-mode login --num-results 5000
        foreach ($r in $rules.items) {
            if ($PSCmdlet.ShouldProcess("$($r.PartitionKey)", "remove inbox rule '$($r.ruleName)'")) {
                Remove-InboxRule -Mailbox $r.PartitionKey -Identity $r.ruleIdentity -Confirm:$false -ErrorAction SilentlyContinue
                Write-Ok "$($r.ruleName) ($($r.PartitionKey))"
            }
        }
    }
    if ($cfg.ExchangeRoleMode -eq 'ScopedRoleGroup' -and $PSCmdlet.ShouldProcess('Exchange Online', 'remove Anonymail role group, scope and service principal')) {
        Write-Step 'Exchange role objects'
        Remove-RoleGroup -Identity 'Anonymail Worker' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-ManagementScope -Identity 'Anonymail eligible mailboxes' -Confirm:$false -ErrorAction SilentlyContinue
        if ($state.automationPrincipalId) { Remove-ServicePrincipal -Identity $state.automationPrincipalId -Confirm:$false -ErrorAction SilentlyContinue }
        Write-Ok 'Removed'
    }
} finally { if ($needExo) { Disconnect-ExchangeOnline -Confirm:$false | Out-Null } }

if ($PSCmdlet.ShouldProcess($cfg.ResourceGroup, 'delete resource group and ALL its data')) {
    Write-Step "Deleting resource group $($cfg.ResourceGroup)"
    Invoke-Az group delete --name $cfg.ResourceGroup --yes | Out-Null
    Write-Ok 'Deleted (managed identities and their Graph/Exchange grants are removed with their resources)'
}
if (-not $KeepAppRegistration -and $state.appObjectId -and $PSCmdlet.ShouldProcess($cfg.AppDisplayName, 'delete app registration')) {
    Invoke-Graph DELETE "/applications/$($state.appObjectId)" | Out-Null
    Write-Ok 'App registration deleted (soft-deleted for 30 days in Entra)'
}
Write-Host "`nRemoval complete. Check Cost Management next month for zero charges on the resource group." -ForegroundColor Green
