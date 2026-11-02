import { HttpRequest } from '@azure/functions';
import { createRemoteJWKSet, JWTPayload, jwtVerify } from 'jose';
import { AppConfig, config } from './config';
import { HttpError } from './http';

export interface Caller {
  userId: string; // Entra object id (immutable) — the ownership key for every alias
  tenantId: string;
  name?: string;
  username?: string;
  /** Group ids from the token, or undefined when absent / overage (then Graph is consulted). */
  groups?: string[];
}

let jwks: ReturnType<typeof createRemoteJWKSet> | undefined;

/**
 * Validates an Entra v2 access token issued by THIS tenant for THIS API.
 * Passkeys are handled entirely by Entra sign-in; the API accepts any authentication
 * method the tenant permits (see docs/authentication.md for "supported" vs "required").
 */
export async function authenticate(req: HttpRequest, cfg: AppConfig = config()): Promise<Caller> {
  const header = req.headers.get('authorization') ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) throw new HttpError(401, 'unauthenticated', 'Sign in required.');

  jwks ??= createRemoteJWKSet(new URL(`https://login.microsoftonline.com/${cfg.tenantId}/discovery/v2.0/keys`));
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(match[1], jwks, {
      issuer: `https://login.microsoftonline.com/${cfg.tenantId}/v2.0`,
      audience: [cfg.apiClientId, `api://${cfg.apiClientId}`],
      algorithms: ['RS256'],
      clockTolerance: 60,
    }));
  } catch {
    throw new HttpError(401, 'invalid_token', 'Access token is invalid or expired.');
  }
  return claimsToCaller(payload, cfg);
}

/** Pure claim checks, separated for unit testing. */
export function claimsToCaller(p: JWTPayload & Record<string, unknown>, cfg: AppConfig): Caller {
  if (String(p.tid ?? '').toLowerCase() !== cfg.tenantId) {
    throw new HttpError(403, 'wrong_tenant', 'Only members of the organisation may use this service.');
  }
  // Delegated user token only — reject app-only tokens.
  if (p.idtyp === 'app' || typeof p.scp !== 'string') {
    throw new HttpError(403, 'user_token_required', 'A signed-in user is required.');
  }
  const scopes = (p.scp as string).split(' ');
  if (!scopes.includes(cfg.apiScope)) throw new HttpError(403, 'missing_scope', `Token lacks scope ${cfg.apiScope}.`);
  const oid = String(p.oid ?? '').toLowerCase();
  if (!/^[0-9a-f-]{36}$/.test(oid)) throw new HttpError(403, 'missing_oid', 'Token has no user object id.');

  const overage = typeof p._claim_names === 'object' && p._claim_names !== null && 'groups' in (p._claim_names as object);
  const groups = !overage && Array.isArray(p.groups) ? (p.groups as string[]).map((g) => g.toLowerCase()) : undefined;

  return {
    userId: oid,
    tenantId: cfg.tenantId,
    name: typeof p.name === 'string' ? p.name : undefined,
    username: typeof p.preferred_username === 'string' ? p.preferred_username : undefined,
    groups,
  };
}
