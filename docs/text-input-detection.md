# Text Input Detection, Workarounds, and Quirks

This document explains how Snippets decides when to show suggestions, how it finds the caret, and why Chromium/Electron apps need special handling.

## Scope

This is specifically about:

- Detecting whether the focused UI element is a text input.
- Showing the suggestion panel at the right place.
- Dealing with Chromium/Electron accessibility behavior.
- Handling monitor-coordinate and event-timing quirks.

Code references:

- `/Users/mike/src/tries/2026-02-15-snippets/snippets/snippets/SnippetExpansionEngine.swift`
- `/Users/mike/src/tries/2026-02-15-snippets/snippets/snippets/SuggestionPanelController.swift`

## High-level pipeline

1. Global key events are observed with a session `CGEvent` tap and a local `NSEvent` monitor.
2. A rolling `typedBuffer` tracks recent characters.
3. On `\`, we try to prove a text field is focused.
4. If focused text input is confirmed, suggestion mode activates.
5. Suggestions are ranked and shown near the caret.
6. The panel updates optimistically while Accessibility confirms the host's actual text.
7. Selection expands only after a fresh exact Accessibility read proves the trigger text.

## Permissions and trust

The engine requires Accessibility trust:

- `AXIsProcessTrustedWithOptions` gates most cross-app Accessibility calls.
- If trust is granted after launch, monitors are restarted to avoid requiring app relaunch.

If trust is missing, status text warns and text-input checks will fail.

## Why Chromium/Electron are special

Chromium-based apps optimize accessibility and may not expose a full tree until assistive tech is detected or explicitly enabled.

Electron also documents a manual activation path for third-party assistive tools on macOS.

Primary references:

- [Electron accessibility guide](https://www.electronjs.org/docs/latest/tutorial/accessibility)
- [Chromium accessibility technical documentation](https://www.chromium.org/developers/design-documents/accessibility/)
- [Chromium source (mac app accessibility handling)](https://chromium.googlesource.com/chromium/src/%2B/master/chrome/browser/chrome_browser_application_mac.mm)
- [Chromium accessibility inspect tools (`--force-renderer-accessibility`)](https://www.chromium.org/developers/accessibility/testing/automated-testing/ax-inspect/)

## Accessibility priming workaround

To reduce false negatives in Chromium/Electron:

- We set `AXManualAccessibility=true` via `AXUIElementSetAttributeValue` on the frontmost app element.
- For Chromium-family bundle IDs, we also set `AXEnhancedUserInterface=true`.
- We cache primed PIDs to avoid unnecessary repeated writes.
- If focused element lookup fails, we retry once with forced priming.

Implemented in:

- `primeAccessibilityIfNeeded(for:force:)` in the engine.
- `primeAccessibilityIfNeeded(for:force:)` in the suggestion panel controller.

Built-in Chromium-family list includes:

- `com.google.Chrome*`
- `org.chromium.Chromium`
- `com.microsoft.edgemac`
- `com.brave.Browser`
- `com.operasoftware.Opera`
- `com.vivaldi.Vivaldi`
- `company.thebrowser.Browser` (Arc)

Users can add custom Chromium-family bundle IDs from:

- `Snippets > Settings…`
- Use `Add App...` to pick an installed app and auto-fill its bundle ID, or `Add Bundle ID...` for manual entries.

Custom IDs are stored in `UserDefaults` and treated the same as built-in IDs for `AXEnhancedUserInterface` priming.
Settings changes clear priming caches and apply immediately (no Snippets relaunch required).

## Focused text-input detection strategy

The detector no longer depends only on role.

Flow:

1. Resolve frontmost app.
2. Read focused AX element.
3. Walk nested `kAXFocusedUIElementAttribute` up to depth 4 (some apps expose nested focus objects).
4. Test candidate and up to 4 parents.

An element is considered text input if any of these are true:

- Role is `AXTextField`, `AXTextArea`, or `AXComboBox`.
- Subrole is `AXSearchField`.
- `AXEditable` is true.
- It exposes `AXSelectedTextRange` attribute (common Chromium/Electron hint).

Fallback behavior:

- If `\` does not open suggestions (focus detection fails), exact unambiguous keyword auto-expand can still fire from typed buffer.

## Suggestion panel anchoring strategy

When suggestion mode starts:

- Anchor is captured once and preserved through result updates.
- Temporary no-result states call `hide()` (keep anchor).
- Session end calls `dismiss()` (clear anchor).

This avoids panel jumping while typing/backspacing.

## Caret and control rect strategy

Preferred path:

- `AXSelectedTextRange` + `AXBoundsForRange` for precise caret bounds.

Fallback path:

- For zero-length range failures, try a 1-char range ending at insertion point.
- If bounds still fail, use focused element position/size.

Normalization:

- For single-line-like inputs (and Safari-specific nested cases), align vertical anchor to containing control bottom so the panel appears below, not on top of text.

## Multi-monitor and coordinate quirks

### Problem

AX geometry is top-left-origin global space. AppKit uses bottom-left-origin. Some Chromium/Electron fields have inconsistent coordinate behavior.

### Workaround

`axRectToAppKit` now tries two interpretations:

1. Normal AX top-left flip against primary-screen height.
2. Treat incoming rect as already AppKit-style global coordinates.

Whichever intersects a known screen is used first.

### Screen selection behavior

- Panel bounds use screen containing anchor center (frame first, then visibleFrame).
- If no anchor screen matches, fallback to `NSScreen.main`.
- Max visible rows are capped based on the active screen's visible frame.

This reduces off-screen or wrong-monitor placement.

## Key-handling quirks in suggestion mode

Handled intentionally:

- `Ctrl+N/P` and arrow keys navigate list and are suppressed.
- `Ctrl+C` dismisses the suggestion panel and is passed through to the host app.
- `Tab`/`Return` select suggestion and are suppressed.
- Printable characters and deletion shortcuts are generally passed through so the host app edits real text first.
- The panel applies printable input and simple backspace immediately; it never waits on an AX timer before repainting.
- The query carries one of three authority states: `axConfirmed`, `localDisplayOnly`, or `uncertainAfterHostEdit`.
- Plain typing changes `axConfirmed` to `localDisplayOnly`. `Backspace`, `Ctrl+H`, `Option+Delete`, `Ctrl+W`, and other host-owned edits change it to `uncertainAfterHostEdit`.
- The engine observes `AXValueChanged` and `AXSelectedTextChanged` on the focused control and readable ancestors. A notification triggers an immediate read of `AXSelectedTextRange` plus the text before the caret.
- There are no 18/60 ms suggestion resync sleeps. A single next-run-loop read is also attempted after activation and printable input; `Backspace` and other host-owned edits never start a timer or poll. A value that still describes the preceding printable keystroke is classified as stale and never rolls the panel backwards.
- Normally, only `axConfirmed` may auto-expand or authorize trigger deletion. `localDisplayOnly` and `uncertainAfterHostEdit` keep the UI responsive but are display-only.
- Ghostty is the deliberately narrow exception. Its terminal `AXTextArea` exposes the rendered screen and mouse selection, but not the insertion caret. A never-AX-confirmed, uninterrupted `localDisplayOnly` session may use local tracking only while the Ghostty bundle ID, target PID, terminal role, and exact focused AX object still match. Backspace, another host-owned edit, a pane/tab focus change, or any earlier AX confirmation revokes the exception. Ghostty search and other UI fields do not qualify.
- An unambiguous exact Ghostty keyword uses the same suppressed-final-key strategy as the panel-less fallback. Explicit Tab/Return/click acceptance still performs a fresh AX read first; only `missingTrigger` or unavailable text may take the narrow Ghostty exception. A mismatch, unsafe query, secure snippet, or any non-Ghostty host leaves the typed trigger untouched.
- This is what handles browser autocomplete correctly: deleting a host-owned completion may produce a temporary local `jaz`, while the following AX notification confirms that the real field still contains `jazz` and restores the displayed query without ever authorizing the wrong delete count.
- Cmd/Option combos mostly dismiss suggestion mode.
- Cmd+Shift+3/4/5/6 are ignored (do not dismiss) to avoid interfering with screenshots.
- Modifier+Space is classified after key-up by comparing the actual keyboard input-source identifier and reading the system-wide AX focused application. An input-source change preserves the panel even if the system switcher briefly owns focus; otherwise Spotlight, Raycast, or any custom launcher that takes keyboard focus dismisses it. The shortcut modifiers are not hardcoded.

## Secure Paste delivery in browser fields

`⌘\` remains Accessibility-only: it never moves a selected snippet through the
pasteboard or a synthetic keyboard event. Password fields keep the established
password-manager-style `AXValue` write, and native ordinary fields keep the narrow
`AXSelectedText` write.

Safari and Chromium can report success for `AXSelectedText` without updating the web
page's real editing model. Inside a positively identified `AXWebArea`, an ordinary
control is eligible only when surfaced as `AXTextField`, `AXComboBox`, or an `AXTextArea`
that advertises popup/autocomplete semantics (the shape measured for Google Search in
Chromium). Secure Paste then uses `AXReplaceRangeWithText` only when that operation and
the `AXStringForRange` readback operation are both advertised by the focused control. The public
`AXUIElementCopyParameterizedAttributeValue` function performs the request, but the
attribute and its `AXReplacementRange` / `AXReplacementText` parameter keys are
undocumented macOS Accessibility SPI. Every invocation is capability-gated so an OS or
browser that removes it fails closed and retains the existing native/password behavior.

The browser route has stricter delivery proof:

1. Reconfirm the original PID, frontmost application, and exact focused AX object.
2. Capture only the selected range and character count before secure bytes become a
   Swift `String`; never read a password value or the whole ordinary field value.
3. Reconfirm that range/count immediately before one plaintext-bearing request.
4. Verify the resulting character count and read back only the bounded inserted range.
5. Collapse Chromium's still-selected replacement to a caret after insertion is proven.

An error or mismatched readback after step 3 is an ambiguous attempted delivery. It is
terminal: there is no retry, `AXSelectedText` fallback, event fallback, or pasteboard
fallback. Multiline snippets remain supported; range validation and readback are bounded
to 1,000,000 UTF-16 units. Generic text areas, web groups, and contenteditable controls
remain ineligible.

## Expansion and pasteboard timing quirks

Replacement has two paths. The Accessibility path is preferred; delete+paste is the fallback.

### Accessibility path

One atomic replacement, no synthetic events and no clipboard involvement:

1. Read the focused element's caret range and the text before it.
2. Prove that text ends with the exact trigger we mean to delete.
3. Set `AXSelectedTextRange` to the trigger's range and write `AXSelectedText`.
4. Collapse the caret behind the inserted text.
5. Verify the write landed by re-reading `AXValue`.

Reading and writing happen in the same main-actor turn — split them and the proof from step 2 is
worthless. Three outcomes, and only one of them falls back:

- `delivered` — committed.
- `unavailable` — the field exposes no writable text attributes, or the write was a silent no-op
  (the Chromium/Electron failure mode, caught by step 5). Falls back to events.
- `rejected` — the text before the caret is not what we expected. Fails closed **when the delete
  count came from an Accessibility read**; with a locally tracked count Accessibility is merely
  lagging, which is the normal state in Chromium, so the event path still runs.

### Chromium writes the whole value instead

Chrome's omnibox is the one failure step 5 cannot see. A selected-text write lands in the text it
draws and never reaches `OmniboxEditModel`, so `AXValue` reads back exactly what was written while
Return still navigates to what the user typed: `\crew` expands to a URL on screen and then searches
the web for `\crew`. The edit model is not in the Accessibility tree, so no read tells that apart
from a real success — the host has to be decided up front rather than by outcome.

Writing the field's whole value does reach the model, so Chromium-family hosts get that strategy
instead of a refusal. It is deliberately narrow:

- `elementIsBrowserChrome` must vouch for the target first — role `AXTextField`, a short single-line
  value, and a parent chain that arrives at `AXApplication` without passing an `AXWebArea`. Positive
  evidence, not absence of evidence: a failed parent read answers `nil` exactly like the top of the
  tree does, and a page field one unreadable link below its web area would pass the weaker test.
- Inside a web area `AXValue` is a flattened rendition of the DOM. Writing it back would strip a rich
  editor to plain text and desynchronize any field whose framework owns its value — the omnibox bug,
  reintroduced on the web. Web content keeps the event path, which is what it already used: those
  selected-text writes were silent no-ops that fell through anyway.
- The caret is moved only after the value reads back as ours. `plan.caretLocation` is an offset into
  the text we meant to write, so placing the caret before that proof would strand it in the old text
  and the event fallback would backspace from there — eating the user's characters, not the trigger.
  No other exit touches the selection, so no other exit has to restore it.
- A value that changed into something we did not write answers `rejected`, not `unavailable`: the
  event path must not paste on top of it.

Safari is unaffected — WebKit's address bar applies a selected-text write through its normal editing
path.

`UserDefaults` keys `SnippetsAccessibilityInsertionEnabled` (set to `false`) and
`SnippetsAccessibilityInsertionExcludedBundleIDs` disable this path globally or per app. An excluded
Chromium host is excluded, not rerouted to the whole-value strategy.

### Event fallback

1. Borrow the pasteboard — **before** deleting anything, so a pasteboard we cannot borrow safely
   costs the user nothing.
2. Delete trigger text with synthetic backspaces.
3. Send synthetic `Cmd+V`.
4. Hold the borrowed pasteboard until delivery is confirmed, then hand it back.

Every event we post carries `SnippetSyntheticEvent.tag` in `kCGEventSourceUserData`, and the tap
skips events carrying it — our own injection comes back through our own session tap, and a timing
window cannot tell it apart from real typing.

The borrow mutates the original `NSPasteboardItem` in place when the first item holds plain text, so
handing the clipboard back costs no change count and clipboard managers record one entry, not two.
An image-first or empty clipboard is rewritten wholesale instead; only a pasteboard that cannot be
snapshotted at all refuses the lease.

Delays are intentional and tuned, and none of them blocks the main thread:

- `injectedKeyDelay`: helps apps that drop rapid synthetic deletes.
- `prePasteDelayAfterDelete`: lets host app settle before paste.
- `pasteboardWriteSettleDelay`: avoid race where paste occurs before clipboard update propagates.

They are awaited through a non-cancellable `settle(for:)`, not `Task.sleep`: a cancelled sleep
returns immediately, which would rush the paste into a host still applying our deletions.

These delays apply only after expansion has already been authorized, while synthetic deletion and
paste are delivered. Suggestion tracking and ordinary AX confirmation have no wall-clock debounce.

### Confirming the paste

The clipboard is returned on evidence, not on a timer. Each poll compares a bounded fingerprint —
caret location, selection length, and up to 32 characters before the caret — against the state
captured just before `Cmd+V`. Never the whole `AXValue`: in an editor that is the entire document,
re-serialized over Accessibility IPC on every poll.

- Caret advanced by the pasted length, or the text before it now ends with what we pasted → confirmed.
- Caret moved backwards → our own backspaces are still landing; re-baseline and keep waiting.
- Host answers nothing at all (terminals, and any host without readable text) → accepted after 400 ms,
  deliberately no shorter than the fixed 350 ms delay this replaced.
- Two independent ceilings — attempts and wall clock — guarantee the loop ends even against a host
  that stalls every read.

Waiting stops early, and the clipboard goes back, when another copy supersedes ours, when secure
input comes on, or when the frontmost app changes. Holding through an app switch would mean the
user's next manual `Cmd+V` pastes our snippet.

### Secure Event Input

`IsSecureEventInputEnabled()` is process-global — any app can hold it on. While it is on, no
synthetic event reaches the host, so expansion refuses to start and refuses to continue across every
suspension point. Tracked state is dropped rather than held next to a password prompt, and keys are
never suppressed on that path. Because secure input also stops key events reaching a session tap at
all, an open suggestion session additionally polls for it — otherwise the panel would sit over the
password prompt with no event left to dismiss it.

## Known limits

- Secure/password fields may block AX details or synthetic events by design.
- Some custom-rendered editors may expose partial/atypical AX semantics.
- Accessibility state can vary per app process/lifecycle; restarting target app can help.
- Chromium may still require explicit runtime forcing in certain environments.

## Operational troubleshooting

If suggestions do not appear in Chrome/Electron:

1. Confirm Snippets is enabled in macOS Accessibility settings.
2. Fully quit and relaunch Snippets.
3. Fully quit and relaunch the target browser/app.
4. Test in a plain text field first (for example omnibox/search field).
5. Force Chromium accessibility and retest:

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --force-renderer-accessibility
```

6. If that fixes it, the issue is Chromium accessibility-mode gating.
7. Test Safari as a control to separate app-specific behavior from global failures.

## Implementation checklist for future changes

When changing detection logic, keep these invariants:

- Do not rely on AX role alone.
- Keep nested-focus and parent-chain checks.
- Keep Chromium/Electron priming + retry.
- Keep panel anchor stable for one suggestion session.
- Keep dual coordinate conversion fallback.
- Restore only a pasteboard we still own (`changeCount` check), and only once delivery is confirmed
  or the budget is spent.
- Read and write in one main-actor turn on the Accessibility path; restore the original selection
  before falling back to events, or the fallback's first backspace eats the trigger and every one
  after it eats the user's text.
- Never suppress an event carrying our own tag: consuming our own backspace breaks the expansion in
  progress.
- Never suppress keys while secure input is on.
- Read the parent chain, but write only to the focused element.

Breaking any of these tends to reintroduce known regressions.
