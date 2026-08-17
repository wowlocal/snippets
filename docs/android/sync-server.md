# Snippets HTTP sync service

The implemented HTTP service is a Go 1.26.6/PostgreSQL 18.4 blind store. It shares no
application model code and never receives plaintext snippets, vault keys, or recovery
material. Apple, Android, hosted, and self-hosted deployments use the same normative
contract: [`../../api/snippets-sync-v2.yaml`](../../api/snippets-sync-v2.yaml).

## Implementation boundary

```text
api/snippets-sync-v2.yaml       normative OpenAPI 3.1 contract
server/cmd/                     server command
server/internal/api/            generated strict net/http interface
server/internal/domain/         reference behavior and opaque token codec
server/internal/auth/           bounded OIDC/JWKS validation
server/internal/httpapi/        admission, strict JSON, DTO mapping
server/internal/postgres/       explicit transactions and SQL
server/Container/postgres-init/ first-boot role and schema initialization
```

Direct dependencies are `oapi-codegen` 2.8.0/runtime 1.6.0, `pgx` 5.10.0, and
`golang-jwt/jwt` 5.3.1. There is no ORM and no Swift server package. Apple uses a manual
Swift adapter and Android a manual Kotlin adapter, both validating the same nested scope
before committing cursor, CAS, or ciphertext state.

## Discovery and routes

`GET /.well-known/snippets-sync` returns protocol 2.0, a stable server instance UUID,
`apiBase=<PUBLIC_BASE_URL>/v2`, OIDC resource `<PUBLIC_BASE_URL>`, current limits,
capabilities, and `recordProfile=snippets-wire-v1`.

```text
DELETE /v2/session
GET    /v2/spaces
POST   /v2/spaces                         Idempotency-Key header
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

Every space-scoped response contains `scope {serverInstanceId, spaceId, scopeBinding,
datasetGeneration, feedEpoch}`. `WireRecord` remains `{id, rev, deleted, blob}` with
client-encrypted `blob`. Batch outcomes are positional. Opaque cursor and record-version
tokens start with `v2` and bind server, space, dataset, and the relevant generation or
feed position. PostgreSQL stores only numeric record generations and sequences.

Android cloud configuration schema 3 persists the resolved `serverInstanceId` before
pairing, recovery, or record sync. A schema-2 v2 configuration without that pin remains
readable but fails closed with `scope_review_required`; signing in or configuring the
space again performs a fresh authenticated resolution instead of adopting a replacement
deployment from an old checkpoint.

Requests use canonical standard Base64, strict JSON with required nullable members, and
no `X-Snippets-Protocol` header. Closed errors are `application/problem+json` with
`type=urn:snippets:error:<code>`, HTTP status, code, random request ID, and optional
retry/limit values—never arbitrary exception text.

## Authentication and authorization

The resource server accepts only bounded RS256/ES256 OIDC access tokens from the fixed
HTTPS issuer/JWKS configuration. Tokens need one exact audience (the public origin),
the official public-client `azp` and/or `client_id`, fresh timestamps, and a stable
subject. Subjects and credentials are HMAC-pseudonymized before persistence; email is
ignored. Recovery-envelope replacement and pairing approval additionally require a
recent phishing-resistant `auth_time` plus approved `amr` or `acr`.

Logout writes a keyed token digest to a shared PostgreSQL denylist. Both logout and all
data-plane transactions serialize on the credential digest and recheck revocation inside
the transaction. Request middleware also checks before body collection and immediately
before handling.

PostgreSQL `FORCE ROW LEVEL SECURITY` derives the user only from a transaction-local
server setting. The runtime role cannot bypass RLS or rewrite ownership, dataset identity,
or quota counters. Quota locks precede sorted record locks, including advisory locks for
absent-row CAS. Restore rotation is owner-only and forces clients into dataset review.

## Verification

All Go workflows run in the pinned Go container; no host Go installation is required.

```sh
cd server
./Scripts/check-openapi.sh
docker run --rm -v "$PWD/..:/workspace" -w /workspace/server \
  golang:1.26.6-bookworm sh -c 'go test -race ./... && go vet ./...'
./Scripts/test-integration.sh
docker compose build server
```

The repository cross-platform script defaults to this repository's `server/`, launches
the Go server and PostgreSQL through Compose, and exercises macOS, iOS Simulator, and
Android against v2. CloudKit and shared client-side encryption/merge remain separate and
unchanged.
