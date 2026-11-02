# Copy to deploy.config.psd1 (git-ignored) and fill in. All setup scripts read this file.
@{
    # --- Azure (pay-as-you-go subscription linked to your Microsoft 365 tenant) ---
    SubscriptionId       = '00000000-0000-0000-0000-000000000000'
    ResourceGroup        = 'rg-anonymail'
    Location             = 'australiaeast'
    StaticWebAppLocation = 'eastasia'          # Free SWA regions: eastasia, westus2, centralus, eastus2, westeurope
    NamePrefix           = 'anonymail'

    # --- Microsoft 365 / Entra ---
    TenantId             = '00000000-0000-0000-0000-000000000000'
    ExchangeOrganization = 'contoso.onmicrosoft.com'   # initial (onmicrosoft.com) domain
    AppDisplayName       = 'Anonymail'

    # Accepted domains (must already be Authoritative accepted domains in Exchange Online).
    AliasDomains         = @('alias.contoso.com')

    # Entra security group(s) whose members may use the service. Empty = every member user with a mailbox.
    EligibleGroupIds     = @()

    # Exchange write scope for the worker (ScopedRoleGroup mode). Limits which mailboxes the worker can change.
    # Example restricting to a custom attribute you set on eligible mailboxes:  "CustomAttribute10 -eq 'anonymail'"
    ExchangeRoleMode     = 'ScopedRoleGroup'   # or 'RecipientAdministrator' (simpler, tenant-wide)
    ExchangeScopeFilter  = "RecipientTypeDetails -eq 'UserMailbox'"

    # --- Cost controls ---
    BudgetAmount         = 5                   # in the subscription's billing currency (A$ for AU accounts)
    BudgetContactEmails  = @('it-admin@contoso.com')
    Limits = @{
        CreationEnabled               = $true
        MaxActiveAliasesPerUser       = 100
        MaxCreationsPerUserPerDay     = 10
        MaxCreationsPerMonth          = 300
        MaxAliasLifetimeDays          = 0      # 0 = users may choose "never expires"
        WorkerJobsSoftLimitPerMonth   = 200    # above this, creation pauses; removal/expiry continue
        WorkerJobsHardLimitPerMonth   = 250    # above this, no Automation jobs start
        WorkerMaxRuntimeMinutes       = 5
        MaxOperationAttempts          = 3
        FunctionMaxInstances          = 2
        LogDailyCapGb                 = '0.025'  # Log Analytics requires > 0.023
    }

    # Add http://localhost:5173 while developing; leave empty in production.
    DevOrigins           = @()
}
