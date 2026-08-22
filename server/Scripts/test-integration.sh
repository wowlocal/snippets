#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"
compose_project="snippets-sync-integration"
test_port="${SNIPPETS_TEST_DATABASE_PORT:-55432}"
owner_password="integration-owner-only"
runtime_password="integration-runtime-only"
schema_password="integration-schema-only"

compose() {
    POSTGRES_DB=snippets_sync_test \
    POSTGRES_USER=snippets_owner \
    POSTGRES_PASSWORD="$owner_password" \
    SNIPPETS_RUNTIME_PASSWORD="$runtime_password" \
    DATABASE_PORT="$test_port" \
    SNIPPETS_ENV=testing \
    PUBLIC_BASE_URL=http://127.0.0.1:8080 \
    SERVER_INSTANCE_ID=00000000-0000-0000-0000-000000000001 \
    TOKEN_HMAC_SECRET=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
    IDENTITY_PEPPER=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI= \
    OIDC_ISSUER=https://identity.example.invalid/ \
    OIDC_JWKS_URL=https://identity.example.invalid/jwks \
    OIDC_AUDIENCE=http://127.0.0.1:8080 \
    OIDC_CLIENT_ID=snippets-test \
    docker compose --file "$server_dir/docker-compose.yml" \
        --project-directory "$server_dir" --project-name "$compose_project" "$@"
}

run_migrations() {
    local database="$1"
    docker run --rm \
        --network "${compose_project}_default" \
        --volume "$server_dir:/source:ro" \
        --env PGHOST=postgres \
        --env PGDATABASE="$database" \
        --env PGUSER=snippets_owner \
        --env PGPASSWORD="$owner_password" \
        postgres:18.4-bookworm@sha256:882236b897e39051d2368c5ccc6cda944904723506b2dfc97f2a8f5bc9afa382 \
        /source/Scripts/migrate.sh
}

cleanup() { compose down --volumes --remove-orphans; }
trap cleanup EXIT

compose up --detach --wait postgres

# Re-run the fresh bootstrap as a database owner that is not a superuser or a
# BYPASSRLS role. The cluster administrator pre-creates the dedicated function
# owner and grants the installer membership, matching managed PostgreSQL setup.
compose exec --no-TTY postgres psql --username snippets_owner --dbname postgres --set ON_ERROR_STOP=1 <<SQL
CREATE ROLE snippets_schema_installer LOGIN PASSWORD '$schema_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOBYPASSRLS;
GRANT snippets_function_owner TO snippets_schema_installer;
CREATE DATABASE snippets_non_super OWNER snippets_schema_installer;
SQL
compose exec --no-TTY --env PGPASSWORD="$schema_password" postgres \
    psql --host 127.0.0.1 --username snippets_schema_installer --dbname snippets_non_super \
    --set ON_ERROR_STOP=1 --file /docker-entrypoint-initdb.d/10-schema.sql
function_owners=$(compose exec --no-TTY postgres psql --username snippets_owner --dbname snippets_non_super \
    --tuples-only --no-align --set ON_ERROR_STOP=1 --command \
    "SELECT bool_and(owner.rolbypassrls AND NOT owner.rolcanlogin) FROM pg_proc candidate JOIN pg_roles owner ON owner.oid=candidate.proowner WHERE candidate.pronamespace='snippets_private'::regnamespace AND candidate.prosecdef;")
if [[ "${function_owners//$'\r'/}" != "t" ]]; then
    echo "security-definer functions do not have the dedicated BYPASSRLS owner" >&2
    exit 1
fi

# A current database must make the pending-only runner a no-op. Replaying the
# historical v2 DDL against schema v3 would fail and is therefore caught here.
for _ in 1 2; do
    run_migrations snippets_sync_test
done

# The ledger must reject a modified historical file, an applied-version gap, and a
# database newer than this checkout. Use a disposable database so the service test
# keeps running against an intact current schema.
compose exec --no-TTY postgres psql --username snippets_owner --dbname postgres \
    --set ON_ERROR_STOP=1 --command "CREATE DATABASE snippets_migration_validation"
compose exec --no-TTY postgres psql --username snippets_owner \
    --dbname snippets_migration_validation --set ON_ERROR_STOP=1 \
    --file /docker-entrypoint-initdb.d/10-schema.sql
compose exec --no-TTY postgres psql --username snippets_owner \
    --dbname snippets_migration_validation --set ON_ERROR_STOP=1 \
    --command "DROP TABLE snippets_private.schema_migration_checksums; DELETE FROM snippets_private.schema_migrations WHERE version != 3"
run_migrations snippets_migration_validation
compose exec --no-TTY postgres psql --username snippets_owner \
    --dbname snippets_migration_validation --set ON_ERROR_STOP=1 \
    --command "UPDATE snippets_private.schema_migration_checksums SET checksum=repeat('0',64) WHERE version=2"
if run_migrations snippets_migration_validation; then
    echo "migration runner accepted a checksum mismatch" >&2
    exit 1
fi
compose exec --no-TTY postgres psql --username snippets_owner \
    --dbname snippets_migration_validation --set ON_ERROR_STOP=1 \
    --command "UPDATE snippets_private.schema_migration_checksums SET checksum='77883c46eac62ae3f13a05ea45d9632e7a92963994712575495d0425fcfbe12c' WHERE version=2"
run_migrations snippets_migration_validation
compose exec --no-TTY postgres psql --username snippets_owner \
    --dbname snippets_migration_validation --set ON_ERROR_STOP=1 \
    --command "DELETE FROM snippets_private.schema_migration_checksums WHERE version=2; DELETE FROM snippets_private.schema_migrations WHERE version=2"
if run_migrations snippets_migration_validation; then
    echo "migration runner accepted a gap in applied history" >&2
    exit 1
fi
compose exec --no-TTY postgres psql --username snippets_owner \
    --dbname snippets_migration_validation --set ON_ERROR_STOP=1 \
    --command "INSERT INTO snippets_private.schema_migrations(version) VALUES (2); INSERT INTO snippets_private.schema_migration_checksums(version,checksum) VALUES (2,'77883c46eac62ae3f13a05ea45d9632e7a92963994712575495d0425fcfbe12c')"
run_migrations snippets_migration_validation
compose exec --no-TTY postgres psql --username snippets_owner \
    --dbname snippets_migration_validation --set ON_ERROR_STOP=1 \
    --command "INSERT INTO snippets_private.schema_migrations(version) VALUES (5)"
if run_migrations snippets_migration_validation; then
    echo "migration runner accepted an unknown newer version" >&2
    exit 1
fi

docker run --rm \
    --network "${compose_project}_default" \
    --volume "$server_dir:/source" \
    --workdir /source \
    --env SNIPPETS_INTEGRATION_TESTS=1 \
    --env SNIPPETS_COMPACTION_SCALE_TESTS="${SNIPPETS_COMPACTION_SCALE_TESTS:-1}" \
    --env DATABASE_HOST=postgres \
    --env DATABASE_PORT=5432 \
    --env DATABASE_NAME=snippets_sync_test \
    --env DATABASE_RUNTIME_USER=snippets_runtime \
    --env DATABASE_RUNTIME_PASSWORD="$runtime_password" \
    --env DATABASE_OWNER_USER=snippets_owner \
    --env DATABASE_OWNER_PASSWORD="$owner_password" \
    --env DATABASE_TLS_MODE=disable \
    golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 \
    sh -c 'go test -race -v ./internal/postgres'
