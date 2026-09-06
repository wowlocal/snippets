# Snippets Sync Server

This directory contains the Go implementation of the Snippets HTTP sync service. It is
a blind storage and coordination boundary: PostgreSQL stores `id`, `rev`, `deleted`,
the client-encrypted `blob`, and opaque recovery/pairing envelopes. Server code never
imports or decodes the app's encrypted `SyncEnvelope` plaintext.

The single normative contract is
[`../api/snippets-sync-v2.yaml`](../api/snippets-sync-v2.yaml). Generated Go models and
the strict `net/http` server interface are checked in at `internal/api/generated.go`.
Apple and Android use small platform-native adapters over the same JSON contract.

## Toolchain and layout

- Go 1.26.6, `oapi-codegen` 2.8.0/runtime 1.6.0;
- `net/http`, `pgx` 5.10.0, manual SQL, and `golang-jwt/jwt` 5.3.1;
- PostgreSQL 18.4 with forced RLS and distinct owner/runtime credentials;
- `cmd/snippets-server` as the only server command;
- `internal/domain` as the in-memory reference implementation;
- `internal/postgres` as the production store;
- a versioned first-boot schema plus owner-only forward migrations documented in
  `ADR/0003-production-schema-lifecycle.md`.

The checked-in generated file is refreshed and verified through Docker:

```sh
cd server
./Scripts/check-openapi.sh
docker run --rm -v "$PWD/..:/workspace" -w /workspace/server \
  golang:1.26.6-bookworm \
  sh -c 'go test -race ./... && go vet ./...'
./Scripts/test-integration.sh
```

The integration helper creates only its dedicated Compose project and volume. PostgreSQL
initializes that fresh volume directly from `Container/postgres-init/`, after which the
test covers RLS tenant isolation, CAS, interleaved snapshot pagination, role parity,
change retrieval, restore, and the multi-instance-safe logout boundary against
PostgreSQL 18.4.

## Native account authentication

Set `AUTH_MODE=native` and configure SMTP as shown in `.env.example`. Native mode has
no Logto/OIDC dependency and does not fetch provider metadata during startup. Clients
render email and six-digit code screens using platform controls; all four endpoints
below accept JSON and return `Cache-Control: no-store`:

```text
POST /v2/auth/email/start   {"email":"you@example.com"}
POST /v2/auth/email/verify  {"challengeId":"…","code":"123456"}
POST /v2/auth/refresh       {"refreshToken":"…"}
POST /v2/auth/revoke        {"token":"…","tokenTypeHint":"refresh_token"}
```

Start returns a random challenge, `expiresIn:600`, `resendAfter:60`, `codeLength:6`.
Verify and refresh return `access_token`, `refresh_token`, `expires_in` (at most 300),
`token_type:"Bearer"`, and `account:{id,email}`. The account ID is immutable and
independent of its email. Signup and sign-in use the same path, response shape and
SMTP behavior. Email is normalized to lowercase ASCII; aliases are not stripped or
linked. Email exists in private authentication records, never in sync identities or
logs. There is no account-profile or provider browser screen in this flow.

`NATIVE_AUTH_SECRET` is an independent 32–64-byte base64 secret for keyed OTP, challenge,
credential and rate digests. `IDENTITY_PEPPER` is the persistent account/email identity
pepper; changing it requires an explicit identity migration. Preserve both across
restarts. Losing the auth secret invalidates pending codes and sessions, but does not
change email account lookup or sync identity. Only digests of codes and tokens persist;
OTP comparison is constant time inside a row-locked transaction. A code lasts ten
minutes, allows five guesses, is consumed once, and is replaced by resend.

PostgreSQL rate limits work across server replicas: a 60-second email cooldown, five
sends/email/hour, ten/email/day, thirty/source-IP/hour, and a thousand sends/deployment/hour.
Verification permits 300 attempts/source-IP/hour and 10,000/deployment/hour; refresh
permits 1,000/source-IP/hour and 30,000/deployment/hour. `429 rate_limited` includes
`Retry-After` and `retryAfterSeconds`. Invalid, expired and exhausted codes have closed
error codes. Rate keys are keyed digests. By default the server uses the TCP peer IP and
ignores all forwarded headers, so clients behind a proxy share its IP budget. To preserve
per-client limits behind a managed edge, set `AUTH_TRUSTED_PROXY_CIDRS` to its immediate
TCP peer networks (comma-separated canonical CIDRs, maximum 32 and 2,048 bytes). Empty
configuration trusts no proxy; `/0`, host bits and IPv4-mapped prefixes are rejected.
Use narrow networks and prevent direct access to the origin from other clients in them.

For native start, verify and refresh, a trusted peer must provide exactly one
`X-Snippets-Client-IP` header containing one literal unicast IP, with no port, list or IPv6
zone. Missing, repeated or malformed values fail with `400 invalid_request` before
authentication. IPv4-mapped peer and client addresses are normalized to IPv4. Headers
from untrusted peers are ignored; `Forwarded` and `X-Forwarded-For` are never consulted.
The edge must remove any incoming `X-Snippets-Client-IP` and set its own value from a
verified transport source. For another upstream proxy/CDN, configure that trust at the
edge first; copying arbitrary forwarded headers would let callers choose a rate bucket.
Discovery, revocation and the data plane do not require this header. Addresses and rejected
header values are not logged. Email, IP and deployment budgets remain unchanged.

Expired transient rows are
pruned in bounded batches every minute and on starts, with creation bounded by global budgets.

Access tokens expire within five minutes. Refresh tokens rotate once within a fixed
30-day family lifetime. Reusing a rotated refresh token revokes that entire family;
clients must serialize refresh and durably replace tokens before further requests.
Revoking any refresh generation also revokes its family. Access-token revocation and
`DELETE /v2/session` revoke only the exact credential. Other device sessions remain
usable. Family revocation takes the same credential advisory locks as the data plane,
so acknowledged logout cannot race a later write using an already-validated token.
Native email authentication does not claim phishing resistance; encrypted library
operations still require the existing root-key proof and local owner authentication.

SMTP supports verified STARTTLS (default), direct TLS, or plaintext only in a private
development/test environment. Set `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM` and optional
`SMTP_USERNAME`/`SMTP_PASSWORD`; credentials cannot be sent over plaintext SMTP.
The SMTP connection and request context have bounded deadlines. Delivery failures
return a sanitized `dependency_unavailable` and invalidate the undelivered challenge.
For local Mailpit use port 1025, `SMTP_TLS=none`, and keep its mailbox UI private.

The optional `AUTH_MODE=oidc` retains the previous server adapter for existing deployments
and protocol tests. The default when the variable is absent remains `oidc`; new native
setups should use the explicit sample configuration. These modes represent distinct
account authorities; switching an existing deployment does not merge accounts.

## Protocol v2

Discovery is `GET /.well-known/snippets-sync`. It advertises protocol 2.1,
`apiBase=<PUBLIC_BASE_URL>/v2`, record profile `snippets-wire-v1`, and the configured
authentication flow. Native deployments publish `nativeAuth` and the
`native-email-code-v1` capability. OIDC deployments publish the existing provider metadata.

The data plane is:

```text
DELETE /v2/session
GET    /v2/spaces
POST   /v2/spaces                         Idempotency-Key: <UUID>
GET    /v2/spaces/{space}
GET    /v2/spaces/{space}/changes
POST   /v2/spaces/{space}/records/batch
GET    /v2/spaces/{space}/recovery-envelope
PUT    /v2/spaces/{space}/recovery-envelope
POST   /v2/spaces/{space}/pairings
GET    /v2/spaces/{space}/pairings/{pairing}
DELETE /v2/spaces/{space}/pairings/{pairing}
PUT    /v2/spaces/{space}/pairings/{pairing}/approval
POST   /v2/spaces/{space}/pairings/{pairing}/claim
```

Every space-scoped response carries a nested `scope` containing the server instance,
space, opaque membership binding, dataset generation, and feed epoch. Clients validate it before
accepting cursors, CAS versions, or ciphertext. Record versions and cursors have the
form `v2.<canonical-base64url-payload>.<HMAC-SHA256>` and bind the server instance,
space, dataset, and relevant record/feed position. The database stores generations,
not those HMAC tokens.

Record batch writes also carry the client's complete `expectedScope`. The server checks
the deployment instance before entering the store, then checks the remaining scope under
the same transaction lock used by dataset/feed rotation. It performs no record mutation
when the instance, dataset generation, feed epoch, or membership binding is stale.

Protocol JSON property names are exact-case. It rejects duplicate, case-colliding, or
unknown members, trailing values, non-canonical standard Base64, compressed bodies, and
bodies on bodyless operations. Errors use a closed `application/problem+json` shape
with one random request ID shared by the `X-Request-ID` response header and access log,
and no arbitrary message or exception text. There is no `X-Snippets-Protocol` header
and no v1 route.

## Security boundary

OIDC access tokens must use RS256 or ES256 and have one exact issuer, audience, and
native-client binding (`azp` and/or `client_id`). Startup fetches a fixed HTTPS JWKS URL
without redirects; the document is capped at 512 KiB and 64 unique key IDs. Unknown
metadata and independently unusable keys are ignored while duplicate key IDs and a set
with no usable verification key fail closed. Unknown-key
refresh is single-flight, cooled down, and negatively cached. JWT `jku`, `x5u`, `crit`,
duplicate JSON members, invalid times, and symmetric algorithms fail closed. Identity
and concrete-credential lookups are keyed HMAC digests; raw issuer subjects and tokens
never enter PostgreSQL or logs. Known cached verification keys use a bounded
stale-while-revalidate window and fail with dependency unavailability after the absolute
JWKS staleness limit. ES256 credential identity uses a low-S canonical
signature so signature malleability cannot evade logout.

Recovery-envelope replacement and pairing approval require a challenge signed by the
library key after local device-owner authentication. The first successful pairing claim is bound to the
claiming account and remains idempotently retrievable until invitation expiry or
cancellation, so a lost HTTP response does not consume the encrypted envelope. Any
current member, including a reader, may claim an approved envelope needed to exercise
their read access; creating, approving, and cancelling pairings still require a writable
role. Logout
stores only a keyed credential digest.
Data-plane transactions take the shared form of the credential advisory lock; logout
takes its exclusive form. Both recheck the denylist inside the transaction, so a
returned `204` is a strict boundary across server instances without serializing all
ordinary requests from one credential.

Liveness bypasses user admission; readiness has two reserved slots. User admission is
ordered: global rate/concurrency limits, authentication, a bounded revocation preflight,
synchronous deadline-bounded strict body decoding, proportional response-memory
reservation where applicable, then the handler transaction and its definitive denylist check. The
server has connection, request, pool-connect, SQL-statement, lock, body-memory,
response-memory, global-rate, and identity-rate limits. Production output is sanitized
JSON logging containing only operation, status, duration, random request ID, and closed
error codes. Application panic recovery returns a closed `500` problem when headers
have not already been committed. The configurable shutdown drain is validated to exceed
the maximum request deadline plus response-flush grace.

PostgreSQL uses `FORCE ROW LEVEL SECURITY`. The runtime login is
`NOSUPERUSER NOBYPASSRLS`, owns no protected object, cannot change ownership or quota
counter columns, and receives only narrow table columns and security-definer functions.
Those functions are owned by the dedicated `NOLOGIN BYPASSRLS`
`snippets_function_owner`, not by the runtime or an assumed-superuser database owner;
their `search_path` and table grants are explicit. A cluster administrator must create
that role (and grant the migration role membership) when the schema installer cannot
create `BYPASSRLS` roles itself.
Write
locking is credential, quota owner/space, then sorted per-record advisory locks; absent
record CAS is serialized too. Quotas are 512 MiB/100,000 records/250,000 changes per
space and 2 GiB per owner. After successful mutations accumulate meaningful reclaimable
history near the byte/count high-water mark, batch preflight selects a deterministic
quota-fitting subset and the same transaction performs at most one compaction to one
immutable version per current record. Accounting for each bulk baseline statement is
set-based, the feed epoch rotates once, and the new scope is returned to the writer.
Invalid, stale, conflicting, and wholly quota-rejected batches do not perform
maintenance. This bounds repeated-update history without a long-lived database snapshot
or repeated baseline rotation. Tombstones remain current records;
safe physical tombstone reclamation still requires the client-checkpoint lifecycle
listed under future work.

After a verified restore or accepted-data loss, keep traffic stopped and run as the
database owner:

```sql
BEGIN;
SELECT snippets_private.rotate_dataset_after_restore(id) FROM spaces;
COMMIT;
```

This rotates dataset/feed generations, clears obsolete changes, increments record
generations, creates one immutable baseline change per restored record, and makes old
cursors return `dataset_reset`. The function is deliberately not granted to the runtime
role.

## Containers

The server is statically built with `CGO_ENABLED=0`. The final scratch image contains
only the command and CA bundle and runs as numeric user `65532`. It contains no schema
SQL or owner credentials. Compose pins Go and PostgreSQL images by digest, initializes
only a brand-new database volume from `Container/postgres-init/`, mounts PostgreSQL 18
at `/var/lib/postgresql`, and makes the application filesystem read-only.

```sh
cd server
cp .env.example .env
# replace every placeholder and configure a real HTTPS OIDC issuer/JWKS
docker compose up --detach --wait postgres
docker compose run --rm migrate
docker compose up --detach --build server
curl http://127.0.0.1:8080/.well-known/snippets-sync
```

`PUBLIC_BASE_URL` is a canonical origin with no path, query, fragment, credentials, or
trailing slash; production requires HTTPS. `TOKEN_HMAC_SECRET` and `IDENTITY_PEPPER`
are independent Base64/Base64url values decoding to 32–64 bytes. Keep
`SERVER_INSTANCE_ID` stable for the deployment lifetime. Production requires PostgreSQL
`verify-full` with `DATABASE_TLS_ROOT_CERT`, hostname verification,
`channel_binding=require`, SCRAM authentication, an access-token lifetime no longer
than five minutes and `openid offline_access`. Use `openid profile email offline_access`
for the native account profile. Account login does not require passkey assurance.

`10-schema.sql` bootstraps an empty database at the squashed pre-production baseline,
schema version 1, and is executed once by PostgreSQL's standard first-boot initializer.
There are no supported pre-v1 Snippets Cloud databases. Outside Compose,
provision `snippets_runtime` plus the dedicated function owner with
`00-runtime-role.sh`, then apply the schema as a migration role that is a member of
`snippets_function_owner` with
`psql --set ON_ERROR_STOP=1 --file Container/postgres-init/10-schema.sql`. Later
forward-only migrations are applied with owner credentials and a repository advisory
lock:

```sh
PGHOST=database.example PGDATABASE=snippets PGUSER=snippets_owner \
  PGPASSFILE=/secure/path/owner.pgpass ./Scripts/migrate.sh
```

This binary requires schema version 3 (baseline 1, library authority 2, native auth 3).
The server refuses startup when the database schema falls outside the binary's declared
compatibility range. The expand/migrate/contract, rollback, and backfill policy is in
ADR 0003.

The first rollout is deliberately fail-closed for any pre-squash candidate history
(versions 2–4 without the current migration checksums): `migrate.sh` rejects it and this binary refuses to start. Do not automate
volume deletion. Inventory development, staging, dark-launch, manual, and restorable
backup databases first. Recreate only a proven-disposable database and rotate
`SERVER_INSTANCE_ID`; preserve any valuable database for a reviewed bridge/export so
clients cannot mistake a reset remote dataset for the old deployment.

The normal integration lane covers fresh bootstrap, migration-ledger validation, RLS,
quota accounting, feed rotation, and the high-water compaction gate. It materializes
100,000 current records and 200,001 history rows and requires the rebuild to finish
inside the configured 20-second SQL deadline:

```sh
./Scripts/test-integration.sh
```

The integration lane includes the 100k-record/200k-change compaction benchmark by
default. A local developer may explicitly set `SNIPPETS_COMPACTION_SCALE_TESTS=0` for a
short diagnostic run, but release and nightly invocations must keep the default gate.

## Deliberately future work

Snippets Cloud remains dark-launched. Device push registration, opaque export, account
and space deletion workflows, hosted billing, metrics/tracing, client checkpoint leases
and tombstone reclamation, production infrastructure, image signing, and SBOM are not
implemented here. CloudKit and the encrypted `snippets-wire-v1` payload remain
unchanged.

## Account login (protocol 2.1)

New libraries support ordinary Apple/Google/email OTP login. Passkeys are optional.
Sensitive library-key mutations use a signed challenge from an approved device. Recovery-kit deferral allows sync
and leaves a Settings reminder. See [ADR 0004](ADR/0004-conventional-account-login.md)
and the [Logto deployment and acceptance guide](Identity/README.md).

The current binary requires schema **2**. After fresh PostgreSQL bootstrap (schema 1),
run `Scripts/migrate.sh` with owner credentials before starting the server; run the same
command for an existing supported v1 database. Migration 2 is additive and must not be
replaced by deleting the database. The runtime container has no owner credential.
