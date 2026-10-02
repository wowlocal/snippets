# Native Omarchy desktop port

The objective remains a native Omarchy version of Snippets. The Linux implementation
is now Rust with GTK 4 / libadwaita. The ordinary-library app and CLI have been ported
from the initial prototype; Python is no longer needed to run, build, or install them.
Apple targets and shared Swift sources are unchanged.

This intermediate checkpoint includes unfinished authenticated deletion-group
recovery for selected sources that retain unresolved conflict carriers. Its latest
focused run passed two tests and failed the WAL/delivery matrix: deleting an
unstaged current source after an incoming remote deletion remains blocked with
`PreservationRequired` after one submitted batch. This path is work in progress;
the complete test, Clippy, Release and installer results below describe the
preceding source-recovery milestone and have not been rerun for this checkpoint.

## Architecture

`snippets-linux/` is an independent Cargo package with a locked dependency graph.
`src/model.rs` owns portable JSON, validation, search, durable storage, record-level
conflict checks, and ordinary undo/redo. `src/bin/cli.rs` uses the same model; build
with `--no-default-features` to omit GTK. `src/ui.rs` owns native widgets, keyboard
actions, asynchronous clipboard/file dialogs, and single-instance activation.
`src/desktop.rs` reads the Omarchy palette, guards short-lived Hyprland targets,
and observes session locks off the GTK thread. `src/crypto.rs`, `src/vault.rs`, and
`src/clock.rs` implement encrypted bodies, bounded owner sessions, durable vault
edits and logical clocks. `src/secure_ui.rs` owns the native vault workspace;
`src/protected_editor.rs` keeps drafts encrypted without a GTK text buffer.
`src/draft_recovery_ui.rs` recovers a retained draft after a foreign vault
replacement. The current vault must already be unlocked; a worker separately
authenticates the captured previous wraps and the current wraps with passphrase
or recovery input. It authenticates the original draft AAD, checks the bounded
UTF-8 body and reseals it under the current key with a fresh UUID and no saved
ancestor. Keys and plaintext never enter the worker reply, which has no Debug
or serialization interface. Publication requires the exact retained source,
current identity/session generation and unchanged UI metadata. Only the volatile
editor is replaced; a separate Save checks keyword and record collisions. The
original survives wrong credentials, revocation, stale files and recovery fences.
The dialog clears both fields on cancellation, focus loss, lock or expiry;
authorization lasts at most 120 seconds with wall and suspend-aware clocks.
Quit cancels and waits for the worker. Recovery does not extend the live vault's
idle deadline, persist a draft or restore archived foreign-vault records.
`src/backup.rs` implements the portable Apple schema-1 encrypted-backup codec.
`src/backup_export.rs` captures both saved primary files under their common lock,
uses fresh one-use vault authentication without an editor session, seals metadata
and ordinary data together with unchanged secure ciphertext, removes local C0
receipts and validates exact before-images before atomic private output.
`src/backup_ui.rs` wires native destination/password/recovery dialogs to that
owner off the GTK thread. A revocable desktop/focus/expiry capability is checked
after authentication/encryption, after the publication-lock wait and before rename;
quit cancels and waits for a secret-owning worker. `src/backup_import.rs` implements
reviewed ordinary ID/keyword upserts and secure ID merges into a matching vault,
with fresh key equality authentication and preservation of local unlock doors.
Creating a vault establishes a new local passphrase from the authenticated
backup key without changing its record seals or portable recovery wrap. Indexed
upserts preserve sequential ID/keyword precedence and front-insertion order.
Ordered local HLCs for the whole batch are reserved with one durable clock write.
Full before/after images are length-framed, encrypted under a fresh per-import
key wrapped with the backup password, and published as the private recovery
fence before either file changes. A separate random local identity binds this
redo to its data root. Replay authenticates the journal before primary reads and
accepts only exact original or final images; it never overwrites unexpected edits.
`src/backup_import_ui.rs` keeps the decoded library and vault key in a worker
across native confirmation, returning only counts/authentication requirements.
**Restore Encrypted Backup…** and **Resume Backup Import** are wired, including
startup gating, field clearing and quit cancellation. The authenticated codec
never returns partial content or exports a raw key. Independent OpenSSL reference
and reverse-decoder checks pass; live native dialogs remain unverified.
`src/canonical.rs` and `src/wire.rs` implement the frozen encrypted sync record
format. `src/cloud.rs` handles the native HTTPS protocol without library keys or
snippet plaintext; the account/recovery UI uses it. `src/inbound.rs` and
`src/receiver.rs` now implement a bounded durable receiving owner, wired to an
explicit native action. `src/outbound.rs` and `src/sender.rs` add exact encrypted
batch retention, positional durable receipts and conflict preservation, wired to
explicit native sending. `src/snapshot_review.rs` owns explicit review of a complete
snapshot which omitted known records. Its native confirmation binds the exact
checkpoint and primary view, keeps current/journal-only intent and immutable C0,
clears old cursors/CAS/acceptances atomically, and requires a new snapshot before
sending. `src/deletion_review.rs` implements explicit one-record deletion/restore
decisions, bound to exact checkpoint/primary views and published with the primary
images and receipt position through one encrypted WAL. `src/sync.rs` coordinates
bounded bidirectional cycles, retained-send/inbox ordering, post-upload receiving
and fresh primary/feed admission before a completion result. Its native **Sync
Now** action uses the same serialized credential/key owner. `src/account_review.rs`
implements encrypted journal retention and exact scope-reset receipts; its native
`src/account_handover.rs` owner retains old capabilities and the verified target
key in Secret Service before journal publication, gates normal key/data operations,
and finishes interrupted activation from the exact receipt. Native worker commands
and review/resume/cancel/offline-finish controls are connected. Exact-purpose local authorization
guards confirmation and continuation; offline cancellation preserves later local
edits before journal publication. `src/pairing_candidate.rs` obtains a target key
through trusted-device pairing into a separate protected history, without installing
it or creating a checkpoint. Native request/check/cancel, public QR/copy, retained-response
ownership and subsequent explicit library review are connected.
`src/bootstrap_candidate.rs` retains first-key/recovery intent for an existing empty
target separately from old active keys, resumes the same server operation and carries
the ready candidate into explicit library review. Native create/resume controls are
connected. Review-only key reuse now supports account/membership/dataset/epoch changes
within the same server instance and library, including durably claimed pairing and
sent first-key candidates whose verification was interrupted. It refreshes authority
and recovery evidence, preserves original candidate pins/proofs, and requires new
exact review and local authorization. `src/account_local_finish.rs` can finish an
exact already-published transition locally after account or server changes, without
remote credentials or data-key admission. `src/key_history.rs` now supplies a
read-only catalogue of retained switches, pairing requests and first-key setup;
native **Library Recovery History…** displays bounded metadata and authenticates
frozen encrypted states. `src/history_restore.rs` now owns native restoration of
saved local changes, with exact fresh authorization, full encrypted redo images,
current-version preservation and offline finish/cancel. Archived live nested conflict
groups now restore together with exact original C0 evidence and selected C1 intent.
Restoration can queue new ordinary and matching-vault generations behind current
conflict-owned groups without changing their offers or proofs, and restores an
archive's pending generations in order. Protected capacity management, creation
of a new library beside old keys and conflict-owned deletion recovery
remain unfinished.
`src/bootstrap.rs` implements portable key bundles, pairing/recovery cryptography
and library-action authority. `src/cloud_bootstrap.rs` adds scope-bound authority
and recovery reads plus the server's atomic first-key bootstrap operation.
`src/cloud_actions.rs` handles pairing lifecycle, validated key challenges and
immutable signed recovery/approval requests with explicit secure journal encodings.
`src/merge.rs` preserves independent field edits and losing ordinary/secure bodies.
`src/journal.rs` and `src/journal_codec.rs` provide immutable offers, original CAS,
copy-before-source receipts and an atomic encrypted Linux checkpoint.
`src/projection.rs` preserves remote clocks, dates and extensions across primary
file round trips. `src/primary.rs` journals encrypted before/after images before
updating either library file and repairs interrupted updates.
`src/materializer.rs` authenticates secure conflict snapshots, reseals their bodies
under each copy UUID and preserves exact C0 evidence separately from later edits.
The vault owner can borrow its bounded session key for a primary-apply plan without
copying the key or extending its idle deadline. `src/secret_store.rs` owns opt-in
Secret Service slots and the independent process mutex; `src/secrets.c` binds
the stable libsecret API without keyring prompts or plaintext D-Bus fallback.
`src/auth_store.rs` journals credential lineage and provides worker operations
for native sign-in, refresh, sign-out and restart cleanup. Offline live-session
validation checks the committed account/deployment/token generation before and
after native key operations. Its
`src/space_creation.rs` worker retains one explicit creation intent and its original
idempotency key before HTTP, then saves the account-bound library receipt before
publishing it. Subsequent key admission checks that receipt before generating or
loading a key. `src/key_store.rs`
journals first-key setup and recovery in Secret Service, verifies the immutable
server authority before activation, and retains the recovery capability across
interruption. Its `src/pairing_store.rs` recipient worker retains the private
draft before creation and the claimed envelope before key installation, with
durable cancellation and sealed ownership of unrecorded responses.
`src/key_mutation.rs` retains recovery/approval candidates before nonce requests,
then journals their original signed request before any send. It consumes fresh
local authorization, rechecks it after waits and at the final HTTP send boundary,
saves acknowledgements before post-send scope checks, and reconciles exact recovery
envelopes without resending. `src/auto_sync.rs` implements explicit per-library
consent, protected target pins, revocable cycle tickets and bounded scheduling.
The account worker reconnects only the exact saved account/deployment/library and
verifies membership, dataset and key epoch before the data plane. It never lists
libraries to choose a default, generates keys, or accepts a review automatically.
Account refresh checks the pinned account under the credential lock and retains
issued grants despite cancellation. Key verification fences each remote operation;
data cycles use the existing session guard and encrypted receipt/journal owners.
Periodic, foreground and local-edit wakes share the same serialized worker, with
retry backoff and a quit admission barrier. The native toggle remains usable to
disable synchronization while account controls are busy. Only primary GApplication
startup starts this owner; secondary command invocations cannot start a second one.
Absent/off consent remains entirely local. `src/account_worker.rs` serializes native sign-in, reconnect,
sign-out, retained issuance, library creation/selection, cloud receiving/sending, pairing and key/recovery operations off the
GTK thread. It owns unrecorded sessions and pairing responses across window dismissal and prevents normal
quit until outstanding work and required secure storage finish.
`src/local_auth.rs` implements fresh native owner authentication and a single-use
process-local gate. Its installed `snippets-owner-auth` subprocess uses the small
`src/owner_auth.c` Linux-PAM adapter, without elevated privileges.
`src/recovery_disclosure.rs` consumes an exact permit after revalidating the saved
recovery presentation and remote authority/envelope. `src/account_ui.rs` now wires
native account/password dialogs, recipient pairing, trusted-device approval,
recovery replacement, library-switch review/resume/cancellation/offline completion, empty-target first-key
creation/resume, focus/lock cancellation, QR/code rendering and
saved-code confirmation to these workers; the new live UI workflow remains
unverified because GTK initialization fails in the restricted environment.
`src/recovery_qr.rs` uses the installed libqrencode ABI, keeps module buffers
zeroizing, and never rasterizes production recovery material to disk. Public pairing
invitations have a separate view and explicit clipboard action. `src/pairing_ui_state.rs`
bounds display and polling by both wall time and suspend-aware monotonic time;
status refreshes cannot restart an invitation's lifetime. The disclosure worker also
confirms a saved-code suffix, removes exact promoted mutation, first-key candidate
and handover target copies while preserving original source capabilities, then
atomically replaces the presentation secret with bound verification metadata.
The bootstrap journal writes schema 2 and migrates schema 1
only after validating its kit, installed key and fresh remote authority.
`src/placeholders.rs` uses a small C adapter compiled against the installed ICU
headers to preserve the native date-format grammar and versioned ABI.

The Linux data root follows XDG conventions and starts empty. Import preserves
ordinary UUIDs, flags, tags, and Foundation dates. It does not reinterpret Apple's
keychain or CloudKit checkpoints. Locked-vault metadata reserves identifiers and
keywords, including during imports and undo. Tests use temporary directories.

## Current evidence and remaining work

| Area | Rust implementation | Verification / next work |
| --- | --- | --- |
| Native workspace | GTK list/editor, search, tags, pins, autosave, keyboard actions and gated startup recovery | Earlier native lifecycle smoke passes with fatal GTK warnings; recovery crash/access checks pass, new recovery UI compiles and needs a live display check |
| Library | CRUD, bounded/strict JSON, file permissions, process lock, atomic replacement, CAS conflicts, undo/redo | Rust core and concurrent CLI writer tests pass |
| Transfers | Native and Raycast JSON import, ordinary sharing export and native portable encrypted-backup export/import with interrupted-import recovery | Round-trip, timestamps, collisions, exact-key authentication, encrypted two-file redo, cancellation and independent OpenSSL backup format checks pass; live native dialogs and Apple app round trips remain unverified |
| Placeholders | Native ICU date/time formats, one-pass clipboard, locale, calendar offsets | Fixed-date, month-end, literal grammar tests pass |
| CLI | Ordinary mutations/get/import and combined metadata catalogue | Concurrent writer and secure output/refusal tests pass |
| Omarchy theme | Active XDG state palette, periodic refresh, validated colors | Parser and CSS injection tests pass |
| Paste picker | Native picker, captured address/process, Lua focus/paste, terminal chord, text clipboard lease | Target validation tested; actual cross-window delivery still requires verification |
| Installation | Rust release GUI/CLI and private PAM helper, user-prefix installer, desktop actions, icon, metadata | Build, temporary-prefix installation, metadata validation |
| Library recovery history | Native catalogue and reviewed restoration of saved local changes, archived deleted/missing conflict participants and queued generations; authenticated materialization of missing secure originals, separate original C0 and selected C1, current-version preservation, bounded protected receipts, encrypted full-file redo, fresh-purpose offline completion/cancellation | Isolated owners cover strict-CAS delivery ordering, stale frames/files, old/current scopes, interrupted writes and lost replies, exact current offers/CAS/feed, tampering, vault seals, retention and generation refusal; foreign vaults and capacity management remain pending; live native GTK/keyring/PAM verification remains unavailable |
| Secure snippets | Native setup/unlock/recovery/password change, encrypted draft editor, foreign-vault retained-draft recovery, save/delete, idle/hard/sleep/desktop locks | OpenSSL fixture, tampering, recovery, CAS, hash, metadata-only CLI and draft tests pass; native secure lifecycle smoke passed earlier; current recovery dialog compiles but display initialization is unavailable; live keyboard/reveal workflow remains open |
| Secure delivery and transfers | Native portable encrypted-backup export/import with authenticated codec and encrypted redo | Fresh vault authentication, metadata encryption, preserved record seals and exact snapshot checks pass; direct insertion without clipboard exposure, archived foreign-vault restoration and fuller editing/accessibility review remain pending |
| Cloud protocol | Rust HTTPS discovery, native email/session endpoints, scope/epoch admission, changes pages and record CAS batches; canonical encrypted wire records; explicit native Sync Now, receiving/sending, missing-snapshot review, deletion/restore and reviewed switching wired | Earlier real loopback HTTP tests, independent OpenSSL/Swift formatter vectors and isolated bidirectional cycle tests pass; current environment cannot run loopback fixtures or initialize the new GTK smoke; complete conflict-owned recovery and live automatic workflow verification remain pending; CloudKit is Apple-only |
| Conflict absence and deletion review | Ordinary source/copy decisions, vault-authenticated protected-copy restoration, reviewed materialization of missing secure originals for selected copies and sources with resolved selected intent, disabled preservation of distinct held source versions, explicit missing-copy counts, remote prerequisite deletion repair, exact current originals/offers, ordered later intent, complete encrypted redo and a native passphrase/recovery prompt | Strict CAS, five WAL interruption phases, lost replies, original versus later nonces, retained receipt ordering, C1 preservation, corruption, reserved collisions, vault identity and expired-session checks pass; selected unresolved carriers and independently unresolved or unapproved missing child intent still need group recovery; live password-dialog verification remains open |
| Library-key setup | Portable sync-v1 bundle, P-256 pairing, recovery QR/code and envelope, Ed25519 authority/proofs and request hashes; bound control-plane HTTP; durable first-key, recovery, recipient activation and signed mutations; native setup, recipient pairing, trusted-device approval, recovery replacement, disclosure, library-switch review/resume/cancel/offline finish and empty-target first-key UI wired | Independent vectors, retained proofs, interrupted Secret Service writes, schema migration, response ownership, exact authorization targets, mutation recovery and offline switch cancellation/completion pass; earlier verified loopback TLS passes; independent QR decoder passes for recovery and pairing payloads; combined live UI/HTTPS/keyring verification, capacity management remains pending |
| Library-switch pairing | Separate bounded Secret Service candidate history, request/check/cancel, retained private drafts and claims, fresh authority verification, native public QR/copy and subsequent reviewed activation | Twenty desktop tests (nineteen without desktop features) cover interruption, response ownership, expiry, scope/account changes, capacity/schema/generation refusal, old-key preservation, exact authorized handover and review-only reuse of retained claims across changed pins/accounts; native GTK and private-keyring attempts stop before window/keyring creation |
| Empty-target first keys | Separate bounded Secret Service candidate history, exact key/envelope before POST, owner-only native create/resume, fresh server reconciliation and reviewed activation | Twenty-seven desktop tests (twenty-six without desktop features) cover writes, races, restart, scope/account/schema/capacity refusal, old-key preservation, reviewed reuse across changed pins/accounts and offline completion/retirement of promoted recovery-code copies; combined live workflow remains unverified |
| Local owner authorization | Bounded unprivileged PAM worker, exact-purpose/scope/generation gate, single-use permit and revocable disclosure lease; password dialog and focus/lock UI wired | Earlier private-policy libpam and current cancellation/clock tests pass; restricted-context private-policy success and live combined current-user/UI verification remain unavailable |
| Cloud credentials | Native Secret Service backend, credential lineage, serialized sign-in/refresh/logout/restart cleanup, bounded live access tokens; native sign-in/reconnect/sign-out UI | Earlier isolated GNOME Keyring and current fault/restart/worker ownership tests pass; live combined account/keyring UI workflow remains unverified; startup connects only with explicit saved automatic consent |
| Automatic synchronization | Explicit per-library toggle, exact protected account/deployment/library pins, primary-process startup, foreground/local-edit wakes, bounded cycles, transient backoff and immediate cancellation/quit admission fencing | Twenty new isolated tests cover consent privacy, stale/missing targets, every binding dimension, cancellation, request priority, backup recovery, checked refresh/key verification and receipt retention; native toggle smoke compiles but cannot initialize GTK here; live keyring/HTTPS workflow remains unverified |
| Cloud library creation | Explicit native create/resume/open and create-another actions; bounded retained intents; one-use confirmation binds account session and existing protected state; original idempotency key retained before POST | Twenty-four fault/restart/schema/expiry tests plus bootstrap admission and reviewed-switch integration; combined live GTK/keyring/HTTPS workflow remains unverified; preserves active keys and sync checkpoint |
| Sync merge and journal | Three-way fields/tags, deterministic disabled copies, authenticated secure v1 materialization, exact offers/ciphertext/CAS, durable partial receipts, nested dependency ordering and connected batch grouping, lossless projection, encrypted two-file recovery, ordered inbound pages/cursors, journal-first missing-snapshot resume, exact-version deletion permissions, bounded bidirectional coordination and retained reviewed library switching/restoration | Merge, projection, secure-copy apply, nested original/edited-copy groups, inbound/outbound, bidirectional cycles, snapshot-review, deletion/restore crash recovery, saved-state restoration and switch authorization/cancellation/offline completion tests pass; conflict-owned absence/deletion recovery remains pending |
| Inline expansion | Pending | Wayland input-method or compositor integration |
| Encrypted backup | Portable encrypted-backup export/import and recovery wired to GTK; independent all-layer codec verification | Live backup password/file-dialog workflow and Apple app round trips remain unverified |
| Clipboard history | Explicit opt-in GTK view, separate local AES-GCM image/key, bounded seven-day retention/search/delete/clear, read-only Wayland data-control worker, foreground exclusions and sensitivity/internal markers, revocable acquisition and quit barriers | Isolated core/worker/privacy tests pass and native backend compiles; private libwayland-server fixture cannot create a client in this restricted environment, GTK cannot initialize a display; full protocol and background/live history verification remain pending |

The initial receiving-field focus failures occurred while this Hyprland 0.56.2
session was locked. `hyprctl -j locked` and Omarchy's lock status confirmed that
condition. It is insufficient evidence of a paste defect. The live test now
fails before clipboard/input changes unless the session is unlocked. Actual
cross-window delivery still needs verification; a dispatcher acknowledgement
does not prove a receiving application accepted the paste.

The session briefly became unlocked during the latest check. The live paste
fixture reached its teardown but aborted on a fatal GTK warning while destroying
an unrealized main window. Picker-only activation now avoids creating that
window; its isolated native teardown regression passes with fatal warnings.
The test also tracks the clipboard provider created by lease restoration and
restores previous text before GTK teardown. The subsequent live attempt stopped
at the lock preflight because the desktop had locked again. Delivery has not yet
been asserted by a successfully completed live test.

Secure rendering uses transient layouts and an explicit reveal gate; it cannot
prevent compositor screenshots or promise erasure of copies made by native font
or input libraries. The native secure smoke test exercises edits programmatically
with a fictional vault, while production display/focus gates remain closed on the
locked host. Full interactive setup, recovery, password-change and reveal testing
still needs an unlocked session. Foreign vault replacement preserves the old
encrypted draft; explicit previous/current authentication can now reseal it as a
new unsaved draft. Its native dialog still needs live display verification.

## Verification on 2026-10-02

- The new native account/recovery UI and serialized worker pass all-target compilation
  and Clippy with warnings denied. The current filtered default library run passes
  659 tests, with sixteen explicitly ignored and 37 excluded (Cloud HTTP module,
  five key-store TLS fixtures and native PAM module). This is a restricted-context
  check, not a green full-suite run. It includes new queue/quit-barrier and lost-UI-reply
  ownership tests, offline saved-deployment/interrupted-lineage checks, control-plane
  admission beside a foreign encrypted checkpoint, QR input bounds, durable
  library creation, creation-receipt admission before key bootstrap, native pairing
  response ownership, post-claim scope halts, live credential validation and public
  invitation deadlines, signed-mutation persistence, interrupted acknowledgement
  recovery, fresh authorization before replay, immutable recovery promotion and
  exact-version deletion/restore with interrupted WAL and lost-response recovery,
  bounded bidirectional cycles, feed/receipt ordering and proportional zeroizing
  canonical buffers, recovery-screen startup beside unread mixed primary files,
  unsafe marker/root refusal and validation of both recovered files before
  replacing cached entries. Five promotion interruption phases now also reopen
  the gated workspace and prove that wrong keys or dataset bindings cannot change
  the files before authenticated recovery. The previous 12-cycle subset took 176.37 seconds before the
  canonical allocation change and 3.97 seconds afterward in the same debug setup;
  this is fixture timing, not a live-network or GUI performance claim.
- Twenty-six account-review kernel tests use public fixtures, encrypted
  temporary journals and an isolated CAS peer. They cover five interrupted commit
  phases, epoch-only review, exact restart receipts, whole-primary generation
  checks, fresh scope/epoch/session admission, preserved journal-only intent and
  immutable conflict copies, reset of old CAS/receipt/cursor/deletion permissions,
  fresh target conflicts, bounded private retention and refusal of unsafe inputs.
  Staged continuation also binds both complete file images, original checkpoint
  presence/ciphertext and the exact target, resumes before publication and refuses
  a changed generation or an advanced target checkpoint without resetting again.
- Fifty durable key-owner tests with desktop features (forty-seven without)
  use a fictional peer and an isolated Secret
  Service fault backend. They cover all seven writes/deletes with failure before
  the operation and after a lost success reply, restart from a retained receipt,
  source-capability history, normal-operation fences, new and retained verified
  keys, same-scope key replacement, fresh recovery state, strict schema/retention,
  root ownership and plaintext-file refusal. Same-account token refresh resumes
  retained consent; another account cannot. A process-local review requires fresh
  consent after any credential generation changes. New checks cover exact-purpose
  commit/resume authorization and revocation, offline cancellation with later local
  edits, refusal after publication or a changed checkpoint, cancellation writes with
  lost replies, reuse of retained cancelled candidates and schema-1 migration. The
  desktop worker test drops a UI completion reply, reads the durable state through
  its queue barrier and finishes activation with a fresh authorization. Native
  worker commands and GTK review/resume/cancel/offline-finish controls are connected.
- Twenty target candidate-pairing tests with desktop features (nineteen without)
  use fictional peers, private temporary roots and a fault-injected Secret Service
  backend. They prove that acquisition changes no active key or bootstrap and creates
  no checkpoint, then exercise the exact locally authorized handover with that candidate.
  Checks cover known-invitation/claim writes before and after lost success replies,
  retained claims after scope halt or expiry, ready-flag restart, no replay after lost
  creation, fresh authority and credential/account admission, capacity/schema refusal,
  receipt-generation exhaustion before claim and lost UI response ownership through
  the worker's quit barrier. These tests use neither a real account, PAM nor a keyring.
- Twenty-seven empty-target first-key candidate tests with desktop features (twenty-six without)
  use fictional peers and an isolated fault backend. They cover durable key/recovery
  intent before POST, both sides of all three writes, lost POST reconciliation,
  retry with the exact same key/envelope when the server did not observe the request,
  authority/recovery/record and role refusal before generation, atomic server races,
  post-response scope halts, same-account refresh and other-account refusal,
  closed schemas, capacity and generation exhaustion. Acquisition changes no active
  key/bootstrap/primary/checkpoint; actual handover requires a fresh exact permit.
  Confirmation retires three promoted recovery-code copies despite interrupted
  writes, preserves original source capabilities and prevents redisclosure. Adoption
  through an already verified recovery code also retires its initial candidate copy;
  a before/after failure in that final retirement keeps activation pending until
  freshly authorized resume, without republishing the journal.
  A lost desktop reply remains recoverable without a volatile-response quit barrier.
  These tests do not use real Cloud, PAM or a keyring.
- Fifteen new review-only reuse checks span those owners. Actual creation/claim flows
  retain the original candidate, then change account, membership, dataset or epoch
  and exercise fresh locally authorized activation. Normal APIs still reject the old
  consent. A claimed envelope can finish without another poll/claim, and a sent
  first-key candidate without another POST. Source/target key history is usable after
  another library switch while preserving earlier entries, primary records and old
  recovery capabilities. Same-epoch presentations require fresh recovery evidence;
  obsolete epoch codes remain only in protected history. Candidate-frame changes
  revoke prepared consent before publication. Completion/retirement write failures
  keep activation pending and resume the same journal with new authorization. Wrong
  server/instance/library or authority and unclaimed drafts cannot supply a key.
- Twelve additional offline-completion checks use the real retained journal/key
  owners with temporary files, synthetic authorization and fault backends. They
  cover account/scope changes followed by fresh online review, later primary edits,
  before/after failures in all five slot changes and the completed receipt, wrong
  purposes/roots, revocation before and during activation, malformed credentials,
  missing/tampered/linked images and journals, advanced checkpoints, foreign slots,
  pending primary markers, generation exhaustion and exact completed-document size.
  A synchronized backend verifies the common library lock during activation. A
  dropped worker reply retains completion without returning a data key. Actual
  sent first-key candidates complete/retire offline after a scope change, including
  before/after failures, without another POST or replacing original proofs.
- Eleven additional history-inspection checks use actual retained switches,
  first-key bootstrap and recipient pairing with temporary roots and fictional
  peers. They cover all stored phases, old/current scope distinction, later local
  edits, mixed activation slots, pending primary markers, malformed credentials,
  missing/tampered/linked images and journals/directories, protected-schema refusal,
  full/generation-exhausted archives and dropped desktop replies. Inspection writes
  no protected slot or library/journal file, invokes no peer operation and leaves
  pending activation fenced. Exact protected-document sizes are reported. No
  recovery code, private invitation/proof, ciphertext, key or snippet body enters
  the catalogue. The native fixture additionally opens the read-only dialog and
  closes it through the shared focus/cancellation path; it remains unavailable at
  GTK initialization in this environment.
- The native AccountReview, PairingCandidate and BootstrapCandidate Secret Service slots are included in the private-keyring
  fixture. Its latest invocation cannot create its isolated D-Bus socket (`EPERM`)
  and exits before opening a keyring; those native slot operations remain unverified
  here. It does not use the host bus or login keyring.
- An explicitly invoked independent `zbarimg --nodbus` reader recovers the exact
  public recovery fixture and a complete public pairing invitation. Only this test
  writes a raster; the decoder cannot emit a D-Bus message. The new native lifecycle
  test uses an injected worker, synthetic
  authorization and public visual material, without a real keyring, account, PAM
  or network request. Its explicit host-bus run fails at GTK initialization before
  creating a window; focus/password/confirmation, pairing, signed-action and library-switch
  integration remain unverified. The updated fixture also covers switch candidates,
  pending-target admission, completion controls, failure fencing, recovery-input clearing,
  separately retained candidate invitations, non-extending deadlines, received-key
  cancellation fences and reader-role request admission, plus first-key owner-role
  admission, exact-candidate resume and separate review before activation. It also
  checks offline completion admission without a matching live selection and clears
  role/selection/data controls after local completion or failure.
- Thirty restoration checks with desktop features (twenty-nine without) cover
  the pure proposal and actual saved key/journal owners. They verify metadata-only
  and held-intent preservation, restamped local fields, untouched extra records,
  ignored historical tombstones, unchanged current offers/CAS/feed/confirmed facts,
  exact source selection and primary/capability frames, six interrupted boundaries,
  both sides of protected writes, fresh-purpose restart, cancellation with later
  edits, tampered/advanced states, full image retention and exhausted generations.
  Real fixture vault authentication verifies seals/hashes, reseals a disabled copy
  under its own UUID and resumes without retaining a borrowed vault key. Foreign
  salts or corrupted current hashes refuse the entire restoration. Strict protected
  schema tests fence admission/catalogue reads; the desktop worker test loses its
  completion reply, inspects the durable receipt through the queue and finishes
  with fresh authorization. These use temporary files, a fault backend and
  synthetic local permits, with no live server, keyring or PAM authentication.
- Thirteen additional group/scheduler/owner checks cover nested source/copy roles,
  iterative 4,096-edge traversal, cycle and foreign-role refusal, ambiguous original
  offers/CAS, connected read-set races, order-independent full-file redo, reviewed
  absence and held intent, exact secure C0 evidence beside an explicit C1, and real
  protected-history restoration followed by strict synthetic CAS delivery. Secure
  owners borrow one vault key only during preparation; redo retains the original
  nonce and needs no vault key. Carrier cleanup updates file images, desired intent
  and the reviewed anchor in one WAL, retaining existing offers. A copy ACK that
  enables cleanup continues the bounded send cycle instead of reporting a halt.
- Eight additional generation/owner checks preserve active graphs and exact outbound
  packets beside restored ordinary and matching-vault groups, including different
  sealed-copy nonces, a lost current leaf ACK, five interrupted restoration phases,
  later source CAS, two queued decisions, disjoint groups, queue exhaustion without
  eviction, JNL5 migration and refusal of nested queues or injected server facts.
  Secure cleanup remains valid when later carriers are still present. Already
  published decisions replay without appending another generation; a released
  child cannot prematurely recreate future carriers while its parent is pending.
- Six additional archive-generation checks restore all ordered local frames through
  the actual protected owner, with finished or in-flight current groups, two
  interrupted boundaries and uninterrupted application. Synthetic CAS delivery proves intermediate
  versions precede the final selection. Secure originals with a shared UUID retain
  both exact nonces through borrowed-key preparation and key-free redo. Corrupted
  old seals/hashes or a foreign vault refuse the whole proposal before an ordinary
  final edit can apply. Full-queue refusal preserves files, the current packet and
  all capabilities. Data-only export carries no historical protocol facts, and
  older non-dependency targets deliver before later queued targets of the same UUID.
- Eleven additional archive participant checks cover deleted ordinary copies and
  nested C1 sources, tombstone parents without retained bodies, absent/deleted secure
  originals, selected carriers without a staged graph, ordered queued originals,
  and preservation of a later current secure edit. Actual protected receipts and
  key-free restart precede strict synthetic CAS delivery; each generated or retained
  original nonce stays fixed. A current ambiguous authorized deletion packet keeps
  its exact bytes and original CAS ahead of new restoration, while archived
  tombstones never send. Damaged keyed hashes and foreign reserved UUID occupants
  refuse before primary changes or a protected receipt. Borrowed vault preparation
  keeps the existing idle deadline and refuses expired or replaced keys.
- Six additional current-original checks exercise Keep and Delete for a never-created
  secure copy across five primary WAL interruption phases, actual remote deletion
  CAS, invalid keyed hashes, reserved UUID collisions, and queued materialization
  beside a source request whose reply was lost. Retained nonces, confirmed versions,
  queued targets and packet bytes remain exact through restart. Changed primary
  files, checkpoints or vault identity refuse without overwriting the raced state.
- Six additional source-owner checks preserve ordinary and secure held winners
  through both decisions and five WAL interruption phases, keep edited companion
  C1 behind its exact original C0, and materialize queued originals beside a real
  lost-reply source request. Current packet bytes/CAS, confirmed versions, old
  nonces and queued targets remain exact. Source and companion UUID collisions,
  damaged keyed hashes, stale checkpoints and selected unresolved carriers refuse
  without partial primary or journal changes. Secure held bodies decrypt only
  under their new copy identities; deletion finishes after actual original/source
  acknowledgements.
- The corresponding filtered build without desktop features passes 626 library
  tests, with two ignored and 34 excluded (Cloud HTTP module and key-store TLS
  fixtures). The current 23 process/core and one helper-protocol tests also pass.
- Release GUI, CLI and private owner-auth helper compile with the locked Cargo dependencies.
  Two consecutive installs of the current artifacts into an isolated temporary
  prefix pass: all three executables match the Release outputs, executable modes
  are preserved, existing support files survive, the helper stays private, and
  a fresh temporary CLI library stays empty without sync, vault, backup-recovery
  or device-clock state.
- Twenty-eight clipboard-history core, serial-worker and revoked-FFI tests use
  fictional text and temporary roots. They cover disabled/empty startup without
  keys or a clipboard connection, private closed preferences and consent CAS,
  literal UTF-8 and exact duplicate identity, seven-day/count/byte retention,
  diacritic/case search, sensitive/file/internal formats and foreground exclusion
  hints, AES-GCM nonces/tampering, missing/wrong keys and lost namespaces,
  cancellation before/after key and image publication, external-image races,
  safe pruning/delete/clear including damaged or oversized regular images,
  symlink/hardlink/mode refusal, primary/backup separation, preference repair,
  queue overflow, focus/clock/lock/quit revocation and stale-view refusal before
  a backend is constructed. Core tests are independent of GTK and keyring.
  The native read-only ext-data-control-v1 backend is compiled with generated
  bindings and C warnings denied; it uses bounded, cancellable in-memory pipe
  transfers and never requests primary selection or writes either clipboard.
  Its private libwayland-server executable also compiles with warnings denied,
  but an explicit run stops at refused client creation before a protocol
  handshake. The explicitly invoked empty/disabled GTK history fixture stops at GTK initialization before
  creating temporary state or accessing clipboard/keys. Full protocol, live
  background acquisition and interactive history checks remain unverified.
- The automatic mode's native toggle fixture was invoked explicitly with fatal
  GTK warnings. It stopped at GTK initialization before creating a window or
  starting its synthetic worker. Its control/callback behavior therefore remains
  unverified in a live graphical session. Core automatic tests use fictional
  credentials and temporary roots; no live account or keyring was contacted.
- Nine retained-draft recovery tests cover all four passphrase/recovery-key
  combinations, recovery-only vaults, wrong credentials and 4 KiB input limits,
  cancellation at all authentication/reseal boundaries, original draft AAD and
  invalid body refusal, exact source body/metadata/ancestor guards, all current
  identity fields, locked/expired sessions and backup recovery fences. Recovery
  changes no vault, device clock or sync files; unrelated current records survive,
  and a duplicate keyword requires a change before explicit Save appends the
  new record. Two desktop authorization tests cover permanent cancellation,
  fresh unlocked epochs, elapsed and backward wall/monotonic clocks. A separate
  native fixture covers both credential fields, bounded borrowed input and
  cancellation. It uses only fictional text and temporary roots, without vault
  keys, keyring, PAM, clipboard, accounts or network. Its explicit run with fatal
  GTK warnings stops at GTK initialization, before a window, fixture library or
  session observer is created; live dialog behavior remains unverified.
- Thirteen encrypted-backup tests cover the independent OpenSSL format, NFC
  passwords, exact AAD/wrap domains, tampering, duplicate IDs/keywords, future
  metadata and removal of device-local receipts, large payloads and bounded KDF
  parameters. Export preserves both primary files and original secure seals,
  omits an empty vault and never writes account/sync state. All six cancellation
  boundaries, changed primary/vault files, pending redo, unsafe output paths,
  mode `0600`, a different root and revocation across a real held file lock are
  checked with public isolated data. A separate explicitly run public-export
  fixture writes a shipping-cost Rust artifact; the independent OpenSSL decoder
  authenticates its vault key, record bodies and hashes. No Python is needed by
  Cargo or the installed application. The new native password lifecycle fixture
  is compiled; its explicit display attempt fails at GTK initialization before
  creating a window or fixture library.
- Fifteen import-owner tests cover new and matching vaults, preservation of
  local doors/receipts and incoming future metadata, ID/keyword upserts and
  cross-kind collision refusal, missing/wrong fresh authentication and different
  root keys, repeated-import idempotence, repair of a damaged live secure seal,
  empty-library no-op, different data roots, edited incoming authentication and
  hostile KDF bounds, a 2,020-row mixed ID/keyword batch, a required new local
  passphrase and refusal to replace existing doors. Two additional clock tests
  cover batch carries/ancestor floors, restart high-water marks, empty-batch
  non-seeding and refusal of partial reservations on exhaustion. Four durable
  fault boundaries and all thirteen revocation
  checks preserve exact redo ownership: prepublication cancellation changes no
  primary file, while a published journal gates app/CLI/vault readers until
  authenticated recovery. Wrong passwords, ciphertext tampering, foreign local
  identity, linked inputs, external edits and overlapping cloud recovery fail
  closed without erasing the fence or overwriting either file. Two desktop worker
  tests use public reference backups and a synthetic continuously observed
  session to prove confirmation is required before writes, cancellation releases
  the retained incoming key, and fresh current-vault authentication runs in the
  worker. No test uses the user's keyring, PAM, account, library or network.
  The new ignored native restore fixture covers password, local-vault credential
  and new-passphrase fields through cancellation and actual response buttons.
  Its explicit attempt with fatal GTK warnings fails at GTK initialization before
  a window, observation thread or fixture file is created. A process test also
  proves the actual CLI refuses a pending backup before parsing mixed primary
  bytes, without changing either file or creating cloud state.
- Rust core/process tests pass with and without the desktop feature. They cover
  independent crypto vectors, authenticated tampering, vault sessions and drafts,
  record conflicts, CLI privacy, strict parsing and file permissions.
- Before the environment became restricted, the full default suite passed 255
  tests (232 library + 22 process/core + 1 helper protocol), including the extended
  TLS confirmation test; the build without the desktop feature passed 251
  (229 library + 22 process/core), including the final Unicode normalization test.
- An earlier full rerun was not green in the restricted context: 199 library
  tests passed, 33 HTTP/TLS fixtures could not bind a loopback socket (`EPERM`),
  and the private-policy PAM success fixture returned the closed `Unavailable`
  failure. The latest restricted TLS attempt has the same socket refusal. That
  PAM failure's precise
  underlying cause has not been established. Three native GUI checks
  were run explicitly on September 30; the live paste check remains open.
- In the restricted context, 68 key-owner/recipient/disclosure/mutation unit tests pass
  with desktop features and 66 without them (explicitly excluding the five TLS fixtures).
  The 22 process/core tests and the helper's invalid-frame test pass separately.
  These targeted checks do not replace a full HTTP/TLS/PAM rerun.
- Earlier ordinary and secure native lifecycle smoke tests passed with
  `G_DEBUG=fatal-warnings`. The current GTK environment cannot initialize the
  new startup-recovery fixture; this does not verify the changed UI in a live session.
- Clippy passes for all targets with warnings denied; formatting checks pass.
- Temporary-prefix installation and replacement pass with a path containing
  spaces and preserve an existing data sentinel. The helper is a regular mode-0755
  sibling of the app, with no public `bin` link. The release helper rejects an
  unsupported argument with only its closed status byte, and its imported symbols
  include `pam_start` without the fixture's `pam_start_confdir` entry point.
- The current release artifacts install twice into an isolated temporary prefix;
  the ordinary CLI starts empty without creating Sync/Vault state and the GUI
  version command works without initializing GTK. An explicitly created fictional
  pending marker then fences the installed CLI before parsing a malformed mixed
  primary file; neither that file nor the sentinel changes, and no journal is created.
- Canonical floating-point bytes match 11,903 values generated by the actual
  Swift 6.2 runtime C formatter. Independent encrypted sync vectors cover both
  ordinary records and a vault record whose inner ciphertext remains unchanged.
- HTTP tests use loopback fixtures with fictional credentials. They verify
  discovery/endpoint pinning, issued-credential journaling before account checks,
  sticky account/dataset halts before record access, explicit create-CAS nulls,
  positional acknowledgements, original offers across one bounded feed retry,
  rejected redirects/encodings/oversized bodies, and closed failure schemas.
- Twelve portable bootstrap tests cover independent P-256 pairing/recovery
  ciphertext, the existing Swift/Android recovery and Ed25519 vectors, invitation
  bindings/time windows, strict secret schemas, recovery-code grammar, fresh
  randomness and request hashes. Six additional loopback HTTP tests cover bound
  authority/recovery reads, epoch and nil-identity refusal, explicit null initial
  CAS, exact bootstrap receipts, owner-role checks and malformed metadata.
- Thirteen more HTTP tests cover pairing create/poll/claim/cancel, signed recovery
  and approval requests, a connection dropped after receiving a mutation, exact
  retry bytes, authority/role refusal, strict complete recovery receipts, challenge
  scope/action/hash/epoch/nonce/expiry checks, metadata redaction, empty 204 ACKs,
  owner-only recovery, writer approvals and role downgrades before mutation.
  Six retained-proof tests cover exact restart encodings, wrong signing keys/IDs,
  strict journal shapes, both expiry clocks and inspection after expiry without
  replay authorization. These loopback tests do not run the real Go server.
- Twenty key-owner tests cover durable candidate-before-POST ordering, restart
  before and after each of four secret writes, lost bootstrap replies, remote
  authority verification, competing initial keys, strict binding/schema checks,
  replaced recovery envelopes, locked stores and preservation of existing
  encrypted checkpoints. Recovery beside a pending primary marker leaves that
  marker and checkpoint bytes unchanged; an absent checkpoint key or foreign
  scope cannot activate a library key. Three of these tests use actual loopback
  TLS and the public fictional test CA: lost-reply activation and recovery on
  another installation, normal rejection of the untrusted certificate, and a
  sticky dataset halt after bootstrap. Certificate verification stays enabled;
  the host trust store and keyring are untouched. These are Rust server fixtures,
  not an execution of the production Go server.
- Twenty-four library-creation tests cover both sides of secure-store writes, lost
  POST replies, fresh sessions after restart, account/deployment/credential-lineage
  changes, both expiry clocks, invalid receipts, locked stores, linked directories
  and preservation of existing keys/checkpoints/primary intent. They also cover
  legacy migration retaining every earlier receipt, distinct new requests,
  pending requests in another account, bounded capacity/generation refusal,
  exact confirmation across credential/key/history changes, and expiry during
  preflight or POST. A retained receipt
  requires no repeat POST; dataset, membership or key-epoch changes halt while feed
  and role changes can still be inspected. One additional key-owner integration
  test refuses a foreign creation target before minting any key, accepts the exact
  target for normal bootstrap, and refuses later activation after an account
  change. A second integration creates metadata beside an existing active key
  and encrypted checkpoint, prepares fresh target keys without changing either,
  then explicitly authorizes the reviewed handover while preserving local intent.
  These tests inject fictional remote responses and secret storage; they
  do not establish live HTTP or keyring behavior.
- Nineteen recipient tests with desktop features (eighteen without them) cover the persisted private draft and invitation,
  all six interrupted secret writes, exact retry after a lost claim response,
  retained ownership after failed/locked persistence, completion after expiry,
  stale receipt refusal, durable idempotent cancellation, competing key owners,
  reader-role handling, tampered envelopes/authority and strict journal schemas.
  Existing checkpoint/primary marker bytes and verified recovery presentations
  survive paired key recovery. Two tests use actual certificate-verified loopback
  TLS: a lost claim followed by failed secure persistence and expiry, and a dataset
  reset during claim that halts before installation. The fixture server receives
  only public recipient data, authority and sealed envelopes; the fictional trusted
  client performs key wrapping outside the server thread. Offline inspection returns
  only the last retained public step/invitation and never performs HTTP or activates
  a key; it distinguishes a received claim from live account/key readiness.
  A new worker test uses the actual injected pairing kernel and receipt owner:
  losing the UI consumer cannot discard a claim, failed retention keeps the quit
  barrier and blocks logout, and successful retention permits later activation
  without another poll/claim. A separate fault test preserves a validated claim
  before a later scope check detects a dataset change; it covers both sides of
  receipt writes and halts without installing a key or discarding the response.
- Twenty-one signed-mutation tests with desktop features (twenty without) use
  actual pairing/recovery cryptography, temporary roots, an injected remote and
  Secret Service faults, and synthetic local authorization. They cover both sides
  of every candidate/signature/acknowledgement/promotion write, exact proof replay
  after a lost response, expiry and read-only reconciliation, cancellation during
  challenge and final send preflight, wrong targets, foreign challenges, role/scope
  changes, strict journals and immutable inactive authority pins. Confirmation
  retires both copies of a promoted kit with fault-safe ordering, preserves an
  unrelated future replacement, and cannot reconstruct a retired kit from a restored
  older mutation item. An injected native-worker test drops the UI reply and verifies that the saved
  acknowledgement remains durable. These tests do not run native PAM, a keyring,
  real HTTP or the Go server. The existing host-bus GUI smoke now includes explicit
  code comparison, cancellation and retained-step controls, but fails before window
  creation at GTK initialization in this environment.
- Nine local-owner tests cover exact purpose/scope/generation/digest targets,
  single-use grants, cancellation, backgrounding, gate disposal, late/wrong-gate
  results, desktop lock epochs, unavailable/stale observation and both expiry
  clocks. Three run actual libpam with a disposable private policy and fictional
  password module, including wrong credentials, account expiry/change, changed
  PAM identity, cached success without a password prompt, repeated/unsupported
  conversations, malformed status, helper permissions and cancellation/timeout
  of an owned child. The production helper's protocol integration test uses only
  invalid frames guarded by an impossible owner UID. None attempts a real user's
  authentication or modifies host PAM policy, authentication counters or keyrings.
- Thirteen recovery-disclosure/verification tests cover exact retained QR/code bytes without
  marking the kit saved, changed generations/purpose, cancellation, replaced
  envelopes and access beside a checkpoint that requires account review without
  using or altering that checkpoint. The existing verified TLS bootstrap test also
  checks disclosure, background revocation, saved-code confirmation/retirement and
  recovery on another installation after retirement. Confirmation tests cover
  incorrect/full/oversized suffixes, separators/case, Unicode grapheme preservation,
  uppercase expansion, cancelled or changed targets, cancellation during remote
  revalidation, unchanged keys/checkpoints and both sides of a failed atomic write.
  Schema-1 migration preserves unconfirmed kits, retires authenticated verified
  kits before key publication, refuses foreign scope/authority, and resumes after
  ambiguous writes. Schema-2 verification rejects secret fields, bad hash sizes,
  mismatched authority, invalid status/version and unknown schemas. These tests explicitly
  use synthetic process-local proofs, separately from the libpam fixtures;
  password-dialog and combined live PAM/account workflows remain unverified.
- Six secret-store tests cover opt-in namespaces, private files without secret
  bytes, competing snapshots, ambiguous writes, locked/duplicate/corrupt values,
  lost keys/owners, unsafe links and the independent cross-process mutex. The
  explicitly invoked native fixture also passes against a disposable GNOME
  Keyring on a private D-Bus, including embedded zero bytes and locked collection
  refusal without prompts. Its new recipient slot passes create/read/delete and
  locked-write checks. The extended library-creation slot fixture compiles but has
  not been rerun in the current restricted environment. It never initializes GTK
  or accesses the host keyring.
- Nineteen credential-lineage/owner tests cover issue-before-validation ordering,
  rotation-family retention, interrupted grants, partial revocation, durable logout,
  stale generations, strict schemas, overlapping tokens, rejected account metadata,
  locked/ambiguous secret writes with retained in-memory ownership, stale error
  refusal, lost receipt persistence and expiry on either clock. A real HTTP fixture
  verifies deployment preflight sends no credentials; unbound challenges and nil
  deployment identities fail closed. Credential-owner fault tests use fictional
  injected grants/receipts, separately from the actual HTTP and keyring fixtures.
  Offline live-session validation additionally refuses replaced tokens, changed
  accounts/deployments, pending lineage, logout, expiry and locked storage without
  mutation or HTTP. Two public invitation clock tests cover suspend/wall expiry,
  backwards wall time, overflow, unavailable clocks and polling intervals.
- Twenty merge tests cover independent edits, tombstone/absence rules, tag
  add/remove ordering, nonce-independent keyed body identity, vault routing from
  the selected body, representation changes, conflict union/tie convergence,
  exact carrier cleanup, unknown versions and input/output size limits. Public
  reference fingerprints and UUIDv5 identities were generated independently.
- Twenty-six journal tests cover immutable offers after local/remote changes,
  explicit create-CAS absence, lost/older ACKs, exact C0 preservation receipts,
  copy-before-source-before-copy-delete ordering, restored secure carriers,
  reviewed absence versus unknown ancestry, encrypted restart, tampering/scope
  refusal, strict bounded decoding, permissions, competing file writers and
  upgrade from all four original checkpoint schemas, strict partial-page/cursor
  receipts and exact-version deletion permissions. Legacy prepared tombstones
  keep their original ciphertext/CAS and acquire no automatic permission.
- Twenty-three sender tests use a strict fictional CAS store, actual wire encryption
  and temporary primary/checkpoint files. They cover create/update CAS, identical
  ciphertext replay after a lost response, faults before/after all five durable
  phases, newer local edits beside old offers, partial accepted/rejected replies,
  persistent retry delays, post-HTTP account/role changes, three-way conflict
  preservation and crash replay, source acknowledgement after C0, refusal to
  overwrite edited remote C1, ten-record limits, receive/send ordering, corrupt
  receipts/ciphertext, missing primary files, current-session guards and a durable
  key epoch that still fences primary recovery after the outbound packet drains.
  Retained receipts and ambiguous original packets can finish beside an incomplete
  inbox, while subsequent new batches require receiving first. Feed rotation
  before sending or between batches stops fresh offers until a new snapshot applies.
- Nineteen bidirectional-cycle tests use actual encrypted checkpoint/primary
  storage and a fictional paged CAS peer. They cover empty installs, receiving
  before uploads, post-upload changes, page/batch budgets and resumption, exact
  ciphertext/CAS replay after a lost reply, a newer local edit, failure after a
  successful upload, read-only membership, a role downgrade after acknowledgement,
  refusal to replay an ambiguous offer after that downgrade, receiving during persisted backoff,
  edits/feed rotation/scope changes at the final check, scope/epoch/session
  admission, invalid budgets, local/cloud deletion review, missing snapshots and
  copy-before-source conflict preservation. A cycle cannot report completion
  while either queue, preservation work or unconfirmed physical intent remains.
  Native wiring compiles; combined live GTK/keyring/HTTPS verification remains open.
- Canonical output now allocates proportionally to actual data rather than
  reserving the wire ceiling for every small hash. Growth copies into a new
  zeroizing owner and erases the old capacity before freeing it; it never lets
  Vec reallocate an existing plaintext buffer. Two additional tests cover small
  allocations, exact maximum-size output and oversized escaped text. Existing
  independent wire/crypto vectors continue to define the unchanged byte grammar.
- Eleven missing-snapshot review tests use real encrypted checkpoint/primary
  storage and a fictional positional CAS transport. They cover cancellation,
  atomic reset before/after persistence, retained primary/merge ancestry,
  mandatory fresh receiving before sending, original scope/key/session/feed
  refusal, checkpoint-key replacement, concurrent primary/checkpoint edits,
  missing-file refusal, independent local body/remote metadata changes,
  immutable C0 before a fresh source acknowledgement and later journal-only C1,
  and newer physical edits superseding held intent. Review never posts records,
  approves tombstones or replaces a library/vault key. Native confirmation is
  compiled; combined live GTK/keyring/HTTPS validation remains unverified.
- Twenty-three receiver tests use fictional records, real wire encryption and private
  temporary primary/checkpoint files, with no network, PAM or Secret Service. They
  cover ordered duplicate delta generations, failure before and after each inbox
  save, replay after primary apply, conflict preservation, partial snapshots,
  sticky missing-record review, malformed/tampered complete pages, post-HTTP
  account/key/feed changes, cursor-invalid restart preserving original offers,
  old-feed draining before cursor reset, pending local/cloud deletion and locked
  vaults, session revocation, bounded cycles, installation-clock admission and a
  concurrent edit after preparation that preserves both primary and the queued page.
  Key epoch is checked before primary redo or marker removal. Native receiver
  wiring is compiled; the combined live GTK/keyring/HTTPS workflow is unverified.
- Thirty-two deletion-review tests cover cancellation, local absence versus missing
  whole files, restore and cloud deletion decisions, exact deletion CAS, lost
  deletion replies followed by restoration, withdrawal of an unapproved legacy
  packet, retained CAS-conflict receipts, newer remote edits, future remote clocks,
  all five WAL interruption phases, changed files/checkpoints/session/scope/epoch
  and refusal to bypass missing preservation evidence. Ordinary conflict-owned
  source/copy absence tests keep exact C0 and source offers, CAS and confirmed
  facts through all five interrupted WAL phases. Queued deletion cancellation
  withdraws only unsent tombstones; ambiguous authorized deletions finish with
  actual post-copy source acknowledgements before the restored version uploads.
  Locked compatible-vault tests
  retain exact sealed bodies and unchanged key material; missing/foreign vaults
  cannot be recreated by restore. These use real encrypted storage and a strict
  fictional CAS fixture, without HTTP, keyring or PAM. Native confirmation compiles;
  the live combined workflow remains unverified.
- Protected-copy restoration verifies the later C1 seal and each connected current
  or queued C0 through one bounded borrowed vault session. All five WAL interruption
  phases recover without retaining that key. Missing/expired authentication,
  corrupt original ciphertext, wrong keyed hash and a foreign vault identity leave
  both primary files and the encrypted checkpoint unchanged. Queued protected-copy
  deletion cancellation keeps the latest seal and original ambiguous transmission,
  including a lost C0 acknowledgement. A separate vault deadline test proves that
  this borrow does not extend idle life. The native account lifecycle fixture now
  exercises cancellation and confirmation of both password-dialog choices with a synthetic
  worker, without a real keyring, PAM, network or user data; its live display run
  remains unverified.
- Materialized remote-original deletion tests cover native keep/delete decisions
  before an original ACK, after an ACK with an exact source request in flight,
  and beside absent or newer local content. All five WAL interruption phases
  preserve original copies, later edits and unchanged unrelated packets; strict
  CAS delivery uses the actual tombstone version, and a queued repair needs fresh
  source ACKs. Actual saved acceptance receipts must drain before a later incoming
  deletion. Reviewed deleted sources remain deleted, and their permission survives
  every required release. Protected repairs authenticate both choices and redo
  without a vault key, preserving original and later nonces plus vault headers.
  An ordinary selected copy also requires authentication when a later connected
  generation contains secure evidence; damaged later evidence refuses the entire
  decision before files, consent or protocol state can change.
  Full-queue refusal leaves both primary files, checkpoint and consent unchanged.
- Nine projection tests cover exact remote round trips, fractional dates,
  deterministic local clocks, encrypted extension retention, vault routing,
  opaque future conflict versions and the primary metadata privacy boundary.
- Twenty primary-apply tests cover record and file races, all five interrupted
  promotion phases, scope/key refusal, unsafe external changes, restored old
  checkpoints, conflict-copy identity collisions, key-material preservation and
  keyword collisions. Concurrent ordinary/vault/catalogue readers wait for both
  replacements and read one generation. One test terminates a child process
  between the two file replacements and recovers on restart; its explicitly
  invoked child helper is otherwise ignored by the ordinary test runner.
- Eight secure materialization tests authenticate an independent OpenSSL source
  fixture, verify copy UUID binding, preserve random-nonce C0 evidence across retry,
  distinguish valid later C1 bodies from C0, retain existing C1 records and refuse
  tampered seals/hashes, foreign vaults, duplicate identities and unrelated occupants.
  Primary tests cover a secure-to-plain source move with an implicit secure copy,
  all interruption phases, C1 retention and copy-ACK/source-ACK ordering, implicit
  read-set races and changed root material. Two vault-owner tests cover expiry,
  unchanged idle deadlines and old-key refusal after vault replacement.
- Desktop entry, AppStream metadata, and installer shell syntax validate.
- Temporary-prefix installation and repeat installation pass. The installed CLI
  handles fictional records in an isolated root. The installed GUI accepts repeated
  New activations and Quit through an isolated D-Bus session.
- The live paste fixture awaits an unlocked desktop; its preflight now refuses
  a locked or unobservable session before changing the clipboard or sending keys.

Swift/Xcode checks cannot run on this Linux machine. This port does not edit their
targets or cross-platform Swift code.

## Cloud integration boundary

The transport is synchronous and intended for an owner worker, never the GTK
thread. Initial discovery pins the deployment; an engine must compare durable
membership and dataset identities before admitting data-plane access. Preflight
and every page/batch response preserve that pin. Only a feed rotation within
the same membership/dataset can be adopted automatically. A boundary change
stays halted for that transport lifetime; recovery requires explicit engine
review and a fresh admission after journal-first checkpoint repair.

Requests require HTTPS, validate certificates, follow no redirects, send no
cookies, and bound responses at 16 MiB. Pages and batches request at most ten
records. Batch results are positional and checked against the exact offered
revision/identifier; CAS versions are opaque. The sender durably retains the
exact encrypted offers/CAS before HTTP and complete positional receipts before
applying them or requesting another chunk. A lost response replays the original
ciphertext, not a fresh seal. The inbound owner handles `cursor_invalid`
with a bounded snapshot restart that preserves outbound offers, confirmed
ancestors and local intent. It never mixes a rejected page's cursor into the checkpoint.

Email sign-in proves account access, not possession of a library key. Issued
credentials must be journaled into a secure store before account/lifetime
validation, and rejected generations remain available for durable revocation.
The app currently creates no session, transport, sync checkpoint or network
request by default. **Sync Now** is an explicit bidirectional action after key
verification; it may create the separate device-only checkpoint key. The separate
receive/send actions remain available. Automatic synchronization stays off.
Isolated wire, HTTP and cycle tests do not establish combined live GTK/keyring/HTTPS
synchronization, which remains unverified.

The native secure store keeps one closed credential-lineage document in Secret
Service, plus separate slots for library, checkpoint, bootstrap and library-creation
material.
The library-key owner integrates initial, recovery and paired-recipient activation;
checkpoint creation remains an explicit operation. Disk contains a random lookup
namespace and an independent `0600` process lock, never a token or key. Attributes contain only that opaque
namespace and a fixed slot name; labels contain no account or endpoint. A compatible
provider must negotiate an encrypted Secret Service session and have an existing,
unlocked default collection. Duplicate, locked, malformed or unavailable items
halt the operation. The libsecret adapter refuses all prompts, bounds each
operation to ten seconds and has no plaintext file fallback. It runs on an owner
worker. The independent secret mutex spans the complete onboarding transaction,
including HTTP; the common library lock is taken only to validate checkpoints,
always after the secret mutex, and is released before network operations.

Credential operations persist the pending generation before issuance, then the
issued pair before validating account metadata or publishing a live session.
A committed refresh retires only its old access token; revoking any refresh token
from that family would invalidate the new session. An interrupted refresh instead
retires both generations and requires sign-in again. Interactive replacement
retains the old session until publication, then retires its old grant family.
Overlapping issued tokens cannot publish; cleanup cannot restore a session whose
token was included in that rejected grant. Logout clears the current session
durably before revocation. Every successful revoke is acknowledged durably before
sending the next token. A lost receipt can replay that exact idempotent revoke;
it cannot authorize new issuance. After restart, pending cleanup finishes before
another replacement or refresh can begin.

First-library creation is an explicit control-plane operation. Its closed
`space-creation-v1` Secret Service document retains the current account/deployment,
one UUID-v4 idempotency key and, after success, the validated key binding. The
server's creation idempotency contract replays that key for the same principal.
Lost replies and failed receipt writes retain the original intent; a persisted
receipt uses only observation on retry. Creation refuses existing library keys,
bootstrap/pairing state, checkpoint keys, encrypted checkpoints or a pending
primary transaction. Account and live credential lineage are checked before
HTTP, and discovery is revalidated around observation. The receipt fences later
bootstrap, recovery, pairing and disclosure even before a library key exists.
Feed and role changes do not alter that binding; changed membership, dataset or
key epoch require review. The worker never discards the receipt to admit another
library, generates no keys, and does not modify local snippets. The native account
window offers Create, Resume or Open according to this retained state; the native
account-review recovery workflow still needs implementation.

If secure persistence fails after issuance, the typed error retains the issued
pair with its sealed generation/deployment. Its owner must retry retention before
cleanup; a failed retry returns ownership again. It must not become a generic
logged error. An old retained error cannot overwrite a later pending generation.
The native operations revalidate discovery before sending credentials; a changed
deployment never receives them. Email challenges bind to their issuing deployment.
Stored access tokens are never restored as live credentials: refresh is required.
Live access expires on either wall time or Linux's suspend-aware monotonic clock,
anchored before the issuance request. The native account window now uses these
workers through one serialized owner; startup remains offline without saved automatic consent. No real account
was contacted in verification.

Portable bootstrap secrets have no `Debug`, `Clone` or implicit serialization.
Explicit secret encodings use zeroizing buffers; pairing invitations contain only
public recipient material. P-256 ECDH, HKDF and AES-GCM preserve the existing
invitation/recovery AAD. Recovery codes enforce their exact alphabet and trailing
padding bits. Library-action authority derives from the library bundle and the
canonical HTTPS origin, deployment instance and space, independently of login.

The control-plane transport validates complete scope and key epoch before accepting
authority or recovery state. A changed epoch halts the admitted transport, including
later record operations. Initial key bootstrap sends an explicit null recovery CAS
and accepts only version 1 with the exact submitted ciphertext and binding. The
key owner persists its candidate bundle, recovery kit and exact envelope before
that POST. It resumes the same candidate after an ambiguous outcome and verifies
the immutable remote authority before installing it. A different confirmed
authority can retire an uninstalled initial candidate; missing evidence never
discards it. Existing keys are not overwritten. Initial creation requires an
empty remote library, the owner role and no local checkpoint. Recovery proves
possession through AEAD and authority verification, and validates any existing
checkpoint with its original device-only key and account/dataset binding before
installing library material. It never creates a replacement checkpoint key or
changes a primary marker, cursor or journal generation.

The recovery presentation is persisted before the final pending entry is cleared.
Interrupted activation stays unavailable until resumed. Initial recovery kits
remain awaiting presentation; authenticated recovery input retains only verification
metadata after activation, with its status tied to the current remote envelope.
A newer server envelope marks an old kit replaced while preserving the confirmed
library key. Loading a usable key revalidates scope and remote authority; it does
not expose unfinished activation. Recovery-kit disclosure now requires a fresh
process-local permit bound to its exact saved generation, complete key binding,
purpose and presentation digest. Before consuming it, the worker rereads retained
state and verifies remote authority and the current recovery envelope again.
This control-plane path deliberately does not load record data or use a checkpoint;
an invalid checkpoint cannot destroy an independently verified recovery capability.
It cannot activate a key or authorize a different operation. Revealing the kit does
not mark it saved. The confirmation worker consumes that exact live disclosure and
an explicit last-eight-character suffix. It rereads/revalidates its scope, generation,
authority and remote envelope again, then atomically replaces the retained kit with
verification metadata in the same Secret Service document. The record contains its
binding, envelope version, SHA-256 fingerprints of the kit/envelope and derived
authority, but no kit secret or ciphertext. Matching verifies the current envelope
and installed authority; replaced envelopes do not affect the library key.
When an interrupted recovery replacement still holds an acknowledged copy of this
same kit, confirmation clears that mutation first, before replacing the presentation.
A crash therefore leaves an unconfirmed presentation or removes both copies; it
cannot report successful retirement while retaining a hidden duplicate. An
unrelated prepared/signed future replacement remains untouched. Both documents
are owned under the common process mutex, and faults on either side of both writes
resume by rereading the actual items.

Confirmation rejects incorrect, full-code or oversized input before network work.
Separators and case follow the Apple verifier, while grapheme clusters preserve
diacritics and variation selectors rather than stripping them from a letter/digit.
The normalization vectors are derived from the app's Swift verifier and upstream
[Swift Character properties](https://raw.githubusercontent.com/swiftlang/swift/swift-6.2-RELEASE/stdlib/public/core/CharacterProperties.swift),
not execution of Swift on this machine. A failed confirmation consumes the visible
disclosure. After an uncertain write, a fresh status read distinguishes a retained
unconfirmed kit from committed verification; it cannot redisclose a retired secret.
The operation leaves library keys, checkpoints and primary markers unchanged.

Bootstrap journal schema 2 distinguishes retained presentation from verification.
Schema 1 remains readable: authenticated legacy verified input converts in memory,
then persists metadata only after matching the installed key and fresh remote
authority before key publication. Unconfirmed/replaced legacy kits remain retained.
Migration failure halts publication and resumes by rereading the actual secret item,
without minting keys. Newer/unknown schemas and mixed secret/verification shapes
fail closed. Native account and recovery presentation/confirmation UI are wired;
Signed replacement/approval persistence and native authorization actions are also
implemented; combined live verification remains pending.

Native owner authentication uses the current process's real/effective identity
and the fixed `system-auth` PAM service. It supplies exactly one nonempty password
and requires successful authentication, account validation and unchanged PAM user
identity. Cached/no-prompt success, another identity, password-change requirements,
echo-on prompts and multiple factors cannot issue a permit. The adapter follows
Linux-PAM's [authentication](https://github.com/linux-pam/linux-pam/blob/v1.7.2/doc/man/pam_authenticate.3.xml),
[conversation](https://github.com/linux-pam/linux-pam/blob/v1.7.2/doc/man/pam_conv.3.xml)
and [account validation](https://github.com/linux-pam/linux-pam/blob/v1.7.2/doc/man/pam_acct_mgmt.3.xml)
contracts. No login session is opened and no password is changed. Only a closed
status byte leaves the helper; credentials use bounded stdin pipes, never arguments
or environment variables, and raw PAM messages are not reflected or logged.
The helper disables core dumping before reading credentials. Owned Rust buffers
are zeroized, but PAM/module/kernel copies lie outside Rust's erasure guarantees.

The worker resolves a regular, non-linked, non-setuid/non-setgid sibling helper
owned by the current user or root and unwritable by group/others. It does not search
`PATH` or accept a service/configuration override, and revalidates the executable
before every request. PAM runs off the UI thread in that unprivileged child; a
20-second deadline, cancellation or desktop lock kills and reaps the owned child.
The gate and disclosure lease have 60-second wall and suspend-aware monotonic
deadlines. Backgrounding, cancellation, a newer request, lock-state changes or
gate disposal revoke them. A disclosure has no debug, clone or serialization path,
and its getters check the lease every time. The native account window cancels on
focus loss, closing and desktop lock, and clears visible secret state before
account operations. Its combined live focus/password/lock workflow remains
unverified. No password, grant or authentication success is cached or persisted.

Recipient pairing uses a separate closed Secret Service journal under the same
independent owner mutex. It saves the P-256 private draft and an attempted-create
marker before POST, then saves the validated invitation before permitting QR/code
display. Creation is not idempotent in the current server API. If its response is
lost, the worker reports an unconfirmed creation and sends no automatic second
POST; explicit cancellation permits a new invitation. An unreachable server entry
was never displayed and expires itself. A known invitation instead keeps its exact
private/public/nonce binding across polling and idempotent claim retries.
Read-only retained-state inspection permits public invitation/countdown display
after restart or during network trouble; it does not assert live readiness.

The claimed envelope is retained in Secret Service before library-key installation.
AEAD and a fresh immutable authority match are mandatory; an already installed
key must match exactly. Once retained, the envelope can finish activation after
invitation expiry without another poll or claim. Failed persistence returns a
non-debuggable owner value containing the original response; retention retries
keep that ownership on failure and cannot overwrite a cancelled or newer journal
generation. The caller must retain it before proceeding. Completed activation
retires the private draft only after the installed key is durable. Cancellation
is journaled before DELETE and retries the same ID after a lost response; it cannot
discard a received library key. A valid claim response is retained before the next
scope validation, so a later boundary halt preserves it for review without
installing a key. Other key owners cannot expose or replace keys while recipient
setup remains unfinished.

The native account screen now offers pairing on this computer: it displays only
the saved public invitation, its confirmation code and remaining lifetime, allows
explicit public-invitation copying, and handles check, cancellation and retained
activation. Automatic polling requires a visible active window, an unlocked desktop,
no outstanding operation or response retention, and an unexpired display deadline.
It waits at least two seconds after a status reply. Network/account failures pause
polling until an explicit retry or reconnect. Same-invitation replies preserve the
original monotonic deadline, including across wall-clock changes. Received claims
have a separate Finish action and cannot be cancelled. This is compiled/tested at
the worker boundary; the trusted Linux approval action is also wired, while live
combined GTK/keyring/HTTPS verification remains outstanding. Startup remains offline.

Signed pairing approval and recovery replacement now validate the remote authority
before requesting a challenge. They check its exact scope, action, epoch, request
hash, nonce and bounded expiry before accepting a caller-supplied signature. The
signature must verify under that authority; a different key or challenge cannot
produce a sendable request. Live proof deadlines use wall time and suspend-aware
monotonic time. Every send revalidates the original scope and current role, and
accepts only the exact recovery CAS/ciphertext or bound approved pairing metadata.
Recovery replacement requires the membership's owner role; writers can approve
pairings. Readers cannot create, cancel or approve them. These roles are checked
again immediately before mutation rather than trusting the role at challenge time.

The immutable signed request has a closed, bounded secure-store encoding. A dropped
response retries with the original proof, CAS and ciphertext, without another
challenge. After restart, server expiry is authoritative; expired retained requests
remain inspectable for read-only outcome reconciliation but cannot send. The durable
owner now retains candidates before obtaining a nonce and saves the signature before
HTTP. The process-local permit binds the exact intent, installed key, bootstrap
generation and purpose; its revocable lease is rechecked after waits and immediately
before mutation, following the transport's awaited preflight. Each replay needs
fresh local authorization but keeps its original signature, nonce, ciphertext and CAS.
A signed or acknowledged operation cannot be cancelled or overwritten by a new
operation; only an unsigned draft may be discarded.

Acknowledgements are persisted before the next remote-scope check. Recovery
reconciliation compares both exact ciphertext and next version; it may finish
after proof expiry without another mutation. A redacted Approved pairing status
cannot prove that the original cipher was accepted. Without its saved acknowledgement,
an expired approval remains review-required. Recovery promotion preserves the
installed root and writes the retained kit into the existing presentation journal.
If the final mutation write fails, later reconciliation preserves an already
confirmed metadata-only presentation and cannot reconstruct a retired kit.
The separate disclosure action still needs fresh local authorization. The native
UI displays the pairing confirmation code and requires explicit comparison before
PAM approval; replacement describes the old offline copy's loss of access to the
current recovery envelope. Worker results publish the retained state even when a
candidate write's receipt is ambiguous. The pure signing and HTTP APIs do not
establish that product gate or activate a key. Pairing create/poll/approval metadata
must remain redacted; only the atomic claim endpoint releases the opaque envelope.

The pure merge validates every input and every generated output before returning
an outcome. An oversized or malformed losing snapshot stops the operation; it
cannot be mistaken for absence. Secure losing seals remain bound to the source
UUID until the vault owner authenticates and reseals a deterministic copy.
Unknown conflict versions remain opaque and prevent deletion/cleanup.

The journal kernel stores confirmed state, latest desired generations and exact
offers separately. Repeated offers retain the original nullable CAS, even after
a fetch learns a newer server generation. Conflict prerequisites have independent
offers and receipts: an edited C1 with the same provenance cannot prove that C0
was preserved. A source release needs its own post-copy ACK, followed by a fresh
primary reread, before held copy edits/deletes can proceed.

The Linux-only `SCJ1` / `JNL6` checkpoint has a 256 MiB encrypted-file ceiling. It
uses AES-GCM with a separate per-install key supplied by the Secret Service owner,
an independent key derivation/AAD domain and a fresh nonce. The owner can create
checkpoint material only on an explicit setup request; a missing key alongside
an existing checkpoint fails closed. The app does not initialize that owner or
generate a checkpoint key by default. All journal payloads and the membership/
dataset bindings are encrypted, including projected envelopes, pending primary
file images, ordered inbound generations, opaque cursors and exact outbound
packets/receipts and exact-version deletion permissions; decoding checks those
bindings before envelopes. A separate durable key epoch remains after either
queue drains and fences primary recovery.
The reader accepts `JNL1` through `JNL5`, preserving existing state and
adding empty sections where absent before upgrading on the next save. Legacy
tombstone offers remain unapproved. Primary files retain their existing 32 MiB
limits; the larger checkpoint can hold both before and after
images during recovery.
JNL6 adds fixed active delivery targets and at most eight ordered local generations.
Queued graphs contain original copies and selected targets, with no offers or
acceptance proofs. Their nested data frames forbid protocol state and further
queues before recursion. All fields remain inside the encrypted checkpoint.
The binary decoder rejects unknown schema/tags, duplicate identities, malformed
ownership/receipts, truncated data and trailing bytes. Saving uses the library's
common process lock, ciphertext compare-and-swap, private permissions and atomic
fsync replacement. It neither reads nor rewrites Apple checkpoint formats.

The inbox retains one authenticated page of at most ten records. Its fetched
cursor advances only in the same encrypted write as the complete page; its applied
cursor advances only after every record's primary transaction and confirmed/local
intent receipt. Delta generations of the same UUID remain ordered, never collapsed
into a map. A crash after primary apply replays against the recovered projection
and immutable conflict evidence. An uncertain save ends the cycle; the next action
reloads authenticated disk state before HTTP. The native credential owner mutex
spans the cycle, with current session/library-material validation around waits;
the common library lock is held only for local transactions. No payload or cursor
is logged or stored in plaintext diagnostics.

Snapshot identities accumulate across pages, without deriving deletions from a
partial result. A complete applied snapshot missing any confirmed record enters
sticky review. An old authenticated page drains before a feed epoch's cursors are
reset; account/dataset/key epoch changes halt before primary. Local primary absence
beside a known live record and remote deletion of local content stay queued for
explicit single-record review. Unresolved conflict dependencies and locked/incompatible
secure conflict units still require their recovery paths. Receive
outcomes deliberately do not claim that local changes were uploaded.

Missing-snapshot review is an explicit action in the already verified library.
Preparation authenticates the checkpoint scope and key epoch before existing
primary recovery, then retains the complete primary view and exact ciphertext
snapshot in the worker. The confirmation dialog carries only a one-use token and
bounded counts. Confirmation freshly validates the account/key/feed, reauthenticates
the checkpoint, and compares the complete primary view under the common lock.
Changed or missing files/checkpoints require another review; no unknown local
absence becomes a deletion or resurrection. One encrypted atomic save retains
current and journal-only desired state, original merge ancestors and immutable
conflict snapshots, while clearing offers, CAS/acceptance generations and cursors.
The restarted feed fences sending until a new complete snapshot is applied.
Old copy/source acknowledgements cannot authorize post-review dependency release;
fresh C0 and source evidence are required before later C1 offers. A retained
journal-only edit materializes through the existing primary WAL; a newer physical
edit supersedes it. Account/library/key replacement remains unfinished; deletion
permissions require their own explicit review. Startup performs none of these
actions automatically.

Single-record deletion review retains the actual bytes of both primary files and
the authenticated checkpoint in the worker. The native dialog carries only an
opaque one-use token and bounded identifying metadata. Confirmation rechecks the
account/key/feed and both saved views, then commits the exact decision, any
inbound/outbound receipt position and the complete primary images through the
same encrypted WAL. A local missing record becomes a fresh stamped tombstone only
after confirmation. A keep/restore preserves the identifier and sealed body while
creating an edit causally newer than the reviewed deletion, even with clock skew.
Protected-copy decisions can borrow a matching live vault owner. Before
primary preparation, every source, target and original in the selected connected
component is authenticated separately for each ordered generation. A later C1
does not substitute for C0, and an existing original is never resealed.
The returned plan contains only ciphertext and exact before/after
images, with unchanged vault headers. The key borrow checks expiry again after
validation and never changes the idle deadline. The native worker authenticates
an ephemeral owner off the GTK thread from an explicitly entered passphrase or
recovery key, consumes the review token once, and drops that owner after commit.
Missing whole primary files and selected records with unresolved carriers cannot
use this path. Complete ordinary conflict
groups retain their existing originals/offers while the reviewed absence decision
waits in the ordered journal. Vault documents, wraps and root identity are never
created or replaced. Selected unresolved-carrier recovery still needs its separate
group recovery path.

A selected secure copy whose original has never been materialized can now be
reviewed from its exact retained carrier. The dialog shows the eventual copy's
name and conflict timestamp without decrypting its body. Both Keep and Delete
require the matching vault. Under the common lock, preparation authenticates the
connected active and ordered graphs, retains every existing C0 nonce and seals
only missing originals. Reserved UUID collisions refuse the proposal. The new
snapshots, chosen later intent, exact deletion permission and receipt progress
become durable together through the encrypted primary WAL; no copy is created
before confirmation. Restart needs no retained vault key. Existing packet bytes,
confirmed versions, queued targets and ownership remain current facts. A remote
deletion supplies its actual CAS for the original save, which must finish before
the chosen final copy version. Hidden carrier timestamps contribute to the new
edit's HLC floor.

A selected source with resolved retained intent can also review its missing
originals. Before confirmation, the owner binds all connected original identities
and distinct active/queued source versions to the complete primary/checkpoint
snapshot. The native dialog counts missing originals to restore and held source
versions to preserve as disabled copies. Both choices authenticate the connected
graphs and all additional secure source bodies with the matching bounded vault
owner. A missing original becomes an explicit primary outcome, using later live
local intent when available; independent unresolved intent or an unapproved child
tombstone refuses the operation. Distinct held source bodies get their own copy
UUIDs, with secure ciphertext resealed under those UUIDs. Existing edited companions
retain C1 in the files while C0 stays immutable in the delivery graph. The full
read-set includes original and companion identities. All data and the source
decision publish in the same encrypted WAL without retaining a vault key.
An absent source's carrier can retire only after its exact original's actual
acceptance and a valid local deletion decision. The source still needs its own
actual acknowledgement; old source offers, queued targets and CAS remain exact.
Selected intent that itself contains unresolved carriers is still refused.

A remotely deleted materialized original requires review even beside absent or
newer local content. An actual saved send receipt for that UUID must finish first;
the incoming tombstone cannot replace that receipt's CAS or count as original-copy
acceptance. Before a copy has been accepted, review retires only an ambiguous
prerequisite request whose original CAS differs from the actual deleted occupant's
CAS. Unrelated transmissions remain byte-for-byte unchanged. After a real original
acknowledgement, review retains the active source packet and appends a data-only
repair generation, followed by the chosen final copy version. Fresh original saves
use the confirmed deletion's CAS, and each new source release needs its own actual
acknowledgement. Retained original nonces and later local bodies stay separate.
Previously reviewed deleted sources stay deleted, with exact permission retained
through their ordered releases. If the queue is full, the decision publishes
neither consent nor primary changes. A protected repair authenticates the whole
connected group for either choice through the same bounded matching-vault borrow;
its encrypted redo needs no live vault key. The vault requirement includes later
connected generations, even when the selected copy and active repair are ordinary.

Deletion permission binds the complete envelope hash and retained live ancestor
inside the scope/epoch-bound encrypted journal. A later local mutation clears that
permission. Primary deletion additionally checks the exact live ancestor, so an old
request cannot erase a newer restored physical record. The sender freezes permission
with original wire bytes and CAS before any POST. A previously authorized ambiguous
packet survives restore and replays unchanged; its acknowledgement precedes sending
the new live edit. Keeping a queued deletion replaces only the exact tombstone
that has never been offered; an ambiguous active deletion retains its original
transmission. An exact authorized source deletion whose original CAS is rejected
can retain a send-only permission while obtaining a real post-copy acknowledgement
with the authoritative new CAS. That permission has no live ancestor and cannot
delete the restored primary record; an actual acknowledgement retires it. An
unapproved packet can be withdrawn because the native sender could never have
posted it. Remote deletion extensions and legacy checkpoints do
not supply local permission. Snapshot reset clears old permissions and requires
fresh review. Ordinary confirmations remain explicit and perform no automatic HTTP
record mutation.

The sender captures current primary projection and desired intent under the
common lock before creating a packet of at most ten exact offers. The encrypted
checkpoint owns the ciphertext and nullable original CAS, so new edits never
rewrite an ambiguous transmission. Server replies are validated positionally and
retained before post-HTTP admission checks, then acknowledged one at a time. A
partial failure cannot erase earlier successes. Rejected requests may retire
their ambiguity; retry delays retain the complete processed packet and its first
response time across restart. Fully processed backoff does not block receiving.

CAS conflicts enter journal-first three-way primary apply. Losing bodies freeze
as immutable disabled C0 copies; these upload before the source. A fetched source
equal to a lost post-copy offer still needs a fresh actual source acknowledgement
before held edits can release. A remote edited C1 cannot prove C0 and is kept for
review without overwriting it. Source carrier cleanup uses fresh primary read sets;
dependency release requires another fresh primary read after acknowledgements.
Unjournaled primary absence, unapproved deletions, unavailable secure materialization
and incompatible vaults stop sending rather than manufacture intent. Unprocessed
outbound receipts finish before new receiving, and incomplete snapshots finish
before new sending. Both paths use the native credential owner and current key
checks; their successful outcomes remain narrower than a bidirectional sync claim.

The bidirectional coordinator owns no additional journal, cursor or persistent
queue. Its default budget permits four bounded receive attempts and four send
attempts, including retained-page/receipt processing and feed/cursor restarts.
It finishes retained outbound ambiguity before another fetch; the sender permits
only those original packets beside an incomplete inbox, then fences fresh offers.
Both initial and mid-cycle feed rotation require receiving before new packets.
After uploads, receiving runs again before a completion result. Persisted server
backoff still permits receiving, but the same action cannot repeat rejected writes.
An acknowledged write followed by a read-only downgrade still permits receiving;
an unacknowledged original offer remains halted without an unauthorized replay.
Every receive/send step retains the existing scope, epoch and session checks.

Before reporting completion, fresh remote admission precedes authenticated recovery
and a common-lock reread of the checkpoint and actual primary files. Both queues,
snapshot/review state, pending intent and preservation work must be clear, the
applied feed must still match, and every live physical envelope must match its
confirmed hash. Unknown local absence cannot be mistaken for an empty successful
library. New edits or feed changes select another bounded direction; review, vault,
read-only, backoff and budget exhaustion have separate incomplete outcomes. Network
or persistence failure propagates without a success claim; the next action reloads
the original encrypted journal. No action schedules itself after its budget ends.

Primary apply takes the common process lock, verifies the complete read set and
file images, and stages preservation dependencies before changing local content.
An encrypted checkpoint records the transaction's nonce before the small pending
marker is created. The encrypted redo intent is durable before either primary
file changes. Normal library readers and writers refuse access while that marker
exists. Public reads take the common lock before checking the marker; UI and CLI
catalogues read both files under that lock rather than combining cached ordinary
entries with fresh secure metadata. Recovery authenticates the checkpoint and
account/dataset binding first,
then accepts only each file's recorded before or after image; an unrelated change
keeps recovery halted. An old restored checkpoint cannot authorize clearing a
newer marker. Vault root key material cannot be created or replaced by this path.

Desktop startup uses an explicit recoverable open under the same common lock. A
regular, structurally valid pending marker opens an unavailable workspace without
reading either mixed primary file. Unsafe roots, locks, Sync directories and
linked/non-regular/malformed markers fail closed. The recovery banner can open
the existing account worker; ordinary creation/editing, clipboard capture, picker,
imports, exports and secure-workspace activation remain gated. Startup makes no
network/keyring request or checkpoint. Explicit verified data actions perform
the authenticated redo. The local poll enables editing only after the marker is
gone and both primary files validate; a live ordinary draft and its CAS ancestor
remain intact during the halt. The new graphical fixture uses a fictional
encrypted pre-WAL checkpoint and an injected account worker, without real accounts,
PAM, keyring or network. Its explicit host-bus run fails at GTK initialization,
before creating a window or temporary data, so the live display check remains
outstanding.

Projection keeps exact remote envelopes in the encrypted checkpoint so ordinary
and vault storage do not strip extensions or repeatedly restamp rounded dates.
Only approved conflict carriers and provenance enter plaintext vault metadata.
Locked secure conflict units remain deferred as a whole. With a live vault-owner
key, known v1 variants authenticate under the source UUID and reseal under the copy
UUID. The encrypted redo intent freezes exact C0 bytes before either primary file
changes. An authenticated, same-provenance C1 occupant remains in primary and in
latest desired intent; it cannot substitute for C0 evidence or upload before copy
preservation and the source release are acknowledged. Unrelated UUID occupants
halt apply. The complete primary read set includes every implicit copy, so a racing
copy edit retries the whole unit. New enabled-keyword collisions also require
engine arbitration before apply.

`src/account_review.rs` implements the journal side of an explicit account,
dataset or key review. `src/account_handover.rs` verifies and durably retains the
exact target key with all old capabilities in Secret Service before journal
publication; the native account worker and review/resume/cancel controls now call
this owner. Preparation admits the new remote
pin before authenticating the old scoped
checkpoint, finishes only an already authorized old local WAL, and freezes both
primary files plus the old checkpoint. Confirmation rechecks the fresh target
scope/feed/epoch and credential guard, validates the complete primary generation,
and retains both exact encrypted checkpoint images under `Sync/Reviews/` before
publishing the new journal through the old file CAS. The directory stays mode
0700 and new files mode 0600; unknown/linked/non-regular files fail closed. Retention
is bounded to 32 images and 512 MiB and never deletes a previous image to make room.
The 318-byte closed ACR2 receipt belongs only in the owning Secret Service journal,
contains no record payload or path, and binds complete primary file hashes, old
checkpoint presence, both ciphertext hashes and the installation clock identity.
It uses authenticated retained images to recognize the exact published image
after a lost disk/key-store reply. A current checkpoint that merely decrypts in
the target scope is insufficient proof of this transition.

The new journal preserves current local entries, held journal-only intent and
immutable C0 dependency snapshots, while clearing old server versions, inbound
pages/cursors, prepared packets, copy/source acknowledgements and deletion consent.
Old confirmed tombstones do not become deletion intent in the new library. A
pending local deletion keeps its intent but requires permission again. Reviewed
primary images protect held intent from unchanged local files; old remote merge
ancestors are not treated as ancestors of a different library. The first fresh
target snapshot can therefore preserve both conflicting bodies with new CAS facts.
Existing lost-ACK packets and inbound pages remain in the old encrypted image,
not the new data plane. The checkpoint uses the Linux-only binary schema.

The handover owner's closed schema-2 Secret Service archive keeps at most eight
review entries and 128 KiB; it refuses capacity exhaustion without evicting old
capabilities. The entry retains exact old LibraryKey, Bootstrap, PairingRecipient,
SpaceCreation and KeyMutation slot values, the verified new key/presentation,
per-install checkpoint material and the ACR2 receipt. Old capabilities remain in
protected history after their active slots change. Staging retains both encrypted
images without publishing; a durable pending entry records explicit consent before
the journal changes. Restart recognizes the exact published image or rechecks the
complete original file generation before publishing the frozen target through
the original CAS. New active slots accept only their retained old/new values;
foreign values halt recovery. Normal onboarding, disclosure, pairing, mutation,
creation and data-key use stay fenced while activation is pending. All target
slots are reread before the completed receipt removes that fence. A lost final
reply resumes without republishing, and recovery-presentation status is refreshed
against the server before returning success. Entries have exact pending, completed
or cancelled phases. Authenticated schema-1 archives migrate when the next transition
is saved; their capabilities and receipts remain retained.

Commit, resume and cancellation consume a fresh single-use local authorization
permit bound to the purpose, library scope, archive generation and exact retained
entry. Authorization remains revocable across awaited and persistence boundaries.
The worker retains an unconfirmed review while the password helper authenticates,
and rejects an expired or mismatched ticket. Native selection admits the fresh
target transport without loading the previous library's key into its data plane.
Ordinary key/data controls stay fenced until completion. A lost completion reply
restores ready controls only after normal fresh verification of that completed target.

Offline cancellation authenticates both retained encrypted images, the exact old
checkpoint, the per-install key and unchanged old active capabilities. It does not
require the original primary files to remain unchanged, so later local edits survive.
It marks the entry cancelled without changing the active key slots or primary/journal
files; candidate keys and frozen images remain protected. An already published,
foreign or advanced checkpoint cannot be cancelled. A new review can reuse a cancelled
candidate only after checking the current server authority again. Cancellation
remains available from the account window without reconnecting to a server.

Offline completion is a distinct `FinishLocalLibrarySwitch` authorization purpose,
bound to the exact retained entry and archive generation. It accepts only the exact
published target journal after authenticating both encrypted images, their receipt
hashes, scope/epoch and the source-to-target journal reset. The common library lock
stays held through all Secret Service writes and the final receipt; the per-install
checkpoint key and exact old/new active slots are rechecked at every write boundary.
A foreign, advanced, linked or corrupt journal/image, unsafe primary marker or
revoked permit stops activation. It does not reset or rewrite any primary/journal
file. Later local edits remain in place. The exact larger completed archive must
fit its size and generation limits before the first active-slot change.

The local owner completes the five active slots and any exact promoted pairing or
first-key candidate, preserving old account/pin proofs, source capabilities and
encrypted images. Before/after failures leave the same published transition for a
new locally authorized retry; a lost final receipt is inspected without replay.
Current credentials need not exist or decode. No server operation or verified
data-plane key is returned. The native worker drops its selected transport; the UI
clears selection and disables data/key controls. Fresh reconnect and selection
own subsequent live verification/review. The closed schema-2 `completed` phase
records local activation, not current server access. Unpublished transitions still
use offline cancellation; restoring an advanced/foreign frozen state is separate.

`src/key_history.rs` reads the three protected histories under the key-owner mutex
and common library lock. Its ephemeral catalogue contains library/server/key-version
metadata, closed phases/recovery statuses, bounded review counts, prior-capability
presence and exact protected-document sizes. It has no serialization or Debug
interface and returns no key, recovery code, private invitation, account hash,
checkpoint binding, ciphertext or snippet body. Each frozen-state pair is decrypted
and checked against the receipt hashes, scope/epoch and exact reset semantics before
it is labelled verified. The active encrypted journal is read once; only its opaque
digest is compared internally. No primary read, repair, slot mutation, credential
parse, HTTP operation or data-key admission occurs. Missing, malformed, linked or
unreadable saved images have closed status labels; malformed protected histories
fail closed. Mixed activation slots, pending primary markers and full or exhausted
history remain inspectable without eviction or completion.

`src/recovery_history_ui.rs` renders a native scrollable dialogue from this metadata.
It labels historical recovery evidence as saved observations, requires fresh live
verification for later use, and uses plain text with markup disabled. Backgrounding,
an observed desktop lock, cancellation and quit close it; stale asynchronous replies
are discarded. This read-only view needs no PAM permit and does not relax any
authorization boundary for disclosure, activation or restoration. Native history
browsing and separately authorized restoration are wired, including archived
queued generations. Foreign-vault recovery and protected capacity management
remain necessary.

`src/history_restore.rs` binds an opaque history selection to the exact protected
switch document and transition. It authenticates both old encrypted images and
their reset semantics before taking saved local fields as a proposal. The active
key, checkpoint material, bootstrap/candidate/capability frames, current checkpoint
ciphertext and both complete primary files are bound to fresh local consent. The
review identifies the saved and current libraries. Saved live records become new
local HLC versions; current records outside the restoration stay in place and
distinct visible or journal-only versions become disabled preservation copies.
Historical tombstones never grant current deletion permission. Current feed,
confirmed versions, original offers/CAS and outbound packets remain current facts;
old transport state, acknowledgements and key capabilities are not reactivated.

The archived data-only preservation view closes a selected restoration over
its complete source/copy graph. Supporting unchanged records are included. A
deleted or absent participant with retained live fields is restored as a fresh
local version; a retained nested source/C1 takes precedence over its parent's C0
fallback. A tombstone parent without live fields is left alone, while its retained
live originals are restored independently. Unrelated historical tombstones stay
ignored, and no archived tombstone or deletion permission enters a delivery frame.
Original ordinary or sealed C0 snapshots attach to
their parents separately from selected, freshly stamped C1 survivors. The primary
boundary groups connected outcomes and existing implicit descendants, validates
their complete read-set, authenticates all secure originals and edits with the same
borrowed key, and defers a whole component on a race or missing vault. Frozen secure
originals retain their exact nonce; provenance alone cannot replace validation
against the original carrier. All explicit selected intent is staged after C0s,
so UUID ordering cannot erase a copy's chosen later version. Other current records
and all current transport facts remain unchanged.

`src/history_restore_data.rs` resolves secure carriers before selection while the
common library lock is held. It borrows the current bounded vault session without
refreshing idle life, authenticates original carrier metadata and sealed bodies,
retains exact existing C0 nonces and seals genuinely missing originals once per
ordered archived frame. Selected carriers without an existing dependency also
receive authenticated originals. Missing copies become explicit reviewed outcomes,
including beside a later current edit; that edit becomes a disabled secure child.
The local HLC floor includes hidden carrier timestamps. Preparation revalidates
the vault session afterward, and the normal primary boundary rechecks complete
images, reserved identities and all secure versions before freezing redo. Restart
and later delivery retain those frozen seals. A current ambiguous authorized
deletion packet still replays unchanged before the new live intent.

The encrypted journal permits an authenticated copy to own its own preservation
requirements. Iterative DAG traversal rejects cycles and multiple parents. New
delivery saves descendants, then the parent's exact C0, confirms the parent source,
releases that edge, and finally sends held C1. Existing ambiguous offers always
retain their original bytes/CAS and precede new roles. Adding requirements beside
an ambiguous source offer or reparenting an already offered source is refused;
restoration stages an overlapping decision as a later data-only generation. Exact accepted
carriers are removed from files, desired intent and the reviewed primary anchor
in one WAL. The locked boundary permits that exact, journal-proven removal on a
secure primary echo without changing its body. The bounded sender continues after
a copy receipt enables cleanup, instead of reporting an empty-queue preservation
halt before doing the available work.

Restoration leaves each existing dependency, offer, CAS, acceptance, cursor and
outbound packet with its current owner. Connected active source delivery is frozen
before later selected intent enters either primary file. Queued targets fence new
normal offers, while old ambiguous offers replay unchanged. Only actual prerequisite
and source acknowledgement plus proven carrier removal release the active group.
The next generation then receives fresh prerequisites and uses the currently
confirmed CAS. Ordered overlapping generations cannot overtake one another; an
unrelated group does not block activation. Administrative cleanup changes only
exact journal-proven carriers and does not stage a new generation. It can leave
later carriers in place without vault authorization or rebuilding a released child.
The bounded queue refuses a ninth decision without dropping existing data.

An archive containing queued generations exports ordered local targets and original
copy graphs through `RestorationGeneration`, which has no server-fact fields. The
final primary update shows the freshly selected records while earlier deliveries
remain fixed in the encrypted journal. Every archived secure target, source and
original is authenticated under one borrowed vault session; source carriers verify
the original copy metadata and body. Each generation retains its own exact C0 nonce
and receives a fresh local operation nonce. Historical offers, CAS, acknowledgements,
permissions, feed and epoch never enter the active journal. The encrypted full-file
redo and protected receipt cover the entire sequence; restart needs no retained
vault key or resealing. A plain final edit cannot bypass a damaged secure generation.
Older fixed targets remain eligible even when later queued targets share their UUID,
but active prerequisite/source roles still fence delivery. Capacity is reserved before
consent; an oversized sequence leaves files, current packets and keys unchanged.

Secure outcomes borrow an authenticated bounded `Vault` owner for complete seal/hash
verification and copy resealing; its key never leaves that owner or extends idle
life. A missing, changed or incompatible vault rejects the entire proposal.
`src/primary_frozen.rs` stages the existing dependency/WAL graph and retains full
before/after ordinary and vault images, including unchanged vault headers. Both
encrypted source/WAL images are fsynced under the shared non-evicting 32-file/512-MiB
budget before a `HistoryRestore` Secret Service receipt permits any primary write.
Its closed schema-1 history retains at most eight entries/128 KiB and reserves both
terminal receipts/generations before consent. Failed pre-receipt writes can leave
encrypted orphan images; they consume capacity and cannot authorize an update.

An owned pending receipt fences normal key/data operations. Redo accepts only the
complete recorded source, unique no-intent baseline, WAL or completed journal
generation; decryption/scope alone is insufficient. The normal primary fence stays
until the protected completion receipt is durable. Lost replies retain ownership,
including completion awaiting marker removal. Fresh-purpose local resume requires
no credential/server connection and writes only recorded before/after file images.
Pre-WAL cancellation preserves later local edits and every retained image; an
already published WAL must finish. Native actions run in the serialized worker,
clear selected transport afterward and require fresh reconnect/selection before
sync. Review, vault-password and computer-password dialogs cancel on focus loss,
known lock or dismissal. Incompatible copy units and new keyword collisions fail closed
pending separate group/collision review. Foreign-vault and legacy hash repair,
capacity management and live combined verification remain unfinished.

Durable consent binds the target account/deployment so a legitimate reconnect
can refresh token generations. Each network boundary still checks the caller's
live owner. A process-local unconfirmed ticket additionally binds the exact
credential generation and both candidate-history snapshots. Native confirmation shows
the account/server, selected library, whether the key is locally retained or supplied
through a recovery code, retained-record counts and that the next explicit sync may
upload kept records to the selected library;
the computer password then authorizes that exact review. Cancellation before publication
allows fresh consent after primary changes. Managing protected history capacity
and combined live verification remain necessary for the complete workflow.

An initialized target's key can now be acquired through `src/pairing_candidate.rs`.
Its separate `PairingCandidate` Secret Service slot has a closed schema-1 history
with at most eight entries and 128 KiB. Each entry binds account/deployment and
the full target key pin, retains its private draft before creation, marks the
non-idempotent request sent before POST, and saves known invitations and claimed
envelopes before post-response scope/credential checks. Space and generation for
the response are reserved before sending or claiming; capacity exhaustion never
evicts a previous candidate. A lost creation response cannot replay the request.
Received ciphertext authenticates against the retained private draft and fresh
immutable server authority; completed candidates keep both proofs in protected
history. The owner writes no active key, bootstrap, primary file or checkpoint.

Candidate request/check/cancel and public invitation QR/copy controls live outside
the disabled normal-key panel. Polling uses the same foreground/unlocked desktop
and non-extending wall/suspend-aware deadlines as ordinary recipient pairing.
A received candidate cannot be cancelled; its retained claim can verify after
expiry without another poll or claim. Failed invitation/claim persistence returns
the exact unrecorded owner to the serialized worker; window dismissal and a lost
UI reply do not remove its quit barrier. Retry Secure Storage needs no network or
new token. Reconnect can refresh the same account, while another account cannot
resume the original pairing consent. A separate explicit library review can propose
a locally owned claimed envelope after account, membership, dataset or epoch changes
within the same server instance and library. It checks current authority, consumes
fresh local authorization and finishes the original ready flag only after the target
journal and active slots are confirmed. It preserves the original account/pin,
private proof and ciphertext; no second poll/claim is needed. Unclaimed drafts and
another server instance or library cannot supply a review key. Once the exact target
journal is published, locally authorized offline completion can finish activation
without the original live account/pin. Protected history management remains outstanding.

An existing empty selected target uses `src/bootstrap_candidate.rs` and the separate
`BootstrapCandidate` Secret Service slot. Its exact schema-1 document has a generation
and at most eight entries, capped at 128 KiB. Each entry binds the account/deployment
and complete target pin, retains the key plus authenticated recovery presentation,
and records prepared, sent, ready or lost status. Capacity exhaustion preserves all
previous capabilities. Only an owner may start initialization; fresh authority,
recovery and record reads must all establish an empty target before generation.
The server's atomic empty-library bootstrap remains the final race guard.

The prepared intent and sent status are durable before POST, with generation space
reserved for subsequent receipts. A lost response reconciles fresh immutable
authority and recovery evidence; a known winner is never reposted. If the server
still has no authority, recovery or records, retry sends the exact retained key and
envelope without new randomness. A competing winner leaves the unused candidate
protected. Every network boundary rechecks the target and current credential/key
owner. This path writes no active key, Bootstrap, primary file or checkpoint.
An interrupted candidate blocks another target pairing request until its outcome
is reconciled. Same-account token refresh can resume; another account or target pin
cannot silently reuse its capability.

Native owner-only create/resume controls remain outside the fenced normal-key panel.
Creation confirms the displayed account, server and selected library. A ready key
enters the ordinary exact library review, with fresh remote authority/recovery checks
and local authorization before activation. Its recovery presentation is promoted
to the active Bootstrap so normal locally authorized disclosure and saved-code
confirmation still apply. Confirmation retires exact promoted copies in the mutation,
first-key and handover target histories before saving the active verification-only
receipt. Earlier source capabilities and frozen encrypted journal images remain
unchanged. Before/after write failures can resume from the active presentation;
verified recovery-input adoption retires the matching initial candidate before the
handover is marked completed. A sent or ready owned candidate can be proposed by a
new explicit review after account, membership, dataset or epoch changes within the
same server instance and library. Current immutable authority must match; ordinary
create/resume still requires the original account and complete pin. A sent candidate
becomes ready only after the reviewed target journal and active slots are confirmed,
without another POST or rebinding its original history entry. Same-epoch recovery
presentations bind the reviewed pin and fresh recovery evidence; an old-epoch code
stays in protected history and is not promoted. Exact promoted duplicates can retire
across reviewed pins only within the same library/epoch with matching code/cipher or
verification proof. Original source capabilities stay unchanged. Completion writes
can fail before/after receipt and leave handover pending for fresh authorized resume.
Active keys and historical source/target keys follow this same proposal policy;
reviewing an earlier library preserves its prior entries and current local intent.
New-library metadata creation beside old keys uses `src/space_creation.rs`'s
closed schema-2 history, limited to eight entries and 64 KiB. Schema-1 intents
migrate on the next explicit create-another action without dropping their request
or completed receipt. The worker retains a memory-only one-use proposal before
native confirmation; it binds the exact credential generation, protected key-slot
beforeimages and creation-history generation, with non-extending two-minute wall
and suspend-aware deadlines. Only aggregate counts and a random UI token leave
that owner; its fingerprint is never logged or persisted. The modal names the
account/server, defaults to Cancel, and requires the same active unlocked desktop
observation. Focus loss, lock, dismissal, account actions and quit revoke review.

After confirmation, a new idempotency request is saved before POST. A validated
response is retained before checking post-request expiry or changed source state;
an interrupted request resumes its original UUID. Existing library keys, recovery
presentation, checkpoint material, primary files and journal remain unchanged.
Original-source admission remains available while the separate target needs its
existing fresh-key candidate and reviewed handover. Created metadata grants no
data-plane access or permission to transfer local records. Retention exhaustion
halts new creation without evicting older intents; capacity management remains
pending. Combined live GTK/keyring/HTTPS
verification remains outstanding.

This kernel is not a complete sync engine. It still needs legacy secure hash/stamp
repair, conflict-owned absent/deleted-copy recovery, account/rekey
reconciliation and complete secure conflict recovery. Library-key activation
and bidirectional/receive/send cycles are wired to explicit account-window actions;
verified opt-in automatic startup and scheduling now share that same owner. Unknown variant versions stay
opaque and prevent deletion/cleanup. The recovery startup gate reaches the explicit
authenticated data owner without exposing mixed primary files; its combined live
graphical/account workflow still needs verification. These
obligations remain part of the full port.
