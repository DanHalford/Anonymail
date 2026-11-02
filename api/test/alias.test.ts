import { describe, expect, it } from 'vitest';
import { expiryBucket, generateLocalPart, isGeneratedLocalPart, resolveExpiry, validateDomain, validateLocalPart } from '../src/lib/alias';
import { claimsToCaller } from '../src/lib/auth';
import { loadConfig } from '../src/lib/config';
import { lockIsActive } from '../src/lib/dispatcher';

const TENANT = '11111111-1111-1111-1111-111111111111';
const CLIENT = '22222222-2222-2222-2222-222222222222';
const OID = '33333333-3333-3333-3333-333333333333';

const cfg = loadConfig({
  TENANT_ID: TENANT,
  API_CLIENT_ID: CLIENT,
  ALIAS_DOMAINS: 'alias.example.com, other.example.com',
  EXCHANGE_ORGANIZATION: 'example.onmicrosoft.com',
  WORKER_DISPATCH_ENABLED: 'false',
  MAX_ALIAS_LIFETIME_DAYS: '90',
});

describe('alias naming', () => {
  it('generates valid local parts', () => {
    for (let i = 0; i < 200; i++) expect(validateLocalPart(generateLocalPart(), cfg)).toMatch(/^[a-z]+-[a-z]+-\d{2}$/);
  });
  it('recognises accepted suggestions but not look-alikes', () => {
    expect(isGeneratedLocalPart(generateLocalPart())).toBe(true);
    expect(isGeneratedLocalPart('quiet-otter-07')).toBe(true);
    expect(isGeneratedLocalPart('john-smith-12')).toBe(false);
    expect(isGeneratedLocalPart('quiet-otter-482')).toBe(false);
    expect(isGeneratedLocalPart('quiet-otter-7')).toBe(false);
  });
  it('rejects reserved and malformed names', () => {
    expect(() => validateLocalPart('postmaster', cfg)).toThrow(/reserved/);
    expect(() => validateLocalPart('a..b', cfg)).toThrow();
    expect(() => validateLocalPart('-abc', cfg)).toThrow();
    expect(validateLocalPart('Shop.Deals', cfg)).toBe('shop.deals');
  });
  it('only allows configured domains', () => {
    expect(validateDomain('ALIAS.example.com', cfg)).toBe('alias.example.com');
    expect(() => validateDomain('evil.com', cfg)).toThrow(/not available/);
  });
});

describe('expiry', () => {
  const now = new Date('2026-11-02T00:00:00Z');
  const uncapped = { ...cfg, maxAliasLifetimeDays: 0 };
  it('accepts a future drop-dead date and normalises it to UTC', () => {
    expect(resolveExpiry('2026-12-24T23:59:59+11:00', cfg, now)).toBe('2026-12-24T12:59:59.000Z');
  });
  it('treats no date as "never" unless a maximum lifetime is configured', () => {
    expect(resolveExpiry(undefined, uncapped, now)).toBeUndefined();
    expect(resolveExpiry('', cfg, now)).toBe('2027-01-31T00:00:00.000Z');
  });
  it('rejects past, too-near, too-far and zone-less dates', () => {
    expect(() => resolveExpiry('2026-11-01T23:59:59Z', cfg, now)).toThrow(/future/);
    expect(() => resolveExpiry('2026-11-02T00:30:00Z', cfg, now)).toThrow(/future/);
    expect(() => resolveExpiry('2027-02-01T00:00:00Z', cfg, now)).toThrow(/no later than 2027-01-31/);
    expect(() => resolveExpiry('2026-12-24T23:59:59', uncapped, now)).toThrow(/time zone/);
    expect(() => resolveExpiry('next tuesday', uncapped, now)).toThrow(/ISO 8601/);
  });
  it('buckets by UTC day', () => expect(expiryBucket('2026-12-02T10:00:00.000Z')).toBe('20261202'));
});

describe('token claims', () => {
  const base = { tid: TENANT, oid: OID, scp: 'Aliases.Manage', name: 'Test' };
  it('accepts a delegated token from the tenant', () => {
    expect(claimsToCaller({ ...base, groups: ['ABC'] }, cfg)).toMatchObject({ userId: OID, groups: ['abc'] });
  });
  it('rejects other tenants, app tokens and missing scope', () => {
    expect(() => claimsToCaller({ ...base, tid: '99999999-9999-9999-9999-999999999999' }, cfg)).toThrow(/organisation/);
    expect(() => claimsToCaller({ ...base, idtyp: 'app' }, cfg)).toThrow(/signed-in user/);
    expect(() => claimsToCaller({ ...base, scp: 'User.Read' }, cfg)).toThrow(/scope/);
  });
  it('treats group overage as unknown so Graph is consulted', () => {
    expect(claimsToCaller({ ...base, _claim_names: { groups: 'src1' } }, cfg).groups).toBeUndefined();
  });
});

describe('worker lock', () => {
  const now = Date.parse('2026-11-02T00:30:00Z');
  it('treats idle or stale locks as free', () => {
    expect(lockIsActive(undefined, 20, now)).toBe(false);
    expect(lockIsActive({ status: 'Idle', updatedAt: '2026-11-02T00:29:00Z' }, 20, now)).toBe(false);
    expect(lockIsActive({ status: 'Running', updatedAt: '2026-11-02T00:00:00Z' }, 20, now)).toBe(false);
    expect(lockIsActive({ status: 'Running', updatedAt: '2026-11-02T00:25:00Z' }, 20, now)).toBe(true);
  });
});
