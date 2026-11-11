# Git sync: an ordinary git host as the sync backend

Status: **available on Mac, iPhone and iPad** as a third sync provider beside iCloud
and Snippets Cloud (Settings → Sync → Cloud Provider → Git Repository). Android and
Linux do not implement it yet.

## What it is

The user runs only the Snippets client apps. Any smart-HTTP git host (GitHub, GitLab,
Gitea/Forgejo, GitVerse, a self-hosted `git http-backend`) acts as the sync service.
The apps speak the git wire protocol directly; there is no Snippets server and no
host-specific REST API.

Like every transport it only handles `WireRecord`s, which are sealed before they reach
it, so the host stores ciphertext. Secure-snippet bodies stay additionally sealed under
their vault key, exactly as with iCloud and Snippets Cloud. A Git library publishes that
vault with its key under the library's recovery code, so the one code opens secure
snippets on a new device too (see "Secure snippets: the library's vault").

## Configuration

| Field | Notes |
|---|---|
| Repository | HTTPS (`https://github.com/me/snippets-library`, with or without `.git`; no credentials, query or fragment) or SSH (`git@github.com:me/snippets-library.git`, `ssh://git@host[:port]/path`). |
| Branch | Default `main`. Validated against a conservative subset of `git check-ref-format`. |
| Username + access token | HTTPS only. Sent as HTTP Basic on every request. |

Tokens that work:

- **GitHub**: fine-grained personal access token limited to the one repository, with
  *Contents: read and write*. Any non-empty username.
- **GitLab**: personal or project access token with `read_repository` and
  `write_repository`. Any non-empty username (for example `oauth2`).
- **Gitea / Forgejo**: access token with `write:repository`; the account name as
  username.
- **GitVerse** and others: a token with repository write access. Not yet verified
  against those hosts (see Verification).

SHA-256 object-format repositories are refused.

### SSH

SSH carries exactly the same upload-pack/receive-pack requests as smart HTTP
(`GitSSHClient`); only the framing differs, because over SSH the service speaks first.
A connector reads the ref advertisement through its flush packet, writes the request,
closes the channel's input and reads the rest. Over SSH the server sees the
compare-and-swap directly, so a stale push is answered with a flush instead of
uploading a pack that would be refused, and a fetch whose wanted tip moved is a
retryable race (`git_ref_moved`).

- **macOS** runs the system `/usr/bin/ssh` (`GitSystemSSHConnector`) exactly as git
  does: the user's ssh-agent (including `IdentityAgent` agents such as 1Password or
  Secretive), `~/.ssh/config` (aliases, `ProxyJump`, `IdentityFile`) and
  `known_hosts` decide how to connect. It always passes `BatchMode=yes` (never a
  prompt), `-a -x -T`, `ClearAllForwardings=yes`, `PermitLocalCommand=no`, and `--`
  before the destination, and resets the session options a user configuration could
  set that would break an exchange (`RemoteCommand=none`, `SessionType=default`,
  `StdinNull=no`, `ForkAfterAuthentication=no`); identity, proxy and host-key choices
  stay the user's. `GIT_PROTOCOL`, askpass and `DISPLAY` are removed from its
  environment. Snippets stores no SSH secret. An unknown host is
  `git_ssh_host_key_unknown`: the message names the exact check to run in Terminal
  (`ssh -T [-p port] user@host`). The request is written through the connector's own
  duplicate of ssh's input descriptor, which only the writer closes, and stderr is
  given a short grace after ssh exits, because a `ControlPersist` master can hold it
  open indefinitely.
- **iOS** has no ssh or agent, so it uses SwiftNIO SSH (`GitNIOSSHConnector`) with
  one ECDSA P-256 key per device (`GitSSHDeviceIdentity`): created on first use, in the
  Secure Enclave when the hardware has one (the Keychain then holds only its
  device-bound handle), otherwise a software key in the device-only Keychain; usable
  after first unlock and never synced. Settings shows the public key with Copy and
  Share, to add as a deploy key with write access or to the account. Host keys are
  trusted on first use only after the user confirms the SHA-256 fingerprint; they are
  stored in preferences as `known_hosts` entries (`host` or `[host]:port`), and a
  changed key is never accepted silently. SwiftNIO SSH supports Ed25519 and ECDSA host
  keys, curve25519/ECDH key exchange and AES-GCM: a server offering only RSA host keys
  (for example Gitea's built-in SSH server with default settings) cannot be used from
  iOS (`git_unsupported_ssh_handshake`); use HTTPS there. A refused device key ends
  the connection at once instead of waiting out the server's login grace time.

Both connectors fail an exchange only after 120 seconds without progress (bytes read
or written, or the SSH send window reopening), so a slow but moving push is never cut
off; cancellation is reported as cancellation, not as a network failure. ssh's exit
status 255 is classified only by ssh's own messages, so a login script's noise cannot
turn a dropped connection into a permanent stop; a remote "temporarily read-only" is
retryable.

Values that reach an ssh command line or a remote shell are validated conservatively:
the user and host cannot start with `-`, and the path may not contain quotes, shell
metacharacters, whitespace or a `..` segment. The remote command is what git sends:
`git-upload-pack '<path>'` (an `ssh://host/~user/…` path drops its leading `/`).

**One repository, one identity.** Key scopes, the account digest and the local cache
use `canonicalIdentity`: lowercase host plus path, without scheme, user, port, leading
`/` or trailing `.git`. `git@github.com:me/lib.git` and `https://github.com/me/lib` are
the same library, so devices can mix access methods freely (and Apple devices sharing
iCloud Keychain find the same library key). Two checks are stricter than the identity:
an HTTPS token is bound to the exact address it was entered for (port included), and
while Git is active a reconnect must name the same endpoint: between two SSH addresses
the account and port must match too, and between two HTTPS addresses the port. A `%`
in an SSH path is refused, because the saved address would decode differently.

Use a dedicated, private repository. The transport never overwrites a branch that is
not a Snippets library, but pointing it at a large code repository still makes setup
download that branch's snapshot once.

## Repository layout

One branch holds one library:

```text
snippets-sync.json            {"datasetID","format","recordProfile","schemaVersion"}
README.md                     explains the repository to someone browsing it
keys/recovery.json            the library key sealed under the offline recovery code
keys/vault.json               the secure-snippet vault: its identity, and its key under the same code
records/<2 hex>/<uuid>.json   {"blob","deleted","id","rev"}: one WireRecord, canonical JSON
```

`records/` is fanned out by the first two hex digits of the record id, so a commit
rewrites the root tree, `records/`, one small directory per touched prefix, and the
record files. Any other file in the tree (a LICENSE, notes) is preserved byte-for-byte
on every commit.

`initializeRepository()` creates the branch with the manifest, README,
`keys/recovery.json` and `keys/vault.json` only when the branch does not exist. An existing library is adopted. A branch without the manifest
`format` marker is someone else's data and is refused (`git_branch_not_snippets_library`).
A manifest with an unknown `schemaVersion` was written by a newer build and stops sync
(`git_sync_schema_unsupported`). The data plane never creates a repository implicitly
(`git_repository_not_initialized`).

`schemaVersion` is 1 for a library as created and 2 once its keys were replaced (see
"Replacing the keys"). The layout is identical. The number keeps out 1.4.0, which
predates `keys/vault.json` and would join with its old vault and upload secure snippets
under the retired vault key.

## Plain-text libraries

A library is created either **encrypted** (manifest `recordProfile`
`snippets-wire-v1`, everything above) or **plain text** (`snippets-plain-v1`), chosen
once in the creation dialog. A build that does not know a profile refuses the library
(`git_sync_schema_unsupported`). Plain text trades confidentiality of ordinary
snippets for being able to browse, diff and edit them in the repository: anyone who
can read the repository can read them. Secure snippets and all deletions stay
ciphertext under `records/`, exactly as in an encrypted library; the library key,
`keys/vault.json` and the recovery code work the same way. In a plain-text library the
recovery code is therefore what protects secure snippets: the key for their bodies is
wrapped under it, and their names, keywords and tags are sealed under the library key
it opens.

Each device pins the mode the user agreed to when creating or joining. A manifest that
later names another mode (someone with push access turning an encrypted library into
plain text) stops sync with `git_library_mode_changed`; reconnecting in Settings shows
the mode and asks again. A device connected to an encrypted library is never given the
plain-text codec at all.

Layout additions:

```text
snippets/<slug>-<first 8 hex of id>.md   one live, non-secure snippet
records/<xx>/<uuid>.json                 secure snippets and tombstones (ciphertext)
```

Each Markdown file is front matter, then the body verbatim:

```text
---
name: "Greeting"
keyword: "hi"
tags: ["work"]
enabled: true
pinned: false
id: 617a0002-0000-4000-8000-000000000002
sync: <base64url, unpadded, of canonical JSON {createdAt, hash, hlc, origin, schemaVersion, updatedAt, x}>
---
Hello there!
```

- Writers emit exactly these lines in this order: `name`, `keyword` and `tags` as
  canonical JSON (`CanonicalJSON`), booleans as `true`/`false`, the id lowercase, then
  `---`, the body bytes, and one `\n`. A snippet is rendered only if it has no `x`
  extension keys (they can hold a secure loser's conflict snapshot or future fields
  meant to stay encrypted) and its file reads back as exactly the same envelope;
  anything else is written as ciphertext under `records/`.
- Readers strip a leading UTF-8 BOM and drop the one final `\n` (`\r\n` when the
  closing `---` line ends in CRLF). They accept CRLF, blank lines, `#` comments, lines
  without a key, bare or single-quoted strings, JSON, bare, bracketed or YAML block
  (`- item`) tag lists, `yes`/`no`/`1`/`0`, and ignore unknown keys and an invalid `id`.
  A file that starts with `---` but does not parse (no closing line, say) is delivered
  as unreadable under the id it declares, so the engine quarantines that snippet; it is
  never read as a new snippet or a deletion. A file a newer Snippets wrote (a `sync`
  object with a later `schemaVersion`, or with keys beyond the eight above) is delivered
  the same way (`tooNew`) and never normalized, so an older build cannot downgrade it.
- `sync` holds what people never edit: the snippet `id` (lowercase), the envelope's
  `hlc` and `origin` strings, `schemaVersion`, `createdAt`/`updatedAt` as
  reference-date seconds (`Double`, bit-exact), the `x` bag, and the envelope `hash` it
  was written with.
- **Reading.** Rebuild the ten-key envelope from the front matter, body and `sync`
  (`secure` false, `deleted` false, `contentHash` = SHA-256 of the body) and compute its
  hash. Equal to `sync.hash`: the file is exactly what a device wrote. Otherwise it was
  edited by hand: build the envelope with `hlc` = the `sync` clock plus one counter tick
  (wall + 1 and counter 0 on overflow) on the foreign device `00000000`, `origin`
  `00000000`, tags normalized, timestamps from `sync`. A file with no usable `sync` is
  new: `hlc` `000000000000-0000-00000000` (wall 0, counter 0, foreign device), timestamps 0, id from its `id` line or, without one, the
  first 16 bytes of SHA-256 of `snippets-git-plain-file-v1\n<path>` with version 8 and
  RFC 4122 variant bits. A file with no front matter is all body, named after its file.
  Every device derives the same envelope from the same bytes.
- **Ids.** A file's id comes from the file alone, so every device agrees whatever its
  history: the `sync` id, else the first valid `id` line, else the path-derived id
  (also for a file whose front matter does not parse; its lines are scanned on bytes,
  so CRLF works). A file whose `id` line disagrees with its `sync` id, or that is read
  under another id, is an edit, and normalizing rewrites its `id` line. Several files
  claiming one id are copies: the file named `…-<id8>.md` keeps the id (else the first
  by name) and every other copy becomes its own snippet with a path-derived id. A file
  restored by hand while a tombstone under `records/` shadows its id is overwritten when
  that snippet becomes live again, so it cannot take the snippet over.
- **Records.** The engine still sees ordinary sealed records: the transport opens
  what it is given with the library sealer and renders ordinary snippets as Markdown,
  and seals what it reads back. A record's version is its current file's blob id,
  `git-blob-sha1:<hex>` under `records/` and `git-md-blob-sha1:<hex>` for a Markdown
  file, so a version whose file is gone can be told apart without the cache. A ciphertext record wins over a Markdown file with the
  same id, so a readable file can never shadow a secure snippet or a deletion. A record
  that changes kind (made secure, deleted, recreated) moves between the directories in
  one commit; a renamed snippet's file is renamed, otherwise its path is kept.
- **Edits and deletions made in the repository.** A device that reads an edited file
  delivers the derived revision and then, best effort, commits the file rewritten with
  fresh `sync` metadata ("Normalize … edited outside Snippets"), so that a later edit
  orders after this one. A Markdown file deleted by hand is delivered as a tombstone
  (one tick after the file's clock, without the in-app deletion marker, so the engine's
  unexplained-deletion safety applies) and recorded under `records/` in the same
  commit. Devices race to normalize with identical bytes and converge; a device that
  cannot push skips it. A hand deletion not yet recorded is retried on later fetches
  until a tombstone exists. An edit the engine submits for a file deleted by hand is
  answered with that derived deletion as a conflict, never a reset; a device that lost
  the deleted file from its cache answers with a deletion at the lowest clock, so the
  edit wins. A device whose push was refused pauses normalizing for an hour. Deleting an
  encrypted record is still a reviewed reset.
- **Consent.** Joining a plain-text library asks first (both platforms): this device's
  ordinary snippets become readable in the repository and its history.
- Not supported by hand: restoring a deleted snippet by restoring its file (the
  tombstone wins), and editing `sync` or `id` lines.

## How the sync contract maps onto git

| Sync concept | Git |
|---|---|
| Account identity | SHA-256 of the canonical repository location and ref. Each connected library also gets its own local base and journal (keyed by location, branch and dataset), so a different repository never reuses another one's record versions. While Git is active, Settings refuses to retarget it to a different library; that needs a switch away and a new Switch and Sync. |
| Dataset identity | Derived from the manifest's random `datasetID`. A replaced manifest or recreated branch is a remote reset that requires review; it is never merged silently. |
| Record version (CAS token) | The git blob id of the record file (`git-blob-sha1:<hex>`; `git-md-blob-sha1:<hex>` for a plain-text library's Markdown file). It changes whenever the stored bytes change and survives rebasing onto another device's commit. |
| Cursor | `git1.<datasetID>.<commit>`, the commit the engine last fetched. |
| Fetch | Diff the cursor commit's tree against the current head locally and return exactly the changed records, however many commits lie in between. A cursor the device can no longer diff (cache lost, other dataset) returns a full snapshot with `isFullResync`. |
| Submit | One commit per batch, CAS-checked per record against the current head, in order (the same id twice behaves like two sequential writes). Identical bytes are accepted with no commit. |
| Batch atomicity and contention | The push names the head it was built on. receive-pack moves the ref only if it still points there: the compare-and-swap for the whole library. A lost race re-reads the new head, re-evaluates every record's CAS against it, and retries (5 attempts, then `rateLimited`). A rejection that leaves the branch unchanged (protected branch, hook, permission) is permanent (`git_push_rejected`). |
| Tombstones | Record saves with `deleted: true`, never file removals. |
| Physically removed record file | Remote data loss: `remoteDataReset(git_record_removed)`, resolved by the existing reviewed restore. |
| Push notifications | None. `pollInterval` is 60 s. Polling an unchanged branch costs one `info/refs` GET. |

Do not rebase, force-push or hand-edit the branch. A manual `git revert` is handled
(the reverted content is delivered as a change), but removed files and replaced
manifests deliberately stop sync for review.

## Protocol subset

- Smart HTTP or SSH, protocol v0/v1 framing. Every host still speaks it, and
  `git-receive-pack` has no protocol-v2 equivalent, so one code path covers both
  directions. Dumb HTTP is refused.
- **Fetch**: `want <head>`. A device with nothing cached asks for the tip alone
  (`deepen 1`); one holding snapshots sends them as plain `have`s (see "Cost and
  performance"). If a pack turns out incomplete, or catching up through a long history
  exceeds the response limit, the fetch is repeated with no haves. No `multi_ack`, so
  the response is one ACK or NAK (GitHub sends one per common have), an optional
  shallow-info section, and the pack, side-band-multiplexed or raw.
- **Packs**: version 2/3, offset and reference deltas, checksum verified, with bounds
  on object count, object size, total inflated bytes and delta depth. Pushed packs are
  undeltified: records are ciphertext and would not delta-compress.
- **Push**: `report-status`, with `side-band-64k` and `quiet` when offered.
- **Redirects** are followed only for GET and only to the same scheme, host and port,
  so the explicit `Authorization` header cannot leak to another origin. As git does,
  later POSTs use the URL that ref discovery was redirected to.

## Cost and performance

Measured against a private GitHub repository from a Mac on a home connection, with a
200-snippet library (`GitSyncHostBenchmarkTests`, opt-in; SSH uses the user's own ssh
and agent):

| Operation | HTTPS | SSH (macOS) |
|---|---|---|
| Idle poll, nothing changed | 1 request, ~0.25 s, 1.3 KB | 1 exchange, ~0.6 s |
| Make one edit (round + push) | 3 requests, ~1.6 s | ~2.8 s |
| Other device picks up 1 edit | 2 requests, ~0.5 s, 6 KB | ~1.2 s, 6 KB |
| Other device picks up 20 edits | 2 requests, ~0.6 s, 35 KB | ~1.2 s, 36 KB |
| Fresh device, whole library | 2 requests, ~1.0 s, 376 KB | ~1.6 s, 376 KB |
| First upload of 200 snippets | 9 requests (4 commits), ~6.9 s | ~9.5 s |

The transport polls every 60 seconds while sync is on (macOS for as long as the app
runs, iOS while it is in the foreground), so an idle device costs one small request
a minute: about 1.9 MB a day for an always-on Mac. Snippets uses only the git
protocol, never a host's REST API. A rate limit or overload answered with HTTP 429 or
503 is honoured through `Retry-After` (1 s to 1 h); other failures back off
exponentially. Either way changes wait, nothing is lost, and **Sync Now** bypasses the
backoff.

Three details keep this cheap:

- A round's fetch reuses the branch advertisement its preflight read a moment before,
  if it is the very next operation and under 3 seconds old. Any push, another
  preflight or a later fetch asks again.
- Only a device with nothing cached asks for a shallow tip (`deepen 1`); one with
  snapshots names them as plain `have`s. Declaring them shallow made servers resend
  the whole snapshot on every change. If a server leaves out an object it assumed came
  with history, the install fails and the fetch is repeated without haves.
- On macOS, ssh shares one authenticated connection per host (`ControlMaster=auto`,
  `ControlPersist=90`) through sockets in `/tmp/snippets-ssh-<uid>`, which must be a
  0700 directory owned by the user (otherwise connections are not shared). The socket
  name is `%C` plus a short hash of the destination as typed, because `%C` hashes the
  resolved host: two `~/.ssh/config` aliases for one host (a deploy key each) must not
  share a connection. iOS keeps one pooled connection per host, open 90 seconds after
  its last exchange; a channel that does not open within 15 seconds retires the
  connection and retries once on a fresh one, and a stalled exchange closes only its
  own channel.

GitHub acknowledges every common `have` (reference git acknowledges only the first);
the client skips extra `ACK`/`NAK` lines before the pack.

History grows by roughly the changed snippet's ciphertext per edit: 26 commits cost 39
KB on top of a 385 KB tip in the measurement above (about 1.9 KB per edit). New
devices download only the tip, so history affects storage, not sync speed.

## Local snapshot cache

`GitObjectCache` keeps complete snapshots (commit, trees, record blobs) of the four
most recently used commits, plus a pinned copy of the commit the last fetch returned as
its cursor. Objects are stored content-addressed as `"<type> <size>\0<content>"` and
re-hashed on every read.

The cache is an optimization, never a source of truth: a corrupt or missing object is a
miss, and any operation that hits one discards the cache and retries once against a
fresh download. Deleting the directory at any time is safe and costs one full snapshot
fetch. It holds only what the host also holds (ciphertext and tree listings), never a
credential or cursor. Directories are mode `0700`.

## What the host can see

Record ids (file names), record count and sizes, the cleartext `deleted` flag (which
`WireRecord` already exposes to every backend), and commit times, which reveal when a
device synced. Commit authorship is fixed (`Snippets Sync <sync@snippets.invalid>`) and
messages carry only a record count. No device name, account, path or stable per-install
value is written.

## Failure vocabulary

`SyncTransportFailure` details are closed codes; no server text, URL or token is ever
included.

| Detail | Meaning |
|---|---|
| `git_http_401`, `git_http_403` (`authenticationRequired`) | Token missing, expired, or without write access. |
| `git_repository_not_found` (`authenticationRequired`) | Wrong URL, or a token that cannot see a private repository (hosts answer 404 for both). |
| `git_repository_not_initialized` | The branch does not exist (never created, or deleted); reconnect in Settings. |
| `git_branch_not_snippets_library` | The branch holds other data and will not be touched. |
| `git_sync_schema_unsupported` | Written by a newer Snippets build. |
| `git_push_rejected` | The host refused the update without the branch moving. |
| `git_library_replaced` | The branch now holds a different library than the one this device joined, for example because its keys were replaced; reconnect with the newest recovery code. |
| `git_key_required`, `git_credential_required` | This device lacks the library key or the access token; fix in Settings. |
| `git_invalid_path` | Programming error: only `keys/` files may be read or written outside records. |
| `dataset_reset`, `git_record_removed` (`remoteDataReset`) | The remote library was replaced underneath a pinned dataset, or a record file was removed by hand (detected on fetch, or when an edit names a generation whose file is gone); review required. |
| `git_unsupported_*` | The server lacks a required capability (smart HTTP, `report-status`, SHA-1), offers no SSH algorithm this client supports (`ssh_algorithms`, `ssh_handshake`), has no git on its SSH side (`ssh_no_git`), or this Mac has no ssh (`ssh_unavailable`). |
| `git_ssh_host_key_unknown`, `git_ssh_host_key_changed` (`authenticationRequired`) | The SSH host key is not trusted yet, or differs from the trusted one. macOS: known_hosts; iOS: confirm the fingerprint in Settings. |
| `git_ssh_permission_denied` (`authenticationRequired`) | No offered key was accepted, or the key is read-only for this repository. |
| `git_protocol_*`, `git_pack_invalid`, `git_http_5xx`, `git_network_*`, `git_ssh_connection`, `git_ssh_timeout`, `git_ssh_failed`, `git_ssh_remote_failed`, `git_ssh_remote_temporary`, `git_ssh_spawn`, `git_ref_moved` (`unreachable`) | Retryable transport problems. |

## Limits

The engine offers every pending record in one submission; the transport splits it
into commits of at most 50 records and about 24 MiB of ciphertext, each CAS-checked on
its own. If the host or a proxy answers a push with HTTP 413, the commit is halved
until it fits; a single record that still does not fit is refused on its own
(`git_push_too_large`). If a later commit fails, the earlier ones are still reported accepted and the
rest come back as retryable rejections. A record over 900,000 bytes (or with a revision
over 256 bytes) is refused on its own and the rest of the batch syncs. A record file
that cannot be parsed is delivered as an unopenable record, so the engine quarantines
that one snippet instead of every device stopping.

Responses: 8 MiB for advertisements and push reports; packs 512 MiB on Mac and 128 MiB
on iOS, with 1 GiB (Mac) or 384 MiB (iOS) of total inflated objects. Both HTTP and SSH
enforce the response limit while the body arrives. A full snapshot is held in memory
while it is parsed; that is comfortable for normal libraries, and is the first thing
to stream if very large libraries need it.

History grows by one commit per synced batch. Ciphertext does not delta-compress, so a
repository grows by roughly the size of each changed record. Compacting history would
rewrite the branch, which other devices would correctly treat as a reset; it is not
implemented.

## Verification

```sh
# Primitives, transport and two-engine end-to-end tests. Each request is served by
# the real `git http-backend` against a temporary bare repository, without a socket.
xcrun swift test --package-path CorePackage --filter 'GitPrimitives|GitSync'

# Opt-in, against a real host. Uses and deletes a random snippets-live-test/<id>
# branch. Use a scratch repository that already has one commit: hosts refuse to delete
# a repository's default branch.
SNIPPETS_GIT_SYNC_LIVE_URL=https://github.com/me/scratch \
SNIPPETS_GIT_SYNC_LIVE_USERNAME=me \
SNIPPETS_GIT_SYNC_LIVE_TOKEN=… \
xcrun swift test --package-path CorePackage --filter GitSyncLiveHost
```

Use `xcrun swift`: the swiftly toolchain selected by `.swift-version` cannot load
CryptoKit from the current Xcode SDK.

The live test has passed against Gitea 1.22.6, with both the `.git` and plain URL forms.
It has not yet been run against GitHub, GitLab or GitVerse.

## Connecting a device (Settings)

Settings → Sync → Cloud Provider → **Git Repository…** opens the same flow on both
platforms (`MacGitSyncViewController`, iOS `GitSyncSettingsViewController`), driven by
the shared `GitSyncSetup`:

1. Before anything is connected the screen says to create a new private repository
   without a README. The user enters the repository address, branch and, for HTTPS,
   user name and access token (a missing `https://` is added). Guidance follows the
   address as it is typed (`GitSyncSetup.tokenHelp`, `deployKeyLink`): for GitHub a
   fine-grained token limited to the repository with Contents read and write, for
   GitLab a project access token with `read_repository`/`write_repository`, each with a
   link to create it. The user name is optional for github.com (`x-access-token`) and
   gitlab.com (`oauth2`). An SSH address hides the token fields; on macOS the sheet
   names the exact `ssh -T` command, on iOS the screen shows numbered deploy-key steps,
   this device's public key (labelled `snippets-iphone` or `snippets-ipad`) and, for
   GitHub and GitLab, a link to the repository's deploy-key page. On iOS the first
   connection to a host asks the user to confirm its host key fingerprint and then
   repeats the step; for github.com, gitlab.com, codeberg.org and bitbucket.org on port
   22 the prompt says the key matches the one the host publishes
   (`GitSSHHostKeyStore.publishedFingerprints`). The user still confirms.
2. **Inspect** reports *empty*, *library* or *foreign*. Nothing is written. A foreign
   branch (a README, say) offers **Use Branch “snippets”**, which retries on that
   branch.
3. An empty branch becomes a library only after the user chooses **Create Encrypted
   Library** (the default) or **Create Plain-Text Library**. A plain-text library is
   refused (`publicRepository`) when the repository can be cloned anonymously over
   HTTPS: 200 with the upload-pack advertisement is public, 401/403/404 private,
   anything else unknown. Redirects are followed only within the same origin. An SSH
   address is checked only at the well-known forges it maps to (github.com,
   ssh.github.com, gitlab.com, altssh.gitlab.com, codeberg.org, bitbucket.org); an alias
   or self-hosted SSH host is unknown. Unknown asks the user to confirm the repository is
   private before creating.
   A fresh 64-byte library key is minted and stored in the Keychain *before* the
   creating push, so a crash after the push still leaves this device able to open
   the library. The recovery envelope is written in the same commit, and the recovery
   code is shown exactly once, large and monospaced (with a Copy that marks the
   pasteboard concealed, transient and this-Mac-only and clears it after two minutes on
   Mac, and local-only with a two-minute expiry on iOS; the iOS sheet hides before
   app-switcher snapshots and cannot be swiped away). The same commit carries
   `keys/vault.json`: this device's secure-snippet vault (after device-owner
   authentication when it already has one, otherwise a vault minted on the spot, with
   no prompt), its key wrapped under the same code. If the push's response is lost, the repository is re-inspected: the key
   is forgotten only when the library provably does not exist, and the code is shown
   whenever the library does, even if saving the connection then fails. If the
   repository cannot be checked either, the key is kept and the code is shown with a
   warning, because it opens the library if one was created.
4. An existing library is joined with the key this device already holds, or with
   the recovery code. A wrong code is rejected before anything is saved. The device
   adopts the library's vault, and the code restores the vault key, so secure snippets
   open without another step. A device whose own secure snippets are sealed under a
   different vault is refused before anything is saved (`differentVault`). Joining a
   plain-text library asks first unless this device already agreed to the same library,
   repository and branch, and the mode the user agreed to is saved and pinned (see
   "Plain-text libraries").
5. Only then are the coordinates (UserDefaults) and token (device-only Keychain item,
   service `com.khm.snippets.git-sync.credentials`) saved, and the shared **Switch and
   Sync** confirmation (`SyncBackendSelectionStore.switchConfirmation`; "Start Syncing
   with Git?" when sync is off) selects Git as the provider. Success shows in the status
   line; only a failed switch shows an alert.

When Git is already active, only its own repository and branch can be reconnected
(inside `SyncCoordinator.withQuiescedCloudTransport`): a new token, a recovered key, or
— after an explicit **Connect and Merge** confirmation — the library that replaced the
old one on that branch (its keys were replaced, say; the device's secure snippets are
then re-sealed under the new vault key), or a new library created on the branch after
it was deleted. A
branch holds exactly one library, so this is how `git_library_replaced` and
`git_repository_not_initialized` are resolved in place. A different repository or
branch is refused until sync is switched away. Joining an
existing library first checks that the token can write (the receive-pack
advertisement), so a read-only token fails at setup rather than at the first sync.
While a switch *to* Git is unfinished, or a switch away from it has not yet selected
its target, the repository cannot be changed: the switch receipt pins that location.
Once the target is selected the old source location is no longer consulted, so an
unfinished switch away from Git never blocks reconnecting it. The access token is stored with the repository and
user it belongs to, so stale coordinates never send another host's token. Leaving the token field empty keeps the
saved token, but only for the same repository, branch and user name. **Remove from
This Device** forgets the coordinates and token (only while Git is not the active
provider); the library key stays so reconnecting needs no code, and nothing in the
repository is touched.

## Library keys and the recovery code

Each Git library has its own key, never shared with iCloud sync or Snippets Cloud.
`GitSyncKeyStore` stores one Keychain record per library, bound to the repository
location, branch and dataset id. It uses the default Keychain tier: on builds entitled
to the shared access group that tier is synchronizable, so iCloud Keychain carries the
key to the user's other Apple devices and they connect without the code. Other devices
use the recovery code.

`SyncKeyStore` never mints a key while Git is the provider: a missing key stops sync
with `git_key_required` ("enter the recovery code in Sync settings") instead of
encrypting the library under a key no other device has.

The recovery code reuses the vault recovery-key format: 128 random bits as 27
Crockford symbols with a full check symbol, so typos are reported as typos.
`keys/recovery.json` seals the portable key bundle with AES-256-GCM under
HKDF-SHA256(code), with the dataset id in the associated data. The code is bound to
the library, not to the host: moving the repository keeps it valid. **New Recovery
Code** (after device-owner authentication) re-seals the key under a new code. Git
history keeps every earlier envelope, so this replaces a lost code but cannot revoke a
leaked one; revoking means **Replace Keys** (see "Replacing the keys").

The connected dataset id is part of the transport configuration. If the branch later
holds a different library, sync stops with `git_library_replaced` until the user
reconnects, rather than uploading this device's library under its old key.

Debug builds accept a loopback `http://` repository only with
`SNIPPETS_GIT_ALLOW_LOOPBACK_HTTP=1` (or in iOS UI-test launches); Release builds are
HTTPS-only.

## Secure snippets: the library's vault

A secure snippet's body is sealed under the vault key (`K_lib`, see
`docs/cloud-sync.md`), bound to the vault's `kid`. Neither travels with the library
key, and with Git there is usually no iCloud Keychain to carry them (Linux has none).
So the library owns its vault: one dataset, one library key, one vault, one recovery
code.

`keys/vault.json` (`GitSyncVault`, `snippets-linux/src/git_vault.rs`) holds
`{kdf, kid, schemaVersion, vaultSalt, wrapRecovery}`: the vault's identity and the vault
key wrapped under the library's recovery code with `KeyWrap` (purpose `recovery`, the
wrap `vault.json` keeps as `wrapRecovery`). The file is sealed with AES-256-GCM under
HKDF-SHA256(library key, salt = library salt, info = AAD), AAD
`snippets-git-vault-v1\0<dataset>`. It uses the same four-key JSON framing as
`keys/recovery.json`.

- **The library key never yields the vault key.** Opening the file takes the library
  key; opening the wrap inside takes the recovery code, which no device stores. Sync
  still runs without access to any secure body, and revealing one still asks for the
  device owner.
- **A passphrase wrap is never published** (a repository is where an offline guessing
  target must not go). Neither is `wrapCLI` or any `x` extension.
- **Creation.** `createLibrary` publishes this device's vault: an existing one after
  device-owner authentication (`VaultSession.withOneUseAuthentication`), otherwise a
  freshly minted key that is stored in the Keychain before the push, like the library
  key. The vault document is written only once the library exists. A vault that already
  had its own recovery key keeps it: that key still restores the vault on this device.
- **Joining.** `connect` reads the file, refuses a device whose vault is another one
  and in use (`differentVault`), then writes a records-free `vault.json` for the
  library's `kid` and restores the vault key from the code. An unused vault (no
  records, and no secure envelope in the sync metadata or base) is replaced: every
  library mints one, so a device moving between libraries usually has exactly that. A
  code that opens the library but not the wrap (issued by a build that rewrote only
  `keys/recovery.json`) still joins; secure snippets then wait for a code that does.
- **Nothing mints a rival.** While Git is the provider, `SecureSnippetStore` never
  creates a vault on its own ("make this secure" reports
  `libraryVaultSetupRequired`), because a second `kid` is a second crypto scope that
  every other device refuses.
- **New Recovery Code** rewraps the vault key and replaces both envelopes in one
  commit. It needs the vault unlocked, which is also its owner check. A device that
  cannot open the vault cannot issue a code (`vaultKeyUnavailable`). As with the
  library key, history keeps earlier wraps: a leaked code is revoked only by replacing
  the keys.
- **Set Up Secure Snippets…** (Settings → Git, shown while secure snippets do not work
  on the device) adopts the published vault, asking for the recovery code when the key
  is not in the Keychain.
- **Libraries created by 1.4.0** have no `keys/vault.json`. The device that holds the
  vault publishes it with New Recovery Code; other devices then enter that code under
  Set Up Secure Snippets. If no device has a vault, Set Up Secure Snippets mints one
  with a new code, but only after a completed sync shows no secure snippet waiting
  for a vault held elsewhere (`vaultHeldElsewhere`, `syncBeforeSecureSetup`).
- A file written by a newer build (`unsupportedVersion`) is never replaced. A damaged
  one does not block ordinary snippets and is replaced by the next New Recovery Code.

Not supported yet: bringing secure snippets that are sealed under another vault into a
library the device was not already syncing (they must be made ordinary or deleted
first; only a device following its own library to the one that replaced it re-seals
them, see below), and secure snippets on Linux (the Linux app mirrors the file format,
refuses to issue a recovery code for a library that has one, and reports `vault_locked`
for secure records).

## Replacing the keys

**Replace Keys…** (Settings → Git, on the device where Git is the active provider)
rotates everything that protects a library: the library key, the vault key and the
recovery code. Use it when a recovery code may have leaked or a device was lost.

A library's key is bound to its dataset id, so new keys mean a new library in the old
one's place (`GitSyncSetup.rotateKeys`, `GitSyncTransport.replaceLibrary`):

1. Sync runs once and must end idle with no secure snippet waiting for a key.
2. The vault is unlocked (the one device-owner prompt) and every secure snippet is
   opened once, so one that cannot be re-sealed stops the rotation before anything
   changes. Unresolved secure sync conflicts stop it too (`pendingSecureConflicts`):
   their losing sides are ciphertext under the old key.
3. A new dataset id, library key, vault key and recovery code are minted. Both keys go
   into the Keychain before the push, as when a library is created.
4. One commit on top of the current head replaces the manifest (new dataset id, same
   mode, `schemaVersion` 2), writes `keys/recovery.json` and `keys/vault.json` as the
   whole of `keys/`, and removes `records/` and, in a plain-text library, `snippets/`.
   Files that are not Snippets' own stay. The push names the commit the engine last
   fetched: if the branch moved since, nothing is written (`git_ref_moved`), sync runs
   again and the step is retried, so the old library is never dropped with changes
   this device has not merged. It is an ordinary fast-forward commit, never a rewrite.
5. `vault.json` is re-sealed in one write under the library lock: every record is
   opened with the old key and sealed under the new one with the new `kid` in its
   associated data, and its keyed content hash is recomputed. The old passphrase and
   recovery wraps are dropped. The coordinates move to the new dataset, the old library
   key is forgotten, and the new code is shown once.
6. Sync restarts on the new dataset, which has its own base and journal, and uploads
   the library again under the new keys.

If the response to the push is lost, the repository is inspected: the new library
there means the move is finished and the code shown; the old one means the new keys are
forgotten. If it cannot be checked, the keys are kept and the code is shown with a
warning (`rotationUncertain`). A crash after the push leaves the device on the old
dataset with both new keys in its Keychain; reconnecting (below) completes the move
without the code.

**Other devices** stop with `git_library_replaced` and say so. Reconnecting in Settings
(**Update**, then **Connect and Merge**) asks for the new recovery code, opens the
library key and the vault key with it, and re-seals the device's own secure snippets
from its old vault key to the library's (`SecureSnippetStore.resealIntoLibraryVault`,
one device-owner prompt). The first round on the new dataset is the ordinary
loss-preserving merge of the device's library with the repository:

- Snippets that are the same on both sides stay as they are. Two devices that re-seal
  the same secure body produce different ciphertext but the same keyed hash, so that
  is not a conflict.
- A snippet the device changed while it was away wins or loses by its clock, and the
  losing version is kept as a conflict copy. For a secure snippet that copy is made
  once the vault is unlocked; until then sync reports that it is waiting.
- There is no common ancestor across the replacement, so a deletion the device had not
  uploaded, or had not received, is not carried over: the snippet comes back. Syncing
  every device before replacing the keys avoids both.

A device that cannot open its own secure snippets (its vault key is missing) cannot
move them and is refused before anything is saved (`differentVault`); after **Forget
Secure Snippets** it reconnects and downloads the library's copies. A device whose
Keychain received the new library key from iCloud Keychain is still asked for the code
when the vault key did not arrive with it. Re-sealing happens only here, where a device
follows the library it was syncing: anywhere else a vault in use may be shared with
another provider's devices and is never re-pointed.

What replacing the keys does and does not do:

- Nothing written after the replacing commit can be opened with the old recovery code,
  library key or vault key. A stolen device keeps what it already has but receives
  nothing more, and cannot rejoin without the new code.
- Git history is not rewritten. Commits before the replacement still hold the old
  ciphertext, and the old code still opens them for anyone who can read the
  repository. Secrets that may already have been read must be changed at their source.
  To remove the old ciphertext as well, create the library again in a new repository
  and delete the old one.
- The retired vault key is deleted from a device-only Keychain once the vault is
  re-sealed. A key that iCloud Keychain shares is left in place, because deleting it
  would delete it on the user's other devices before they re-sealed their own secure
  snippets. It opens nothing in the new library, and nothing in the repository without
  the retired library key.

Linux reads a replaced library (`schemaVersion` 2) and reconnects to it with the new
code, but cannot replace keys itself.

## Integration tests

```sh
# Mac Settings sheet end to end, in process (real git http-backend via URLProtocol).
xcodebuild -project Snippets.xcodeproj -scheme Snippets -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/snippets-macos-derived \
  CODE_SIGNING_ALLOWED=NO test -only-testing:'Snippets macOSTests/GitSyncSettingsMacTests'

# Multi-process macOS ⇄ iOS: production store/bridge/coordinator on both platforms
# against one loopback repository over HTTPS, then over SSH, then the iOS Settings UI,
# then a Mac joining the UI-created library with the code the UI copied. Reuses an
# idle iPhone simulator.
scripts/test-git-sync-integration.sh
```

CorePackage also runs SSH through a stand-in `ssh` (deterministic framing, failure
classification, SSH and HTTPS devices sharing one library) and through the real OpenSSH
client and an unprivileged loopback `sshd` with a private agent (`GitRealSSHTests`:
agent-only authentication, changed and unknown host keys, an empty agent). Both SSH
harnesses pin ssh to a private configuration, `known_hosts` and agent socket; they never
read the user's own keys, agent or configuration.

The script's phases are: macOS creates the library and syncs a snippet; a fresh iOS
installation joins with the recovery code (a wrong code is rejected first), edits and
adds; a fresh macOS installation joins, verifies and deletes; a fresh iOS installation
verifies the deletion; a fresh macOS installation joins and replaces the library's keys;
a fresh iOS installation is refused with the old recovery code and opens everything,
secure snippets included, with the new one. Over SSH, through a throwaway loopback `sshd` whose
`authorized_keys` force a wrapper that runs only git services inside the run's
directory: macOS creates a library with the system ssh and a key held only by a private
ssh-agent; a fresh iOS installation meets the untrusted host key, checks its
fingerprint, trusts it, joins with the recovery code through SwiftNIO SSH and its device
key, and adds a snippet; a fresh macOS installation sees it. Then the iOS UI test creates a library in a second repository
through Settings, copies the code and switches sync, and a fresh macOS installation
joins it. After each stage the bare repository is checked for the record count, the
key envelope, the fixed commit authorship, and the absence of every plaintext marker
and recovery code anywhere in its history.

## Linux

The Linux app (`snippets-linux/`, Rust/GTK) implements the same repository layout,
identities, recovery envelope and failure vocabulary with the system `git` CLI over a
private bare cache (`<data>/snippets/GitSync/<digest>.git`). It plugs into the
existing Linux sync owner through `receiver::Remote`/`sender::Remote`. See
`docs/linux/GIT_SYNC.md`.

- The README, manifest and record bytes, `keys/vault.json` (a shared known-answer
  file in `GitSyncVaultTests` and `git_tests.rs`), `canonicalIdentity`, the key-scope
  account (`git-library-v1-…`), the account/dataset digests, `git-blob-sha1:` record
  versions and the `git1.<dataset>.<commit>` cursor are byte-identical. Because the
  Linux inbox takes 10 records per page, Linux adds a local-only paging cursor,
  `git1p.<dataset>.<target>.<base|full>.<offset>`. It never leaves the device.
- HTTPS tokens travel only in an environment-only `http.extraHeader`. SSH uses the
  user's `ssh`, agent, `~/.ssh/config` and `known_hosts` with `BatchMode=yes` and
  `StrictHostKeyChecking=yes`, plus the same RemoteCommand/SessionType/StdinNull/
  ForkAfterAuthentication resets as macOS.
- Keys live in Secret Service slot `git-library-keys-v1` (keyed by the Apple
  key-store account); tokens live in `git-credential-v1`, bound to the exact
  normalized address and user name.
- A device whose journal belongs to another library switches only through the
  journal-first account review, after confirmation.
- Interop has been verified both ways. A Swift-created library (CorePackage
  `GitSyncTransport`/`GitSyncRecovery`/`WireCodec`) was opened on Linux with its
  recovery code, and a Linux-created library was opened by Swift with its code.
  Edits, additions and tombstones flowed in both directions using each other's
  blob versions as CAS tokens.

## Next phases

1. **Android** transport implementing the same layout, CAS rules and
   `keys/recovery.json` envelope (Linux: see `docs/linux/GIT_SYNC.md`).
2. Optional device pairing through short-lived files on the branch, as an alternative
   to typing the recovery code.
3. History compaction, which other devices would treat as a reviewed reset.
