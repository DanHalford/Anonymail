# Anonymail

### Disposable email aliases for Microsoft 365, on your own domain, for about the price of a coffee a month.

Every newsletter, webshop, competition and SaaS trial wants an email address. Hand over your real
one and it ends up on marketing lists and in data breaches, and it gets sold on.

**Anonymail gives everyone in your Microsoft 365 organisation a one-click way to hand out a
different address every time.** For example:

> `quiet-otter-07@alias.contoso.com` → lands in *your* Exchange Online inbox, sorted into the folder you chose.

When an address starts attracting spam, remove it and the spam stops. You also know exactly
which company leaked it, because that alias was the only place it was used.

Anonymail runs entirely in **your own** Azure subscription and Microsoft 365 tenant. There's no
third-party relay, no per-user licence, and no mail leaves Microsoft 365. For a small organisation
it targets **under A$5 a month**.

---

## ✨ Highlights

- **🎲 One-click random addresses.** The form greets you with a readable random address such as
  `brave-otter-42@…`, already checked against every address in your organisation. Don't like it?
  Hit **New suggestion**. Prefer your own name? Administrators can allow that too.
- **📂 Mail sorted automatically.** Choose a folder when you create an alias, and Anonymail sets up
  an Outlook rule (`Anonymail - Move to Shopping`) so that alias's mail goes straight there. Aliases
  for the same folder share one rule, so you stay well inside Exchange's rule limits.
- **⏳ Self-destructing addresses.** Pick an expiry date and the alias removes itself overnight.
  Perfect for that one-off competition entry.
- **📬 Native delivery, no forwarding.** An alias is a real address on your mailbox, so Exchange
  Online Protection, retention, eDiscovery and compliance all work exactly as they do today.
- **🛟 Nothing to break.** Existing aliases are ordinary mailbox addresses. If Anonymail is down,
  paused or uninstalled, mail still arrives.
- **🔐 Sign in the way you already do.** It uses your existing Entra ID tenant, with passkeys and
  MFA supported. Guests are always refused.
- **🧑‍💼 Built for administrators.** You control who can use it (by Entra group), which domains they
  can use, quotas, maximum lifetimes, and a pause switch, and every create, remove and expiry is
  audited.
- **💸 Scales to zero.** Nothing runs when nobody is using it. No VMs, no database servers, no
  premium licences.

## 👀 What users see

1. Sign in with their normal work account.
2. The form already shows a fresh, guaranteed-free random address.
3. Optionally add a **note** ("Qantas competition"), an **expiry date**, and a **folder** to deliver to.
4. Press **Create alias**. Within a few minutes the address is live.
5. Their aliases are listed with status, note, folder and expiry. **Remove** retires one for good.
   Removed addresses are never given to anyone else.

## 🍏 "So it's Hide My Email for work?"

Pretty much, but built on the opposite model:

- **iCloud Hide My Email** is a *forwarding relay* run by Apple, on Apple's domain.
- **Anonymail** adds the alias *to your own mailbox* in Exchange, on a domain your organisation owns.

| | iCloud Hide My Email | Anonymail |
|---|---|---|
| **Who it's for** | Individuals with an Apple account | Everyone in one Microsoft 365 organisation |
| **Cost** | Part of a paid iCloud+ subscription, per person | Azure pay-as-you-go, targeting < A$5/month for the **whole organisation** |
| **Address domain** | `@icloud.com`, shared by millions | Your organisation's own domain (ideally a dedicated subdomain) |
| **What the address reveals** | Nothing about you | Your **organisation**, through the domain, but not your name |
| **How mail arrives** | Apple receives it and forwards it | Delivered natively by Exchange Online. No extra hop. |
| **Who handles your mail** | Apple, then your mail provider | Only Microsoft 365 |
| **Spam filtering** | Apple's, then your provider's | Exchange Online Protection, with your existing policies |
| **If the service is down** | Forwarding depends on Apple's relay | **Existing aliases keep working**. Delivery never depends on Anonymail. |
| **Auto-sort into a folder** | — | **Yes**: one managed Outlook rule per folder |
| **Expiry dates** | No | **Yes**: the alias removes itself automatically |
| **Address reuse** | — | Never: a removed address is never reissued |
| **Replying from the alias** | Supported through the relay | Optional: enable Exchange's *send from alias* (`Set-OrganizationConfig -SendFromAliasEnabled $true`) |
| **Hidden from colleagues** | — (personal account) | **No**: aliases appear on your directory entry |
| **Where you create them** | iCloud settings, Safari and Mail autofill | The Anonymail web page |
| **Administration and audit** | None, it's personal | Group-based eligibility, quotas, pause switch, full audit log |
| **Data location** | Apple | Your tenant and your Azure subscription, in a region you choose |

> **Honest disclaimer: it's not an anonymity tool.** The domain identifies your organisation, and
> your organisation can always see which alias belongs to whom. What Anonymail hides is *your name
> and primary address* from the sites you hand an alias to, and it shows you which site leaked
> your address.

## ⚙️ How it works

```
Browser ──MSAL sign-in (Entra ID, passkeys supported)──► Static Web App (Free tier)
   │ bearer token
   ▼
Functions API (Flex Consumption, scales to zero) ──► Table Storage
   │  1. uniqueness check (Anonymail + Microsoft Graph)  aliases, reservations, quotas,
   │  2. record + enqueue                                expiry index, rules, audit log
   │  3. start worker only if idle                              ▲
   ▼                                                            │ status
Storage Queue ──► Azure Automation runbook (one short job per burst of activity)
                     ├─► Exchange Online: Set-Mailbox -EmailAddresses @{Add / Remove}
                     └─► Exchange Online: one "Anonymail - Move to …" inbox rule per folder
```

- **An alias is a secondary SMTP address** on the owner's mailbox. Exchange treats it like any other
  address the person has.
- **Uniqueness is checked before an address is offered, again at creation, and once more in
  Exchange.** The checks cover users (mail, sign-in name and every proxy address), groups and
  contacts.
- **Folder rules are kept in sync, not piled up.** Each folder has one rule listing all of its live
  aliases. The rule is updated as aliases come and go, and deleted with the last one. If a user
  deletes the rule themselves, Anonymail leaves it deleted.
- **Nothing runs when there's nothing to do.** The API scales to zero, and the Exchange worker starts
  only when work is queued, processes it in batches, and stops.

The full design is in [docs/architecture.md](docs/architecture.md).

## 💰 What it costs

| Component | Plan |
|---|---|
| Web frontend | Azure Static Web Apps **Free** |
| API and timers | Azure Functions **Flex Consumption**, no always-ready instances |
| Data | Azure **Table Storage** and **Storage Queue**, Standard LRS |
| Exchange worker | Azure **Automation** (Basic), billed per job minute after the free allowance |
| Monitoring | Application Insights with sampling, 30-day retention and a daily ingestion cap |
| Spending alerts | Resource-group budget (A$5) with actual and forecast alerts |

No Entra ID P1/P2 or other premium licence, database server, VM, always-on compute, paid API or
trial subscription is needed. The reference workload is 25 users, 2,500 aliases and 200 operations
a month.

> **A target, not a guarantee.** The A$5 figure relies on Azure's free monthly allowances, which
> other workloads in the same subscription may already use. **Budget alerts warn; they don't cap
> spending.** Measure your own numbers with `tools/Measure-MonthlyCost.ps1`, and see
> [docs/cost-model.md](docs/cost-model.md).

## 🧑‍💼 Administrator controls

Every control is an application setting. Quotas, limits and the pause switch can be changed on a
running deployment with `scripts/Set-OperationalLimits.ps1`:

- **Who can use it:** one or more Entra security groups. Guests are always refused.
- **Which domains** users can pick from.
- **Quotas:** active aliases per user, creations per user per day, and creations per month for the
  whole organisation.
- **Lifetime cap:** the latest expiry date a user may choose.
- **Custom names** on or off (`ALLOW_CUSTOM_LOCAL_PART`), and **folder rules** on or off
  (`ALLOW_FOLDER_RULES`).
- **Pause creation** without affecting removal, expiry or delivery.
- **Worker job budget:** a soft limit pauses creation, and a hard limit stops new worker jobs, so
  queued work waits instead of running up cost.

See [docs/operations.md](docs/operations.md) for every setting and the routine checks.

## 🚀 Get it running in an afternoon

You'll need:
- a pay-as-you-go Azure subscription in the same tenant as Microsoft 365;
- your alias domain added to Exchange Online as an accepted domain;
- an administrator who can register apps and consent to permissions.

[docs/setup.md](docs/setup.md) lists the exact roles and tools. Then:

```powershell
Copy-Item scripts/deploy.config.sample.psd1 scripts/deploy.config.psd1   # then edit it
./scripts/0-Test-Prerequisites.ps1      # tools, sign-in, roles
./scripts/1-Register-EntraApp.ps1       # single-tenant app registration and API scope
./scripts/2-Deploy-Infrastructure.ps1   # Bicep: everything in one resource group
./scripts/3-Grant-WorkerPermissions.ps1 # Graph and Exchange permissions for the managed identities
./scripts/4-Publish-Application.ps1     # API, worker runbook and web app
./scripts/5-Test-Deployment.ps1         # end-to-end checks
```

The scripts are idempotent, so re-run them after any change. `scripts/deploy.config.psd1` holds
your tenant-specific settings and is deliberately **not** committed. Changed your mind?
`scripts/Remove-Anonymail.ps1` removes everything. Add `-RemoveAliasesFromMailboxes` to strip the
aliases and folder rules from mailboxes too.

## 🗂️ Repository layout

| Path | Contents |
|---|---|
| `infra/main.bicep` | All Azure resources, role assignments and the budget |
| `api/` | Functions app: HTTP API, daily expiry scan, dispatch sweep, unit tests, reference-data seeder |
| `worker/Invoke-AnonymailWorker.ps1` | Exchange worker runbook (Windows PowerShell 5.1, managed identity) |
| `web/` | Static frontend (Vite, TypeScript, MSAL) |
| `scripts/` | Guided setup, operational limits, verification and removal |
| `tools/Measure-MonthlyCost.ps1` | Measures actual usage and projects the monthly cost |
| `docs/` | [Setup](docs/setup.md), [architecture](docs/architecture.md), [authentication](docs/authentication.md), [cost model](docs/cost-model.md), [operations](docs/operations.md), [acceptance checklist](docs/acceptance.md) |

## 🛠️ Local development

```powershell
cd api; npm install; npm test            # unit tests
Copy-Item local.settings.sample.json local.settings.json
npx azurite --silent &                   # local Table/Queue emulator
npm start                                # Functions host on :7071 (WORKER_DISPATCH_ENABLED=false)
cd ../web; npm install; npm run dev      # http://localhost:5173 (put a config.json in web/public)
```

## 🤝 Contributing

Issues and pull requests are welcome. If you deploy Anonymail in your organisation, I'd love to hear
how it goes, especially your real-world monthly cost.

## 📄 Licence

[MIT](LICENSE). Use it, fork it, ship it.

*iCloud and Hide My Email are trademarks of Apple Inc. Anonymail is an independent project and is
not affiliated with or endorsed by Apple.*
