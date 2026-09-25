# Library, clipboard, and picker search — 2026-09-25

Follow-up to [the expansion search optimization](suggestion-search-performance.md).
Baseline: `162be75d0a7f30465ae85dd9dd5cc5b34f230166`. Scope: library search on
Mac/iPhone/iPad, clipboard history on Mac, and highlights in Command-Backslash.
No package dependency was added. Settings search is unchanged.

## Library

`SnippetStore` now retains a `SnippetLibraryProjection`: display order, tag counts,
tag labels, and canonical tag keys. Repeated keystrokes reuse it instead of sorting
and normalizing every tag on the UI actor before submitting background search.
Both ordinary and secure-shell arrays and the locale participate in invalidation.
Body-only edits still replace selectable snippet values.

`SnippetSearchIndex` now keeps one previous scan against an immutable snapshot.
A normalized prefix extension can scan only the previous matches. Backspace,
replacement, locale changes, and library mutations force a fresh scan. The saved
candidate set is independent of active tag filters: relaxing a filter cannot lose
valid results. Sequence and snapshot checks prevent an older concurrent search from
replacing a newer cache. Existing worker coalescing and UI generation checks remain.

Search accepts a fuzzy subsequence in an explicit name, keyword, or tag. For example,
`prjal` finds `Project Alpha`. Full content still uses a contiguous substring. An
unnamed snippet's first body line is not treated as fuzzy metadata. Filtering retains
the existing display/pinned order; it does not introduce a new relevance sort.
Secure records participate only through their content-free shells.

The query is prepared once. Library filtering uses membership checks, without score
matrices or highlight paths. It checks short metadata before scanning a large body.
The existing 16 MiB estimated normalization budget includes the added structures;
overflow entries remain searchable through the uncached fallback.

## Prepared substring matching

The initial benchmark exposed another cost: repeatedly calling `String.contains`
over megabytes of already-folded text. `PreparedSubstringSearch` stores ASCII fields
as `Data` and uses Foundation byte search, preceded by an ASCII membership mask.
That byte storage replaces the folded body String. Metadata retained for fuzzy
matching is included in the library cache accounting.

Unicode fields retain canonical `String.contains` behavior. ASCII matches validate
CRLF boundaries, so a standalone CR/LF cannot match half of a Swift grapheme. Queries
use canonical decomposition when choosing their ASCII representation, preserving
equivalences such as the Kelvin sign. Empty substring behavior also matches the
original API; empty *search requests* are handled separately by each product's policy.
Case/diacritic folding and locale decisions remain with the calling search index.

## Clipboard history

The panel captures current entries on MainActor and sends nonempty queries to a
serial worker. Only one active and one pending request are retained; newer queries
replace the pending request. The worker reuses a bounded 32 MiB prepared index and
keeps the existing AND-of-words, case/diacritic-insensitive substring semantics and
recency order. Original entry bytes remain the source for copying/pasting.

Worker and UI generation checks reject stale results after edits, deletion, clear,
disable, dismissal, or a newer presentation. A fast Return or Command-number waits
for the current results instead of accepting an old row. A newer query cancels that
pending acceptance; status-only notifications do not cancel it. Selected identity
and preview whitespace remain intact. Empty searches bypass the worker, and closing
the panel or clearing the query releases the prepared cache on its worker queue.
An already executing scan may finish, but cannot republish into the closed panel.
No plaintext index, query, or clipboard contents are written to disk or diagnostics.

## Command-Backslash

The picker scores candidates without highlight ranges. Each result retains immutable
prepared fields and a query for optional highlighting. `NSTableView` resolves those
ranges as it requests a cell, including after scrolling. A bounded 128-row cache avoids
repeating work for recently displayed rows and resets on every result replacement.
The full ranked result set, secure-ranking policy, and keyboard selection remain.
Ordinary backslash suggestions still compute ranges for their top eight rows.

## Reproduction and measurements

```sh
./scripts/benchmark-library-search.sh
```

This compiles the current production search components and the baseline library index
with `swiftc -O`. It initializes no store, app, pasteboard, or vault and uses synthetic
data only. Run with no builds/tests in progress. The script removes its temporary
executable. The baseline ref may be passed as its first argument.

Measurements: Apple M4 Max, arm64, macOS 27.0, Apple Swift 6.4. Library/clipboard cases
have three warm-ups and 20 samples; picker matching has three warm-ups and 30 samples.
The table reports p50/p95 milliseconds. Initial preparation is measured separately.
These are local CPU measurements, excluding worker scheduling, UI layout and rendering.

Library bodies contain the complete ASCII alphabet, so rejected queries also exercise
byte search rather than benefiting only from the character mask. Each timed library
query adds one character to a prepared prefix. The baseline includes tag aggregation,
display sorting and its existing cached substring index. The current path includes
projection validation and its indexed search. This corpus intentionally produces the
same result sets under substring and fuzzy metadata matching; every result and tag
count is compared, and typing is required to build the projection only once.

| Library rows / body size | Query | Old p50 | New p50 | Old p95 | New p95 |
| --- | --- | ---: | ---: | ---: | ---: |
| 1,000 / 4 KiB | `g` | 2.893 | 0.110 | 3.179 | 0.136 |
| 1,000 / 4 KiB | `gh` | 2.884 | 0.306 | 3.045 | 0.324 |
| 1,000 / 4 KiB | `gho` | 55.102 | 1.014 | 56.744 | 1.190 |
| 1,000 / 4 KiB | `ghost` | 54.780 | 0.063 | 55.992 | 0.077 |
| 1,000 / 4 KiB | `ghx` | 68.982 | 1.220 | 70.105 | 1.480 |
| 1,000 / 4 KiB | `zz` | 64.823 | 1.654 | 66.595 | 1.886 |
| 10,000 / 512 B | `gho` | 93.285 | 4.099 | 96.084 | 4.474 |
| 10,000 / 512 B | `ghost` | 92.977 | 0.466 | 98.367 | 0.498 |
| 10,000 / 512 B | `ghx` | 111.049 | 4.622 | 112.910 | 5.058 |

Initial library preparation: 18.479 ms for 1,000 rows and 82.770 ms for 10,000 rows.
It is not included in warm-query numbers. Library/locale changes can require rebuilding;
prefix narrowing does not apply to arbitrary query replacement.

| Clipboard, 1,000 entries / 4 KiB | Old p50 | New p50 | Old p95 | New p95 |
| --- | ---: | ---: | ---: | ---: |
| `c` | 0.590 | 0.073 | 0.605 | 0.075 |
| `cafe` | 245.198 | 2.711 | 248.385 | 2.862 |
| `cafe token` | 246.395 | 2.716 | 248.529 | 2.788 |
| `zz` | 307.265 | 1.810 | 311.248 | 1.887 |

Initial clipboard preparation: 13.066 ms, on the worker. The benchmark verifies exact
returned entries and requires preparation once per entry. Non-ASCII folded bodies
use the Unicode path; these ASCII-heavy numbers are not a claim of equal speedups for
all languages, body sizes, or queries. Over-budget entries retain the old scan.

Command-Backslash matching/highlighting for 1,000 rows and eight requested cells:
0.348 → 0.293 ms p50, 0.357 → 0.298 ms p95. This stage already used the optimized matcher;
its additional time reduction is modest. Highlight paths fall from 2,000 fields to 16
for that viewport. AppKit tests separately check that opening a 400-row list does not
resolve all rows, scrolling resolves new rows, and query changes invalidate ranges.

## Verification

Core tests cover literal/fuzzy scope, preserved order, narrowing and reset, tag-filter
relaxation, locale/library edits, bounded fallback, Unicode and CRLF, unchanged clipboard
bytes, coalescing, and stale-result cancellation. macOS tests cover deferred acceptance,
dismiss/reopen, history deletion, menu tracking, lazy highlights and keyboard selection.
Both platform builds and the iPhone/iPad unit/UI suites exercise the app integrations.

- `swift test --package-path CorePackage`: 1,051 tests passed.
- macOS arm64 Debug build: passed.
- iOS generic Simulator Debug build: passed.
- macOS clipboard panel/service/menu and suggestion panel/index suites: 45 tests passed.
- iPhone Simulator: 521 unit tests (1 skipped), 13 UI tests (6 skipped), no failures;
  `xcodebuild test` succeeded.
- iPad Simulator: 521 unit tests (1 skipped), 13 UI tests (7 skipped), no failures;
  `xcodebuild test` succeeded.

The first iPad run completed all cases without test failures, then Xcode stalled while
finalizing its logs. That runner was stopped and verification repeated separately.
The final iPhone run also passed after one simulator animation-idle wait timed out;
the search assertion itself succeeded. Skips cover opt-in/device-specific scenarios.
The production Mac app is not installed by these checks, and live browser AX latency
remains outside these search-only measurements.
