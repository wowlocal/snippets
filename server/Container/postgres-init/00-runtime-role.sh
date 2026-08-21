#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SNIPPETS_RUNTIME_PASSWORD:-}" ]]; then
    echo "SNIPPETS_RUNTIME_PASSWORD is required" >&2
    exit 1
fi

psql \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --set ON_ERROR_STOP=1 \
    --set runtime_password="$SNIPPETS_RUNTIME_PASSWORD" <<'SQL'
DO $role$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'snippets_function_owner') THEN
        CREATE ROLE snippets_function_owner NOLOGIN
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'snippets_runtime') THEN
        CREATE ROLE snippets_runtime LOGIN
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
END
$role$;

SELECT format(
    'ALTER ROLE snippets_runtime WITH LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS',
    :'runtime_password'
) \gexec
SQL
