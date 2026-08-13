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
- strict OIDC JWT validation with HTTPS issuer/JWKS, exact audience, asymmetric
  RS256/ES256 allow-listing, bounded JWKS, token age and keyed subject pseudonyms;
- personal spaces and membership-derived authorization;
- exact per-record create/update CAS with authoritative conflicts and positional partial
  batch results;
- stable full-snapshot pagination followed by an ordered at-least-once delta feed;
- HMAC-bound opaque record versions and cursors scoped to server, space, dataset and
  feed generation;
- opaque recovery-key envelope CAS and short-lived, key-substitution-resistant pairing;
- PostgreSQL constraints, transactions, immutable changes, `FORCE ROW LEVEL SECURITY`,
  and separate migration/runtime roles;
- checksum-pinned migrations and an operator-only restore-generation rotation;
- closed API errors, a 16 MiB pre-decoding request cap, compression rejection, and no
  arbitrary database/identity-provider error text in responses;
- non-root, read-only Compose service packaging.

`MemorySyncStore` is a deterministic test/reference implementation. The production
executable always constructs `PostgresSyncStore` and a real OIDC validator; there is no
environment switch to a fake identity or in-memory production backend.

This is the service foundation, not yet the public hosted product. Per-account storage
quotas, general request-rate limiting, device/push registration, opaque export,
account/space deletion workflow, metrics/tracing, hosted infrastructure, and retention
jobs are intentionally still absent. Pairing has a small per-space active-offer limit.
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
IDs, stale/future token times, and non-exact issuer/audience values fail closed.

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
| `OIDC_AUDIENCE` / `OIDC_CLIENT_ID` | Access-token audience and native client discovery value |
| `OIDC_SCOPES` | Space-separated native client scopes |
| `OIDC_ALLOWED_ALGORITHMS` | Comma-separated subset of `RS256,ES256` |
| `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME` | PostgreSQL location |
| `DATABASE_RUNTIME_USER`, `DATABASE_RUNTIME_PASSWORD` | Data-plane login |
| `DATABASE_OWNER_USER`, `DATABASE_OWNER_PASSWORD` | Migration-only login |
| `DATABASE_TLS_MODE` | `require` or development-only `disable` |

Terminate public TLS at a reviewed edge/load balancer, require TLS to PostgreSQL, inject
secrets from a secret manager, restrict outbound traffic to the configured OIDC endpoint
and required dependencies, and keep database backups encrypted. The included image is
non-root and the Compose service drops capabilities and uses a read-only filesystem, but
image signing, digest pinning, SBOM/scanning and orchestrator policy remain deployment
work.

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
isolation with overlapping record UUIDs, probes the runtime role and no-context RLS,
exercises concurrent create CAS, and verifies restore-generation behavior. It deletes
only the helper's dedicated Compose project and volume when finished.

```sh
cd server
./Scripts/test-integration.sh
```

Docker was not available in the original implementation environment, so the checked-in
integration suite is compiled by `swift test` but must run in CI or a workstation with
Docker before merge/deployment.

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
