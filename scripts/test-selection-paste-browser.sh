#!/bin/bash
# Opt-in GUI test. Uses only a temporary Chrome profile and synthetic fields.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/snippets-selection-browser.XXXXXX)
swift build --package-path CorePackage --build-tests >/dev/null
build_dir=$(swift build --package-path CorePackage --show-bin-path)
swiftc -parse-as-library -I "$build_dir" \
  Tests/Integration/SelectionPasteBrowserFixture.swift snippets/TemporaryPasteboardLease.swift \
  "$build_dir/libSnippetsCore.a" -o "$fixture_dir/fixture"
"$fixture_dir/fixture" "$fixture_dir" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
