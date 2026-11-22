#!/bin/bash
# Opt-in GUI test. Requires an unlocked Mac, Accessibility for the Snippets test host, Chrome, Safari, Preview, Script Editor and TextEdit. Electron, Cursor and Zed are optional.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/snippets-browser-expansion.XXXXXX)
cleanup() {
    local status=$?
    /usr/bin/osascript Tests/Integration/CloseSafariExpansionFixture.applescript "$fixture_dir" || status=1
    rm -rf "$fixture_dir"
    exit "$status"
}
trap cleanup EXIT
xcrun swiftc -parse-as-library Tests/Integration/BrowserExpansionWebKitHost.swift -o "$fixture_dir/webkit-host"
TEST_RUNNER_SNIPPETS_SUPPORT_DIR="$fixture_dir/library" TEST_RUNNER_SNIPPETS_BROWSER_FIXTURE_ROOT="$fixture_dir" TEST_RUNNER_SNIPPETS_BROWSER_SMOKE=1 TEST_RUNNER_SNIPPETS_WEBKIT_TEST_HOST="$fixture_dir/webkit-host" \
    xcodebuild -project Snippets.xcodeproj -scheme Snippets -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
    -only-testing:'Snippets macOSTests/BrowserExpansionSmokeTests' \
    -only-testing:'Snippets macOSTests/CodeEditorExpansionSmokeTests' \
    -only-testing:'Snippets macOSTests/PreviewExpansionSmokeTests' \
    -only-testing:'Snippets macOSTests/DocumentEditorExpansionSmokeTests' "$@" test
