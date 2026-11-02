import { Auth } from './auth';

export type AliasStatus = 'Pending' | 'Active' | 'Removing' | 'Removed' | 'Failed' | 'RemoveFailed';

export interface Alias {
  address: string;
  domain: string;
  note?: string;
  status: AliasStatus;
  createdAt: string;
  expiresAt?: string;
  lastOperationId?: string;
  lastError?: string;
}

export interface Me {
  name?: string;
  eligible: boolean;
  reason?: string;
  domains: string[];
  allowCustomLocalPart: boolean;
  maxAliasLifetimeDays: number;
  creationEnabled: boolean;
  quotas: { active: number; activeMax: number; today: number; todayMax: number };
}

export interface Operation {
  id: string;
  status: 'Queued' | 'Retrying' | 'Succeeded' | 'Failed';
  error?: string;
}

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

export class Api {
  constructor(private readonly auth: Auth) {}

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await fetch(`${this.auth.cfg.apiBaseUrl}${path}`, {
      method,
      headers: { Authorization: `Bearer ${await this.auth.token()}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new ApiError(res.status, data.error ?? 'error', data.message ?? `Request failed (${res.status})`);
    return data as T;
  }

  me = () => this.call<Me>('GET', '/me');
  list = () => this.call<{ aliases: Alias[] }>('GET', '/aliases').then((r) => r.aliases);
  suggest = (domain: string) =>
    this.call<{ localPart: string; domain: string; address: string }>('GET', `/aliases/suggestion?domain=${encodeURIComponent(domain)}`);
  /** expiresAt: ISO 8601 instant with offset; omit for "never". */
  create = (req: { domain: string; localPart?: string; note?: string; expiresAt?: string }) =>
    this.call<{ alias: Alias; operationId: string }>('POST', '/aliases', req);
  remove = (address: string) => this.call<{ operationId: string }>('DELETE', `/aliases/${encodeURIComponent(address)}`);
  operation = (id: string) => this.call<Operation>('GET', `/operations/${encodeURIComponent(id)}`);
}
