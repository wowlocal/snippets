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

## Protocol v2

Discovery is `GET /.well-known/snippets-sync`. It advertises protocol 2.0,
`apiBase=<PUBLIC_BASE_URL>/v2`, the OAuth resource equal to the canonical
`PUBLIC_BASE_URL` origin, and record profile `snippets-wire-v1`.

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

Recovery-envelope replacement and pairing approval require recent provider-asserted
phishing-resistant authentication. The first successful pairing claim is bound to the
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
docker compose up --build
curl http://127.0.0.1:8080/.well-known/snippets-sync
```

`PUBLIC_BASE_URL` is a canonical origin with no path, query, fragment, credentials, or
trailing slash; production requires HTTPS. `TOKEN_HMAC_SECRET` and `IDENTITY_PEPPER`
are independent Base64/Base64url values decoding to 32–64 bytes. Keep
`SERVER_INSTANCE_ID` stable for the deployment lifetime. Production requires PostgreSQL
`verify-full` with `DATABASE_TLS_ROOT_CERT`, hostname verification,
`channel_binding=require`, SCRAM authentication, an access-token lifetime no longer
than five minutes, `openid offline_access`, and an explicitly configured step-up AMR
and/or ACR allow-list.

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

The server refuses startup when the database schema falls outside the binary's declared
compatibility range. The expand/migrate/contract, rollback, and backfill policy is in
ADR 0003.

The first rollout is deliberately fail-closed for any pre-squash candidate history
(versions 2–4): `migrate.sh` rejects it and this binary refuses to start. Do not automate
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
