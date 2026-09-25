# Suggestion search performance — 2026-09-25

Follow-up to [the browser typing audit](expansion-performance-audit.md).
Baseline: `71ae67330e01fa4c285b42c600857eb0b0cb0e65`, including the earlier AX observer
and duplicate-render fixes. This change speeds up the CPU work for a **changed** query.

## Ideas examined

| Implementation | Relevant approach | Applied here |
| --- | --- | --- |
| [fzf](https://github.com/junegunn/fzf/blob/master/src/algo/algo.go) | Normalize the pattern once, reject impossible subsequences before scoring, reuse slab memory, request positions separately. V2 uses modified Smith–Waterman with O(nm) scoring; V1 trades optimal scoring for a greedy scan. | Prepared queries, rejection before scoring, reusable workspace, separate scoring/highlighting. |
| [fff / fff.nvim](https://github.com/dmtrKovalenko/fff/blob/708d57bb3559b0313a537f31a210e2ad6c9addc5/crates/fff-core/src/score.rs) | The inspected revision uses `neo_frizbee` and a prepared path arena. `fuzzy_match_byte_offsets_for_page` derives highlights for the selected page after ranking. | Keep prepared metadata across keystrokes; derive highlight ranges only for the eight displayed suggestions. |
| [nucleo matcher](https://github.com/helix-editor/nucleo/blob/8c16d47cdfa9607d3e44df5f81c635c6f43c65ee/matcher/src/lib.rs) | Its API explicitly separates score-only methods from index-producing methods and reuses scratch buffers. | One workspace per search pass; no highlight arrays for rejected or undisplayed candidates. |
| [ordo-one/FuzzyMatch](https://github.com/ordo-one/FuzzyMatch/tree/ea09aa7faa3c1832716d1ccdb81dcb83bea89774) | A pure Swift SPM option with no external dependencies, prepared queries, and edit-distance/Smith–Waterman modes. | Evaluated as an integration option; no package added. Its matching/ranking contract differs from the existing Snippets contract. |

These are design references, not a claim that this matcher implements fzf's or
fff's scoring. No Rust/Go bridge, binary artifact, copied upstream implementation,
or new SPM dependency is required. The Swift package remains a reasonable candidate
if typo tolerance or new ranking semantics become a product requirement; it has not
been benchmarked against this implementation on the same corpus.

## Implementation

`SuggestionSearchIndex` owns an in-memory snapshot of ordinary snippets and secure
content-free shells. It prepares display names, normalized keywords, and tags once;
unchanged fields reuse their prepared values after a library edit. Full snippet
values still update, so a body-only remote edit cannot leave old text selectable.
Locale changes and ordinary/secure membership changes invalidate the snapshot.
The initial snapshot is built before installing the keyboard tap.

Each prepared field contains folded characters, word boundaries, original UTF-16
ranges, a character-to-positions table, and a 128-bit ASCII membership mask.
ASCII normalization avoids per-character Foundation calls. Unicode, Turkish/Azeri
case folding, and CRLF graphemes retain the Foundation path and original ranges.

For each query, the matcher first rejects impossible masks and subsequences.
Scoring walks occurrence lists with two reusable rows. For non-adjacent matches it
keeps the best preceding state instead of scanning every suffix of every prior state.
Adjacent streak states remain separate because Snippets' existing bonus grows with
streak length. There are no per-state dictionaries or copied highlight paths.

The scoring contract remains: 1 per character, 3 at word boundaries, 5 at the target
start, and 2 times the current consecutive streak. Final ties retain score, end
position, original UTF-16 start, and streak ordering. Fully equivalent middle paths
now resolve deterministically; the old dictionary iteration could pick different
equivalent highlights. Preserving the growing streak bonus gives O(m²n) worst-case
time, not fzf's O(mn). Long repeated-character fields remain a pathological case.

The backslash panel scores both fields without ranges, maintains a bounded sorted
list of eight candidates, and reconstructs ranges only for those rows. Existing
keyword tiers, pinning, learned query bindings, frecency, and display order still
decide ranking. Command-Backslash also reuses prepared fields; its scrollable list
still computes all result rows and highlights.

An exact-keyword dictionary replaces the per-keypress ordinary-library sort and
folding scan. Duplicate keywords and shorter prefixes of another enabled keyword
are excluded when building the dictionary. Secure shells never enter that dictionary.
The guard against deleting multi-scalar trigger graphemes remains in place.

## Reproduction

```sh
# Actual suggestion CPU path versus the previous implementation:
./scripts/benchmark-suggestion-search.sh

# Isolated matcher: old, current one-shot, and prepared-field paths:
./scripts/benchmark-expansion-matching.sh --baseline-ref 71ae673
```

Both compile with `swiftc -O`, use only generated metadata, initialize no app/store,
and remove their temporary executables. The full benchmark compiles the old matcher
from the baseline commit and a reference of the old ranking/exact-keyword path.
It compares every returned item (including ranges, secure flags and ranking fields)
and exact expansion ID with the current production search function on every pass.
It also checks that typing does not rebuild the snapshot.

Measured on Apple M4 Max, arm64, macOS 27.0, Apple Swift 6.4. Synthetic fixtures mix
Latin/Cyrillic names, diacritics, secure shells, disabled rows, and pinned rows.
Five warm-ups precede 30 samples for 100/1,000 rows and 10 samples for 10,000 rows.
The old pass runs before the new pass in each pair. This is a local microbenchmark,
not a statistically controlled comparison between devices.

### Full suggestion CPU path, milliseconds

Includes snapshot validation, matching, ranking, top-eight selection, highlights,
and ordinary exact-keyword lookup. Initial snapshot preparation is measured separately.
Excludes AX IPC, table reload/layout, keyboard delivery, and snippet insertion.

| Rows | Query | Old p50 | New p50 | Old p95 | New p95 |
| ---: | --- | ---: | ---: | ---: | ---: |
| 100 | `gh` | 3.205 | 0.033 | 3.302 | 0.038 |
| 100 | `cafe` | 3.458 | 0.034 | 3.530 | 0.038 |
| 1,000 | `gh` | 36.439 | 0.271 | 37.565 | 1.006 |
| 1,000 | `pr` | 36.634 | 0.275 | 37.877 | 0.339 |
| 1,000 | `cafe` | 39.915 | 0.273 | 40.602 | 0.982 |
| 1,000 | `ghost.40` | 45.800 | 0.179 | 46.404 | 0.927 |
| 1,000 | `zz` | 36.597 | 0.152 | 37.657 | 0.825 |
| 10,000 | `gh` | 446.144 | 4.012 | 514.457 | 8.873 |
| 10,000 | `pr` | 425.563 | 4.066 | 443.858 | 4.273 |
| 10,000 | `cafe` | 452.624 | 3.747 | 463.205 | 3.796 |
| 10,000 | `ghost.40` | 506.481 | 2.534 | 510.244 | 2.603 |
| 10,000 | `zz` | 415.773 | 2.297 | 421.164 | 2.433 |

The 1,000-row cases improve by 133–256 times in median CPU time. Snapshot builds
take 4.140 / 11.786 / 118.580 ms for 100 / 1,000 / 10,000 mixed rows respectively;
the first includes process initialization overhead. Initial preparation runs before
the event tap, but a subsequent library/locale change rebuilds on demand. This remains
a possible cold pause for very large libraries. Memory now scales with prepared
metadata; memory usage was not profiled in this audit.

### Isolated matcher

For 1,000 ASCII rows, `p` / `pr` / `proj` go from 20.620 / 22.588 / 26.579 ms to
0.098 / 0.163 / 0.305 ms with prepared targets and eight highlighted rows.
For 1,000 Unicode rows, `п` / `пр` / `cafe` go from 21.227 / 23.611 / 26.201 ms to
0.135 / 0.248 / 0.228 ms. Target preparation costs 3.644 ms for ASCII and 23.293 ms
for Unicode. The unprepared Unicode API is not faster in every case: repeatedly
rebuilding preparation is still expensive. Callers get the main benefit by reusing
prepared fields, not merely by calling the replacement one-shot API.

## Verification

- CorePackage passed: 1,044 tests across its test executables, including the new
  exhaustive matcher oracle (14,560 small input pairs), Unicode/locale UTF-16
  checks, repeated-character scoring, and score-only/highlight parity.
- macOS Debug and iOS Simulator Debug builds passed.
- All 19 selected macOS tests passed: search index, observer registration, result
  updater, and suggestion-panel keyboard behavior. Index tests cover body-only
  edits, locale changes, secure transitions, collisions/prefixes, disabled records,
  top-eight selection, empty queries, learned bindings, and frecency.
- iPhone simulator: unit suite 521 tests (1 skipped), UI suite 13 tests (6 skipped),
  zero failures. iPad simulator: unit suite 521 tests (1 skipped), UI suite 13 tests
  (7 skipped), zero failures. Skips are the existing device-specific, hardware-keyboard,
  screenshot-capture, and opt-in Cloud integration/auth cases. UI launches retain
  `--ui-testing-reset` and temporary storage safeguards.

No new diagnostics events or persistent caches were added. The installed production
Mac app has not been replaced. A live browser before/after replay is still needed
to quantify end-to-end typing latency: synchronous AX reads remain a separate risk
identified in the original audit.
