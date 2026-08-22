# ADR 0003: Production schema lifecycle

- Status: accepted
- Date: 2026-08-21
- Amends: ADR 0002

## Decision

Snippets Cloud has not had a production deployment. All pre-launch schema candidates are
therefore squashed into the empty-database baseline, version 1; local and integration
databases created from earlier candidates are disposable and are not upgrade targets.
After the first production deployment, the bootstrap remains an equivalent fresh-install
representation of the latest schema while every upgrade is a forward-only numbered
migration, beginning with version 2, under `Container/postgres-migrations/`. Migrations
are applied by `Scripts/migrate.sh` with the offline database-owner credential. The
runtime container does not contain that credential and retains no DDL privilege.
Migration bodies contain no ledger writes or transaction control; the runner alone
publishes the expected version and checksum after proving the body left both ledgers
unchanged.

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
SHA-256 checksum for every post-baseline migration file. It validates every already
applied checksum before starting any pending migration. Source migrations are copied to
a private immutable execution snapshot before PostgreSQL is contacted, and SQL generation
must complete before `psql` starts. A checksum mismatch is repaired with a new forward
migration, never by editing published history.

## Rollback policy

Application rollback is permitted only to a binary whose declared range includes the
current schema. Production schema migrations are not reversed. A bad additive change is
repaired by a new forward migration; destructive rollback requires traffic to stop and
a separately reviewed restore procedure that rotates the affected dataset generation.

## Consequences

The pre-launch squash is a one-time boundary and must not be repeated after the first
deployment. Owner credentials remain operational tooling only. Release automation must
run compatibility, fresh-bootstrap, upgrade, mixed-version, and rollback-candidate tests
before publication.

Any database reporting a version other than the squashed baseline at the first rollout
halts both the migration runner and runtime startup. Automation must never delete such a
database or volume. Operators first inventory development, staging, dark-launch, backup,
and manually provisioned databases; a database with valuable data requires a reviewed
bridge/export, while a proven-disposable database may be recreated with an explicitly
rotated server identity.
