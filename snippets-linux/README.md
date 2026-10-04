# Snippets for Omarchy

Native GTK 4 / libadwaita desktop app and CLI, written in Rust. Python is not needed
to build, install or run the application. It is used only by development tools
that regenerate checked-in reference fixtures. The client handles ordinary local entries
and an encrypted vault workspace; [the full desktop port remains in development](../docs/linux/IMPLEMENTATION.md).

## Build and install

On Omarchy, install missing build and native runtime packages:

```sh
omarchy pkg add rust gtk4 libadwaita icu libsecret pam qrencode wayland wayland-protocols libxkbcommon pkgconf base-devel
```

Requirements: Rust 1.92+, GTK 4.12+, libadwaita 1.5+, ICU, libsecret 0.21+, Linux-PAM,
libqrencode 4.1+, Wayland, libxkbcommon, Cairo/Pango and wayland-protocols with the ext-data-control-v1 XML. Cargo dependencies
are locked in `Cargo.lock`. The GUI links to the installed native GTK libraries.
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
and export checks use temporary roots; the native controls and actual system-log
mirror still need a live desktop check.

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
metadata without making an HTTP request. Enter your HTTPS Snippets Cloud server
and email, request a sign-in code, then verify it. After an incorrect code, enter
the correct code for the same challenge and try again. **Reconnect Saved Account**
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
choice. Unknown pending raw-child decisions, local-absence source review and
unrelated ambiguous packets remain separate checks.

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
Unknown pending raw-child decisions, local-absence source review, unrelated
ambiguous packets, pairing and signed operations remain under live acceptance. The native interrupted-startup recovery fixture passes with temporary
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
private native keyring. Pairing, library switching and complete sync still need
combined live acceptance.

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
draft, and Ctrl+L locks the vault. Secure entries use explicit Save; they do not
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

Open **Inline Expansion…** from the app menu and choose **Enable Expansion…**.
The confirmation explains which nearby text Snippets reads. Expansion is disabled
by default; the setting belongs to this library. The window shows whether the
handler is waiting for an unlocked desktop, a compatible field, or a connection.
**Disable Expansion** immediately cancels its worker. **Retry Connection** starts
a fresh connection after the previous worker finishes.

Type `\keyword` in a compatible public field. Only a newly extended, unique
enabled ordinary keyword expands; enabled longer prefixes or duplicate keywords
prevent replacement. Initial activation establishes a baseline. Password, PIN,
sensitive, selected and unrecognized fields are excluded. The compositor must
support input-method-v2 and have an unused input-method seat; Snippets does not
evict another input method. Some applications do not provide the required
surrounding-text updates. Exact-only expansion does not grab the hardware keyboard.

Choose **Enable Suggestions…** separately to show up to eight ordinary names and
keywords near the caret after `\`. Prefix and fuzzy name/keyword matches use
matched-letter highlights, pins and a frozen local usage ranking. Use ↑/↓ or
Ctrl+N/P to move, Return/Tab to insert, Shift+Tab to move backward, and Escape
to dismiss the current trigger. Secure entries never enter this popup. A selected
entry is reread before preparing the same echo-confirmed replacement.

Suggestions use the compositor's native input-popup surface without switching
to a Snippets window. While visible, the popup temporarily grabs the keyboard
and forwards other raw keys and modifiers through a virtual keyboard on the
same verified connection, using the compositor-provided XKB map. Stale rows
cannot authorize selection. **Disable Suggestions** releases this owner before
returning to exact-only expansion. Legacy expansion consent leaves suggestions
disabled; enabling them has its own Cancel-default confirmation.


Replacement uses native UTF-8 text commits without changing the clipboard.
`{clipboard}` reads only a requested plain-text selection, bounded to 256 KiB and
two seconds; placeholders render once. Output also fits 256 KiB and is sent in
bounded chunks, each followed by a confirming field update. Snippets checks the
saved record and destination and stops on detected cancellation, lock, changed
files or uncertain acceptance. An interruption may leave a prefix. Focus checks
cannot make replacement atomic on Hyprland; text can reach another field during
a focus race. Check the destination before retrying. Interrupted text is never
retried automatically. Snippets windows are excluded from this path.

The native bridge, popup renderer, raw-key passthrough, selected-entry guards and
private protocol exchanges are verified in isolation. Popup buffers and queued
keys are bounded. The unrestricted Omarchy session also passes peer authentication,
native settings and three independent GTK receiving-field checks: exact keyword
expansion, suggestion selection with Return and replacement containing another
keyword without recursive expansion. These use native injected keys; compatibility
with other receiving applications and physical keyboard assignments remains a
separate check. Secure snippets use the separate authenticated picker insertion.

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
after successful delivery, using the same fresh authentication as before. This
does not prove a receiving application consumed input; live delivery remains
unverified.

Open **Suggestion Learning…** in the main menu to control frequency ranking and
prefix memory separately, reset either history, or reset both. Both controls
default to on. Disabling frequency ranking keeps counting use. Disabling prefix
memory erases saved choices and stops collecting them. Storage failures are shown
in that window; protected or unsupported files are preserved.

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
halt and in-flight-disable checks. Pairing, switching and remaining native
interactions are still under review.
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
The separate combined account fixture uses the real serial account owner and
native Secret Service backend on its own bus and data root. It exercises mapped
GTK response buttons against a certificate-verified loopback server, with exact
fixture-CA trust scoped to its worker thread. The ordinary constructor rejects
that certificate before and after the scenario. Its private PAM policy uses the
production helper protocol and libpam with a public fictional password module;
it never reads the host authentication database. The check covers wrong-code
retry, explicit selection of the first/only library without implicit key creation,
key setup, recovery cancellation/wrong-password refusal, focus revocation, fresh
authorization and confirmation, new-worker reconnect and sign-out. Both workers
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
does not initialize GTK or touch the desktop keyring. Run native GUI fixtures
on the normal desktop bus, separately from this keyring harness.
