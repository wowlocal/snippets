#!/bin/bash
# Opt-in GUI regression; only a disposable host with synthetic content is used.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/snippets-broken-ax.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT
swiftc -parse-as-library Tests/Integration/SecurePasteBrokenAXFixture.swift \
  snippets/AXMessagingBudget.swift -o "$fixture_dir/fixture"
"$fixture_dir/fixture"
