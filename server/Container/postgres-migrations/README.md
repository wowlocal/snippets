# PostgreSQL migrations

Snippets Cloud has not had a production deployment, so all pre-launch schema candidates
were squashed into the empty-database baseline, version 1. The directory is intentionally
empty until the first post-launch schema change. Add forward-only migrations as
`0002_description.sql`, `0003_description.sql`, and so on. Migration files contain only
the reviewed application DDL/data change. They must not modify
`schema_migrations`/`schema_migration_checksums`, issue transaction control, or contain
psql meta-commands. Version and checksum publication belong exclusively to the runner.

`Scripts/migrate.sh` holds the repository-wide session advisory lock, requires an exact
contiguous applied history, rejects unknown newer versions, and checks the SHA-256 of
every recorded repository migration before any pending migration begins. It tests exact
version membership instead of trusting `max(version)`. Before connecting to PostgreSQL,
the runner copies every regular, non-linked migration into a private read-only snapshot,
computes checksums from those bytes, and completely generates a read-only execution
script. Each pending migration body runs between exact before/after ledger assertions;
the runner then publishes the expected version plus checksum in that same transaction.
A failed migration rolls back without publishing DDL, version, or checksum. The runtime
service can only read the version table and refuses to start outside its declared
compatible version range or with a gap in the applied history.
