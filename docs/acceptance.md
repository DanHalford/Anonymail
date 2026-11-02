# Acceptance checklist (v1.3)

Record the date, the tester and the evidence (screenshot, command output or a link) for each item.

## Licensing and deployment baseline

| # | Requirement | How to verify | Result |
|---|---|---|---|
| A1 | Deploys into a standard pay-as-you-go subscription linked to the M365 tenant | `0-Test-Prerequisites.ps1` output | |
| A2 | No Power Apps or Power Automate Premium | No Power Platform components exist in the solution | |
| A3 | No Entra ID P1/P2 | Run steps 1–5 in a tenant **without** P1/P2 SKUs (check *Entra → Licenses*). No Conditional Access, no group-based app assignment. | |
| A4 | No paid database server, VM or always-on compute | `5-Test-Deployment.ps1`: "No database server or VM", "No always-ready instances" | |
| A5 | No paid third-party API or AI service | Code review: outbound calls go only to Microsoft Graph, ARM, Storage and Exchange Online | |
| A6 | Only generally available services; no dependency on the developer | Resource list; all identities and credentials belong to the tenant | |
| A7 | All resources in one resource group | `az resource list -g <rg>` | |

## Authentication

| # | Requirement | How to verify | Result |
|---|---|---|---|
| B1 | Users authenticate through Entra ID | Sign in at the SWA URL; the redirect goes to `login.microsoftonline.com/<tenant>` | |
| B2 | Passkey sign-in works in the baseline (no P1) | With the Passkey (FIDO2) method enabled, sign in using a passkey only | |
| B3 | "Supported" is distinguished from "required" | [authentication.md](authentication.md); without CA, password sign-in still works | |
| B4 | Tenant membership enforced in the API | A token from another tenant gets 403 `wrong_tenant` (unit test `token claims`). A guest gets 403 `not_eligible (guest_not_allowed)`. | |
| B5 | Eligibility enforced | A member outside `ELIGIBLE_GROUP_IDS` gets 403 `not_eligible` | |
| B6 | Mailbox ownership enforced | User A can't list or remove user B's alias (rows are keyed by `oid`; returns 404). The worker rejects a mismatched `ExternalDirectoryObjectId`. | |

## Runtime efficiency

| # | Requirement | How to verify | Result |
|---|---|---|---|
| C1 | An empty expiry scan starts no Automation job | With no expiring aliases, the next morning *Automation → Jobs* shows no job at about 17:00 UTC | |
| C2 | Jobs start only when work is pending | Idle for 24 h; no jobs appear | |
| C3 | Compatible operations are batched | Create 5 aliases quickly; one job processes all 5 (job output: `5 received`) | |
| C4 | Bounded retries and concurrency | Force a failure (for example, remove the Exchange role); the op reaches `Failed` after 3 attempts. The `state/worker/lock` row never shows two jobs at once. | |
| C5 | Polling only while active | Browser devtools: no requests while the tab is hidden or nothing is pending | |

## Cost controls

| # | Requirement | How to verify | Result |
|---|---|---|---|
| D1 | Cost alerts configured; documented as non-capping | Budget visible in Cost Management; README and setup docs say alerts don't cap spend | |
| D2 | Creation quotas and concurrency limits are configurable | `Set-OperationalLimits.ps1` changes take effect | |
| D3 | Removal and expiry continue while creation is restricted | `-CreationEnabled $false`: create returns 503, remove succeeds, expiry still runs | |
| D4 | Cost estimate published with measured workload | `docs/cost-model.md` updated from `Measure-MonthlyCost.ps1` output | |
| D5 | Forecast ≤ A$5, or cause documented and workload stated | Release notes | |

## Delivery resilience

| # | Requirement | How to verify | Result |
|---|---|---|---|
| E1 | App downtime doesn't interrupt delivery | `az functionapp stop` and disable the runbook; send external mail to an existing alias; it is delivered | |
| E2 | Suspended creation doesn't interrupt delivery | `-CreationEnabled $false`; send mail to an existing alias; it is delivered | |
