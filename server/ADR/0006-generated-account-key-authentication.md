# ADR 0006: Generated account-key authentication

- Status: implemented behind the Snippets Cloud feature flag
- Date: 2026-10-03
- Supersedes: ADR 0005's email and one-time-code login

Snippets Cloud has never been deployed, so this is a breaking replacement rather than an
additive migration. Native mode no longer collects, stores or sends email. There is no
SMTP dependency, challenge table, email rate bucket or email field in any response.

## Decision

An account is a random immutable UUID plus one server-generated **account key**. The key is
the only sign-in secret and also the only lookup handle, so users never choose it. Holding
the key is equivalent to holding the account. Library confidentiality is unchanged: an
account key, like the email code before it, grants no library-key authority. Opening an
existing library still requires an approved device or the offline recovery kit, and
recovery replacement and pairing approval still require a library-action proof.

### Key format

- Alphabet: Crockford Base32 `0123456789ABCDEFGHJKMNPQRSTVWXYZ`.
- Body: 26 symbols. Each symbol is `alphabet[byte & 31]` for one CSPRNG byte (unbiased),
  giving 130 bits. Only the server generates keys.
- Check: `h = SHA-256(ASCII "snippets-account-key-check-v1\n" || ASCII body)`,
  `v = (h[0] << 2) | (h[1] >> 6)` (ten bits), check symbols `alphabet[v >> 5]`,
  `alphabet[v & 31]`.
- Canonical/wire form: body followed by check, 28 uppercase ASCII symbols, no separators.
- Display form: seven groups of four joined by `-`.
- Client input normalization: reject input longer than 64 UTF-8 bytes; remove ASCII
  whitespace and `-`; uppercase ASCII; map `O`→`0` and `I`/`L`→`1`; then require exactly
  28 alphabet symbols with a matching check. Anything else is a local typing error and is
  never sent.

Test vectors (body → canonical → display):

```text
00000000000000000000000000 → 00000000000000000000000000HF → 0000-0000-0000-0000-0000-0000-00HF
ZZZZZZZZZZZZZZZZZZZZZZZZZZ → ZZZZZZZZZZZZZZZZZZZZZZZZZZ8R → ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZ8R
7KQF9M2XR4TDH8WBZN3CP6YE1A → 7KQF9M2XR4TDH8WBZN3CP6YE1AQ7 → 7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7
0123456789ABCDEFGHJKMNPQRS → 0123456789ABCDEFGHJKMNPQRS45 → 0123-4567-89AB-CDEF-GHJK-MNPQ-RS45
```

Normalization examples: ` 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-1aq7 ` and
`7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-IAQ7` both normalize to `7KQF9M2XR4TDH8WBZN3CP6YE1AQ7`;
`7KQF9M2XR4TDH8WBZN3CP6YE1AQ8` fails the check; any `U` is invalid.

### Server storage

The server stores only `HMAC-SHA256(IDENTITY_PEPPER, "snippets-native-account-key-v1", key)`
under a unique index. A deterministic peppered MAC is deliberate: the key is the lookup
handle, so a per-row salt cannot be found without one, and with 130 random bits a slow
password hash adds nothing. The persistent identity pepper is used, not `NATIVE_AUTH_SECRET`:
losing the auth secret must invalidate sessions, never every account. Collision at a
billion accounts is about 10⁻²¹; the unique index still turns one into a retried
generation instead of a shared account.

### Protocol

Discovery publishes `nativeAuth.flow = "account_key"`, `createAccountEndpoint`,
`signInEndpoint`, `refreshEndpoint`, `revokeEndpoint` and capability
`native-account-key-v1`. All four endpoints are on the server origin, unauthenticated,
JSON, and `Cache-Control: no-store`.

```text
POST /v2/auth/accounts   (no body)              → {"accountKey":"…","session":NativeTokenResponse}
POST /v2/auth/sign-in    {"accountKey":"…"}      → NativeTokenResponse
POST /v2/auth/refresh    {"refreshToken":"…"}    → NativeTokenResponse
POST /v2/auth/revoke     {"token":"…","tokenTypeHint":"…"} → 204
```

`NativeTokenResponse.account` is `{"id": "<uuid>"}`. A malformed or unknown key returns
`401 invalid_account_key`. Account creation returns its key exactly once and never
again. A lost creation response leaves an orphan account with no library; the client
simply creates another. Sessions, refresh rotation, family reuse revocation, the
denylist and the data plane are unchanged from ADR 0005.

Rate limits are PostgreSQL rows shared by replicas: account creation 10/source-IP/hour and
1,000/deployment/hour; sign-in 300/source-IP/hour and 10,000/deployment/hour; refresh is
unchanged. Online guessing is irrelevant at 130 bits; these budgets bound storage and
CPU. The trusted-proxy client-IP rules apply to create, sign-in and refresh.

## Client contract

All four clients (macOS, iOS/iPadOS, Android, Linux) present the same native flow:

- Signed out: **Create Account** and **Sign In with Account Key**. No email field exists.
- **Create Account** calls the create endpoint, journals the issued grant exactly as an
  interactive sign-in did, then shows **Save Your Account Key** with the display form in a
  monospaced, selectable presentation, **Copy**, and an explicit **I've Saved It**
  acknowledgement before continuing. Copy text: “This key is the only way to sign in to
  this account on another device. Snippets can't recover it or send it to you. Store it in
  your password manager.”
- **Sign In with Account Key** is one field plus **Sign In**. Local validation uses the
  normalization above. A local failure says “This isn't a valid account key. Check it for
  typos.”; `invalid_account_key` says “That account key wasn't accepted. Check it and try
  again.” Rate limiting keeps the existing wait/retry copy.
- The key is stored with the session in the platform's existing device-only secret storage
  and removed with it on sign-out. The signed-in account screen shows **Account ID** as the
  first eight hex digits of the account UUID, uppercase, as `XXXX-XXXX`, and offers
  **Show Account Key**. Where the platform already gates recovery-kit disclosure behind
  device-owner authentication, the same gate protects this disclosure. The sign-out
  confirmation adds “You'll need your account key to sign in again.”
- Clipboard copies of the key follow the recovery-kit rules: expiry or conditional clear
  after two minutes where supported.
- Keys never enter diagnostics, logs, exports, analytics, crash reports, UI test
  fixtures that persist, or backups. Diagnostic operations are `account_create` and
  `account_sign_in`; the failure family adds `invalid_account_key` and drops email/code
  values.

## Consequences

- No email means no account recovery, no contact channel and no support-side ownership
  proof. Losing every device and the saved key loses the account. This matches the
  existing library model, where losing every device and the recovery kit already loses
  the library.
- The server holds no personal identifier for native accounts.
- Account creation is cheap. Per-IP and deployment budgets bound it now; platform
  attestation or proof-of-work is a launch-time decision.
- A leaked key grants persistent account access until rotation exists. The data stays
  end-to-end encrypted, but an attacker could consume quota or submit records.

## Deliberately future work

- Key rotation. It needs a two-phase server-generated replacement so a lost response
  cannot lock the account out, and it must revoke every other session family.
- ~~Adding a device by scanning a QR code~~: superseded by
  [ADR 0007](0007-device-approved-sign-in.md), where an approved device signs the new one in
  without transferring the account key.
- Silent re-authentication with the stored key after the fixed 30-day refresh family
  expires.
