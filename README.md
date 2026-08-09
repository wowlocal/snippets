# Snippets (macOS)

Local text-expander app for macOS with a Raycast-style snippet list/editor and global snippet insertion.

## Features

- Create, edit, delete, duplicate, enable/disable, and pin snippets.
- Global expansion in other apps by typing `\` + keyword.
- Suggestion panel near the caret with fuzzy matching on snippet name and keyword.
- Secure snippets stay encrypted at rest, carry a lock marker in suggestions, never
  auto-expand, and require a fresh Touch ID/login-password approval on every explicit insertion.
- Usage-based ranking: snippets you expand often rise in the suggestion panel. Match quality and pinning always win over usage. Two toggles and a reset live in `Settings > General`; usage stays on this Mac and never travels in exports or share links.
- Dynamic placeholders in snippet content:
  - `{clipboard}`
  - `{date}`
  - `{time}`
  - `{datetime}`
  - `{date:<DateFormatter pattern>}` (for example `{date:yyyy-MM-dd}`)
- Share ordinary snippets as JSON, or explicitly create a password-protected encrypted backup
  that also includes secure snippets.
- Share a single snippet via a `snippets://share?...` deep link.
- Menu bar item with quick open/quit.
- Global `⌘\` shortcut that shows the app from any app and hides it again when it already has focus (on by default, switchable in Settings).
- Optional Launch at Login toggle.
- Configurable extra Chromium bundle IDs in a dedicated `Snippets > Settings…` window (applies immediately, no relaunch).

## Requirements

- macOS 15.5+ (project deployment target).
- Xcode with Swift 5 support.

## Build and Run

1. Open `Snippets.xcodeproj` in Xcode.
2. Select the `Snippets` scheme.
3. Build and run.

### Install on a connected iPad

With a paired iPad connected, run:

```sh
./scripts/install-ipad.sh
```

The script discovers the device, performs an incremental signed Release build, verifies
the finished app and its provisioning profile, installs it without deleting its data
sandbox, and launches it. Use `--device <name>` when more than one iPad is paired,
`--no-build` to reinstall the existing derived-data artifact, or `--no-launch` to stop
after installation. If the device is locked, an interactive run asks you to unlock it
and retries the launch. Run `./scripts/install-ipad.sh --help` for all options.

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
- `SnippetUsageStore`: records which snippets get used and supplies the ranking snapshot. Backed by `Usage/usage.json`, a sibling directory to `snippets.json` so its writes never trip the library's folder monitor. Pure math and file format live in `SnippetFrecency` and `SnippetUsageDocument`.

Detailed deep dive:

- `docs/text-input-detection.md` explains cross-app text-input detection, Chromium/Electron workarounds, monitor quirks, and troubleshooting.
- `docs/frecency-ranking.md` specifies usage-based ranking: the decay math, where usage sits in the precedence chain, the merge rules, and the privacy boundary.
- `docs/cloud-sync.md` covers multi-writer safety and the sync/secure-snippet design: the three-way merge, why `snippets.json` is frozen, the vault's key hierarchy and threat model, and what still has to be verified before a backend can ship.

Global expansion pipeline:

1. The expansion engine starts a session-level `CGEvent` tap plus a local `NSEvent` monitor.
2. Typed characters are appended to an internal rolling buffer.
3. On `\`, suggestion mode activates and `SuggestionPanelController` shows ranked matches.
4. Ranking uses fuzzy scoring (`FuzzyMatch`) against snippet name and keyword, then keyword-match quality, then pinning, and only then how often you use each snippet.
5. Selecting an ordinary snippet (or its unambiguous exact-match auto-expand) triggers expansion.
   A secure suggestion must be selected explicitly and authenticates every time.
6. The engine resolves placeholders with `PlaceholderResolver` and injects final text.

Text replacement strategy:

- Preferred path: one atomic Accessibility replacement. The engine proves the text before the caret
  is the trigger it means to delete, then overwrites that range in place — no synthetic keys, and the
  clipboard is never touched.
- Fallback, for fields that expose no writable text: the engine borrows the pasteboard, deletes the
  trigger with synthetic backspaces, and sends `Cmd+V`.
- Chromium-family apps replace the field's whole value instead. Chrome's omnibox acknowledges a
  selected-text write, redraws it, and keeps the old string in its edit model, so Return would
  navigate to what the user typed instead of the snippet — and nothing in the Accessibility tree
  reports that. A whole-value write does reach the model. It is allowed only in the browser's own
  one-line fields, never in rendered page content, which keeps the fallback it already used.
- The borrow is returned once there is evidence the host applied the paste, or on a bounded timeout —
  never on a fixed delay, which is both too slow for a native field and too fast for a loaded Electron
  host. A newer copy is never overwritten.
- Every event the engine posts is tagged so its own injection cannot be mistaken for typing.
- Nothing is injected while secure keyboard entry is on.

Suggestion panel positioning:

- The panel attempts to read caret bounds from Accessibility (`AXBoundsForRange`).
- If that fails, it falls back to focused-element geometry.
- Extra normalization avoids awkward placement in some apps (for example Safari/Chromium-style controls).

Persistence and sync behavior:

- Snippet updates write through `SnippetStore` and are saved with a short debounce.
- Immediate writes are used for operations like add/delete/import/export.
- Pending writes are flushed on app termination.

## Global Shortcut

- `⌘\` opens Snippets from any app, including while it is hidden in the menu bar.
- Pressing `⌘\` again while Snippets is focused hides it. If the shortcut had pulled the app out of the menu bar, hiding returns it there (no Dock icon left behind); otherwise it hides like `⌘H`.
- It is on by default and can be switched off in `Snippets > Settings… > General` (for example when another app needs `⌘\`).
- The shortcut is registered with Carbon's `RegisterEventHotKey`, so it does not depend on Accessibility permissions and works before expansion is enabled.
- If macOS refuses the registration because another app already owns `⌘\`, Settings says so; quit that app and reopen Settings to retry.

## Keyboard Shortcuts (Main Window)

The in-app shortcuts panel shows essential shortcuts by default. Hold `Option` while it is open to reveal the full list.

- `Return`: copy selected snippet to clipboard.
- `Cmd+Return`: paste selected snippet into frontmost app.
- `Cmd+K`: open/close shortcuts panel.
- `Cmd+F`: focus search.
- `Cmd+N`: create snippet.
- `Cmd+E`: edit selected snippet.
- `Cmd+D`: duplicate selected snippet.
- `Cmd+/`: enable/disable selected snippet.
- `Cmd+.`: pin/unpin selected snippet.
- `Cmd+Delete`: delete selected snippet.
- `Cmd+Shift+C`: copy a deep link for the selected snippet.
- `Cmd+Shift+I`: import JSON.
- `Cmd+Shift+E`: export ordinary snippets as shareable JSON (secure snippets are excluded).
- `Esc`: close action panel (or return focus to list).
- `Ctrl+N` / `Ctrl+P`: move selection down/up in list context.

## Import/Export Format and Merge Rules

- Import accepts:
  - A raw array of snippets: `[...]`
  - Wrapped payload: `{ "snippets": [...] }`
  - Password-protected `.snippetsbackup` files created by **Encrypted Backup (Includes Secure Snippets)…**
- **Export for Sharing…** is the default export and writes `{ "snippets": [...] }`; it structurally
  excludes secure snippets.
- **Encrypted Backup (Includes Secure Snippets)…** is a separate action with no shortcut. It seals
  the whole library with a random AES-GCM key, wraps that key from a user password with
  PBKDF2-HMAC-SHA512 (600,000 iterations), and writes the result with private file permissions.
  Snippets cannot recover a forgotten backup password.
- Import merge behavior:
  1. Match by `id` first (replace existing).
  2. Else match by `keyword` case-insensitively (replace existing, preserve existing `id` and `createdAt`).
  3. Else insert as new.
  Importing the same export or encrypted backup repeatedly is therefore idempotent and does not
  create duplicate rows. A secure backup may restore a fresh vault or merge into the same vault;
  importing it over a different vault is refused.

## Deep Links

- `Cmd+Shift+C` copies a shareable deep link for the selected snippet.
- Deep links use the custom scheme `snippets://share?data=...`.
- Opening one of these links shows an import confirmation and then imports that single snippet using the same merge rules as JSON import.

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
  - If you choose "Remember choice", you can reset it later from Settings, the menu bar menu, or the main window's More menu.
