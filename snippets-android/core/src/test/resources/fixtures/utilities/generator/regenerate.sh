#!/bin/bash
# Rebuilds the swift-*.tsv fixtures next to this folder by running the unmodified Swift
# sources. Run on a Mac, from anywhere:
#
#   core/src/test/resources/fixtures/utilities/generator/regenerate.sh
#
# Nothing under snippets/ is changed or copied; the Swift files are compiled in place.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fixtures="$(dirname "$here")"
repository="$(cd "$here/../../../../../../../.." && pwd)"
core="$repository/snippets/Core"
build="$(mktemp -d "${TMPDIR:-/tmp}/snippets-utilities-probe.XXXXXX")"
trap 'rm -rf "$build"' EXIT

xcrun swiftc -swift-version 6 -o "$build/probe" "$here/main.swift" \
  "$core/FuzzyMatch.swift" "$core/PreparedSubstringSearch.swift" "$core/PlaceholderResolver.swift" \
  "$core/RaycastPlaceholders.swift" "$core/KeywordSuggestions.swift" "$core/SettingsCatalog.swift" \
  "$core/Snippet.swift" "$core/SnippetDeepLink.swift" "$core/SnippetImportParser.swift" \
  "$core/SnippetSearchIndex.swift" 2>/dev/null

for section in fuzzy substring settings settings-catalog keywords tags grammar links link-encode dates calendar; do
  "$build/probe" "$section" > "$fixtures/swift-$section.tsv"
  echo "swift-$section.tsv: $(grep -vc '^#' "$fixtures/swift-$section.tsv") lines"
done
"$build/probe" locales > "$fixtures/swift-available-locales.txt"
echo "swift-available-locales.txt: $(grep -vc '^#' "$fixtures/swift-available-locales.txt") lines"
