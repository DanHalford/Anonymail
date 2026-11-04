# Anonymail

**Disposable email aliases for Microsoft 365, on your organisation's own domain.**

Anonymail gives everyone in a Microsoft 365 organisation a self-service page for creating throwaway
addresses such as `quiet-otter-07@alias.contoso.com`. Each alias delivers straight into the
person's existing Exchange Online mailbox. Use one address per shop, newsletter, competition or
supplier. When an address starts attracting spam, or you're done with it, remove it, or give it an
expiry date when you create it.

It is, in short, Apple's iCloud **Hide My Email**, rebuilt for a Microsoft 365 tenant. The comparison
below explains where the two differ.

Everything runs in **your own** Azure subscription and tenant, at a target of **under A$5 a month**
for a small organisation. There is no third-party service, no relay, and no per-user licence.

---

## What users see

1. Sign in with their normal work account. Passkeys work if the organisation has enabled them.
2. The form already offers a random address, such as `brave-otter-42@alias.contoso.com`. It has been
   checked against every address in the organisation, so it's guaranteed free.
   - **New suggestion** swaps in another one if the first doesn't appeal.
   - **Choose my own name** lets the user type one instead, if the administrator allows it.
3. Optionally, add a **note** ("Qantas competition") and an **expiry date**.
4. Press **Create alias**. Within a few minutes the address is live, and mail sent to it lands in
   their inbox.
5. Their aliases are listed with status, note and expiry. **Remove** retires one immediately.
   Expired aliases are removed automatically overnight.

## Compared with iCloud Hide My Email

Both services hand out random addresses that deliver to your real inbox, and both let you retire an
address when it's no longer wanted. They're built on opposite models:

- **Hide My Email** is a *forwarding relay* run by Apple, on Apple's domain.
- **Anonymail** adds the alias *to your own mailbox* in Exchange, on a domain your organisation owns.

| | iCloud Hide My Email | Anonymail |
|---|---|---|
| **Who it's for** | Individuals with an Apple account | Staff of one Microsoft 365 organisation |
| **Cost** | Included in a paid iCloud+ subscription, per person | Azure pay-as-you-go, targeting < A$5/month for the whole organisation. No per-user cost. |
| **Address domain** | `@icloud.com`, shared by millions of users | Your organisation's own domain, ideally a dedicated subdomain |
| **What the address reveals** | Nothing about you | Your **organisation**, through the domain, but not your name |
| **Address format** | Random string, e.g. `abc_def_1x@icloud.com` | Readable random name, e.g. `brave-otter-42@…`, with a **New suggestion** button. Optional custom names. |
| **How mail arrives** | Apple receives it and forwards it to your personal address | Delivered natively by Exchange Online, with no forwarding hop |
| **Who handles your mail** | Apple's relay servers, then your mail provider | Only Microsoft 365, already your mail provider |
| **Spam and malware filtering** | Apple's filtering, then your provider's | Exchange Online Protection, with the organisation's existing policies |
| **If the service is down** | Forwarding depends on Apple's relay | **Existing aliases keep working**: they're ordinary mailbox addresses, so delivery never depends on Anonymail |
| **Expiry dates** | No. Addresses last until you deactivate them. | **Yes**: pick a drop-dead date, and the alias is removed automatically |
| **Retiring an address** | Deactivate (can be reactivated) or delete | Remove: mail to it then bounces. Removal is permanent. |
| **Address reuse** | — | Never: a removed address is never given to anyone else |
| **Notes / labels** | Label and note | Note |
| **Replying from the alias** | Supported through the relay | Not by default. Replies come from your primary address unless the administrator enables Exchange's *send from alias* setting (`Set-OrganizationConfig -SendFromAliasEnabled $true`), which lets Outlook send as the alias. |
| **Hidden from colleagues** | — (personal account) | **No**: aliases are proxy addresses on your mailbox, so administrators, and colleagues looking at your directory entry, can see them |
| **Where you create them** | iCloud settings, Safari and Mail autofill, Sign in with Apple | The Anonymail web page. No browser or OS autofill integration. |
| **Limits** | Set by Apple | Set by your administrator: per-user active total, per-day and per-month creation, worker job budget |
| **Administration and audit** | None. It's personal. | Eligibility by Entra group, quotas, a pause switch, and an audit log of every create, remove and expiry |
| **Data location** | Apple | Your tenant and your Azure subscription, in a region you choose |

**Choose Anonymail when** you want disposable addresses for work. That means mail kept in
Microsoft 365 under your organisation's retention, filtering and compliance; no personal
subscriptions; and the administrator in control of who can create addresses and how many.

**It is not an anonymity tool.** The domain identifies the organisation, and the organisation can
always see which alias belongs to whom. What it does hide is the person's name and primary address
from the sites they hand an alias to. It also makes it obvious which site leaked or sold an
address: that alias is the only one getting the spam.

## How it works

```
Browser ──MSAL sign-in (Entra ID, passkeys supported)──► Static Web App (Free tier)
   │ bearer token
   ▼
Functions API (Flex Consumption, scales to zero) ──► Table Storage
   │  1. uniqueness check (Anonymail + Microsoft Graph)  aliases, reservations, quotas,
   │  2. record + enqueue                                expiry index, audit log
   │  3. start worker only if idle                              ▲
   ▼                                                            │ status
Storage Queue ──► Azure Automation runbook (one short job per burst of activity)
                     └─► Exchange Online: Set-Mailbox -EmailAddresses @{Add / Remove}
```

- **An alias is a secondary SMTP address** on the owner's mailbox. Exchange treats it exactly like
  any other address the person has, so delivery, filtering and retention are unchanged.
- **Uniqueness is checked before an address is offered, and again at creation.** The check covers
  Anonymail's own reservations and the directory: users (mail, sign-in name and every proxy
  address), groups and contacts. The Exchange worker makes a final check before adding it.
- **Nothing runs when there's nothing to do.** The API scales to zero. The Exchange worker starts
  only when operations are queued, processes them in batches, and stops. A daily expiry scan that
  finds nothing due starts no job.
- **Expiry dates are the end of the chosen day in the user's own time zone.** The overnight scan
  removes aliases that have passed it.

For more detail, see [docs/architecture.md](docs/architecture.md).

## Cost

| Component | Plan |
|---|---|
| Web frontend | Azure Static Web Apps **Free** |
| API and timers | Azure Functions **Flex Consumption**, no always-ready instances |
| Data | Azure **Table Storage** and **Storage Queue**, Standard LRS |
| Exchange worker | Azure **Automation** (Basic), billed per job minute after the free allowance |
| Monitoring | Application Insights with sampling, 30-day retention and a daily ingestion cap |
| Spending alerts | Resource-group budget (A$5) with actual and forecast alerts |

No Entra ID P1/P2 or other premium licence, database server, VM, always-on compute, paid API or
trial subscription is needed. The reference workload is 25 users, 2,500 aliases and 200 operations a
month.

> **A target, not a guarantee.** The A$5 figure relies on Azure's free monthly allowances, which
> other workloads in the same subscription may already use. **Budget alerts warn; they don't cap
> spending.** Measure your own figures with `tools/Measure-MonthlyCost.ps1`. See
> [docs/cost-model.md](docs/cost-model.md).

## Administrator controls

Every control is an application setting, changed with `scripts/Set-OperationalLimits.ps1`:

- **Who can use it:** one or more Entra security groups. Guests are always refused.
- **Which domains** users can pick from.
- **Quotas:** active aliases per user, creations per user per day, and creations per month for the
  whole organisation.
- **Lifetime cap:** the latest expiry date a user may choose. With a cap set, every alias must have
  an expiry date.
- **Custom names** on or off. With custom names off, users get random suggestions only.
- **Pause creation** without affecting removal, expiry or delivery.
- **Worker job budget:** a soft limit pauses creation, and a hard limit stops new worker jobs.
  Queued work then waits instead of running up cost.

See [docs/operations.md](docs/operations.md) for every setting and the routine checks.

## Getting started

You need a pay-as-you-go Azure subscription in the same tenant as Microsoft 365, your alias domain
added to Exchange Online as an accepted domain, and an administrator who can register apps and
consent to permissions. [docs/setup.md](docs/setup.md) lists the exact roles and tools.

```powershell
Copy-Item scripts/deploy.config.sample.psd1 scripts/deploy.config.psd1   # then edit it
./scripts/0-Test-Prerequisites.ps1     # tools, sign-in, roles
./scripts/1-Register-EntraApp.ps1      # single-tenant app registration and API scope
./scripts/2-Deploy-Infrastructure.ps1  # Bicep: everything in one resource group
./scripts/3-Grant-WorkerPermissions.ps1 # Graph and Exchange permissions for the managed identities
./scripts/4-Publish-Application.ps1    # API, worker runbook and web app
./scripts/5-Test-Deployment.ps1        # end-to-end checks
```

`scripts/deploy.config.psd1` holds your tenant-specific settings and is deliberately **not**
committed. To remove everything, use `scripts/Remove-Anonymail.ps1`. Existing aliases stay on the
mailboxes until you remove them in Exchange.

## Repository layout

| Path | Contents |
|---|---|
| `infra/main.bicep` | All Azure resources, role assignments and the budget |
| `api/` | Functions app: HTTP API, daily expiry scan, dispatch sweep, unit tests, reference-data seeder |
| `worker/Invoke-AnonymailWorker.ps1` | Exchange worker runbook (Windows PowerShell 5.1, managed identity) |
| `web/` | Static frontend (Vite, TypeScript, MSAL) |
| `scripts/` | Guided setup, operational limits, verification and removal |
| `tools/Measure-MonthlyCost.ps1` | Measures actual usage and projects the monthly cost |
| `docs/` | [Setup](docs/setup.md), [architecture](docs/architecture.md), [authentication](docs/authentication.md), [cost model](docs/cost-model.md), [operations](docs/operations.md), [acceptance checklist](docs/acceptance.md) |

## Local development

```powershell
cd api; npm install; npm test            # unit tests
Copy-Item local.settings.sample.json local.settings.json
npx azurite --silent &                   # local Table/Queue emulator
npm start                                # Functions host on :7071 (WORKER_DISPATCH_ENABLED=false)
cd ../web; npm install; npm run dev      # http://localhost:5173 (put a config.json in web/public)
```

## Licence

[MIT](LICENSE)

*iCloud and Hide My Email are trademarks of Apple Inc. Anonymail is an independent project and is
not affiliated with Apple.*
