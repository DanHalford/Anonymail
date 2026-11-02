import { azureCredential } from './storage';

/** Minimal Microsoft Graph client using the Function App's managed identity (application permissions). */
async function graph<T>(path: string, init?: RequestInit): Promise<T | undefined> {
  const token = await azureCredential().getToken('https://graph.microsoft.com/.default');
  const res = await fetch(`https://graph.microsoft.com/v1.0${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token.token}`, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
  });
  if (res.status === 404) return undefined;
  if (!res.ok) throw new Error(`Graph ${path} failed: ${res.status}`);
  return (await res.json()) as T;
}

export interface GraphUser {
  id: string;
  accountEnabled: boolean;
  userType: string | null;
  mail: string | null;
  userPrincipalName: string;
}

export function getUser(userId: string): Promise<GraphUser | undefined> {
  return graph<GraphUser>(`/users/${encodeURIComponent(userId)}?$select=id,accountEnabled,userType,mail,userPrincipalName`);
}

/**
 * True if any user, group or organisational contact in the directory already owns the address
 * (as mail, UPN or any proxy address). One Graph $batch round trip. Requires User.Read.All,
 * GroupMember.Read.All and OrgContact.Read.All. The Exchange worker re-checks with Get-Recipient,
 * which also covers Exchange-only recipients (e.g. public folders).
 */
export async function addressInUseInDirectory(address: string): Promise<boolean> {
  const a = address.replace(/'/g, "''");
  const proxy = `proxyAddresses/any(x:x eq 'smtp:${a}')`;
  const q = (path: string, filter: string) => `${path}?$filter=${encodeURIComponent(filter)}&$select=id&$top=1`;
  const res = await graph<{ responses: { id: string; status: number; body?: { value?: unknown[] } }[] }>('/$batch', {
    method: 'POST',
    body: JSON.stringify({
      requests: [
        { id: 'users', method: 'GET', url: q('/users', `mail eq '${a}' or userPrincipalName eq '${a}' or ${proxy}`) },
        { id: 'groups', method: 'GET', url: q('/groups', `mail eq '${a}' or ${proxy}`) },
        { id: 'contacts', method: 'GET', url: q('/contacts', `mail eq '${a}' or ${proxy}`) },
      ],
    }),
  });
  for (const r of res?.responses ?? []) {
    if (r.status !== 200) throw new Error(`Directory check (${r.id}) failed: ${r.status}`);
    if ((r.body?.value?.length ?? 0) > 0) return true;
  }
  return false;
}

/** Returns the subset of groupIds the user is a (transitive) member of. Requires GroupMember.Read.All. */
export async function memberOf(userId: string, groupIds: string[]): Promise<string[]> {
  if (groupIds.length === 0) return [];
  const res = await graph<{ value: string[] }>(`/users/${encodeURIComponent(userId)}/checkMemberGroups`, {
    method: 'POST',
    body: JSON.stringify({ groupIds }),
  });
  return (res?.value ?? []).map((g) => g.toLowerCase());
}
