import { T, getEntityOrUndefined, isStatus, table } from './storage';

interface Counter { count: number }

export const monthKey = (d = new Date()) => d.toISOString().slice(0, 7).replace('-', '');
export const dayKey = (d = new Date()) => d.toISOString().slice(0, 10).replace(/-/g, '');

/**
 * Atomically increments a counter unless it has reached `limit`.
 * Uses ETag optimistic concurrency so concurrent instances cannot overshoot.
 * Returns false (and does not increment) when the limit is reached.
 */
export async function tryIncrement(pk: string, rk: string, limit: number): Promise<boolean> {
  if (limit <= 0) return false;
  const client = await table(T.usage);
  for (let attempt = 0; attempt < 8; attempt++) {
    const row = await getEntityOrUndefined<Counter>(client, pk, rk);
    try {
      if (!row) {
        await client.createEntity({ partitionKey: pk, rowKey: rk, count: 1 });
        return true;
      }
      if (row.count >= limit) return false;
      await client.updateEntity({ partitionKey: pk, rowKey: rk, count: row.count + 1 }, 'Merge', { etag: row.etag });
      return true;
    } catch (err) {
      if (isStatus(err, 409) || isStatus(err, 412)) continue; // lost the race; re-read
      throw err;
    }
  }
  throw new Error(`Counter ${pk}/${rk} is too contended`);
}

/** Best-effort decrement used to roll back a reservation. */
export async function decrement(pk: string, rk: string): Promise<void> {
  const client = await table(T.usage);
  for (let attempt = 0; attempt < 5; attempt++) {
    const row = await getEntityOrUndefined<Counter>(client, pk, rk);
    if (!row || row.count <= 0) return;
    try {
      await client.updateEntity({ partitionKey: pk, rowKey: rk, count: row.count - 1 }, 'Merge', { etag: row.etag });
      return;
    } catch (err) {
      if (!isStatus(err, 412)) throw err;
    }
  }
}

export async function readCount(pk: string, rk: string): Promise<number> {
  const row = await getEntityOrUndefined<Counter>(await table(T.usage), pk, rk);
  return row?.count ?? 0;
}

export const counters = {
  userDaily: (userId: string, d?: Date) => ({ pk: `user:${userId}`, rk: `create:${dayKey(d)}` }),
  globalMonthly: (d?: Date) => ({ pk: 'global', rk: `create:${monthKey(d)}` }),
  workerJobs: (d?: Date) => ({ pk: 'global', rk: `jobs:${monthKey(d)}` }),
};
