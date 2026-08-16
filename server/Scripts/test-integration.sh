#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"
compose_project="snippets-sync-integration"
test_port="${SNIPPETS_TEST_DATABASE_PORT:-55432}"
owner_password="integration-owner-only"
runtime_password="integration-runtime-only"

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

cleanup() { compose down --volumes --remove-orphans; }
trap cleanup EXIT

compose up --detach --wait postgres

docker run --rm \
    --network "${compose_project}_default" \
    --volume "$server_dir:/source" \
    --workdir /source \
    --env SNIPPETS_INTEGRATION_TESTS=1 \
    --env DATABASE_HOST=postgres \
    --env DATABASE_PORT=5432 \
    --env DATABASE_NAME=snippets_sync_test \
    --env DATABASE_RUNTIME_USER=snippets_runtime \
    --env DATABASE_RUNTIME_PASSWORD="$runtime_password" \
    --env DATABASE_OWNER_USER=snippets_owner \
    --env DATABASE_OWNER_PASSWORD="$owner_password" \
    --env DATABASE_TLS_MODE=disable \
    golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 \
    sh -c 'go test -race ./internal/postgres'
