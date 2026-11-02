# Guided setup

A **tenant administrator** performs every privileged step. Ordinary users need no Azure
subscription access and no administrative role. They just sign in to the web app.

Nothing here depends on the developer's accounts, infrastructure or credentials. All resources are
created in *your* subscription and tenant.

## Prerequisites

- A standard **pay-as-you-go** Azure subscription in the same Entra tenant as Microsoft 365. Not a
  trial, credit-based or developer subscription.
- Microsoft 365 mailboxes for eligible users, and each alias domain added as an **Authoritative
  accepted domain** in Exchange Online.
- Tools: PowerShell 7, Azure CLI with Bicep, Node.js 20+, Azure Functions Core Tools 4, and the
  `ExchangeOnlineManagement` module.
- Roles held by whoever runs setup:

  | Where | Role | Used for |
  |---|---|---|
  | Azure subscription | Owner (or Contributor + User Access Administrator) | Resource group and role assignments |
  | Entra | Application Administrator | App registration |
  | Entra | Privileged Role Administrator or Global Administrator | Admin consent; app-role grants to managed identities |
  | Exchange Online | Organization Management | Role group and management scope (ScopedRoleGroup mode) |

## Step 0: configure and check

```powershell
Copy-Item scripts/deploy.config.sample.psd1 scripts/deploy.config.psd1
# Edit: subscription, tenant, ExchangeOrganization, AliasDomains, EligibleGroupIds, BudgetContactEmails, Limits
az login --tenant <tenant-id>
./scripts/0-Test-Prerequisites.ps1
```

**Domain and eligibility configuration**

- `AliasDomains`: the accepted domains users may pick from. A dedicated subdomain such as
  `alias.contoso.com` keeps aliases apart from staff addresses.
- `EligibleGroupIds`: Entra security group(s) of eligible users. Leave it empty to allow every
  enabled member user with a mailbox. Guests are always refused.
- `ExchangeScopeFilter`: limits which mailboxes the worker may modify. Keep it aligned with
  eligibility. For example, set `CustomAttribute10 = anonymail` on eligible mailboxes and use
  `"CustomAttribute10 -eq 'anonymail'"`.

## Step 1: Entra app registration

```powershell
./scripts/1-Register-EntraApp.ps1
```

This creates a **single-tenant** app with SPA redirect URIs, exposes the delegated scope
`Aliases.Manage`, issues v2 tokens with security-group claims, and grants admin consent. It uses
no P1/P2 feature.

## Step 2: Azure resources (one resource group)

```powershell
./scripts/2-Deploy-Infrastructure.ps1 -WhatIf   # preview
./scripts/2-Deploy-Infrastructure.ps1
```

This deploys `infra/main.bicep` and **prints every tier**, so you can confirm nothing paid was
deployed:

- SWA Free
- Flex Consumption with 0 always-ready instances
- Standard_LRS storage
- Automation Basic, billed per minute after the free allowance
- Log Analytics with a daily cap
- the A$5 budget alert

It then adds the SWA hostname to the app registration's redirect URIs.

## Step 3: API and Exchange worker permissions

```powershell
./scripts/3-Grant-WorkerPermissions.ps1
```

| Identity | Permission | Why |
|---|---|---|
| Function App managed identity | Graph `User.Read.All` (application) | Confirm the user is enabled, a member, and has mail |
| Function App managed identity | Graph `GroupMember.Read.All` (application) | Eligibility check when token group claims overflow; group addresses for the uniqueness check |
| Function App managed identity | Graph `OrgContact.Read.All` (application) | Contact addresses for the uniqueness check |
| Function App managed identity | *Automation Operator* on the Automation account (set by Bicep) | Start worker jobs |
| Function App managed identity | Storage Blob/Queue/Table data roles (set by Bicep) | Host storage, queue, tables |
| Automation managed identity | Exchange `Exchange.ManageAsApp` (application) | App-only Exchange Online PowerShell |
| Automation managed identity | Exchange role group **Anonymail Worker** (Mail Recipients, custom write scope), or Entra *Exchange Recipient Administrator* | Add/remove proxy addresses |
| Automation managed identity | Storage Queue Data Message Processor and Table Data Contributor (set by Bicep) | Drain queue, update status |

Exchange role assignments can take up to an hour to apply.

**Exchange organization customization.** `ScopedRoleGroup` mode needs custom role groups and
management scopes. Many tenants have these disabled until `Enable-OrganizationCustomization` has
been run once. That is a one-time change across the whole organisation and can't be undone. It
allows customisation but doesn't change existing behaviour. The script detects this and stops
unless you choose one of these:

- `./scripts/3-Grant-WorkerPermissions.ps1 -EnableOrganizationCustomization` enables it and keeps
  the worker limited to `ExchangeScopeFilter`. The change can take a while to apply, so if
  role-group creation still fails, wait and re-run.
- `ExchangeRoleMode = 'RecipientAdministrator'` avoids customization. Instead it gives the worker
  the tenant-wide Exchange Recipient Administrator role, which is broader.

## Step 4: publish code

```powershell
./scripts/4-Publish-Application.ps1
```

This builds and tests the API and publishes it to the Function App. It uploads and publishes the
runbook, then builds the SPA, writes `config.json` and deploys to SWA.

## Step 5: verify

```powershell
./scripts/5-Test-Deployment.ps1
```

The script runs automated checks:

- tiers and no paid hosting;
- budget, log cap and limits;
- runbook and module;
- permissions;
- anonymous requests are rejected.

It then lists the manual acceptance checks in [acceptance.md](acceptance.md), including passkey
sign-in in a tenant without premium licences.

## Cost alerts and operational limits

- The budget is created at **resource-group** scope, in the subscription's billing currency.
  **Alerts do not cap spending.**
- To change limits without redeploying:

  ```powershell
  ./scripts/Set-OperationalLimits.ps1 -CreationEnabled $false        # pause creation; removal and expiry continue
  ./scripts/Set-OperationalLimits.ps1 -MaxCreationsPerMonth 100
  ```

- To measure cost, run `./tools/Measure-MonthlyCost.ps1`. See [cost-model.md](cost-model.md).

## Removal

```powershell
./scripts/Remove-Anonymail.ps1 -RemoveAliasesFromMailboxes   # also strips aliases from mailboxes
./scripts/Remove-Anonymail.ps1                               # leaves aliases delivering
```

This deletes the resource group (with all data and the budget), the Exchange role group, scope and
service principal, and the app registration. Managed identities and their Graph and Exchange
grants are deleted along with their resources. **Without `-RemoveAliasesFromMailboxes`, existing
aliases keep delivering mail**, because they are native Exchange addresses. Check Cost Management
the following month to confirm the resource group shows no charges.
