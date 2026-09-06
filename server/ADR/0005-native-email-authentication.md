# ADR 0005: Native email and one-time code authentication

- Status: implemented behind the Snippets Cloud feature flag
- Date: 2026-09-06
- Supersedes: ADR 0004's browser/provider account login

Snippets presents native email and code controls on iOS, macOS and Android. Account login
must not create a WebView, system browser session, redirect or account-center page. The
first implementation is email OTP; Apple and Google login are outside this change.

The Go server owns the email challenge and opaque session lifecycle in `AUTH_MODE=native`.
An explicit OIDC mode remains for existing protocol fixtures and deployments; native
clients require the advertised email capability and never fall back to browser login.
The discovery contract pins four first-party HTTPS endpoints to the server origin.

The SMTP adapter sends cryptographically random six-digit codes without reflecting SMTP
errors. Codes are HMAC-bound to random challenges, expire in ten minutes, allow five
attempts under a database row lock, and are consumed atomically with session issuance.
Resends replace earlier codes. Shared per-email, per-source-IP and deployment rate rows
prevent replicas from multiplying the request budget. No existing-account check changes
the public start response or delivery behavior. ASCII email addresses are canonicalized
case-insensitively, with no provider-specific alias linking.

An account receives a random immutable UUID. The verified email is private display/contact
data, and its lookup uses the persistent identity pepper. Sync identity is a separately
domain-separated HMAC of the immutable account ID. The independent native auth secret
protects code/challenge/credential/rate digests. Raw tokens and codes never persist.

Access tokens last up to five minutes. Refresh tokens rotate once and expire with their
30-day family; reuse revokes the family transactionally. Keeping rotated digests until
family expiry lets a device revoke a superseded generation after losing a refresh response.
Exact access revocation preserves other tokens and sessions. Family revocation waits on
the existing data-plane credential locks and inserts retained access tokens, including
recently expired ones, into the denylist. A principal admitted before expiry can still be
waiting for its request body when logout completes. Expired families remain available for
revocation for a five-minute cleanup grace period; this extends neither the 30-day family
authorization nor access-token validity. Denylist retention likewise extends only denial.

The default rate-limit identity is the immediate TCP peer. Deployments behind a proxy can
set explicit `AUTH_TRUSTED_PROXY_CIDRS` and have that trusted hop overwrite the single
`X-Snippets-Client-IP` header. Malformed or missing trusted-hop identities fail closed;
untrusted peers cannot affect rate buckets by supplying forwarding headers.

Schema 3 is additive. New authentication tables have forced RLS, no direct runtime grants,
and narrowly scoped security-definer operations owned by the existing non-login function
owner. Transient records have bounded cleanup work and globally bounded creation rates.
SMTP permits plaintext only for isolated development/test Mailpit, never production.
All authentication HTTP responses disable caching, and log fields remain closed and free
of email, OTP, token and SMTP exception text.

Library root keys, client-side encryption, offline recovery, pairing and signed library
actions are unchanged. Email OTP alone grants no library key authority and makes no
phishing-resistance claim. Existing OIDC and native identities are not merged implicitly.
