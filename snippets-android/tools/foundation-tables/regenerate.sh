#!/bin/sh
# Regenerates the Foundation-derived tables and corpora used by :core.
# Run on a Mac with Xcode; takes about a minute. See README.md.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
android="$(cd "$here/../.." && pwd)"
repository="$(cd "$android/.." && pwd)"
resources="$android/core/src/main/resources/com/khm/snippets/core/text"
fixtures="$android/core/src/test/resources/fixtures/foundation"

build="$(mktemp -d "${TMPDIR:-/tmp}/foundation-tables.XXXXXX")"
trap 'rm -rf "$build"' EXIT

# Optimised: the probes build tens of millions of short strings.
xcrun swiftc -O -suppress-warnings -o "$build/foundation-tables" \
    "$here"/Sources/*.swift \
    "$repository/snippets/Core/Snippet.swift" \
    "$repository/snippets/Core/SnippetLibraryCodec.swift"

mkdir -p "$resources" "$fixtures"
"$build/foundation-tables" "$resources" "$fixtures" "$(xcrun swift --version 2>/dev/null | head -n 1)"
