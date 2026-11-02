import { app } from '@azure/functions';
import { CreateRequest, createAlias, getOperation, listAliases, requestRemoval, suggestAddress } from '../lib/aliases';
import { authenticate } from '../lib/auth';
import { config } from '../lib/config';
import { creationSuspendedByJobBudget, ensureWorker } from '../lib/dispatcher';
import { requireEligible, resolveEligibility } from '../lib/eligibility';
import { HttpError, handle, json, readJson } from '../lib/http';
import { counters, readCount } from '../lib/quota';

// Dispatch failures must not fail the user request: the operation is durably queued and the
// sweep timer will start a worker later.
async function dispatch(reason: string, log: (m: string) => void) {
  try {
    await ensureWorker(config(), reason);
  } catch (err) {
    log(`Worker dispatch deferred: ${(err as Error).message}`);
  }
}

app.http('me', {
  methods: ['GET'],
  route: 'me',
  authLevel: 'anonymous', // authentication is enforced in code (Entra JWT), not by function keys
  handler: handle(async (req) => {
    const cfg = config();
    const caller = await authenticate(req, cfg);
    const rec = await resolveEligibility(caller, cfg);
    const aliases = rec.eligible ? await listAliases(caller.userId) : [];
    const daily = counters.userDaily(caller.userId);
    const suspended = !cfg.creationEnabled || (await creationSuspendedByJobBudget(cfg));
    return json(200, {
      userId: caller.userId,
      name: caller.name,
      eligible: rec.eligible,
      reason: rec.reason,
      domains: cfg.aliasDomains,
      allowCustomLocalPart: cfg.allowCustomLocalPart,
      maxAliasLifetimeDays: cfg.maxAliasLifetimeDays,
      creationEnabled: !suspended,
      quotas: {
        active: aliases.filter((a) => a.status !== 'Removed' && a.status !== 'Failed').length,
        activeMax: cfg.maxActiveAliasesPerUser,
        today: await readCount(daily.pk, daily.rk),
        todayMax: cfg.maxCreationsPerUserPerDay,
      },
    });
  }),
});

app.http('aliases-list', {
  methods: ['GET'],
  route: 'aliases',
  authLevel: 'anonymous',
  handler: handle(async (req) => {
    const cfg = config();
    const caller = await authenticate(req, cfg);
    await requireEligible(caller, cfg);
    return json(200, { aliases: await listAliases(caller.userId) });
  }),
});

app.http('aliases-suggest', {
  methods: ['GET'],
  route: 'aliases/suggestion',
  authLevel: 'anonymous',
  handler: handle(async (req) => {
    const cfg = config();
    const caller = await authenticate(req, cfg);
    await requireEligible(caller, cfg);
    return json(200, await suggestAddress(req.query.get('domain') ?? undefined, cfg));
  }),
});

app.http('aliases-create', {
  methods: ['POST'],
  route: 'aliases',
  authLevel: 'anonymous',
  handler: handle(async (req, ctx) => {
    const cfg = config();
    const caller = await authenticate(req, cfg);
    await requireEligible(caller, cfg);
    const result = await createAlias(caller, await readJson<CreateRequest>(req), cfg);
    await dispatch('create', (m) => ctx.warn(m));
    return json(202, result);
  }),
});

app.http('aliases-delete', {
  methods: ['DELETE'],
  route: 'aliases/{address}',
  authLevel: 'anonymous',
  handler: handle(async (req, ctx) => {
    const cfg = config();
    const caller = await authenticate(req, cfg);
    // Removal is allowed even if the user has since become ineligible: they can always clean up.
    const result = await requestRemoval(caller.userId, decodeURIComponent(req.params.address), 'user', caller.userId);
    if (!result) throw new HttpError(404, 'not_found', 'Alias not found.');
    await dispatch('remove', (m) => ctx.warn(m));
    return json(202, result);
  }),
});

app.http('operations-get', {
  methods: ['GET'],
  route: 'operations/{id}',
  authLevel: 'anonymous',
  handler: handle(async (req) => {
    const caller = await authenticate(req, config());
    const op = await getOperation(caller.userId, req.params.id);
    if (!op) throw new HttpError(404, 'not_found', 'Operation not found.');
    return json(200, op);
  }),
});

app.http('health', {
  methods: ['GET'],
  route: 'health',
  authLevel: 'anonymous',
  handler: async () => json(200, { status: 'ok' }),
});
