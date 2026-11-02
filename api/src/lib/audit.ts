import { randomUUID } from 'node:crypto';
import { T, table } from './storage';

/** Inverted ticks so the newest audit rows sort first within a month partition. */
function invertedTicks(d: Date): string {
  return (8_640_000_000_000_000 - d.getTime()).toString().padStart(16, '0');
}

export interface AuditEntry {
  actor: string; // user object id, 'system:expiry', 'system:worker', ...
  action: string; // alias.create.requested, alias.remove.requested, ...
  target?: string;
  outcome: 'accepted' | 'rejected' | 'succeeded' | 'failed';
  detail?: string;
}

/**
 * Audit records go to Table Storage (cents per GB-month) rather than a log analytics workspace,
 * so retaining them does not depend on continuous telemetry ingestion.
 */
export async function audit(entry: AuditEntry, now = new Date()): Promise<void> {
  const client = await table(T.audit);
  await client.createEntity({
    partitionKey: now.toISOString().slice(0, 7).replace('-', ''),
    rowKey: `${invertedTicks(now)}-${randomUUID().slice(0, 8)}`,
    at: now.toISOString(),
    ...entry,
    detail: entry.detail?.slice(0, 1024),
  });
}

/** Deletes whole month partitions older than the retention window. */
export async function pruneAudit(retentionDays: number, now = new Date()): Promise<number> {
  if (retentionDays <= 0) return 0;
  const cutoff = new Date(now.getTime() - retentionDays * 86_400_000).toISOString().slice(0, 7).replace('-', '');
  const client = await table(T.audit);
  let deleted = 0;
  for await (const e of client.listEntities({ queryOptions: { filter: `PartitionKey lt '${cutoff}'`, select: ['PartitionKey', 'RowKey'] } })) {
    await client.deleteEntity(e.partitionKey!, e.rowKey!);
    deleted++;
  }
  return deleted;
}
