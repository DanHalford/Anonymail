export interface AppConfig {
  tenantId: string;
  apiClientId: string;
  apiScope: string;
  aliasDomains: string[];
  eligibleGroupIds: string[];
  storageAccountName?: string;
  storageConnectionString?: string;
  queueName: string;
  automationAccountId: string;
  automationRunbookName: string;
  exchangeOrganization: string;
  workerDispatchEnabled: boolean;
  creationEnabled: boolean;
  allowCustomLocalPart: boolean;
  maxActiveAliasesPerUser: number;
  maxCreationsPerUserPerDay: number;
  maxCreationsPerMonth: number;
  maxAliasLifetimeDays: number; // 0 = no maximum
  workerJobsSoftLimitPerMonth: number; // above this, creation is suspended; removal/expiry continue
  workerJobsHardLimitPerMonth: number; // above this, no worker jobs start at all
  workerMaxRuntimeMinutes: number;
  workerLockTtlMinutes: number;
  maxOperationAttempts: number;
  mailboxCacheTtlHours: number;
  auditRetentionDays: number;
  reservedLocalParts: string[];
}

const DEFAULT_RESERVED = [
  'abuse', 'admin', 'administrator', 'billing', 'hostmaster', 'info', 'mailer-daemon',
  'noreply', 'no-reply', 'postmaster', 'root', 'security', 'support', 'webmaster',
];

function list(v: string | undefined): string[] {
  return (v ?? '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
}

function int(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 0) throw new Error(`Setting ${name} must be a non-negative integer`);
  return n;
}

function bool(env: NodeJS.ProcessEnv, name: string, fallback: boolean): boolean {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  return raw.toLowerCase() === 'true';
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const v = env[name];
  if (!v) throw new Error(`Missing required setting ${name}`);
  return v;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const workerDispatchEnabled = bool(env, 'WORKER_DISPATCH_ENABLED', true);
  return {
    tenantId: required(env, 'TENANT_ID').toLowerCase(),
    apiClientId: required(env, 'API_CLIENT_ID').toLowerCase(),
    apiScope: env.API_SCOPE_NAME || 'Aliases.Manage',
    aliasDomains: list(required(env, 'ALIAS_DOMAINS')),
    eligibleGroupIds: list(env.ELIGIBLE_GROUP_IDS),
    storageAccountName: env.STORAGE_ACCOUNT_NAME,
    storageConnectionString: env.STORAGE_CONNECTION_STRING,
    queueName: env.QUEUE_NAME || 'exchange-ops',
    automationAccountId: workerDispatchEnabled ? required(env, 'AUTOMATION_ACCOUNT_ID') : env.AUTOMATION_ACCOUNT_ID ?? '',
    automationRunbookName: env.AUTOMATION_RUNBOOK_NAME || 'Invoke-AnonymailWorker',
    exchangeOrganization: required(env, 'EXCHANGE_ORGANIZATION'),
    workerDispatchEnabled,
    creationEnabled: bool(env, 'CREATION_ENABLED', true),
    allowCustomLocalPart: bool(env, 'ALLOW_CUSTOM_LOCAL_PART', true),
    maxActiveAliasesPerUser: int(env, 'MAX_ACTIVE_ALIASES_PER_USER', 100),
    maxCreationsPerUserPerDay: int(env, 'MAX_CREATIONS_PER_USER_PER_DAY', 10),
    maxCreationsPerMonth: int(env, 'MAX_CREATIONS_PER_MONTH', 300),
    maxAliasLifetimeDays: int(env, 'MAX_ALIAS_LIFETIME_DAYS', 0),
    workerJobsSoftLimitPerMonth: int(env, 'WORKER_JOBS_SOFT_LIMIT_PER_MONTH', 200),
    workerJobsHardLimitPerMonth: int(env, 'WORKER_JOBS_HARD_LIMIT_PER_MONTH', 250),
    workerMaxRuntimeMinutes: int(env, 'WORKER_MAX_RUNTIME_MINUTES', 5),
    workerLockTtlMinutes: int(env, 'WORKER_LOCK_TTL_MINUTES', 20),
    maxOperationAttempts: int(env, 'MAX_OPERATION_ATTEMPTS', 3),
    mailboxCacheTtlHours: int(env, 'MAILBOX_CACHE_TTL_HOURS', 24),
    auditRetentionDays: int(env, 'AUDIT_RETENTION_DAYS', 365),
    reservedLocalParts: [...DEFAULT_RESERVED, ...list(env.RESERVED_LOCAL_PARTS)],
  };
}

let cached: AppConfig | undefined;
export function config(): AppConfig {
  return (cached ??= loadConfig());
}
