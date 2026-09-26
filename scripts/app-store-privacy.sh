#!/bin/bash
# Optional Apple web-session bridge. These actions are never part of metadata sync.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:---help}" in
    --help|-h)
        echo 'Usage: scripts/app-store-privacy.sh plan|apply|publish'
        echo 'Uses the authenticated asc web session. apply updates the draft; publish publishes it.'
        exit 0 ;;
    plan|apply|publish) ACTION="$1" ;;
    *) echo 'Expected plan, apply, or publish' >&2; exit 1 ;;
esac
[ "$#" -eq 1 ] || { echo 'Unexpected arguments' >&2; exit 1; }
function fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
EXPECTED_BUNDLE_IDENTIFIER=com.khm.snippets
CONFIG_FILE="${SNIPPETS_ASC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/snippets/app-store-connect.env}"
source "$PROJECT_DIR/scripts/lib/asc-common.sh"
load_configuration
app_json="$(asc_cli apps list --bundle-id "$EXPECTED_BUNDLE_IDENTIFIER" --output json)"
jq -e --arg id "$ASC_APP_ID" --arg bundle "$EXPECTED_BUNDLE_IDENTIFIER" \
    'any(.data[]; .id == $id and .attributes.bundleId == $bundle)' <<< "$app_json" >/dev/null \
    || fail "App Store app identity mismatch"
case "$ACTION" in
    plan|apply)
        asc_cli web privacy "$ACTION" --app "$ASC_APP_ID" \
            --file "$PROJECT_DIR/Distribution/AppStore/privacy.json" --output json ;;
    publish)
        # Compare the draft with the approved local declaration before publishing.
        # This command is explicit; the agent must inspect `plan` before invoking it.
        asc_cli web privacy publish --app "$ASC_APP_ID" --confirm --output json
        asc_cli web privacy pull --app "$ASC_APP_ID" --output json ;;
esac
