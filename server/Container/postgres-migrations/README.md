# PostgreSQL migrations

The empty-database bootstrap tracks the latest schema (currently version 4). Add
forward-only migrations here as `0005_description.sql`, `0006_description.sql`, and so
on. Each migration must finish with:

```sql
INSERT INTO snippets_private.schema_migrations(version) VALUES (5)
ON CONFLICT (version) DO NOTHING;
```

`Scripts/migrate.sh` holds the repository-wide session advisory lock, requires an exact
contiguous applied history, rejects unknown newer versions, and checks the SHA-256 of
every repository migration that has been recorded. It tests exact version membership
instead of trusting `max(version)` and commits each pending migration in its own
transaction. A failed migration rolls back without publishing its version or checksum.
The runtime service can only read the version table and refuses to start outside its
declared compatible version range or with a gap in the applied history.
