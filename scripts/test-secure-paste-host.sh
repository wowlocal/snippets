#!/bin/bash
# Opt-in GUI regression test. Activates only a disposable synthetic fixture.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/snippets-secure-host.XXXXXX)
swiftc -parse-as-library Tests/Integration/SecurePasteHostFixture.swift \
  snippets/AXMessagingBudget.swift -o "$fixture_dir/fixture"
"$fixture_dir/fixture"
"$fixture_dir/fixture" --web
