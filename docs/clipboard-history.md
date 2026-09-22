# Clipboard history

Clipboard history is a macOS-only, explicitly enabled text feature. The preference
`SnippetsClipboardHistoryEnabled` defaults to false. The main library offers it without
stealing focus on a normal foreground opening in a compact banner below the toolbar.
Closing the banner is remembered; history stays off. Login and
Secure Paste launches do not open that invitation. Settings always provides access.

## Interaction

`⌘⇧V` toggles a non-activating AppKit panel with search, recency list, and a literal text
preview. Return inserts into the captured original text field; with no supported field
it copies. `⌘Return` copies, `⌘N` creates a snippet from the selection, `⌘Delete` removes
one entry, and Escape closes. A conflicting global registration is reported in Settings;
the menu-bar entry remains available. Recording is independent of the expansion shortcut
preference.

While the history panel or the `⌘\` snippet picker is open, `⌘1` through `⌘9`
immediately choose the corresponding result in the current search order. The first nine
rows display their shortcuts; filtering and new copies update the numbering. Selection
uses the same primary action as Return: paste to the captured destination, or copy when
there is no supported destination. Secure snippets still use the existing authentication
and paste checks. Missing result numbers and key repeats do nothing. These shortcuts
are local to the keyboard-enabled picker; ordinary inline suggestions leave them alone.

The history and snippet pickers share a system-adaptive floating surface. Light/dark
appearance changes update open panels without resetting their selection or search.
The full-text preview has a slightly denser reading background over the glass.

History entries are distinct from snippets: insertion never invokes PlaceholderResolver,
sync, or snippet usage ranking. Creating a snippet uses the existing editor and focuses
its keyword field. Search and list updates preserve a user-selected entry by identity.

## Capture and storage

`ClipboardHistoryService` owns polling, preferences, storage work, and lifecycle state.
It does not initialize a pasteboard reader or open history storage while disabled.
Enabling establishes the current generation as a baseline; only subsequent copies enter
history. A 0.5-second poll samples `changeCount`, checks all advertised item types before
reading text, and rechecks the generation after reading. Intermediate rapid copies can
be missed. Exclusions use the frontmost application's bundle ID, an approximate source.

The Foundation-only `ClipboardHistory` policy preserves exact UTF-8 text, including
whitespace and normalization. Repeated identical copies reuse the entry ID and refresh
its position. The bounded, in-memory search index is never written as plaintext.

History is stored under `SnippetStorageLocations.supportFolderURL/ClipboardHistory/`.
The entire document is AES-GCM encrypted with a separate, device-local Keychain key.
The directory uses mode 0700, files use 0600, and the directory is excluded from backup.
The history is not part of the snippet library, sync, diagnostic export, or snippet backup.
An unreadable history is kept and recording stops with a visible error; it is not silently
replaced. Clear is an explicit destructive action that remains available while disabled.

Limits: seven days while enabled, 1,000 entries, 256 KiB per entry, 32 MiB of text total.
Turning recording off retains the encrypted data; expiration is enforced on re-enable.
All storage work is ordered, so an older queued write cannot resurrect a cleared history.
Tests use temporary directories, isolated defaults, fake readers, and isolated keys.

## Pasteboard coordination

The expansion engine drains any pending external copy before temporarily borrowing the
pasteboard. `TemporaryPasteboardLease` acknowledges only proven restored generations,
including acquisition rollback. A competing user copy is never acknowledged as our own.
Transient, concealed, sensitive, generated, file, and private history markers are rejected
by capture. Ordinary explicit snippet copies remain eligible.

History insertion shares the existing injection queue, exact captured field checks,
bounded confirmation, and clipboard restoration. It never fakes a snippet or starts a
second independent clipboard lease. Picker search keystrokes are excluded from expansion
tracking. Protected fields use the existing Secure Paste feature; history falls back to
Copy when it cannot capture a supported ordinary destination.

New history files must not disturb the library's directory observer. A previously enabled
service prepares its directory before SnippetStore initialization. First-time enablement
temporarily replaces that observer around directory creation and reconciles genuine
external library writes afterward.
