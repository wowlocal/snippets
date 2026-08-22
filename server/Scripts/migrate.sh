#!/bin/sh
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
migration_directory=${SNIPPETS_MIGRATION_DIR:-"$script_directory/../Container/postgres-migrations"}
[ -d "$migration_directory" ] || {
  echo "migration directory does not exist: $migration_directory" >&2
  exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
  checksum_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  checksum_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "sha256sum or shasum is required" >&2
  exit 1
fi

previous_version=1
for migration in "$migration_directory"/[0-9][0-9][0-9][0-9]_*.sql; do
  [ -f "$migration" ] || continue
  migration_name=${migration##*/}
  version=${migration_name%%_*}
  while [ "${version#0}" != "$version" ]; do version=${version#0}; done
  [ -n "$version" ] || version=0
  case "$version" in *[!0-9]*) echo "invalid migration filename: $migration_name" >&2; exit 1;; esac
  expected_version=$((previous_version + 1))
  if [ "$version" -ne "$expected_version" ]; then
    echo "migration history is not contiguous: expected $expected_version, found $migration_name" >&2
    exit 1
  fi
  previous_version=$version
done
latest_version=$previous_version

{
  printf '%s\n' '\set ON_ERROR_STOP on'
  printf '%s\n' "SET lock_timeout = '30s';"
  printf '%s\n' 'SELECT pg_advisory_lock(824776254196138476);'
  printf 'SELECT EXISTS (SELECT 1 FROM snippets_private.schema_migrations WHERE version > %s) AS unknown_version \\gset\n' "$latest_version"
  printf '%s\n' '\if :unknown_version' '\echo unknown database migration version' 'SELECT 1 / 0;' '\endif'
  printf '%s\n' 'SELECT NOT EXISTS (SELECT 1 FROM snippets_private.schema_migrations WHERE version = 1) AS missing_baseline \gset'
  printf '%s\n' '\if :missing_baseline' '\echo database migration baseline is missing' 'SELECT 1 / 0;' '\endif'
  printf '%s\n' 'SELECT EXISTS ('
  printf '%s\n' '  SELECT 1 FROM generate_series(1, (SELECT max(version) FROM snippets_private.schema_migrations)) AS expected(version)'
  printf '%s\n' '  WHERE NOT EXISTS (SELECT 1 FROM snippets_private.schema_migrations applied WHERE applied.version = expected.version)'
  printf '%s\n' ') AS migration_gap \gset'
  printf '%s\n' '\if :migration_gap' '\echo database migration history has a gap' 'SELECT 1 / 0;' '\endif'
  printf '%s\n' "SELECT to_regclass('snippets_private.schema_migration_checksums') IS NULL AS missing_checksum_ledger \\gset"
  printf '%s\n' '\if :missing_checksum_ledger' '\echo database migration checksum ledger is missing' 'SELECT 1 / 0;' '\endif'

  # Validate the complete applied history before allowing any pending DDL to start.
  # The session advisory lock keeps this preflight and the following commits ordered.
  printf '%s\n' 'SELECT EXISTS ('
  printf '%s\n' '  SELECT 1 FROM snippets_private.schema_migration_checksums checksums'
  printf '%s\n' '  LEFT JOIN snippets_private.schema_migrations applied USING (version) WHERE applied.version IS NULL'
  printf '%s\n' ') AS orphan_checksum \gset'
  printf '%s\n' '\if :orphan_checksum' '\echo database migration checksum has no applied version' 'SELECT 1 / 0;' '\endif'
  for migration in "$migration_directory"/[0-9][0-9][0-9][0-9]_*.sql; do
    [ -f "$migration" ] || continue
    migration_name=${migration##*/}
    version=${migration_name%%_*}
    while [ "${version#0}" != "$version" ]; do version=${version#0}; done
    [ -n "$version" ] || version=0
    checksum=$(checksum_file "$migration")
    case "$checksum" in ''|*[!0-9a-f]*) echo "invalid migration checksum: $migration_name" >&2; exit 1;; esac
    printf 'SELECT EXISTS (SELECT 1 FROM snippets_private.schema_migrations WHERE version = %s)\n' "$version"
    printf "  AND NOT EXISTS (SELECT 1 FROM snippets_private.schema_migration_checksums WHERE version = %s AND checksum = '%s') AS checksum_mismatch \\\\gset\n" "$version" "$checksum"
    printf '%s\n' '\if :checksum_mismatch' "\echo migration checksum mismatch: $migration_name" 'SELECT 1 / 0;' '\endif'
  done

  # Only a fully trusted applied history may reach the per-migration transactions.
  for migration in "$migration_directory"/[0-9][0-9][0-9][0-9]_*.sql; do
    [ -f "$migration" ] || continue
    migration_name=${migration##*/}
    version=${migration_name%%_*}
    while [ "${version#0}" != "$version" ]; do version=${version#0}; done
    [ -n "$version" ] || version=0
    checksum=$(checksum_file "$migration")
    case "$checksum" in ''|*[!0-9a-f]*) echo "invalid migration checksum: $migration_name" >&2; exit 1;; esac
    escaped_migration=$(printf '%s' "$migration" | sed "s/'/''/g")
    printf 'SELECT NOT EXISTS (SELECT 1 FROM snippets_private.schema_migrations WHERE version = %s) AS apply_migration \\gset\n' "$version"
    printf '%s\n' '\if :apply_migration' 'BEGIN;'
    printf "\i '%s'\n" "$escaped_migration"
    printf "INSERT INTO snippets_private.schema_migration_checksums(version, checksum) VALUES (%s, '%s');\n" "$version" "$checksum"
    printf '%s\n' 'COMMIT;' '\endif'
  done
  printf '%s\n' 'SELECT pg_advisory_unlock(824776254196138476);'
} | psql -X
