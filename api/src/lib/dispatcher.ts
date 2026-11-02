import { randomUUID } from 'node:crypto';
import { AppConfig } from './config';
import { counters, readCount, tryIncrement } from './quota';
import { T, azureCredential, getEntityOrUndefined, isStatus, opsQueue, table } from './storage';

export type DispatchResult = 'started' | 'already-running' | 'no-work' | 'limit-reached' | 'disabled' | 'lost-race';

interface WorkerLock {
  status: 'Idle' | 'Starting' | 'Running';
  jobId?: string;
  updatedAt: string;
  reason?: string;
}

const LOCK_PK = 'worker';
const LOCK_RK = 'lock';

export function lockIsActive(lock: WorkerLock | undefined, ttlMinutes: number, now = Date.now()): boolean {
  if (!lock || lock.status === 'Idle') return false;
  return now - Date.parse(lock.updatedAt) < ttlMinutes * 60_000;
}

/** True when there is at least one *visible* message (peek ignores messages waiting for retry). */
export async function hasPendingWork(): Promise<boolean> {
  const q = await opsQueue();
  const peek = await q.peekMessages({ numberOfMessages: 1 });
  return peek.peekedMessageItems.length > 0;
}

/**
 * Ensures at most ONE Exchange worker job is running. Starts a job only when work is pending,
 * no live worker holds the lock, and the monthly hard job limit has not been reached.
 * The worker drains the queue in batches (one Exchange connection per job), so callers
 * can invoke this freely after enqueuing.
 */
export async function ensureWorker(cfg: AppConfig, reason: string): Promise<DispatchResult> {
  if (!cfg.workerDispatchEnabled) return 'disabled';
  if (!(await hasPendingWork())) return 'no-work';

  const state = await table(T.state);
  const lock = await getEntityOrUndefined<WorkerLock>(state, LOCK_PK, LOCK_RK);
  if (lockIsActive(lock, cfg.workerLockTtlMinutes)) return 'already-running';

  const jobs = counters.workerJobs();
  if ((await readCount(jobs.pk, jobs.rk)) >= cfg.workerJobsHardLimitPerMonth) return 'limit-reached';

  // Take the lock with optimistic concurrency so concurrent callers start only one job.
  const jobId = randomUUID();
  const next: WorkerLock = { status: 'Starting', jobId, updatedAt: new Date().toISOString(), reason };
  try {
    if (lock) await state.updateEntity({ partitionKey: LOCK_PK, rowKey: LOCK_RK, ...next }, 'Replace', { etag: lock.etag });
    else await state.createEntity({ partitionKey: LOCK_PK, rowKey: LOCK_RK, ...next });
  } catch (err) {
    if (isStatus(err, 409) || isStatus(err, 412)) return 'lost-race';
    throw err;
  }

  if (!(await tryIncrement(jobs.pk, jobs.rk, cfg.workerJobsHardLimitPerMonth))) {
    await releaseLock(jobId);
    return 'limit-reached';
  }

  try {
    await startRunbookJob(cfg, jobId);
    return 'started';
  } catch (err) {
    await releaseLock(jobId);
    throw err;
  }
}

async function releaseLock(jobId: string): Promise<void> {
  const state = await table(T.state);
  const lock = await getEntityOrUndefined<WorkerLock>(state, LOCK_PK, LOCK_RK);
  if (lock?.jobId !== jobId) return;
  await state.updateEntity(
    { partitionKey: LOCK_PK, rowKey: LOCK_RK, status: 'Idle', updatedAt: new Date().toISOString() },
    'Merge', { etag: lock.etag },
  ).catch(() => undefined);
}

async function startRunbookJob(cfg: AppConfig, jobId: string): Promise<void> {
  const token = await azureCredential().getToken('https://management.azure.com/.default');
  const url = `https://management.azure.com${cfg.automationAccountId}/jobs/${jobId}?api-version=2023-11-01`;
  const res = await fetch(url, {
    method: 'PUT',
    headers: { Authorization: `Bearer ${token.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      properties: {
        runbook: { name: cfg.automationRunbookName },
        parameters: {
          StorageAccountName: cfg.storageAccountName ?? '',
          Organization: cfg.exchangeOrganization,
          QueueName: cfg.queueName,
          LockJobId: jobId,
          MaxRuntimeMinutes: String(cfg.workerMaxRuntimeMinutes),
          MaxAttempts: String(cfg.maxOperationAttempts),
        },
      },
    }),
  });
  if (!res.ok) throw new Error(`Starting Automation job failed: ${res.status} ${await res.text()}`);
}

/** Creation is suspended once the soft job limit is reached so removal/expiry keep the remaining headroom. */
export async function creationSuspendedByJobBudget(cfg: AppConfig): Promise<boolean> {
  const jobs = counters.workerJobs();
  return (await readCount(jobs.pk, jobs.rk)) >= cfg.workerJobsSoftLimitPerMonth;
}
