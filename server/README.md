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
- one declarative first-boot schema, `Container/postgres-init/10-schema.sql`.

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
test covers RLS tenant isolation, CAS, change retrieval, and the multi-instance-safe
logout boundary against PostgreSQL 18.4.

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

Every space-scoped response carries a nested `scope` containing the space, opaque
membership binding, dataset generation, and feed epoch. Clients validate it before
accepting cursors, CAS versions, or ciphertext. Record versions and cursors have the
form `v2.<canonical-base64url-payload>.<HMAC-SHA256>` and bind the server instance,
space, dataset, and relevant record/feed position. The database stores generations,
not those HMAC tokens.

Protocol JSON rejects duplicate or unknown members, trailing values, non-canonical
standard Base64, compressed bodies, and bodies on bodyless operations. Errors use a
closed `application/problem+json` shape with a random request ID and no arbitrary
message or exception text. There is no `X-Snippets-Protocol` header and no v1 route.

## Security boundary

OIDC access tokens must use RS256 or ES256 and have one exact issuer, audience, and
native-client binding (`azp` and/or `client_id`). Startup fetches a fixed HTTPS JWKS URL
without redirects; the document is capped at 512 KiB and 64 unique key IDs. Unknown-key
refresh is single-flight, cooled down, and negatively cached. JWT `jku`, `x5u`, `crit`,
duplicate JSON members, invalid times, and symmetric algorithms fail closed. Identity
and concrete-credential lookups are keyed HMAC digests; raw issuer subjects and tokens
never enter PostgreSQL or logs. ES256 credential identity uses a low-S canonical
signature so signature malleability cannot evade logout.

Recovery-envelope replacement and pairing approval require recent provider-asserted
phishing-resistant authentication. Logout stores only a keyed credential digest.
Every data-plane transaction and logout take the same credential advisory lock and
recheck the denylist inside the transaction, so a returned `204` is a strict boundary
across server instances.

Request admission is ordered: global rate/concurrency limits, authentication, shared
revocation check, bounded strict body decoding, a second revocation check, then the
handler transaction. The server has connection, in-flight, body-time, body-memory,
global-rate, and per-principal-rate limits. Production output is sanitized JSON logging
containing only operation, status, duration, random request ID, and closed error codes.

PostgreSQL uses `FORCE ROW LEVEL SECURITY`. The runtime login is
`NOSUPERUSER NOBYPASSRLS`, owns no protected object, cannot change ownership or quota
counters, and receives only narrow table columns and security-definer functions. Write
locking is credential, quota owner/space, then sorted per-record advisory locks; absent
record CAS is serialized too. Quotas are 512 MiB/100,000 records/250,000 changes per
space and 2 GiB per owner.

After a verified restore or accepted-data loss, keep traffic stopped and run as the
database owner:

```sql
BEGIN;
SELECT snippets_private.rotate_dataset_after_restore(id) FROM spaces;
COMMIT;
```

This rotates dataset/feed generations, clears obsolete changes, increments record
generations, and makes old cursors return `dataset_reset`. The function is deliberately
not granted to the runtime role.

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
`SERVER_INSTANCE_ID` stable for the deployment lifetime. Production also requires DB
TLS, an access-token lifetime no longer than five minutes, `openid offline_access`, and
an explicitly configured step-up AMR and/or ACR allow-list.

There is deliberately no migration runner or schema history: the HTTP service has never
been deployed. `10-schema.sql` is the final schema bootstrap for an empty database and
is executed once by PostgreSQL's standard first-boot initializer. Outside Compose,
provision the restricted `snippets_runtime` role with `00-runtime-role.sh`, then apply
the schema as the database owner with
`psql --set ON_ERROR_STOP=1 --file Container/postgres-init/10-schema.sql`. Future schema
evolution must first define an explicit operational policy rather than silently
introducing an upgrade path here.

## Deliberately future work

Snippets Cloud remains dark-launched. Device push registration, opaque export, account
and space deletion workflows, hosted billing, metrics/tracing, automated retention and
quota reclamation, production infrastructure, image signing, SBOM, and admission policy
are not implemented here. CloudKit and the encrypted `snippets-wire-v1` payload remain
unchanged.
