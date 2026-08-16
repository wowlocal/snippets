#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"
repository_dir="$(cd "$server_dir/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

docker run --rm \
    --volume "$repository_dir:/workspace" \
    --workdir /workspace/server \
    golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 \
    sh -c 'go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.8.0 -config internal/api/oapi-codegen.yaml ../api/snippets-sync-v2.yaml'

git -C "$repository_dir" diff --exit-code -- server/internal/api/generated.go
