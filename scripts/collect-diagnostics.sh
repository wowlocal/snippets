#!/bin/bash

set -euo pipefail

MODE=""
DEVICE=""
BUNDLE_IDENTIFIER="com.khm.snippets"
OUTPUT=""

function usage() {
    cat <<'EOF'
Copy Snippets' retained, privacy-filtered JSONL diagnostics.

Usage:
  ./scripts/collect-diagnostics.sh --mac [--output <directory>]
  ./scripts/collect-diagnostics.sh --ios --device <name> [options]

Options:
  --mac                  Collect from this Mac's Snippets support folder.
  --ios                  Collect from a paired iPhone or iPad app data container.
  --ipad                 Legacy alias for --ios.
  --device <name>        Paired iPhone/iPad name understood by devicectl.
  --debug                Use the Debug iOS bundle, com.khm.snippets.debug.
  --output <directory>   New destination directory. The default is timestamped in $PWD.
  -h, --help             Show this help.

The copied files contain JSON Lines, not snippet data. Secure-snippet keywords are
approved diagnostic metadata. Bodies, names, tags, record IDs, paths, keys and
ciphertext are excluded by the app's typed logging API.
EOF
}

function fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mac)
            [ -z "$MODE" ] || fail "Choose exactly one of --mac or --ios"
            MODE="mac"
            shift
            ;;
        --ios|--ipad)
            [ -z "$MODE" ] || fail "Choose exactly one of --mac or --ios"
            MODE="ios"
            shift
            ;;
        --device)
            [ "$#" -ge 2 ] || fail "--device requires a value"
            DEVICE="$2"
            shift 2
            ;;
        --debug)
            BUNDLE_IDENTIFIER="com.khm.snippets.debug"
            shift
            ;;
        --output)
            [ "$#" -ge 2 ] || fail "--output requires a directory"
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[ -n "$MODE" ] || fail "Choose --mac or --ios"
if [ -z "$OUTPUT" ]; then
    OUTPUT="$PWD/Snippets-Diagnostics-$(date -u +%Y%m%d-%H%M%S)"
fi
[ ! -e "$OUTPUT" ] || fail "Destination already exists: $OUTPUT"

mkdir -m 700 "$OUTPUT"

if [ "$MODE" = "mac" ]; then
    LOGS_DIRECTORY="$HOME/Library/Application Support/SnippetsClone/Diagnostics/Logs"
    [ -d "$LOGS_DIRECTORY" ] || fail "No retained diagnostics were found on this Mac"
    cp -R "$LOGS_DIRECTORY" "$OUTPUT/Logs"
else
    [ -n "$DEVICE" ] || fail "--device <name> is required for iOS collection"
    command -v xcrun >/dev/null 2>&1 || fail "xcrun is required for iOS collection"
    xcrun devicectl device copy from \
        --device "$DEVICE" \
        --source "Library/Application Support/SnippetsClone/Diagnostics/Logs" \
        --destination "$OUTPUT/Logs" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_IDENTIFIER" \
        --quiet
fi

find "$OUTPUT" -type d -exec chmod 700 {} +
find "$OUTPUT" -type f -exec chmod 600 {} +

file_count="$(find "$OUTPUT/Logs" -type f -name '*.jsonl' | wc -l | tr -d ' ')"
printf 'Collected %s JSONL file(s) into %s\n' "$file_count" "$OUTPUT"
