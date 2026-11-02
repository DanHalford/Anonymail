import { Caller } from './auth';
import { AppConfig } from './config';
import { getUser, memberOf } from './graph';
import { HttpError } from './http';
import { T, getEntityOrUndefined, table } from './storage';

/**
 * Cached, revalidated mapping from Entra user -> mailbox eligibility.
 * Keyed by immutable object id; the Exchange worker independently re-verifies the mailbox
 * (RecipientTypeDetails = UserMailbox, ExternalDirectoryObjectId match) before every change.
 */
export interface MailboxRecord {
  eligible: boolean;
  reason?: string;
  primarySmtp?: string;
  inGroup: boolean;
  graphValidatedAt: string;
  exchangeVerifiedAt?: string; // written by the worker
}

const NEGATIVE_TTL_MS = 60 * 60 * 1000; // re-check ineligible users hourly so newly added users get in quickly

export async function resolveEligibility(caller: Caller, cfg: AppConfig, now = Date.now()): Promise<MailboxRecord> {
  const client = await table(T.mailboxes);
  const cached = await getEntityOrUndefined<MailboxRecord>(client, 'mbx', caller.userId);
  const ttl = cached?.eligible ? cfg.mailboxCacheTtlHours * 3_600_000 : NEGATIVE_TTL_MS;
  let record: MailboxRecord;

  if (cached && now - Date.parse(cached.graphValidatedAt) < ttl) {
    record = { ...cached };
  } else {
    record = await validateWithGraph(caller, cfg, now);
    await client.upsertEntity({ partitionKey: 'mbx', rowKey: caller.userId, ...record }, 'Merge');
  }

  // Token group claims (when present) are fresher than the cache; they can only revoke, never grant
  // beyond the cached user/mailbox checks.
  if (cfg.eligibleGroupIds.length > 0 && caller.groups) {
    const inGroup = caller.groups.some((g) => cfg.eligibleGroupIds.includes(g));
    if (!inGroup) return { ...record, eligible: false, inGroup: false, reason: 'not_in_eligible_group' };
  }
  return record;
}

async function validateWithGraph(caller: Caller, cfg: AppConfig, now: number): Promise<MailboxRecord> {
  const stamp = new Date(now).toISOString();
  const user = await getUser(caller.userId);
  const deny = (reason: string): MailboxRecord => ({ eligible: false, reason, inGroup: false, graphValidatedAt: stamp });
  if (!user) return deny('user_not_found');
  if (!user.accountEnabled) return deny('account_disabled');
  if (user.userType && user.userType !== 'Member') return deny('guest_not_allowed');
  if (!user.mail) return deny('no_mailbox');

  let inGroup = true;
  if (cfg.eligibleGroupIds.length > 0) {
    inGroup = caller.groups
      ? caller.groups.some((g) => cfg.eligibleGroupIds.includes(g))
      : (await memberOf(caller.userId, cfg.eligibleGroupIds)).length > 0;
  }
  return {
    eligible: inGroup,
    reason: inGroup ? undefined : 'not_in_eligible_group',
    primarySmtp: user.mail.toLowerCase(),
    inGroup,
    graphValidatedAt: stamp,
  };
}

export async function requireEligible(caller: Caller, cfg: AppConfig): Promise<MailboxRecord> {
  const rec = await resolveEligibility(caller, cfg);
  if (!rec.eligible) throw new HttpError(403, 'not_eligible', `You are not eligible to use aliases (${rec.reason}).`);
  return rec;
}
