# Authentication

## Baseline: passkeys **supported**

The baseline needs only the free Entra ID features that come with Microsoft 365.

- Users sign in through the organisation's Entra tenant, using a single-tenant app registration.
- Passkey sign-in (FIDO2 security keys, or passkeys in Microsoft Authenticator) works wherever the
  tenant has enabled the **Passkey (FIDO2)** method in the Authentication methods policy. That
  policy is available without P1 or P2.
- The app accepts **any** authentication method the tenant allows. It doesn't weaken, bypass or
  override existing tenant policies such as security defaults, per-user MFA or existing
  Conditional Access.

To enable passkeys (Authentication Policy Administrator):

1. Go to **Entra admin center → Protection → Authentication methods → Policies → Passkey (FIDO2)**.
2. Set **Enable** and choose the target users or group. For the baseline, leave
   *Enforce attestation* and key restrictions at your organisation's standard.
3. Users register a passkey at <https://mysignins.microsoft.com/security-info>.

With this setup, passkeys are **supported, not required**. A user who still has a password, or
another method the tenant allows, can sign in with it.

## Optional enhancement: passkeys **required**

You can enforce passkey-only (phishing-resistant) sign-in for Anonymail if the tenant has licences
for **Conditional Access** (Entra ID P1 or above, or Microsoft 365 Business Premium, E3 or E5).

1. Create a Conditional Access policy targeting the **Anonymail** enterprise application and the
   eligible users.
2. Under **Grant**, choose **Require authentication strength → Phishing-resistant MFA**, or a
   custom strength that allows passkeys only.
3. Test in report-only mode first.

This is **not part of the baseline**. The cost and licensing verification in
[acceptance.md](acceptance.md) runs without it. The API doesn't check `amr` or
authentication-strength claims, so enforcement lives entirely in Conditional Access.

## Restricting who may sign in, without P1

| Method | Licence | Notes |
|---|---|---|
| `ELIGIBLE_GROUP_IDS`, enforced by the API (default) | None | Group membership is checked on every request. Users outside the group can sign in but can't use the service. |
| Enterprise app → *Assignment required* plus **direct user** assignment | None | Assigning **groups** to an app needs P1, so assign users one at a time. |
| Conditional Access | P1 | Optional, see above |
