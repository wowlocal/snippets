# Clipboard history

Clipboard history is a macOS-only, explicitly enabled text feature. The preference
`SnippetsClipboardHistoryEnabled` defaults to false. The main library offers it without
stealing focus on a normal foreground opening in a compact banner below the toolbar.
Closing the banner is remembered; history stays off. Login and
Secure Paste launches do not open that invitation. Settings always provides access.

## Interaction

`⌘⇧V` toggles a non-activating AppKit panel with search, recency list, and a literal text
preview. Return inserts into the captured original text field by default; with no supported
field it copies. Settings → Clipboard History → Pressing Enter can switch the primary
action to Copy to Clipboard. The per-bundle preference
`SnippetsClipboardHistoryPrimaryAction` defaults to `paste` and can be changed while
capture is off. `⌘Return` always copies, regardless of this setting.

`⌘K` or the footer's Actions button opens a native menu with Paste, Copy, Create Snippet,
and Delete. Paste is available only when the panel captured a supported text field.
`⌘N` creates a snippet from the selection, `⌘Delete` removes one entry, and Escape closes
the menu first, then the panel. Menu actions retain the original entry by identity across
incoming copies and execute after menu tracking ends; a deleted entry or expired panel
session cannot trigger an action. A conflicting global registration is reported in Settings;
the menu-bar entry remains available. Recording is independent of the expansion shortcut
preference.

While the history panel or the `⌘\` snippet picker is open, `⌘1` through `⌘9`
immediately choose the corresponding result in the current search order. The first nine
rows display their shortcuts; filtering and new copies update the numbering. Selection
uses the same primary action as Return: for history, the configured Paste or Copy action;
for snippets, paste to the captured destination or copy when there is no supported field.
Secure snippets still use the existing authentication
and paste checks. Missing result numbers and key repeats do nothing. These shortcuts
are local to the keyboard-enabled picker; ordinary inline suggestions leave them alone.

The history and snippet pickers share a system-adaptive floating surface with a neutral
veil over the native blur (36% black in dark mode, 30% white in light mode). This mutes
busy backgrounds while preserving translucency and the glass rim. Light/dark appearance
changes update open panels without resetting their selection or search. The same veil
also applies to the pre-macOS 26 material.

History entries are distinct from snippets: insertion never invokes PlaceholderResolver,
sync, or snippet usage ranking. Creating a snippet uses the existing editor and focuses
its keyword field. Search and list updates preserve a user-selected entry by identity.

Nonempty searches run on a serial worker with a prepared, bounded in-memory index.
New queries replace pending work, and results from an old query or closed panel cannot
replace the current list. A quick Return or Command-number waits for the current search
before selecting; changing the query cancels that pending selection. Search retains
AND-of-words substring matching and original entry bytes for delivery. The prepared
cache is released when the query is cleared or the panel closes. Reproduction and
measurements are in [the search performance report](library-search-performance.md).

## Capture and storage

`ClipboardHistoryService` owns polling, preferences, storage work, and lifecycle state.
It does not initialize a pasteboard reader or open history storage while disabled.
Enabling establishes the current generation as a baseline; only subsequent copies enter
history. A 0.5-second poll samples `changeCount`, checks all advertised item types before
reading text, and rechecks the generation after reading. Intermediate rapid copies can
be missed. Exclusions use the frontmost application's bundle ID, an approximate source.

The default excluded apps are Passwords, Keychain Access, 1Password (7 and 8), Bitwarden,
KeePassXC, Enpass, and Proton Pass. The defaults apply only when the exclusions preference
has never been saved; a customized or explicitly empty list is preserved across launches.
Users can remove any default. The list includes apps that are not installed yet, and
Settings shows their names alongside their bundle IDs. No browser or general text editor
is excluded by default. Exclusions reject a copy before reading its text and do not remove
previously saved entries. Browser extensions still depend on the sensitive pasteboard
markers because the foreground app is the browser.

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

History insertion shares the existing injection queue and exact captured field checks.
Choosing an entry writes its literal text to the current clipboard with the internal
history marker, then posts one PID-addressed Command-V. The entry stays on the clipboard,
just like Copy, so a slow receiver can read it without racing clipboard restoration.
There is no artificial paste delay, post-dispatch Accessibility readback, temporary lease,
or delayed restoration. The operation finishes when the shortcut is sent, making the
picker available again immediately. Dispatch is logged without claiming confirmed text
insertion, and it does not show an unconfirmed-paste warning.

A pending snippet clipboard loan must finish before a history entry can replace it.
Focus, secure-input state, and clipboard generation are checked before dispatch; a
changed destination or newer copy prevents the paste. Picker search keystrokes are
excluded from expansion tracking. Protected fields use the existing Secure Paste
feature; history falls back to Copy when it cannot capture a supported ordinary destination.

New history files must not disturb the library's directory observer. A previously enabled
service prepares its directory before SnippetStore initialization. First-time enablement
temporarily replaces that observer around directory creation and reconciles genuine
external library writes afterward.
