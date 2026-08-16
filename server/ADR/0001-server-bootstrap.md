# ADR 0001: Swift HTTP sync service bootstrap

- Status: superseded by ADR 0002
- Date: 2026-08-13

## Decision

Use Swift on Linux with Hummingbird and generated OpenAPI server bindings. Use explicit
PostgresNIO SQL and PostgreSQL as the durable source of truth. Keep the service a blind
outer-record store and publish one protocol for hosted Snippets Cloud and self-hosted
Custom Server deployments.

The initial reviewed exact package pins are:

| Package | Version |
|---|---:|
| Hummingbird | 2.26.0 |
| swift-openapi-hummingbird | 2.0.1 |
| swift-openapi-generator | 1.13.0 |
| swift-openapi-runtime | 1.12.0 |
| PostgresNIO | 1.33.1 |
| JWTKit | 5.6.0 |
| swift-crypto | 4.5.1 |
| swift-log | 1.15.0 |
| swift-http-types | 1.6.0 |
| swift-nio-ssl | 2.37.2 |

`Package.resolved` is committed. Upgrades require dependency/security review, full unit
and PostgreSQL integration tests, an OpenAPI generation diff, and container/conformance
checks.

## Rationale

Explicit SQL keeps transaction boundaries, lock ordering, absent-row CAS serialization,
RLS context and immutable change insertion visible in review. Generated routing keeps
the public schema and Swift handler surface coupled. A common server codebase prevents
the hosted data plane from gaining a private compatibility extension unavailable to
self-hosters.

The runtime database role is deliberately unprivileged and never owns tables. An
offline database owner is separate and elevated for schema changes, policy
helper ownership and restore-generation rotation.

## Consequences

The server cannot merge or recover user plaintext. Losing all trusted devices and the
recovery secret is intentionally unrecoverable. PostgreSQL-specific RLS, advisory locks
and transaction behavior are part of the design and must be tested against real
PostgreSQL, not only the in-memory reference store.

The initial container builds with the official `swift:6.3.3-noble` image and runs on its
official `6.3.3-noble-slim` counterpart. Local Compose pins PostgreSQL 17.10 Bookworm.
Moving to distroless or another base requires dynamic-library and CA/JWKS verification
plus an image security review.
