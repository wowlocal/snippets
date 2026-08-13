#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"
repository_dir="$(cd "$server_dir/.." && pwd)"
normative="$repository_dir/api/snippets-sync-v1.yaml"
generator_input="$server_dir/Sources/SyncOpenAPI/openapi.yaml"

if [[ "${1:-}" == "--sync" ]]; then
    cp "$normative" "$generator_input"
fi
if ! cmp --silent "$normative" "$generator_input"; then
    echo "OpenAPI generator input differs from api/snippets-sync-v1.yaml" >&2
    echo "Run server/Scripts/check-openapi.sh --sync after reviewing the normative contract." >&2
    exit 1
fi
