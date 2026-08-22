# PostgreSQL migrations

The empty-database bootstrap tracks the latest schema (currently version 3). Add
forward-only migrations here as `0004_description.sql`, `0005_description.sql`, and so
on. Each migration must finish with:

```sql
INSERT INTO snippets_private.schema_migrations(version) VALUES (4)
ON CONFLICT (version) DO NOTHING;
```

`Scripts/migrate.sh` holds the repository-wide session advisory lock, skips versions at
or below the current database version, and commits each pending migration in its own
transaction. A failed migration rolls back without publishing its version. The runtime
service can only read the version table and refuses to start outside its declared
compatible version range.
