# 04 - Snippets Cloud (HTTP provider) porting brief

For engineers re-implementing the Snippets Cloud provider in pure Kotlin under `com.khm.snippets.core.cloud` (wave 5 of
`snippets-android/docs/PLAN.md`). The provider is dark-launched: off unless a build flag and a pinned origin are both
supplied.

The Swift code is the behavioural reference. The old Android client under `app/` is a second reference for storage shape
and JVM crypto calls, but it delegated the library authority signature and the merge to Swift over JNI
(`CoreBridge.kt:20-43`) and does not use the shared sync engine. Disagreements are called out with the side to follow.
Paths are relative to the repository root. Pointer shorthand:

| Short | File |
| --- | --- |
| `T` | `snippets/Core/SnippetsCloudTransport.swift` |
| `K` | `snippets/Core/SnippetsCloudAccountKey.swift` |
| `B` | `snippets/Core/LibraryKeyBootstrap.swift` |
| `C` | `snippets/Sync/SnippetsCloudBootstrapClient.swift` |
| `A` | `snippets/Sync/SnippetsCloudAccountBootstrap.swift` |
| `F` | `snippets/Sync/SnippetsCloudAccountKeySignInFlow.swift` |
| `S` | `snippets/Sync/SyncBackendSelectionStore.swift` (contains `SnippetsCloudNativeAuthClient`, line 1809) |
| `KS` | `snippets/Sync/SyncKeyStore.swift` (`SnippetsCloudKeyStore`, line 273) |
| `ST` | `snippets/Core/SyncTransport.swift` |
| `oH` | `app/src/main/java/com/khm/snippets/android/HttpSyncClient.kt` |
| `oA` | `app/src/main/java/com/khm/snippets/android/CloudAuthenticator.kt` |
| `oP` | `app/src/main/java/com/khm/snippets/android/NativeCloudProtocol.kt` |
| `oB` | `app/src/main/java/com/khm/snippets/android/LibraryKeyBootstrap.kt` |
| `oR` | `app/src/main/java/com/khm/snippets/android/SnippetRepository.kt` |
| `oM` | `app/src/main/java/com/khm/snippets/android/Models.kt` |
| `API` | `api/snippets-sync-v2.yaml` (normative OpenAPI 3.1, version 2.1.0) |

## 1. Component map

| Reference file | Purpose | Kotlin target (section 17) |
| --- | --- | --- |
| `T` (786 lines) | `SyncTransport` over `/v2/spaces/{space}`: scope preflight, paged pull, chunked CAS push, feed-rotation adoption, error mapping | `CloudTransport` |
| `K` (121) | Account key parse, normalise, check symbols, display form, redaction | `AccountKey` |
| `B` (890) | Portable key bundle, pairing and recovery crypto, QR payload codecs, device-sign-in codecs, library action authority (Ed25519) | `KeyBundle`, `PairingCrypto`, `RecoveryCrypto`, `CloudPayloads`, `LibraryAuthority` |
| `C` (653) | Space-scoped control-plane HTTP: recovery envelope, key authority, challenges, pairings, device-request approval | `BootstrapClient` |
| `A` (1443) | Onboarding state machine, durable intents, recovery-kit verification status, sign-out gate | `CloudOnboarding` |
| `F` (196) | Sheet-owned request runner: local key validation, device-approval poll loop, copy strings | `SignInFlow` |
| `S` 1809-3568 | Discovery, create/sign-in/refresh/revoke, session storage, credential journals, library selection | `AuthClient`, `SessionStore`, `CredentialJournal`, `SpaceResolver` |
| `S` 102-290, 400-491, 1221-1400, 1447-1589 | Feature flag, pinned origin, coordinates, local erase, transport construction, provider state location | `CloudFeature`, `CloudCoordinates`, app layer |
| `KS` 266-420 | Device-only store of the 64-byte library root bound to server, space, instance, protocol | `CloudKeyStore` (app-side Keystore wrap) |
| `snippets-ios/CloudAccountKeySignInViewController.swift` (784) | Native sheet, QR rendering, secret clipboard rule, reveal screen | app UI, not `:core` |

Server and contract: `API`, `server/README.md`, `server/ADR/0006-generated-account-key-authentication.md`,
`server/ADR/0007-device-approved-sign-in.md`. Other ADR titles: 0001 Swift HTTP sync service bootstrap, 0002 Go HTTP sync
service, 0003 Production schema lifecycle, 0004 Account login and encrypted library access, 0005 Native email and one-time
code authentication (superseded by 0006).

## 2. Build flags and origin pinning

- Old Android Gradle properties (`app/build.gradle.kts:20-34`): `SNIPPETS_CLOUD_ENABLED` (`true`/`false`, default `false`,
  any other value fails the build) and `SNIPPETS_CLOUD_URL` (default empty). Both become `BuildConfig` fields. Build
  example: `./gradlew :app:assembleDebug -PSNIPPETS_CLOUD_ENABLED=true -PSNIPPETS_CLOUD_URL=https://sync.example.com`
  (`docs/android/IMPLEMENTATION.md:116-123`).
- Apple equivalents are build settings `SNIPPETS_CLOUD_ENABLED` (default `NO`) and `SNIPPETS_CLOUD_BASE_URL` (default
  empty), surfaced as Info.plist keys `SnippetsCloudEnabled` and `SnippetsCloudBaseURL` (`S:107-121`, `S:1389-1400`,
  `Snippets.xcodeproj/project.pbxproj:1032-1033`). Note the name difference: Android uses `_URL`, Apple `_BASE_URL`.
- Both must be set. The flag alone or the URL alone leaves the provider disabled (`S:102-106`). There is no runtime field
  that can change the origin. Disabled means: the provider is not listed (`S:679`), no account UI, no discovery request,
  no key creation; every entry point fails closed with `featureDisabled` / `cloud_feature_disabled` (`S:1332`,
  `oR:1750-1752`, test `AndroidBoundaryTest.disabledCloudFeatureFailsClosedBeforeNetworking`).
- Pinned-origin normalisation: HTTPS, host present, no user info, query or fragment; trailing slashes removed
  (`S:1389-1400`, `S:3526-3538`, at most 2,048 bytes). Old Kotlin additionally requires an empty path (`oP:335-343`);
  Swift `LibraryActionAuthorization` also requires an empty path (`B:843`). Treat "origin only, no path, no trailing
  slash" as the rule.
- Every credential-bearing request must target that exact origin. Old Kotlin checks scheme, host and port on each request
  (`oA:463-468`); Swift checks `response.url == request.url` and refuses redirects (`T:495-497`, `T:673-689`, `S:3399`,
  `S:3570`).

## 3. HTTP conventions

- JSON only. Requests: `Accept: application/json`; `Content-Type: application/json` only when a body is sent;
  `Authorization: Bearer <access token>` on authenticated calls (`T:450-462`, `C:575-581`). No `X-Snippets-Protocol`
  header (`docs/android/sync-server.md:69-72`).
- The server rejects unknown, duplicate or case-colliding members, trailing values, compressed bodies, bodies on bodyless
  operations, and non-canonical standard Base64 (`server/README.md:166-171`). Nullable members that the schema lists as
  required must be sent as explicit `null`: `expectedRecordVersion` (`T:747-766`), `expectedVersion` (`C:124-139`).
  `org.json`'s `put(name, null)` removes the member; use `JSONObject.NULL` or an encoder that emits nulls (`oH:157-161`).
- Binary fields in API bodies are standard Base64 with padding (`recipientPublicKey` 88 chars, `nonce` 44,
  `recipientKeyHash` 44, `requestHash` 44, `signature` 88, `publicKey` 44; `API:462-463`, `API:715`, `API:767`, `API:782`,
  `API:792`). QR payloads and envelope JSON use unpadded Base64url instead (section 12).
- UUIDs in paths and bodies are lowercase (`T:530-532`, `C:356`, `C:360-361`).
- Redirects are never followed. A redirect is a failure.
- No cookies, no HTTP cache (`T:520-528`, `S:2010-2015`).
- Timeouts and response ceilings:

| Call | Timeout | Response ceiling | Pointer |
| --- | --- | --- | --- |
| Data plane (space, changes, batch) | 30 s | 16 MiB | `T:448`, `T:518` |
| Bootstrap control plane | 30 s | 64 KiB | `C:578`, `C:624` |
| Discovery | 15 s | 256 KiB | `S:3466`, `S:3332` |
| Native auth POST (create, sign-in, refresh, device request, claim) | 20 s | 256 KiB | `S:3380`, `S:3397` |
| Revoke, `DELETE /v2/session` | 20 s | 256 KiB | `S:2942`, `S:2967-2974` |
| `GET/POST /v2/spaces`, `GET /v2/spaces/{id}` during sign-in | 20 s | 1 MiB | `S:3441`, `S:3448` |

  Old Kotlin differs: connect 15 s / read 30 s and a single 16 MiB ceiling for every bearer call (`oH:572-573`, `oH:773`);
  auth connect and read 15 s, 256 KiB (`oA:472-473`, `oA:526`). Follow Swift's per-call ceilings.
- Errors: `application/problem+json` with members `type` (`urn:snippets:error:<code>`), `status`, `code`, `requestId`,
  optional `retryAfterSeconds`, `limit` (`API:746-756`). Clients read only `code` (and `retryAfterSeconds` on the data
  plane, the `Retry-After` header on native auth). An unparseable error body becomes `http_<status>` (`T:651`,
  `C:595-596`). The response also carries `X-Request-ID` (`server/README.md:168-170`); clients do not use it.
- Dates from the server are RFC 3339 with or without fractional seconds; reject anything else and anything over 64 bytes
  (`C:539-546`).

## 4. Endpoints

All paths are relative to the pinned origin. `Scope` is `{serverInstanceId, spaceId, scopeBinding, datasetGeneration,
feedEpoch}` (three UUIDs plus a 32-256 byte opaque string, `API:567-576`). "Auth" is `Bearer` unless marked none.

| Method and path | Auth | Request | Success response |
| --- | --- | --- | --- |
| `GET /.well-known/snippets-sync` | none | - | 200 `Discovery` (section 5) |
| `POST /v2/auth/accounts` | none | no body at all | 200 `{accountKey, session: NativeTokenResponse}` |
| `POST /v2/auth/sign-in` | none | `{accountKey}` (28-symbol canonical) | 200 `NativeTokenResponse` |
| `POST /v2/auth/refresh` | none | `{refreshToken}` | 200 `NativeTokenResponse` |
| `POST /v2/auth/revoke` | none | `{token, tokenTypeHint}`; hint is `access_token` or `refresh_token` | 204 empty |
| `DELETE /v2/session` | Bearer | - | 204 empty (401 is also treated as done, `S:2977-2978`) |
| `POST /v2/auth/device-requests` | none | `{recipientPublicKey, nonce}` | 200 `{requestId, pollToken, expiresAt}` |
| `POST /v2/auth/device-requests/{id}/approval` | Bearer | `{spaceId, pairingId}` | 204 empty |
| `POST /v2/auth/device-requests/{id}/claim` | none | `{pollToken}` | 200 `{state:"pending", expiresAt}` or `{state:"approved", expiresAt, spaceId, pairingId, session}` |
| `GET /v2/spaces` | Bearer | - | 200 `{spaces:[Space]}` (at most 100) |
| `POST /v2/spaces` | Bearer | no body; header `Idempotency-Key: <uuid>` | 201 `Space` |
| `GET /v2/spaces/{space}` | Bearer | - | 200 `Space` = `{scope, role, keyEpoch}`; role is `owner`, `writer` or `reader` |
| `GET /v2/spaces/{space}/changes?limit=&cursor=` | Bearer | - | 200 `{scope, records:[ServerRecord], cursor, hasMore, fullSnapshot}` |
| `POST /v2/spaces/{space}/records/batch` | Bearer | `{expectedScope, items:[{record:{id,rev,deleted,blob}, expectedRecordVersion}]}` | 200 `{scope, outcomes:[BatchOutcome], partial}` |
| `GET /v2/spaces/{space}/recovery-envelope` | Bearer | - | 200 `{scope, keyEpoch, recovery}`; `recovery` is null or `{purpose, version, keyEpoch, algorithm, ciphertext, createdAt}` |
| `PUT /v2/spaces/{space}/recovery-envelope` | Bearer | `{proof, expectedVersion, keyEpoch, algorithm, ciphertext}` | 200 same shape as GET |
| `GET /v2/spaces/{space}/key-authority` | Bearer | - | 200 `{scope, keyEpoch, publicKey}` (`publicKey` null before bootstrap) |
| `POST /v2/spaces/{space}/key-bootstrap` | Bearer | `{expectedScope, publicKey, recovery:{expectedVersion:null, keyEpoch, algorithm, ciphertext}}` | 200 recovery-envelope shape |
| `POST /v2/spaces/{space}/key-challenges` | Bearer | `{expectedScope, action, keyEpoch, requestHash}`; action is `replace_recovery` or `approve_pairing` | 200 `{scope, challenge:{challengeId, action, keyEpoch, requestHash, nonce, expiresAt}}` |
| `POST /v2/spaces/{space}/pairings` | Bearer | `{recipientPublicKey, nonce, expiresInSeconds}` (60-600) | 201 `{scope, pairing}` |
| `GET /v2/spaces/{space}/pairings/{pairing}` | Bearer | - | 200 `{scope, pairing}` (ciphertext redacted) |
| `DELETE /v2/spaces/{space}/pairings/{pairing}` | Bearer | - | 204 |
| `PUT /v2/spaces/{space}/pairings/{pairing}/approval` | Bearer | `{proof, recipientKeyHash, algorithm, ciphertext}` | 200 `{scope, pairing}` |
| `POST /v2/spaces/{space}/pairings/{pairing}/claim` | Bearer | no body | 200 `{scope, pairingId, algorithm, ciphertext}` |

`key-authority`, `key-bootstrap` and `key-challenges` are in `API:196-241` and used by both clients, but are missing from
the route lists in `docs/android/sync-server.md:34-55` and `server/README.md:138-152`. The OpenAPI file is the authority.

Shapes:

- `NativeTokenResponse` = `{access_token, refresh_token, expires_in (1-300), token_type:"Bearer", account:{id:<uuid>}}`
  (`API:514-523`). These four members are snake_case; everything else is camelCase.
- `ServerRecord` = `{id, rev, deleted, blob, recordVersion}`; `blob` standard Base64 at most 1,200,000 characters; `rev`
  1-256; `recordVersion` 32-2,048 characters (`API:594-603`).
- `BatchOutcome` = `{kind, recordVersion?, revision?, authoritativeRecord?, errorCode?, retryAfterSeconds?}`, `kind` in
  `accepted`, `conflict`, `rejected` (`API:654-664`). Outcomes are positional.
- `Pairing` = `{pairingId, recipientPublicKey, nonce, authenticationTag, state, algorithm?, expiresAt}`, `state` in
  `pending`, `approved` (`API:725-736`).
- `LibraryActionProof` = `{challengeId, signature}` (`API:761-767`).

## 5. Discovery and feature gating

`GET /.well-known/snippets-sync`. Accept only when all of the following hold (`S:3330-3357`); otherwise fail with the
"insecure server profile" class and send nothing else:

- `protocolMajor == 2`; `serverInstanceId` is not the zero UUID; `recordProfile == "snippets-wire-v1"`; `apiBase ==
  <origin>/v2`.
- Limits exactly: `maxBlobBytes 900000`, `maxRevisionBytes 256`, `maxBatchRecords 50`, `maxPageRecords 50`,
  `maxRequestBytes 16777216`, `maxResponseBytes 67108864`, `maxKeyEnvelopeBytes 4096`, `maxPairingSeconds 600`.
- `capabilities`: 1-16 entries, unique, each 1-64 bytes, and containing all of `native-account-key-v1`,
  `library-action-proof-v1`, `pairing-v2`, `offline-recovery-v1`, `resource-session-revocation`.
- `nativeAuth.flow == "account_key"` and the four endpoints equal exactly `<origin>/v2/auth/accounts`, `/v2/auth/sign-in`,
  `/v2/auth/refresh`, `/v2/auth/revoke`.
- Optional capability `native-device-sign-in-v1` (`B:18`) gates **Sign In with Another Device**. Its endpoints are fixed
  paths, never read from discovery (`oP:17-21`).

Swift/Kotlin differences: old Kotlin does not check limits, `recordProfile`, the zero instance or capability uniqueness
and allows up to 32 capabilities (`oP:33-59`). Follow Swift. `oidc` may be present in discovery and is ignored by native
clients.

Discovery runs once, after the first explicit Create Account / Sign In / device action, never merely because the sheet
appeared (`S:2076-2097`). The device-sign-in availability probe is the one exception: a discovery read with no credential
access (`F:114-119`, `S:2156-2159`).

## 6. Account key (server ADR 0006)

- Alphabet (Crockford Base32, no `I L O U`): `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (`K:27`).
- Body 26 symbols (130 bits, server generated only). Check: `h = SHA-256("snippets-account-key-check-v1\n" || body)`, `v =
  (h[0] << 2) | (h[1] >> 6)`, check symbols `alphabet[v >> 5]`, `alphabet[v & 31]` (`K:99-106`, `oP:110-118`).
- Canonical / wire form: body + check, 28 uppercase ASCII symbols. Regex in the contract: `^[0-9A-HJKMNP-TV-Z]{28}$`
  (`API:443`).
- Display form: seven groups of four joined by `-` (`K:39-44`).
- Input normalisation (`K:50-73`): reject more than 64 UTF-8 bytes; drop bytes `0x09-0x0D`, `0x20` and `-`; uppercase
  ASCII `a-z`; map `O`->`0`, `I` and `L`->`1`; every remaining byte must be in the alphabet; exactly 28 symbols; check
  must match. Anything else (including `U` and any non-ASCII byte) is a local typing error and is never sent.
- Vectors (ADR 0006): body `00000000000000000000000000` -> `...00HF`; `ZZZZZZZZZZZZZZZZZZZZZZZZZZ` -> `...ZZ8R`;
  `7KQF9M2XR4TDH8WBZN3CP6YE1A` -> `7KQF9M2XR4TDH8WBZN3CP6YE1AQ7` (display `7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7`);
  `0123456789ABCDEFGHJKMNPQRS` -> `...RS45`. ` 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-1aq7 ` and
  `7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-IAQ7` normalise to the third; `...1AQ8` fails.
- Account ID shown in UI: first eight hex digits of the account UUID, uppercase, `XXXX-XXXX` (`K:115-120`). Library ID
  shown in UI: first four bytes of `SHA-256("<serverInstanceId lowercase>:<spaceId lowercase>")` as eight uppercase hex
  digits (`S:163-167`, `oM:234-235`).
- The key type must redact itself in `toString` and must never reach logs, diagnostics, saved-instance state, backups or
  persistent test fixtures (`K:108-110`, ADR 0006 "Client contract").

## 7. Session model

### 7.1 Tokens

- Access and refresh tokens are opaque. Swift accepts 32-512 bytes, all in `0x21-0x7E`, and requires access != refresh
  (`S:3216-3219`, `S:3359-3362`). Old Kotlin accepts 8-16,384 bytes without whitespace or control characters
  (`oP:330-333`). The contract says 1-512 (`API:519-520`). Follow Swift.
- `token_type` must be exactly `Bearer` (Swift `S:3366`; old Kotlin compares case-insensitively, `oP:264`). `expires_in`
  1-300. `account.id` must parse as a UUID.
- Local expiry = now + min(max(expires_in, 1), 300) seconds (`S:2113`). A cached access token is reused while more than 60
  s remain; otherwise refresh first (`S:2628`, `oA:216`).
- The transport retries exactly once after `401` with code `authentication_required`, calling the token provider with
  `forceRefresh = true` (`T:465-480`). Any provider failure maps to `authenticationRequired("sign_in_required")`.
- Server side: access tokens live at most five minutes; refresh tokens rotate on every use inside a fixed 30-day family;
  reusing a rotated refresh token revokes the whole family; revoking any refresh generation revokes its family; revoking
  an access token or calling `DELETE /v2/session` revokes only that credential (`server/README.md:113-122`).
- Therefore: refresh must be serialised process-wide (Swift `credentialMutationGate`, `S:1812`, `S:287-291`; old Kotlin
  repository mutex) and the new pair must be durable before the next request uses it.

### 7.2 Stored state

Swift keeps one session record and two journals in device-only Keychain; old Kotlin keeps a committed session, a pending
session and three journals as files in its Keystore-wrapped store.

| Concept | Swift (`S`) | Old Kotlin (`oA:533-537`) |
| --- | --- | --- |
| Committed session | account `oidc-session-v1`, schema 7 (`S:488`, `S:1954-1978`) | `native-cloud-session.enc`, schema 2 |
| Uncommitted candidate | held in memory until `commitCoordinates` | `native-cloud-pending-session.enc` |
| Replacement journal | `oidc-session-replacement-journal-v1` (`S:489`) | `native-cloud-replacement-journal.enc` |
| Revocation (logout intent) journal | `oidc-revocation-journal-v1` (`S:490`) | `native-cloud-revocation-journal.enc` |
| Refresh-in-flight journal | replacement journal with `replacementKind: refreshRotation` | `native-cloud-refresh-journal.enc` |
| Local-erase marker | `cloud-local-erase-v1`, value `pending` (`S:491`, `S:1261-1263`) | `cloud-local-erase.enc` (`oR:2575`) |

Session contents that matter: account UUID, canonical account key or null (a device signed in by another device), origin,
server instance, protocol major 2, access token, refresh token, expiry. Swift re-validates on every load (`S:2724-2751`):
exact schema, `apiBase == origin/v2`, client id `native-account-key-v1`, refresh and revoke endpoints on the origin,
maximum token age 300 s, expiry at most 360 s ahead, at most 128 KiB. Older schemas are never migrated.

Journals hold token generations only (never the account key): Swift as two ordered unique lists `accessTokens` and
`refreshTokens`, 1-16 entries each, schema 2, bound to origin and revoke endpoint (`S:1980-1990`, `S:3013-3054`); old
Kotlin as a list of `{grantID, accessToken, refreshToken}` generations, 1-16, schema 1 (`oA:384-409`). A `grantID` is a
client-minted UUID per interactive grant and identifies the refresh family.

### 7.3 Rules that must hold (both implementations agree)

1. Journal first. As soon as a response contains a token pair that passes the bare token format check, write it to the
   replacement journal, with no suspension point in between, before validating `token_type`, `expires_in`, `account`, the
   returned account key or any device-claim member (`S:2098-2119`, `oP:251-260`). A rejected response must not orphan a
   live session family.
2. A new interactive grant never overwrites the committed session until library selection and the bootstrap intent are
   durable (`S:2359-2388`, `oA:265-275`).
3. Cleanup after an interactive replacement (`S:247-280`, `oP:319-328`): revoke every journaled access token except the
   current one; revoke the refresh tokens of every other grant; never revoke an earlier refresh token of the grant being
   kept (that kills the family).
4. Cleanup after a refresh (`S:2634-2684`, `oP:302-313`): if the rotated pair was committed, retire only the previous
   access token; if it was not committed or its metadata was rejected (same refresh token returned, account id changed,
   same access token), revoke the issued access and refresh tokens and drop the stored session, forcing sign-in.
5. Refresh must rotate both tokens and keep the same account UUID (`S:2673-2675`, `oP:269-275`).
6. While a logout-intent journal exists, no token is handed out and no new sign-in starts (`S:2083-2085`, `S:2616-2618`).
   While a replacement journal exists, cleanup runs before any token is handed out (`S:2615`); old Kotlin fails with
   `credential_cleanup_required` instead (`oA:211-212`).
7. Access-token retirement uses `DELETE /v2/session` with that token (204 or 401 are both success) in Swift
   (`S:2959-2982`) and `POST /v2/auth/revoke` with hint `access_token` in old Kotlin (`oA:451-457`). Swift's full logout
   does both (`S:2926-2932`). Refresh-token revocation is always `POST /v2/auth/revoke` with hint `refresh_token`,
   expecting exactly 204.

### 7.4 Sign-out (disconnect this device)

Order (`A:853-879`, `S:1221-1329`, `oR:1192-1233`):

1. If a local-erase marker exists, resume the erase and stop.
2. Refresh recovery-kit status against the server. `knownReplaced` and `replacementInProgress` block sign-out; a status
   that cannot be confirmed blocks with "recovery status unconfirmed"; `verifiedCurrent` and `neverVerified` proceed.
3. Merge the committed session and both journals into the revocation journal, persist it, revoke every access token, then
   every refresh token. Do not refresh during logout.
4. Write the local-erase marker (the commit point).
5. Erase in this order: library root key, bootstrap intents, tokens and journals, provider switch receipts, coordinates;
   set the provider back to its default; remove the marker last. Every step is idempotent and re-run on launch.

Sign-out never deletes remote data (`docs/android/provider-switching.md:315-327`). The sign-out confirmation adds "You'll
need your account key to sign in again." (`F:44`).

## 8. Library (space) selection

After a grant (`S:3226-3328`, `oH:228-287`, `S:170-180`):

1. `GET /v2/spaces`. Every entry must carry the discovered `serverInstanceId`, a 32-256 byte `scopeBinding` and a known
   role, else fail closed.
2. Writable = `owner` or `writer`. If spaces exist but none is writable: "read-only library".
3. Automatic choice: the existing space if it is still writable; otherwise the only writable space. With an account change
   and a different space, ask for confirmation even then.
4. More than one writable candidate: explicit chooser (`space_selection_required`).
5. None at all: `POST /v2/spaces` with `Idempotency-Key: 7b28d156-77fd-4f7f-bdf3-234f7d97ac91` (a fixed constant in both
   clients, `S:3300`, `oH:774`); the result must be writable.
6. Always re-read `GET /v2/spaces/{id}` and require the same instance, id, binding and a writable role before committing.

Coordinates persisted after commit: origin, `apiBase`, space UUID, server instance UUID, protocol major (`S:400-406`,
defaults keys `S:475-479`). Old Android configuration schema 4 adds cursor, `scopeBinding`, `datasetGeneration`,
`feedEpoch` (`oM:41-56`, `oM:472-486`); in the new app the cursor and identities belong to the engine's provider base, not
to configuration. A stored configuration with protocol 2 but no server instance fails closed with `scope_review_required`
(`oM:62-64`, `docs/android/sync-server.md:63-67`).

## 9. Data plane and mapping to the engine transport

Transport constants: `identifier = "snippets-cloud"`, `supportsPush = true`, `pollInterval = 60 s`, no round pacing, an
event stream that finishes immediately (`T:58-61`, `T:81`). Engine protocol: `ST:546-643`.

### 9.1 Identities

Both are SHA-256 over the concatenation of fields, each prefixed with its UTF-8 length as a big-endian `UInt32`
(`T:546-613`):

- account identity: `"snippets-cloud-membership-v2"`, origin string, `"2"`, instance UUID lowercase, space UUID lowercase,
  `scopeBinding`;
- dataset identity: `"snippets-cloud-dataset-v2"`, the same five, then `datasetGeneration` lowercase.

`feedEpoch` is in neither. Provider state directory key (journal, base, quarantine): first 16 bytes, lowercase hex, of
`SHA-256("snippets.sync.provider.v1\0http\0<origin lowercased>\0<instance>\0<space>\0<major>")` (`S:1572-1589`).

### 9.2 Preflight

`preflightScope()` = `GET /v2/spaces/{space}`; instance mismatch -> `accountChanged`; space mismatch ->
`unreachable("invalid_scope_response")` (`T:324-334`). First call pins scope and identity. Later calls adopt a new scope
only if account identity and dataset identity are unchanged (a feed rotation); otherwise the old pin stays so the engine
sees the difference and runs its explicit review (`T:88-115`). `legacyAccountIdentities` is always empty.

### 9.3 Pull

`GET .../changes?limit=10[&cursor=<raw cursor>]` (`T:348-358`, `T:519`). The limit is 10, not the protocol's 50, so ten
maximum-size blobs stay under the 16 MiB client ceiling.

- `cursor == nil` requires `fullSnapshot == true`, else `permanent("incomplete_full_snapshot")`.
- `cursor_invalid`: retry once with no cursor; require `fullSnapshot`; adopt the feed rotation (same instance, space,
  `scopeBinding`, `datasetGeneration`); report `replacesPriorPages = true`.
- Validate every page's scope against the pinned identity, dataset and exact pinned scope (`T:360-381`): different binding
  -> `accountChanged`; different dataset -> `remoteDataReset("dataset_reset")`; scope differs from the pin in any other
  way -> `unreachable("feed_changed_during_response")`.
- Result: records in server order, `cursor` opaque, `cursorKind = legacy`, `hasMore`, `isFullResync = fullSnapshot`. A
  full snapshot is a snapshot: never infer deletion from absence.
- `recordVersion` is the server string stored as its UTF-8 bytes in `SyncRecordVersion` (schema 1); old Kotlin's JSON form
  is `{"schemaVersion":1,"data":"<base64 of UTF-8>"}` (`T:722-729`, `oH:689-697`).

### 9.4 Push (per-record CAS)

- Engine batch: 1-50 records; each blob at most 900,000 bytes and `rev` at most 256 UTF-8 bytes, else
  `permanent("invalid_batch_size" | "record_too_large")` before any request (`T:159-164`).
- Split into HTTP messages of 10. Each item sends `record {id, rev, deleted, blob}` (no `recordVersion` inside the record)
  and `expectedRecordVersion`: the stored version string (32-2,048 bytes) or explicit `null` for a create.
- `expectedScope` is the full pinned scope; the server checks it before any mutation.
- `cursor_invalid` on a chunk: re-read the space, adopt feed rotation, resend that chunk once. `forbidden`: re-read the
  space (so an instance change surfaces as `accountChanged`) and rethrow.
- A response scope different from the one sent may only be a feed rotation; adopt it for the following chunks.
  `outcomes.count` must equal the chunk size.
- Outcome mapping (`T:624-648`): `accepted` needs both `revision` and `recordVersion` -> `.accepted`; `conflict` ->
  `.rejected(.conflict(remote: authoritativeRecord))`; `rejected` with `authentication_required` -> auth required, with
  `rate_limited` -> rate limited (`retryAfterSeconds` or 60), anything else -> `permanent(errorCode ??
  "record_rejected")`.
- The returned submission cursor is the cursor passed in; the transport does not advance it.

Old Kotlin differs materially and must not be copied (hazard 12): it pages, merges and retries outside any engine
(`oH:84-212`, `oR:1682-1726`). The new client implements `SyncTransport` as Swift does; the shared engine owns merge,
retries and base advancement.

### 9.5 Call-level error mapping (`T:650-670`)

| Server code | Engine failure |
| --- | --- |
| `authentication_required`, `reauthentication_required` | `rejected(authenticationRequired(code))` |
| `rate_limited` | `rejected(rateLimited(retryAfterSeconds ?? 60))` |
| `dataset_reset` | `remoteDataReset(code)` |
| `server_identity_changed` | `rejected(authenticationRequired(code))` |
| `cursor_invalid` | internal; handled as in 9.3 / 9.4 |
| `dependency_unavailable` with status >= 500 | `unreachable(code)` |
| anything else, including `http_<status>` | `rejected(permanent(code))` |
| network error, oversized or redirected response | `unreachable("network_request_failed" | "response_too_large" | "invalid_http_response")` |
| undecodable 2xx body | `unreachable("invalid_json_response")` |

`server_identity_changed` is handled by the client but is not in the contract's `ErrorCode` enum (`API:757-759`); see Open
questions.

### 9.6 Review resets

`resetAfterAccountReview`, `resetAfterCheckpointReview`, `resetAfterRemoteDataResetReview` and `resetForLocalFullResync`
all re-read the space, require the expected account identity (else `accountChanged`) and the expected dataset identity
(else `remoteDataReset`), then re-pin (`T:233-305`). The HTTP transport has no private checkpoint; the cursor lives in the
engine base.

## 10. Binding and scope stickiness

- Three layers are pinned independently: origin (build), server instance (discovery, then every scope), membership
  (`scopeBinding`), dataset (`datasetGeneration`). Only `feedEpoch` may change silently.
- Any other change is a sticky review halt owned by the engine: account or instance change -> account review; dataset
  change or `dataset_reset` -> remote-reset review. Never auto-attach, never repopulate a reset remote from the local
  cache without the explicit action (`docs/android/provider-switching.md:283-297`).
- Before bootstrap continues after any sign-in or library change, check whether the engine's existing provider state is
  "meaningful" and bound to another account or dataset (`A:1366-1426`): unreadable or too-new state, a halt, or an
  identity mismatch discards all pending bootstrap intents except the post-authorization marker.
- The library root key is stored together with origin, space, instance and protocol major and is returned only when all
  four match (`KS:334-349`). A schema-1 record without the instance reads as absent.
- One writer per local library: the cloud transport must not run alongside another provider; switching awaits the old
  transport's shutdown barrier (`docs/android/provider-switching.md:10-14`).
- Data-plane tokens are refused while a post-authorization marker, a local-erase marker or a revocation journal exists
  (`S:1331-1369`, `S:1447-1473`); the control plane may still obtain a token to finish the marker.

## 11. Library key, authority key and action proofs

- Root material: 64 bytes = 32-byte wire key followed by 32-byte salt, crypto scope id `sync-v1` (`B:36-48`). It encrypts
  wire records exactly as other providers do (see the crypto brief); nothing in this document changes record encryption.
- Portable bundle JSON (the plaintext inside pairing and recovery envelopes), sorted keys, no escaped slashes, at most
  2,048 bytes, exactly these four members (`B:50-87`): `{"key":"<std Base64, 44 chars>","salt":"<std Base64, 44
  chars>","schemaVersion":1,"scopeID":"sync-v1"}`. The shared recovery vector decrypts to a 146-byte plaintext, consistent
  with this form.
- Authority key (`B:835-864`): Ed25519. Seed = HKDF-SHA-256(IKM = material[0..32), salt = material[32..64), info = UTF-8
  of `"snippets-library-action-signing-v1\n" + origin + "\n" + instance lowercase + "\n" + space lowercase`, 32 bytes).
  Public key = raw 32 bytes. Origin must be `https`, no path, no trailing slash.
- Proof (`B:866-875`): Ed25519 signature (64 bytes) over `"snippets-library-action-proof-v1\n" || nonce(32 bytes)`; sent
  as `{challengeId, signature}`.
- Request hashes (SHA-256 of newline-joined UTF-8, `B:877-889`):
  - recovery: `snippets-recovery-action-v1`, keyEpoch, expectedVersion or the literal `null`,
    `snippets-recovery-hkdf-sha256-aes256gcm-v1`, std Base64 of the ciphertext;
  - pairing: `snippets-pairing-action-v1`, pairing UUID lowercase, std Base64 of SHA-256(recipient public key),
    `snippets-pairing-p256-hkdf-sha256-aes256gcm-v1`, std Base64 of the ciphertext.
- Challenge sequence (`C:289-313`): `GET key-authority` (scope valid, `keyEpoch` equal, `publicKey` equal to the locally
  derived key) -> `POST key-challenges` with that scope -> require the same scope, action, epoch and hash, a 32-byte
  nonce, and expiry in (0, 330] s -> sign.
- `verifyAuthority(material)` after pairing claim, recovery restore and first bootstrap: `key-authority.publicKey` must
  equal the derived key before the material is installed (`C:256-261`, `A:619`, `A:717`, `A:1133`).
- Vector (`Tests/Core/LibraryKeyBootstrapTests.swift:11-32`, `AndroidBoundaryTest.kt:52-66`): material bytes 0..63, origin
  `https://sync.example`, instance `10000000-0000-0000-0000-000000000001`, space `20000000-0000-0000-0000-000000000001` ->
  public key `BpJCgx4cUQSQFyZtp9NGBSH/vu8g+LUff0Gzc60K4kc=`; nonce 32 bytes of `0x07` -> signature
  `SpmC5BUDjmvaeUhXOjcTs6NtUfD+ncwuUbzstz3x7AqqSNwKasvgalPp0F0Ly8JKPW+qqzodsPyV8VuMniznCw==`.

## 12. Payload and envelope formats (byte-exact)

Common rules (`B:717-736`, `B:788-808`): compact JSON, keys sorted lexicographically, `/` not escaped, binary as unpadded
Base64url that must round-trip exactly, UUIDs lowercase, origin without trailing slash, at most 4,096 UTF-8 bytes, parsing
requires exactly the listed keys.

Pairing invitation QR (schema 2, `B:137-148`, `B:660-669`):

```json
{"expiresAt":<epoch s>,"kind":"snippets-pairing","nonce":"<b64url 32B>","pairingId":"<uuid>","recipientPublicKey":"<b64url 65B>","schemaVersion":2,"server":"https://...","spaceId":"<uuid>"}
```

Device sign-in QR (schema 1, `B:313-322`, `B:671-679`):

```json
{"expiresAt":<epoch s>,"kind":"snippets-device-sign-in","nonce":"<b64url 32B>","recipientPublicKey":"<b64url 65B>","requestId":"<uuid>","schemaVersion":1,"server":"https://..."}
```

Recovery kit QR (schema 1, `B:543-551`, `B:681-688`):

```json
{"keyEpoch":<int>,"kind":"snippets-recovery","schemaVersion":1,"secret":"<b64url 32B>","server":"https://...","spaceId":"<uuid>"}
```

Validation: `recipientPublicKey` is a 65-byte uncompressed P-256 point starting `0x04` and on the curve; `nonce` is 32
bytes; `expiresAt` must satisfy `now - 30 < expiresAt <= now + 630` (`B:169-170`, `B:277-278`). The device sign-in parser
additionally requires `server` and `requestId` to be byte-identical to their canonical forms (`B:298`, `B:310`).

Disagreement: old Kotlin emits the pairing and recovery payloads with `org.json` in insertion order (`oB:102-112`,
`oB:325-333`); only its device-sign-in payload is canonical (`oB:184-192`, hand-written encoder `oB:664-685`). Parsers on
every platform accept any key order, so interop holds, but the new client must emit the sorted, unescaped form above.

Recovery long code (`B:510`, `B:749-786`): the 32-byte secret in RFC 4648-style Base32 bit packing with alphabet
`ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, no padding, 52 symbols, shown as thirteen groups of four joined by `-`. Decoding
uppercases, strips `-` and whitespace, requires 52 symbols and an exact re-encode match. The long code carries no server,
space or epoch; those come from the signed-in coordinates and the server's current envelope (`A:701-715`). Saved-copy
challenge: the last eight alphanumeric symbols of the long code (`A:36-47`).

Confirmation code / server `authenticationTag` (`B:485-492`): first eight bytes of
`SHA-256("snippets-pairing-confirm-v1" || nonce || recipientPublicKey)`, each mapped through `ABCDEFGHJKLMNPQRSTUVWXYZ23456789[b & 31]`. Clients require the
server tag to match `^[A-Z2-9]{8}$` and equal the local derivation.

Pairing envelope (`B:559-621`), algorithm `snippets-pairing-p256-hkdf-sha256-aes256gcm-v1`:

- sender generates an ephemeral P-256 key; shared secret = ECDH x-coordinate (32 bytes);
- AAD = UTF-8 of `"snippets-pairing-v2"`, origin, space, pairing id, Base64url nonce, Base64url recipient key, joined with
  a single NUL byte (`B:697-706`);
- key = HKDF-SHA-256(IKM = shared secret, salt = the 32-byte pairing nonce, info = AAD, 32 bytes);
- AES-256-GCM, random 12-byte nonce, 16-byte tag, plaintext = bundle JSON;
- envelope bytes = `{"nonce":"<b64url 12B>","schemaVersion":1,"sealed":"<b64url ct||tag>","senderPublicKey":"<b64url
  65B>"}`, at most 4,096 bytes; sent to the server as standard Base64 in `ciphertext`.

Recovery envelope (`B:623-656`), algorithm `snippets-recovery-hkdf-sha256-aes256gcm-v1`:

- AAD = `"snippets-recovery-v1"`, origin, space, decimal keyEpoch, NUL-joined (`B:708-715`);
- key = HKDF-SHA-256(IKM = 32-byte kit secret, salt = `"snippets-recovery-salt-v1"`, info = AAD, 32 bytes);
- ciphertext bytes = `nonce(12) || ciphertext || tag(16)`, 28-4,096 bytes, raw (not JSON).
- Vector: `Tests/Core/LibraryKeyBootstrapTests.swift:108-123` (secret bytes 160..191, space
  `01234567-89ab-cdef-0123-456789abcdef`, epoch 7, material 0..63).

`recipientKeyHash` = SHA-256 of the 65-byte recipient key (`B:658`). Device poll token: `sn_d_` plus 43 Base64url symbols
encoding 32 bytes, 48 characters (`B:477-481`). Default pairing lifetime 300 s (`B:16`); device-sign-in pairing lifetime
`clamp(requestExpiresAt - now - 5, 60, 600)` (`B:469-474`).

## 13. Library-key bootstrap state machine

Durable intents (Swift Keychain accounts in service `com.khm.snippets.cloud-bootstrap.<bundle id>`, `A:250-270`; old
Kotlin files `oR:2560-2575`): recipient pairing, approval, device sign-in, device approval, pending recovery upload,
recovery presentation, recovery verification, post-authorization marker. All are device-only, excluded from backup, and
erased on sign-out.

Post-authorization marker: `{schemaVersion:1, phase:"bootstrapPending", serverURL, serverInstanceID, protocolMajor:2,
spaceID, scopeBinding, operation}` with `operation` in `signIn`, `changeAccount`, `changeLibrary` (`A:169-200`,
`A:1232-1279`). It is written before the new session is published and cleared only when bootstrap returns; while present
the data plane is fenced and the UI shows "setup interrupted" with **Resume setup**. Resume re-validates the exact
membership; a mismatch requires signing in with the account that owns that library (`A:516-553`, `S:2493-2518`).

`finishPostAuthorization(localAuthorized)` evaluates in this order (`A:891-973`):

1. Pending device approval: without fresh owner authentication return "approval ready" with the code; with it, run section
   14.2.
2. Pending pairing approval: same gate; with authentication, approve (below) and delete it.
3. No installed key and a stored recipient pairing for this origin and space: claim it (`checkPairing`).
   `pairing_expired`, `pairing_missing`, `not_found` delete it and fall through.
4. Pending recovery upload: a replacement needs owner authentication; a first bootstrap does not. Upload (below).
5. Key installed: ready.
6. `GET recovery-envelope` and `GET changes?limit=1`. If an envelope exists or any record exists: "needs a trusted device
   or recovery kit". Never mint.
7. Truly empty space: generate 64 random bytes, build a recovery envelope for the server's current `keyEpoch`, persist
   `{schemaVersion:1, kitPayload, ciphertext, expectedVersion:null, newLibraryMaterial}` (`A:161-167`), then upload.
   `conflict` here means another device won: delete the intent and go to "needs a trusted device or recovery kit".

Upload (`A:1104-1148`, `C:268-287`):

- First bootstrap: `POST key-bootstrap` with the current scope, the derived authority public key and
  `recovery.expectedVersion: null`. The response must echo version 1 and the identical ciphertext.
- Replacement: `PUT recovery-envelope` with a `replace_recovery` proof and `expectedVersion` = the version read when the
  replacement was prepared.
- Lost response: on `conflict`, re-read; treat it as success only if `keyEpoch`, algorithm and ciphertext bytes equal the
  pending ones. Otherwise surface the conflict.
- Then: verify authority, install the root key (first bootstrap only), store the kit payload as the recovery presentation,
  and delete the upload journal last.

Recovery kit presentation and verification:

- The kit (QR plus long code) is shown only after fresh device-owner authentication, and that authorisation is single-use
  per presentation (`A:22-34`, `A:416-432`).
- **I've saved it** (`A:750-800`): re-read the envelope, open it with the kit, require the opened material to equal the
  installed root, then store a verification record `{origin, instance, protocolMajor, space, scopeBinding, keyEpoch,
  envelopeVersion, SHA-256 hex of envelope ciphertext, SHA-256 hex of kit payload}` with status `verifiedCurrent` (schema
  2) and delete the presentation.
- Status values: `verifiedCurrent`, `knownReplaced`, `statusUnconfirmed`, `neverVerified`, `replacementInProgress`
  (`A:54-60`). A stored `verifiedCurrent` is displayed as unconfirmed until re-checked against the server in this process
  (`A:335-337`).

Pairing, new device (`A:556-636`): create draft (P-256 key pair + 32-byte nonce) -> `POST pairings` (300 s) -> require
`pending` and tag == code -> persist draft and invitation -> show QR, code and a live countdown -> poll `GET
pairings/{id}` (old Android: automatic with a manual **Check Again**) -> when `approved`, `POST .../claim` -> open
envelope -> verify authority -> install -> delete the intent. Cancel sends `DELETE` best-effort.

Pairing, approving device (`A:641-666`, `A:978-1007`): parse the QR; origin and space must be this device's and a key must
be installed; `GET` the pairing and require `pending`, the same tag and the same expiry second; persist the payload; show
the code and consequence; require fresh device-owner authentication; then re-read (already `approved` means a lost
response: done), seal the bundle, obtain an `approve_pairing` proof, `PUT .../approval`.

Poll and approval responses never contain `algorithm` or `ciphertext`; a response that does is invalid. Only the claim
releases the envelope (`C:480-491`). Claim is idempotent for the claiming account until expiry.

Restore from recovery kit (`A:697-720`): read the envelope (none -> "no usable recovery kit"); input starting with `{` is
a QR payload, otherwise a long code; kit origin, space and epoch must match coordinates and the server; open, verify
authority, install.

## 14. Device-approved sign-in (server ADR 0007)

### 14.1 New device

1. Offered only when signed out, not during account change or target-bound reauthentication, and only if discovery lists
   `native-device-sign-in-v1` (`S:2130-2134`, `S:2156-2167`).
2. Resume a stored request for this origin if more than 60 s of lifetime remain (`S:2173-2179`); otherwise create a draft
   and `POST /v2/auth/device-requests` with standard Base64 key and nonce. Validate: poll token format, canonical request
   UUID, expiry in the future (old Kotlin: exact member set and `now - 30 < expiresAt <= now + 630`, `oP:179-190`).
3. Persist `{schemaVersion:1, draft, requestPayload, pollToken}` device-only (`B:337-379`); show QR, copyable payload
   text, confirmation code and countdown. The payload is not a credential; the poll token is and is never shown, logged or
   exported.
4. Poll `POST .../claim` with `{pollToken}` (`F:129-167`): start at 2 s; `pending` -> 2 s and reset back-off;
   `rate_limited` -> `min(max(2, Retry-After), 300)` s; transport failure -> double up to 30 s; stop at request expiry.
   Old Kotlin: `Retry-After` clamped to 1-3,600 s; failures `2 s << min(n, 4)` capped at 30 s
   (`NativeCloudSignInDialog.kt:217-220`).
5. `pending` must have exactly `state` and `expiresAt`. `approved` must have exactly `state`, `expiresAt`, `spaceId`,
   `pairingId`, `session`; journal the session before checking anything else; the stored session has no account key
   (`S:2234-2262`, `oP:211-240`).
6. Terminal codes: `not_found`, `conflict` -> rejected; `pairing_expired` (410) -> expired (`S:2224-2228`). At most five
   claims per request; a repeated approved claim revokes the previously issued family (ADR 0007).
7. Select exactly the returned space: it must appear in `GET /v2/spaces` as writable and re-validate through `GET
   /v2/spaces/{id}`; no chooser; otherwise fail closed (`S:2421-2455`).
8. `GET` the returned pairing with the new session: it must be `approved`, carry this device's own key and nonce, and its
   tag must equal the locally derived code (`S:2460-2491`). Convert the draft into an ordinary pending pairing (expiry
   from the server pairing) and let section 13 step 3 claim it.
9. **Show Account Key** on such a device shows: "This device was signed in by another device. View the account key on a
   device that has it." (`F:46`).

### 14.2 Approving device

1. The scan/paste entry accepts `kind: "snippets-device-sign-in"` as well as pairing invitations, routed by `kind` only
   (`A:641-644`, `B:324-332`).
2. No network call yet: parse strictly, require the payload origin to equal the pinned origin and a key to be installed,
   persist `{schemaVersion:1, requestPayload, pairingPayload:null}` (`A:672-689`). Show the code and: "Sign in a new
   device to this account? It will also receive this library's key. Continue only if this code matches the code on the new
   device." (`A:12-14`).
3. Require the same fresh device-owner authentication as pairing approval.
4. `POST pairings` with the request's key and nonce and the clamped lifetime; require `pending` and tag == code; persist
   the created pairing in the intent before approving, so a retry reuses it (`A:1047-1079`).
5. Approve it through the ordinary proof and envelope path.
6. `POST /v2/auth/device-requests/{id}/approval` with `{spaceId, pairingId}`; expect 204 with an empty body; retry
   transport failures after 1, 2 and 4 s (`C:349-374`); it is idempotent.
7. Final answers end the intent: `pairing_expired`, `pairing_missing`, `not_found`, `conflict`, `forbidden`, a tag
   mismatch or an account mismatch (`A:1088-1097`). Transient failures keep it.
8. Success text: "The new device is signed in." (`A:16`).

Neither side logs the request id, poll token, payload, code or any key. Diagnostics may record closed outcomes for
`device_request`, `device_approval`, `device_claim` only (ADR 0007).

## 15. Error taxonomy and UX rules

Server codes (closed, `API:757-759`): `invalid_account_key`, `invalid_request`, `authentication_required`,
`reauthentication_required`, `forbidden`, `not_found`, `conflict`, `cursor_invalid`, `dataset_reset`,
`incompatible_version`, `payload_too_large`, `quota_exceeded`, `rate_limited`, `pairing_expired`,
`dependency_unavailable`, `internal_error`.

Client-side codes used by the references (not sent by the server): `sign_in_required`, `library_key_required`,
`pairing_missing`, `space_selection_required`, `read_only_library`, `scope_review_required`, `server_auth_insecure`,
`account_key_malformed`, `device_sign_in_expired | rejected | unavailable | wrong_server | library_missing | failed`,
`credential_cleanup_required`, `credential_revocation_incomplete`, `post_authorization_incomplete`,
`resume_account_mismatch`, `recovery_kit_not_saved`, `recovery_kit_changed`, `recovery_status_unconfirmed`,
`secure_setup_failed`, `cloud_feature_disabled`, `cloud_build_not_configured`, `sync_did_not_converge` (old Kotlin only).

Native auth mapping (`S:3404-3418`): `invalid_account_key` -> "not accepted"; `rate_limited` -> wait for `Retry-After`
(default 60, clamp 1-86,400 s); `authentication_required` -> token exchange failed; everything else -> "unavailable". Old
Kotlin keeps only an allow-list of codes and collapses the rest to `server_request_failed` (`oA:486-490`).

UX rules (`docs/android/IMPLEMENTATION.md:91-109`, ADR 0006, ADR 0007, `F:26-48`, `A:116-158`):

- Machine codes never appear in the account UI. Every surfaced error says what happened, states the local-data outcome
  ("Your local snippets are safe/unchanged"), and offers the relevant action: sign in, resume setup, retry cleanup, new
  invitation, recover library. Old Android's full table is `MainActivity.kt:2055-2201`; Swift's is `A:139-158`. Reuse the
  copy.
- Signed out: **Create Account**, **Sign In with Account Key**, and, when advertised, **Sign In with Another Device**.
  Native dialogs only; no browser or WebView.
- Create Account: show **Save Your Account Key** with the display form in a monospaced, selectable field, **Copy**, and an
  explicit **I've Saved It**; the dialog cannot be cancelled while the key is on screen. Message: "This key is the only
  way to sign in to this account on another device. Snippets can't recover it or send it to you. Store it in your password
  manager."
- Sign in: one field. Local failure: "This isn't a valid account key. Check it for typos." Server refusal: "That account
  key wasn't accepted. Check it and try again."
- Secret clipboard rule (account key, recovery kit): local to the device and cleared or expired after two minutes
  (`CloudAccountKeySignInViewController.swift:683-703`); copying the device sign-in payload is allowed and expires with
  the request. The Android equivalent (sensitive clip flag plus a timed conditional clear) is an app-layer decision.
- **Show Account Key** and recovery-kit disclosure require fresh device-owner authentication each time and close when the
  app leaves the foreground.
- Readiness: sign-in or key bootstrap finishing shows "Account connected"; **Up to date** only after the first full sync
  round succeeds.
- Pairing shows step-by-step instructions, the eight-symbol code and a live five-minute countdown.
- The account screen does not offer device inventory or remote account/library deletion; the server has no such contract.
- Diagnostics: closed codes only. Never bodies, tokens, keys, UUIDs, paths, the account id or server exception text.

## 16. Running the server locally for tests

- Stack: Go 1.26.6 server and PostgreSQL 18.4 via `server/docker-compose.yml`; no host Go needed.
- Manual start (`server/README.md:256-264`): `cd server && cp .env.example .env`, replace every placeholder, set
  `AUTH_MODE=native` and `NATIVE_AUTH_SECRET`, then `docker compose up --detach --wait postgres`, `docker compose run --rm
  migrate` (schema must reach version 3), `docker compose up --detach --build server`, `curl
  http://127.0.0.1:8080/.well-known/snippets-sync`. Never print or commit `server/.env`.
- Compose defaults `AUTH_MODE` to `oidc` (`server/docker-compose.yml:73`); native tests must set it.
- Server-only checks: `./Scripts/check-openapi.sh`, the `go test -race ./... && go vet ./...` container command,
  `./Scripts/test-integration.sh` (own compose project and volume).
- Clients require HTTPS. The existing lanes put a TLS edge in front of the local API:
  `scripts/test-cross-platform-sync.sh` (OIDC token fixture, `cloudflared` quick tunnel,
  `scripts/cross-platform-tls-edge.rb` with deterministic fault injection) and `scripts/test-native-cloud-integration.py`
  with `scripts/test-native-cloud-integration-gateway.py` (native auth; gateway on loopback 8787 -> API 8087; documented
  in `scripts/test-native-cloud-integration.md`). Both reset a disposable emulator and need explicit opt-in flags.
- Old instrumentation arguments: `snippetsServerUrl`, `snippetsAccessToken`, `snippetsSpaceId`, `snippetsPhase`
  (`CloudEndToEndTest.kt:36-42`); `snippetsNativeAuthE2E=disposable-emulator` and a `snippetsServerUrl` equal to
  `BuildConfig.SNIPPETS_CLOUD_URL` (`NativeCloudAuthEndToEndTest.kt:33-36`).
- The manual bearer-token configuration is a test seam only and must not exist in the shipping settings UI
  (`docs/android/IMPLEMENTATION.md:100-101`).

## 17. Suggested Kotlin decomposition (`com.khm.snippets.core.cloud`)

Dependency order, each depending only on earlier items plus `core.crypto` and `core.sync`:

1. `CloudOrigin` (pinned-origin parsing), `CloudFeature` (flag and origin both present), `AccountKey` (redacted value
   class).
2. `CloudJson`: strict reader (exact key set, size bound), canonical writer (sorted, unescaped `/`), explicit nulls,
   canonical Base64 and Base64url, RFC 3339 parser.
3. `KeyBundle`; `CloudPayloads` (`PairingInvitation`, `DeviceSignInRequest`, `RecoveryKit`, long code, confirmation code,
   poll-token check, pairing-seconds clamp).
4. `PairingCrypto`, `RecoveryCrypto` (ECDH, HKDF, AES-GCM); `LibraryAuthority` (Ed25519 seed, public key, proof, request
   hashes).
5. `CloudHttp`: one bounded, no-redirect, origin-checked request function behind an interface so tests inject a fake;
   `Problem` parsing; `Discovery` acceptance rules.
6. `SessionStore`, `CredentialJournal`, cleanup planners: pure logic over an injected `SecretStore` (the app supplies the
   Keystore-backed implementation).
7. `AuthClient` (create, sign-in, refresh, revoke, device request, claim; owns the mutex); `SpaceResolver`.
8. `BootstrapClient`: the space-scoped control plane of section 4 with scope validation.
9. `CloudOnboarding`: sections 13 and 14 over `SecretStore`, `CloudKeyStore`, `BootstrapClient`, `AuthClient`, an
   owner-authentication callback and a clock.
10. `CloudTransport` (`SyncTransport` with an injected token provider); `SignInFlow` (poll loop and cancellation for the
    UI).

`:core` stays JVM-only: no `android.util.Base64`, no Android `org.json`, no `BuildConfig`; flag and origin are constructor
parameters supplied by `:app`.

## 18. Test inventory to port

| Pri | Source | What it proves |
| --- | --- | --- |
| P0 | `Tests/Core/SnippetsCloudAccountKeyTests.swift`; `NativeCloudAccountKeyTest.kt` | ADR vectors, normalisation, 64-byte limit, strict canonical form, typo detection, redaction, account-id display |
| P0 | `Tests/Core/LibraryKeyBootstrapTests.swift`; `LibraryKeyBootstrapTest.kt` | authority key and signature vectors, pairing round trip and tamper/AAD binding, recovery round trip from QR and long code, shared recovery wire vector |
| P0 | `Tests/Core/DeviceSignInCodecTests.swift`; `DeviceSignInTest.kt` | exact canonical device payload, strict keys, expiry window, clamp, poll-token format, pending-state round trips, claim member sets, journal-first on malformed approved claim, poll back-off |
| P0 | `Tests/Core/SnippetsCloudTransportTests.swift` | HTTPS-only configuration, scope binding on every response, token provider use, single 401 refresh retry, replacement server -> account review, explicit-null create, feed rotation across chunks |
| P0 | `NativeCloudProtocolTest.kt` | discovery pinning and downgrade refusal, token/lifetime rules, refresh must rotate and keep account, journal-first creation, replacement and refresh cleanup plans, Retry-After clamp |
| P1 | `CloudAccountUxTest.kt` | recovery suffix check, library chooser rules, reader never writable, library id, post-authorization marker round trip, cleanup-failure presentation, error copy |
| P1 | `CloudConfigurationMigrationTest.kt` | missing server instance fails closed |
| P1 | `RecoveryPresentationDisclosureTest.kt`, `AndroidBoundaryTest.recoveryReplacementInvalidationSurvivesStoreReopen`, `disabledCloudFeatureFailsClosedBeforeNetworking` | no kit in process-wide state, durable invalidation, flag gate |
| P1 | `snippets-cross-platform-tests/SnippetsCloudAccountUXTests.swift`, `SnippetsCloudAppIntegrationTests.swift` | app-level flows on Apple (read for scenarios; not read in full for this brief) |
| P2 | `CloudEndToEndTest.kt`, `NativeCloudAuthEndToEndTest.kt`, `NativeDeviceApprovalEndToEndTest.kt`, `StatefulFaultAuditTest.kt` | opt-in live lanes against a disposable server and emulator |
| New | not present anywhere | JVM fake-server tests for the onboarding state machine (first bootstrap, lost-response conflict, two-device race, device-approved sign-in both sides); `docs/android/testing-strategy.md:99-101` notes this gap |

## 19. Porting hazards

1. Ed25519 is required for every proof (`B:835-875`). The old app got it from Swift over JNI (`CoreBridge.kt:38-43`), so
   no Kotlin implementation exists and a platform Ed25519 provider must not be assumed on API 28 (Open question 5). Check
   any choice against the section 11 vectors.
2. The old client implements HKDF by hand over `HmacSHA256` (RFC 5869, `oB:601-628`); do the same and note the two
   different salt/info layouts (section 12).
3. `KeyFactory` does not always reject off-curve points; validate `y^2 = x^3 + ax + b mod p` explicitly for every received
   public key (`oB:562-580`).
4. JSON nulls: `expectedRecordVersion` and `expectedVersion` must be present as `null` (`T:755-765`, `C:128-139`). Many
   Kotlin encoders drop nulls by default.
5. Canonical payload bytes: sorted keys and unescaped `/` (`B:732-736`). `org.json` and default `kotlinx.serialization` do
   neither reliably; write the encoder by hand (`oB:665-685`).
6. Two Base64 dialects: standard padded in API bodies, unpadded URL-safe in payloads and envelope JSON. Both must be
   checked for canonical round-trip (`B:796-807`, `oH:743-749`).
7. snake_case token members versus camelCase everything else (`S:1901-1907`).
8. Journal-first ordering has no suspension point between receiving a grant and persisting it (`S:2114-2117`); in
   coroutines wrap it in `NonCancellable` as the old client did (`oA:96`, `oA:209`).
9. Never revoke an earlier refresh token of the family being kept (`S:2909-2912`, `oP:318`); doing so signs the device
   out.
10. Refresh must be single-flight across the data plane, control plane and UI (`S:1810-1812`); a concurrent second refresh
    with the old token revokes the family server-side.
11. Page and chunk size is 10, not the advertised 50 (`T:171-175`, `T:519`); response ceilings assume it.
12. Do not port the old Kotlin pull/push loop (`oH:84-212`, `oR:1682-1726`): it applies records outside the engine, throws
    on per-record rejection and resets cursors itself.
13. A nil-cursor page without `fullSnapshot`, or a `cursor_invalid` restart without it, must fail rather than be treated
    as an empty library (`T:127-142`).
14. Only `feedEpoch` may change silently. Comparing whole scopes for equality where an identity comparison is meant (or
    the reverse) breaks either rotation or review (`T:360-405`).
15. First-key minting is allowed only when both the recovery envelope is absent and `changes?limit=1` is empty, and the
    key is installed only after the nil-CAS bootstrap wins and authority verifies (`A:944-972`, `A:1132-1140`).
16. Lost-response recovery compares ciphertext bytes, so the pending upload must store the exact bytes sent
    (`A:1122-1131`).
17. `URL.absoluteString` semantics: Swift feeds the origin string into AAD, identities and the authority context exactly
    as stored (no lowercasing, no trailing slash); the provider state key alone lowercases it (`S:1577`). Keep one
    canonical origin string and reuse it.
18. UUID case: lowercase in every hash input, path and payload; Java's `UUID.toString()` is lowercase but parsed input may
    not be, so compare case-insensitively then re-emit.
19. Clock dependence: invitation windows (`-30 s`, `+630 s`), challenge expiry (`<= 330 s`), token expiry and request
    expiry all use wall-clock time; inject a clock for tests.
20. Old Kotlin tolerances that are looser than Swift (token length, capability count, case-insensitive `Bearer`, error
    body `problem.code` fallback at `oA:489`) should not be carried over without a decision.

## 20. Open questions

1. Session and journal model: Swift's two ordered token lists with a `replacementKind`, or the old Android grant-id
   generations with a separate refresh journal? They are local formats and behaviourally equivalent by intent; the Android
   form is simpler to reason about but the Swift form is the stated reference. Needs a decision before `SessionStore` is
   written.
2. Access-token retirement: `DELETE /v2/session` (Swift) or `POST /v2/auth/revoke` with `access_token` (old Kotlin)?
   Swift's logout does both. Is one sufficient for Android?
3. `server_identity_changed` is mapped by `T:660-662` but absent from the contract's error enum. Is it still emitted by
   the server? The Go sources were not read for this brief.
4. Token length bounds: Swift 32-512 bytes, contract 1-512, old Kotlin 8-16,384. Confirm 32-512.
5. Ed25519 for API 28: is a platform provider available at minSdk 28 (not verified here), and if not, which dependency or
   in-tree implementation is acceptable for `:core`, given the "only APIs that exist on Android API 28+" rule in
   `PLAN.md`? The same check applies to HKDF.
6. HTTPS in JVM tests: the references refuse plain HTTP outright and the existing lanes rely on a tunnel. Should `:core`
   tests use an in-process TLS fake server, an injected `CloudHttp` fake, or a debug-only loopback seam like the Git
   provider's? Nothing equivalent exists for Snippets Cloud today.
7. Background delivery: the transport declares `supportsPush = true` but its event stream is empty and the server README
   lists device push registration as future work. Android scheduling (WorkManager, 60 s foreground poll) is undecided
   here.
8. Flag naming for the new Gradle project: keep `SNIPPETS_CLOUD_URL`, or align with Apple's `SNIPPETS_CLOUD_BASE_URL`?
9. ADR 0006 lists silent re-authentication after the 30-day family expires as future work. What does Android show when the
   family expires, especially on a device that holds no account key?
10. Provider switching without iCloud: which parts of `docs/android/provider-switching.md` apply between Local, Git and
    Snippets Cloud, and is the switch receipt needed or only the one-writer rule?
11. Not verified for this brief: the server's Go sources, `docs/android/testing-strategy.md` beyond its native sign-in
    section, the Apple app tests in `snippets-cross-platform-tests/`, `NativeCloudSignInDialog.kt` beyond its poll-delay
    function, and the macOS sheet.
