# Architecture

## Request flow

1. **Sign-in.** The SPA uses MSAL with the authorization code + PKCE flow against
   `login.microsoftonline.com/{tenantId}`. It is a single-tenant app. Entra's own sign-in page
   offers every method the tenant allows, including passkeys.
2. **API call.** The SPA calls the Function App directly with a v2 access token for
   `api://{appId}/Aliases.Manage`. CORS allows only the Static Web App hostname. SWA Free can't
   link a separate backend, so the API is a standalone Function App.
3. **The API enforces** these checks on every request (`api/src/lib/auth.ts`, `eligibility.ts`):
   - the token signature, the issuer (this tenant only), the audience and the scope, and that it is a delegated user token, not an app-only one;
   - **tenant membership**: the token's `tid` must match the tenant; Graph must report `userType = Member` and `accountEnabled`;
   - **user eligibility**: membership of `ELIGIBLE_GROUP_IDS`, read from the token's group claims or from Graph `checkMemberGroups` when the claim overflows;
   - **mailbox ownership**: every alias row is keyed by the caller's immutable object ID (`oid`), so a caller can only read or change their own aliases. The worker then checks again that the target mailbox is a `UserMailbox` whose `ExternalDirectoryObjectId` equals that `oid`.
4. **Suggest.** The form opens with a random address from `GET /api/aliases/suggestion`.
   Before it's offered, the address is checked against `aliasindex` and the tenant directory:
   users (mail, UPN, proxy addresses), groups and contacts, in one Graph `$batch` call. The user
   can ask for a new suggestion as often as they like, or type their own name if custom names are
   allowed. Accepted suggestions are allowed even when `ALLOW_CUSTOM_LOCAL_PART=false`.
5. **Create.** `POST /api/aliases` takes the address and an optional drop-dead `expiresAt`: the end
   of the chosen day in the user's time zone. The API checks uniqueness **first**. It reserves the
   address in `aliasindex` (an insert that fails on conflict, so two requests can't both win),
   then re-checks the directory and releases the reservation on a clash. Addresses found in the
   directory are kept as tombstones so they're never suggested again. Only then does it check
   quotas, write the `aliases`, `operations` and `expiry` rows, enqueue one message, write an
   audit row and call `ensureWorker()`. If the directory can't be checked, creation fails with 503
   instead of guessing. The worker's `Get-Recipient` check remains the final check, and also
   covers Exchange-only recipients.
6. **Dispatch** (`api/src/lib/dispatcher.ts`). A job starts only when *all* of these hold:
   - the queue has a visible message;
   - no live worker holds the lock (an ETag-guarded row in `state`);
   - the monthly hard job limit hasn't been reached.

   Only one worker runs at a time.
7. **Worker** (`worker/Invoke-AnonymailWorker.ps1`). The runbook takes batches of up to 32
   messages. It connects to Exchange Online once, and only after it has actually received a
   message. It groups operations by mailbox and applies each group with a single
   `Set-Mailbox -EmailAddresses @{Add=…; Remove=…}`. Then it updates the rows and deletes the
   messages. Before exiting it releases the lock and checks the queue once more. Each job stops
   after `MaxRuntimeMinutes`.
8. **Status.** The SPA polls the alias list only while something is pending *and* the tab is
   visible. It backs off from 3 s to 30 s and stops after 10 minutes (`web/src/poll.ts`).

## Scheduled work

| Function | Schedule | Behaviour |
|---|---|---|
| `expiry-scan` | daily at 17:00 UTC (`EXPIRY_SCHEDULE`) | Reads the `expiry` index for buckets on or before today. **If nothing has expired, it doesn't touch the queue or Automation, so no job starts.** It also prunes audit partitions on the 1st of each month. |
| `dispatch-sweep` | every 30 min (`SWEEP_SCHEDULE`) | Peeks the queue (one transaction) and calls `ensureWorker()`. This is the safety net when a dispatch failed or a message is retrying. |

Neither function scans every mailbox in the tenant. Mailboxes are looked up on demand by object ID.
Eligibility results are cached in `mailboxes` (24 h for eligible users, 1 h for ineligible users)
and re-checked when the cache expires. The worker refreshes `exchangeVerifiedAt` each time it
touches a mailbox.

## Data model (Table Storage)

| Table | PartitionKey / RowKey | Purpose |
|---|---|---|
| `aliases` | user oid / address | Alias state: `Pending`, `Active`, `Removing`, `Removed`, `Failed` or `RemoveFailed` |
| `aliasindex` | domain / local part | Keeps each address unique across the organisation. **Never released after activation**, so an address can't be reissued to someone else. |
| `expiry` | `yyyymmdd` / address | Cheap daily lookup for expiry. The row is deleted once removal is queued. |
| `operations` | user oid / op id | Status of each operation the SPA can poll |
| `mailboxes` | `mbx` / user oid | Cached mapping of eligibility and mailbox |
| `usage` | `user:{oid}` or `global` / counter | Quotas and the monthly count of worker jobs (ETag counters) |
| `state` | `worker` / `lock` | Single-worker lock and heartbeat |
| `audit` | `yyyymm` / inverted ticks | Audit trail (`AUDIT_RETENTION_DAYS`, default 365) |

## Bounded behaviour

| Concern | Bound |
|---|---|
| Worker concurrency | 1 (lock) |
| Worker runtime | `WORKER_MAX_RUNTIME_MINUTES` per job (default 5) |
| Worker jobs per month | Soft limit 200 (creation pauses) and hard limit 250 (no jobs start) |
| Retries | `MAX_OPERATION_ATTEMPTS` (default 3). The queue's visibility timeout spaces retries 5 minutes apart. |
| Function scale-out | `functionMaxInstances` (default 2) |
| Creation | Per-user active and daily limits, an organisation monthly limit, and the `CREATION_ENABLED` switch |
| Logs | Host log level Warning, sampling on, Live Metrics off, 0.025 GB/day workspace cap (Log Analytics requires more than 0.023), 30-day retention. Automation progress and verbose streams are off. |

## Failure modes

- **API or Functions down.** Existing aliases keep delivering, because Exchange owns them. New
  requests fail. Queued operations stay queued; queue message TTL is unlimited.
- **Automation unavailable, or job limit reached.** Operations stay `Queued` or `Retrying`. Expiry
  rows have already been turned into queued removals, so they run once jobs can start again.
  Aliases are removed late, but never lost.
- **Creation suspended**, either by `CREATION_ENABLED=false` or by the soft job limit. Removal and
  expiry are deliberately exempt.

## Known limitations of the baseline

- An alias is a proxy address on the user's mailbox. Internal users can see it in the GAL on the
  user's object. It hides the user's address from external senders, not from colleagues.
- Replies are sent from the user's primary address unless the tenant enables
  [sending from aliases](https://learn.microsoft.com/exchange/recipients-in-exchange-online/manage-user-mailboxes/add-or-remove-email-addresses).
  Sending from aliases isn't configured by this scaffold.
- Exchange Online caps proxy addresses per recipient. The default `MAX_ACTIVE_ALIASES_PER_USER` of
  100 stays well under that cap.
