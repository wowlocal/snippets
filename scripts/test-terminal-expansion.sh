#!/bin/bash
# Opt-in GUI test. Requires an unlocked Mac, Accessibility for the Snippets test host, and Ghostty.
# It launches a disposable Ghostty with a clean configuration and takes the keyboard focus while it runs.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/snippets-terminal-expansion.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT
TEST_RUNNER_SNIPPETS_SUPPORT_DIR="$fixture_dir/library" TEST_RUNNER_SNIPPETS_BROWSER_SMOKE=1 \
    xcodebuild -project Snippets.xcodeproj -scheme Snippets -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
    -only-testing:'Snippets macOSTests/TerminalExpansionSmokeTests' "$@" test
