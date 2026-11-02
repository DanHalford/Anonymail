import { app, InvocationContext } from '@azure/functions';
import { expiryBucket } from '../lib/alias';
import { requestRemoval } from '../lib/aliases';
import { pruneAudit } from '../lib/audit';
import { config } from '../lib/config';
import { ensureWorker } from '../lib/dispatcher';
import { T, table } from '../lib/storage';

/**
 * Daily expiry check. Reads only the expiry index in Table Storage; an empty scan returns
 * without touching the queue or Automation, so it never starts an Exchange job.
 */
app.timer('expiry-scan', {
  schedule: '%EXPIRY_SCHEDULE%',
  runOnStartup: false,
  handler: async (_timer, ctx: InvocationContext) => {
    const cfg = config();
    const today = expiryBucket(new Date().toISOString());
    const expiry = await table(T.expiry);
    let queued = 0;

    for await (const e of expiry.listEntities<{ userId: string; expiresAt: string }>({
      queryOptions: { filter: `PartitionKey le '${today}'` },
    })) {
      if (Date.parse(e.expiresAt) <= Date.now()) {
        const res = await requestRemoval(e.userId, e.rowKey!, 'expiry', 'system:expiry').catch((err) => {
          ctx.warn(`Expiry of ${e.rowKey} deferred: ${(err as Error).message}`);
          return null; // keep the row; retry tomorrow
        });
        if (res === null) continue;
        if (res) queued++;
        await expiry.deleteEntity(e.partitionKey!, e.rowKey!);
      }
    }

    if (queued > 0) await ensureWorker(cfg, 'expiry');
    if (new Date().getUTCDate() === 1) await pruneAudit(cfg.auditRetentionDays);
  },
});

/**
 * Safety net: if work is visible on the queue and no worker is live (e.g. a dispatch failed,
 * or a message became visible again for retry), start one. Costs one queue peek per run.
 */
app.timer('dispatch-sweep', {
  schedule: '%SWEEP_SCHEDULE%',
  runOnStartup: false,
  handler: async (_timer, ctx) => {
    const result = await ensureWorker(config(), 'sweep');
    if (result === 'limit-reached') ctx.warn('Worker job hard limit reached for this month; operations remain queued.');
  },
});
