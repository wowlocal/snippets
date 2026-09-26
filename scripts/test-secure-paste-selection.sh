#!/bin/bash
# Opt-in GUI test: activates a disposable fixture and clicks only its own window.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/snippets-selection-fixture.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT
swiftc -parse-as-library Tests/Integration/SecurePasteSelectionClickFixture.swift \
  snippets/AXMessagingBudget.swift snippets/SecurePasteTargetResolver.swift \
  -o "$fixture_dir/fixture"
"$fixture_dir/fixture"
