#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/snippets-library-search.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
baseline_commit="$(git -C "$repo_root" rev-parse --verify --end-of-options "${1:-162be75}^{commit}")"
git -C "$repo_root" show "$baseline_commit:snippets/Core/SnippetSearchIndex.swift" \
  | sed 's/SnippetSearch/ReferenceSnippetSearch/g' > "$scratch/ReferenceSearch.swift"
xcrun swiftc -O \
  "$scratch/ReferenceSearch.swift" \
  "$repo_root/snippets/Core/Snippet.swift" \
  "$repo_root/snippets/Core/SnippetFrecency.swift" \
  "$repo_root/snippets/Core/FuzzyMatch.swift" \
  "$repo_root/snippets/Core/PreparedSubstringSearch.swift" \
  "$repo_root/snippets/Core/SnippetSearchIndex.swift" \
  "$repo_root/snippets/Core/ClipboardHistory.swift" \
  "$repo_root/snippets/Core/ClipboardHistorySearch.swift" \
  "$repo_root/snippets/SuggestionSearchIndex.swift" \
  "$repo_root/Tests/Harnesses/LibrarySearchBenchmark.swift" \
  -o "$scratch/benchmark"
echo "baseline=$baseline_commit"
"$scratch/benchmark"
