---
name: maintain-snippets-ipad-keyboard
description: Implement and verify hardware-keyboard behavior for the Snippets iPad split-view interface. Use when changing UIKeyCommand shortcuts, Return or Escape handling, list/search focus behavior, shortcut hints, responder-chain priority, or iPad keyboard unit and UI tests.
---

# Maintain Snippets iPad Keyboard

Preserve Mac-style keyboard behavior on iPad without stealing keys from search fields, editors, shortcut panels, or the touch-first iPhone interface.

## Work in the correct layer

1. Read `AGENTS.md` and inspect the current implementation before editing.
2. Keep iPad keyboard behavior in `snippets-ios/`. Do not move UIKit into shared core files.
3. Use `MainSplitViewController` for semantic commands and focus gates.
4. Keep `PhoneRootViewController` unaffected. Add protocol defaults that return `false` when a window-level interception is iPad-only.
5. Update `ShortcutPanelView` whenever the visible shortcut changes.

## Implement a shortcut

Define a reusable static `UIKeyCommand` factory so tests and imperative handlers use the same command definition. For an unmodified Return command:

```swift
let command = UIKeyCommand(
    title: "Copy Snippet",
    action: #selector(copySnippetCommand(_:)),
    input: "\r",
    modifierFlags: []
)
command.wantsPriorityOverSystemBehavior = true
```

Gate the action on product state. Return should copy only when the shortcut panel is absent, the snippet list owns focus, and a snippet is selected. Return `false` when the app should allow UIKit's normal behavior.

## Handle UIKit interception

Do not assume `UIKeyCommand` is sufficient for unmodified Return or Escape. `UISearchController` and `UITableView` can consume hardware-key presses before responder-chain commands run.

When that occurs, intercept `UIPressesEvent` at the custom `UIWindow` boundary:

- recognize both `.keyboardReturnOrEnter` and `.keypadEnter`;
- require no Command, Option, Control, or Shift modifiers for plain Return;
- invoke the root controller's semantic handler only on `.began`;
- consume the remaining `.changed`, `.ended`, and `.cancelled` phases after handling `.began`;
- reset the consuming flag on `.ended` or `.cancelled`;
- call `super.sendEvent` for every event the app does not handle.

Keep the window ignorant of selection and focus details. Expose Boolean methods such as `handleReturnBeforeSystemBehavior()` through `SnippetsRootController`; let the active root controller decide whether to consume the press.

## Preserve focus semantics

- Search-focused Return must remain available to search/system behavior.
- Escape may move focus from search to the filtered list without clearing the query.
- List-focused Return may invoke the selected-snippet action.
- Editor-focused Return must continue inserting a newline.
- Presented panels and modal UI must retain their own Return/Escape behavior.

## Test the behavior

Add unit coverage in `snippets-ios-tests/SnippetsIOSTests.swift` for:

- command input, modifiers, and `wantsPriorityOverSystemBehavior`;
- the invoked action's observable result;
- positive list-focus gating;
- negative search/editor/panel gating.

Add or update the smoke test in `snippets-ios-uitests/SnippetsIOSUITests.swift`. Launch with `--ui-testing-reset` to preserve storage and sync isolation.

Do not treat a Simulator-generated `XCUIElement.typeKey` as proof of the physical hardware-key pipeline. The simulator can bypass `UIPressesEvent`; skip that assertion under `targetEnvironment(simulator)` and run it on an iPad when end-to-end coverage is required. Keep simulator unit tests for the deterministic handler and command configuration.

Run the iOS unit and UI checks from `AGENTS.md` on available iPhone and iPad simulators. For a narrow iteration, use `-only-testing` for the affected tests, then run the broader target checks before merging a cross-cutting change.
