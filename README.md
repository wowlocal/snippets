# Snippets

Native, local-first snippet apps for macOS, iPhone, and iPad. Snippets expands text
system-wide on Mac, keeps an encrypted library available across devices, and provides
native keyboard-first and touch-first ways to manage it.

- **macOS:** global text expansion, a caret-side suggestion panel, menu bar access,
  secure insertion, and the full library editor.
- **iPhone:** a touch-first library and editor with tap-to-copy, swipe actions,
  multi-tag filtering, and a short-lived secure clipboard.
- **iPad:** a keyboard-oriented split view with the same library, editor, transfer,
  security, and sync tools.

The project is free and open source under the [MIT License](LICENSE).

## Features

### Fast expansion on macOS

- Type `\` followed by a keyword in another app to open suggestions and insert a
  snippet without switching windows.
- Fuzzy matching searches names and keywords; use `↑` / `↓`, `Ctrl+N` / `Ctrl+P`,
  `Tab`, or `Return` to choose a result.
- An unambiguous exact keyword expands automatically. Prefix collisions are called out
  in the editor so one keyword does not silently block another.
- Pinned snippets and match quality lead the ranking. Optional on-device usage ranking
  and per-prefix selection memory learn what you choose without syncing or exporting
  that history.
- The suggestion panel follows the caret when Accessibility geometry is available and
  falls back safely when an app exposes less information.
- Native text fields use an atomic Accessibility replacement. Compatible fallbacks
  preserve the clipboard, avoid overwriting a newer copy, and include dedicated handling
  for Chromium and Electron apps.
- Secure Keyboard Entry suspends injection.

### A complete snippet library

- Create, edit, duplicate, delete, enable/disable, and pin snippets.
- Create a snippet directly from the current clipboard.
- Add multiple tags, filter by several tags at once, and search across names, keywords,
  content, and tags. Secure snippet bodies remain excluded while locked.
- Get keyword suggestions from the snippet name or first line, live collision warnings,
  placeholder completion after typing `{`, and a rendered placeholder preview.
- Undo and redo ordinary library changes. iPhone also offers an inline Undo action after
  deleting an ordinary snippet.
- Copy a snippet, paste it into the previously active Mac app, or share an ordinary
  snippet through the system share sheet on iOS.

### Dynamic placeholders

Placeholders are resolved at insertion or copy time:

| Placeholder | Result |
|---|---|
| `{clipboard}` | Current clipboard text |
| `{date}` | Localized current date |
| `{time}` | Localized current time |
| `{datetime}` | Localized current date and time |
| `{date:yyyy-MM-dd}` | Date using a compact `DateFormatter` pattern |
| `{date format="EEEE, MMMM d"}` | Date using an explicit quoted pattern |
| `{date locale="fr-FR"}` | Localized date for a chosen locale |
| `{date offset=+1d}` | Date adjusted by minutes, hours, days, months, or years |

The explicit `format`, `locale`, and `offset` syntax is compatible with current Raycast
date placeholders. Offsets can contain several terms, for example
`{datetime offset=+1d -2h}`.

### Secure snippets

- Make any snippet secure to move its body out of the ordinary JSON library and into an
  AES-GCM encrypted vault.
- Reveal or edit secure content only after device-owner authentication. On macOS, the
  editor marks the body as protected Accessibility content, renders it through a
  capture-protected layer, and shows its pixels only while the pointer is over the
  editor. Secure editor copy, drag, Services, sharing, Find, speech, Quick Look, text
  checking, and Writing Tools routes are disabled. On iPhone and iPad, explicit secure
  copy and insertion remain authenticated actions.
- The vault auto-locks after five minutes without secure-content use and always within
  thirty minutes of authentication. Sleep, screen/session lock, screensaver start, and
  iOS backgrounding lock it immediately; merely switching away from the macOS app does
  not, because secure insertion is used while another app is active.
- Secure snippets never auto-expand, never appear in ordinary exports or share links,
  and show a lock marker wherever their searchable metadata appears.
- On macOS, press `⌥\` in a text or password field to open Secure Paste. It searches
  the whole library, ranks secure snippets ahead of equally relevant ordinary snippets,
  restores the exact original field, and writes through Accessibility without exposing
  the body to the clipboard. Secure snippets authenticate on every use; ordinary
  snippets do not. A password field is replaced; an ordinary text field uses its
  selection or caret.
- macOS Secure Event Input can suppress third-party global shortcuts while a real
  password field is focused. In that case choose **Secure Paste…** from the Snippets
  menu-bar item; the mouse-driven route captures the same field before opening the same
  picker.
- A recovery key can restore the vault key if it is missing from Keychain.
- On iPhone and iPad, secure copies are device-local and expire from the clipboard after
  60 seconds.
- Names, keywords, and tags remain visible locally so Snippets can find a secure snippet
  while the vault is locked. The encrypted body is the protected part.

Capture protection and hover reduce accidental screen-share, screenshot, recording,
and shoulder-surfing exposure; they are not a DRM or physical-camera guarantee. A camera
can still photograph content while the pointer is over it, and sufficiently privileged
software on the same Mac remains outside this boundary.

### End-to-end encrypted iCloud sync

- Sync is opt-in on every installation. With it off, Snippets does not create a
  CloudKit transport or sync base.
- Ordinary and secure snippets are encrypted on-device before upload to the app's
  private CloudKit database. The wire encryption key is shared through iCloud Keychain;
  Apple receives ciphertext, including encrypted names, keywords, and tags.
- Field-aware three-way merging preserves edits from multiple devices. Concurrent body
  edits retain the losing version as a disabled conflict copy instead of discarding it.
- A deletion safety guard halts suspiciously large remote deletions for review.
- Use **Sync Now** on Mac or pull to refresh on iPhone. Without push notifications,
  background polling can take up to two minutes to notice a remote change.
- Usage counts and learned prefix choices stay on the Mac where they were recorded.

> A switched iCloud account is still a known edge case: the current sync base does not
> bind itself to the CloudKit user record name.

### Import, export, backup, and links

- Import native raw arrays (`[...]`), wrapped JSON (`{ "snippets": [...] }`), and
  Raycast snippet exports. Raycast date placeholders are preserved or converted to the
  supported explicit syntax.
- **Export for Sharing** writes ordinary snippets only.
- **Encrypted Backup (Includes Secure Snippets)** protects the complete library with a
  password and includes both ordinary and secure records. Forgotten backup passwords
  cannot be recovered.
- Native imports merge by ID first and then by case-insensitive keyword, making repeated
  imports idempotent instead of creating duplicate rows.
- Share one ordinary snippet with a `snippets://share?...` deep link. Opening the link
  shows a preview and confirmation before applying the same merge rules.

### Native platform workflows

On macOS:

- `⌘\` brings Snippets forward from any app and hides it again when already focused.
- Run from the Dock, hide to a menu bar item, optionally launch at login, and choose
  whether `⌘Q` hides or quits.
- Collapse the sidebar for a focused editor; search results become a keyboard-navigable
  overlay.
- Built-in compatibility covers Chrome, Chromium, Edge, Brave, Opera, Vivaldi, and Arc.
  Additional Chromium/Electron bundle identifiers can be added in Settings without a
  relaunch.
- Configure matched-letter highlighting, usage ranking, selection memory, the global
  shortcut, quit behavior, sync, secure storage, browsers, and diagnostics.
- Signed releases check for updates with Sparkle and expose download/apply progress in
  the app menu and window chrome.
- Install the bundled `snippets-cli` from Settings for scripts and agents.

On iPhone:

- Tap a row to copy it, swipe right to edit, swipe left to pin or delete, or long-press
  for all actions.
- Search the full library, filter by multiple tags, and keep pinned snippets in their
  own section.
- Edit in touch-first **Content** and **Details** modes with a keyboard-following mode
  control, live keyword help, tags, enable/disable, secure conversion, and placeholder
  preview.
- Pull to sync, import documents and shared links, export JSON, create encrypted backups,
  and create a new snippet from the clipboard.

On iPad:

- Use a two-column list and editor designed for a hardware keyboard.
- Search, filter, navigate snippets, move between fields, copy, import/export, undo/redo,
  and open the in-app shortcut reference without leaving the keyboard.

### Automation and diagnostics

`snippets-cli` reads and safely updates the same local Mac library. It supports JSON
output for:

- `list`, `search`, `get`, and `tags`;
- `add`, `update`, and `delete`;
- `secure-status`; and
- `reveal`, which asks the running app for human approval instead of decrypting the
  vault itself.

When iCloud sync is enabled and the Mac app is running, CLI mutations share a one-second
trailing debounce and then request one outbound sync round. A script can therefore add or
update many snippets without starting one CloudKit operation per command. If the app is
closed, its normal startup round uploads those changes the next time it launches.

Both apps keep bounded, structured diagnostic logs for troubleshooting. Settings can
export one validated JSONL file or delete retained logs. The schema excludes snippet
bodies, display names, tags, IDs, paths, ciphertext, and keys; secure keywords may be
present after sanitization. See [docs/diagnostics.md](docs/diagnostics.md) for the exact
privacy contract and retention limits.

## Requirements

| Target | Minimum version | UI framework |
|---|---:|---|
| Snippets for Mac | macOS 15.5 | AppKit |
| Snippets for iPhone and iPad | iOS/iPadOS 26.0 | UIKit |

Building the iOS target requires an Xcode version with the iOS 26 SDK. The iOS app is a
universal native target (`TARGETED_DEVICE_FAMILY = 1,2`), not Catalyst and not a wrapper
around the Mac app.

## Download or build

Download the latest signed Mac release from
[GitHub Releases](https://github.com/wowlocal/snippets/releases), or build from source:

1. Open `Snippets.xcodeproj` in Xcode.
2. Select **Snippets** for macOS or **Snippets iOS** for iPhone/iPad.
3. Choose a destination and build.

For a paired iPhone or iPad, the repository helper performs a signed Release build,
validates its entitlements and provisioning profile, installs it in place, and launches
it without deleting the existing data sandbox:

```sh
./scripts/install-ios.sh
```

Use `--device <name>` when more than one device is paired, `--no-build` to reuse the
current device artifact, or `--no-launch` to stop after installation. Run
`./scripts/install-ios.sh --help` for all options.

## First launch on macOS

Global expansion uses Accessibility APIs:

1. Click **Request Permission** in the app banner.
2. Open **Accessibility** from the same banner and enable Snippets.
3. Return to Snippets and click **Refresh**.

Input Monitoring may also be required on some macOS configurations. Library management,
global shortcut registration, and menu bar access do not depend on Accessibility permission;
insertion through Secure Paste does.

## Keyboard shortcuts on macOS

The in-app shortcut panel shows essentials first; hold `Option` to reveal the complete
list.

| Shortcut | Action |
|---|---|
| `⌘\` | Show or hide Snippets globally |
| `⌥\` | Secure Paste into the focused field |
| `Return` | Copy selected snippet |
| `⌘Return` | Paste selected snippet into the frontmost app |
| `⌘F` | Search |
| `⌘B` | Toggle sidebar |
| `⌘K` | Toggle shortcut panel |
| `⌘N` | New snippet |
| `⇧⌘N` | New snippet from clipboard |
| `⌘E` | Edit selected snippet |
| `⌘D` | Duplicate selected snippet |
| `⌘/` | Enable or disable selected snippet |
| `⌘.` | Pin or unpin selected snippet |
| `⌘Delete` | Delete selected snippet |
| `⇧⌘C` | Copy share link |
| `⇧⌘I` / `⇧⌘E` | Import / export for sharing |
| `⌘Z` / `⇧⌘Z` | Undo / redo |
| `Ctrl+N` / `Ctrl+P` | Move selection down / up |

## Storage and privacy boundaries

The normal storage root is:

- macOS: `~/Library/Application Support/SnippetsClone`
- iOS/iPadOS: `Library/Application Support/SnippetsClone` inside the app container

Important contents include:

```text
SnippetsClone/
├── snippets.json          # ordinary snippets
├── Vault/vault.json       # secure metadata and encrypted bodies
├── Sync/                  # merge base, state, tombstones, and quarantine
├── Usage/usage.json       # Mac-only ranking history; never synced
├── Diagnostics/Logs/      # bounded structured JSONL logs
└── Backups/               # safety snapshots made by the merge layer
```

The Mac app creates a starter snippet on first launch. The iOS app intentionally starts
with an empty library so a fresh installation can fetch the remote library without
looking like it authored a local record.

## Architecture

- `snippets/` contains the AppKit app, expansion engine, Mac settings, CloudKit app
  boundary, diagnostics backend, and platform integrations.
- `snippets-ios/` contains the native UIKit universal app, including separate iPhone and
  iPad workflows.
- `snippets/Core/`, `snippets/Sync/`, `snippets/Vault/`, and
  `snippets/SnippetStore.swift` hold the shared model, persistence, crypto, merge, sync,
  and vault logic.
- `snippets-cli/` contains the entitlement-free command-line client.
- `CorePackage/` is a test overlay for the shared Foundation-only core.

The CloudKit implementation stays at the app boundary. The shared core does not import
CloudKit, AppKit, UIKit, CocoaLumberjack, or MetricKit unconditionally.

More detail:

- [docs/text-input-detection.md](docs/text-input-detection.md) — cross-app text input
  detection and replacement strategies.
- [docs/frecency-ranking.md](docs/frecency-ranking.md) — usage ranking, decay, merging,
  and privacy.
- [docs/cloud-sync.md](docs/cloud-sync.md) — sync safety and secure-snippet design. Its
  older phase/status table predates the shipping CloudKit transport and iOS target; the
  current code is authoritative for implementation status.
- [docs/android/README.md](docs/android/README.md) — implementation plan for the native
  Android app, shared Swift core, fully compatible iCloud/HTTP provider switching, and
  the self-hostable sync service. It is a design proposal, not shipping status.
- [docs/diagnostics.md](docs/diagnostics.md) — persistent logging, exports, privacy, and
  collection workflows.

## Verification

Run the checks that cover the changed layer. For cross-platform shared-code changes:

```sh
swift test --package-path CorePackage

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme Snippets \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/snippets-macos-derived \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iOS' \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/snippets-ios-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run iOS unit and UI tests on available iPhone and iPad simulators as described in
[AGENTS.md](AGENTS.md).

For the Android application, use Android Studio's bundled JBR and an API 36 emulator:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:testDebugUnitTest :app:connectedDebugAndroidTest
```

`CloudEndToEndTest` is opt-in because it destroys only the test application's local
encrypted state and requires a disposable Snippets Cloud space. It uploads an encrypted
snippet, deletes the local files and Android Keystore wrapping key, then downloads and
decrypts the record with the same portable `sync-v1` key:

```sh
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.khm.snippets.android.CloudEndToEndTest \
  -Pandroid.testInstrumentationRunnerArguments.snippetsServerUrl=https://sync-test.example \
  -Pandroid.testInstrumentationRunnerArguments.snippetsAccessToken='<ephemeral-test-token>' \
  -Pandroid.testInstrumentationRunnerArguments.snippetsSpaceId='<disposable-space-uuid>'
```

Never point this destructive fresh-install test at a production app sandbox or reuse a
production bearer token.
