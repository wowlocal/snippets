#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/snippets-matching.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Standalone synthetic benchmark: no app, store, keychain, or live library access.
xcrun swiftc -O \
  "$repo_root/snippets/Core/FuzzyMatch.swift" \
  "$repo_root/Tests/Harnesses/ExpansionMatchingBenchmark.swift" \
  -o "$scratch/benchmark"
"$scratch/benchmark"
