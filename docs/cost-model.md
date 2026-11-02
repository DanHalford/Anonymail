# Cost model and validation

**Target:** no more than **A$5 per month** of extra Azure charges for light organisational use.
This is a design and validation target, **not a guaranteed bill**. Microsoft 365 mailbox licences
and domain registration are prerequisites and aren't counted.

> **Status of the figures below: PRE-MEASUREMENT ESTIMATE.** They come from the design and from
> placeholder A$ unit rates. Before release, replace them with values measured by
> `tools/Measure-MonthlyCost.ps1` on the reference workload (see *Validation procedure*), and
> confirm current AUD rates for your region on the
> [pricing calculator](https://azure.microsoft.com/pricing/calculator/).

## Reference workload

| Item | Value |
|---|---|
| Eligible users | 25 |
| Stored alias records | 2,500 (seed with `api/scripts/seed-reference-data.ts`; Table rows only, no Exchange changes) |
| Exchange-changing operations | 200 per month, including expiry |
| Interactive use | About 9 visits per user per month, about 16 API calls per visit including status polls |
| Scheduled | `expiry-scan` 1×/day; `dispatch-sweep` every 30 min |

## Resource-by-resource estimate (reference workload)

| Resource | Tier | Driver | Est. usage / month | Free allowance | Est. A$ / month |
|---|---|---|---|---|---|
| Static Web Apps | Free | Static files | < 1 GB bandwidth | 100 GB | 0.00 |
| Functions | Flex Consumption, on demand, 512 MB, 0 always-ready | about 3.6k HTTP + 1.4k sweep + 30 expiry runs | about 5k executions, about 3k GB-s | 250k executions, 100k GB-s (per subscription) | 0.00 |
| Automation | Basic | about 150 jobs for user ops + about 20 for expiry, about 2 min each | about 340 job-minutes | **500 min per subscription (shared)** | 0.00. If other accounts have used the allowance: about 1.05 |
| Table Storage | Standard LRS | API/worker reads and writes, 2,500 rows (< 10 MB) | about 40k transactions | none | < 0.05 |
| Queue Storage | Standard LRS | Enqueue, sweep peeks, worker receive/delete | about 3k transactions | none | < 0.05 |
| Blob Storage | Standard LRS | Deployment package (about 30 MB), **Functions host leases while an instance is alive** | 10k–350k transactions (**main uncertainty**) | none | 0.10–3.00 |
| Log Analytics / App Insights | PAYG, 0.025 GB/day cap, 30-day retention | Requests and warnings, with sampling | about 20–50 MB | 5 GB/month per billing account (shared) | 0.00. With no allowance left: < 0.25 |
| Budget, role assignments, managed identities | — | — | — | — | 0.00 |
| **Total** | | | | | **≈ A$0.20–0.60 expected; ≈ A$4.50 plausible worst case** |

**Worst case** means all shared free allowances are already used by other workloads *and* a
Function instance stays warm all month. Both are possible in a busy subscription, which is why
release requires measurement.

### Upper bounds enforced by configuration

| Control | Default | Spend it bounds |
|---|---|---|
| `WORKER_JOBS_HARD_LIMIT_PER_MONTH` × `WORKER_MAX_RUNTIME_MINUTES` | 250 × 5 min | ≤ 1,250 job-minutes, so ≤ about A$3.90 even with no free minutes left. Typical jobs take about 2 min. |
| `WORKER_JOBS_SOFT_LIMIT_PER_MONTH` | 200 | New creation pauses; removal and expiry keep the remaining headroom |
| `functionMaxInstances` | 2 | Function scale-out |
| Log Analytics `dailyQuotaGb` | 0.025 (Log Analytics requires more than 0.023) | ≤ about 0.75 GB/month, so ≤ about A$3.40 with no free ingestion left |
| `MAX_CREATIONS_PER_MONTH` | 300 | Total Exchange add operations |

The hard bounds aren't designed to all stay under A$5 at once. They stop runaway spend; they don't
promise a total. The budget alert (A$5: 50 % and 100 % actual, 100 % forecast) tells you when to
lower them. **Budget alerts notify only; they do not stop or cap spending.**

## Things that can push you over the target

- **Shared allowances are already used.** Automation's 500 free minutes are per subscription.
  The Functions grant is per subscription. The 5 GB of log ingestion is per billing account.
  `Measure-MonthlyCost.ps1` adds up job minutes across every Automation account in the
  subscription.
- **Microsoft Defender for Storage** turned on at subscription level is billed per storage
  account. `0-Test-Prerequisites.ps1` warns about it.
- **A Function instance staying warm.** The host renews blob leases while an instance is alive.
  Keep `SWEEP_SCHEDULE` at 30 min or slower. Hourly is fine, because the API dispatches
  immediately and the sweep is only a safety net.
- **Much heavier use than the reference.** Batching keeps Automation minutes sub-linear, but
  thousands of creations a month will go beyond the target.

## Validation procedure (before release)

1. Deploy to the target subscription (`scripts/1`–`4`).
2. Seed the stored-record volume:
   `STORAGE_ACCOUNT_NAME=<name> npx tsx api/scripts/seed-reference-data.ts`. Your identity needs
   *Storage Table Data Contributor*.
3. Run the reference workload for at least 7 days: 25 users, about 50 Exchange operations a week
   (create/remove/expiry mix), normal UI use.
4. Run `./tools/Measure-MonthlyCost.ps1 -OutFile docs/measurements/<yyyy-mm>.json` with your
   confirmed AUD rates. It reports:
   - measured Automation minutes, for this account and for the subscription;
   - Functions executions and GB-s;
   - storage transactions for each service, and capacity;
   - log ingestion;
   - actual month-to-date cost from Cost Management;
   - a full-month projection compared with A$5.
5. **If the forecast exceeds A$5**, document the cause (the largest component) in the release
   notes. Then do one of these:
   - lower the limits;
   - change the implementation (for example, slow the sweep or reduce telemetry);
   - state explicitly which smaller workload fits the target.

   **Never move to a paid tier silently.**
6. Remove the synthetic rows: `... seed-reference-data.ts --remove`.
7. Publish this document's table with the measured values, the date and the subscription's
   allowance situation alongside the release.
