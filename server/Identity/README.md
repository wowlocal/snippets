# Snippets account deployment

Native clients now use OIDC code + PKCE with Apple, Google, or email OTP. Passkeys are
optional for new libraries. Global uses Logto Cloud; the regional deployment uses the
pinned Logto OSS stack in `docker-compose.yml`. These are independent identity domains:
separate issuer, subjects, databases, API origins, server instance IDs, SMTP and callback
hosts. There is no email-based migration, automatic geolocation, or fallback from one
region to the other. The region is selected at build time.

No tenant or social-provider credentials are stored here. This configuration is a
reviewable deployment template; it has not provisioned a live Logto tenant. Keep the
feature disabled until both real provider acceptance lanes below pass.

## Configure each tenant

1. Create one **Native** application, with the exact verified HTTPS callbacks for Mac,
   iOS and Android. Register the platform associations (`apple-app-site-association`
   and `assetlinks.json`) on that region's callback host. No wildcards or custom-scheme
   fallback. The resource server currently accepts one native client ID, so all three
   callbacks belong to that application.
2. Add an API resource whose indicator is the exact Snippets API origin (no `/v2` or
   trailing slash). Set its access-token TTL to **300 seconds**. Configure refresh-token
   TTL **30 days**, rotation on each refresh, and grant TTL **180 days**. Use **RS256**
   signing keys for the server's default allow-list; clients also validate ES256.
3. Enable email verification-code sign-in/sign-up, disable mandatory password and
   mandatory MFA enrollment. Add Apple and Google social connectors using the region's
   own credentials. Disable automatic linking by email. Do not require a social user
   to add an email as an extra onboarding step. A passkey can be added later.
4. Use the region's SMTP connector for OTP. The regional email path must use regional
   DNS, delivery and storage and must work with Apple, Google and Logto Cloud unreachable.
   Host sign-in assets locally, remove externally hosted fonts and analytics, and avoid
   a global CAPTCHA dependency. Social sign-in may be unavailable while email remains
   usable; the application must not switch identity domains.
5. Enable Account API and hosted Account Center. Allow editing name, email, social
   connections and passkeys. Keep server-side verification for sensitive changes.
   Hide password, phone, custom data, Secret Vault, account deletion and session actions
   that are not supported by this product. Account Center links use `/account/profile`.
   Linking starts from an authenticated account and verifies ownership of the other
   login method; identical email strings alone must never merge accounts or libraries.
6. Include `openid profile email offline_access` scopes. Configure Logto to include the
   requested name and verified email in ID tokens if those claims are to be displayed.
   The native app verifies signature, issuer, audience, expiry, nonce and the resource
   token's subject, then stores only the minimal profile in its device-only credential
   store. It never stores the raw ID token. Profile edits appear at the next sign-in.
7. Set API `OIDC_ISSUER` and `OIDC_JWKS_URL` from that tenant's discovery document,
   `OIDC_CLIENT_ID` to the native app ID, `OIDC_AUDIENCE` to the resource origin and
   `OIDC_SCOPES=openid profile email offline_access`. Library mutations always require
   a signed device challenge. No IdP assurance value or passkey enrollment substitutes
   for possession of the library key.

Apply server schema migration `0002_library_action_proof.sql` with the owner migration
runner before starting the new binary (`docker compose run --rm migrate` in the
server directory for the Compose stack). It supports schema 2. The additive migration
preserves records, recovery envelopes, identities and cursors. See ADR 0004.

Apple build settings are illustrated in the two `.xcconfig.example` files. Android uses
`-PSNIPPETS_CLOUD_URL`, `-PSNIPPETS_OAUTH_CALLBACK_HOST`,
`-PSNIPPETS_CLOUD_ACCOUNT_CENTER_URL` and `-PSNIPPETS_CLOUD_ENABLED=true` only for an
acceptance build. No endpoint input is exposed in production account UI.

## Provider acceptance gate (requires operator-owned endpoints and credentials)

Run separately for Cloud and OSS; use disposable test accounts and libraries, never the
user's existing snippets. The repository unit/database lanes cannot prove IdP behavior.

- Email OTP: new and returning account, wrong/expired/replayed code, cancellation,
  browser/process interruption and retry. Verify Apple and Google cancellation/login,
  adding an optional passkey, and that no mandatory enrollment blocks a new library.
- Confirm resource JWT `iss`, `aud`, `client_id`, 300-second lifetime and JWKS rotation;
  ID-token signature/nonce/audience/subject validation; rotated refresh tokens, expired
  grant, provider revocation and immediate API denylist after disconnect.
- Same email in separate issuers stays separate. Linking requires both accounts'
  verification; changing email does not change `sub` or create a new library. Account
  Center browser logout alone is not native-device revocation.
- New library → sync without saving recovery → restart → reminder remains → save and
  verify kit. Disconnect with an unsaved-kit warning remains possible. Local snippets
  survive. Reveal on every platform requires fresh local device-owner authentication.
- Mac/iPhone/iPad/Android pairing in both directions, recovery restore, altered QR,
  mismatched confirmation code, expired invitation, competing initial bootstrap and
  response loss during recovery replacement. A restarted pending approval asks for
  local authentication again. Unsigned key mutations fail even with a fresh passkey login.
- Block external/global identity and SMTP destinations for the regional lane. Verify
  email OTP, refresh, new-library bootstrap, pairing, recovery and account settings via
  regional services; inventory browser asset requests as well as server egress.
- Inspect exported diagnostics: no profile data, token, root, recovery material,
  ciphertext, record IDs or stable identity hashes.

Sources: [Logto deployment](https://docs.logto.io/logto-oss/deployment-and-configuration),
[SMTP connector](https://docs.logto.io/integrations/smtp),
[application settings](https://docs.logto.io/integrate-logto/application-data-structure),
[Account Center](https://docs.logto.io/end-user-flows/account-settings/by-account-center-ui).
