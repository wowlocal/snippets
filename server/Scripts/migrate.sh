#!/bin/sh
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
migration_directory="$script_directory/../Container/postgres-migrations"

{
  printf '%s\n' '\set ON_ERROR_STOP on'
  printf '%s\n' "SET lock_timeout = '30s';"
  printf '%s\n' 'SELECT pg_advisory_lock(824776254196138476);'
  for migration in "$migration_directory"/[0-9][0-9][0-9][0-9]_*.sql; do
    [ -f "$migration" ] || continue
    migration_name=${migration##*/}
    version=${migration_name%%_*}
    while [ "${version#0}" != "$version" ]; do version=${version#0}; done
    [ -n "$version" ] || version=0
    case "$version" in *[!0-9]*) echo "invalid migration filename: $migration_name" >&2; exit 1;; esac
    escaped_migration=$(printf '%s' "$migration" | sed "s/'/''/g")
    printf 'SELECT coalesce(max(version), 0) < %s AS apply_migration FROM snippets_private.schema_migrations \\gset\n' "$version"
    printf '%s\n' '\if :apply_migration' 'BEGIN;'
    printf "\\i '%s'\n" "$escaped_migration"
    printf '%s\n' 'COMMIT;' '\endif'
  done
  printf '%s\n' 'SELECT pg_advisory_unlock(824776254196138476);'
} | psql -X
