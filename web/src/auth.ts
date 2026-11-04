import { AccountInfo, InteractionRequiredAuthError, PublicClientApplication } from '@azure/msal-browser';

const GRAPH_MAIL_READ_BASIC = 'https://graph.microsoft.com/Mail.ReadBasic';

export interface RuntimeConfig {
  tenantId: string;
  clientId: string;
  apiBaseUrl: string;
  apiScope: string;
}

/**
 * Sign-in is a standard Entra ID authorization-code + PKCE flow against the organisation's
 * own tenant. Passkeys (and any other method the tenant allows) are offered by Entra's sign-in
 * page; this app neither weakens nor adds to the tenant's authentication policy.
 */
export class Auth {
  private constructor(private readonly msal: PublicClientApplication, readonly cfg: RuntimeConfig) {}

  static async create(cfg: RuntimeConfig): Promise<Auth> {
    const msal = new PublicClientApplication({
      auth: {
        clientId: cfg.clientId,
        authority: `https://login.microsoftonline.com/${cfg.tenantId}`, // single tenant only
        redirectUri: window.location.origin + '/',
      },
      cache: { cacheLocation: 'sessionStorage' },
    });
    await msal.initialize();
    const result = await msal.handleRedirectPromise();
    if (result?.account) msal.setActiveAccount(result.account);
    else if (!msal.getActiveAccount() && msal.getAllAccounts().length) msal.setActiveAccount(msal.getAllAccounts()[0]);
    return new Auth(msal, cfg);
  }

  get account(): AccountInfo | null {
    return this.msal.getActiveAccount();
  }

  signIn(): Promise<void> {
    return this.msal.loginRedirect({ scopes: [this.cfg.apiScope] });
  }

  signOut(): Promise<void> {
    return this.msal.logoutRedirect({ account: this.account ?? undefined });
  }

  /** Delegated Graph token for listing the user's own mail folders (admin-consented, so normally silent). */
  async graphToken(): Promise<string> {
    const account = this.account;
    if (!account) throw new Error('Not signed in');
    return (await this.msal.acquireTokenSilent({ scopes: [GRAPH_MAIL_READ_BASIC], account })).accessToken;
  }

  /** Interactive fallback when graphToken() needs consent or a fresh sign-in. */
  consentGraph(): Promise<void> {
    return this.msal.acquireTokenRedirect({ scopes: [GRAPH_MAIL_READ_BASIC], account: this.account ?? undefined });
  }

  async token(): Promise<string> {
    const account = this.account;
    if (!account) throw new Error('Not signed in');
    try {
      return (await this.msal.acquireTokenSilent({ scopes: [this.cfg.apiScope], account })).accessToken;
    } catch (err) {
      if (err instanceof InteractionRequiredAuthError) {
        await this.msal.acquireTokenRedirect({ scopes: [this.cfg.apiScope], account });
      }
      throw err;
    }
  }
}
