# PostgreSQL migrations

The empty-database bootstrap is schema version 1. Add forward-only migrations here as
`0002_description.sql`, `0003_description.sql`, and so on. Each migration must be safe
to re-run and must finish with:

```sql
INSERT INTO snippets_private.schema_migrations(version) VALUES (2)
ON CONFLICT (version) DO NOTHING;
```

`Scripts/migrate.sh` applies every file in lexical order in one owner transaction while
holding the repository-wide migration advisory lock. The runtime service can only read
the version table and refuses to start outside its declared compatible version range.
