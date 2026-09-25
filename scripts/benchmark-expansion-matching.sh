#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/snippets-matching.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != "--baseline-ref" ]]; then
    echo 'usage: benchmark-expansion-matching.sh [--baseline-ref <git-ref>]' >&2
    exit 2
  fi
  baseline_commit="$(git -C "$repo_root" rev-parse --verify --end-of-options "$2^{commit}")"
  git -C "$repo_root" show "$baseline_commit:snippets/Core/FuzzyMatch.swift" > "$scratch/BaselineFuzzyMatch.swift"
  xcrun swiftc -O "$scratch/BaselineFuzzyMatch.swift" \
    "$repo_root/Tests/Harnesses/ExpansionMatchingBenchmark.swift" -o "$scratch/baseline"
  echo "baseline=$baseline_commit"
  "$scratch/baseline"
fi

# Standalone synthetic benchmark: no app, store, keychain, or live library access.
xcrun swiftc -O -D PREPARED_FUZZY_BENCHMARK \
  "$repo_root/snippets/Core/FuzzyMatch.swift" \
  "$repo_root/Tests/Harnesses/ExpansionMatchingBenchmark.swift" \
  -o "$scratch/benchmark"
echo 'current'
"$scratch/benchmark"
