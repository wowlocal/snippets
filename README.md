# Snippets (macOS)

Local text-expander app for macOS with a Raycast-style snippet list/editor and global snippet insertion.

## Features

- Create, edit, delete, duplicate, enable/disable, and pin snippets.
- Global expansion in other apps by typing `\` + keyword.
- Suggestion panel near the caret with fuzzy matching on snippet name and keyword.
- Dynamic placeholders in snippet content:
  - `{clipboard}`
  - `{date}`
  - `{time}`
  - `{datetime}`
  - `{date:<DateFormatter pattern>}` (for example `{date:yyyy-MM-dd}`)
- Import/export JSON snippets.
- Menu bar item with quick open/quit.
- Optional Launch at Login toggle.
- Configurable extra Chromium bundle IDs in a dedicated `Snippets > Settings…` window (applies immediately, no relaunch).

## Requirements

- macOS 15.5+ (project deployment target).
- Xcode with Swift 5 support.

## Build and Run

1. Open `/Users/mike/src/tries/2026-02-15-snippets/snippets/Snippets.xcodeproj` in Xcode.
2. Select the `snippets` scheme.
3. Build and run.

## First Launch and Permissions

The global expander uses Accessibility APIs. If expansion does not start:

1. Click `Request Permission` in the app banner.
2. Open `Accessibility` from the same banner and enable Snippets.
3. Click `Refresh`.

Depending on macOS version/settings, Input Monitoring may also be needed for global keystroke capture.

## How Expansion Works

- Type `\` in a text input field to open suggestions.
- Keep typing to filter snippets (fuzzy match by name/keyword).
- Use `↑/↓` or `Ctrl+N` / `Ctrl+P` to navigate suggestions.
- Press `Tab` or `Return` to insert the selected snippet.
- If your query exactly matches one keyword (and no longer keyword shares that prefix), it auto-expands.
- If focused text-field detection fails in some apps, fallback auto-expansion still tries to trigger from typed text.

Keyword notes:

- In the editor, the visible `\` is a prefix label. Store keywords without the leading slash.
- Spaces in keywords are converted to `-`.
- Overlapping keywords (prefix collisions) show a warning and prevent auto-expand disambiguation.

## Under the Hood

The app is organized around three main pieces:

- `SnippetStore`: owns snippet state in memory, debounces writes, persists JSON, and handles import/export merge rules.
- `ViewController`: builds the app UI, binds controls to the store, and routes keyboard actions.
- `SnippetExpansionEngine`: runs global key listening, suggestion mode, and text replacement in other apps.

Detailed deep dive:

- `/Users/mike/src/tries/2026-02-15-snippets/snippets/docs/text-input-detection.md` explains cross-app text-input detection, Chromium/Electron workarounds, monitor quirks, and troubleshooting.

Global expansion pipeline:

1. The expansion engine starts a session-level `CGEvent` tap plus a local `NSEvent` monitor.
2. Typed characters are appended to an internal rolling buffer.
3. On `\`, suggestion mode activates and `SuggestionPanelController` shows ranked matches.
4. Ranking uses fuzzy scoring (`FuzzyMatch`) against snippet name and keyword.
5. Selecting a snippet (or unambiguous exact-match auto-expand) triggers expansion.
6. The engine resolves placeholders with `PlaceholderResolver` and injects final text.

Text replacement strategy:

- The engine deletes trigger characters with synthetic backspaces.
- It writes expansion text to the pasteboard.
- It sends synthetic `Cmd+V` to paste into the frontmost app.
- It restores previous clipboard contents shortly after paste, unless the clipboard changed in the meantime.

Suggestion panel positioning:

- The panel attempts to read caret bounds from Accessibility (`AXBoundsForRange`).
- If that fails, it falls back to focused-element geometry.
- Extra normalization avoids awkward placement in some apps (for example Safari/Chromium-style controls).

Persistence and sync behavior:

- Snippet updates write through `SnippetStore` and are saved with a short debounce.
- Immediate writes are used for operations like add/delete/import/export.
- Pending writes are flushed on app termination.

## Keyboard Shortcuts (Main Window)

- `Return`: copy selected snippet to clipboard.
- `Cmd+Return`: paste selected snippet into frontmost app.
- `Cmd+K`: open/close shortcuts panel.
- `Cmd+F`: focus search.
- `Cmd+N`: create snippet.
- `Cmd+E`: edit selected snippet.
- `Cmd+D`: duplicate selected snippet.
- `Cmd+.`: pin/unpin selected snippet.
- `Cmd+Delete`: delete selected snippet.
- `Cmd+Shift+I`: import JSON.
- `Cmd+Shift+E`: export JSON.
- `Esc`: close action panel (or return focus to list).
- `Ctrl+N` / `Ctrl+P`: move selection down/up in list context.

## Import/Export Format and Merge Rules

- Import accepts:
  - A raw array of snippets: `[...]`
  - Wrapped payload: `{ "snippets": [...] }`
- Export writes wrapped payload format: `{ "snippets": [...] }`
- Import merge behavior:
  1. Snippets with matching content are skipped and surfaced as a warning.
  2. Else match by `id` first (replace existing).
  3. Else match by `keyword` case-insensitively (replace existing, preserve existing `id` and `createdAt`).
  4. Else insert as new.

## Data Storage

- Snippets are persisted locally at:
  - `~/Library/Application Support/SnippetsClone/snippets.json`
- On first launch (or load failure), a starter snippet is created:
  - Name: `Temporary Password`
  - Keyword: `tp`
  - Content: `TP-{date:yyyyMMdd}-{clipboard}`

## App Behavior Notes

- App Sandbox is disabled so global key monitoring and synthetic paste can work.
- `Cmd+Q` supports a one-time choice:
  - Hide to menu bar (keep running), or
  - Quit completely.
