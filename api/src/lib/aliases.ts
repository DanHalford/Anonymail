import { randomUUID } from 'node:crypto';
import { expiryBucket, generateLocalPart, isGeneratedLocalPart, resolveExpiry, validateDomain, validateLocalPart } from './alias';
import { audit } from './audit';
import { Caller } from './auth';
import { AppConfig } from './config';
import { creationSuspendedByJobBudget } from './dispatcher';
import { addressInUseInDirectory } from './graph';
import { HttpError } from './http';
import { counters, decrement, tryIncrement } from './quota';
import { T, getEntityOrUndefined, isStatus, odata, opsQueue, table } from './storage';

export type AliasStatus = 'Pending' | 'Active' | 'Removing' | 'Removed' | 'Failed' | 'RemoveFailed';
export type OperationStatus = 'Queued' | 'Retrying' | 'Succeeded' | 'Failed';

export interface AliasRecord {
  address: string;
  domain: string;
  note?: string;
  status: AliasStatus;
  createdAt: string;
  expiresAt?: string;
  activatedAt?: string;
  removedAt?: string;
  lastOperationId?: string;
  lastError?: string;
}

/** Message placed on the exchange-ops queue and consumed by worker/Invoke-AnonymailWorker.ps1. */
export interface ExchangeOp {
  opId: string;
  userId: string;
  type: 'add' | 'remove';
  address: string;
  reason: 'user' | 'expiry' | 'admin';
  requestedAt: string;
}

const LIVE: AliasStatus[] = ['Pending', 'Active', 'Removing', 'RemoveFailed'];

export async function listAliases(userId: string): Promise<AliasRecord[]> {
  const client = await table(T.aliases);
  const out: AliasRecord[] = [];
  for await (const e of client.listEntities<AliasRecord>({ queryOptions: { filter: `PartitionKey eq ${odata(userId)}` } })) {
    out.push(strip(e));
  }
  return out.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

function strip<E extends AliasRecord>(e: E): AliasRecord {
  const { address, domain, note, status, createdAt, expiresAt, activatedAt, removedAt, lastOperationId, lastError } = e;
  return { address, domain, note, status, createdAt, expiresAt, activatedAt, removedAt, lastOperationId, lastError };
}

/** expiresAt: drop-dead instant (ISO 8601 with offset); omit for "never" (subject to MAX_ALIAS_LIFETIME_DAYS). */
export interface CreateRequest { domain?: string; localPart?: string; note?: string; expiresAt?: string }

export async function createAlias(caller: Caller, body: CreateRequest, cfg: AppConfig): Promise<{ alias: AliasRecord; operationId: string }> {
  if (!cfg.creationEnabled) throw new HttpError(503, 'creation_suspended', 'New aliases are temporarily unavailable. Existing aliases keep working.');
  if (await creationSuspendedByJobBudget(cfg)) {
    throw new HttpError(503, 'creation_suspended', 'Monthly processing budget reached; new aliases resume next month. Existing aliases keep working.');
  }

  const domain = validateDomain(body.domain ?? cfg.aliasDomains[0], cfg);
  // A local part matching the generator's pattern is a suggestion the user accepted, which is
  // allowed even when custom names are disabled.
  const requested = body.localPart?.trim().toLowerCase() || undefined;
  const custom = requested && !isGeneratedLocalPart(requested) ? requested : undefined;
  if (custom && !cfg.allowCustomLocalPart) throw new HttpError(400, 'custom_not_allowed', 'Custom alias names are disabled.');
  const note = body.note?.trim().slice(0, 200) || undefined;
  const expiresAt = resolveExpiry(body.expiresAt, cfg);

  const existing = await listAliases(caller.userId);
  if (existing.filter((a) => LIVE.includes(a.status)).length >= cfg.maxActiveAliasesPerUser) {
    throw new HttpError(429, 'alias_limit', `You can have at most ${cfg.maxActiveAliasesPerUser} active aliases.`);
  }

  // Reserve an address that is unique in both Anonymail and the tenant directory BEFORE anything
  // is queued. A requested name (custom or accepted suggestion) gets one try; a server-generated
  // one retries with fresh names.
  const index = await table(T.aliasIndex);
  const fixed = requested ? validateLocalPart(requested, cfg) : undefined;
  let localPart: string | undefined;
  for (let attempt = 0; attempt < (fixed ? 1 : 5) && !localPart; attempt++) {
    const candidate = fixed ?? generateLocalPart();
    if (await reserveUnique(domain, candidate, caller.userId)) localPart = candidate;
  }
  if (!localPart) {
    throw new HttpError(409, 'address_taken', fixed ? 'That address is already in use. Choose another or use a new suggestion.' : 'Could not find a free address. Try again.');
  }
  const address = `${localPart}@${domain}`;

  const daily = counters.userDaily(caller.userId);
  const monthly = counters.globalMonthly();
  const release = () => index.deleteEntity(domain, localPart!).catch(() => undefined);
  if (!(await tryIncrement(daily.pk, daily.rk, cfg.maxCreationsPerUserPerDay))) {
    await release();
    throw new HttpError(429, 'daily_limit', `You can create ${cfg.maxCreationsPerUserPerDay} aliases per day.`);
  }
  if (!(await tryIncrement(monthly.pk, monthly.rk, cfg.maxCreationsPerMonth))) {
    await Promise.all([release(), decrement(daily.pk, daily.rk)]);
    throw new HttpError(503, 'monthly_limit', 'The organisation has reached its monthly alias quota.');
  }

  const now = new Date().toISOString();
  const opId = randomUUID();
  const alias: AliasRecord = { address, domain, note, status: 'Pending', createdAt: now, expiresAt, lastOperationId: opId };
  await (await table(T.aliases)).createEntity({ partitionKey: caller.userId, rowKey: address, ...alias });
  if (expiresAt) {
    await (await table(T.expiry)).upsertEntity({ partitionKey: expiryBucket(expiresAt), rowKey: address, userId: caller.userId, expiresAt });
  }
  await enqueue({ opId, userId: caller.userId, type: 'add', address, reason: 'user', requestedAt: now });
  await audit({ actor: caller.userId, action: 'alias.create.requested', target: address, outcome: 'accepted' });
  return { alias, operationId: opId };
}

/** Checks the directory, so a lookup failure is surfaced rather than treated as "free". */
async function inDirectory(address: string): Promise<boolean> {
  try {
    return await addressInUseInDirectory(address);
  } catch {
    throw new HttpError(503, 'uniqueness_check_failed', 'Could not confirm the address is unique. Try again shortly.');
  }
}

/**
 * Inserts the aliasindex reservation (fails on conflict, so concurrent requests can't both win),
 * then confirms no directory object already uses the address; releases the reservation if one does.
 * Reservations are never released after activation, so an address is never re-issued to someone else.
 */
async function reserveUnique(domain: string, localPart: string, userId: string): Promise<boolean> {
  const index = await table(T.aliasIndex);
  try {
    await index.createEntity({ partitionKey: domain, rowKey: localPart, userId, reservedAt: new Date().toISOString() });
  } catch (err) {
    if (isStatus(err, 409)) return false;
    throw err;
  }
  let used: boolean;
  try {
    used = await inDirectory(`${localPart}@${domain}`);
  } catch (err) {
    await index.deleteEntity(domain, localPart).catch(() => undefined);
    throw err;
  }
  if (used) {
    // Keep a tombstone so this taken address is never suggested again.
    await index.updateEntity({ partitionKey: domain, rowKey: localPart, userId: '', inDirectory: true }, 'Replace').catch(() => undefined);
    return false;
  }
  return true;
}

/**
 * Proposes a random address that is currently free in Anonymail and the directory. Nothing is
 * reserved; createAlias re-checks (and reserves) when the user accepts it.
 */
export async function suggestAddress(domainInput: string | undefined, cfg: AppConfig): Promise<{ localPart: string; domain: string; address: string }> {
  const domain = validateDomain(domainInput ?? cfg.aliasDomains[0], cfg);
  const index = await table(T.aliasIndex);
  for (let attempt = 0; attempt < 5; attempt++) {
    const localPart = generateLocalPart();
    if (await getEntityOrUndefined(index, domain, localPart)) continue;
    if (await inDirectory(`${localPart}@${domain}`)) continue;
    return { localPart, domain, address: `${localPart}@${domain}` };
  }
  throw new HttpError(503, 'no_suggestion', 'Could not find a free address. Try again.');
}

/**
 * Queues removal. Deliberately NOT gated by CREATION_ENABLED or the soft job budget,
 * so restricting creation never blocks removal or expiry.
 */
export async function requestRemoval(userId: string, address: string, reason: ExchangeOp['reason'], actor: string): Promise<{ operationId: string } | undefined> {
  const aliases = await table(T.aliases);
  const row = await getEntityOrUndefined<AliasRecord>(aliases, userId, address.toLowerCase());
  if (!row) return undefined;
  if (row.status === 'Removed' || row.status === 'Removing') return { operationId: row.lastOperationId ?? '' };
  if (row.status === 'Pending') throw new HttpError(409, 'operation_pending', 'The alias is still being created. Try again shortly.');

  const opId = randomUUID();
  const now = new Date().toISOString();
  if (row.status === 'Failed') {
    // Never reached Exchange: retire locally, nothing to remove.
    await aliases.updateEntity({ partitionKey: userId, rowKey: row.address, status: 'Removed', removedAt: now }, 'Merge', { etag: row.etag });
    return { operationId: row.lastOperationId ?? '' };
  }
  await aliases.updateEntity({ partitionKey: userId, rowKey: row.address, status: 'Removing', lastOperationId: opId }, 'Merge', { etag: row.etag });
  await enqueue({ opId, userId, type: 'remove', address: row.address, reason, requestedAt: now });
  await audit({ actor, action: 'alias.remove.requested', target: row.address, outcome: 'accepted', detail: reason });
  return { operationId: opId };
}

async function enqueue(op: ExchangeOp): Promise<void> {
  await (await table(T.operations)).createEntity({
    partitionKey: op.userId, rowKey: op.opId, type: op.type, address: op.address, reason: op.reason,
    status: 'Queued' satisfies OperationStatus, attempts: 0, requestedAt: op.requestedAt,
  });
  // TTL -1: operations never silently expire from the queue.
  await (await opsQueue()).sendMessage(JSON.stringify(op), { messageTimeToLive: -1 });
}

export async function getOperation(userId: string, opId: string) {
  const row = await getEntityOrUndefined<Record<string, unknown>>(await table(T.operations), userId, opId);
  if (!row) return undefined;
  const { type, address, status, attempts, requestedAt, completedAt, error } = row;
  return { id: opId, type, address, status, attempts, requestedAt, completedAt, error };
}
