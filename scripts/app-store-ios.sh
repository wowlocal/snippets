#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -eq 0 ] || [ "$1" = --help ] || [ "$1" = -h ]; then
    exec python3 "$PROJECT_DIR/scripts/lib/ios_release.py" --help
fi
function fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
EXPECTED_BUNDLE_IDENTIFIER=com.khm.snippets
CONFIG_FILE="${SNIPPETS_ASC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/snippets/app-store-connect.env}"
source "$PROJECT_DIR/scripts/lib/asc-common.sh"
load_configuration
exec python3 "$PROJECT_DIR/scripts/lib/ios_release.py" "$@"
