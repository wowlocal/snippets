#!/bin/sh
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
migration_directory="$script_directory/../Container/postgres-migrations"
set --
for migration in "$migration_directory"/[0-9][0-9][0-9][0-9]_*.sql; do
  [ -f "$migration" ] || continue
  set -- "$@" --file "$migration"
done

psql \
  -X \
  --set ON_ERROR_STOP=1 \
  --single-transaction \
  --command "SELECT pg_advisory_xact_lock(824776254196138476);" \
  "$@"
