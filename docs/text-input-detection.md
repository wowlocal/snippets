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

Chromium-family list currently includes:

- `com.google.Chrome*`
- `org.chromium.Chromium`
- `com.microsoft.edgemac`
- `com.brave.Browser`
- `com.operasoftware.Opera`
- `com.vivaldi.Vivaldi`
- `company.thebrowser.Browser` (Arc)

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
- `Tab`/`Return` select suggestion and are suppressed.
- Backspace is generally passed through so host app deletes text too.
- `Option+Delete` and `Ctrl+W` delete previous word in query logic.
- Cmd/Option combos mostly dismiss suggestion mode.
- Cmd+Shift+3/4/5/6 are ignored (do not dismiss) to avoid interfering with screenshots.
- Input-source switching shortcuts (for example Cmd+Space) do not dismiss.

## Expansion and pasteboard timing quirks

Text replacement is delete+paste, not direct insertion:

1. Delete trigger text with synthetic backspaces.
2. Write resolved snippet to pasteboard.
3. Send synthetic `Cmd+V`.
4. Restore previous clipboard snapshot after short delay if clipboard unchanged.

Delays are intentional and tuned:

- `injectedKeyDelay`: helps apps that drop rapid synthetic deletes.
- `prePasteDelayAfterDelete`: lets host app settle before paste.
- `pasteboardWriteSettleDelay`: avoid race where paste occurs before clipboard update propagates.
- `pasteboardRestoreDelay`: reduces race restoring old clipboard over new user copy.

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
- Keep pasteboard restoration guard (`changeCount` check).

Breaking any of these tends to reintroduce known regressions.
