# Secure Paste multiline readback investigation

Status: **reproduced in isolated WebKit; destination-aware confirmation implemented**.
Investigated on 2026-09-22, starting from commit `b7518eb`.

## Report and hypothesis

With a browser field focused, selecting a snippet from the `⌘\` picker sometimes
shows “Secure Paste may have inserted the snippet” even though text appears.
The user identified multiline snippets as the trigger.

The diagnostic event at 22:45:47 Moscow time recorded successful focus handoff,
`transport=web_range`, `ax_error_code=0`, followed by
`reason=readback_unconfirmed` after 10 ms. This is the clipboard-free Secure Paste
route, separate from typed-trigger expansion fixed in `484c5c7`.

Hypothesis: the browser accepts the replacement but normalizes its line endings to
fit the destination. The original verifier expected the original UTF-16 length and
exact original text, so it classified the transformed result as ambiguous. Unlike
an asynchronous AX update, such a mismatch will not disappear with a longer wait.

This hypothesis is supported by WebKit's
[`TextFieldInputType::handleBeforeTextInsertedEvent`](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/html/TextFieldInputType.cpp):
single-line insertion trims trailing CR/LF and converts internal CRLF, CR, and LF
to spaces. The measurement below exercises the actual AX range request rather
than assuming that it follows this source-code path.

## Reproduce

From an Accessibility-authorized terminal, with the synthetic fixture left focused:

```sh
bash scripts/test-secure-paste-web-range.sh
```

The script compiles into a fresh `/tmp/snippets-web-range-fixture.*` directory.
It does not build, install, launch, or replace Snippets. It opens a disposable
`WKWebView` with a nonpersistent data store and a network-blocking CSP. There is
no access to the library, vault, clipboard, browser profiles, or real pages.
The sender can address only its own fixture parent. Focus is returned to the
previous app when the fixture exits, provided the user has not switched away.

The current 30 cases cover `input[type=text]`, `input[type=search]`, and `textarea`,
each with plain Unicode, LF, CRLF, CR, trailing LF, a blank line, a larger payload,
and three page-script interference cases (truncation, lost line, same-length rewrite).
Each case replaces a known selection while retaining a prefix and suffix:

1. Use the shipping `SecurePasteWebReplacementPolicy` snapshot and planner.
2. Classify the real control's AX role using the shipping policy. The harness
   explicitly supplies Safari's host identity because its own process hosts a
   known WKWebView; bundle discovery in Safari itself is not exercised.
3. Send exactly one advertised `AXReplaceRangeWithText` operation using the
   shipping `AXMessagingBudget`; never retry. Confirm with the shipping normalized
   plan and adjust the caret only after confirmation.
4. Compare the new verifier with the original exact-text plan, immediately and
   after 500 ms (the legacy/delayed reads are diagnostic-only).
5. Independently check DOM value, the model updated by `input` events, exactly
   one `input` event, the resulting caret, and an untouched second field.

The fixture uses the actual AX operation and shipping pure policies; it does not
invoke the complete Snippets engine, picker, authentication, or warning HUD.
Output contains synthetic case labels, counts, and booleans, not user content.

## Original reproducer results

Environment: macOS 27.0 (26A428), WebKit 22625.1.29.11.27.
**18/18 cases passed.** Every AX call returned success, the DOM and input-event
model agreed, exactly one input event fired, and the unrelated field was unchanged.

The following strings are synthetic test data. “Confirmed” refers to the existing
original strict verifier, not merely to the fact that insertion happened.

| Destination | Replacement | Actual inserted text | Strict confirmation |
| --- | --- | --- | --- |
| All three fields | Plain Unicode | Unchanged | Yes |
| Text/search input | `one\ntwo` or `one\rtwo` | `one two` | No: same length, different text |
| Text/search input | `one\r\ntwo` | `one two` | No: shorter and different |
| Text/search input | `one\ntwo\n` | `one two` | No: trailing newline removed |
| Text/search input | `one\n\ntwo` | `one  two` | No: same length, different text |
| Textarea | LF, trailing LF, blank line | Unchanged, including LF | Yes |
| Textarea | `one\r\ntwo` | `one\ntwo` | No: CRLF becomes LF |
| Textarea | `one\rtwo` | `one\ntwo` | No: same length, different line ending |

Immediate and delayed confirmation agreed in every measured case. In particular,
all transformed payloads still failed exact confirmation after 500 ms. This
reproduces the mechanism behind the warning without a failed insertion or a
missing `input` event. It also demonstrates why checking only length is unsafe.

## Fix and regression coverage

Safari and Safari Technology Preview `AXTextField` controls use the measured
single-line normalization; their `AXTextArea` controls normalize CRLF/CR to LF.
Only these host/role pairs opt in. Unknown roles, missing metadata, other apps
and other browsers keep exact original-text verification. Password transports
are unchanged.

Normalization applies only to the expected result, never to the text sent.
The plan uses the delivered UTF-16 length for character count, bounded readback
and caret placement. Actual readback is compared exactly: no general whitespace
folding, Unicode canonical equivalence, retries, clipboard fallback, or warning
suppression. Empty normalized edits and already-present normalized results are
rejected before writing. The original request still has the same size limit.

**30/30 integration cases passed after the fix.** All 21 intended insertions
confirmed immediately, reached the DOM and input-event model, and placed the
caret after the actual inserted text. All nine injected page-script alterations
remained unconfirmed; no caret write or second insertion followed them.
The legacy verifier still rejected the normalized multiline cases.
Unit tests also cover unknown hosts/roles, exact Unicode and whitespace retention,
lost blank lines, invalid counts, empty/no-op results and oversized requests.

## Performance

There is no new AX query, timer, polling loop or retry in production: host and role
are taken from metadata already read during preparation. Expected-text processing
is linear in the bounded input size, with a fast path returning the original string
when conversion is unnecessary.

The optimized fixture's first post-fix run measured the preflight/write/readback/
caret phase at **3.96 ms median**, **2.83 ms minimum**, **46.62 ms maximum** across
30 cases. The maximum was the large textarea case (18,435 UTF-16 input units).
This is total observed delivery work, not a claim about incremental overhead;
it excludes GUI startup and the diagnostic-only 500 ms wait. Timings vary with host
load. The script also prints a separate optimized planner microbenchmark for
approximately 1K, 20K and 1M UTF-16 units.

In the second run, the optimized planner averaged **0.003 ms / 0.051 ms / 2.563 ms**
at 999 / 19,998 / 999,999 UTF-16 units respectively (both normalization modes).
This includes planning/allocation but excludes AX. The repeated 30-case GUI run
also passed, with a 3.86 ms delivery median and 45.93 ms maximum.

## Limits

This confirms the normalization hypothesis in the installed WebKit engine, not
the exact original Safari page: its field type and original snippet line endings
were not captured. Ordinary LF in a real textarea passed here. A warning for that
case would need separate investigation, such as page-script rewriting or stale AX
state. Chromium, rich contenteditable editors, passwords, and native fields were
not tested by this fixture.

The accepted transformation is narrowly scoped to the measured rules. Do not
silence all ambiguity, equate all whitespace, or retry the write: those could
conceal real truncation or duplicate input. Merely waiting longer does not address
the reproduced cases.
