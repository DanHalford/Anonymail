import { randomInt } from 'node:crypto';
import { AppConfig } from './config';
import { HttpError } from './http';

const ADJECTIVES = [
  'amber', 'brisk', 'calm', 'dusty', 'eager', 'fuzzy', 'gentle', 'hollow', 'icy', 'jolly', 'keen', 'lucky',
  'misty', 'nimble', 'olive', 'plain', 'quiet', 'rapid', 'sunny', 'tidy', 'urban', 'vivid', 'witty', 'young',
];
const NOUNS = [
  'acorn', 'badger', 'canyon', 'dingo', 'ember', 'falcon', 'gecko', 'harbor', 'island', 'jetty', 'koala', 'lagoon',
  'meadow', 'nectar', 'otter', 'pebble', 'quokka', 'river', 'summit', 'thistle', 'umbra', 'valley', 'wombat', 'zephyr',
];

const LOCAL_PART = /^[a-z0-9](?:[a-z0-9._-]{1,62}[a-z0-9])$/;

export function generateLocalPart(): string {
  const a = ADJECTIVES[randomInt(ADJECTIVES.length)];
  const n = NOUNS[randomInt(NOUNS.length)];
  return `${a}-${n}-${randomInt(1000, 10000)}`;
}

/** True if the local part has exactly the generator's shape (word list + 4 digits). */
export function isGeneratedLocalPart(lp: string): boolean {
  const m = /^([a-z]+)-([a-z]+)-(\d{4})$/.exec(lp);
  return !!m && ADJECTIVES.includes(m[1]) && NOUNS.includes(m[2]) && Number(m[3]) >= 1000;
}

export function validateLocalPart(localPart: string, cfg: AppConfig): string {
  const lp = localPart.trim().toLowerCase();
  if (!LOCAL_PART.test(lp) || /[._-]{2}/.test(lp)) {
    throw new HttpError(400, 'invalid_local_part', 'Use 3–64 letters, digits, dots, hyphens or underscores, starting and ending with a letter or digit.');
  }
  if (cfg.reservedLocalParts.includes(lp)) throw new HttpError(400, 'reserved_local_part', 'That name is reserved.');
  return lp;
}

export function validateDomain(domain: string, cfg: AppConfig): string {
  const d = domain.trim().toLowerCase();
  if (!cfg.aliasDomains.includes(d)) throw new HttpError(400, 'domain_not_allowed', 'That domain is not available for aliases.');
  return d;
}

const MIN_LEAD_MS = 60 * 60_000; // an expiry must be at least an hour away
const MAX_YEARS_MS = 3650 * 86_400_000;

/**
 * Validates a drop-dead expiry instant (ISO 8601, e.g. the end of the chosen day in the user's
 * time zone, as sent by the SPA) and returns it normalised, or undefined for "never".
 * MAX_ALIAS_LIFETIME_DAYS caps how far ahead the date may be; when set, "never" becomes the cap.
 * The alias is removed by the first daily expiry run after this instant.
 */
export function resolveExpiry(expiresAt: string | undefined, cfg: AppConfig, now = new Date()): string | undefined {
  const capMs = cfg.maxAliasLifetimeDays > 0 ? cfg.maxAliasLifetimeDays * 86_400_000 : MAX_YEARS_MS;
  if (expiresAt === undefined || expiresAt === null || expiresAt === '') {
    return cfg.maxAliasLifetimeDays > 0 ? new Date(now.getTime() + capMs).toISOString() : undefined;
  }
  // Require an explicit offset or Z so the instant is unambiguous.
  const t = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(expiresAt) ? Date.parse(expiresAt) : NaN;
  if (Number.isNaN(t)) throw new HttpError(400, 'invalid_expiry', 'expiresAt must be an ISO 8601 date-time with a time zone.');
  if (t < now.getTime() + MIN_LEAD_MS) throw new HttpError(400, 'invalid_expiry', 'The expiry date must be in the future.');
  if (t > now.getTime() + capMs) {
    const latest = new Date(now.getTime() + capMs).toISOString().slice(0, 10);
    throw new HttpError(400, 'expiry_too_far', `The expiry date can be no later than ${latest}.`);
  }
  return new Date(t).toISOString();
}

/** Daily expiry bucket key, e.g. 20261102. */
export function expiryBucket(iso: string): string {
  return iso.slice(0, 10).replace(/-/g, '');
}
