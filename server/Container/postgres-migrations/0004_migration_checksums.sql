CREATE TABLE snippets_private.schema_migration_checksums (
    version bigint PRIMARY KEY REFERENCES snippets_private.schema_migrations(version),
    checksum text NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$')
);

INSERT INTO snippets_private.schema_migration_checksums(version, checksum) VALUES
  (2, '77883c46eac62ae3f13a05ea45d9632e7a92963994712575495d0425fcfbe12c'),
  (3, '5cc7bffd681878e20fef9387fb384e0a382ee5319798e375abbbaa5ec9aca2a6');

INSERT INTO snippets_private.schema_migrations(version) VALUES (4)
ON CONFLICT (version) DO NOTHING;
