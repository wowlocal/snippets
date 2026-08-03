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
6. Selection expands by deleting trigger text and pasting resolved snippet content.

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
- After host edits, the active query is reread from `AXSelectedTextRange` plus text before the caret instead of being inferred from key presses.
- AX reread is retried after short delays because Chromium/Electron text state can lag behind the key event.
- If AX text is unavailable, printable characters and simple backspace keep a local fallback query so terminal apps can still update suggestions.
- Until AX has successfully found the trigger in the current session, a missing AX trigger can also stay on local fallback because terminal accessibility text may not expose the current typed buffer.
- Selection and auto-expand are allowed only after a successful reread or tracked local fallback; unknown unavailable text context dismisses the active session instead of using stale query/delete state.
- Host-side edits that invalidate the local query, such as `Ctrl+W` or `Option+Delete`, cannot re-enable local fallback until AX resync succeeds.
- `Backspace`, `Ctrl+H`, `Option+Delete`, and `Ctrl+W` therefore use the host app's actual edit result and then resync suggestions.
- Cmd/Option combos mostly dismiss suggestion mode.
- Cmd+Shift+3/4/5/6 are ignored (do not dismiss) to avoid interfering with screenshots.
- Input-source switching shortcuts (for example Cmd+Space) do not dismiss.

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

`UserDefaults` keys `SnippetsAccessibilityInsertionEnabled` (set to `false`) and
`SnippetsAccessibilityInsertionExcludedBundleIDs` disable this path globally or per app.

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
