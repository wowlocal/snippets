# PostgreSQL migrations

Snippets Cloud has not had a production deployment, so all pre-launch schema candidates
were squashed into the empty-database baseline, version 1. The directory is intentionally
empty until the first post-launch schema change. Add forward-only migrations as
`0002_description.sql`, `0003_description.sql`, and so on. Each migration must finish
with its own version publication:

```sql
INSERT INTO snippets_private.schema_migrations(version) VALUES (2)
ON CONFLICT (version) DO NOTHING;
```

`Scripts/migrate.sh` holds the repository-wide session advisory lock, requires an exact
contiguous applied history, rejects unknown newer versions, and checks the SHA-256 of
every recorded repository migration before any pending migration begins. It tests exact
version membership instead of trusting `max(version)` and commits each pending migration
plus its checksum in one transaction. A failed migration rolls back without publishing
its version or checksum. The runtime service can only read the version table and refuses
to start outside its declared compatible version range or with a gap in the applied
history.
