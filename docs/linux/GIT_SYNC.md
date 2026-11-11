# Git sync on Linux

Serverless sync through an ordinary git repository on GitHub, GitLab, Gitea/Forgejo,
GitVerse or any git host, compatible with the Mac and iPhone/iPad apps. The
user runs only client apps. In an encrypted library the host stores only unreadable
encrypted files; in a plain-text library ordinary snippets are readable
Markdown files (see [Plain-text libraries](#plain-text-libraries)).
The protocol and safety design are shared with Apple and described in
[docs/git-sync.md](../git-sync.md). This page covers the Linux implementation.

## What a Linux user can do

From the main menu, choose **Git Repository…** (window title **Git Repository**). The
CLI equivalent is `snippets-cli git …`. The wording below is shared with Apple.

- **Connect a repository**: "Create a new private repository without a README, then
  paste its address." Over HTTPS with an access token, or over SSH
  (`git@host:owner/repo.git`, `ssh://[user@]host[:port]/path`). SSH uses
  the user's own `ssh`, `ssh-agent`, `~/.ssh/config` and `~/.ssh/known_hosts`.
  No token is stored for SSH. The SSH hint names the exact check command for the
  address, `ssh -T [-p port] [user@]host`, as on macOS.
- **Token help by host.** github.com: a fine-grained token limited to this repository
  with "Contents: Read and write", with a link to
  `https://github.com/settings/personal-access-tokens/new`; gitlab.com: a project access
  token with `read_repository` and `write_repository`, with a link to
  `https://gitlab.com/<path>/-/settings/access_tokens`; other hosts: a token that can read
  and write the repository (`write:repository` on Gitea and Forgejo, with the account
  name as user name). The user name is optional on github.com (`x-access-token`) and
  gitlab.com (`oauth2`) and required elsewhere. The window shows the text under the
  token field; the CLI prints it as a `hint:` line after an authentication, not-found,
  missing-token or user-name failure.
- **A branch that already has files** ("This branch already has files, such as a README.
  Snippets can use its own branch in this repository instead."): the window offers
  **Use Branch “snippets”**, which fills in `snippets` and checks again; the CLI prints
  `hint: Try again with --branch snippets.` (and `inspect` returns the same hint).
- **Create a library** on an empty branch, choosing **Create Encrypted Library** (the
  default: "Encrypted (recommended): the host and anyone with access to the repository
  see only unreadable files.") or **Create Plain-Text Library** ("Plain text: ordinary
  snippets become Markdown files that the host and anyone with access can read, and they
  stay in the repository’s history even after you delete them. Secure snippets are
  always encrypted."), then "You can’t change this later." Plain text is refused
  (`public_repository`, "This repository is public. Anyone on the internet could read
  plain-text snippets. Make it private, or create an encrypted library.") when an
  anonymous HTTPS request can clone the repository (below). When Snippets cannot tell
  (`visibility_unknown`), the window asks **Couldn’t Check the Repository** ("Snippets
  couldn’t check whether this repository is private. Create a plain-text library only if
  it is private: anyone who can read the repository can read your ordinary snippets.")
  with Cancel and **It’s Private**; the CLI needs `--confirm-private`. The one-time recovery code
  appears in a dialog with **Copy**. Copying uses the same password-manager hint and
  two-minute clipboard clearing as the account key.
- **Join an existing library** (made by Mac, iOS or Linux) with its recovery code.
  A device that already holds the key (for example after **Remove from This
  Computer**) needs no code. The mode comes from the library's manifest, and the device
  agrees to that mode: joining a plain-text library first asks **Join a Plain-Text
  Library?** (CLI: `--accept-plain-text`) unless this device already agreed to exactly
  that library: the same dataset, plain-text mode, the same endpoint (Apple
  `sameEndpoint`: canonical identity, plus account and port between two SSH addresses
  or port between two HTTPS ones) and the same branch. Connecting to another library
  while one is active uses the same endpoint rule.
- A connected plain-text library shows "Ordinary snippets are saved as readable
  Markdown files in your Git repository. Secure snippets stay encrypted." (`git status`
  as `modeDescription`); `git status` and `git inspect` report `"mode": "encrypted"` or
  `"plain_text"`.
- **Sync Now** or **Automatic Sync**. Automatic sync is the shared `auto_sync::Schedule`:
  30 s when current, 2 s while more work remains, backoff after transient
  failures, and a halt when review is needed. Local edits and foregrounding wake it.
  As in the Cloud worker, these retry instead of halting: the network, rate limits and
  races, a locked, unavailable or timed-out keyring, the library being recovered or
  changed by another part of Snippets (`library_busy`), and an unusable cache (deleted
  and rebuilt once in the same cycle first). A halted schedule ignores wakes until an
  explicit action.
- **Review…** remote or local deletions, and the missing-records snapshot review.
- **New Recovery Code…** ("Your old code stops working in Snippets. Someone who already
  has it and can read the repository’s history could still decrypt the library. To
  fully revoke a code, create a new library.") and **Remove from This Computer…**
  (CLI: `replace-recovery-code`, `disconnect`).

```sh
printf '%s\n' "$TOKEN" | snippets-cli git inspect --repository https://github.com/me/lib --username me --token-stdin
printf '%s\n' "$TOKEN" | snippets-cli git create --repository https://github.com/me/lib --username me --token-stdin
printf '%s\n' "$TOKEN" | snippets-cli git create --repository https://github.com/me/notes --username me --token-stdin --plain-text
printf '%s\n%s\n' "$TOKEN" "$CODE" | snippets-cli git join --repository https://github.com/me/lib --username me --token-stdin --recovery-code-stdin
printf '%s\n%s\n' "$TOKEN" "$CODE" | snippets-cli git join --repository https://github.com/me/notes --username me --token-stdin --recovery-code-stdin --accept-plain-text
snippets-cli git join --repository git@github.com:me/lib.git --recovery-code-stdin <<<"$CODE"
snippets-cli git sync
snippets-cli git deletion-review            # show; then --delete or --keep
snippets-cli git snapshot-review            # show; then --confirm
snippets-cli git replace-recovery-code
snippets-cli git automatic on|off
snippets-cli git status
snippets-cli git disconnect
```

Tokens and recovery codes are read only from stdin, never from argv or the
environment. A new recovery code is printed once, as JSON on stdout. If a
creation step cannot be confirmed, the CLI and window still show the code,
because the library may exist and the code opens it.
`--confirm-switch` is required when connecting would replace this device's sync
state for another library (see below).

## Files and how they map to the contract

| File | Role |
| --- | --- |
| `src/git_location.rs` | HTTPS/SSH/scp location parsing, `canonical_identity` (byte-identical to Apple: lowercase host + percent-decoded path; strip leading `/`, then one `.git`, then trailing `/`; user/port ignored), SSH value rules (including `%` refused after one decoding pass), branch/user/token rules, `HttpCredential` (no Debug/Clone) |
| `src/git_layout.rs` | Manifest (with `recordProfile` → `Mode`), both READMEs, record file and commit message bytes; strict decoders; fanout/record paths; `git-blob-sha1:<hex>` record and `git-md-blob-sha1:<hex>` Markdown versions; cursors; account/dataset/key-scope digests |
| `src/git_plain.rs` | Plain-text Markdown files, byte for byte `GitPlainSnippetFile`: render (verified read-back), front-matter parser, edit detection and derived revisions, hand-deletion tombstones, path-derived ids, slugs, Foundation-compatible tag normalization |
| `src/git_recovery.rs` | `keys/recovery.json`: HKDF-SHA256 (salt `snippets-git-recovery-salt-v1`, info = AAD) + AES-256-GCM (combined nonce‖ct‖tag) over the sync-v1 portable bundle; AAD `snippets-git-recovery-v1\0<dataset>`; Apple `RecoveryKey` code format |
| `src/git_vault.rs` | `keys/vault.json`, byte for byte `GitSyncVault`: the secure-snippet vault's identity and its key under the recovery code, sealed with HKDF-SHA256 (IKM = library key, salt = library salt, info = AAD) + AES-256-GCM; AAD `snippets-git-vault-v1\0<dataset>`. Format only: Linux does not read or write the file during sync yet |
| `src/git_repo.rs` | The system `git` in a hardened environment over a private bare cache; one-time git/ssh version checks; ls-remote, depth-1 fetch, `--force-with-lease` push, receive-pack dry-run write check, `ls-tree`/`cat-file`/`hash-object`/`mktree`/`commit-tree`; closed stderr classification |
| `src/git_transport.rs` | `receiver::Remote` + `sender::Remote` for the existing bounded sync owner; setup operations (inspect, initialize, read/write `keys/`, verify write); the plain-text record locations, fetch, normalize commit and commit planning |
| `src/git_setup.rs` | Configuration file, Secret Service slots, create/join/replace/disconnect, the agreed mode, token help by host, the public-repository probe, reviewed journal switch, sync cycles, deletion/snapshot reviews |
| `src/git_ui.rs` | GTK window and the background owner thread (primary process only) |
| `src/bin/cli_git/mod.rs` | `snippets-cli git …` |

### Engine mapping

- **Scope.** The journal `Scope` is `{membership: SHA256("snippets-git-account-v1\n<location>\n<ref>"),
  dataset: SHA256("snippets-git-dataset-v1\n<location>\n<ref>\n<dataset>")}`, the
  same digests the Apple transport uses. The feed is `{epoch: dataset id, key_epoch: 1}`.
- **Cursor.** `git1.<dataset>.<commit>` is the Apple cursor. Because the Linux inbox
  accepts at most 10 records per page, a delta or full snapshot larger than that
  continues with a Linux-only `git1p.<dataset>.<target>.<base|full>.<offset>` toward
  one fixed target commit. Full snapshots never infer deletions.
  A cursor whose base this device no longer holds returns `CursorInvalid`;
  the owner then restarts with a reviewed snapshot.
- **CAS.** Each offer is checked against the head plus earlier offers in the same
  batch. A blind create of an existing id, or a version mismatch, returns the
  authoritative record as a conflict. An expected ciphertext version whose file
  vanished is `git_record_removed`, which means a reviewed reset (a Markdown version
  is a conflict instead; see below). Identical bytes are accepted without a commit.
- **Commits.** One commit per engine batch (at most 10 offers), on the head it was
  built on. The push uses `--force-with-lease=refs/heads/<b>:<old>`, and the
  server moves the ref only if it still points there. A lost race re-reads the
  head and replans. A rejection that leaves the head unchanged is
  `git_push_rejected`: a protected branch, a hook or missing permission. GitLab's
  "not allowed to push code to protected branches" is `git_push_rejected` at once. Five
  races in a row produce a 5 s retry.
- **Size.** HTTP 413 halves the commit. A single record that still does not fit is
  rejected alone as `PayloadTooLarge`, and so is a blob over 900,000 bytes or a
  revision over 256 bytes. Unrelated tree entries survive every commit.
- **Datasets.** A branch whose manifest names another dataset than the connected
  one is `git_library_replaced`. A change of the pinned dataset within a session
  is `dataset_reset`. Both halt the transport. A manifest (or a cursor's target or
  base commit) naming another storage mode than the one this device agreed to is
  `git_library_mode_changed`, also a halt: someone with push access cannot turn an
  encrypted library into plain text. Reconnecting shows the mode and asks for consent
  again. The head's mode is the one checked; a cursor whose commit was written in the
  old mode is `CursorInvalid`, so after consent the next fetch starts over in full
  instead of halting again. A branch with no Snippets format marker is foreign and never overwritten.
- **Failures.** Git failures reach the engine as the existing closed
  `cloud::Failure` vocabulary. The precise Git code stays on the transport (for
  example `git_authentication`, `git_ssh_host_key_unverified`, `git_push_too_large`)
  and is shown through `git_setup::Failure::message`.

### Plain-text libraries

The format and rules are the Apple ones in
[docs/git-sync.md](../git-sync.md#plain-text-libraries); `snippets/Core/Git/GitPlainText.swift`
and the plain paths of `GitSyncTransport.swift` are the reference. On Linux:

- **Mode.** `git_layout::Mode` is the manifest's `recordProfile`: `snippets-wire-v1`
  (encrypted) or `snippets-plain-v1` (plain text); any other profile is
  `git_sync_schema_unsupported`. Creation takes the mode; joining reads it, and the
  user agrees to it. `git-sync.json` stores the agreed mode as `recordProfile` only for
  plain-text libraries, so encrypted configurations stay readable by earlier builds.
  The data-plane `Configuration` carries it as `expected_mode` (Apple
  `expectedMode`); the library key reaches the transport, and the plain codec is used,
  only when the agreed mode is plain text. Connecting or joining fails with
  `git_library_mode_changed` when the repository's mode differs from the agreed one,
  and so does a creation whose lost response is recovered by re-inspection and finds
  the new library in another mode than chosen (the recovery code is still shown).
- **Files.** An ordinary live snippet without `x` extensions is
  `snippets/<slug>-<id8>.md`: `name`, `keyword` and `tags` as canonical JSON
  (`canonical.rs`), `enabled`/`pinned`, the lowercase id, then `sync`, unpadded
  base64url of canonical `{createdAt, hash, hlc, id, origin, schemaVersion, updatedAt,
  x}` (`id` lowercase; exactly these eight keys, and an id that does not round-trip
  lowercase makes the metadata unusable), `---`, the body and one `\n`. `render` verifies the file reads back as exactly that
  envelope, as Swift does; anything else (secure, tombstones, `x` present) is a
  ciphertext record under `records/`.
- **Reading.** `git_plain::parse` follows Swift's `String` semantics where people type
  freely: grapheme comparisons for `#`, `:`, quotes, brackets and `- item`;
  Foundation's `.whitespaces` set (which includes U+200B) for trimming; lossy UTF-8
  lines; BOM, CRLF (the final `\r\n` is dropped only when the closing `---` line is
  CRLF), comments, lines without a key, JSON/bare/bracketed/YAML-block tags,
  `true/yes/on/1`, an invalid `id` ignored, Foundation's lenient base64 (unused trailing
  bits and extra `=` accepted), and Apple number semantics in `sync` (an integer beyond
  Int64 becomes a double; a non-finite double makes the file unreadable, not new).
  Identity comes from the file alone: the `sync` id (covered by its hash), else the
  first valid `id` line (later or invalid ones never replace it), else
  `SHA256("snippets-git-plain-file-v1\n<path>")` with version 8 and RFC 4122 bits. Front
  matter that does not parse is scanned by splitting on the byte `\n` and trimming
  whitespace and newlines (so `\r` too), preferring a parseable `sync:` line, else the
  first valid `id:` line. There is no history rule: devices with and without a cache
  read the same id from the same file. A file is exact only when its `sync` names
  schema 1, its id equals the id the file is read under (assigned or not), the `id`
  line says the same, and the rebuilt ten-key envelope has the same hash. Anything else
  is an edit, so normalizing rewrites the `id` line (a copy, a changed or removed `id`
  line). An edited file gets the `sync` clock plus one tick on device `00000000`,
  origin `00000000`, normalized tags; a new one HLC 0 and timestamps 0. A file from a
  newer Snippets (Apple `Failure.tooNew`: the last `sync` line decodes to an object
  with an integer `schemaVersion` above 1, or with a strict superset of the eight keys)
  is unreadable, never a hand edit, so it is skipped and never rewritten; a malformed or
  partial `sync` is still a hand edit.
- **Tags.** `SnippetTagging.normalizedTags` dedupes with Foundation's
  `folding([.caseInsensitive, .diacriticInsensitive], en_US_POSIX)`. `git_plain::tag_key`
  reproduces it from measurements, not from documentation: a base that decomposes to
  and folds below U+0510 drops every following removable mark; another case-changing
  base keeps them; any other base drops only U+0300–036F and U+0483–0489; spacing marks
  (Mc without Grapheme_Extend, exported from Foundation) are never dropped; folding is
  full case folding then lowercasing, leaving U+1C80–1C88 alone. Compared with
  Foundation on macOS 27 for all 1,112,038 scalars and 1,067,677 base+mark pairs (13
  kinds of mark): no difference in which strings are equal.
- **Records.** A ciphertext record wins over a Markdown file with the same id. Several
  files claiming one id are copies: the one named `…-<id8>.md` keeps it (else the first
  by Swift string order), each other copy gets its path-derived id and is read under it
  (an edit). A record's version names its current file's blob and its kind:
  `git-md-blob-sha1:<hex>` for a Markdown file (also for an unreadable one, a normalize
  rewrite and an accepted plain submission), `git-blob-sha1:<hex>` for a record under
  `records/`. When a record under `records/` becomes Markdown again and a file restored
  by hand (which that record shadowed) still claims its id, that file is overwritten
  instead of writing a `-2` copy that would keep the id. A record that changes kind
  moves between `snippets/` and `records/`
  in one commit, and a file is renamed only when the snippet's name changed
  (canonically equivalent names are the same name, as in Swift). New names get
  `-2`, `-3`… suffixes exactly like Swift.
- **Normalize.** A fetch that starts a new page sequence first rewrites hand-edited
  files with fresh `sync` metadata and records hand deletions as tombstones in one
  best-effort `Normalize N file(s) edited outside Snippets` commit (pushed with a
  lease; a lost race or a refusal skips it), then pages toward that commit so its
  records, including deletions recorded only now, carry the rewritten files' and new
  tombstones' versions. After an authentication failure (probably read-only access)
  normalize and pending-deletion pushes pause for one hour for that library, process-wide
  because a Linux transport lasts one cycle. Racing devices write identical Markdown, so
  only one normalize commit lands.
- **Hand deletions.** A Markdown file deleted by hand is delivered as a tombstone one
  tick after the file's clock, without the in-app deletion marker (so deletion review
  applies). Until a tombstone file exists, the record's version is a Linux-only local
  token `git-absent-sha1:<deleted blob>` (it never leaves the device; an offer naming
  it with no file present is a creation). Unrecorded deletions are retried on later
  fetches in this process, including an otherwise unchanged head, until a tombstone
  exists or the id is back (Apple keeps the same list in memory; a Linux transport lasts
  one cycle, so the list is process-wide per library). An offer whose expected version
  is a Markdown version with no file present gets a deletion as a conflict and adds it
  to that list: one tick after the deleted file's clock when the cache holds the blob,
  else (a lost cache) the lowest clock (`000000000000-0000-00000000`, origin
  `00000000`, not secure), so an edit made since outranks it. This is decided by the
  version's prefix, never by the cache; a vanished ciphertext version is still
  `git_record_removed`.
- **History.** Apple retries a fetch that exceeds the size limit while catching up
  through history once from the tip alone. Linux always fetches the tip with depth 1,
  so there is no catch-up fetch to retry.
- **Unreadable files.** A file that starts with `---` but does not parse, is not
  UTF-8, or is over 1.1 MB does not stop sync. That one file is skipped: it is not
  delivered, not treated as a deletion (its id is still present), and not normalized;
  everything else syncs. The cycle reports a non-fatal warning with counts only
  (`unreadableFiles` and `refusedEdits` from `snippets-cli git sync`, a sentence in the
  window's status; no paths or names, and nothing is logged). An in-app edit or
  deletion of that snippet is refused for that record (`git_plain_file_unreadable`,
  reaching the engine as a `Rejected` outcome without a retry delay), so it stays
  pending and the person's file is never overwritten; once the file is fixed in the
  repository, the next fetch delivers it and the waiting edit goes through. This uses
  the engine's existing per-record rejection; Apple instead delivers an unopenable
  record that its engine quarantines. One limit remains without engine changes: a
  full snapshot (a fresh join or a lost cache) that omits a known snippet because its
  file is unreadable leads to the existing missing-records review, because the
  transport cannot hand the engine a record it cannot read.

### Transport safety

- The inherited environment is cleared to an allow-list: PATH, HOME, USER,
  `SSH_AUTH_SOCK`, proxies and CA overrides. `GIT_CONFIG_NOSYSTEM=1` and
  `GIT_CONFIG_GLOBAL=/dev/null` apply. Hooks (`core.hooksPath=/dev/null`),
  templates, credential helpers, askpass, terminal prompts, replace objects and
  every `GIT_TRACE*` variable are off.
- Only `https` and `ssh` transports are allowed. Plain `http` is accepted only for
  literal loopback addresses (`127.0.0.0/8`, `::1`; never a name such as `localhost`)
  when `SNIPPETS_GIT_ALLOW_INSECURE_LOOPBACK=1` in a debug build (test harnesses);
  release builds ignore the variable.
  Redirects are not followed. `http.postBuffer` is 32 MiB, so pushes carry a
  Content-Length instead of a chunked body.
- An HTTPS token travels only in an environment-only `http.extraHeader`
  (`GIT_CONFIG_KEY_n`). It never goes into argv, a URL, a file or a credential helper.
- git 2.32 or later and, for SSH, OpenSSH 8.7 or later are required: `git --version`
  is checked once per process before the cache is created (an older git may not know
  `--object-format`) and `ssh -V` once per ssh program before the first SSH command,
  failing closed with `git_unsupported_git_version` or `git_unsupported_ssh_version`.
- SSH runs `ssh -T -o RequestTTY=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no …`
  with forwarding disabled, and resets `RemoteCommand=none`, `SessionType=default`,
  `StdinNull=no` and `ForkAfterAuthentication=no`, which a user config could set. An unknown or changed host key fails with
  `git_ssh_host_key_unverified` and is never accepted. The user verifies it once
  with `ssh` in a terminal.
- Timeouts are idle limits, not whole-exchange limits. For HTTPS, curl's
  `http.lowSpeedLimit=1`/`http.lowSpeedTime=120` aborts after 120 s without
  progress. For SSH, `ServerAliveInterval=15`/`ServerAliveCountMax=8` and
  `ConnectTimeout=20` apply. A 30-minute per-process ceiling is only a backstop.
- Every git command runs in its own process group. Quitting the app, or
  cancelling, kills the group. stderr is bounded, classified into a closed code
  and discarded, because it can echo URLs. Classification matches only ssh's own
  messages (`Permission denied (`, host key, algorithm negotiation), git's
  messages and host replies. Read-only keys and tokens ("marked as read only", "write
  access", "denied to deploy key", as in Apple's `GitSSHClient`) are
  `git_authentication`. Login-script noise from the remote account never becomes an
  authentication or not-found failure.
- The visibility check for a new plain-text library is Apple's `visibility(of:)`: an
  anonymous `GET <address>/info/refs?service=git-upload-pack` without credentials or
  cookies, with a 10 s timeout, following at most three redirects that keep the scheme,
  host and port. A 200 with `application/x-git-upload-pack-advertisement` is public;
  401, 403 or 404 private; anything else (an error, a timeout, another status, a
  redirect elsewhere) unknown. An SSH address is checked only at well-known forges
  (`publicForgeHost`: github.com and ssh.github.com on 22, ssh.github.com on 443,
  gitlab.com on 22, altssh.gitlab.com on 443, codeberg.org and bitbucket.org on 22) at
  the forge's HTTPS address; any other SSH host is unknown with no request.
- The cache is `<data>/snippets/GitSync/<16-byte account digest hex>.git`. It is a
  private bare repository holding only what the host holds. It is never garbage
  collected and is safe to delete.

### Secrets and configuration

- `<data>/snippets/git-sync.json` (mode 0600, strict schema) holds the repository
  spec, branch, HTTPS user name, dataset id and the automatic flag. It holds no
  token or key.
- Secret Service slot `git-library-keys-v1` holds a bounded map of up to 32
  library keys. Each 64-byte sync-v1 material is keyed by the Apple key-store
  account `git-library-v1-<16-byte hex>`. A key is installed before a new library
  is pushed, kept on Remove from This Computer, and never silently replaced.
- Secret Service slot `git-credential-v1` holds the token. It is bound to the
  exact normalized HTTPS address (scheme, host, port, path) and user name, as on
  Apple. It is reused only for that pair and removed on Remove from This Computer.
- The per-install checkpoint key (`checkpoint-key-v1`) is shared with the rest of
  the app.

### Switching from another library

The journal belongs to exactly one library. If this device already syncs another
one (Snippets Cloud, or another Git repository or library), connecting asks for
confirmation (`--confirm-switch` in the CLI). It then runs the existing
journal-first account review:
`prepare_account_review` → `stage_account_review` → `continue_account_review`.
That keeps every local snippet and local intent, discards the old library's
cursors, offers and CAS generations, and retains both encrypted journal images.
Unsynced local deletions block the switch (`local_absence`). Activating Git
turns Snippets Cloud automatic sync off.

## Verification (Omarchy, 2026-11-09)

All commands run from `snippets-linux/` with `CARGO_TARGET_DIR` outside the
user's checkout:

```sh
cargo fmt --check && cargo clippy --all-targets
cargo test --lib git_tests                       # 33 pass, 2 live tests ignored
cargo test --lib --no-run                        # then, with that test binary:
tests/git-sync-live.sh "$BIN"                    # HTTP token + system ssh/sshd/agent
tests/git-sync-desktop-live.sh "$BIN"            # GTK window, private keyring
cargo build --bin snippets-cli && tests/git-sync-cli-live.sh target/debug/snippets-cli
```

- `git_tests` (33): the 16 below; eight vector tests in `git_tests::plain`
  (`src/git_plain_tests.rs`, `tests/fixtures/git-plain-v1.json` regenerated from the
  current Swift by `tests/reference/git-plain-vectors.swift`: 15 rendered files, 122
  reads with envelopes, edit flags, normalized rewrites, tombstones and declared ids,
  13 reads under an assigned id, file names, tags, README and manifest; the reads cover
  the `sync` id winning over the `id` line, uppercase, invalid or missing meta ids,
  byte-split scans of unclosed front matter, CRLF included, and newer-format files: a
  later schema, a superset of keys, the last `sync` line deciding, and near misses that
  stay hand edits); a returning snippet overwriting the file its tombstone shadowed and
  a newer-format file never rewritten; three-way visibility (statuses, same-origin
  redirects up to three, a cross-origin redirect not followed, forge mapping,
  `sameEndpoint`) and plain-text creation refused when public, needing confirmation
  when unknown; five more
  (file-only identity over real git: a removed `id` line read the same from history and
  from nothing and rewritten once, a foreign `id` line ignored, an edit of a hand-deleted
  file from a device without the file answered with the lowest-clock deletion that is
  then recorded and delivered with its record version, a mode other than agreed
  refused on fetch and submit; an encrypted library flipped to plain text by hand
  stopping sync with nothing published, asking for consent again, and resuming after
  consent with the waiting edit published as Markdown; an OpenSSH 8.6
  refused; tool version parsing and token help by host); join consent bound to the
  branch and endpoint; and two plain-text libraries
  over real git: an engine-level one (layout, consent,
  edit and rename, a hand edit adopted by both devices with one normalize commit and
  the same revision, a hand-added file with a YAML tag list, a hand deletion reviewed on
  both and recorded under `records/`) and a transport-level one (secure and
  extension-carrying records stay ciphertext and nothing secret is in any object,
  Markdown and record versions tagged by kind, a
  copied file, a replaced id line restored, a mistyped id line, broken front matter
  skipped with a warning and an edit of it refused until the file is fixed, a deletion
  retried after a refused normalize push, an edit of a hand-deleted file answered with a
  conflict). The engine-level test also breaks a file by hand: the cycle stays
  `current` with the warning, other changes still arrive, an edit of that snippet is
  deferred without touching the file, and goes through once the file is restored.
- The original 16: identity vectors from the coordinator's rule, unsafe location
  refusal, layout bytes, strict decoders, cursors, recovery envelopes, stderr
  classification (including read-only deploy keys and GitLab protected branches).
  Over real git with a stand-in ssh program: shared layout and
  authorship, no plaintext in any object; join with wrong, invalid and right
  codes; edits both ways; concurrent edits converging; deletion review on both
  devices; tombstones kept as records; disconnect and reconnect without a code;
  replaced recovery code; 23-record snapshot and 14-record delta paging; foreign
  branches; a replaced library; a hand-removed record; unrelated files
  preserved; a reviewed switch from another library that keeps local snippets;
  shell-metacharacter locations refused.
- `git-sync-live.sh`: HTTP Basic token through the real `git http-backend`
  (missing token, wrong token, saved-token reuse). The system `ssh` against a
  private unprivileged sshd, with a throwaway key held only by a private
  `ssh-agent` on a short `/tmp` socket. The harness aborts unless that agent
  started, and passes `-F` with a private known_hosts. An unknown host key is
  refused. A plain-text library over the same sshd (consent, Markdown, edits both
  ways). Checks that the token is in no repository.
- `git-sync-desktop-live.sh`: the actual window. It covers the "Git Repository" title,
  token help and optional user names by host, a branch with a README offering **Use
  Branch “snippets”** that switches and finds that branch empty, the creation mode
  dialog with the shared wording and Encrypted as default,
  a plain-text library created from it (mode shown, Markdown in the repository), the
  plain-text join consent dialog (Cancel connects nothing, Join connects), the SSH form toggling,
  the wrong-token message, create, the recovery-code dialog, token entry
  clearing, the keyring holding the token and key but no file holding the token
  or code, a wrong code refused, a lowercase/spaced code accepted, deletion
  review on both devices, and **Remove from This Computer** forgetting the token but
  keeping the key.
- `git-sync-cli-live.sh`: two isolated installations through `snippets-cli git`, then
  two more on a plain-text library: `--plain-text` creation, the Markdown file in the
  bare repository, `inspect`/`status` reporting `plain_text` and the shared status
  line, a join refused without
  `--accept-plain-text`, an edit committed with plain `git` adopted by both with
  exactly one normalize commit and no further commits, and a Linux edit written back as
  Markdown at the same path. A fifth installation meets a branch with a README:
  `inspect` reports it with the `--branch snippets` hint, `create` fails with
  `hint: Try again with --branch snippets.`, and that branch is empty.
- Harness safety: each keyring daemon starts only when `XDG_DATA_HOME` is inside
  the fixture. Each harness resolves the real `${XDG_DATA_HOME:-$HOME/.local/share}/keyrings`
  before overriding `XDG_DATA_HOME`, captures the test's exit status, and always
  compares that directory afterwards, failing if it changed (`git-sync-live.sh`, which
  starts no keyring, checks it too). The private sshd sets `HOME` to a fixture
  directory, `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` for the remote
  git (`SetEnv`). Fixture repositories are made with `GIT_CONFIG_GLOBAL=/dev/null`.
  An independent before/after comparison of the real keyring directory around all three
  harnesses also matched. (On
  2026-11-09 an earlier draft of the CLI harness lacked the first guard, and its
  fixture daemon created an empty `login.keyring`/`user.keystore` with the public
  fixture password in the real keyring directory. Both were moved to
  `~/Work/snippets-git-sync-linux/quarantine-keyring-artifacts-20261109/`. The
  default `Default_keyring` was never touched.)

### Interop with the Apple implementation

A scratch SwiftPM driver used `@testable import SnippetsCore` from the unmodified
`CorePackage`: `GitSyncTransport`, `GitSyncRecovery`, `WireCodec` and
`SnippetCryptoSealer`. Linux ran the full Linux engine through `snippets-cli`.
Each side served the same bare repository from its own loopback
`git http-backend`, and the repository moved between machines as a tarball.

- **Apple creates, Linux joins.** The Swift-written README and manifest are
  byte-identical to the Linux constants, and the envelope and record shapes match.
  Linux joined with the Apple code and decrypted the Apple record. It edited that
  record and added one ("Sync 2 records"). Swift decrypted both, then edited the
  Linux record and tombstoned the Apple record using Linux blob versions as CAS,
  and added a third. Linux received the edit, the addition and the deletion
  (reviewed as `remote_deletion`). A fresh Linux installation joined with the
  Apple-issued code and matched.
- **Linux creates, Apple joins.** The README blob is identical to the
  Apple-created repository's. Swift opened the Linux recovery envelope with the
  Linux-issued code, so Swift's strict bundle decoding accepts Linux output. It
  decrypted Unicode content, then edited, added and deleted. Linux received all
  three.

### Plain-text interop (2026-11-10, current format)

The same approach, with a second scratch driver over `GitSyncTransport` in plain-text
mode (`GitPlainCodec`, `expectedMode: .plainText`) and `GitPlainSnippetFile`, and
Linux through `snippets-cli` in private bus/keyring fixtures. Both sides ran the
code at `5877578`, with the `id` key in `sync` and the file-only identity rules. An
earlier run on 2026-11-09 predated those rules; this one replaces it.

- **Apple creates, Linux joins.** Linux refused to join without
  `--accept-plain-text` (`plain_text_consent_required`), joined with it
  (`"mode": "plain_text"`), received the Swift snippet, merged a local one, and edited
  the Swift snippet: Markdown at the Swift path. Swift read both Linux-written files as
  exact (not edited) with the same ids, re-rendering them gave byte-identical files,
  and a full fetch added no commit.
- **Hand edit, Linux first.** A body and tag edit committed with plain `git` (tags
  `[integration, Plain, plain, hand]`). Swift derived revision `ee5cca2b…`, clock
  `…-0001-00000000` and the file's own id, without fetching. Linux synced: one
  `Normalize 1 file(s) edited outside Snippets` commit, tags normalized to
  `["integration","Plain","hand"]`, and no commit from a second cycle. Swift read
  Linux's rewrite as exact with revision `ee5cca2b…`, and its full fetch added no
  commit.
- **Hand edit, Apple first.** A CRLF rewrite of the Linux snippet: Swift fetched and
  normalized (revision `46f70f82…`); Linux then took the body with its inner `\r\n`
  and wrote nothing.
- **Renamed by hand.** `git mv` of a Linux-written file to `renamed-by-hand.md`: Swift
  read it as exact with the same id, and Linux kept the snippet with no deletion
  review and no commit.
- **Copied by hand, Linux first.** A copy of the Swift file (`…-617a0011.md`) with a
  new keyword and body, still carrying the original's `sync` id. Linux kept the id on
  the file whose name ends in that id and gave the copy its path-derived id
  (`db223717…`) in one normalize commit. Swift read the rewritten copy as exact with
  that id, and its ids for all snippets matched Linux's.
- **Copied by hand, Apple first.** A copy of `renamed-by-hand.md` (no id suffix in
  either name) as `zz-copy-two.md`. Swift kept the id on the first name and gave the
  copy `0949e1e9…` in one normalize commit. Linux reported the same ids for every
  snippet and wrote nothing.
- **Linux creates, Apple joins.** The plain README is byte-identical to the
  Swift-created library's, and the manifest matches apart from the dataset id. Swift
  read both Linux files (one with a Cyrillic name that Linux slugs `snippet-…`) as
  exact with byte-identical re-rendering, edited one (path kept) and added one; Linux
  received both. A Markdown file deleted with plain `git` was reviewed on Linux as
  `remote_deletion` and recorded under `records/` in a normalize commit; Swift read
  the tombstone one tick after the deleted file's clock, origin `00000000`, without
  the user-deletion marker, and added no commit.
- **Secure snippets.** A Swift secure snippet in a plain-text library is a
  `records/` file; neither its secret nor its name occurs in any repository object.
  Linux reports `vault_locked` for it (below).

Every phase checked that `~/.local/share/keyrings` was unchanged. CAS versions never
leave a device, so the `git-md-blob-sha1:` version has no cross-device bytes.

## Not done yet

- Plain-text libraries: an unreadable Markdown file omitted from a full snapshot leads
  to the missing-records review (see above), and file names transliterate non-Latin
  names less than Apple (`Привет` becomes `snippet`, not `privet`; paths are cosmetic
  and kept once chosen).

- Secure snippets over Git sync are not done yet. A cycle that needs vault
  authentication reports `VaultLocked`. The authenticated one-cycle vault sync is
  wired only to the Cloud worker.
- The Apple apps publish the library's vault in `keys/vault.json` so that the recovery
  code also opens secure snippets. Linux mirrors the file format (`git_vault.rs`, with
  the Apple known-answer file in `git_tests`) but does not adopt or publish a vault,
  and a library created on Linux has none until an Apple device adds it. Because Linux
  cannot rewrap the vault key, `replace_recovery_code` refuses a library that has the
  file (`vault_recovery_code`): a code that opened the library without its secure
  snippets would be worse than none.
- Linux cannot replace a library's keys (`docs/git-sync.md`, "Replacing the keys").
  When an Apple device does, Linux stops with `git_library_replaced` like every other
  device and reconnects to the new library with the new recovery code through the
  usual journal-first review. Such a library's manifest has `schemaVersion` 2, which
  `decode_manifest` accepts (`ROTATED_SCHEMA_VERSION`); Linux itself only writes 1.
- A malformed record file halts Linux sync (`git_record_malformed`). The Apple
  transport instead quarantines that one record, and the Linux engine has no
  per-record quarantine.
- No Git diagnostics events have been added. The Git modules log nothing.
- Switching back from Git to Snippets Cloud is not a reviewed path yet. Remove from
  This Computer keeps the Git-scoped journal.
- The app-hosted Apple engine phases (`GitSyncAppIntegrationTests` with Linux in
  the iOS role) have not run yet. The prebuilt macOS test bundle did not contain
  them.
- SHA-256 object-format repositories are unsupported. For internationalized
  hostnames, identity may differ from Apple: Linux uses punycode.
