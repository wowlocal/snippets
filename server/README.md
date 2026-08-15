# Snippets Sync Server

This directory contains the Swift/Linux implementation of the public Snippets HTTP
sync protocol. It is a blind storage and coordination service: PostgreSQL stores the
exact portable outer fields `id`, `rev`, `deleted`, and encrypted `blob`, plus server
CAS/cursor metadata. No server target imports or decodes the application's encrypted
`SyncEnvelope` plaintext.

The normative protocol is [`../api/snippets-sync-v1.yaml`](../api/snippets-sync-v1.yaml).
`Sources/SyncOpenAPI/openapi.yaml` is an exact generator input copy; CI and unit tests
verify that it has not drifted.

## Implemented boundary

- Hummingbird 2 and Swift OpenAPI generated server routing;
- strict OIDC JWT validation with HTTPS issuer/JWKS, one exact resource audience, asymmetric
  RS256/ES256 allow-listing, bounded JWKS, single-flight refresh with unknown-key
  cooldown/negative caching, token age, native-client binding and keyed subject
  pseudonyms (email claims are ignored);
- fresh phishing-resistant OIDC step-up for recovery-envelope replacement and pairing
  approval, with a closed `reauthentication_required` client signal;
- immediate resource-server logout through a PostgreSQL-backed denylist of keyed JWT
  digests, including ES256 low-S canonicalization, followed by RFC 7009 access/refresh
  revocation at the identity provider;
- personal spaces and membership-derived authorization;
- exact per-record create/update CAS with authoritative conflicts and positional partial
  batch results;
- stable full-snapshot pagination followed by an ordered at-least-once delta feed;
- HMAC-bound opaque record versions and cursors scoped to server, space, dataset and
  feed generation;
- opaque recovery-key envelope CAS and short-lived, key-substitution-resistant pairing;
- pairing v2 with a 256-bit nonce, validated uncompressed P-256 recipient key,
  server-derived comparison code, P-256 ECDH/HKDF-SHA-256/AES-256-GCM client envelopes,
  redacted polling, and atomic one-use retrieval;
- PostgreSQL constraints, transactions, immutable changes, `FORCE ROW LEVEL SECURITY`,
  and separate migration/runtime roles;
- checksum-pinned migrations and an operator-only restore-generation rotation;
- closed API errors, a 16 MiB pre-decoding request cap, compression rejection, and no
  arbitrary database/identity-provider error text in responses;
- pre-authentication before request-body collection, body/idle timeouts, connection and
  in-flight caps, plus global and per-principal token-bucket request limits;
- hard per-space/per-owner payload and row-count quotas maintained by PostgreSQL triggers;
- digest-pinned, non-root, read-only Compose service packaging with separate runtime and
  migration images and credentials.

`MemorySyncStore` is a deterministic test/reference implementation. The production
executable always constructs `PostgresSyncStore` and a real OIDC validator; there is no
environment switch to a fake identity or in-memory production backend.

This is the service foundation, not yet the public hosted product. Device/push
registration, opaque export, account/space deletion workflow, metrics/tracing, hosted
infrastructure, automatic quota reclamation, and retention jobs are intentionally still
absent. Pairing has a transactionally enforced per-space active-offer limit.
Do not describe this build as a complete public Snippets Cloud deployment until those
gaps and the external security/operations gates are closed.

## Build and unit tests

Swift 6.2 or newer is required. Dependencies are exact-pinned in `Package.swift` and
resolved in `Package.resolved`.

```sh
cd server
./Scripts/check-openapi.sh
swift build
swift test
```

The ordinary test command skips PostgreSQL integration tests unless their explicit
test-only gate is enabled. It still builds those tests.

The repository-wide matrix that determines when server, database, Apple, Android,
provider-switching, and live compatibility gates are required is in
[`../docs/test-strategy.md`](../docs/test-strategy.md).

## Local Compose

Docker Compose is a development convenience, not a production TLS topology. Copy the
example and replace every placeholder. `TOKEN_HMAC_SECRET` and `IDENTITY_PEPPER` must be
different random values of 32–64 decoded bytes. Keep `SERVER_INSTANCE_ID` stable
for the lifetime of this deployment; changing it deliberately forces client review.

```sh
cd server
cp .env.example .env
# edit .env and configure a real HTTPS OIDC issuer/JWKS
docker compose up --build
curl http://127.0.0.1:8080/.well-known/snippets-sync
```

OIDC JWKS are fetched and parsed before the HTTP service starts. JWT-provided `jku`,
`x5u`, critical headers, symmetric algorithms, redirecting JWKS responses, unknown key
IDs, stale/future token times, and non-exact issuer/audience values fail closed. Unknown
key IDs cannot cause an unbounded provider fetch: refresh is single-flight, globally
cooled down, and bounded by a negative cache.

## Account and sign-in boundary

The sync server is an OIDC resource server, not a password database. Native clients use
Authorization Code with PKCE in the system browser and request `offline_access`; the
identity provider owns passkey enrollment, Sign in with Apple/Google, abuse controls and
account recovery. Snippets has no password and does not require or store an email
address. The provider must put the following
claims into the **access token** issued for `OIDC_AUDIENCE`:

- stable pairwise `sub`, plus the standard issuer/audience/time claims;
- `azp` or `client_id` equal to `OIDC_CLIENT_ID`, binding the token to the official
  public native client;
- `auth_time` and `amr` and/or `acr` for a fresh passkey/WebAuthn step-up.

Replacing a recovery envelope or approving a device pairing requires `auth_time` to be
within `OIDC_STEP_UP_MAX_AGE_SECONDS` and an allow-listed phishing-resistant `amr` or
`acr` value. Ordinary refresh-token use remains silent; only those key-granting actions
open a fresh system-browser ceremony. Configure the identity provider to make passkey the
primary action and Apple/Google the one-tap alternatives. Email claims are ignored:
email is neither an account key nor MFA. Never merge accounts by matching email; linking
must be an authenticated provider operation that preserves the same stable subject.

The discovery document advertises protocol minor 4 with `oidc-pkce`,
`oauth-resource-indicators`, `oauth-token-revocation`,
`resource-session-revocation`,
`account-without-required-email`, `phishing-resistant-step-up`, `pairing-v2`, and
`offline-recovery-v1`. It contains policy, issuer, the exact RFC 8707 resource, public
native client ID, scopes, and the server's maximum access-token age—never a client
secret. Clients refresh before the stricter of provider expiry and that age.

Register `OIDC_CLIENT_ID` as a **public native client** with no client secret, mandatory
Authorization Code + S256 PKCE, RFC 7009 token revocation, refresh-token
rotation/reuse detection, RFC 8707
resource indicators, and these exact claimed-HTTPS redirect URIs (substitute the
callback host compiled into the apps):

```text
https://<callback-host>/oauth2redirect/android
https://<callback-host>/oauth2redirect/apple
```

The callback host must bind the Android signing certificate through
`/.well-known/assetlinks.json` and the Apple application identifiers through
`/.well-known/apple-app-site-association`; custom URI schemes are intentionally not
accepted. Official and self-hosted distributions pin both their API origin and callback
host at build time. A generic build with either value absent stays fail-closed instead of
asking a user to trust an arbitrary credential destination.

The production association documents have this minimal shape (replace the Android
fingerprint with the release signing certificate; do not put a debug fingerprint on the
production host):

```json
[{"relation":["delegate_permission/common.handle_all_urls"],"target":{"namespace":"android_app","package_name":"com.khm.snippets.android","sha256_cert_fingerprints":["<RELEASE-SHA256-FINGERPRINT>"]}}]
```

```json
{"webcredentials":{"apps":["H8QG3CBM96.com.khm.snippets"]}}
```

Serve both directly as `application/json` over HTTPS without redirects. Snippets Cloud
is dark-launched, so endpoints alone never enable it. Internal Apple builds must set
`SNIPPETS_CLOUD_ENABLED=YES`, `SNIPPETS_CLOUD_BASE_URL`, and
`SNIPPETS_CLOUD_OAUTH_CALLBACK_HOST`; Android builds use
`SNIPPETS_CLOUD_ENABLED=true`, `SNIPPETS_CLOUD_URL`, and
`SNIPPETS_OAUTH_CALLBACK_HOST`. The associated-domain capability must be present in the
Apple provisioning profiles used to sign both app targets. Normal builds leave the
feature flag off and expose no Snippets Cloud account or provider UI.

Allow `openid offline_access`, set `OIDC_AUDIENCE` to the exact canonical
`PUBLIC_BASE_URL`, and use a distinct `OIDC_CLIENT_ID`. The provider must honor the
`resource` parameter on authorization-code and refresh grants and issue a JWT access
token whose `aud` contains exactly that one resource. Both clients check this before
sending the token to the API, and the server verifies it again. Keep token lifetime at
or below `OIDC_MAX_TOKEN_AGE_SECONDS` (default and production maximum: five minutes).
On sign-out, clients first call `DELETE /v1/session`; the server stores only a keyed
digest of that verified JWT's canonical signature form until expiry and rejects its
replay across every server instance. The middleware checks revocation both before
reading a request body and immediately before the handler, so a slow upload cannot cross
the logout boundary. PostgreSQL additionally serializes logout and every data-plane
transaction on the credential digest and rechecks the denylist inside that transaction,
making the returned `204` a strict multi-instance boundary. The same logout request is
idempotently retryable after a lost response without repeating the database write.
Clients then revoke every journaled access/refresh generation at the provider before
deleting local credentials.
Provider policy—not
the sync database—must offer passkey first, prevent automatic email-based account
linking, publish a secure `revocation_endpoint`, and require a passkey/WebAuthn ceremony
when the native client sends `prompt=login&max_age=0` (plus configured `acr_values`).

The PostgreSQL initialization script creates only `snippets_runtime`, with
`NOSUPERUSER NOBYPASSRLS` and no schema ownership. It runs only when a Compose database
volume is first initialized. Rotating the runtime password later requires an explicit
`ALTER ROLE` or a new development volume.

## Production database roles

Provision roles outside the application. The runtime process receives only the runtime
credential. The migration credential is injected into a short-lived `snippets-migrate`
job and must never be available to the server container.

The migration owner owns the schema/tables and must be an offline administrative role
capable of bypassing RLS while the security-definer policy helpers execute. The runtime
role must be a direct-login role with all of:

```text
NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS
not an owner of any protected table
no permission to create/alter schemas, roles, policies or migrations
```

The migrations revoke public table/function access and grant the runtime role only the
data-plane tables and named `snippets_private` functions. In production, also revoke
default public database/schema access as appropriate and grant connection explicitly to
the two roles.

Personal-space ownership is also stored on `spaces` and checked by a security-definer
policy helper before the first membership can be inserted. Consequently a compromised
runtime query cannot attach its current user to another tenant's known space UUID.
Column/table grants prevent the runtime role from rewriting ownership, membership, or
dataset identity after creation.

Every store operation runs in a database transaction. It resolves the keyed identity
digest, sets `app.user_id` with transaction-local scope, rechecks account status, and
then executes RLS-filtered SQL. Pooled connections outside that wrapper see no protected
rows. The application never accepts `user_id` from an HTTP request.

## Configuration

The server fails startup on missing or malformed values.

| Variable | Meaning |
|---|---|
| `SNIPPETS_ENV` | `development`, `testing`, or `production`; production requires HTTPS public URL and database TLS |
| `PUBLIC_BASE_URL` | Canonical externally visible API origin |
| `SERVER_INSTANCE_ID` | Immutable random UUID persisted with the deployment |
| `TOKEN_HMAC_SECRET` | Base64/base64url 32–64 byte secret for cursors and CAS versions |
| `IDENTITY_PEPPER` | Independent base64/base64url 32–64 byte key for OIDC identity digests |
| `OIDC_ISSUER` / `OIDC_JWKS_URL` | Exact HTTPS issuer and fixed HTTPS JWKS endpoint |
| `OIDC_AUDIENCE` | Exact canonical `PUBLIC_BASE_URL`; the sole JWT audience and RFC 8707 resource |
| `OIDC_CLIENT_ID` | Public native-client identifier; must differ from the resource |
| `OIDC_SCOPES` | Space-separated native client scopes |
| `OIDC_ALLOWED_ALGORITHMS` | Comma-separated subset of `RS256,ES256` |
| `OIDC_MAX_TOKEN_AGE_SECONDS` | Maximum access-token age and `exp - iat` lifetime; default `300`, and production rejects larger values |
| `OIDC_STEP_UP_AMR_VALUES` | Space-separated provider values that specifically prove a passkey/WebAuthn ceremony; production must explicitly configure this and/or ACR values |
| `OIDC_STEP_UP_ACR_VALUES` | Optional space-separated provider-specific phishing-resistant `acr` values; production must explicitly configure this and/or AMR values |
| `OIDC_STEP_UP_MAX_AGE_SECONDS` | Maximum age of the strong ceremony for key-granting operations; default `300` |
| `OIDC_JWKS_REFRESH_SECONDS` | Successful-key-set refresh interval; default `900` |
| `OIDC_UNKNOWN_KID_REFRESH_SECONDS` / `OIDC_UNKNOWN_KID_TTL_SECONDS` | Unknown-key network cooldown and bounded negative-cache TTL; defaults `60` / `300` |
| `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME` | PostgreSQL location |
| `DATABASE_RUNTIME_USER`, `DATABASE_RUNTIME_PASSWORD` | Data-plane login |
| `DATABASE_OWNER_USER`, `DATABASE_OWNER_PASSWORD` | Migration-only login |
| `DATABASE_TLS_MODE` | `require` or development-only `disable` |
| `HTTP_IDLE_TIMEOUT_SECONDS` / `HTTP_BODY_TIMEOUT_SECONDS` | HTTP idle and total body-read deadlines; defaults `30` / `15` |
| `HTTP_READINESS_TIMEOUT_SECONDS` | Maximum PostgreSQL readiness-probe latency before a closed `503`; default `3` |
| `HTTP_MAX_CONNECTIONS` / `HTTP_MAX_CONCURRENT_REQUESTS` | Process-wide connection and in-flight request caps; defaults `256` / `128` |
| `HTTP_BODY_MEMORY_BUDGET_BYTES` | Process-wide reservation budget for live request bodies; default 256 MiB |
| `HTTP_GLOBAL_REQUESTS_PER_SECOND` / `HTTP_GLOBAL_REQUEST_BURST` | Process-wide token-bucket rate and burst; defaults `256` / `512` |
| `HTTP_PRINCIPAL_REQUESTS_PER_SECOND` / `HTTP_PRINCIPAL_REQUEST_BURST` | Per-authenticated-principal token-bucket rate and burst; defaults `30` / `60` |

Terminate public TLS at a reviewed edge/load balancer, require TLS to PostgreSQL, inject
secrets from a secret manager, restrict outbound traffic to the configured OIDC endpoint
and required dependencies, and keep database backups encrypted. The included image is
non-root, the Compose service drops capabilities and uses a read-only filesystem, and
base images are pinned to reviewed registry digests. Image signing, SBOM/scanning,
digest-update automation, and orchestrator admission policy remain deployment work.
The in-process token buckets are a last-resort safety ceiling; production ingress must
also enforce distributed per-source limits before traffic reaches an application socket.

## Storage quotas

Record payload accounting includes the current record plus every retained change copy.
PostgreSQL enforces 512 MiB, 100,000 current rows, and 250,000 change rows per space, and
2 GiB across all spaces owned by one account. The application preflights a write while
holding the same owner/space locks used by the trigger-maintained counters; a rejected
item returns `quota_exceeded` without consuming a feed sequence. These are availability
boundaries, not billing estimates, because PostgreSQL row/index/WAL overhead is bounded
separately by the row counts and infrastructure limits.

Migration `0003_storage_quotas.sql` backfills counters and fails closed if retained data
already exceeds a new hard boundary. Measure aggregate record/change bytes and counts
before applying it to an existing deployment; do not delete current records or arbitrary
change ranges merely to force the migration through.

## Migrations and restore safety

Run migrations before starting a new server version:

```sh
cd server
MIGRATIONS_DIR="$PWD/Migrations" swift run snippets-migrate
```

The runner takes a PostgreSQL advisory lock, verifies the SHA-256 recorded for every
already-applied migration, and applies each new file atomically. Never edit a migration
after it has shipped; add a forward migration.

After restoring an older database snapshot, losing accepted data, or otherwise rolling
back durable state, keep application traffic disabled and rotate every affected space:

```sql
BEGIN;
SELECT snippets_private.rotate_dataset_after_restore(id) FROM spaces;
COMMIT;
```

This rotates dataset and feed generations, clears obsolete change rows, invalidates all
pre-restore per-record CAS tokens, and makes existing rows available in a new full
snapshot. Old cursors then return `dataset_reset`; clients must enter explicit review.
Run this as the migration/operator owner, never grant the function to the runtime role,
and rehearse the procedure against restored backups.

## PostgreSQL integration tests

The helper starts a dedicated database named `snippets_sync_test`, proves two-tenant
isolation with overlapping record UUIDs through both direct store calls and the HTTP
identity boundary, probes the runtime role and no-context RLS, exercises concurrent
create CAS, deterministically discards and redelivers committed responses, replays delta
cursors, checks positional partial batches, and verifies restore-generation behavior. It
deletes only the helper's dedicated Compose project and volume when finished.

```sh
cd server
./Scripts/test-integration.sh
```

The same test can run against an already-provisioned disposable PostgreSQL database by
setting `SNIPPETS_INTEGRATION_TESTS=1` plus the documented owner/runtime database
variables, then running:

```sh
swift test --filter PostgresIntegrationTests
```

To run only the deterministic HTTP/PostgreSQL chaos boundary against that disposable
database:

```sh
swift test --filter \
  PostgresIntegrationTests.testHTTPNetworkChaosRetriesPartialBatchAndDeltaReplayStayConvergent
```

The test deliberately ignores a response only after the router has completed the store
call, then redelivers the exact stale-CAS request and cursor. This models the durable
server side of a lost response without timing or packet-loss randomness. Socket resets,
partial request bodies, proxy/TLS failures, and database disconnects mid-transaction
still require a separate live fault-injection environment; see
[`../docs/test-strategy.md`](../docs/test-strategy.md).

`Scripts/oidc-integration-fixture.rb` is a test-only RS256 helper for a full Android
HTTPS integration environment. Its `serve` mode exposes only JWKS; `token` signs an
ephemeral local test token. Keep its generated private key in a mode-0700 temporary
directory and never use the fixture, its subject, or its keys in production. The opt-in
Android `CloudEndToEndTest` documents the required instrumentation arguments.

## Security and compatibility invariants

- Never parse, index, log, compress, or derive fields from `blob` or key-envelope bytes.
- Never log bearer tokens, raw OIDC issuer/subject, UUIDs, revisions, blobs, ciphertext,
  key material, query text, bind values, filesystem paths, or vendor exception strings.
- Keep the portable raw blob limit at 900,000 bytes and revision limit at 256 UTF-8
  bytes. Production schema changes are additive/forward only once records exist.
- Tombstones are normal CAS saves. Do not physically delete current record rows from the
  sync data plane.
- A cursor is opaque and bound to the current instance/space/dataset/feed. A restore is
  not ordinary cursor compaction.
- CloudKit remains separate Apple app-target code. This server and protocol add the HTTP
  provider; they do not replace or modify the existing iCloud implementation.
