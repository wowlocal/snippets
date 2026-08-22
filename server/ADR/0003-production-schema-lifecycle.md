# ADR 0003: Production schema lifecycle

- Status: accepted
- Date: 2026-08-21
- Amends: ADR 0002

## Decision

Before the first production deployment, the empty-database bootstrap tracks the latest
schema (currently version 4) and every change also includes the forward migration from
the preceding candidate. After the first production deployment, the bootstrap remains
an equivalent fresh-install representation of the latest schema while every upgrade is
a forward-only numbered migration under `Container/postgres-migrations/`, applied by
`Scripts/migrate.sh` with the offline database-owner credential. The runtime container
does not contain that credential and retains no DDL privilege.

Every server release declares the inclusive schema-version range it can run against and
fails startup outside that range. A rolling change uses expand/migrate/contract:

1. Deploy a server version compatible with both the old and expanded schema.
2. Apply additive schema changes and run bounded, resumable backfills.
3. Verify backfill invariants, then deploy the version that requires the new schema.
4. Contract obsolete columns or indexes only in a later release after no running or
   rollback candidate can use them.

Migrations take the repository advisory lock and run transactionally. A migration that
cannot fit one short transaction must add its schema transactionally, perform a separate
idempotent and observable backfill in bounded batches, and only then publish the version
required by the next server release. Backfills must not hold long-lived snapshots or
block the data-plane lock order.

The runner requires the applied ledger to be the exact contiguous sequence from version
1 through the database maximum, refuses versions newer than the checkout, and records a
SHA-256 checksum for every forward-migration file. Existing version-3 databases created
by the historical fresh bootstrap may contain the single equivalent marker `{3}`; the
runner recognizes and expands only that exact legacy shape before enforcing continuity.
A checksum mismatch is repaired with a new forward migration, never by editing published
history.

## Rollback policy

Application rollback is permitted only to a binary whose declared range includes the
current schema. Production schema migrations are not reversed. A bad additive change is
repaired by a new forward migration; destructive rollback requires traffic to stop and
a separately reviewed restore procedure that rotates the affected dataset generation.

## Consequences

The former no-migration exception in ADR 0002 ends before the first deployment. Owner
credentials remain operational tooling only. Release automation must run compatibility,
fresh-bootstrap, upgrade, mixed-version, and rollback-candidate tests before publication.
