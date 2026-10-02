# Snippets for Omarchy

Native GTK 4 / libadwaita desktop app and CLI, written in Rust. Python is not needed
to build, install or run the application. It is used only by development tools
that regenerate checked-in reference fixtures. The client handles ordinary local entries
and an encrypted vault workspace; [the full desktop port remains in development](../docs/linux/IMPLEMENTATION.md).

## Build and install

On Omarchy, install missing build and native runtime packages:

```sh
omarchy pkg add rust gtk4 libadwaita icu libsecret pam qrencode wayland wayland-protocols pkgconf base-devel
```

Requirements: Rust 1.92+, GTK 4.12+, libadwaita 1.5+, ICU, libsecret 0.21+, Linux-PAM,
libqrencode 4.1+, Wayland and wayland-protocols with the ext-data-control-v1 XML. Cargo dependencies
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

## Library

- Start empty, create entries, or import a Mac/iOS **Export for Sharing** file.
- Changes autosave after 600 ms. Ctrl+S saves immediately.
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
synchronization is implemented; complete conflict-owned deletion recovery remains pending. Saved local
changes can now be reviewed and restored from library-switch history.
Remote deletion of materialized conflict originals can now be reviewed while
retaining original requests and later local edits. Protected repairs require the
matching vault's passphrase or recovery key. Missing originals and unresolved
conflict carriers still need further recovery support.

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
presentation/confirmation are now wired to the app; their live combined workflow
still needs verification. Signed approval/recovery operations now retain their
candidate and original proof in Secret Service and have native review/authorization
actions. A bounded inbound owner now saves each authenticated page and its cursor
in one encrypted checkpoint, applies records in server order, and resumes retained
pages after a crash. Native **Sync Now** coordinates receiving and sending; the
separate **Receive Cloud Changes** action remains available. Saved local changes
have native restoration controls, including archived nested conflict groups and
restoration beside current pending groups and ordered archived generations.
Restoring archived secure records into a different vault remains pending. Startup stays offline unless automatic
sync was explicitly enabled for a verified saved library.

## Account and library recovery

Open **Account & Recovery…** from the menu. Opening the window reads saved account
metadata without making an HTTP request. Enter your HTTPS Snippets Cloud server
and email, request a sign-in code, then verify it. **Reconnect Saved Account**
refreshes the retained session and lists existing libraries. Account and keyring
operations run in one worker outside the GTK thread. Closing the window preserves
worker ownership; quit remains unavailable during an in-flight operation or while
a session or pairing response needs secure storage. **Retry Secure Storage**
retains that response before another account operation can proceed. Key operations
check that live credentials still match the committed account and token generation.

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
checkpoint and makes no network request. The combined live GTK/keyring/HTTPS
automatic workflow still needs verification.

Select an existing library, then explicitly set up/resume its keys or supply its
offline recovery code/QR payload. Library selection does not mint a key. A changed
account or library requires explicit review before its keys can replace retained state.

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
password. Secure changes also need the matching vault's passphrase or recovery key.
Current records remain; changed current versions are kept as disabled preservation
copies. Historical tombstones do not delete current records. The operation creates
fresh local edits and keeps the current synchronization journal's server facts.
It contacts no server and never reactivates archived keys or cloud cursors.
Archived conflict groups restore together. Their exact original preservation
copies remain separate from later edits, including encrypted copies. Subsequent
sync saves nested versions before the original copy, confirms the parent, then
sends the edited copy. Historical acknowledgements and CAS versions are not reused.
When current conflict groups are still pending, their original sends finish first.
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
Restoration refuses incompatible vaults and historically deleted conflict participants;
it never applies an ordinary-only subset of a secure restoration. Conflicting
keywords require a separate review. Restoration history is bounded to eight receipts
and 128 KiB; encrypted file images share the existing 32-file/512-MiB budget, with
no automatic eviction. Pending restoration generations are also capped at eight;
capacity exhaustion preserves the existing queue. Restoring multiple saved generations
also uses this budget; a proposal that cannot fit changes no library files or keys.
Capacity management, recovery of deleted conflict copies, and restoration of
archived secure records into a different vault remain unfinished. The combined native GTK/keyring/PAM
workflow still needs live verification.

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
the retained sealed body without revealing it or replacing key material. Missing
whole library/vault files, missing preservation originals, and secure records
that still carry unresolved conflict evidence
require separate recovery; this action cannot approve a mass deletion.

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

Account/key replacement, conflict-owned deletion recovery
and some secure conflict recovery remain unfinished. Missing primary files stop
sending; they never become cloud deletions. Receiving does not send this
computer's local changes, and a connected account or verified key does not mean
snippets have synchronized. The combined live GTK, keyring and HTTPS workflow,
including Sync Now, receiving, sending, snapshot/deletion review, pairing and signed operations,
remains unverified. The startup-recovery UI also needs a live graphical check;
its core crash/restart and file-access checks use only temporary data.

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
resolved from durable state. This account/recovery interface compiles, but the
current restricted environment cannot initialize GTK for its new lifecycle smoke
test, so its live focus/password/confirmation workflow remains unverified.

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
and unsaved secure drafts are preserved. Live cross-platform application tests
have not run.

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

The body editor retains ciphertext rather than a GTK text buffer. It currently
supports typed Unicode, keyboard caret movement, Backspace/Delete, newlines and
tabs; it has no text selection, clipboard operations, drag, text undo, or body
extraction through accessibility. Revealed pixels can still be captured by the
desktop, and input methods/font libraries are outside Rust's memory-erasure
guarantees. Rendering uses transient Pango layouts and zeroes owned Rust buffers.

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

Direct secure insertion and restoring archived secure records into a different
vault remain unfinished.

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

The storage, cancellation and privacy tests pass; the backend and GTK view compile.
The private libwayland-server protocol fixture cannot create its client in the
restricted test environment, and the GTK fixture cannot initialize a display.
Background acquisition and the interactive history workflow still need an
unrestricted, unlocked Hyprland verification. Other Wayland compositors require
ext-data-control-v1 support and the current Hyprland session/source checks.

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
Image and rich-text formats are not preserved. Compositor acknowledgement cannot
prove an application accepted paste; the live receiving-field check remains open.

The app rereads Omarchy's active XDG state `colors.toml` every two seconds. Colors
are validated before CSS generation; light/dark mode follows the palette. No theme
files or hooks are changed. Other desktops use standard libadwaita styling.

Closing the main window saves and hides it. The application stays alive for
activation and clipboard ownership; Ctrl+Q or `snippets --quit` saves and quits.

For a global shortcut on current Omarchy, choose an unused key after checking
`omarchy menu keybindings --print`, then add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + S", "Snippets", "snippets")
o.bind("SUPER + ALT + P", "Snippets picker", "snippets --picker")
```

Validate config edits with `hyprctl reload` and `hyprctl configerrors`.

## Keyboard commands

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

Commands return JSON; errors use a nonzero exit status and safe stderr messages.

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

## Verification

```sh
cargo test --locked --manifest-path snippets-linux/Cargo.toml
cargo test --locked --manifest-path snippets-linux/Cargo.toml --no-default-features
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib ui::tests::native_lifecycle -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib ui::tests::native_picker_without_editor -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib secure_ui::tests::native_secure_lifecycle -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib secure_ui::draft_recovery::tests::native_recovery -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib ui::history::tests::native_disabled_history -- --ignored --test-threads=1
# Private socket-pair compositor; requires unrestricted Wayland peer credentials.
cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib clipboard_history::wayland::protocol_tests::private_libwayland -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib account_ui::tests::native_account -- --ignored --test-threads=1
G_DEBUG=fatal-warnings cargo test --locked --manifest-path snippets-linux/Cargo.toml \
  --lib backup_ui:: -- --ignored --test-threads=1
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
keyring, PAM, clipboard or account. These fixtures do not establish a live
keyboard/reveal or credential-dialog workflow. The separate live
paste test requires an unlocked session before any clipboard change or input.
The latest completed receiving-field verification remains open; an unlocked
attempt exposed a teardown warning, and the retry stopped at the locked-session
preflight. The picker-only teardown regression passes independently. The test guards
the fictional target, refuses non-text clipboards, and restores prior text.

Local-owner tests exercise libpam against a disposable private policy and a
public fictional password module. They cover incorrect passwords, account
restrictions, changed identity, refused conversations, cancellation and timeout
without accessing authentication databases or the host PAM policy. The installed
helper is tested only with malformed requests that cannot authenticate a real
account. The account-window lifecycle fixture injects its worker and authorization,
uses only public visual/input material, and never accesses a real keyring, account,
PAM service or server. It must run on the normal host bus, separately from the
keyring harness; its current restricted-context run cannot initialize GTK.
The independent QR reader test uses public payloads and explicitly disables
zbar's D-Bus publication. Recovery-disclosure/confirmation tests use an explicitly synthetic proof;
they cover suffix normalization, secret retirement, schema migration and both sides
of an interrupted write. They do not
establish an interactive password-dialog workflow. See the
[implementation evidence](../docs/linux/IMPLEMENTATION.md) for current test counts
and authorization limits.

The native Secret Service fixture requires GNOME Keyring, `dbus-run-session`,
`gdbus`, and `rg`. After building library tests, invoke
`bash snippets-linux/tests/secret-service.sh /absolute/path/to/library-test-binary`.
Choose the desktop-feature library test executable containing
`secret_store::tests::native_backend_fixture`, not the app or CLI executable.
The harness creates a private D-Bus, runtime directory and disposable keyring;
it tests binary values, replacement, deletion and locked-keyring refusal. It
does not initialize GTK or touch the desktop keyring. Run native GUI fixtures
on the normal desktop bus, separately from this keyring harness.
