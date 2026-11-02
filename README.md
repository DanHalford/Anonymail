# Anonymail

Self-service email aliases for a Microsoft 365 organisation. Signed-in users create aliases on the
organisation's own domains. Each alias delivers to the user's existing mailbox, and the user can
remove it, or set it to expire, whenever they like.

This scaffold implements the **Deployment and cost amendment v1.3** baseline:

| Component | Implementation |
|---|---|
| Frontend | Azure Static Web Apps **Free** (`web/`, Vite + TypeScript, MSAL) on its supplied `*.azurestaticapps.net` hostname |
| Authentication | Existing Entra tenant, single-tenant app registration. Passkeys are **supported** wherever the tenant enables them ([docs/authentication.md](docs/authentication.md)) |
| API and scheduler | Azure Functions **Flex Consumption** with **no always-ready instances** (`api/`) |
| Database | Azure **Table Storage** |
| Work dispatch | Azure **Storage Queue** (`exchange-ops`) |
| Exchange worker | Azure **Automation** runbook (`worker/`), started only when work is pending |
| Storage | Standard **LRS** |
| Monitoring | Workspace-based Application Insights, sampling on, 30-day retention, daily ingestion cap |
| Cost alerts | Resource-group budget (A$5) with actual and forecast alerts. **Alerts do not cap spending.** |

No Power Platform Premium licence, Entra ID P1/P2 licence, database server, VM, always-on compute,
paid third-party API, AI service, trial credit or developer subscription is needed.

> **Cost target, not a guarantee.** The design aims for **≤ A$5/month of extra Azure charges for
> light use**. That relies on the subscription's free allowances, which other workloads may already
> be using. See [docs/cost-model.md](docs/cost-model.md) and measure with
> `tools/Measure-MonthlyCost.ps1` before release.

## How it works

```
Browser ──MSAL (Entra, passkey)──► Static Web App (Free)
   │ bearer token
   ▼
Functions API (Flex, scale-to-zero) ──► Table Storage (aliases, quotas, audit, expiry index)
   │  enqueue + ensureWorker()             ▲
   ▼                                       │ status updates
Storage Queue ──► Automation runbook (one job at a time, batched, lazy EXO connect)
                     └─► Exchange Online: Set-Mailbox -EmailAddresses @{Add/Remove}
```

Each alias is a plain secondary SMTP proxy address on the owner's mailbox. Exchange delivers it
natively, so **existing aliases keep working if the app is down, stopped, or blocked from creating
new ones**. For more detail, see [docs/architecture.md](docs/architecture.md).

## Repository layout

| Path | Contents |
|---|---|
| `infra/main.bicep` | All Azure resources in one resource group, plus role assignments and the budget |
| `api/` | Functions app: HTTP API, daily expiry scan, dispatch sweep, unit tests, reference-data seeder |
| `worker/Invoke-AnonymailWorker.ps1` | Automation runbook (Windows PowerShell 5.1, managed identity) |
| `web/` | Static frontend |
| `scripts/` | Guided setup, operational limits, verification, removal |
| `tools/Measure-MonthlyCost.ps1` | Measured cost forecast against the A$5 target |
| `docs/` | Setup guide, architecture, authentication, cost model, operations, acceptance checklist |

## Quick start (tenant administrator)

```powershell
Copy-Item scripts/deploy.config.sample.psd1 scripts/deploy.config.psd1   # then edit it
./scripts/0-Test-Prerequisites.ps1
./scripts/1-Register-EntraApp.ps1
./scripts/2-Deploy-Infrastructure.ps1
./scripts/3-Grant-WorkerPermissions.ps1
./scripts/4-Publish-Application.ps1
./scripts/5-Test-Deployment.ps1
```

For the full walkthrough, see [docs/setup.md](docs/setup.md). To remove everything, see
`scripts/Remove-Anonymail.ps1`.

## Local development

```powershell
cd api; npm install; npm test            # unit tests
Copy-Item local.settings.sample.json local.settings.json
npx azurite --silent &                   # local Table/Queue emulator
npm start                                # Functions host on :7071 (WORKER_DISPATCH_ENABLED=false)
cd ../web; npm install; npm run dev      # http://localhost:5173 (put a config.json in web/public)
```
