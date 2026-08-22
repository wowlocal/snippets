#!/bin/sh
set -eu

export LC_ALL=C

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
  checksum_file() {
    checksum_output=$(sha256sum "$1") || return
    printf '%s\n' "${checksum_output%% *}"
  }
elif command -v shasum >/dev/null 2>&1; then
  checksum_file() {
    checksum_output=$(shasum -a 256 "$1") || return
    printf '%s\n' "${checksum_output%% *}"
  }
else
  echo "sha256sum or shasum is required" >&2
  exit 1
fi

temporary_parent=${TMPDIR:-/tmp}
temporary_root=$(mktemp -d "$temporary_parent/snippets-migrate.XXXXXX")
snapshot_directory="$temporary_root/migrations"
manifest_file="$temporary_root/manifest"
execution_sql="$temporary_root/execution.sql"
mkdir "$snapshot_directory"
: > "$manifest_file"
: > "$execution_sql"

cleanup() {
  status=$?
  trap - 0 HUP INT TERM
  rm -rf -- "$temporary_root"
  exit "$status"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Copy every migration before touching PostgreSQL. Checksums and execution both use
# these read-only snapshots, so a source-tree change cannot create a hash/bytes race.
for candidate in "$migration_directory"/*.sql; do
  if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
    continue
  fi
  candidate_name=${candidate##*/}
  case "$candidate_name" in
    [0-9][0-9][0-9][0-9]_*.sql) ;;
    *) echo "invalid migration filename: $candidate_name" >&2; exit 1;;
  esac
done
previous_version=1
for migration in "$migration_directory"/[0-9][0-9][0-9][0-9]_*.sql; do
  if [ ! -e "$migration" ] && [ ! -L "$migration" ]; then
    continue
  fi
  migration_name=${migration##*/}
  if [ ! -f "$migration" ] || [ -L "$migration" ]; then
    echo "migration must be a regular non-linked file: $migration_name" >&2
    exit 1
  fi
  case "$migration_name" in
    ''|*[!A-Za-z0-9._-]*) echo "invalid migration filename: $migration_name" >&2; exit 1;;
  esac
  description=${migration_name#????_}
  case "$description" in ''|.sql) echo "invalid migration filename: $migration_name" >&2; exit 1;; esac
  version=${migration_name%%_*}
  while [ "${version#0}" != "$version" ]; do version=${version#0}; done
  [ -n "$version" ] || version=0
  case "$version" in *[!0-9]*) echo "invalid migration filename: $migration_name" >&2; exit 1;; esac
  expected_version=$((previous_version + 1))
  if [ "$version" -ne "$expected_version" ]; then
    echo "migration history is not contiguous: expected $expected_version, found $migration_name" >&2
    exit 1
  fi
  snapshot="$snapshot_directory/$migration_name"
  cp "$migration" "$snapshot"
  chmod 0400 "$snapshot"
  if grep -Eq '^[[:space:]]*\\' "$snapshot"; then
    echo "psql meta-command is forbidden in migration body: $migration_name" >&2
    exit 1
  else
    grep_status=$?
    [ "$grep_status" -eq 1 ] || exit "$grep_status"
  fi
  if grep -Eiq '(^|[^A-Za-z0-9_])(COMMIT|ROLLBACK|ABORT)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])(START|PREPARE)[[:space:]]+TRANSACTION([^A-Za-z0-9_]|$)' "$snapshot"; then
    echo "transaction control is forbidden in migration body: $migration_name" >&2
    exit 1
  else
    grep_status=$?
    [ "$grep_status" -eq 1 ] || exit "$grep_status"
  fi
  checksum=$(checksum_file "$snapshot")
  case "$checksum" in ''|*[!0-9a-f]*) echo "invalid migration checksum: $migration_name" >&2; exit 1;; esac
  printf '%s|%s|%s\n' "$version" "$checksum" "$migration_name" >> "$manifest_file"
  previous_version=$version
done
latest_version=$previous_version

append_sql() {
  printf '%s\n' "$@" >> "$execution_sql"
}

append_sql \
  '\set ON_ERROR_STOP on' \
  "SET lock_timeout = '30s';" \
  'SELECT pg_advisory_lock(824776254196138476);'
printf 'SELECT EXISTS (SELECT 1 FROM snippets_private.schema_migrations WHERE version > %s) AS unknown_version \\gset\n' "$latest_version" >> "$execution_sql"
append_sql \
  '\if :unknown_version' \
  '\echo unknown database migration version' \
  'SELECT 1 / 0;' \
  '\endif' \
  'SELECT NOT EXISTS (SELECT 1 FROM snippets_private.schema_migrations WHERE version = 1) AS missing_baseline \gset' \
  '\if :missing_baseline' \
  '\echo database migration baseline is missing' \
  'SELECT 1 / 0;' \
  '\endif' \
  'SELECT EXISTS (' \
  '  SELECT 1 FROM generate_series(1, (SELECT max(version) FROM snippets_private.schema_migrations)) AS expected(version)' \
  '  WHERE NOT EXISTS (SELECT 1 FROM snippets_private.schema_migrations applied WHERE applied.version = expected.version)' \
  ') AS migration_gap \gset' \
  '\if :migration_gap' \
  '\echo database migration history has a gap' \
  'SELECT 1 / 0;' \
  '\endif' \
  "SELECT to_regclass('snippets_private.schema_migration_checksums') IS NULL AS missing_checksum_ledger \\gset" \
  '\if :missing_checksum_ledger' \
  '\echo database migration checksum ledger is missing' \
  'SELECT 1 / 0;' \
  '\endif' \
  'SELECT EXISTS (' \
  '  SELECT 1 FROM snippets_private.schema_migration_checksums checksums' \
  '  LEFT JOIN snippets_private.schema_migrations applied USING (version) WHERE applied.version IS NULL' \
  ') AS orphan_checksum \gset' \
  '\if :orphan_checksum' \
  '\echo database migration checksum has no applied version' \
  'SELECT 1 / 0;' \
  '\endif'

# Validate all already-applied snapshots before the first pending transaction.
while IFS='|' read -r version checksum migration_name; do
  [ -n "$version" ] || continue
  printf 'SELECT EXISTS (SELECT 1 FROM snippets_private.schema_migrations WHERE version = %s)\n' "$version" >> "$execution_sql"
  printf "  AND NOT EXISTS (SELECT 1 FROM snippets_private.schema_migration_checksums WHERE version = %s AND checksum = '%s') AS checksum_mismatch \\\\gset\n" "$version" "$checksum" >> "$execution_sql"
  append_sql \
    '\if :checksum_mismatch' \
    "\echo migration checksum mismatch: $migration_name" \
    'SELECT 1 / 0;' \
    '\endif'
done < "$manifest_file"

# Migration bodies may change application schema/data only. The runner snapshots and
# compares both ledgers around the body, then publishes the expected version/checksum.
while IFS='|' read -r version checksum migration_name; do
  [ -n "$version" ] || continue
  printf 'SELECT NOT EXISTS (SELECT 1 FROM snippets_private.schema_migrations WHERE version = %s) AS apply_migration \\gset\n' "$version" >> "$execution_sql"
  append_sql \
    '\if :apply_migration' \
    'BEGIN;' \
    'LOCK TABLE snippets_private.schema_migrations, snippets_private.schema_migration_checksums IN ACCESS EXCLUSIVE MODE;' \
    'CREATE TEMP TABLE snippets_migration_versions_before ON COMMIT DROP AS SELECT * FROM snippets_private.schema_migrations;' \
    'CREATE TEMP TABLE snippets_migration_checksums_before ON COMMIT DROP AS SELECT * FROM snippets_private.schema_migration_checksums;'
  printf "\\ir 'migrations/%s'\n" "$migration_name" >> "$execution_sql"
  append_sql \
    'DO $snippets_migration$' \
    'BEGIN' \
    '  IF EXISTS (' \
    '    (SELECT * FROM snippets_private.schema_migrations EXCEPT SELECT * FROM pg_temp.snippets_migration_versions_before)' \
    '    UNION ALL' \
    '    (SELECT * FROM pg_temp.snippets_migration_versions_before EXCEPT SELECT * FROM snippets_private.schema_migrations)' \
    '  ) OR EXISTS (' \
    '    (SELECT * FROM snippets_private.schema_migration_checksums EXCEPT SELECT * FROM pg_temp.snippets_migration_checksums_before)' \
    '    UNION ALL' \
    '    (SELECT * FROM pg_temp.snippets_migration_checksums_before EXCEPT SELECT * FROM snippets_private.schema_migration_checksums)' \
    '  ) THEN' \
    "    RAISE EXCEPTION 'migration body modified the schema ledger';" \
    '  END IF;' \
    'END' \
    '$snippets_migration$;'
  printf 'INSERT INTO snippets_private.schema_migrations(version) VALUES (%s);\n' "$version" >> "$execution_sql"
  printf "INSERT INTO snippets_private.schema_migration_checksums(version, checksum) VALUES (%s, '%s');\n" "$version" "$checksum" >> "$execution_sql"
  append_sql \
    'DO $snippets_migration$' \
    'BEGIN'
  printf '  IF (SELECT count(*) FROM snippets_private.schema_migrations) <> %s\n' "$version" >> "$execution_sql"
  printf '     OR EXISTS (SELECT 1 FROM generate_series(1, %s) expected(version) WHERE NOT EXISTS (SELECT 1 FROM snippets_private.schema_migrations applied WHERE applied.version=expected.version))\n' "$version" >> "$execution_sql"
  printf '     OR (SELECT count(*) FROM snippets_private.schema_migration_checksums) <> %s\n' "$((version - 1))" >> "$execution_sql"
  printf '     OR EXISTS (SELECT 1 FROM generate_series(2, %s) expected(version) WHERE NOT EXISTS (SELECT 1 FROM snippets_private.schema_migration_checksums stored WHERE stored.version=expected.version)) THEN\n' "$version" >> "$execution_sql"
  append_sql \
    "    RAISE EXCEPTION 'migration runner failed to publish the exact expected ledger';" \
    '  END IF;' \
    'END' \
    '$snippets_migration$;' \
    'COMMIT;' \
    '\endif'
done < "$manifest_file"

# Recheck the complete structural ledger before reporting success.
append_sql 'SELECT ('
printf '  (SELECT count(*) FROM snippets_private.schema_migrations) <> %s\n' "$latest_version" >> "$execution_sql"
printf '  OR EXISTS (SELECT 1 FROM generate_series(1, %s) expected(version) WHERE NOT EXISTS (SELECT 1 FROM snippets_private.schema_migrations applied WHERE applied.version=expected.version))\n' "$latest_version" >> "$execution_sql"
printf '  OR (SELECT count(*) FROM snippets_private.schema_migration_checksums) <> %s\n' "$((latest_version - 1))" >> "$execution_sql"
printf '  OR EXISTS (SELECT 1 FROM generate_series(2, %s) expected(version) WHERE NOT EXISTS (SELECT 1 FROM snippets_private.schema_migration_checksums stored WHERE stored.version=expected.version))\n' "$latest_version" >> "$execution_sql"
append_sql \
  ') AS final_ledger_mismatch \gset' \
  '\if :final_ledger_mismatch' \
  '\echo migration runner did not reach the exact repository ledger' \
  'SELECT 1 / 0;' \
  '\endif' \
  'SELECT pg_advisory_unlock(824776254196138476);'

chmod 0400 "$manifest_file" "$execution_sql"
psql -X --file="$execution_sql"
