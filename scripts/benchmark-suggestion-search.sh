#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/snippets-search.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export SNIPPETS_SUPPORT_DIR="$scratch/support"

baseline_ref="${1:-71ae673}"
baseline_commit="$(git -C "$repo_root" rev-parse --verify --end-of-options "$baseline_ref^{commit}")"
git -C "$repo_root" show "$baseline_commit:snippets/Core/FuzzyMatch.swift" \
  | sed 's/nonisolated struct FuzzyMatch/nonisolated struct ReferenceFuzzyMatch/' > "$scratch/ReferenceFuzzyMatch.swift"
xcrun swiftc -O \
  "$scratch/ReferenceFuzzyMatch.swift" \
  "$repo_root/snippets/Core/FuzzyMatch.swift" \
  "$repo_root/snippets/Core/Snippet.swift" \
  "$repo_root/snippets/Core/SnippetFrecency.swift" \
  "$repo_root/snippets/SuggestionSearchIndex.swift" \
  "$repo_root/Tests/Harnesses/SuggestionSearchBenchmark.swift" \
  -o "$scratch/benchmark"
echo "baseline=$baseline_commit"
"$scratch/benchmark"
