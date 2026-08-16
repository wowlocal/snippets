# ADR 0002: Go HTTP sync service

- Status: accepted
- Date: 2026-08-16
- Supersedes: ADR 0001

## Decision

Replace the undeployed Swift/Hummingbird service with a clean-slate Go 1.26.6 service.
Use an OpenAPI 3.1 protocol-v2 contract and an `oapi-codegen` strict `net/http` server
interface, manual platform client adapters, `pgx` with explicit SQL, and PostgreSQL 18.4.
Initialize a brand-new database directly from one final-state schema; do not carry a
migration runner or schema-history table because no HTTP service or database was deployed.

The reviewed direct pins are `oapi-codegen` 2.8.0, runtime 1.6.0, `pgx` 5.10.0, and
`golang-jwt/jwt` 5.3.1. Containers build with `CGO_ENABLED=0`; the scratch server image
contains neither schema SQL nor owner credentials.

## Rationale

The rewrite reduces server runtime and container surface while preserving visible
transaction boundaries, RLS context, advisory-lock ordering, and blind-storage rules.
Generated routing keeps the normative schema coupled to handlers without forcing
generated networking code into Apple or Android clients.

## Consequences

Protocol v1 and Swift server sources are removed without a compatibility window. Apple
and Android persisted HTTP sessions move to protocol 2 and require sign-in before using
legacy state; legacy credentials remain readable only for explicit logout cleanup.
CloudKit, client merge/crypto, and the encrypted `snippets-wire-v1` record payload are
unchanged. PostgreSQL-specific RLS, quotas, restore rotation, and logout linearization
remain mandatory real-database tests. Schema bootstrap is valid only for a fresh
database; there is deliberately no undeployed-version upgrade path to preserve.
