import { randomInt } from 'node:crypto';
import { AppConfig } from './config';
import { HttpError } from './http';

const ADJECTIVES = [
  "red", "orange", "yellow", "green", "blue",
  "purple", "pink", "white", "silver", "golden",
  "bronze", "copper", "amber", "scarlet", "crimson",
  "coral", "violet", "indigo", "teal", "turquoise",
  "swift", "quick", "rapid", "speedy", "agile",
  "nimble", "steady", "quiet", "silent", "cautious",
  "curious", "alert", "watchful", "patient", "clever",
  "bright", "bold", "brave", "calm", "friendly",
  "gentle", "playful", "lively", "cheerful", "daring",
  "adventurous", "small", "little", "tall", "strong",
  "mighty", "fierce", "valiant", "noble", "wise",
  "honest", "loyal", "kind", "generous",
  "brilliant", "charming", "diligent", "energetic", "fearless",
];
const NOUNS = [
  "tiger", "panther", "fox", "bear",
  "rabbit", "owl", "eagle", "falcon", "hawk",
  "robin", "sparrow", "parrot", "penguin", "puffin",
  "otter", "beaver", "badger", "deer", "moose",
  "horse", "pony", "zebra", "giraffe", "elephant",
  "panda", "koala", "kangaroo", "wallaby", "wombat",
  "dolphin", "whale", "seal", "turtle", "gecko",
  "chameleon", "frog", "butterfly", "dragonfly", "beetle",
  "scout", "ranger", "sailor", "pilot", "climber",
  "hiker", "runner", "swimmer", "archer", "gardener",
  "scholar", "artist", "musician", "dancer", "chef",
  "baker", "writer", "poet", "inventor", "explorer",
  "captain", "commander", "adventurer", "seeker", "voyager",
];

const LOCAL_PART = /^[a-z0-9](?:[a-z0-9._-]{1,62}[a-z0-9])$/;

export function generateLocalPart(): string {
  const a = ADJECTIVES[randomInt(ADJECTIVES.length)];
  const n = NOUNS[randomInt(NOUNS.length)];
  return `${a}-${n}-${String(randomInt(100)).padStart(2, '0')}`;
}

/** True if the local part has exactly the generator's shape (word list + two digits, 00-99). */
export function isGeneratedLocalPart(lp: string): boolean {
  const m = /^([a-z]+)-([a-z]+)-(\d{2})$/.exec(lp);
  return !!m && ADJECTIVES.includes(m[1]) && NOUNS.includes(m[2]);
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
