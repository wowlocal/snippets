# Snippets for Omarchy

Native GTK 4 / libadwaita desktop app and CLI, written in Rust. Python is not needed
to build, install or run the application. It is used only by development tools
that regenerate checked-in reference fixtures or rebuild an optional patched GTK
dependency with upstream Meson tools. The client handles ordinary local entries
and an encrypted vault workspace; [the full desktop port remains in development](../docs/linux/IMPLEMENTATION.md).

## Core qualification, 2026-10-06

Core functionality takes priority over further sync and race-condition work.

| Feature | Current result |
| --- | --- |
| Global shortcuts | Saved Super+Alt+N/P/C bindings pass Open, targeted Picker/Return and Capture through native virtual-keyboard events. Picker returns focus and restores the previous clipboard. Physical hardware input is not established by these events. |
| Clipboard history | Installed UI consent, collection while its window is closed, accessible row selection, literal Copy, opt-out, process restart and Clear pass with an isolated real keyring. The independent GTK button now passes with the test pointer kept alive; physical pointer input remains unverified. User library data and prior ordinary clipboard text are preserved. |
| Inline expansion and suggestions | The updated native candidate integrates with Fcitx instead of competing for its input-method seat. The actual user-prefix GUI and addon expand real library records in GTK, default native Wayland Chromium and Ghostty with the stock Omarchy Fcitx service running. A single `\` opens the caret panel; Down and Return insert the selected actual record without moving receiver focus. |

The panel follows the Mac interaction: up to eight ordinary names with keywords
on the next line, typing `\` to open, arrows or Ctrl+N/P to select, Return/Tab to
insert, Escape to dismiss. New explicit **Enable Expansion…** consent enables
suggestions in the same action. Existing preferences are preserved, including
legacy exact-only consent. Snippets now supplies a Mac-style rounded panel through
the existing Fcitx connection, using the Omarchy palette. It includes wrapped
titles, keyword match tint, tags and mouse selection. Other input methods retain
their own Fcitx theme.

The original `0c125c28` receiving-app failures remain recorded. A first browser
observation in the new integration also failed; an unchanged repeat passed. That
initial result is retained as unclassified, not claimed fixed by retrying or by
waiting longer. Further sync and chooser-race work stays deferred. The current
compositor is still in Safe Mode using the user's unchanged profile; physical
input and a fresh normal session remain separate checks.

## Build and install

On Omarchy, install missing build and native runtime packages:

```sh
omarchy pkg add rust gtk4 libadwaita icu libsecret pam qrencode fcitx5 wayland wayland-protocols libxkbcommon pkgconf base-devel
```

Requirements: Rust 1.92+, GTK 4.12+, libadwaita 1.5+, ICU, libsecret 0.21+, Linux-PAM,
libqrencode 4.1+, Fcitx5 5.1+, Wayland, libxkbcommon, Cairo/Pango, json-c and wayland-protocols with the ext-data-control-v1 XML. Cargo dependencies
are locked in `Cargo.lock`. Source builds normally use the installed native GTK.
The latest user-test candidate includes GTK 4.22.4 and libadwaita 1.9.3 with the
verified fallback-cancellation and alert-heading measurement repairs as app-local
shared libraries. Other native dependencies are provided by Omarchy. The combined
runtime passes its minimal reproductions, installed-GUI Cancel/focus/private-state
check and existing host-portal smoke with verified mapped libraries.
The CLI and storage model also build without GTK or libsecret using `--no-default-features`.

From the repository root:

```sh
cargo run --locked --manifest-path snippets-linux/Cargo.toml --bin snippets
./scripts/install-linux.sh
snippets
```

The installer builds the release executables and installs `snippets`,
`snippets-cli`, a private `snippets-owner-auth` helper, desktop actions, the existing app icon, and AppStream metadata
under `~/.local`. `--prefix PATH` selects another prefix; `--no-build` reuses
existing release binaries. It preserves library data and desktop configuration.
Ensure the prefix's `bin` directory is on `PATH`.
The authentication helper stays beside the application under `share/snippets-linux/`;
it has no `bin` shortcut and runs without elevated privileges. Installation does
not create or edit a system PAM policy.

A bundled GUI embeds a relative ELF RUNPATH pointing to a manifest-addressed GTK
directory beside the executable. The installer checks the exact regular-file
payload, manifest/content hashes and SONAME before installing it, then completes
and rechecks the runtime before replacing the GUI. Source builds without this
option keep using system GTK even when an older bundle directory is present.
CLI/helper and launched external applications receive no library-path override.
`readelf` from binutils is required by the installer. The optional build input is
`SNIPPETS_GTK_RUNTIME_DIR=gtk-runtime-<SHA256-of-SHA256SUMS>`; the corresponding
directory belongs under the release output. The bundled license, original source
archive, patch, receipt and `REBUILD.txt` allow rebuilding/replacing the dependency.

## Desktop settings and login startup

Open **Settings…** from the menu, press **Ctrl+,**, or run `snippets --settings`.
The native preferences window searches its row titles and descriptions. Its pages
open the existing vault, Cloud account/recovery, inline expansion, learning,
clipboard history and encrypted backup controls.

**General → When Library Window Closes** chooses **Hide and Keep Running**
(the default) or **Quit Snippets**. Quit uses the same draft-saving, sensitive
operation cancellation and worker-completion checks as Ctrl+Q and `snippets --quit`.
Settings writes finish before quitting. Closing the Settings window hides it.

**Launch at Login** explicitly registers this installation to start with
`--background`. That command starts the primary desktop owner and its existing
opt-in services without opening the library window. Recovery-required startup
shows the recovery window. A secondary background invocation leaves the current
windows alone. Opening Settings only reads the current preferences and login entry.

Registration uses a private app-owned entry at
`$XDG_CONFIG_HOME/autostart/com.khm.snippets.linux.desktop` (normally
`~/.config/autostart/`). Disabling writes `Hidden=true`, which also masks a
lower-priority system entry. A changed installation offers **Use This Installation**;
this updates only an unchanged managed entry. Custom, newer, linked, oversized or
concurrently changed entries are preserved. Paths with a literal backslash cannot
be enabled because the installed systemd generator cannot preserve them; use the
normal installed location instead. Spaces, Unicode, quotes, dollar signs and
percent signs are checked with independent native launchers.

Omarchy's UWSM handles [XDG autostart](https://raw.githubusercontent.com/Vladimir-csp/uwsm/master/README.md).
The registration follows the [desktop autostart specification](https://specifications.freedesktop.org/autostart/latest/).
The mapped Settings switch, actual XDG generator and installed release pass a
live user-systemd activation check in Omarchy. The background primary has no
window; opening the application activates that same process, and one Quit stops
the service. Disabling registration prevents its next private target activation.
The fixture uses private config/data and unique runtime units, preserving the
user's login entry. A full logout and new sign-in remain a separate check.

## Desktop tray

The primary desktop process publishes a native status item for Omarchy's panel.
Left-click opens the library, middle-click opens the copy picker, and right-click
offers **Open Snippets**, **Find a Snippet…**, **Capture Clipboard**, **Clipboard
History…**, **Settings…**, **Secure Snippets…**, **Account & Recovery…** and **Quit
Snippets**. The picker opened here copies ordinary text; `snippets --picker`
captures a receiving window for targeted paste.

The menu uses the same actions as the application. Recovery disables unavailable
library actions; Quit keeps the existing save and worker-completion checks. Opening
history or account controls preserves their existing opt-in and authorization
steps. The tray exposes only fixed public labels and a generic recovery status.

This requires a running StatusNotifier host, supplied by the current Omarchy
shell. The app uses its existing session connection and re-registers when the
host restarts. If the host is absent, open Snippets through the application
launcher or `snippets`. The public icon, registration and host-restart checks pass
on the real Omarchy shell. Its visible menu opens Settings through a native pointer
click and focuses that window. Menu actions use labels without optional GTK
symbolic icons, which the Qt host could not resolve. The status item retains its
public application icon.

## Local diagnostic logs

**Settings → Diagnostics** shows local log storage and offers **Export Logs…**
and **Delete Logs…**. The primary desktop process writes structured plaintext
JSONL under the library root's `Diagnostics/Logs/`. Ordinary CLI and headless
startup do not create diagnostics or install a logging backend.

Logs contain closed operation/stage/outcome labels, aggregate counts, durations
and classified numeric errors. Snippet bodies, names, keywords, tags, clipboard
contents, record/account/device identities, paths, ciphertext and keys are excluded.
Only these sanitized records are mirrored to the native system log. Logs stay
local and are absent from library synchronization and encrypted backups.
System-log copies follow the host's retention and are outside **Delete Logs**.

Retention is limited to 14 days, 64 files and 24 MiB; files roll at 1 MiB or
24 hours. Directories use `0700` and files `0600`. Export asks for confirmation,
validates the exact Linux event vocabulary and saves one JSONL file beginning
with a manifest, capped at 25 MiB. Only a torn final line can be skipped.
Linked/non-regular inputs, duplicate sequences, unknown fields and changed
destinations are refused. Review the plaintext file before sharing it.

Deletion removes retained app-owned logs, including corrupt regular logs;
new operations can create new logs. It preserves library and recovery data,
unrelated files and unsafe linked inputs. Storage, schema, privacy, rotation
and export checks use temporary roots. The complete native export/delete cycle,
including privacy confirmation, cancellation, the actual host SaveFile portal,
private output permissions and subsequent recording, passes in a public isolated
fixture. That fixture neither installs a global sink nor exercises the system-log
mirror. See [live diagnostics acceptance](#live-diagnostics-export-and-delete-2026-10-04).

## Library

- Start empty, create entries, or import a Mac/iOS **Export for Sharing** file.
- Changes autosave after 600 ms. Ctrl+S saves immediately.
- The ordinary editor suggests keywords from the name or first content line.
  Suggested buttons avoid reserved keywords and enabled prefix conflicts;
  existing keywords appear as references. Tab at the end of the keyword field
  completes the next shared part without choosing between ambiguous entries.
  Warnings explain duplicates and both directions of trigger-prefix conflicts.
- Search names, keywords, tags, and ordinary text. Metadata supports fuzzy
  subsequences; content uses contiguous matching. Selected tags must all match.
  Pins sort first; disabled entries stay editable but leave the picker.
- Duplicate, delete with confirmation, undo/redo library changes, or capture
  clipboard text. The content editor has a separate text undo history.
- Import native arrays, `{"snippets": [...]}`, or Raycast JSON. Existing identifiers
  and keywords are skipped. An invalid record rejects the entire import.
- Export ordinary entries as plaintext JSON after reviewing the sharing notice.
- Copy resolves `{clipboard}`, `{date}`, `{time}`, `{datetime}`, compact ICU
  formats such as `{date:yyyy-MM-dd}`, and explicit `format`, `locale`, and
  calendar `offset` attributes. Unknown/malformed placeholders remain literal.
- **Preview…** shows a bounded snapshot of resolved ordinary text. Opening it
  explicitly reads the clipboard only when `{clipboard}` is present, with the
  existing size/time limits and desktop-session checks. Closing it, leaving the
  window, changing the draft, quitting or observing a desktop lock clears the
  preview and cancels an unfinished read. Clipboard display is capped at 1,000
  graphemes or 8 KiB; the complete preview at 2,000 graphemes or 16 KiB. Copy
  resolves the template again. Secure bodies never supply keyword suggestions
  or enter this preview.
- External changes are polled every two seconds. Conflicting saves preserve the
  unsaved draft; Reload offers to discard it and load the current disk record.

The local root is `${XDG_DATA_HOME:-~/.local/share}/snippets/`. `snippets.json` and
`library.lock` use mode `0600`, the root `0700`. Writers take a common process
lock, reread the library, compare the edited record, then atomically replace and
fsync. UUIDs, flags, tags, and Foundation's 2001 reference dates match the Apple
format. Linux never opens Apple's live support directory or CloudKit checkpoints.
`SNIPPETS_SUPPORT_DIR` redirects storage for isolated tests only. Locked vault
metadata reserves identifiers and keywords; ordinary operations fail closed on
an unreadable vault. Explicit bidirectional **Sync Now**, cloud receiving, sending, missing-snapshot review
and single-record deletion/restore decisions are available. Opt-in automatic
synchronization and current v1 conflict-owned absence/deletion recovery are implemented.
Saved local changes can be reviewed and restored from library-switch history.
Remote deletion of materialized conflict originals can now be reviewed while
retaining original requests and later local edits. Protected repairs require the
matching vault's passphrase or recovery key. Missing originals and known current
conflict carriers can be recovered together through an authenticated group review.
If a missing conflict copy has its own pending deletion, **Review Deletion** now
offers that copy first. The dialog identifies it as a prerequisite and confirms
only its own fate. Review again afterward for the parent. Restoring a secure
copy requires vault authentication; an original not yet materialized requires
authentication for either choice. Later body edits remain intact. Existing
originals, cloud requests and later decisions keep their ordering.
A prerequisite whose original is still inside the parent's current conflict,
with no preservation frame yet, can also be restored. Both choices authenticate
the matching vault and retain the encrypted original before applying the child's
own decision. The parent's contents or absence and previous cloud requests stay
intact until its separate review.
Directly selected pending raw-copy deletions can also be restored while their
parent remains live. Each sibling keeps its own exact pending decision, even
when a previous review has already retained the whole group's originals.
An unsupported variant in the related group keeps that decision unavailable;
unrelated records are not included in the child's decision.

The account-review journal and its durable key owner preserve encrypted previous
state, local intent and old key/recovery/pairing capabilities across an explicitly
reviewed library switch. Native review, resume, cancellation and offline completion controls are now
connected to the worker. Secret Service retains the selected library's verified
key before journal publication and resumes interrupted activation while fencing
normal key/data operations. The combined live desktop/keyring/HTTPS workflow still
needs verification. An existing empty target can now receive its first keys in a
separate protected history before the switch is explicitly reviewed.
An initialized library's candidate can now be obtained through trusted-device
pairing and kept separately until the switch is explicitly confirmed.

New switch history also retains the vault's encrypted key wraps in Secret Service,
without saving its catalogue records or unrelated metadata. These wraps remain
available if the current vault is later replaced. Older history can lack them;
the core can now authenticate the saved source vault independently and re-encrypt
archived secure conflict graphs into the current vault. Native restoration now
offers independent previous/current passphrase or recovery-key inputs. Explicit
file selection also supports older history without retained wraps: choose the
previous `vault.json` or `.snippetsbackup` file. A backup uses its own password;
its records are not imported. The file and selected history must remain unchanged
until confirmation. After durable consent, interrupted restoration can finish
without that file or either vault key. Live verification of these native dialogs
remains pending.
The same serialized retention controller is used by the app and isolated worker
tests. A failed preparation consumes the selected-file token, so choosing the
source again is required before retrying; unrelated commands discard it as well.
Backup credentials use a password without offering a recovery-key option.

For saved changes spanning several vaults, choose **Choose Several Vault Files…**.
Select their vault JSON files or encrypted backups, then enter each password or
recovery key in its labelled field. You can also unlock the vault retained in
recovery history; leave that option off if you selected the same vault as a file.
At most eight source vaults can be used for one review. Each body must authenticate
with exactly one supplied vault, even when vaults share the same kid. Missing or
duplicate ownership refuses the whole restoration. All selected files must stay
unchanged until confirmation; after durable consent completion needs no source
file or live vault key. Failed preparation consumes the complete file-selection
ticket. These paths have isolated core and production-retention coverage; live
verification of the native picker and inputs remains pending.

Explicit previous-vault authentication can also recover missing own vault stamps
or content hashes in archived records. The original encrypted body and its UUID
must authenticate before current metadata is derived. Existing invalid metadata,
incomplete raw conflict snapshots and edited copies masquerading as originals
are refused. Present invalid live-record and wire metadata stay strict.

Legacy own secure wire records without a vault stamp can be recognized as exact
saved echoes while the vault is locked. Changed or absent unstamped bodies still
stop ordinary receiving. The primary apply core can authenticate them against
the current vault key and required content hash, preserving the incoming sealed
bytes and journal evidence. **Verify Vault and Sync…** connects fresh current-vault
authentication to one bounded receiving/sending cycle. The editor's unlocked key
is not used by the account worker. Conflict copies and original v1
snapshots continue to require their stamps and hashes.

The Rust core now implements the existing encrypted Cloud wire format and native
HTTPS transport, with independent cryptographic/Swift number-format fixtures and
local HTTP integration tests. Three-way merge and an encrypted journal kernel
preserve conflict bodies, exact offers and original CAS across restart.
Lossless projection and encrypted two-file recovery protect interrupted library
updates; the core refuses reads and writes until recovery completes. After an
interrupted update, the app opens a recovery screen instead of exiting. Use
**Account & Recovery** to reconnect your saved account and library, then choose
**Sync Now**. Library actions stay unavailable until authenticated recovery and
validation of both local files succeed. Existing unsaved ordinary drafts remain
in the editor during a recovery halt; reopening the app does not restore a draft
that had never been saved.
Known secure conflict variants authenticate and reseal under their copy UUID;
exact original evidence stays in the encrypted journal while later edits remain
in primary storage. A native Secret Service backend and durable credential owner
now handle sign-in, refresh, revocation and interrupted credential replacement.
They require an unlocked compatible system keyring; values never fall back to
library files. Portable pairing/recovery cryptography and scope-bound authority,
recovery-state and first-key bootstrap HTTP operations are implemented and tested.
Signed pairing approval/recovery replacement validate the complete challenge and
retain the exact original request across retry; pairing envelopes are released only
through atomic claim. A durable Secret Service owner now saves the library-key
candidate and recovery capability before bootstrap, resumes interrupted activation,
and verifies recovery and the immutable server authority before installing a key.
Paired-recipient setup persists its private draft and received envelope, retries
the same claim after a lost response, and finishes retained activation after
expiry. Failed persistence retains response ownership; cancellation cannot discard
a received key. A bounded native PAM worker and a process-local, single-use gate
now protect recovery-kit disclosure against changed saved state, scope or server
envelopes. Confirming the last eight characters of a saved code retires any
promoted mutation, first-key candidate and handover target copies before replacing
the presentation with bound verification metadata; original source capabilities
remain in protected history. Restart resolves a lost
write receipt without regenerating a code. Native account/key setup and recovery
presentation/confirmation pass a combined live GTK, verified HTTPS, private native
keyring and private-policy PAM check, including a fresh worker reconnect and
sign-out. Signed approval/recovery operations now retain their
candidate and original proof in Secret Service and have native review/authorization
actions. A bounded inbound owner now saves each authenticated page and its cursor
in one encrypted checkpoint, applies records in server order, and resumes retained
pages after a crash. Native **Sync Now** coordinates receiving and sending; the
separate **Receive Cloud Changes** action remains available. Saved local changes
have native restoration controls, including archived nested conflict groups and
deleted/missing archived participants, restoration beside current pending groups
and ordered archived generations.
Restoring archived secure records into a different vault now uses separately
authenticated source and current vaults. Its native dialog still needs live
display verification. Startup stays offline unless automatic
sync was explicitly enabled for a verified saved library.

## Account and library recovery

Open **Account & Recovery…** from the menu. Opening the window reads saved account
metadata without making an HTTP request. Enter your HTTPS Snippets Cloud server,
then choose **Create Account** or **Sign In with Account Key**. Snippets Cloud
never asks for an email address. A new account shows **Save Your Account Key**
once, in monospaced selectable text with **Copy**; continue only after choosing
**I've Saved It**. The key is the only way to sign in to the account on another
device, and Snippets cannot recover or resend it. Signing in accepts the key with
or without dashes, in either case, and with `O`/`I`/`L` typed for `0`/`1`/`1`; a
key that fails its built-in check is reported as a typing error and never sent.
After the server rejects a key, correct it and choose **Sign In** again.

The key is stored with the session in the system keyring and removed with it on
**Sign Out**, which asks first: you need the key to sign in again. While signed in,
the window shows a short **Account ID** and **Show Account Key…**, which requires
your computer login password like recovery-code disclosure. A shown key hides when
the window loses focus, the desktop locks or authorization expires. **Copy** marks
the clipboard as a password for clipboard managers, keeps it out of Snippets'
clipboard history, and clears it after two minutes if it is still current. Keys
never enter logs, diagnostics, exports or backups. A session saved by the retired
email sign-in is ignored, replaced on the next account operation, and requires
signing in again.

**Sign In with Another Device** appears when the server advertises device-approved
sign-in. It shows a QR code, copyable request text and a confirmation code; no key
is typed. On a device that is signed in and opens the library, paste or scan the
request into the add-device field, check that both devices show the same code,
continue and enter your computer login password. That device approves the pairing
and signs this computer in; this computer then selects that library and receives
its key. The request expires after ten minutes; **Cancel** discards it locally. A
device signed in this way cannot show the account key.

**Reconnect Saved Account**
refreshes the retained session and lists existing libraries. Account and keyring
operations run in one worker outside the GTK thread. Closing the window preserves
worker ownership; quit remains unavailable during an in-flight operation or while
a session or pairing response needs secure storage. **Retry Secure Storage**
retains that response before another account operation can proceed. Key operations
check that live credentials still match the committed account and token generation.

If encrypted incoming records or secure conflicts stop ordinary sync, choose
**Verify Vault and Sync…** after selecting and verifying the library. Enter the
current vault's passphrase or recovery key. The worker captures the exact vault
file and actual library/key epoch before asking for credentials, verifies them
afresh, and borrows the resulting key for that single bounded sync cycle. It does
not unlock or extend the editor session. The dialog defaults to Cancel and clears
its field; focus loss, hiding, desktop lock, cancellation or the two-minute deadline
revoke the operation. Account, library-switch, snapshot and deletion reviews still
apply. A saved page or conflict response resumes with its original encrypted bytes
and CAS version. Cancelling before the write journal preserves current primary
files; cancellation after journal publication retains the encrypted redo for normal
recovery. Saved automatic scheduling pauses until the request/cycle releases its
key; ordinary and automatic cycles continue without borrowing an editor key.
The mapped native dialog now passes combined private-keyring/verified-HTTPS
acceptance with independent public vault wraps. Cancel, incorrect passphrase,
focus loss and replacement of the captured file preserve primary/checkpoint
bytes. A fresh passphrase cycle receives an unmarked legacy secure edit and sends
the local secure edit; another such incoming edit requires a new recovery-key
authorization. Explicit same-vault routing also passes sealed exchange while the
vault stays locked. A retained strict-CAS secure conflict now passes native
preservation: its disabled protected copy is acknowledged before the source
changes. Fresh-authorized restoration of a missing copy preserves its nonce.
Flat current secure v1 cloud-source Keep/Delete and acknowledged-copy deletion
repair now pass native acceptance with independent mixed source/copy choices and
retained source rejection packets. Nested physical/journal-only C1 source
Keep/Delete also pass: original copies are acknowledged before later intent,
and C1 retains its sealed body. A cloud-deleted copy received before its raw
owner arrives now receives its own Keep/Delete choice before either parent
choice. Unknown pending raw-child Keep/Delete decisions now pass before parent
Keep, with separate fresh credentials and exact copy-before-source CAS. Local-absence
secure source Keep/Delete also passes with its own mapped review and fresh credentials.
Unrelated accepted-but-unanswered packets now pass native local-absence Keep/Delete
review with exact ciphertext/CAS retry; new pages remain blocked until that send finishes.

After reconnecting, selecting a library and verifying its keys, choose **Enable
Automatic Sync for This Library**. Snippets resumes that exact saved account and
library after restart, checks every 30 seconds while running (including with the
window hidden), and schedules checks on foreground activation and ordinary local
edits. Each cycle has the same bounded receive/send limits as Sync Now. Reader
libraries only receive changes. Temporary network or keyring failures back off
from five seconds to five minutes; longer server retry delays are respected up to
24 hours. Reviews and invalid saved state stop automatic cycles and remain visible
in Account & Recovery.
An interrupted credential refresh may require **Resume Interrupted Account
Operation** or **Retry Secure Storage** before another refresh can proceed;
automatic mode does not discard or repeat an unresolved issuance.

**Turn Off Automatic Sync** also works during account activity or local backup
recovery. It fences new requests immediately and saves the disabled preference
through the existing worker. An already sent operation can finish saving its
encrypted receipt; the next verified cycle resumes it without resending. Changing
the account or library, reconnecting, or starting key/recovery operations turns
automatic mode off before the operation proceeds. Enable it again after review.
The public preference contains only a consent nonce; account/library pins stay in
the system keyring. A missing preference does not create an owner, sync keys or
checkpoint and makes no network request. The combined live GTK, private native
keyring and verified HTTPS checks now cover explicit enable, transient HTTP
backoff/retry, bidirectional exchange on the normal 30-second timer with the window
hidden, consent-based startup through a new worker and disabling while a response
is in flight. A read-only library receives without uploading local edits; a changed
membership stops background work until review. After disabling and restarting,
no background HTTP request is made.

The library selector starts at **Select a library…**. Choose an existing library,
then explicitly set up/resume its keys or supply its offline recovery code/QR
payload. Library selection does not mint a key. A changed account or library
requires explicit review before its keys can replace retained state.

For an existing initialized library, choose **Review Library Switch…**. Enter its
recovery code or leave the field empty to reuse an available retained key after
fresh server verification. Review the account/server, selected library and retained-record counts,
confirm the switch, then authenticate with your computer password. Local records
and previous keys are kept; the next **Sync Now** can upload those records to the
selected library. Selection alone does not authorize that transfer.

Leaving the recovery field empty checks locally owned keys against the selected
library's current server authority. A retained first-key candidate, received pairing
envelope or key from earlier library history can be reviewed again after an account,
membership, dataset or epoch change, provided it belongs to the same server instance
and library. The dialog identifies whether it uses a retained key or the recovery
code you supplied. Ordinary reconnect/pairing/setup cannot reuse the old consent.
If the epoch changed, the previous recovery code stays in protected history and is
not offered as a current code; obtain the current copy from a trusted device or
explicitly replace it after activation. An unchanged-epoch code is carried forward
only with fresh server evidence. A changed history or credential generation before
confirmation requires a new review.

If its key is not saved here, choose **Get Selected Library Key…** and approve
the public invitation on a trusted device that already opens that library. Compare
the confirmation codes on both devices. The received key is retained in a separate
protected history; it does not replace your current keys, start synchronization,
or create a checkpoint. Then leave the recovery field empty and choose **Review
Library Switch…**. Receiving approval and switching are separate actions.

Reconnect and select the same library to continue an interrupted request. A retained
claim can finish verification after the invitation expires. **Retry Secure Storage**
keeps a received response if the keyring write failed; quit remains unavailable
until that response is retained. Cancel an unapproved or interrupted creation attempt
before requesting another invitation. An already received key stays in protected
history. History is bounded to eight attempts and 128 KiB and refuses new requests
without evicting previous candidates. **Library Recovery History…** shows its
saved requests, received-key status and library-switch restoration actions.

For an existing empty library where you are the owner, choose **Create First Keys
for Empty Library…**. Confirm the displayed account, server and library. The worker
retains the exact new key and recovery code before asking the server to initialize
the library; the server atomically refuses an already initialized or nonempty target.
Current local keys and records stay in place. Then choose **Review Library Switch…**
and authenticate to activate the retained key. Use **Show Pending Recovery Code…** after
activation and confirm the last eight characters of your saved copy. Reconnect and
select the same target after an interruption, then choose **Resume Selected Library
Key Setup**; it reuses the retained key and recovery envelope. A competing setup
keeps the unused candidate in protected history and requires the winning library's
trusted device or recovery code. This separate first-key history is bounded to
eight entries and 128 KiB without evicting previous capabilities.

After an interruption, reconnect and select the same target library, then use
**Resume Saved Library Switch…** with fresh local authentication. **Cancel Saved
Library Switch…** works without a server connection before the new journal is
published: it requires an unlocked keyring and local authentication, retains the
candidate key in protected history, and preserves later local edits. Once publication
has occurred, **Finish Saved Switch Offline…** can finish its local key activation
even after changing account or server. It checks both saved encrypted images and
the exact published journal, requires fresh local authentication, and preserves
later local edits and previous keys. It does not contact a server. Reconnect and
select a library afterward to verify access before syncing. A changed or advanced
journal requires separate recovery; this action cannot overwrite it.
Cancellation lets you start a new review
with the current local files; it does not discard previous keys or frozen recovery
images. Selecting a previous library can propose its retained key for fresh review;
**Library Recovery History…** is available without reconnecting. It lists previous
and reviewed keys, saved local-change counts, retained recovery capabilities,
pairing requests and first-key setup. Both encrypted states are authenticated before
the view reports them as verified. Missing, damaged or unsafe states are marked;
the view also shows whether the current journal matches a saved state. Recovery
metadata reflects the last saved receipt; reconnecting checks current access.
Viewing history exposes no recovery codes or snippet contents. Choose **Review…**
under a verified saved switch to restore its saved local changes. Review the saved
and current libraries and record counts, then authenticate with your computer
password. Secure changes also ask for the current vault's passphrase or recovery
key. If the saved changes use a previous vault, enter its passphrase or recovery
key separately; each vault can use a different authentication method. The dialog
suggests the previous vault when its saved encryption scope differs. The
confirmation explains that those records will use the current vault's encryption.
Verification alone does not apply changes. Closing or backgrounding the window,
a desktop lock, session change or two-minute deadline cancels that preparation.
Both password fields clear on cancellation and submission. A separate computer
password authorization follows the review.
Current records remain; changed current versions are kept as disabled preservation
copies. Historical tombstones do not delete current records. The operation creates
fresh local edits and keeps the current synchronization journal's server facts.
It contacts no server and never reactivates archived keys or cloud cursors.
Archived conflict groups restore together. Their exact original preservation
copies remain separate from later edits, including encrypted copies. Subsequent
sync saves nested versions before the original copy, confirms the parent, then
sends the edited copy. Historical acknowledgements and CAS versions are not reused.
When current conflict groups are still pending, their original sends finish first.
Deleted or missing archived conflict copies can be restored from retained live
versions. If a deleted parent has no retained body, its live copies are restored
while the current parent stays in place. Missing encrypted originals are created
from authenticated saved conflict data after unlocking the matching vault. Newer
current edits are kept as disabled copies. Existing authorized deletion requests
finish before the new restored version; archived deletions are never sent again.
Restored changes wait in the encrypted journal and survive a restart. Each version
uses fresh acknowledgements and the current server version when it becomes eligible.
An archive's pending generations return in their saved order, including exact
encrypted originals with different nonces. All secure generations are verified
before the final file update. Old server acknowledgements and offers are discarded.

**Saved Restorations** shows retained receipts. After an interruption choose
**Finish…** with fresh local authentication. **Cancel…** works before the file
update starts and keeps later local edits and every retained image. After the file
update begins, finish it instead. Reconnect and select a library before syncing
restored records. A changed journal or unrecognized file generation remains halted.
Restoration refuses unauthenticated vaults and unrelated occupants of reserved copy identifiers;
it never applies an ordinary-only subset of a secure restoration. Conflicting
keywords require a separate review. Restoration history is bounded to eight receipts
and 128 KiB; encrypted file images share the existing 32-file/512-MiB budget, with
no automatic eviction. Pending restoration generations are also capped at eight;
capacity exhaustion preserves the existing queue. Restoring multiple saved generations
also uses this budget; a proposal that cannot fit changes no library files or keys.
For a finished entry, choose **Review Removal…** in Library Recovery History.
Review the affected libraries, saved keys and encrypted-file sizes, then authorize
with your computer login password. This permanently removes only that selected
saved copy. It can be the only copy of old keys or historical changes, so keep any
recovery material you still need first. Current library files, active keys and the
live sync journal stay unchanged. Pending key requests, unfinished restorations
and old capabilities without a validated terminal receipt cannot be removed.

Removal saves a small intent in Secret Service before replacing the archive or
deleting its authenticated encrypted files. After an interruption, choose
**Review and Finish…** with fresh local authentication. Other key/account operations
wait for completion. Empty archives keep their generation, so freeing the final
entry never resets stale-request protection. Unknown, replaced, linked or shared
recovery files are refused.

**Review Cleanup…** separately reviews unused encrypted recovery files that have
no reference in any validated saved history. The review shows file counts and
sizes and warns that they may contain the only historical copy; save anything
you still need first. Fresh computer authentication saves consent before deleting
the exact reviewed files. Current files, keys, the sync journal and saved history
remain unchanged. Files created after review stay for another review. Missing,
changed, linked or unknown-format files and unreadable history refuse a new
cleanup. After interruption, **Review and Finish…** resumes saved consent with
fresh authentication. The combined native GTK/keyring/PAM workflow still needs
live verification.

**Create New Cloud Library…** explicitly creates an
empty library in the displayed account and server. The worker saves its original
idempotency key in Secret Service before sending the request. **Resume Library
Creation** retrieves the same library after an interrupted request; **Open Created
Library** reuses its saved receipt without another creation request. The receipt
binds subsequent key setup to the same account, deployment, membership, dataset
and key epoch. Creation keeps local snippets and does not generate library keys
or a sync checkpoint. **Create Another Cloud Library…** creates a separate library
beside valid existing keys and checkpoint state. Confirmation names the connected
account/server and expires after two minutes; changes to the account session,
keys or retained creation history require a fresh confirmation. Previous intents
and receipts remain in Secret Service, bounded to eight entries and 64 KiB without
automatic eviction. Resume an unfinished request before creating another in the
same account. New key setup and the reviewed library switch remain separate actions;
creation alone preserves current local records and the synchronization checkpoint.

The native creation workflow passes with a real private Secret Service keyring
and certificate-verified loopback HTTPS. Cancel and actual focus loss send no
creation request. If the server creates the library but closes TLS before its
response, a fresh account-window worker resumes the saved request with the same
idempotency key. **Open Created Library** sends no additional creation request;
key setup and synchronization still require separate actions. Creating a second
library preserves the first library's exact keys and encrypted sync checkpoint,
retains both receipts, and requires explicit switch review after reopening.
The worker now refreshes **Create Another Cloud Library…** availability when
a library is selected; interrupted requests and pending key transitions still
prevent new creation.

The separate **Review Library Switch…** workflow also passes native acceptance.
First keys for an empty target stay separate until review and fresh computer-password
authorization. Cancel, focus loss and an incorrect password preserve the active
library. A completed switch keeps local records, resets the target sync checkpoint
and retains the original library in protected recovery history. Only explicit
**Sync Now** uploads records under the target key. Reopening reconnects to the
selected library; switching back uses its saved original key without new key setup.
Ordinary saved-history restoration also passes native acceptance. The saved and
current libraries appear separately in review. Cancel, focus loss, incorrect
computer-password authorization and a stale local edit preserve current files
and keys. Fresh authorization restores the selected fields, keeps the current
version as a disabled copy and retains unrelated records. Current cloud CAS/feed
facts stay intact. A new worker reconnects explicitly before encrypted sync;
the preserved copy is sent before the restored source. Same-vault protected
restoration also passes fresh vault passphrase/recovery verification followed by
separate computer-password authorization. The whole ordinary/protected selection
is restored; both current versions survive as disabled copies, while unrelated
ordinary/protected records, vault wraps and active keys stay exact. A new worker
requires explicit reconnect and fresh vault verification before encrypted sync.
Simulated write interruptions in same-vault restoration also pass native checks.
A fresh window can cancel before the primary update starts, retaining later local
edits, or finish after partial ordinary/vault writes using the exact already
approved encrypted images. Keep Current State, wrong PAM password and focus loss
preserve pending state. Each final action needs fresh purpose-bound PAM; local
completion makes no HTTP request while the fixture server refuses requests.
Fresh reconnect and vault verification remain required before encrypted sync.
These cases simulate I/O errors at durable write boundaries; actual process
termination and power-loss acceptance remain separate.
Restoration from a retained previous vault also passes native acceptance. The
saved and current vaults have independently wrapped, different roots. Separate
current/source passphrase or recovery-key verification precedes fresh PAM consent;
current-only verification refuses the whole ordinary/protected selection. Missing
current vault metadata also refuses before credential review or a receipt. The
saved body is re-encrypted under the current root, current versions and unrelated
records survive, and current wraps/future metadata and keys remain exact. OpenSSL
checks actual output before and after fresh-worker reconnect and encrypted sync;
protected packets carry the current vaultKID. Multiple-source/external-file vault
restoration and interrupted switching remain separate checks.

**Library Creation Receipts** in Library Recovery History shows the retained
requests and completed receipts without reading account credentials. Use
**Review Removal…** to discard a completed receipt for a separate library with
fresh computer-password authorization. This frees one of the eight history slots;
the remote library and its records are kept. The receipt for the currently installed
library, uncertain creation requests, and receipts supporting unfinished pairing
or first-key setup remain protected. The removal also checks that the remaining
history still admits the current library. Unknown old formats stay retained and
are shown as unreadable. Interrupted removal uses the same **Review and Finish…**
flow. A final removal keeps an empty document and its generation, so creating
another library continues the existing sequence.

For an existing Snippets Cloud library, **Pair This Computer with a Trusted
Device** creates or resumes its retained invitation. On the trusted device, choose
**Add device**, scan the QR or paste the copied public invitation, and approve only
if both devices show the same confirmation code. The invitation contains no
library key, private key or recovery code. Approval is checked while this window
is active on an unlocked desktop, with at least two seconds between checks.
**Check Approval** retries after a network error. Expiry, closing/backgrounding,
desktop lock and failed persistence stop new automatic checks; the private draft and
any received envelope stay in the worker or keyring. A lost creation response
requires **Cancel Invitation** before creating another; it is never automatically
reposted. **Finish Key Installation** resumes a durably received envelope, even
after the invitation expires. Such an envelope cannot be discarded by cancellation.
No library key is installed until encryption, server authority and scope checks pass.

To approve another device from Linux, paste its public invitation into **Public
invitation from the new device**, then choose **Review Device Invitation**. Check
that the confirmation code matches on both devices, select the matching-code
checkbox, and choose **Authorize Device Approval…**. A fresh computer-login-password
dialog authorizes that exact retained operation. Writers and owners can approve;
readers cannot. Closing/backgrounding or locking the desktop clears the local
authorization and checkbox. Resume requires another review and fresh authorization.

**Replace Recovery Code…** prepares a new offline recovery capability for the
existing library key. Only the owner can authorize replacement. The old offline
copy no longer opens the current recovery envelope; the library key and snippets
are kept. After success, use **Show Pending Recovery Code…** and save/confirm a
new offline copy. Replacement does not revoke a device that already holds the
library key.

An interrupted operation remains in the keyring. **Check Saved Result** reconciles
a recovery replacement against its exact remote envelope, or completes a saved
acknowledgement. **Review and Authorize Retained Operation** retries the same saved
signature while it is valid, with fresh local authorization. A redacted approved
status alone cannot confirm a lost device-approval response; after its proof expires,
the operation requires account review. **Cancel Unsent Operation** is available
only before a signature is retained. Durably saved candidates and signatures are
reused across restart, including when a write succeeded but its receipt was lost.

After the library key is ready, **Sync Now** receives cloud changes, sends local
changes, then checks the cloud again after uploads. It resumes a retained request
or reply before fetching another page and finishes an incomplete snapshot before
preparing new uploads. Each action allows four receive steps and four send steps;
larger queues ask you to choose Sync Now again. A completion message requires both
directions to be clear and checks the current local files, account and cloud feed.
Read-only libraries keep local edits without uploading them. A server retry delay
does not stop receiving new cloud changes. Automatic mode stays off until explicitly enabled.

**Receive Cloud Changes** separately downloads and merges up
to four pages per action. If more pages remain, choose it again. A saved page
resumes before requesting another; duplicate record generations retain server
order. Changes stay queued when a local deletion, cloud deletion, vault conflict
or account boundary needs review. Missing records in a completed cloud snapshot
halt receiving and preserve local records.

If the complete snapshot omitted previously known records, **Review Missing Cloud
Records…** shows the number of missing records and local records to keep. **Keep
Records and Resume** keeps local snippets, pending edits and saved conflict copies,
then requires **Sync Now** or **Receive Cloud Changes** to read a fresh snapshot before sending.
The confirmation checks that the reviewed local files, saved checkpoint, cloud
feed, account session and key epoch still match. Changes during the dialog require
another review. Cancelling keeps the original halt. This action cannot authorize
a local deletion or change the account/library key; those need their own recovery.

**Review Deletions…** reviews one missing local record, queued cloud deletion or
pending deletion at a time. **Confirm Deletion** saves permission for that exact
record version; **Restore Retained Version** or **Keep Local Version** restores
the same identifier as a new local edit. Cancelling leaves the saved state intact.
Cloud deletions never provide local permission by themselves. The decision checks
the reviewed files, checkpoint, feed, account and key epoch again before saving.
Choose **Sync Now** to finish the saved receive page or send receipt and upload
the restored version.

A prepared, previously authorized deletion may already have reached the server.
Restoring keeps its original request until that outcome is resolved, while the
new local version stays intact and uploads afterward. Ordinary missing conflict
sources and copies can now be kept or deleted when every connected preservation
original is already saved. Originals finish in their existing order before later
copy deletions; deleting a source that was never offered does not reupload its
enabled body. Restoring a queued deletion cancels only its unsent tombstone; an
authorized request with an unknown outcome keeps its original bytes and CAS.
A compatible vault restores
the retained sealed body without revealing it or replacing key material. A secure
copy whose original was never created can now be reviewed from its retained
conflict metadata. Both choices ask for the matching vault and authenticate the
whole connected group before preparing that original. Existing originals and
requests retain their exact bytes; the chosen later version waits behind them.
An absent source can also recover missing originals.
The dialog lists how many originals will be restored and how many distinct held
source versions will become disabled copies. Both choices require the matching
vault; existing copy edits stay intact while their originals synchronize first.
For known current conflict evidence, the review also counts original versions to
preserve. It authenticates the selected source and its connected copies, including
edited or missing copies with further conflicts. Originals keep their saved
encrypted form, and copy edits stay separate while synchronization completes in
order. Missing whole library/vault files and unknown conflict versions require
separate recovery. A child's independent deletion needs its own confirmation;
this action cannot approve a mass deletion.

Restoring a protected conflict copy asks for the matching vault's passphrase or
recovery key. One bounded vault session verifies the latest sealed body and every
connected original in the current and queued generations. A valid later edit
cannot bypass a damaged original. Originals keep their own nonce and existing
transmissions; the restored version waits behind them. The encrypted redo retains
the complete prepared files, so finishing an interrupted update needs no retained
vault key. Cancelling the password dialog clears its field and keeps the review
unchanged. This native password workflow is compiled but still needs a live
graphical check.

Use **Send Local Changes** to send up to four batches of ten records. A prepared
batch retains its exact encrypted bytes and original CAS versions across restart,
including when a newer local edit arrives. Complete server replies are saved
before local acknowledgement or conflict apply, so accepted records survive
partial failure. A server's retry delay is retained across restart. Body conflicts
preserve a disabled copy before the source and later copy edits can be sent.
An edited remote copy cannot substitute for the immutable preservation receipt.

Account/library/key changes use an explicitly reviewed handover that retains the
previous protected state. Current v1 conflict recovery preserves immutable originals
and later edits, including independently reviewed missing/deleted copies. Unknown
variant versions, damaged originals or ambiguous body ownership still refuse recovery.
Missing primary files stop sending; they never become cloud deletions. Receiving does not send this
computer's local changes, and a connected account or verified key does not mean
snippets have synchronized. Ordinary automatic receiving/sending now passes the
combined live GTK, private native keyring and verified HTTPS workflow. Explicit
Sync Now/Receive/Send controls and fresh passphrase/recovery-key cycles also pass
combined live acceptance. Retained secure-conflict preservation, protected-copy
restoration and basic cloud deletion Cancel/Keep/Delete also pass. Missing-snapshot
Cancel/focus/stale-primary refusal and explicit resumption now pass for acknowledged
ordinary and protected records, with preserved nonce and fresh create CAS. Flat
current secure v1 source and acknowledged-copy deletion repair also pass with fresh
credentials, cancellation refusal and exact CAS ordering. Nested physical and
journal-only C1 source Keep/Delete also pass with retained child seals and
separate originals. Prior-confirmed cloud-child Keep/Delete before parent
Keep/Delete also passes all four native combinations with actual saved CAS.
Unknown pending raw-child Keep/Delete before parent Keep now passes as well.
Local-absence secure source Keep/Delete also retains unrelated ambiguous packets
through authenticated review and exact ciphertext/CAS retry. Switch-candidate pairing
now passes; other interrupted switching and mixed-vault,
external-file/multiple-source vault restoration and actual process termination
during restoration remain under live acceptance. Native recipient pairing and signed approval/recovery
replacement now pass, including retained-request restart. The native
interrupted-startup recovery fixture passes with temporary
data; full file-dialog
and Apple-app backup round trips remain separate.

**Show Pending Recovery Code…** opens a fresh computer-login-password dialog.
The request is bound to this library and retained presentation. QR/code pixels
appear only while its single-use lease is valid; backgrounding, hiding, cancellation,
desktop lock, or either authorization deadline revoke it. The complete secret
does not enter GTK text widgets, accessibility text, the clipboard or a disk image.
Owned Rust buffers are erased, while GTK password fields, native encoder/font
allocations and compositor surfaces are outside that guarantee. Record an offline
copy, check **I saved an offline copy**, and enter the last eight characters.
Confirmation hides the presentation before the worker verifies and retires it.
A mismatch requires fresh authorization before redisplay; an ambiguous write is
resolved from durable state. The live native check now verifies cancellation, an
incorrect password, fresh private-policy PAM authorization, actual focus-loss
revocation and fresh reauthorization followed by recovery-code confirmation.
Reconnect through a new worker and sign-out preserve the same library key in the
private native keyring. Ordinary manual/automatic synchronization, fresh vault
synchronization and reviewed two-library switching also pass combined live checks.
Two native installations now pass pairing and trusted-device approval, including
a lost HTTPS reply and exact signed-request replay after restart. Recovery-code
replacement also passes: after a lost acknowledgement, a new worker either verifies
the exact retained envelope or obtains fresh authorization to resend the original
proof. The old code cannot open the new envelope; the new code restores the same
library key and synchronized record. Ordinary saved-history restoration now also
passes, including current-version preservation and explicit reconnect/sync.
Same-vault protected restoration also passes vault passphrase/recovery review,
separate fresh PAM, both current-version copies and unrelated-record retention.
Simulated interrupted same-vault restoration also passes fresh-worker offline
cancellation/completion and exact frozen-image checks. Candidate pairing for
switching, interrupted switching, external-file/multiple-source vault restoration
and actual process termination during restoration remain under acceptance.
Retained foreign-vault restoration now passes separate source/current verification,
fresh PAM, exact current wraps and independent OpenSSL checks across encrypted sync.

## Secure Snippets

Open **Secure Snippets…** from the menu, or select a catalogue row with a lock.
Set up a passphrase and record the recovery key offline. An existing vault from
the Apple app can use its recovery key; **Change Passphrase…** can add a Linux
passphrase without changing the root key, bodies, or recovery key. Ordinary
sharing exports do not contain vault bodies.

Use **Encrypted Backup…** in the library menu to export the saved ordinary and
secure library as a password-protected `.snippetsbackup` file. Choose a destination
outside the app's data directory and a backup password of at least 12 characters.
Including secure records also requires fresh authentication with the current
vault's passphrase or recovery key. The whole payload, including names, keywords
and tags, is encrypted. Secure bodies keep their original seals; local sync
receipts, account credentials, sync state and unsaved drafts are excluded.
Cancellation, backgrounding, desktop lock, expiry or changed saved files prevent
publication. The output file uses mode `0600` and is replaced atomically.
The format follows the Mac/iOS schema-1 backup; an independent OpenSSL decoder
checks Rust exports, and Rust opens an independent reference backup. Restoration
uses **Restore Encrypted Backup…**. Enter the backup password, review the record
counts and confirm the import. Ordinary entries match by ID, then normalized
keyword; a keyword match keeps the local ID and creation date. Secure entries
match by ID and require a compatible vault and matching key. Authenticate the
current vault again when importing into it. For a new vault, choose a local
passphrase of at least 12 characters; its original recovery key stays valid.
Other entries, existing vault unlock methods
and unsaved secure drafts are preserved. The live Omarchy acceptance uses the real
desktop file portal, fresh credential dialogs, independent OpenSSL verification,
matching-vault restoration and new-vault restoration. Chooser/password cancellation,
focus loss, wrong vault authentication, wrong backup passwords and cancelled import
confirmation leave the saved files unchanged. Portal completion waits briefly for
the parent activation event before requesting credentials; it does not force focus.
Live cross-platform application tests have not run.

An interrupted import hides the library until **Resume Backup Import** finishes
the saved changes using the same backup password. Both primary files have an
encrypted redo journal under the app's private Backups directory; the recovered
vault key is never stored separately. Cancellation before publication leaves
both files unchanged. After publication it retains the journal for recovery.
Unexpected external file changes stop recovery without overwriting them.

Secure metadata stays searchable while locked. Unlock, choose an entry, and use
**Reveal to Edit** for protected content. Ctrl+S saves, Ctrl+N creates a secure
draft, and Ctrl+L locks the vault, including while a credential dialog is open.
Lock revokes the pending request; submitting its old fields cannot unlock or
change the vault. Secure entries use explicit Save; they do not
use the ordinary editor's autosave or undo. Closing hides and locks the secure
window, retaining the encrypted draft until it is saved or explicitly discarded.
Quit asks you to unlock and save or discard a remaining draft before exiting.

For a saved legacy entry without a content hash, choose **Repair Legacy Entry…**
with no unsaved changes. Enter its vault passphrase or recovery key again. The
app verifies the encrypted body and any preserved conflict originals, then saves
the missing hash with a new logical revision. Other JSON values and the encrypted
body are preserved. This action also works while the vault is locked and does
not unlock the editor. Cancellation, focus loss, desktop lock, expiry or changed
files stop publication; an uncertain save requires rereading the entry. Existing
invalid hashes or vault stamps are refused. The native dialog still needs live
display verification.

The body editor retains ciphertext rather than a GTK text buffer. Use Shift with
arrows, Home/End or Ctrl+Home/End to select; Ctrl+A selects the whole body. Click
to place the caret, Shift-click to extend a selection, or drag inside the editor.
Typing, Backspace or Delete replaces/removes the selected range. Ctrl+Left/Right
moves by words; Ctrl+Backspace/Delete removes words. Character movement and
deletion keep combining characters, emoji sequences, flags and CRLF together.
Up/Down keeps the preferred character column across short logical lines. Newlines
and tabs can be typed; Shift+Tab leaves the editor and Escape hides content.

Selection stores only offsets and does not mark the draft dirty or change its
ciphertext. Body changes are encrypted before they become retained editor state;
Save remains explicit. Ctrl+Z undoes a body edit; Ctrl+Shift+Z or Ctrl+Y redoes it.
The toolbar also has body Undo/Redo buttons. History keeps at most 64 encrypted
versions and 8 MiB of body ciphertext in memory. It survives hiding and locking,
but using it requires the same unlocked, revealed draft. Save keeps the history;
undoing after Save creates an unsaved body change without reverting current
metadata or its saved-record conflict check. A new body edit discards Redo;
navigation and unchanged edits keep it. Discard, loading another entry and
completed previous-vault recovery clear history. A verified passphrase change
preserves it. Ctrl+V or the Paste toolbar button reads plain clipboard text into
the revealed editor. Reading is limited to two seconds and 256 KiB; hiding,
leaving the editor, changing the selection or draft, Save, vault lock or an
observed desktop lock cancels a pending request. An empty clipboard leaves the
body and selection intact. A paste replaces the selection as one encrypted Undo
step and remains unsaved until Save. No clipboard output, external text drag,
plaintext undo history or body extraction through accessibility is provided. Accessible instructions
describe the keyboard controls without exposing the body. Revealed pixels can
still be captured by the desktop, and input methods/font libraries are outside
Rust's memory-erasure guarantees. Rendering and pointer hit testing use transient
Pango layouts from the same widget context; owned Rust buffers are zeroed.
The new editing core passes isolated checks; actual keyboard, mouse, font scaling
and assistive-technology behavior still need live verification.

Sessions expire after five idle minutes or thirty minutes overall, including
computer sleep. Backgrounding hides revealed content. A desktop lock, unavailable
lock-state observation, explicit vault lock, or changed vault identity drops the
session key. Authentication and password derivation run off the GTK thread;
cancelled, backgrounded, or stale requests cannot unlock the owner later.
Secure operations currently require an observable, unlocked Hyprland session.

`Vault/vault.json` uses the schema-1 AES-256-GCM envelopes, HKDF/HMAC key hierarchy,
600,000-iteration PBKDF2 passphrase wrap, Crockford recovery grammar, and ISO dates
specified by the Swift core. The independent OpenSSL fixture tests the wire
grammar; execution against the actual Swift implementation remains unverified
on this Linux machine. Vault files use `0600`, the vault directory `0700`.

If another operation replaces the vault, the previous draft stays encrypted and
refuses edits under the new identity. Unlock the current vault and choose
**Recover Previous Draft…**. Supply a passphrase or recovery key for each vault.
Recovery creates a new encrypted draft in the current vault without changing saved
entries. Review its metadata and choose **Save**; change a duplicate keyword first.
Cancellation, focus loss, desktop lock, expiry or changed files leave the previous
draft intact. Quit waits for the recovery worker to release its credentials.
This native dialog is compiled and its core checks pass; live display verification
remains open. Drafts are retained in memory, not across application restarts.

Archived records from a different vault use the separately authenticated
saved-history restoration flow described above.

### Inline expansion

Install with `scripts/install-linux.sh`, then restart Fcitx once to load the
Snippets addon. Open **Inline Expansion…** and choose **Enable Expansion…**.
Its Cancel-default confirmation also enables the caret suggestion panel.
Expansion remains disabled by default and belongs to this library. Existing
exact-only consent is not silently upgraded; **Enable Suggestions…** is available
for those installations. **Disable Expansion** revokes the worker immediately.

Type `\` in a public text field to see up to eight ordinary names and keywords.
Names and keywords use fuzzy matching and a frozen local usage ranking. Use ↑/↓
or Ctrl+N/P to move, Return/Tab to insert, Shift+Tab to move backward, and Escape
to dismiss while retaining the literal query. Typing an enabled unique exact
keyword expands automatically; duplicate keywords and enabled longer prefixes
prevent that automatic expansion. Secure snippets use the authenticated picker.

The small native Fcitx addon owns only the backslash-started preedit. The Rust
worker owns consent, ordinary-library access, matching, current-record validation,
placeholder resolution and usage accounting. Fcitx places the native candidate
panel at the caret and commits directly to its receiving input context without
activating a Snippets window or changing the clipboard. Snippets does not claim
a second input-method seat, need surrounding-text updates, or forward a general
keyboard stream to the app. The addon excludes password/sensitive/disabled input
contexts and resets its query on focus/reset/protected-capability changes. Public
capability updates preserve its current query and selected row. Snippets windows
are excluded by the receiving-window guard.

IPC uses a bounded, private runtime socket with reciprocal process authentication:
the app accepts the installed Fcitx executable, and the addon accepts the exact GUI
next to its installed library. The transport does not log or persist
queries, bodies or surrounding text. Successful selections follow existing
**Suggestion Learning** settings: enabled prefix memory may retain a bounded short
search prefix and the chosen ordinary record in private local files. Candidate
rows contain only ordinary metadata.
Selection rereads the saved record, refuses modified/removed choices and checks
consent, observable session state and the original receiving window before delivery.
`{clipboard}` reads a plain-text selection only when requested, with a short deadline;
resolved output is capped at 256 KiB. Failed/interrupted requests are not retried.

Current temporary-prefix and actual user-prefix live checks use the installed
GUI/addon, private D-Bus/public libraries and native virtual-keyboard events.
With the stock Fcitx service continuously running, exact expansion and visible
partial-query panels with Return insertion pass in GTK, default Wayland Chromium
and Ghostty. The separate two-record arrow-selection case preserves GTK receiver
focus. Saved shortcuts and the installed clipboard-history UI also pass on this
same new executable. The earlier
direct Wayland backend and its protocol/echo tests remain as a fallback on systems
without Fcitx; those historical checks do not qualify the new Fcitx backend.
The normal primary is running with expansion and suggestions explicitly enabled
through its native dialog. User library data was not used as a test fixture.
Full modifier press/character/release sequences now preserve the panel: Ctrl+N/P
and Shift+Tab select the correct public record in the installed GTK receiver.
The native state regression covers eight modifier sequences and fails against the
previous handler. Fcitx-normalized Ctrl key comparisons are used on both sides.
Physical input and normal-session qualification remain open. On the previous
qualified addon, two of three empty-profile browser launches expand and one
retains the literal keyword; this first-field failure remains a core blocker.
No delay, retry or warning suppression is claimed as a repair.

The latest capability-change candidate adds six real Fcitx state checks. Changing
Preedit, ClientSideInputPanel or SurroundingText support in the same focused public
context preserves the query, candidate rows and selection; Password, Sensitive and
Disable transitions still wipe them without committing text. The previous handler
fails the public Preedit case. All 42 inline tests and desktop/headless all-target
Clippy pass. After unlocking, the installed capability-change addon passes exact
expansion and visible partial-query selection in GTK, default Wayland Chromium
and Ghostty, full Ctrl+N/P and Shift+Tab navigation, saved global shortcuts and
accessible history selection/Copy/opt-out/restart/Clear. Three cold Chromium first
fields also finish with the exact body and no composition within the original
eight-second deadline. This does not establish the cause or repair of the earlier
intermittent failure. The normal primary and existing consent are restored.
Fcitx supplies the panel's Linux appearance; these checks establish the macOS
backslash/caret/keyboard interaction, not visual equivalence to its glass panel.

A generation-scoped browser observer now records actual composition state and
requires final expansion within the original eight-second deadline. On the last
unmodified qualified addon, its first field retained only the 12 keyword letters
and lost the backslash. This confirms an unresolved input failure beyond the
old premature literal-match predicate. Diagnostic addon runs complete three fields,
but those altered binaries and service restarts do not qualify a repair. The
current user-test archive and candidate receipts distinguish these states.

The panel also preserves a keyboard-selected snippet when further typing updates
the results, following the Mac reference. A changed rank, name or keyword does
not change the choice while that record remains offered. Without a deliberate
selection, the best-ranked first result remains selected; removing the choice or
entering a private field resets it. The installed previous version inserts the
wrong public fixture after Ctrl+N and another character; the corrected version
inserts the intended 45-byte fixture with receiver focus preserved. Version 2 of
the authenticated local row protocol carries ordinary record identity only for
this selection, without logging or addon persistence. Old row-protocol peers are
rejected before taking input. Six native selection/protocol checks and the
previous modifier/capability checks pass; 43 inline tests pass with four existing
live cases ignored in this unit filter. No observation delay changed.

An isolated Mac-style renderer prototype now draws its own rounded caret panel
through the existing Fcitx connection and per-context UI callback. The unchanged
installed GUI supplies real library rows; Return inserts the exact body in GTK,
default Wayland Chromium and Ghostty without changing receiver focus. A discovered
2x-display blur is addressed in the prototype by rendering a matching pixel
buffer, with unchanged logical pane dimensions. Source, screenshots and numeric
scale observations have their own prototype receipts. These results do not
qualify a product renderer: the installed addon and user-test archive remain
`2dd9d6b`. Product lifecycle/fallback, palette, tags, match highlights, wrapped
titles, pointer selection and Ghostty caret overlap remain panel work. The
earlier cold first-field failure still has no confirmed repair. No global theme
or compositor settings change is required by the demonstrated rendering path.

That rendering path is now part of the product addon. A 320-point pane with an
18-point radius contains 46/62-point rows, 12-point selection pills, 13-point
titles and 11-point monospaced keywords. Two tag chips and a fitting `+N` chip
yield to the keyword. UTF-8 match ranges come from the same Rust matching owner.
The local row protocol is version 3; old peers fail before taking input.
Palette values are bounded RGB data, and the addon receives no body until the
existing selected insertion request. The Fcitx 5.1.22 wrapper is used only when
both SDK and runtime match; other versions/frontends use the normal Fcitx panel.
The exact interface sources, provenance and LGPL license accompany installation.

The installed product passes the existing GTK, Chromium and Ghostty expansion,
panel, full-modifier navigation, retained-selection, global shortcut and accessible
clipboard-history checks. Panel screenshots include actual wrapped names, tags,
overflow count and tinted matches from a private library. A virtual pointer click
on the second row also inserts its exact body without changing receiver focus.
Physical pointer input remains unverified; the older independent GTK button
failure and history's accessible-selection qualification keep their own limits.
The first visual-fixture attempt expected 45 bytes while selecting a different
28-byte record; its screenshot and terminal count establish correct insertion of
the selected record. Correcting the private fixture's ranking makes the existing
receiver check coherent; product code, waits and deadlines are unchanged.
The qualified earlier renderer overlaps Ghostty's first input line when its receiving toolkit supplies no caret geometry.
Compositor glass-material equivalence and the earlier cold first-field repair
remain unproven. Cloud and GTK race work stays deferred.

The Omarchy renderer now follows the Mac mouse fallback when the compositor's
caret rectangle has zero width and height. GTK and Chromium continue using the
input-method popup at their reported caret. Ghostty instead uses a Snippets-owned
layer surface with keyboard interactivity disabled. The pointer is captured once
for that presentation, and filtering cannot make the panel follow subsequent
mouse movement. The panel is clamped to the pointer's output and its reserved
edges; rotated and fractionally scaled output geometry is handled explicitly.
This is a missing-geometry fallback, not a precise Ghostty caret measurement.

Two read-only Omarchy IPC requests share a 75 ms deadline, run only for missing
geometry, and retain no compositor reply beyond the current presentation. There
is no command subprocess, input replay, added observation delay, global theme
change or compositor rule. If the output or protocol is unavailable, the normal
Fcitx panel remains the fallback. The layer is configured through Wayland events
and releases its role on focus loss, reset or connection shutdown. Four native
placement checks cover screen-edge clamping, changing panel height, rotation,
fractional scale and malformed coordinates. The protocol XML, licenses and
source hashes accompany the installer and test archive.

The existing private Ghostty receiver confirms the first line remains visible,
the captured panel origin stays unchanged after moving the mouse and filtering,
and keyboard acceptance delivers the exact 45-byte library body while preserving
receiver focus. A targeted virtual pointer click on that fallback layer does
not deliver the body; its cause and physical-pointer behavior remain unconfirmed.
The older caret-popup pointer result does not qualify this different role.
The direct-expansion receiver gate reproduces the earlier first-field Chromium
failure on this candidate: 12 keyword letters remain without the backslash or
expanded body, while field focus is preserved. The candidate therefore fails
core qualification; the installed addon is restored to `8143b06`. A passing
panel selection case is not evidence that exact inline expansion is repaired.
Full glass-material equivalence also remains unproven. These are qualification limits, not successes inferred from a
longer wait or a service restart.

An external Fcitx observer reproduces that 12-byte Chromium failure while the
candidate addon remains byte-for-byte unchanged. It sees FocusOut/FocusIn for
the same ephemeral context before the first observed letter. Because this
public watcher runs after Snippets can filter a key, those observations do not
prove where the backslash disappeared or whether Snippets owned its preedit.
Later observations also cover input-method activation, UI/preedit updates and
bounded commit lengths; their passing runs do not establish a repair. With the
Snippets addon absent, three cold fields retain the complete 13-byte literal
keyword. That control is too small to rule out an intermittent lower-layer
failure. Existing deadlines and input sequences are preserved. Numeric evidence
is retained under `target/live-omarchy-acceptance/core-functionality/first-field-external-observer/`.
Those checks restored the `8143b06` addon and retained its user-test archive.
The surface-interoperability update below supersedes that installed renderer;
the same five finite acceptance groups remain open.

On 2026-10-06, the unchanged mouse-fallback addon reproduces a Fcitx `SIGSEGV`
when the pointer enters its panel. The service automatically restarts, so a later
active-service check did not expose the failure. The core's first two frames are
inside `libclassicui`; their function names remain unsymbolized. Fcitx's pointer
wrapper treats surface proxy user data as its `WlSurface` object, and ClassicUI
then reads that wrapper's window data. Snippets previously supplied a native
`Window*`. Both caret and layer surfaces now carry the pinned Fcitx wrapper with
null ClassicUI window data. Local wrapper functions remain hidden, and the same
5.1.22 SDK/runtime checks gate their use. No additional input-method seat, grab,
key replay or observation delay is introduced.

A separate remaining failed click is classified by closed numeric events:
the button arrives, but both pointer coordinates are negative and row hit testing
returns -1. The short-lived test pointer makes the seat capability disappear;
Hyprland initializes a newly requested pointer under an existing surface at
(-1,-1). Keeping the owned test device alive before Fcitx startup and throughout
the test gives valid coordinates without adding a sleep. Invalid coordinates
remain rejected in the application. This input-fixture correction is distinct
from the actual surface interoperability repair.

The production Release addon then passes all nine existing live stages, including
Ghostty fallback click insertion, three receiver expansions, full modifier
navigation, retained selection, global actions, history and three cold browser
fields. One Fcitx process survives the complete sequence with no service restart.
The earlier caret-popup click and independent GTK button also pass with the held
device. All 43 serial inline tests, desktop/headless all-target Clippy, formatting,
installer syntax and the Release build pass. Numeric evidence is retained in
`target/live-omarchy-acceptance/core-functionality/surface-interop/`.
The earlier lost-backslash Chromium failure still has no confirmed cause or
repair; passing cold fields do not close it. Physical input, a fresh normal
compositor session and full glass-material equivalence remain unverified. The
user-test build is a candidate; cloud and chooser race work remains deferred.

Physical keyboard acceptance confirms the Chromium first-field fixture expands
to its exact 45-byte body without Return. Saved Open and Picker/Return actions
also pass with physical keys, preserving target focus and the clipboard lease.
The physical Capture action exposed a separate defect: while another application
holds keyboard focus, GTK's cached clipboard offer can produce an empty draft.
An existing-window control reproduces the empty body; the same selection is
captured correctly when Snippets is focused.

Explicit Capture now uses the existing read-only ext-data-control transport in
a short-lived worker instead of the GTK clipboard offer. It reads only the current
selection, checks the active Hyprland peer and unlocked session, retains the same
256 KiB UTF-8/no-NUL limit and a two-second deadline, and writes no clipboard data
or history. Empty selections show the existing hint without creating a draft.
The focused/background comparison and the physical Capture hotkey now preserve
the exact fixture body. Private native protocol tests cover an initial selection
without any keyboard focus, empty input and revocation. Earlier first-field
failure causality and a fresh normal compositor session remain open.

### Insert saved secure text

Open the picker from the destination application and select an enabled secure
entry. Its vault window retains the original destination for two minutes and
offers **Insert into Original Window…**. Save or discard an unsaved draft first.
Review the destination application and supply a fresh vault passphrase or
recovery key for this insertion, even if the editor is already unlocked.
This authentication does not unlock or extend the editor's reveal session.
If another library operation holds the process lock, insertion returns
immediately; retry after that operation finishes.

The backend types Unicode through the compositor's native virtual keyboard.
It writes no clipboard selection, sends no body in subprocess arguments, and
uses anonymous sealed memory descriptors for XKB maps. `{clipboard}` is read
only when requested by the saved template; its text transfer is limited to
256 KiB and two seconds. Placeholder resolution is one pass, and the resolved
text must also fit 256 KiB. CRLF and CR become one Return; tabs become Tab.
Other control characters are rejected before keyboard input. Returns and tabs
can submit forms, execute commands or move focus in the receiving application.

Keep the original application focused while input is sent. Cancellation, a
desktop lock, unavailable lock observation, a changed file or an expired request
stops further input when detected. The authentication and destination expire
after two minutes, including sleep. Interrupted delivery may leave a prefix;
there is no clipboard fallback or automatic retry. Compositor synchronization
does not prove that the receiving application accepted the intended text.

Wayland virtual-keyboard input follows keyboard focus. Destination checks cannot
make focus and delivery atomic, so a focus race can route a prefix into a newly
focused window. Saved-file checks also do not claim protection against every
hostile ancestor-path change or noncooperating concurrent writer. These limits
must be included in live desktop validation. Legacy entries without an
authenticated content hash refuse direct insertion until **Repair Legacy Entry…**
verifies and saves that metadata with fresh vault authentication.

The native UI and backend compile; core, native XKB decoding, cancellation and
bounded in-memory GIO-stream checks pass. Live credential-dialog and receiving
application verification remain open. The private Wayland-server fixture builds
but cannot create its test client in the current restricted environment (`EPERM`).

## Local clipboard history

Open **Clipboard History** from the app menu, Ctrl+Shift+H, the launcher action,
or `snippets --clipboard-history`. Collection starts only after explicit consent
in its window; it is off by default. An empty, disabled history does not read
the clipboard or initialize a keyring namespace, key, preferences or history image.

The native read-only Wayland data-control client watches future text copies
without requiring Snippets to have keyboard focus. It ignores the initial offer
on every connection and reconnect, including after an observed desktop lock.
Primary selection, file copies, sensitivity markers and Snippets-generated
clipboard providers are excluded before requesting text. Default password-manager
classes and custom **App Exclusions** use the foreground Hyprland window as a
best-effort hint; they cannot identify every source or secret. A locked,
unobservable or changed session cancels acquisition and admission to storage.

`ClipboardHistory/history.bin` uses AES-256-GCM and a separate local
`clipboard-history-key-v1` Secret Service slot. It is excluded from library sync,
snippet sharing and encrypted backups. Retention is seven days, at most 1,000
entries, 256 KiB per UTF-8 copy and 32 MiB of text in total. Exact duplicates move
to the top; whitespace, Unicode byte sequences and literal placeholders survive.
Search matches all terms without case or diacritics. View, delete, copy literal
text, or explicitly open an ordinary snippet editor; saved ordinary snippets can
sync. Focus loss, lock and quit discard the view and cancel dialogs.

Turning collection off keeps retained entries. **Clear History** needs no
decryption key and also deletes a damaged or oversized private regular image.
Missing keys are never silently replaced. Unreadable or concurrently changed
preferences require **Reset History Settings**, which turns collection off while
preserving ciphertext. Exit waits for acquisition and the serial storage worker.

Storage, cancellation, privacy, private libwayland-server protocol and disabled
GTK controls pass. Live unlocked Omarchy acceptance also exercises the production
data-control/storage workers and mapped GTK controls against an independent C/GTK
clipboard owner, with a private D-Bus, GNOME Keyring and XDG data root. Cancelled
consent creates no history key; collection ignores the initial selection, continues
after closing the view, skips sensitivity/internal markers and stops after opt-out.
The view decrypts the retained copy, searches and copies it without recapture.
Deletion and clear require their own default-Cancel confirmations and preserve the
current clipboard. The image has private permissions and contains no fixture
plaintext. This fixture disables accessibility services on its private test bus;
accessibility and physical input remain separate acceptance work. Other Wayland
compositors require ext-data-control-v1 and the current Hyprland session/source checks.

## Local suggestion learning

The native picker ranks matches by relevance, keyword match and pins before
remembered choices and frequency. Its learning snapshot is frozen when it opens;
using a snippet does not move rows during that picker session. The library list
keeps its usual order. Short prefix collisions, such as `re` matching `reply`
and `refund`, learn from deliberate picker choices. Prefixes are folded and must
fit within eight graphemes; longer queries are rejected rather than truncated.

Successful copies contribute 0.25; accepted paste and completed inline expansion
contribute 1.0. Usage decays with a 14-day half-life. A single copy has no frequency
ranking effect. Native secure insertion records only its saved snippet identifier
after successful delivery, using the same fresh authentication as before.
Physical input and delivery to the intended receiving applications are tracked
separately in the bounded acceptance list below.

Open **Suggestion Learning…** in the main menu to control frequency ranking and
prefix memory separately, reset either history, or reset both. Both controls
default to on. Disabling frequency ranking keeps counting use. Disabling prefix
memory erases saved choices and stops collecting them. Changing either option or
confirming a reset closes a picker that retains an earlier learning snapshot.
Cancel preserves that picker and the history. Storage failures are shown in that
window; protected or unsupported files are preserved.

`Usage/usage.json` stores UUIDs, bounded weights, counts, times and short search
prefixes. It contains no snippet bodies, display names, tags, clipboard contents
or keys. `Usage/preferences.json` stores the two controls. This local plaintext
history uses mode `0600` inside a `0700` directory and is excluded from sync,
sharing export and encrypted backups. It never changes snippet timestamps or
Undo. A separate lock and atomic writes merge concurrent writers without summing
their common ancestor; reset markers prevent stale caches restoring cleared data.
Writes run on a worker with a five-second trailing delay and 60-second ceiling.
The desktop attempts a final flush on quit; optional learning cannot prevent quit.
The ordinary CLI never starts the learning worker or creates `Usage/`.
`SNIPPETS_USAGE_DISABLED=1` prevents usage reading, writing and all access to its
files, including settings and reset operations.

The complete mapped picker/settings cycle now passes with public learning
notifications, independent resets and a fresh worker. See
[native learning acceptance](#live-learning-picker-and-resets-2026-10-04).

## Desktop picker and appearance

`snippets --picker` captures the active Hyprland window before opening the picker.
Use ↑/↓ and Return, Ctrl+1…9, or Escape. Secure rows open their authenticated
workspace instead of copying a body. Targeted ordinary paste checks an unlocked
session and the captured window
address and process again before using the current Lua dispatcher API. Terminal
tags select Shift+Insert; other windows use Ctrl+V. A failed delivery keeps the
ordinary entry copied and explains the fallback. In-app Ctrl+K opens a copy picker.

The picker uses the ordinary system clipboard. Prior plain text is restored after
1.5 seconds if Snippets still owns the same clipboard provider. Newer copies win.
Image and rich-text formats are not preserved. An independent GTK receiving-field
check verifies ordinary delivery and clipboard restoration on Omarchy. Delivery
to other applications still depends on their paste handling.

The app rereads Omarchy's active XDG state `colors.toml` every two seconds. Colors
are validated before CSS generation; light/dark mode follows the palette. No theme
files or hooks are changed. Other desktops use standard libadwaita styling.

Closing the main window saves and follows **When Library Window Closes** in
Settings. By default it hides while the app remains available through the tray,
launcher and CLI; Ctrl+Q or `snippets --quit` saves and quits.

For a global shortcut on current Omarchy, choose an unused key after checking
`omarchy menu keybindings --print`, then add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + N", "Snippets", "snippets")
o.bind("SUPER + ALT + P", "Snippets picker", "snippets --picker")
```

Validate config edits with `hyprctl reload` and `hyprctl configerrors`.

## Keyboard commands

Open **Settings → Input & Clipboard → Global Keyboard Shortcuts** to register
native Hyprland actions for opening Snippets, opening its targeted paste picker
and capturing clipboard text. **Enable Global Shortcuts** is off by default and
stored only on this device. Snippets must be running; **Launch at Login** can
keep the owner available in the background.

Physical keys belong to the compositor. The window provides examples and an
explicit **Copy** button; choose unused keys after checking
`omarchy menu keybindings --print`, then add the adjusted lines to
`~/.config/hypr/bindings.lua`:

The Open example uses N because Omarchy already assigns Super+Alt+S to moving
a window to the scratchpad. Review your own assignments before adding any keys.

```lua
o.bind("SUPER + ALT + N", "Snippets", hl.dsp.global("com.khm.snippets.linux:open"))
o.bind("SUPER + ALT + P", "Snippets paste picker", hl.dsp.global("com.khm.snippets.linux:picker"))
o.bind("SUPER + ALT + C", "Snippets capture", hl.dsp.global("com.khm.snippets.linux:capture"))
```

Use these as an alternative to CLI bindings for the same keys. Reload Hyprland
and inspect `hyprctl configerrors`. The application does not edit those bindings
or assign the example keys automatically. **Desktop Connection** reports
registration separately from key assignment; **Retry Connection** retries after
a missing or restarted compositor, duplicate registration or connection error.
Other desktops can keep using the CLI bindings above.

The listener accepts only three fixed public actions and never grabs the keyboard
or reads surrounding text. A locked or unavailable desktop, an expired queued
call, disabled consent or Quit prevents activation. The picker captures its
receiving window before presentation and keeps the existing paste checks.
Independent private-wire and worker tests pass. The unrestricted Omarchy session
also verifies real compositor peer credentials, registration, native settings and
picker focus/paste. Temporary compositor key assignments also pass Open, Picker
with Return and Capture using native virtual-keyboard events. Their bindings are
removed after testing; saved user key assignments and physical keyboard input
remain separate checks.

| Shortcut | Action |
| --- | --- |
| Ctrl+N | New snippet |
| Ctrl+Shift+N | Capture clipboard |
| Ctrl+F | Search |
| Ctrl+S | Save |
| Ctrl+Return | Copy resolved content |
| Ctrl+K | Picker |
| Ctrl+Shift+H | Clipboard history |
| Ctrl+Alt+Z / Ctrl+Alt+Shift+Z | Undo / redo library change |
| Ctrl+Shift+I / Ctrl+Shift+E | Import / export |
| Ctrl+Q | Save and quit |

## CLI

Ordinary commands return JSON; errors use a nonzero exit status and safe stderr
messages. `reveal` returns raw UTF-8 bytes without an added newline.

```sh
snippets-cli add --keyword dashboard --name "Team dashboard" \
  --content 'https://example.com/dashboard' --tags work,links --pinned
snippets-cli search dashboard
snippets-cli list --tag work --enabled
snippets-cli get dashboard
snippets-cli update dashboard --tags work,daily --no-pinned
snippets-cli delete dashboard
snippets-cli import snippets-export.json
```

`--content -` reads bounded UTF-8 stdin. Mutations and `get` handle ordinary
entries only. `list` includes secure metadata with an empty `content`; `search`
returns `{"secure": BOOLEAN, "snippet": OBJECT}` rows. Secure bodies, wraps and
keys are absent from CLI output; secure keywords/IDs reject `get`, update and delete.

Secure creation and reveal go through the running desktop app:

```sh
snippets-cli secure-status
snippets-cli add --secure --keyword service-token --name "Service token" --prompt
snippets-cli add --secure --keyword private-note --content-file /path/to/private-note
snippets-cli reveal service-token
```

The native window identifies the verified CLI and its reported parent program,
defaults to **Deny**, and requires fresh vault passphrase or recovery-key
authentication after approval. An unlocked editor does not authorize a request.
Before admitting a secure command, the app saves pending editor changes and
locks its existing vault session; a save conflict refuses the command. The
request does not unlock or extend the editor session. Secure creation adds a
new entry and returns only its UUID, keyword and `secure: true`; duplicates refuse.
Secure updates and deletion remain desktop-editor operations. Reveal sends
plaintext to stdout, where scripts, logging or downstream tools may retain it.

Exactly one private input source is required for `add --secure`: `--content -`
for stdin, `--content-file`, `--content-fd`, or `--prompt` for one hidden terminal
line. The app is verified before input is read. Literal body arguments and
environment-variable body sources are not accepted. Input must be non-empty UTF-8
without NUL, at most 256 KiB. Files must be owned by the current user, have no
group/other access and no symbolic or hard links; stdin/descriptors accept private
regular files or pipes. Terminal stdin is refused; use `--prompt`. Hidden input
restores terminal settings on success, cancellation and handled termination or
job-control signals. User-provided files are not removed by the CLI.

Install the app and CLI together. The private runtime socket uses Linux
`SO_PEERCRED` and `SO_PEERPIDFD`, same-user checks and pinned installed executable
identities on both sides. Unsupported or denied kernel proof fails closed.
Executable identity is not Apple code signing: a script can invoke the genuine
CLI, so review the caller and operation before approval. The parent label is
informational; this does not defend a fully compromised same-user process or
installation. No body or caller path is logged. Consent expires after 30 seconds,
fresh authentication after 60; focus loss, desktop lock, quit, disconnect or a
changed source revokes delivery. Only one secure prompt is active and at most five
requests per minute are admitted. The client buffers a complete validated reveal
before writing stdout. Failed requests are not automatically retried; check the
library before repeating creation when its receipt was lost.

`secure-status` returns `secureCount`, `appAvailable` and `unlocked`. With no app,
only local metadata is read and `unlocked` is `null`. Exit codes are 0 for success,
2 for invalid usage, 3 for an unavailable app, 4 for denial/cancellation/expiry,
5 for unavailable vault authentication, 6 for no unique secure entry, 7 for an
unsupported protocol, and 1 for other refusals or uncertain completion.

The isolated IPC, vault and private-input tests pass, including hidden input on a
private PTY. The actual installed Release app and CLI also pass native consent,
fresh passphrase/recovery-key reveal and secure creation in unlocked Omarchy.
An independent OpenSSL decoder authenticates the created record and its content
hash. Deny, Cancel, wrong credentials, focus loss, disconnect, both unchanged
deadlines, the request limit, executable mismatch, duplicates and changed vault
sources refuse delivery. The fixture uses public fictional content on private
D-Bus/AT-SPI buses and data roots; the desktop editor remains locked. A separate
fixture starts every request with the actual editor unlocked, verifies that
status through the installed CLI, and proves that only new consent and fresh
credentials allow disclosure or creation.

## Verification

The unrestricted Omarchy session now passes native peer authentication, private
D-Bus tray registration/restart, private Wayland clipboard/input protocols, PAM,
verified HTTPS and an isolated Secret Service fixture. A real release primary also
registers with the Omarchy tray host, accepts activation and mirrors its exact
sanitized diagnostics to the system journal. Native library/recovery and Settings
checks pass after fixing GTK markup handling. Native window tests pass, including account cancellation, backup credentials
and ordinary paste into an independent GTK receiving process with clipboard
restoration. The complete encrypted-backup portal cycle passes in Debug and
Release, including cancellation, fresh authentication, independent OpenSSL
verification and both matching-vault and new-vault restoration. The installed
primary registers three real global actions and exits on one Quit request; its
installed CLI also verifies that primary and completes approved secure creation
and disclosure through real native credential dialogs. Freshly authenticated
secure insertion now reaches the independent receiving process too, with cancellation and incorrect
password refusal. Exact inline expansion, suggestion selection with Return and
replacement-echo isolation pass in that independent GTK receiver too. Combined
native sign-in, explicit library selection, key setup, recovery disclosure and
confirmation, worker restart/reconnect and sign-out pass using a private native
keyring, certificate-verified loopback HTTPS and private-policy PAM. Automatic
sync also passes live bidirectional/read-only, background, retry, restart, scope
halt and in-flight-disable checks. Reviewed switching to a separately keyed
library and back passes too. Two-installation pairing and signed device approval
pass with retained-request restart. Recovery replacement passes both exact-envelope
reconciliation and freshly authorized original-proof replay after restart, followed
by same-key recovery and encrypted synchronization. Ordinary saved-history
restoration also passes current-version/unrelated-record preservation, current
CAS/feed retention, new-worker reconnect and encrypted dependency ordering.
Same-vault protected restoration also passes fresh vault and separate PAM
authorization, exact unrelated records and encrypted preservation ordering.
Simulated interrupted same-vault restoration also passes offline cancellation
and completion after a fresh worker, with separate fresh PAM and exact approved
images. Retained foreign-vault restoration also passes independent current/source
verification and current-root re-encryption, with OpenSSL checks across native sync.
Native candidate pairing, published-switch offline finish, unpublished-switch
offline cancellation, all five installed file-source restoration combinations and
actual SIGKILL/offline restoration now pass. Other already listed interruption work
and the five bounded acceptance groups remain separate.
All three globally assigned actions, visible tray-menu selection/focus and re-registration
with a restarted Omarchy host pass; see the latest implementation milestone.
Focus-dependent checks require an unlocked session for their entire lifetime.

```sh
cargo test --locked --manifest-path snippets-linux/Cargo.toml
cargo test --locked --manifest-path snippets-linux/Cargo.toml --no-default-features
# Private authenticated bus and independent GIO client; requires Unix socket binding.
cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib tray::tests::isolated_native_tray_registration -- --ignored --test-threads=1
# Independent private shortcut protocol peer; no compositor, clipboard or input.
cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib global_shortcuts:: -- --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib native_global_shortcuts_settings_default_off -- --ignored --test-threads=1
# Native peer authentication requires unrestricted SO_PEERCRED.
cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib native_shortcut_peer_credentials_match -- --ignored --test-threads=1
# Real compositor registration and a single Quit; no running Snippets primary.
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --test desktop-quit -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib ui::tests::native_lifecycle -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib ui::tests::native_picker_without_editor -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib secure_ui::tests::native_secure_lifecycle -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib secure_ui::draft_recovery::tests::native_recovery -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib secure_ui::legacy_repair::tests::native_legacy_repair -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib ui::history::tests::native_disabled_history -- --ignored --test-threads=1
# Explicit live selection replacement; saves prior ordinary text in memory,
# then restores it after stopping all collectors. Private keyring/bus/data only.
# Obtain the library-test executable with cargo test --lib --no-run first.
bash snippets-linux/tests/clipboard-history-live.sh /absolute/path/to/library-test-binary
# Live host user-systemd/GTK activation of an installed release through a generated
# service and unique temporary target. No existing Snippets primary may be running.
bash snippets-linux/tests/login-startup-live.sh /absolute/path/to/library-test-binary /absolute/path/to/release-directory
# Mapped account/password dialogs, real private keyring, verified loopback HTTPS
# and private-policy PAM; no login-keyring or host-PAM-policy access.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary
# Native creation confirmation, lost HTTPS reply/restart, then a separate library
# beside actual keyring-owned keys and an encrypted sync checkpoint.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --creation
# Complete reviewed switch, independent target key setup, protected history,
# explicit encrypted sync, new-worker reconnect and return using the saved key.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --switch
# Selected ordinary saved-history restoration: safe-default review, fresh PAM,
# stale-primary refusal, current-version preservation and explicit encrypted sync.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --restoration
# Whole ordinary/protected saved history, fresh vault passphrase/recovery and PAM,
# stale ciphertext refusal, both current versions and unrelated records retained.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --secure-restoration
# Different independent current/source vault roots retained in history: separate
# credentials, whole-selection refusal, current-root re-encryption and OpenSSL.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --foreign-restoration
# Actual GTK fallback chooser on the private bus: selected external vault.json
# or independent encrypted backup, source-file binding through fresh PAM.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --file-restoration
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --backup-file-restoration
# Actual third-switch archive of a public legacy mixed-scope primary: vault A
# and independent C use the same KID with different salts/roots.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --mixed-retained-restoration
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --mixed-files-restoration
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --mixed-backup-restoration
# Real host FileChooser portal with the same isolated account bus/keyring.
# Only OpenFile and read-only GTK settings cross the narrow test relay.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --portal-chooser
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --portal-file-restoration
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --portal-backup-file-restoration
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --portal-mixed-retained-restoration
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --portal-mixed-files-restoration
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --portal-mixed-backup-restoration
# Simulated durable write interruptions; each case restarts the actual native
# worker, refuses all server requests, and requires fresh local-purpose PAM.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --restore-cancel-consent
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --restore-cancel-baseline
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --restore-finish-ordinary
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --restore-finish-vault
# Two private native installations: retained public invitation, compare-code gate,
# fresh PAM approval, original signed-request replay and claimed-key encrypted sync.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --pairing
# Owner recovery replacement: lost reply/restart, exact-envelope reconciliation
# or fresh-authorized original-proof replay, new offline copy and same-key recovery.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --recovery-reconcile
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --recovery-retry
# Each variant has its own native GTK process, bus, keyring and data root.
# The hidden-window checks wait for the unmodified 30-second scheduler.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --automatic-sync
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --automatic-reader
# Manual Receive/Send/Sync Now and fresh passphrase/recovery-key vault cycles.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --vault-sync
# Retained secure CAS conflict, protected-copy restore, cloud Cancel/Keep/Delete,
# then cursor-invalid snapshot Cancel/focus/stale-primary refusal and resumption.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --sync-review
# Flat current secure v1 source Keep/Delete, then separate acknowledged-copy
# deletion repair while an actual source rejection packet is retained.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --current-review-keep
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --current-review-delete
# Nested secure C1, physically present or held only in the native journal.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --nested-review-keep
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --nested-review-delete
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --nested-journal-keep
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --nested-journal-delete
# Cloud child deletion received before its raw owner; independent choices.
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --prior-child-keep-parent-keep
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --prior-child-keep-parent-delete
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --prior-child-delete-parent-keep
bash snippets-linux/tests/account-live.sh /absolute/path/to/library-test-binary --prior-child-delete-parent-delete
# Private socket-pair compositor; requires unrestricted Wayland peer credentials.
cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib clipboard_history::wayland::protocol_tests::private_libwayland -- --ignored --test-threads=1
cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib secure_insertion::wayland::protocol_tests::private_input_protocol -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib secure_ui::insertion::tests::native_insertion_review -- --ignored --test-threads=1
# Real fresh vault authentication and virtual keyboard; separate owned receiving app.
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib secure_ui::insertion::live_tests::live_secure_paste -- --exact --ignored --test-threads=1
# Real inline worker and independent GTK receiver; run each in its own process.
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib inline_expansion::worker::live_tests::live_inline_expansion -- --exact --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib inline_expansion::worker::live_tests::live_inline_suggestions -- --exact --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib inline_expansion::worker::live_tests::live_inline_echo_guard -- --exact --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib account_ui::tests::native_account -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib backup_ui::tests:: -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib backup_ui::importing::tests::native_restore_passwords_clear_on_cancel_and_confirm -- --exact --ignored --test-threads=1
# Actual Omarchy file portal and complete encrypted backup/restore cycle.
# Obtain the library-test executable with cargo test --lib --no-run first.
# The host portal/compositor is shared; library and app XDG roots are private.
bash snippets-linux/tests/backup-live.sh /absolute/path/to/library-test-binary
# Actual installed Release GUI/CLI with native consent and fresh vault credentials.
# Build all three Release binaries first; this installs them under a private prefix.
cargo build --locked --manifest-path snippets-linux/Cargo.toml --release \
  --bin snippets --bin snippets-cli --bin snippets-owner-auth
bash snippets-linux/tests/control-live.sh /absolute/path/to/library-test-binary \
  /absolute/path/to/cargo-target/release
# Start each secure CLI request with an actually unlocked native editor.
bash snippets-linux/tests/control-live.sh /absolute/path/to/library-test-binary \
  /absolute/path/to/cargo-target/release unlocked-editor
# Native protected keyboard editing, Undo/Redo, Escape/reveal and passphrase change.
bash snippets-linux/tests/control-live.sh /absolute/path/to/library-test-binary \
  /absolute/path/to/cargo-target/release secure-editor
# Native recovery-key unlock/change, credential cancellation and focus/Lock revocation.
bash snippets-linux/tests/control-live.sh /absolute/path/to/library-test-binary \
  /absolute/path/to/cargo-target/release secure-recovery
# Empty-vault setup, displayed recovery key, native keyboard gates and first save.
# Requires grim and Tesseract with its English language data; capture stays in memory.
bash snippets-linux/tests/control-live.sh /absolute/path/to/library-test-binary \
  /absolute/path/to/cargo-target/release secure-setup
# Authenticated logind sleep events on a separate private system bus; no host suspend.
bash snippets-linux/tests/control-live.sh /absolute/path/to/library-test-binary \
  /absolute/path/to/cargo-target/release sleep-events
# Actual temporary compositor locks; first run the private owner protocol check.
cargo test --locked --manifest-path snippets-linux/Cargo.toml --lib \
  control_ui::live_tests::lock_fixture::private_session_lock_owner_obeys_graceful_release_and_deadman \
  -- --exact --test-threads=1
bash snippets-linux/tests/control-live.sh /absolute/path/to/library-test-binary \
  /absolute/path/to/cargo-target/release compositor-lock
# Optional independent reader check; requires zbarimg (Arch package: zbar).
cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib recovery_qr::tests::independent_reader -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib ui::tests::live_paste -- --ignored --test-threads=1
cargo clippy --locked --manifest-path snippets-linux/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path snippets-linux/Cargo.toml --check
desktop-file-validate snippets-linux/data/com.khm.snippets.linux.desktop
appstreamcli validate --no-net snippets-linux/data/com.khm.snippets.linux.metainfo.xml
bash -n scripts/install-linux.sh
bash -n snippets-linux/tests/secret-service.sh
```

Unit/process tests always use temporary roots. The explicitly selected native UI
smoke test needs a display and verifies editing, search, duplicate, picker,
external conflicts, disabled entries, and separation of text undo between records.
The secure smoke test checks native catalogue/editor construction, real worker
authentication, programmatic encrypted edits, save, and draft retention after
lock. The retained-draft recovery fixture checks both password fields, input
bounds and cancellation with public fictional text; it uses no vault keys,
keyring, PAM, clipboard or account. The separate live secure-insertion test
creates a temporary vault, starts with its editor locked, enters its public test
passphrase into the native password dialog and activates its response button.
It checks cancellation and an incorrect password before valid authentication,
observes exact field contents through the independent receiving application's
match marker, and checks credential clearing and an unchanged vault. It uses the
real session monitor, native virtual keyboard and source admission without a
synthetic authorization. The live ordinary paste test requires an unlocked
session before any clipboard change or input.
It compiles a separate C/GTK receiving application, verifies its exact owned
window and process before sending input, and observes the expected public text
in that application's field. It refuses non-text clipboards and restores prior
text. The current live run passes. The primary-process Quit regression copies
Cargo executables into a temporary installation, enables global shortcuts only
in its private library, verifies ownership on D-Bus, and observes release of all
three registrations and exit after exactly one Quit request.

The installed secure-CLI fixture uses the real Release executables, installer,
socket server, peer checks, session monitor, consent and credential windows.
Its private D-Bus session activates only its own accessibility broker; it starts
an isolated AT-SPI registry directly. The C actor selects controls only under the
exact owned application PID and mapped CLI request window. Public credentials
enter the PasswordEntry through stdin-backed AT-SPI editing; recovery selection
uses native Tab/Space with observed focus/check state. No password or snippet body
is passed as a command argument or printed. It requires `atspi-2` development
files, `dbus-run-session`, `gdbus`, the distro AT-SPI broker/registry and OpenSSL.
All private app, input and bus roots are removed after exit. Host services,
keyring, PAM and clipboard are untouched. The default fixture lasts about two
minutes because it preserves the real 30/60-second deadlines. The
`unlocked-editor` variant opens the actual installed workspace through its native
GApplication action and unlocks it through its real password dialog before each
request. Its bounded read-only status probes can repeat a failed admission while
the nonblocking common file lock is occupied. Secure requests are never retried.
The `secure-editor` variant enters a public fictional body using real native
keyboard events, saves it through Ctrl+S and independently authenticates the
saved seal, content hash and passphrase wrap with OpenSSL. It checks metadata,
Undo/Redo, hidden-input refusal after Escape, single-click reveal afterward,
passphrase cancellation/change, explicit lock, old-password refusal and
new-password unlock. The protected drawing surface exposes only a static
accessible label and keyboard instructions; the actor requires actual focus
and refuses any AT-SPI Text or EditableText interface on that surface. It never
reads the body through accessibility. Button actions allow GTK's 250 ms native
activation animation to finish before sending subsequent input. The events
exercise the compositor path; physical keyboard and other IME input are separate.
The `secure-recovery` variant unlocks through the real recovery-key dialog and
changes the passphrase using native recovery selection and fresh credentials.
It covers Cancel, wrong recovery keys, mismatched confirmation, actual focus
loss, Ctrl+L in a pending credential dialog and focus loss during observed native
authentication/rewrap work. Fresh password fields are checked only for a zero
character count; the actor never reads their text. The installed CLI confirms
locked/unlocked state. OpenSSL independently authenticates the original body/hash
and new password wrap, and the fixture requires unchanged records, recovery wrap
and ordinary file. New-password and continued recovery unlock must both succeed;
the old password must refuse. All credentials stay in stdin-backed private input.

The `secure-setup` variant starts with no vault in two independent private roots.
Cancel, short/mismatched confirmation and focus/Lock revocation before submission
or during observed native setup work must leave the vault absent. It creates a
new vault through the installed Release dialogs, requires Continue to remain
disabled until the recording checkbox is selected, and tests native dismissal
with Escape outside the protected field. Tab/Space selects the affirmative gate
in the second root; a passphrase of exactly 12 characters must also create and
subsequently unlock that vault.

For the first root, narrowly scoped AT-SPI bounds and exact active-window/process
checks constrain grim to the owned recovery field. The accessible window size
must match the compositor's owned window size. PPM pixels and Tesseract
transcription stay in zeroizing memory; the bounded inset includes both glyph rows.
Consecutive lines, dictionary-free OCR and optional Crockford alphabet constraints
are checked without post-correcting symbols. Neither an image nor the key is saved or
printed. The actual displayed key must pass its checksum, independently unwrap
the same root as the passphrase through OpenSSL, and unlock through the native
recovery dialog after Lock. Escape in the field must hide the key and clear
Reveal; hidden Shift+Tab must leave it; one click reveals the same key again.
Actual focus loss and native vault Lock must hide it. The protected field has
no AT-SPI Text or EditableText interface. A first native keyboard-authored record
must then authenticate with OpenSSL, retain its exact body/hash, and preserve
the ordinary file. Private permissions, sanitized diagnostics, absent Sync state
and graceful quit are checked. This variant verifies native vault Lock. The
separate fixtures below exercise sleep notifications and actual compositor locks;
hardware suspend and broader physical keyboard/application compatibility remain open.

The `sleep-events` variant sends real D-Bus messages on a second private bus to
actual installed Release executables. The desktop monitor now reads logind's
initial `PreparingForSleep` property, pins sleep signals to its current unique
system-bus owner, and rebinds after owner loss. Missing or malformed state and
connection loss close the gate. A queued sleep/resume pair invalidates the epoch
and remains unavailable for at least 1.5 seconds; a later unlocked observation
requires fresh credentials. The GTK revocation tick also compares desktop epochs,
so a lock cycle cannot preserve a key if GTK missed its blocked interval.

The fixture covers foreign-sender refusal, an unlocked key with unchanged focus,
a pending password dialog, observed real authentication/setup workers, malformed
owner notifications, service restart and pending CLI disclosure. It terminates
only its own fictional system-bus daemon after the bus confirms its PID and UID,
then requires an unlocked native vault to revoke without focus loss. Primary files
stay exact, rejected setup leaves the vault absent, and CLI disclosure returns no
body. Fresh credentials, private diagnostics and graceful quit are checked.
This exercises the installed application's sleep-notification boundary. Actual
hardware suspend/resume remains a separate live check.

The `compositor-lock` variant requests real temporary Wayland session locks from
the selected Hyprland instance. Its standalone test owner verifies the socket's
peer against that compositor and creates no surfaces or input/clipboard clients.
The compositor supplies its opaque fallback. Cancellation, EOF, a signal or the
owner's independent timer requests graceful release; a queued lock acknowledgement
is consumed before choosing the correct destructor. The owner waits for an ordered
Wayland sync acknowledgement after unlock before exiting. Rust unwinding also
releases through this owner; it never kills a connected lock client.

Before touching the desktop, an independent socket-pair Wayland server checks
missing/duplicate managers, denied locks, immediate/delayed acknowledgements,
timer expiry, EOF, signals and controller unwinding. Both helpers are compiled
under a disposable test root using `cc`, `pkg-config`, `wayland-scanner` and the
installed `wayland-protocols`; neither helper is installed as a normal locker.

The live fixture observes actual compositor Locked state and revocation of an
unlocked vault, a correctly filled password dialog, running authentication and
passphrase-change workers, pending CLI disclosure and a running new-vault setup.
After acknowledged unlock, primary files stay exact, the original passphrase still
works, the interrupted setup leaves no vault and CLI stdout contains no body.
Fresh credentials, diagnostic privacy and graceful quit are checked. Host PAM,
idle configuration, Stay Awake and the lock-restoration timer are preserved.
The current live session uses Hyprland Safe Mode; normal Omarchy configuration
and hardware suspend remain separate acceptance work.

Local-owner tests exercise libpam against a disposable private policy and a
public fictional password module. They cover incorrect passwords, account
restrictions, changed identity, refused conversations, cancellation and timeout
without accessing authentication databases or the host PAM policy. The installed
helper is tested only with malformed requests that cannot authenticate a real
account. The account-window lifecycle fixture injects its worker and authorization,
uses only public visual/input material, and never accesses a real keyring, account,
PAM service or server. It must run on the normal host bus, separately from the
keyring harness. The login-launch fixture also uses the normal desktop bus and
user manager. It copies the GUI/CLI/helper release artifacts into a private path
with spaces and checks peer admission against the actual generated-service owner.
It writes only private registration/data and unique runtime units; it starts no
shared desktop target and performs no logout. Ordinary primary startup creates
its normal empty private Usage lock, but no snippets, vault, sync, history or
learned usage payload. All owned services, units and windows are removed.
The account lifecycle's current unlocked run passes after waiting for the parent
window to map before presenting its child and applying the selected-library
state before testing pairing controls.
The pairing variant uses two private library roots with independent random
Secret Service namespaces and saved account credentials. Public invitation/QR
and comparison code are retained across recipient restart; cancelling clears the
view and removes the server request. Trusted-device approval requires matching
codes and fresh computer-password authorization. Cancel, incorrect password and
focus loss make no challenge or approval request. The peer independently checks
the exact ciphertext/recipient request hash and Ed25519 challenge signature.
After committing approval it closes TLS without a reply; read-only result checking
keeps the original signed intent, and a new trusted worker authorizes replay of
that same proof. One server receipt is accepted despite two sends. The recipient
claims the encrypted packet, installs the original library key, synchronizes and
reconnects without another pairing or bootstrap. Both primary libraries remain
exact through the approval workflow. No invitation is copied to the host clipboard
by this fixture. Candidate pairing for switching remains a separate live check.

The two recovery-replacement variants use the same independent signed-action peer.
Default password Cancel, incorrect private-policy PAM and actual filled-dialog
focus loss retain the original unsigned intent and leave the envelope, active
keys, primary/checkpoint files and record data exact. A successful owner-authorized
replacement increments only the envelope version, then deliberately loses its TLS
reply. A new worker retains Signed state. One variant reconciles the exact saved
ciphertext without another challenge or PUT; the other obtains fresh computer-password
authorization and replays the same proof, with one accepted server receipt. The
new recovery visual/code is freshly authorized and confirmed through its native
offline-copy controls. Another isolated installation refuses the old code, restores
the original library key using the new one, and receives the encrypted record.
Confirmed recovery state survives a further reconnect. The peer keeps encrypted
bytes and public verifier/proof material; no code, key or plaintext body is sent
or written by the test controller. Full codes/keys exist only in zeroizing fixture
memory for the cryptographic checks.

The separate combined account fixture uses the real serial account owner and
native Secret Service backend on its own bus and data root. It exercises mapped
GTK response buttons against a certificate-verified loopback server, with exact
fixture-CA trust scoped to its worker thread. The ordinary constructor rejects
that certificate before and after the scenario. Its private PAM policy uses the
production helper protocol and libpam with a public fictional password module;
it never reads the host authentication database. The check covers account
creation with its one-time key screen, explicit selection of the first/only
library without implicit key creation, key setup, recovery cancellation/
wrong-password refusal, focus revocation, fresh authorization and confirmation,
new-worker reconnect, owner-authorized **Show Account Key** and its focus
revocation, confirmed sign-out, and signing in again after a local typing error
and a rejected key. Both workers
drain, all fixture children are reaped, and private bus/keyring/data are removed.
Its onboarding variant requires an unlocked desktop and creates no vault or sync
checkpoint. The automatic variants explicitly create private sync checkpoints
through saved native consent. Their independent server stores only opaque encrypted
wire records and validates CAS versions; the test thread alone opens the public
fixtures using the actual temporary keyring-owned library key. Both background
directions use the production timer with the account window hidden. Writer checks
also verify HTTP backoff, new-worker automatic reconnect, a mapped Disable action
while the HTTP response is held, unchanged primary/checkpoint bytes after revocation,
and offline startup after opt-out. Reader checks verify no batch upload and a halt
on changed membership. The vault variant uses independent public wraps and
private vault/checkpoint files. It covers mapped manual commands, sealed
same-vault exchange, fresh passphrase/recovery methods, cancellation, focus and
source revocation, encrypted local/remote edit convergence and a second cycle
requiring new proof. It never enables automatic scheduling, and only the test
thread opens fixture bodies to verify the result. The HTTPS server keeps opaque
wire records. The review variant captures bounded encrypted POST packets and
positional CAS, proving protected-copy acknowledgement before the source update.
It also verifies missing-copy restoration with fresh credentials and the same
sealed nonce, cancellation/wrong credentials without writes, actual review focus
revocation, and ordinary cloud Keep/Delete decisions preserving unrelated data.
Only closed status/failure enums and counts appear in failure output.
The independent QR reader test uses public payloads and explicitly disables
zbar's D-Bus publication. Recovery-disclosure/confirmation tests use an explicitly synthetic proof;
they cover suffix normalization, secret retirement, schema migration and both sides
of an interrupted write. The separate combined fixture above establishes the
native password-dialog path with private-policy PAM. See the
[implementation evidence](../docs/linux/IMPLEMENTATION.md) for current test counts
and authorization limits.

The default tray tests include an independent C/GIO/Cairo reader of the public
ARGB icon. The separate ignored tray fixture creates its own authenticated
`dbus-daemon`, a watcher and an independent client; it never changes the session
bus environment or contacts the user's bus. Its current attempt stopped before
connection creation because Unix socket binding was denied. It does not establish
live Omarchy panel or application-action behavior.

The native Secret Service fixture requires GNOME Keyring, `dbus-run-session`,
`gdbus`, and `rg`. After building library tests, invoke
`bash snippets-linux/tests/secret-service.sh /absolute/path/to/library-test-binary`.
Choose the desktop-feature library test executable containing
`secret_store::tests::native_backend_fixture`, not the app or CLI executable.
The harness creates a private D-Bus, runtime directory and disposable keyring;
it tests binary values, replacement, deletion and locked-keyring refusal. It
does not initialize GTK or touch the desktop keyring. Use each GUI fixture's
dedicated runner on the unlocked compositor. Account portal variants retain
an isolated account bus/keyring and relay only the supported host portal calls.

The external-history variants use a real mapped GTK FileChooserDialog, reached
through the production FileDialog callback on the private bus. They do not
manufacture a selected-file reply or source ticket. Only the exact public fixture
path is selected. The chooser is allowed to take focus after the two prefilled
vault fields have been cleared and the old preparation revoked. Cancelling it
keeps primary files, checkpoint, nine protected key frames and record exchange
unchanged. The JSON variant exercises independent source passphrase/recovery;
the backup variant uses the existing independent OpenSSL container and exposes
only a backup password for the source. Whole-selection credential, review, PAM,
focus and stale-primary refusals are followed by actual current-root restoration,
independent OpenSSL verification, fresh-worker reconnect and encrypted sync.
Changing the selected file after review, before valid fresh PAM, refuses before
receipt or primary writes. Contents of the selected backup are not imported.
The account runner now isolates GTK configuration/cache and uses memory GSettings,
as well as its existing private bus/keyring/data roots. This establishes GTK's
fallback chooser. The portal variants below add actual host selection while
retaining account/keyring isolation. All five combinations now also complete
restoration through unchanged installed Release artifacts with private native PAM.
See docs/linux/IMPLEMENTATION.md for the exact evidence and remaining host checks.

The mixed-history variants first sync public source A, then install one public
legacy sealed participant encrypted with independent C under A's metadata-only
primary. The real third reviewed switch archives all three ordinary/A/C records;
no protected history is rewritten. A and C deliberately share a KID but have
different salts/roots. Independent current B has both IDs before its first native
vault sync, giving both records actual current CAS/feed state. The mapped GTK
multiple-file chooser selects exactly one owned JSON plus retained A, two JSON
files, or A JSON plus C's independent OpenSSL backup. Wrong, incomplete or duplicate
source authority refuses the whole selection. Filled-field chooser cancellation,
vault/review/PAM cancellation and focus loss clear all inputs without writes.
Every selected file is individually replaced after whole review and before valid
fresh PAM; each refuses before receipt or primary writes. A later current-ciphertext
change also refuses. Fresh verification/consent restores all three saved records
under current B, keeps three disabled current versions and two unrelated records,
and imports no source-only content. Exact wraps/header, nine protected frames,
current CAS/feed, the source A wire and completed history are checked across a new
worker and freshly authenticated encrypted copy-before-source synchronization.
OpenSSL verifies both independent source scopes and actual current output before
and after sync. The mixed Debug fixture waits up to 150 seconds for completion,
with closed numeric peer progress; the real 120-second authorization and bounded
sync limits are unchanged. The portal variants exercise the host route as well.
The missing-header GUI path now passes with an explicit historical schema-2
archive and real old-JSON chooser, followed by process death and file-free offline
completion; see the bounded evidence below. Legacy own-record metadata recovery
is a distinct core check.

The portal variants export a test-only OpenFile relay on the private bus before
GTK initializes. Its version comes from the authenticated host portal; replies
are accepted only from that pinned owner and their results are relayed unchanged.
Only request object paths are translated between the two buses. Read-only GTK
appearance/GNOME settings are forwarded on a separate main context; unsupported
session-monitor/registry capabilities negotiate version zero. A local fail-closed
service advertisement makes GTK 4.22 discover the relay without forcing portals
or exposing host activation directories. The account's Secret Service remains
private, and the relay never forwards keyring calls.

Two-file requests receive only an initial-folder hint for the exclusive public
fixture directory. That hint does not select files. The actual host chooser gets
Ctrl+A and Open; every returned URI must match the exact owned set before the
production callback can request credentials. Single-file requests use the normal
chooser and type only the public fixture path, including spaces. Before every
key, the harness checks the unlocked session and exact active portal address/PID
against its host D-Bus implementation owner. Cancel/other aborted responses are
relayed unchanged and must contain no files. The smoke fixture checks cancel,
single/multiple selection and parent focus; the full restoration fixtures retain
the whole-selection refusal, stale-file/PAM, OpenSSL and fresh-worker sync checks.
No compositor configuration is changed.


## User test build and bounded remaining acceptance (2026-10-05)

The Release GUI, CLI and unprivileged PAM helper are installed under `~/.local`.
Start the application with `~/.local/bin/snippets` or its desktop entry. Quit with
Ctrl+Q or `~/.local/bin/snippets --quit`. The installer has not enabled login
startup, sync, clipboard history or inline expansion. Installation preserves
library data and the desktop configuration. The latest verified user archive and
GUI/CLI/helper hashes are recorded in `target/user-testing/latest.json`. This latest
archive has passed the combined-runtime GUI checks in an isolated installation. The normal
prefix's deployed source and private code-only rollback directory are recorded in
`target/user-testing/installed-current.json`. The normal launcher includes the
first-key continuation and losing-candidate pairing-control fixes.
It remains the separately verified `7fd967c` GTK-only deployment; packaging the
combined GTK/libadwaita candidate has not replaced that installation.

For this user test, create a disposable ordinary snippet, edit and search it,
close/reopen the library, and verify persistence. Exercise Copy and the picker in
your usual receiving application. Try a sharing JSON import/export and an encrypted
backup with disposable content. If testing Secure Snippets, enter the real local
password in its native prompt yourself; automated acceptance used private PAM and
keyring fixtures. Keep any diagnostic report to the action, observed result and
whether focus returned; snippet contents and passwords are unnecessary.

The confirmed GTK 4.22.4 defect is fallback cancellation during an
unfinished path-bar update. A minimal C program, independent of Snippets, reproduces
`gtk_box_remove: GTK_IS_BOX` twice with a public 128-level folder. Fatal warnings
abort; the ordinary policy emits criticals and returns the dismissed callback.
The simple GTK cancellation control passes. The installed Release app's actual
**Choose Several Vault Files…** Cancel passes with both fatal and ordinary warning
policies, and after navigation to that public folder: focus returns and the primary,
vault and encrypted history/checkpoint files are unchanged. These passes do not
close the GTK race by themselves. The `7fd967c` GTK-only deployment carries the
verified ownership repair for the app's fallback chooser. Its relative loader
path was checked in the actual installed GUI without LD_LIBRARY_PATH. The same
minimal reproduction passes using that installed runtime; original system GTK
still reproduces the defect. The real host portal has its own unchanged GTK
process; its existing cancel/single/multiple/focus smoke passes with that GTK
sender and with the later corrected GTK host profile.

The latest candidate also includes the independently verified libadwaita heading
repair and corrected GTK resource paths/native integrations. Both libraries load
through the candidate GUI's relative RUNPATH without a loader override, verified
at executable initialization. Installation from the archive into a private prefix
passes. Its final mapped inflight Cancel, installed-GUI Cancel/focus/private-state
check and existing host-portal smoke now pass on the unlocked session. The
unchanged installed runner verifies both libraries through its relative RUNPATH,
actual Cancel, focus return, normal quit and exact private state. One earlier
attempt failed before Cancel without GTK warnings; its control failure remains
recorded separately. A diagnostic run and the unchanged runner then pass. No
delay or warning-policy change is presented as a repair. Earlier GUI passes
retain their original bindings. Neither source patch changes cancellation timing
or suppresses warnings.

Reproduce only this concrete defect in an unlocked Wayland session:

```sh
bash snippets-linux/tests/chooser-cancel.sh minimal --inflight-folder
bash snippets-linux/tests/chooser-cancel.sh minimal --inflight-folder --nonfatal
# Release library-test executable from cargo test --release --lib --no-run:
bash snippets-linux/tests/chooser-cancel.sh installed /path/to/test-harness   "$HOME/.local/share/snippets-linux/snippets"
```

The runner owns temporary data/config/cache, a private D-Bus, private native
keyring and private accessibility registry. It selects only public owned controls
in the installed process. Navigation keys require the exact owned active chooser
and unlocked session. It forwards no host secrets and changes no compositor rules.
Its only observation delay is after Cancel; it is not a cancellation workaround.

The finite remaining acceptance list for the first stable port is below. These
are evidence gaps, separately from the confirmed GTK defect; this list does not
introduce more features or a permutation matrix. New cases are added only for a
specific defect.

| Remaining check | Current limit |
| --- | --- |
| Normal Omarchy input and focus | Current live evidence uses Safe Mode. The surface-wrapper Release addon passes all nine existing core stages without a Fcitx restart, including Ghostty click insertion and three cold browser fields. Existing caret-panel and independent GTK button clicks pass with a continuous test pointer. The earlier missing-backslash/literal-input failure still has no confirmed cause or repair. History passes via accessible row selection. Physical input and a fresh normal session remain. |
| Host authentication and lifecycle | Real login PAM/keyring interaction, hardware suspend/resume and a fresh-login autostart cycle remain user-session checks. Private PAM/keyring, simulated sleep and user-manager activation already pass. |
| Durable recovery | Other interrupted switching/first-key setup remains. Native candidate pairing from an independent trusted B installation preserves active A, restarts the invitation and retains the received B key until a separate PAM-authorized switch. Published-switch offline finish, unpublished-switch offline cancellation and first-key lost-response continuation pass. The interrupted empty-target candidate's losing-race pairing control is repaired and covered by the existing native controls gate; this does not prove all remaining interruption boundaries. Native restoration cuts, SIGKILL/offline restoration and the historical missing-header file case also pass. |
| Remaining preferences and diagnostics | Accessible history selection, Copy, opt-out, restart and Clear now pass in the installed GUI. Physical history interaction remains. Mapped learning/picker windows, independent resets and persisted options now pass with public learning notifications. Core privacy/persistence, native lifecycle controls and the complete native diagnostic export/delete cycle with the actual host SaveFile portal pass. The diagnostic fixture has no global sink or system-log mirror; physical learning input remains part of the normal Omarchy input gate. |
| Apple data exchange | Perform an actual Apple-app JSON/encrypted-backup round trip. Independent format/vector checks and native backup portals pass. |

The source-bound archive is available for user testing. Its normal-prefix
installation includes the combined GTK/adwaita runtime and native Fcitx addon;
installation preserves library and preference metadata. Stable-port acceptance
remains open on the five checks above, including the reproduced initial-field
core blocker. System GTK and other applications are unchanged. Desktop idle
schedules are managed separately from application acceptance.

The latest verified user archive and its clean source commit are recorded in
`target/user-testing/latest.json`. Builds retain the rebase on `main` `25296338`
and include source and binary receipts. The archive's installation check uses an
owned temporary prefix; normal-prefix deployment has its own source/hash receipt.

### Private GTK cancellation repair (2026-10-05)

The [GTK 4.22.4 failure cleanup](https://raw.githubusercontent.com/GNOME/gtk/4.22.4/gtk/gtkpathbar.c)
tries to remove pending path buttons from a box. Those floating widgets are only
parented after successful path construction, and the box can already be destroyed
when the cancelled query completes. The small
[reference patch](tests/reference/gtk-4.22.4-pathbar-cancel.patch) sinks and releases
the unparented widgets directly. It leaves successful construction and Cancel
timing unchanged; widget finalization releases the associated button metadata.

An official, checksum-verified 4.22.4 source archive was built privately, retaining
the default Vulkan/OpenGL and Wayland/X11 support. The baseline and patched
libraries use identical build options. Existing diagnostic modes produced:

| Existing check | Baseline GTK | Patched GTK |
| --- | --- | --- |
| Simple minimal Cancel | Exit 0, dismissed callback, no criticals | Same |
| Minimal Cancel during 128-level path update, twice | Exit 134 with `GTK_IS_BOX`, both runs | Exit 0, dismissed callback, no criticals, both runs |
| Installed `79e684b` multiple chooser after public-folder navigation | System GTK: exit 0, focus and exact private state preserved | Same |

Each actual test process's mapped GTK provider was verified. Fatal warnings stayed
enabled; the existing two-second observation occurs after Cancel. The C program,
runner and Rust app were unchanged. Initial build-tool/header failures remain
separate from the completed build and native results. Receipts, source checksums,
build options and immutable libraries are under ignored `target/gtk-chooser-repair/`.

To check the existing reproduction with a privately rebuilt patched library:

```sh
LD_LIBRARY_PATH=/absolute/path/to/patched-library \
  bash snippets-linux/tests/chooser-cancel.sh minimal --inflight-folder
```

That private verification preceded delivery. The subsequent user bundle loads
the same library through its own ELF RUNPATH, without changing system GTK. The
five remaining evidence groups retain their scope, and no new runner option,
Rust test or general acceptance variant was added.

### App-local GTK delivery (2026-10-05)

Only the GUI's link configuration changes: the Rust UI, model, CLI and helper
sources remain unchanged. The candidate release installs into a prefix containing
spaces, retaining exact binary/runtime hashes. The existing deep-folder minimal
case and actual installed multiple chooser Cancel both pass with fatal warnings,
verified mapped GTK providers and no LD_LIBRARY_PATH. Cancel returns focus and
preserves the exact private primary/vault/history state. A compiler-only
LD_RUN_PATH records the library path in the independent C diagnostic's ELF;
the GUI uses its own relative RUNPATH.

The existing actual host OpenFile smoke also passes cancel, single/multiple
selection and parent focus with this GTK sender. That harness alone uses a scoped
dependency override; the normal GUI and external portal environment are unchanged.
All prior restoration/full-suite results retain their original source bindings.
Both all-target Clippy configurations, format, installer syntax, Release build and
the existing native harness compilation pass. The reference/runner/test count is
unchanged. Current archive and deployment receipts remain under `target/user-testing`.
The earlier `4bd8969` archive predates the first-key fixes below.

## Live diagnostics export and delete (2026-10-04)

The previously listed complete diagnostic interaction passes in the Release
native harness on the unlocked Omarchy session. It maps the production controls,
checks the plaintext privacy notice and default Cancel response, and activates
their actual buttons. Cancel at the privacy notice, delete notice and actual
SaveFile portal leaves the logs intact. The successful SaveFile response must
equal the owned public destination before the export worker can write anything.

The actual exported JSONL has one manifest plus exactly the two typed fixture
events, the exact closed top-level and event field sets, the reported counts and
`0600` permissions. The real destructive confirmation deletes retained logs only.
The exported file and primary/vault/checkpoint/history preservation sentinels
remain byte-for-byte unchanged; a subsequent event creates a new log and refreshes
the controls. Focus returns and both buttons become available after completion.
The preservation sentinels do not claim authenticated recovery or sync acceptance.

Run the existing acceptance group with a Release library-test executable:

```sh
bash snippets-linux/tests/diagnostics-live.sh /path/to/library-test-binary
```

The runner retains the real host D-Bus solely for the desktop portal. Only the
authenticated active portal window receives public fixture-path input. Data,
config and cache are temporary; no account, keyring, PAM, clipboard or network
operation is constructed. The isolated diagnostics service has no global facade
registration or OS-log mirror. `G_DEBUG=fatal-warnings` is enabled and the passing
run has no GTK criticals. This is mapped native-control evidence in a test process,
not a new full installed-app or host authentication claim. The seven remaining
groups above stay bounded; no feature or variant matrix is added. The GTK chooser
cancellation blocker remains open and the user test binaries are unchanged.

## Live learning picker and resets (2026-10-04)

The existing native learning smoke fixture now completes the previously listed
picker/settings gate in the unlocked Release session. Four public entries prove
that exact matches and pins retain priority, the open picker keeps a frozen
learning snapshot, and a new picker reflects the corrected prefix choice.
No selection is delivered to a clipboard or receiving application in this fixture.

The actual mapped reset notices default to Cancel. Cancel leaves learning bytes
and the earlier picker intact. Confirming **Reset Usage Counts…** preserves prefix
choices; **Forget Prefix Choices…** preserves counts; **Reset All Learning…**
clears both. Each confirmed change closes the old picker. Disabling ranking keeps
collecting counts, while disabling prefix memory erases choices. Both options and
the reset state survive stopping the owned worker and reopening the real controls.
The original library bytes are unchanged and local usage permissions stay private.

```sh
bash snippets-linux/tests/learning-live.sh /path/to/library-test-binary
```

The runner owns a private D-Bus with no activatable services, temporary config,
data/cache and a short private runtime. It accesses the real compositor only for
GTK windows and read-only session checks. There is no account, keyring, PAM,
clipboard, network, global logging or compositor-configuration operation.
Fatal GTK warnings are enabled; the completed run contains no criticals.

This extends the existing native learning fixture rather than adding acceptance
variants. The input history consists of public notifications through App::learn;
it does not establish physical delivery or recording from a user's application.
Those checks remain in the normal Omarchy input group. The seven-group board is
narrowed, the independent GTK chooser blocker stays open, and the installed user
test build and archive are unchanged.

## Native process termination and offline restoration (2026-10-04)

The already listed actual process-death gate passes at the mixed-image boundary.
An exclusive native child maps the production history, unlocks the two fictional
vaults, reviews the restoration and authorizes it through private PAM. A cfg(test)
hook stops all its threads after the durable ordinary-library write, before the
vault write or injected-failure unwind. The parent observes the stop, sends
SIGKILL and reaps that child before starting another process.

The encrypted WAL retains the approved before/after images. The parent verifies
the actual ordinary file is already the after-image, the vault is still the
before-image, the durable marker exists and library readers are fenced. A fresh
native process completes the saved restoration offline with a new private PAM
authorization, without vault credentials or a borrowed editor/session key.
Both files exactly match the WAL after-images; the marker is removed, readers
reopen, transport state and protected capabilities remain unchanged, and retained
ciphertext history is preserved. A third native process maps the terminal history
without a completion action or further file/receipt changes.

```sh
bash snippets-linux/tests/account-live.sh /path/to/library-test-binary --restore-process-ordinary
```

The fixture uses only public fictional data, a private native keyring and PAM,
and zero HTTP requests. Child scratch files remain under the surviving parent's
owned temporary directory, including after SIGKILL. Fatal GTK warnings are enabled
and the passing run has no criticals. This is native harness evidence at one
existing recovery boundary, not full installed-app restoration or a new crash-cut
matrix. The other recovery gaps and the GTK chooser blocker remain open.

## Native legacy missing-header restoration (2026-10-04)

The existing process-death acceptance now also covers the already listed
missing-header GUI path, without another test, runner option or source/cut matrix.
A fictional schema-2 archive omits its saved vault header while retaining the
authentic encrypted checkpoint images, receipts, record stamps and sealed bodies.
The private native keyring confirms the header is absent before the window opens.
This is distinct from missing own-record stamps/hashes.

The mapped credential window cannot select the unavailable retained vault. Its
real **Choose Previous Vault File…** GTK chooser accepts only the owned public old
JSON; opening the chooser clears entered fields. Returned credentials are fresh,
Cancel remains the default and focus returns. Fresh current passphrase and old
recovery-key verification produces the real whole-restoration review and private
PAM authorization. The existing SIGKILL boundary then holds/reaps the process.

Before starting a fresh continuation process, the parent deletes the selected
JSON. Completion needs only the approved encrypted WAL and new private PAM:
there is no old file, vault password or borrowed editor key. Exact after-images,
reader-fence removal, protected slots, transport state, retained ciphertext history,
current vault identity and terminal history survive the subsequent process reopen.
The existing core test separately passes its established schema-1/schema-2,
JSON/backup and durable-cut coverage. No additional native permutations are claimed.

Use the same existing command:

```sh
bash snippets-linux/tests/account-live.sh /path/to/library-test-binary --restore-process-ordinary
```

The first attempt stopped at GTK Recent Files registration because the test child
registered an application without Application::run and had no program/application
name. Its owned core places the fatal warning in gtk_recent_manager_add_full;
the extracted core was removed. Giving this test child its public identity resolves
that fixture startup failure. Fatal warnings remain enabled. The successful full
cycle contains no GTK criticals. Its actual HTTP counter is zero at the held write
before SIGKILL, and again after each fresh native stage; it counts even refused
offline requests. The independent GTK
path-bar cancellation blocker remains unresolved; no wait or suppression is a fix.
The installed app and prepared user test archive remain unchanged.


## Native history removal and recovery-file cleanup (2026-10-04)

The existing native history-panel fixture now completes the already listed
removal/cleanup gate through the production worker and mapped controls. Its public
private-keyring fixture uses an authentic completed library switch with no unfinished
old capabilities. Existing assertions still hide cleanup when there is no active
key, validated creation history is unavailable or maintenance already needs finishing.

Both destructive reviews default to Cancel and explain the possible loss of the
only recovery copy. Cancel preserves all files and protected slots. Cancelling the
filled cleanup PAM prompt also clears its field without deleting anything. Fresh
private PAM approval removes exactly the reviewed unused encrypted pair; the saved
history pair and a new pair created after the review remain byte-for-byte intact.
A separate removal review and fresh-purpose PAM approval remove only the completed
switch entry and its referenced pair. The new unreviewed pair remains.

Primary JSON, vault and encrypted checkpoint bytes, current keys and twelve
protected capability slots are unchanged. Durable maintenance is cleared, readers
remain available and the real HTTP counter stays at zero. The owned account worker
is observed alive and then terminal before a fresh native process opens the real
history panel. That process confirms no saved switch and the exact retained files;
its inspection makes no further file or protected-history changes.

```sh
bash snippets-linux/tests/account-live.sh /path/to/library-test-binary --history-maintenance
```

This option routes the existing ignored panel test; the native count stays 1,140.
The runner uses temporary data/config/cache, a private native keyring and private
PAM, with fatal GTK warnings. The passing cycle contains no criticals. Eighteen
existing owner tests also cover stale/linked files, cancelled or wrong-purpose
permits and durable cleanup/removal boundaries. The existing legacy file-source
test also passes after the shared fixture refactor. This is native harness evidence
for a completed switch, not physical input or installed full restoration.

The initial fixture retained unfinished old capabilities, so production correctly
hid removal. Those failed runs are retained separately; preparing the terminal
fixture through the real switch owner resolves the test failure without altering
product safeguards or adding a wait. The independent GTK chooser cancellation
blocker remains open. The finite board is narrowed, and the installed app and
prepared rebased user test archive are unchanged.


## Native Unknown pending raw-child decisions (2026-10-04)

The previously listed Unknown pending raw-child gate now passes Keep and Delete
before the separate parent Keep decision. Two existing ignored prior-child tests
run this public fixture in an exclusive child process, then retain their existing
prior-confirmed scenarios. The native count remains 1,140 and runner options stay
the same; no source/choice permutation matrix is added.

The production native owner captures the unresolved secure parent graph. The
fixture seeds only a retained unreviewed child tombstone through Journal::desire
and the actual encrypted checkpoint CAS under the private library lock. Its
ReviewAncestor is explicitly Unknown; no child offer, confirmed version, original,
receipt or deletion approval is fabricated. The parent tombstone arrives through
verified HTTPS, and the mapped review selects the pending child first.

The actual review and fresh vault credential dialog keep default/close Cancel.
Cancel, a filled credential Cancel, focus revocation and a wrong recovery key
preserve exact primary/vault/checkpoint bytes and network counts/packets. A fresh
recovery key authenticates the child's immutable original before its decision.
The retained inbound page and outbound packet remain exact, the raw parent's
sealed body is unchanged and no parent deletion approval is granted. The separate
parent review cancels and refuses wrong credentials before fresh authorization.

Real HTTPS CAS then acknowledges the exact child original with create CAS before
the parent update using the retained parent version. Delete subsequently uses the
child's actual acknowledged version; Keep preserves the original sealed body.
The unrelated ordinary record and current library key remain unchanged. Final
native synchronization completes with no preservation work, approvals or WAL.
The owned worker is observed live and then terminal before the fixture process
exits; it is reaped before the original prior-child scenario starts.

Use the existing commands with a Release library-test executable:

```sh
bash snippets-linux/tests/account-live.sh /path/to/library-test-binary --prior-child-keep-parent-keep
bash snippets-linux/tests/account-live.sh /path/to/library-test-binary --prior-child-delete-parent-keep
```

Both cycles pass with fatal GTK warnings and no criticals. Twenty-six existing
current-recovery owner tests also pass, including their raw-child, independent
choice, stale review and durable-cut coverage. No production runtime behavior
changes. This proves native harness decisions for retained pending state, not
physical editing or an additional native parent-choice matrix. Local-absence
source review, unrelated ambiguous packets and the independent GTK cancellation
blocker remain open. Installed executables and the prepared user archive are unchanged.


## Native local-absence source review (2026-10-04)

The already listed local-absence source review now passes Keep and Delete in the
native Release harness. The two existing current-carrier tests first run this
public case in an exclusive process, then retain their earlier cloud-deletion
and acknowledged-copy repair cases. Test count stays 1,140 and no runner option
or source/choice matrix is added.

Receive records a real HTTPS acknowledgement for a fictional secure source.
Send captures its later unresolved v1 primary graph into the actual encrypted
journal. The fixture then removes only that source record from its owned temporary
vault file, retaining the vault header. No journal, confirmation, permission or
original is injected. Another Send reports local review without an implicit
tombstone, file mutation or data-plane fetch/batch/packet change.

The mapped default-Cancel notice says the snippet is missing locally and discloses
its conflict original. It offers Restore Retained Version separately from Confirm
Deletion. Notice Cancel, filled credential Cancel, actual focus revocation and
wrong recovery-key authentication preserve exact ordinary/vault/checkpoint bytes,
fetch/batch counts and submitted packets. Fresh current-vault recovery authentication
freezes the real disabled original and applies only the selected source choice.
The existing inbox/outbound packet and real confirmed source version remain exact.

Keep restores the captured winner; Delete leaves the source absent. Both preserve
the disabled original with its exact sealed bytes and public body. Real HTTPS CAS
acknowledges that original with create CAS before updating the source at its
original confirmed version. Final native synchronization has no pending intent,
preservation work, approval or WAL. Current library key and unrelated ordinary
record remain intact. The account worker is observed live and terminal before
its process exits and the earlier current-carrier scenario starts.

Use the existing commands with a Release library-test executable:

```sh
bash snippets-linux/tests/account-live.sh /path/to/library-test-binary --current-review-keep
bash snippets-linux/tests/account-live.sh /path/to/library-test-binary --current-review-delete
```

Both full cycles pass with fatal GTK warnings and no criticals. Six existing
source-recovery owner tests also pass, including their retained-version, collision,
stale review and durable-cut coverage. The finite conflict row now leaves unrelated
ambiguous packets. This is native retained-state/file
absence evidence, not physical editing or a new crash/source permutation matrix.
The independent GTK chooser cancellation defect remains open. Installed executables
and the prepared user archive are unchanged.

## Rebase on current main and acceptance audit (2026-10-05)

The development branch is rebased on `main` `e232c886`. All six prior commits
retain their patches in range-diff, the native tree is unchanged, and all nineteen
upstream-changed paths retain the exact upstream bytes. The upstream diagnostics
documentation addition is preserved in the working source overlay as well.

An unfinished extension of the existing current-carrier native test tried to
receive a new cloud-deletion page after an actual lost TLS batch response.
Receive correctly reported that the retained send must finish first. The outer
test failed on its expected status; its successful child is not counted as a
passing overall cycle. The source-bound failed log and test extension are retained
under ignored `target/live-omarchy-acceptance/ambiguous-send-first-failed/`.
The incomplete extension is removed. Production admission rules, warning policy
and waits are unchanged. Unrelated ambiguous packets remain an open acceptance
gate; no new case or defect claim is added.

Format, shell syntax, all-target Clippy, Release harness compilation, all eight
existing preservation-owner tests and Release binaries pass on 324 native inputs.
Those inputs exactly match the previous successful live checkpoint `b33d41a6`.
The new user archive has twelve allowlisted files, matching binary hashes and a
clean rebased source receipt. Offline installation and GUI/CLI version checks pass
in an owned temporary prefix, which is removed afterward. The host installation
is unchanged. The finite seven-group board and independent GTK cancellation
blocker remain open; Stay Awake and its restoration timer are preserved.

## First-key interruption and created-library opening (2026-10-05)

The existing native creation cycle now loses the real TLS response after the
server accepts the first keys. Actual Secret Service retains the initial draft;
no installed key, checkpoint key or primary/checkpoint write is admitted. The
old account worker is observed live and then terminal before a fresh worker
reconnects. Opening the same created library leaves the exact draft and disabled
sync intact. Explicit Set Up / Resume completes with the original bundle,
recovery code, ciphertext and version, no repeat bootstrap POST and no data-plane
mutation. The original creation, encrypted sync and second-library cycle follows.

This found and fixed two concrete defects. Open Created Library used the
new-creation admission rule and refused the retained first-key draft. Completed
receipt opening now permits only the exact initial target with no installed key,
competing recipient/mutation/checkpoint state or primary/import transaction. It
retains account, receipt, scope and protected-state checks around HTTP; new
creation and data admission remain refused while setup is pending. After key
setup, recovery or pairing completes, the worker also returns fresh permission
for creating another library, so the corresponding button is not left disabled.

All three existing native creation/switch/pairing cycles pass under fatal warnings.
Thirty-eight targeted core tests pass, including one new scope/refusal regression
for the reproduced opening defect. Test count is 1,141; no runner option or
acceptance matrix is added. Both failed live runs and an intermediate unused-reply
compile error remain separately source-bound under ignored acceptance artifacts;
successful components of failed cycles are not overall passes. No warning
suppression or added wait fixes either defect.

Release is rebuilt for user testing. This is lost-response/fresh-worker evidence,
not an additional process-death or installed-restoration claim. The other named
durable gates, unrelated ambiguous packets, normal input/host lifecycle/Apple
exchange checks and the independent GTK cancellation blocker remain open. The
seven-group board is preserved; Stay Awake and its scheduled restoration remain.

## Native published switch and offline completion (2026-10-05)

The existing `--switch` cycle now interrupts its real reviewed commit after the
exact target checkpoint is published, before the first active-key replacement.
Real private Secret Service keeps the pending review and original active slots;
primary and vault bytes remain exact. The interruption is a test-only key-write
failure after actual private PAM consent, not a fabricated journal or approval.

The old account worker is observed live and terminal before a fresh worker maps
Finish Saved Switch Offline. Default Cancel, filled-password Cancel, private PAM
denial and actual credential focus loss preserve the exact pending review,
checkpoint and slots. Fresh local authorization installs the exact saved target
key and bootstrap, leaves primary/vault/checkpoint bytes unchanged and completes
the protected history without HTTP. Sync remains unavailable until explicit
reconnect and library selection. The original encrypted sync, reconnect and
reverse-switch assertions still follow; ordinary saved-history restoration also
passes with no injected interruption.

Format, shell syntax, all-target Clippy, Release harness/binaries, twelve existing
core interruption/offline tests and both native cycles pass under fatal warnings.
The test count remains 1,141. No production policy, runner option, observation wait
or acceptance matrix is added. This proves one published-switch boundary with a
fresh worker, not process death or every interruption boundary. Unpublished
cancellation and the other finite gates remain open, alongside the independent
GTK chooser cancellation defect. The user archive is refreshed from the clean
rebased checkpoint; the existing installation and Stay Awake timer are preserved.

## Native unpublished-switch cancellation (2026-10-05)

The existing `--switch` cycle now also checks its already listed offline
cancellation gate. After the original published-switch finish, encrypted sync
and reverse switch, a fresh native review uses the exact saved target key.
Actual private PAM authorizes the commit. Its test-only interruption occurs
immediately after the real pending Secret Service review is saved, before target
checkpoint publication. Active slots and primary/vault/checkpoint bytes stay exact;
no pending review, receipt, candidate, key or journal is fabricated.

The old account worker is observed live and terminal before a fresh offline
worker maps Cancel Saved Library Switch. Default Keep Saved Switch, filled
password Cancel, private PAM denial and actual credential focus loss preserve
the exact pending review, slots and file bytes without HTTP. Fresh cancellation
PAM changes only the saved entry's phase to cancelled; all earlier entries,
source/target capabilities and receipt remain exact. The source key and checkpoint
are unchanged. The native history shows the cancelled entry and active source;
explicit reconnect/selection admits that same source key for sync afterward.

Seventeen existing core cancellation/interruption/offline tests, both complete
native switch and ordinary restoration cycles, format, shell syntax, all-target
Clippy and Release harness/binaries pass on 324 frozen inputs under fatal warnings.
Count remains 1,141, with no new test, runner option, acceptance variant, production
policy or observation wait. The finite durable row removes unpublished-switch
cancellation; other interruption/candidate-pairing gates remain. The independent
GTK chooser cancellation defect and other six groups retain their status.
The user archive is refreshed from the clean rebased checkpoint; the existing
installation, user data and scheduled Stay Awake restoration remain untouched.

## Native switch-candidate pairing (2026-10-05)

The existing `--pairing` cycle now completes the already listed candidate-pairing
gate after its original two-installation approval/restart/sync assertions. Actual
native creation and first-key setup establish A beside the pre-existing B. Fresh
PAM disclosure supplies A's public-fixture recovery code to a fresh installation
through its real Recover Library Key input. It receives A through actual HTTPS
and sync, with no B key, pairing recipient or account-review history. No active
key, candidate, permit, source image or journal is written by the test helper.

That A installation selects B and maps Get Selected Library Key. Its public
invitation can be polled and cancelled without changing active A or any data-plane
facts. A new invitation survives the observed terminal old worker and a fresh
worker's reconnect. The independent trusted B installation compares the code and
authorizes its actual signed challenge through private native PAM. The peer
checks the action/hash/signature and exact library scope; invitation cancellation,
lookup, claim and approval are all scoped to the requested library.

Check Approval decrypts and retains B only in PairingCandidate. A's active slots,
primary/vault/checkpoint bytes, trusted B key/files and fetch/batch counts stay
exact. Default switch Cancel preserves that candidate. Separate fresh PAM
switches to the exact trusted B key, keeps the ordinary/vault files and records A
in protected recovery history; B's checkpoint has no A cursor, confirmations or
outbound batch. Only subsequent explicit Sync reads/writes B, preserving A's
original encrypted server record and carrying the expected content under B's key.

Format, shell syntax, all-target Clippy, Release harness/binaries, twenty-one
existing candidate tests and thirty-one creation regressions pass on 324 frozen
inputs. The complete extended pairing cycle and existing recovery-reconciliation
cycle pass under fatal warnings without GTK criticals. Count remains 1,141;
there is no new test, runner option, acceptance matrix, production policy or wait.
Earlier successful compile/live evidence is retained separately before the final
peer cancellation-scope audit. One subsequent run failed in the original ordinary
pairing test at Check Approval activation after focus returned; foreground
polling may already own or complete that same claim. Its source, log and gate receipt are retained and
excluded from successful evidence. The fixture now observes the actual in-flight
operation or already-completed claim before requesting a manual check, then
keeps the exact one-claim/key-installation assertions; there is no fixed delay. The finite durable row removes candidate pairing;
other named gates and the independent GTK cancellation defect remain open.
The user archive is refreshed from the clean rebased checkpoint; existing
installation, user data and the Stay Awake restoration timer are preserved.

## Native unrelated ambiguous packet review (2026-10-05)

The existing current-carrier Keep/Delete cycles now complete the remaining
unrelated-packet gate through their local-absence child. The native owner first
captures the public raw secure graph and confirms an unrelated ordinary record.
Its next actual Send edits that ordinary record; the verified HTTPS peer accepts
its encrypted offer and changes the real record version, then closes TLS before
sending any HTTP status/body. The retained packet has no receipt, the original
ciphertext and original CAS. No journal, packet or approval is seeded.

Actual Receive reports SendFirst and preserves the packet, inbox, primary bytes
and fetch/batch counts. Removing only the public secure primary record maps its
local-absence review through Send. Default Cancel, filled credential Cancel,
actual focus loss and incorrect recovery input preserve files and perform no
data-plane requests. Fresh vault authentication separately authorizes Keep or
Delete, materializes the disabled original and retains the unrelated packet,
its desired entry and confirmed version exactly. The next actual batch retries
that packet unchanged; real CAS reconciliation and explicit Sync confirm the
original before the secure source update. Public bodies, exact source CAS,
active key, empty pending state and terminal owned worker are checked.

Both complete native cycles pass under fatal warnings with no GTK critical.
Sixty-one distinct existing core tests pass in sixty-four executions, alongside
format, shell syntax, all-target Clippy and Release harness/binaries. Count stays
1,141; no test, runner option, acceptance variant or production rule is added.
One fixture attempt failed before the lost response because it used a stale
ordinary editor snapshot. Its source-bound evidence is retained under ignored
`target/live-omarchy-acceptance/ambiguous-native-stale-editor-failed/` and excluded;
the fixture now reads the actual saved record before editing. The older incorrect
Receive-ordering attempt remains retained separately.

The finite table now has six evidence groups. The independent GTK chooser Cancel
defect remains unresolved; no wait is added. Fresh fetch and rebase confirm the
branch still includes current main `e232c886`. The refreshed user archive carries
the clean commit and binary receipts; installed app, user data, desktop settings
and the scheduled Stay Awake restoration remain unchanged.

## Installed full restoration acceptance (2026-10-05)

The five existing host-portal restoration cycles now complete their successful
restoration through an independently installed Release GUI and its unchanged
production PAM helper: JSON, encrypted backup, retained vault plus JSON, two
JSON files and JSON plus backup. The owned temporary installation is extracted
from source-bound checkpoint `667eb56`, and all three artifact hashes are checked
before and after every cycle. The host installation remains unchanged.

The original native negative/stale-file/current-version checks run first. Its
worker is paused and drained through `prepare_quit` and its window is destroyed;
that parent worker is not claimed terminal. The installed process uses the same
private fixture bus, keyring and data root. Its original helper sees the public
PAM module only through a private `/etc/pam.d` mount. The original UID is retained,
and a private `/dev` supplies usable `/dev/null`; no host PAM policy is changed.
Only this process uses Cairo rendering and private AT-SPI. Fatal warnings remain.

Portal requests are pinned to the actual installed child PID. Public vault
credentials are entered separately through its real mapped fields, and the real
chooser's Cancel and filled PAM Cancel preserve all primary bytes, protected key
slots and the absent completion receipt. A new review and fresh native PAM restore
the entire selection. Exact success status and unavailable Send/Receive/Sync are
observed in the owned, completely traversed accessibility tree. An enabled button,
missing app, ambiguous target, traversal error or traversal limit refuses the
unavailable assertion. The installed process, bus name and executable terminate.
Original complete data/version/header/key/receipt and independent OpenSSL checks,
then a fresh native worker's actual encrypted CAS and copy-before-source sync,
remain mandatory and pass for every combination.

Format, shell syntax, the C controller with warnings as errors, all-target Clippy,
Release harness/binaries and 11 existing owner/multiple-source tests pass
on 326 frozen inputs. Test count remains 1,141; no new test, runner option,
acceptance variant or production change is introduced. Bounded readiness/completion
observations are test-only; waiting is not presented as a GTK fix. Earlier failed and
diagnostic cycles, including the private `/dev` fixture diagnosis and a successful
restoration followed by an incorrect visible-button assertion, remain separately
retained under ignored `target/live-omarchy-acceptance/installed-restore-*/` and
are excluded from whole-cycle success.

The finite board removes installed full restoration and retains five groups.
Normal host authentication and physical input are still separate checks. The
independent GTK fallback chooser Cancel race remains open. Fresh fetch/rebase
confirms `main` `e232c886`; the clean checkpoint and refreshed user archive retain
source/binary receipts. Existing installation, user data, compositor configuration
and the scheduled Stay Awake restoration are unchanged. Stable-port acceptance
remains open.

## Complete current-candidate regressions (2026-10-05)

Both existing Cargo suites pass on the same 326 native inputs as checkpoint
`2028318`: desktop library 1,055 passed/86 ignored, 26 CLI integrations and one
invalid-frame PAM-helper integration; headless library 938 passed/4 ignored and
26 CLI integrations. No failures or GTK criticals are present in their logs.
Headless output uses a separate target directory and all three production Release
artifacts retain their hashes. Counts describe executions per feature configuration;
ignored live cases are not counted as successful GUI acceptance.

The existing native `--creation` case also passes again on this exact source,
including accepted-but-unanswered first-key TLS upload, exact retained key/recovery
capability, terminal old worker and fresh same-key continuation without another
POST, followed by its complete creation and encrypted-sync assertions. Native
inputs, tests and runner options are unchanged; no acceptance variant is added.

The current implementation table and summary now agree with the saved successful
native pairing, switch, ambiguity and full installed-restoration receipts. This
does not close other keyring-write interruption scope or the five remaining groups.
The GTK fallback Cancel defect remains independently reproducible and unresolved;
bounded observations are not a fix. Source-bound logs and gate details are retained
under ignored `target/live-omarchy-acceptance/candidate-full-*`. The refreshed user
archive is verified offline against its clean commit; the host installation and
scheduled Stay Awake restoration are preserved.

## Current user-prefix installation (2026-10-05)

The normal launchers were still pointing at three older Release artifacts despite
the newer checked user archive. The stock installer now updates `~/.local` from
that exact `04fdfb2` archive without rebuilding. All three installed ELF hashes,
sizes, owner/single-link layout and mode match the verified payload; both symlink
launchers resolve to those files and report version 0.1.0. Previous program and
application-metadata files are retained privately for rollback. Installation uses
the existing atomic file replacements, with no running primary.

The installer writes executable/desktop/icon/metainfo files and does not open the
library, alter preferences or enable autostart/sync. Host library/config metadata
was compared only in memory and remains exact; no library contents or credentials were read. Record names/IDs, paths, ciphertext,
credentials and their stable hashes were not logged, exported or persisted.

The unchanged existing installed multiple-file chooser Cancel case now runs on
the actual updated `~/.local` GUI. Its private bus, keyring, data/config/cache and
accessibility registry remain isolated. With fatal warnings, the actual Cancel
button closes the chooser, focus returns to Account & Recovery, the process exits
normally and exact private primary/vault/history bytes stay unchanged. No native
source, test, runner option or acceptance variant is added. The two-second existing
observation follows Cancel; it is not a GTK race workaround.

The archive's clean source remains `04fdfb2`; the documentation checkpoint records
this local deployment separately. Earlier archive and installation-preservation
receipts remain historical and are not rewritten. The five bounded groups and
independent GTK fallback cancellation race stay open. User data, compositor
configuration and the scheduled Stay Awake restoration are preserved.


## Pairing after a losing first-key candidate (2026-10-05)

Review of the remaining interrupted empty-target setup found a concrete UI defect:
a failed setup leaves the candidate Sent and disables pairing; if Resume then
finds another device's winning authority, the candidate becomes Lost but the
pairing button stayed disabled. The displayed instruction to get the winning key
could not be followed without reselecting or reopening the library.

The worker now includes the selected library's independently retained pairing
status in its existing setup reply. Native controls apply that status before the
first-key status, so Owner/Writer can request the winning key while Reader, an
existing unfinished invitation and unreadable pairing state remain unavailable.
Sent/Ready first-key candidates still disable new pairing. Active keys, local
records, sync admission and the separate reviewed switch are unchanged.

The existing native account-controls test fails at Sent -> Lost before the fix
and passes afterward with fatal warnings on a private bus and private XDG roots.
Its regression covers those role/pending/error refusals and keeps Send/Receive/Sync
unavailable. No new test, runner option or general acceptance variant is added;
only this reproduced defect extends the existing controls gate. Related candidate
tests, all-target desktop/headless Clippy, the existing complete native switch
scenario and Release compilation qualify the update. A headless lint failure also
identified a desktop-only test interposition helper with an overly broad cfg; it
is now compiled only for desktop tests, without suppressing the lint.

The replacement user archive is built from the clean rebased checkpoint and the
stock installer updates the normal user prefix, retaining code-only rollback
files. Source/build/install receipts identify its exact artifacts. Earlier full
desktop/headless and five installed restoration runs remain evidence for their
recorded artifacts; they are not relabeled as full runs of this UI change.
The five remaining groups and the independent GTK chooser cancellation defect
stay open. No waiting or error suppression is a fix for that GTK defect.

The actual updated normal-prefix GUI also passes the unchanged existing fallback
chooser Cancel case with fatal warnings, parent focus return and exact private
primary/vault/history preservation. This requalifies that installed cancellation
case; the Sent -> Lost regression above runs in the native Release harness.


## Unreadable first-key status and pairing (2026-10-05)

The losing-candidate refresh exposed one error transition: after Sent, an
unreadable first-key status plus an empty pairing status enabled a new key
request. The backend already refused it; the screen now keeps the request
unavailable until setup history can be read. Invalid history and unavailable
Secret Service both stay closed, while a later verified Lost result still
allows the winning-key request with the existing role/pending/error checks.

The same native controls test reproduces this defect before repair and passes
afterward on private bus/XDG roots with fatal warnings. Two existing backend
refusal tests, all-target desktop Clippy, format and Release compilation cover
the changed UI layer. No backend, headless source, test count, runner option or
general acceptance variant changes. Updated archive/install receipts identify
the candidate; the normal installed fallback Cancel case is requalified on it.
The five remaining groups and the independent GTK chooser Cancel race stay open.

## Native dependency fixes and remaining acceptance (2026-10-05)

The user-test runtime carries the GTK path-bar cancellation ownership repair
and a separate libadwaita alert-heading minimum-size repair. Both have minimal
before/after reproductions with fatal warnings. Neither adds a wait or suppresses
warnings. GTK's resource paths and optional native integrations match the current
Omarchy host; the earlier `/usr/local`, file-print-only build remains historical.

The GUI loads both libraries through its relative ELF RUNPATH. The installer
checks the complete manifest, regular files and library SONAMEs before switching
executables. Source archives, patches, licenses and rebuilding instructions are
included. Python and Cargo are not needed for the installed product. System
libraries and the external portal remain unchanged.

The remaining acceptance is finite:

1. Normal Omarchy configuration: physical shortcuts, focus, paste and inline
   expansion in the intended receiving applications; current live checks use
   Hyprland Safe Mode.
2. Real PAM/keyring authentication, hardware sleep and a fresh login/autostart;
   private or simulated checks do not close those observations.
3. The already listed remaining key-setup/switch interruption boundaries;
   earlier successful native restoration and interruption receipts keep their
   source and binary bindings.
4. Physical input and accessibility checks for clipboard history.
5. Round trips with actual Apple app JSON and encrypted backups.

The independent system GTK race still needs an upstream/system dependency fix.
The bundled ownership repair covers the app's fallback chooser. New variants
are added only when a concrete defect is found, as with the alert-heading case.
