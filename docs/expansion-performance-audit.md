# Browser typing performance audit — 2026-09-25

Baseline: `6ed85f0`. Symptom: quickly typing `\ghost` in a browser makes letters
appear late, as if input is blocked. The browser and editor control were not identified.

## Findings

### 1. Observer registration blocks the keyboard's run loop

`SnippetExpansionEngine.installEventTap()` installs the active event tap on the main
run loop. macOS waits for its synchronous callback to decide whether to deliver a key.
Other synchronous work on that loop can therefore delay even the *next* key callback.

`startSuggestionAccessibilityObserver()` previously yielded a MainActor task before
calling `installSuggestionAccessibilityObserver()`. That left the initial callback,
but still ran setup on the keyboard's run loop. Setup registered value and selection
notifications on the focused object plus up to four ancestors: up to ten synchronous
`AXObserverAddNotification` calls. These calls did not use the aggregate AX messaging
budget. Dismissal synchronously called `AXObserverRemoveNotification` on the same loop.

A 30-second, 2 ms sampling run against the running Snippets process after the user's
reproduction captured `AXObserverAddNotification`, `AXObserverRemoveNotification`,
context refresh, suggestion presentation, and fuzzy matching. Notification registration
had substantially more sampled frame occurrences than the other selected operations.
This is evidence of a blocking path, not a per-keystroke latency percentile: counts
were aggregated across matching stack lines and cannot be summed or converted to
exclusive execution time. Raw sample headers/stacks/image maps were kept only in memory;
only counts for an allow-listed set of code symbols were printed.

**Change:** registration and removal run on a serial worker. The main actor only
attaches/detaches the run-loop source. Cancellation stops additional registrations
after an in-flight call returns and cleans successful registrations on the worker.
The completion checks both the session generation and registration identity before
attaching a source, so a dismissed session cannot install an obsolete observer.
Ancestor discovery and AXObserver creation still occur on the main actor.

### 2. One edit can rebuild identical results several times

The optimistic printable-key handler calls `updateSuggestionResults()`. The scheduled
AX read and separate value/selection notifications can each call it again with the
same query. Each pass sorts the display library, normalizes and fuzzy-matches both
fields, ranks results, reloads the table, lays out the panel, and invalidates its shadow.
The code permits this multiplicity; its frequency in the user's browser was not measured.

**Change:** `SuggestionResultsUpdater` skips this work for unchanged inputs in one
session. It compares the exact query, both full library projections, and locale.
Bodies, enabled/pinned state, and ordinary/secure membership participate, so a remote
body edit or secure transition cannot leave a stale snippet in the selectable results.
Resetting on activation/dismissal also invalidates the frozen usage ranking. Host text
reads, focus checks, deletion authorization, and secure authentication still run.

### 3. Remaining synchronous work

- `refreshSuggestionContextFromFocusedText()` still performs synchronous AX reads on
  the main actor, with an aggregate budget of 400 ms per refresh. Multiple notifications
  can produce multiple refreshes. Moving registration alone does not remove this risk.
- `SuggestionAXTextReader` requests a short range first, but if unsupported it fetches
  the entire AX value before slicing the last 120 UTF-16 units. Large browser editors
  can make that fallback expensive; its cost was not measured here.
- A new printable query still performs fuzzy matching and panel layout in the event
  callback. There is no prepared fuzzy index for this path.
- `unambiguousExactMatch()` sorts the enabled ordinary library before an order-independent
  scan and repeatedly sanitizes keywords. This is avoidable CPU work, not the dominant
  operation in the captured sample.
- Panel anchoring is cached per session; it is **not** reacquired on every letter.
- Paste/delete settle delays and paste confirmation affect insertion, not ordinary
  letters before acceptance. Do not shorten those safety delays to address this symptom.

The next performance step, if stalls persist, is to measure and coalesce context reads,
then move read-only AX work away from the keyboard's run loop with session/query/focus
generation checks. Acceptance must still freshly validate the target and trigger. Merely
wrapping synchronous AX in another MainActor task does not solve keyboard blocking.

## Measurements and limits

Only aggregate library metadata was read: 94 ordinary records (91 enabled), 12 vault
records; median ordinary name length 13 characters. No real snippet content was used in
the benchmark. These counts describe one local library, not a product limit.

The retained `suggestion_anchor` events cover 2026-09-10 through 2026-09-25 and include
both ordinary suggestions and the Command-Backslash picker. Across 200 events, p50 was
3 ms, p95 49 ms, maximum 401 ms. On September 25 alone there were only five events:
p50 3 ms, maximum 22 ms. These numbers concern activation/anchoring and **do not measure
the reported letter-by-letter lag**. Existing `expansion_accessibility` events do not
carry operation durations; none were present in the inspected retained logs.

The optimized standalone benchmark uses the shipping matcher, generated short names
and keywords, five warm-ups and 50 samples per case. Each pass matches two fields per
row. Initial measurements on this Mac:

| Rows | Query length | p50, ms | p95, ms |
| ---: | ---: | ---: | ---: |
| 100 | 1 | 2.08 | 2.42 |
| 100 | 2 | 2.24 | 2.60 |
| 100 | 4 | 2.61 | 2.81 |
| 1,000 | 1 | 22.62 | 24.72 |
| 1,000 | 2 | 25.30 | 26.90 |
| 1,000 | 4 | 29.51 | 31.57 |

This excludes store projection, exact matching, sorting/ranking, AX, and rendering.
It cannot establish end-to-end improvement. The audit changes do not speed up the fuzzy
algorithm itself; they prevent redundant passes when AX confirms unchanged input.

Reproduce with `./scripts/benchmark-expansion-matching.sh`. It creates a temporary
executable, uses synthetic data only, and removes that executable on exit.

## Verification

Targeted macOS tests cover blocked registration/removal with a responsive main actor,
cancellation during IPC, cleanup of a late success, partial notification capability,
duplicate result updates, body-only edits, secure transitions, locale/library changes,
and session reset. The existing suggestion keyboard tests cover selection behavior.
No sync protocol, diagnostics schema, or shared-core source was changed.

Results: Debug macOS build passed; all 14 selected macOS tests passed; the complete
`swift test --package-path CorePackage` command passed. The repository's standalone
benchmark also compiled and ran successfully. App changes are macOS-only, so the iOS
build and simulator suites were not run for this audit.

The installed production app was not replaced. A live before/after browser replay on
the fixed build is still needed before calling the typing delay resolved.
