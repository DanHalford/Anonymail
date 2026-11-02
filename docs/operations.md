# Operations

## Settings (Function App application settings)

| Setting | Default | Effect |
|---|---|---|
| `CREATION_ENABLED` | `true` | `false` pauses new aliases. Removal, expiry and delivery continue. |
| `MAX_ACTIVE_ALIASES_PER_USER` | 100 | Counts aliases in Pending, Active, Removing or RemoveFailed |
| `MAX_CREATIONS_PER_USER_PER_DAY` | 10 | |
| `MAX_CREATIONS_PER_MONTH` | 300 | Organisation-wide |
| `MAX_ALIAS_LIFETIME_DAYS` | 0 | Latest expiry date a user may pick, in days from today. 0 allows "never expires". With a value set, an expiry date is required and defaults to the latest allowed. |
| `ALLOW_CUSTOM_LOCAL_PART` | `true` | `false` allows only random, uniqueness-checked suggestions |
| `RESERVED_LOCAL_PARTS` | — | Comma-separated, added to the built-in list (postmaster, abuse, …) |
| `WORKER_JOBS_SOFT_LIMIT_PER_MONTH` | 200 | At this count, creation pauses until next month |
| `WORKER_JOBS_HARD_LIMIT_PER_MONTH` | 250 | At this count, no more Automation jobs start. Operations stay queued. |
| `WORKER_MAX_RUNTIME_MINUTES` | 5 | Per-job cap |
| `MAX_OPERATION_ATTEMPTS` | 3 | Attempts before an operation is marked Failed |
| `MAILBOX_CACHE_TTL_HOURS` | 24 | How long an eligibility result is reused before Graph is checked again |
| `AUDIT_RETENTION_DAYS` | 365 | Monthly audit partitions older than this are pruned |
| `EXPIRY_SCHEDULE` / `SWEEP_SCHEDULE` | daily / 30 min | NCRONTAB, UTC |

Change these with `scripts/Set-OperationalLimits.ps1`, or in the portal. Also update
`deploy.config.psd1`, so a later infrastructure deployment doesn't revert them.

## Routine checks

- **Cost Management → Budgets**: the A$5 alerts. **Alerts don't cap spending.**
- **Automation → Jobs**: one short job per burst of activity. Job output reports how many
  operations were received, succeeded, failed and are retrying.
- **Failed operations**: query the `operations` table with `status eq 'Failed'`, or the `audit`
  table with `outcome eq 'failed'`.

## Common situations

| Situation | Action |
|---|---|
| An alias is stuck in `RemoveFailed` | Remove it in Exchange (`Set-Mailbox <oid> -EmailAddresses @{Remove='smtp:addr'}`), then ask the user to press Remove again. The worker treats an already-absent address as success. |
| The hard job limit is reached mid-month | Find the cause in the `audit` table (`worker.run` rows). Raise the limit only after checking cost. Queued operations run once jobs can start. |
| A user leaves | Exchange removes their proxy addresses with the mailbox. The alias rows and reservations remain, so the addresses aren't reused. |
| Emergency stop | `Set-OperationalLimits.ps1 -CreationEnabled $false -WorkerJobsHardLimitPerMonth 0`. Delivery to existing aliases continues. |
