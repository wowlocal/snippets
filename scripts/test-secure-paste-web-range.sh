#!/bin/bash
# Opt-in, synthetic WebKit integration probe. No Snippets installation or user data.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/snippets-web-range-fixture.XXXXXX)
swiftc -O -parse-as-library Tests/Integration/SecurePasteWebRangeFixture.swift \
  snippets/AXMessagingBudget.swift -o "$fixture_dir/fixture"
"$fixture_dir/fixture" --benchmark
"$fixture_dir/fixture"
