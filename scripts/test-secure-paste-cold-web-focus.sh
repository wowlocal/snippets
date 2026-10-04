#!/bin/bash
# Opt-in GUI regression test. Activates only a disposable synthetic WKWebView fixture
# and checks that Secure Paste capture waits for WebKit's lazily published focus.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/snippets-cold-web-focus.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -parse-as-library Tests/Integration/SecurePasteColdWebFocusFixture.swift \
  snippets/AXMessagingBudget.swift -o "$fixture_dir/fixture"
"$fixture_dir/fixture"
