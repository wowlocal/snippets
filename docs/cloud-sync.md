# Cloud sync and secure snippets

How the snippet library survives being written by more than one thing at a time, how it will
travel between devices, and how a snippet can hold a secret without that secret ending up in a
clipboard manager, an export file, a log, or a backend operator's database.

Read `docs/frecency-ranking.md` first if you want the house style for this kind of document; the
merge here reuses its join-semilattice reasoning, and its privacy boundary is one this design is
required not to break.

---

## 1. What is built, and what is not

| Phase | State |
|---|---|
| 1. Cross-process locking + three-way merge | **Shipped.** No network, no crypto, no format change. |
| 2. Wire record model, transport protocol, fake transport | Done and exercised by the engine. |
| 3. Secure snippets | Implemented: create, reveal, edit, make ordinary, recovery-key setup/restore, Settings pane. The interactive release check is still open — see below. |
| 4. Sync engine driven by the fake | Done, including the bridge from the two stores to the wire format. `AppDelegate.startSync(with:sealer:)` builds an engine; nothing calls it, because no transport ships. |
| 5. First real backend | Deliberately deferred — see §9. |
| 6. Second backend, conflict UI | Not started. |
| 7. Hosted server tier | Optional; not started. |
| 8. iOS app | Deferred by decision. `snippets/Core/` is already platform-agnostic for it. |

Phases 1–4 are complete. Phase 5 is the next thing, and it is a decision rather than code: pick a
backend, write one `SyncTransport` conformance, and call `startSync`.

**Deliberately no placeholder transport.** An engine that exists but talks to nothing would still
run its loop, write a base file, and report states — all describing a synchronisation that is not
happening. `syncEngine == nil` is the honest representation of "sync is off".

### What has run against reality, and what has not

| | |
|---|---|
| Verified at runtime | The concurrency harness (`Tests/concurrency-harness.sh`), the entitlement-free Keychain store/load/replace/delete/item path including `addItemIfAbsent` (`Tests/Harnesses/KeychainSelfTest.swift`), the publish → adopt → open round trip that replaced the manual vault copy (`Tests/Harnesses/VaultIdentityTest.swift`), the CLI control socket including a refused unsigned peer, and a clean app launch. |
| Proven only against a fake | The whole sync loop. That is the point of Phase 4 — the wire format cannot change after a second device speaks it, so it had to be settled while it was still free to be wrong. |
| **Not automated** | The interactive LocalAuthentication prompt, the data-protection tier (which needs a provisioned entitlement), and an *approved* CLI reveal. All three need a human at a signed, stapled build. |

The old design attached biometric `SecAccessControl` directly to the item. That silently selected
the data-protection keychain and failed with `errSecMissingEntitlement` in today's build; the same
attribute is also invalid on a synchronizable item. The item now uses the selected tier's ordinary
accessibility and `VaultSession` runs `deviceOwnerAuthentication` explicitly before reading it.
The entitlement-free item operations have therefore run for real. Creating a vault, approving an
unlock and reveal, and surviving a Sparkle update are still manual release checks on the exact
signed, stapled artifact.

Phase 1 was worth shipping on its own and does not depend on anything after it.

---

## 2. The bug Phase 1 fixed

The app and `snippets-cli` each did an unlocked read-modify-write of the whole file: decode the
array, edit a private copy, rename a complete replacement into place. Concurrently, that loses
most of the writes — measured at a realistic read-to-write gap, 60 concurrent writers keep 10–18
of their edits. The CLI printed a success receipt for every one.

Every figure here comes from `Tests/concurrency-harness.sh`, which is committed and runnable.

Locking alone does not fix it. A second race survives correct locking entirely:

1. `t=0.00` the user types; the app schedules its debounced write for `t=0.30`.
2. `t=0.28` the CLI writes, correctly, under the lock.
3. `t=0.30` the app writes, correctly, under the lock, from an in-memory array that never saw
   step 2 — and records its own bytes as "what is on disk".
4. `t=0.33` the folder monitor fires, sees bytes matching what the app last wrote, and returns.

Everyone behaved correctly and the edit is gone. `reloadFromDiskIfNeeded` made it worse on
purpose: when a local write was pending it flushed *over* the external change, so any CLI write
landing within 300 ms of a keystroke was destroyed. That was a defensible call before a merge
existed. It is not one now.

**The fix**: one funnel (`LibraryWriter.update`) that takes an `flock`, re-reads *inside* the
lock, and three-way merges when the bytes moved.

The lock alone is still not sufficient, because it can be defeated from outside: `flock` binds to
an inode, so replacing the lock file — a folder restore, a file-syncing tool, a cleanup script —
leaves peers holding locks on different inodes, both believing they are serialized. So every write
also re-reads immediately before writing and confirms immediately after, retrying the whole
transform if the bytes moved either time.

Measured over 60 concurrent writers, three runs each:

| Configuration | Records kept |
|---|---|
| Unlocked read-modify-write (the old behaviour) | 9–18 / 60 |
| Lock file replaced **once** mid-run — the realistic vector | **61 / 61**, three for three |
| Lock file replaced every 5 ms — stress, not a real event | 53–60 / 61 |
| `flock` unavailable, compare-and-swap only | 42–44 / 61 |
| `flock` unavailable, `link(2)` sentinel | **60 / 60**, three for three |

**The compare-and-swap is not a substitute for a lock.** An earlier version of this design claimed
it converged even with no lock at all; the fourth row is what that actually costs. The reason is
structural and no amount of extra re-reading fixes it: A confirms its own bytes, then B — whose
recheck predates A's rename — writes and confirms its own. Both report success and A's record is
gone. More reads move that window; they do not remove it.

That matters because the no-`flock` population is supported on purpose — `LibraryLockPolicy.isFatal`
returns false so a network-mounted home directory does not brick the app — and unlike a contended
lock, the condition is not transient. It is every write, forever, for that user. Hence the `link(2)`
sentinel, which is atomic on exactly the filesystems where `flock` is not. `link` is chosen over
`O_CREAT|O_EXCL` because `O_EXCL` is historically unreliable over NFS.

`Tests/concurrency-harness.sh` reproduces every row. Its gate is a threshold rather than equality,
because the 5 ms churn case is inherently racy and a perfect-score gate fails intermittently on a
healthy tree.

The lock lives on its own zero-byte file rather than on `snippets.json`, because an atomic write
renames the data file's inode away and peers would end up locking different inodes — measurably
the same as no lock at all.

`flock` failing because the filesystem does not implement it falls back to the sentinel rather
than to writing unlocked. A *timeout* is different — it means a peer genuinely holds the lock — so
the caller backs off and retries rather than writing. Both degraded modes are now observable
(`SnippetStore.writeHealth`, and a stderr warning from the CLI) rather than only logged; a user
stuck in permanent no-lock mode previously got no signal whatsoever.

The sentinel owner is host + pid + process start generation, not pid alone. A live process that
has reused a crashed owner's pid therefore cannot hold the old lock forever. Two-line sentinels
from older builds cannot prove that identity; they are treated conservatively while fresh, then
become stealable after the same 30-second stale threshold used for foreign or unreadable owners.

---

## 3. The merge

`snippets/Core/SyncMerge.swift`. Pure, `nonisolated`, no clock, no I/O.

The ancestor is free: `SnippetStore` already tracked `lastKnownDiskData` for an unrelated reason,
and that is exactly the common ancestor a three-way merge needs.

Two invariants, both stated as tests:

1. **Absence is never a delete.** A record missing from one side is a deletion only if the
   ancestor proves it was there and left. Without that proof, absence means "this side has not
   seen it yet" — and treating that as a delete is how a fresh install wipes a library.
2. **An edit always beats a delete.** A deletion the user meant is trivially repeatable. An edit
   a delete swallowed is gone.

Per field: if only one side moved a field away from base, that side wins and **no clock is
consulted**, which is why clock skew between devices barely matters. A clock is needed only when
both sides moved the same field.

**Content is never discarded.** When both sides genuinely changed the body, the winner keeps it
and the loser is preserved as a separate snippet — disabled, keyword cleared, tagged `conflict`.
Its id is derived deterministically (UUIDv5 over the record id and the losing content), so both
devices mint the *same* copy and a third sync is a no-op. With a random id, conflict copies breed
without bound; that is the classic way this feature goes wrong.

**Tags** are merged as a three-way set. With an ancestor, the add-vs-remove conflict an OR-Set
exists to solve cannot arise — removing needs the tag in base, adding needs it absent from base.
The ancestor *is* the causal context an OR-Set carries per element, already paid for.

### Ties must be symmetric

The first implementation broke exact `updatedAt` ties by stamping the local record with this
device's id and the remote one with a reserved low-sorting id, then comparing. **That does not
converge.** It is asymmetric: run it on device A and A wins, run the mirrored inputs on B and B
wins. Both write their own version, each sees the other's, and they rewrite the file at each
other forever.

Ties are not exotic. `updatedAt` truncates to whole milliseconds, and the app-versus-CLI
collision this whole design exists for is by definition two writers in the same instant.

So the tiebreak is taken from the data: both sides hash the two payloads and pick the same
winner. This gives up "the in-app edit always wins a tie", which was never expressible
symmetrically — and matters little, because a tie is only reachable when both sides changed the
same field to different values in the same millisecond, and content specifically is preserved as
a conflict copy either way.

`Tests/Core/SyncMergeTests.swift` has a `Cross-device convergence` suite that asserts mirrored
inputs produce the same library **and** that the result is a fixed point. Reintroducing the
asymmetric tiebreak fails four of them, including a randomized property test.

### Undo

An undo entry is "the library as it was before my edit", stated relative to the pre-merge local
array. Left alone after a merge, `⌘Z` would persist an array that predates every record the other
writer just added — undo would delete someone else's snippets. So the stacks are rebased.

The rebase is **not** the three-way merge, and using the merge here was a real bug. An undo entry
is a stated *intent* — "put it back to exactly this" — not a competing edit by another device, and
the merge treats it as one. No concurrency is needed to break it: edit v1 → v2, let the CLI write
v3, and the rebase sees base v2, local v1, remote v3, all distinct. That is a content conflict by
definition, so `⌘Z` restored nothing and instead minted a disabled `(conflict …)` record into the
shared library, which then survived every later rebase. `SyncMerge.rebaseSnapshot` replays only
what the snapshot actually changes relative to its own baseline and takes the merged library for
everything else — no clock, no arbitration, no conflict copies.

Above a size threshold the rebase degrades to clearing the stacks, which loses undo history but
never data.

---

## 4. Why `snippets.json` never changes

It stays a bare JSON array of objects with exactly nine keys, pretty-printed with sorted keys. It
will not gain a tenth.

`Snippet.init(from:)` ignores unknown keys and `Snippet.encode(to:)` writes exactly nine, so **any
older binary that opens a newer file silently strips every field it does not understand and
writes the stripped version back.** Sparkle rolls out over days, `/usr/local/bin/snippets-cli` is
a symlink nobody refreshes, and debug and release share the support directory because the app
cannot be sandboxed. A format that cannot grow cannot be stripped.

This is what keeps an old build, a stale CLI, `jq`, `vim`, and a Time Machine restore all
first-class writers. The merge is what makes that safe rather than merely tolerated.

Everything new therefore lives in **subdirectories** — for the reason already documented above
`usageFolderURL`: the app watches the support folder with a `DispatchSource`, and `rename(2)`
mutates the destination directory's vnode, so a sidecar beside `snippets.json` would fire the
monitor on every sync tick and collapse the editor's write debounce.

```
~/Library/Application Support/SnippetsClone/
├── snippets.json          FROZEN. Nine keys. Plaintext snippets only.
├── Usage/usage.json       UNCHANGED. Never syncs. See §7.
├── Vault/vault.json       Secure snippets: metadata plaintext, content sealed.
├── Sync/                  state.json, base.json, library-metadata.json, tombstones.json,
│                          library.lock, Quarantine/
├── Backups/               pre-sync-<iso>.json and rolling pre-merge snapshots
└── Tmp/                   mkstemp staging, so an atomic write is ONE monitor event
```

---

## 5. Secure snippets

A secure snippet lives in `Vault/vault.json`, never in `snippets.json` — not even as an empty
`content`. That is a structural guarantee rather than a filter: an old build cannot see the record
at all, so it can never type ciphertext into a chat window, and `exportSnippets(to:)` and
`SnippetDeepLink` cannot leak one because they never encounter it.

### Keys

> **Superseded in part.** This block still describes `K_lib` correctly, but sync no longer uses it:
> the wire has its own key and the vault's identity travels on its own. See "The wire key is not the
> vault key" and "Getting a second Mac working" in §6.
>
> **Decided 2026-08-08:** the vault key lives in the **Keychain**, with no mandatory passphrase.
> `K_lib` is stored with `kSecAttrSynchronizable` when the entitlement is present so iCloud
> Keychain carries it between devices. The app separately requires Touch ID or the login password
> before reading it. Say the consequence plainly rather than burying it: the guarantee now
> rests on Apple's iCloud Keychain rather than on something only the user knows, so an attacker who
> compromises the iCloud account *and* passes its device-approval step reaches the secrets. The
> passphrase implementation below is retained for a future passphrase-protected export — it is
> not on the primary path. Vault creation instead makes a printable recovery key and stores an
> authenticated recovery wrap only after the user confirms that they saved it.
>
> Note also that `kSecAttrSynchronizable` requires the *data-protection* keychain, which requires
> `keychain-access-groups` + an embedded provisioning profile + Keychain Sharing on the App ID.
> Without that portal work the key can still live in the login keychain, and secure snippets work
> fully on one Mac — they just cannot sync.
>
> `KeychainSecretStore` picks between the two at runtime by reading the running binary's own
> entitlements (`SecCodeCopySelf`), not from a build flag — a flag would be wrong in both
> directions. The same binary therefore does the local tier today and the synchronizable tier the
> moment the entitlement appears. On first read after that upgrade it copies and verifies the old
> login-keychain item in the new tier before using it; the legacy copy remains as rollback safety.
> Verified: when `keychain-access-groups` and the application identifier are absent, detection selects the local tier.
>
> Biometry is deliberately **not** a Keychain item attribute. On macOS, adding
> `SecAccessControl` routes this generic-password item to the data-protection keychain even in the
> local tier, producing `-34018`, and synchronizable items reject it. `VaultSession` evaluates
> `deviceOwnerAuthentication` and only then reads the ordinary item. This keeps one compatible
> storage representation in both tiers while retaining an explicit human-presence gate in the app.

A random 256-bit library key `K_lib` is the root and is never used to encrypt anything directly.
Per-purpose subkeys come from HKDF-SHA256:

- `K_rec(id)` — per record, so a 96-bit GCM nonce cannot collide across the library.
- `K_hash` — for the keyed content hash.

`K_lib` is also wrapped under a printable 128-bit recovery key at vault creation. That wrap is the
way back when a migration or entitlement change loses the Keychain item: Settings accepts the
printed key, authenticates the wrap against this vault's `kid`, and restores the item. Older vaults
without a wrap are offered one whenever they are unlocked. The implemented passphrase format uses
PBKDF2-HMAC-SHA512 with 600 000 pinned iterations, but no current UI creates a passphrase wrap;
its `alg` field preserves the future upgrade path to Argon2id or passphrase-protected export.

Every AEAD operation binds an AAD covering version, scope, record id, and the deleted flag, so a
ciphertext cannot be replayed under another record's identity. There is deliberately no
"verifier" field: the AEAD tag already rejects a wrong passphrase, and a second oracle buys
nothing.

### The content hash is keyed

`VaultRecord.contentHash` is `HMAC-SHA256(K_hash, plaintext)` truncated, **not** a bare SHA-256.
`vault.json` is plaintext on an unsandboxed disk, and an unkeyed hash of a six-digit code or
`hunter2` is recoverable offline in seconds. The hash exists so a **locked** vault can still take
part in a merge, and so a fresh GCM nonce does not look like an edit.

The wire envelope's top-level `contentHash` has a different job: it is the SHA-256 of the body
bytes in `fields`, which for a secure record are already the stable sealed value. The vault HMAC
travels separately as `x.vaultContentHash`, inside the encrypted blob. On import only that keyed
value may populate `VaultRecord.contentHash`; writing the envelope digest there would replace a
plaintext HMAC with a hash of ciphertext and break locked merge comparisons.

### What is deliberately not protected

- **Metadata.** A secure snippet's name, keyword, and tags are plaintext in `vault.json`. This is
  non-negotiable: the `CGEvent` keyword matcher runs with the vault locked and the app
  backgrounded, so encrypting the keyword means no trigger detection can exist at all. An attacker
  with the file learns that a secret called *AWS prod root key* exists, not the secret.
- **Someone at the unlocked Mac.** They can open the app and click Reveal.
- **Any process running as the same user** that drives our own binaries. Verifying an IPC peer's
  code signature proves *which binary* is calling; it proves nothing about *who told it to*.
- **Memory.** Swift `String` cannot be reliably zeroed — short strings live inline and copy by
  value, longer ones are immutable and COW-shared, and `NSTextField.stringValue`,
  `AXUIElementSetAttributeValue`, and `JSONEncoder` all take copies out of reach. Plaintext is
  kept as bytes until the final hop. Secure expansion moves the decrypted `Data` immediately into
  a one-owner raw allocation, wipes the source best-effort, and erases that controlled allocation
  with `memset_s` before insertion starts. The final transient `String` references are discarded
  after insertion, but claiming they were physically zeroed would be false.

### Expansion

`enabledSnippetsSorted()` — the auto-expansion path — does **not** include secure records. Its not
containing them is the structural gate that makes "a secret is never typed by an unauthenticated
keystroke trigger" true, rather than a policy a later refactor can quietly drop. The merged view is
`snippetsSortedForDisplay()`, which supplies content-free shells to both the main list and the
suggestion panel; suggestion rows mark them with a lock and `Secure`.

Explicitly accepting a secure suggestion is a separate one-use path. It asks
`deviceOwnerAuthentication` on every acceptance even if the five-minute editor reveal window was
already open, decrypts exactly one record, and drops the in-memory vault key and authentication
context before returning the plaintext lease to the injection engine. Authentication can take
seconds, so the engine then restores the original target and re-proves the exact trigger before it
deletes or inserts anything. Cancellation and every failed revalidation wipe the lease too.

### Where content could escape, and what stops it

| Path | What stops a secret going through it |
|---|---|
| `snippets.json`, export, the undo stack | Secure records are never in `SnippetStore.snippets`. Structural — nothing to filter. |
| Share deep link | `SnippetDeepLink.url(for:isSecure:)` has **no default** for `isSecure`, so omitting the check does not compile. |
| Auto-expansion from the keystroke buffer | Secure records are absent from `enabledSnippetsSorted()`. |
| Authenticated suggestion expansion | Every explicit acceptance gets a fresh LocalAuthentication context. `VaultSession.withOneUseAuthentication` locks before prompting and on every exit; `SecurePlaintextLease` zeroes its owned byte allocation on success, refusal, cancellation, and deinit. |
| Clipboard managers | Secure expansion prefers the Accessibility write path, which never touches the pasteboard. Where the pasteboard is unavoidable, `TemporaryPasteboardLease(isConcealed:)` sets `org.nspasteboard.ConcealedType` and `TransientType` — a **courtesy, not a control**: there is no AppKit constant, managers honour it only by convention, and anything that ignores it still sees the text. |
| The snippet list and suggestion panel | A secure main-list row renders `••••••••`, and a suggestion row shows a lock marker. Both carry a shell with `content == ""`, so there is nothing to render even if either view forgot. |
| Two-file moves | `LibraryTransaction` — one lock over both files, destination written before source removal, crash marker. A mixed-direction sync batch first writes an intentional duplicate state. An interruption duplicates, never disappears. |

### The CLI can ask for a secret; it cannot take one

`snippets-cli reveal <keyword>` sends a request over an `AF_UNIX` socket to the running
app, which prompts a human, naming the calling program. The CLI holds no key and has no
code path that decrypts. `get` on a secure snippet reports that it is secure and points
at `reveal` rather than saying "not found", which would send someone off to recreate a
secret they already have. `list` includes secure snippets as content-free shells, so
their keywords cannot be accidentally reused.

**Verification is one-directional today.** The app checks who is calling it; the CLI does
not check who answered. A same-uid process can unlink the socket and rebind it, then return
a string of its own choosing to `snippets-cli reveal` — the CLI prints it and exits 0. No
secret is disclosed (the attacker supplies a value, never obtains one), and the same
attacker has cheaper routes to the identical outcome: `SNIPPETS_SUPPORT_DIR` is honoured at
runtime, and `/usr/local/bin/snippets-cli` is an unprivileged symlink when that directory is
user-writable. Worth knowing before anyone pipes `$(snippets-cli reveal …)` into something
that matters.

The server checks the caller's audit token (`LOCAL_PEERTOKEN`, not `LOCAL_PEERPID` — pids
are reused) and its code signature against the team identifier. **That proves which
binary is calling and nothing about who told it to.** Any script running as this user can
execute the genuine CLI; that is what "running as the user" means. The signature check
stops a *different* program impersonating ours, and the human prompt is the actual
control — which is why it is not suppressible, names the process, and is rate-limited to
five per minute. Consent has a 30-second deadline; prompt work is dispatched off the socket's
serial accept queue, so one unanswered request cannot wedge every other CLI command. A prompt that
appears often enough is a prompt people dismiss unread.

Verified end to end: the signed CLI is answered, an unsigned client gets `refused`, the
socket is removed on quit, and `reveal` on an unknown keyword returns exit 6 without ever
raising a prompt. The approved path — a real reveal — still needs a human and has not
been exercised.

Tags and keyword uniqueness deliberately *do* span both stores: a tag used only by secure snippets
must still appear in the filter bar, and a plaintext snippet must not be able to claim a keyword a
secure one already uses, or the expander becomes ambiguous with no way for the user to see why.

---

## 6. Sync

Only four fields leave the device:

```json
{ "id": "…", "rev": "12", "deleted": false, "blob": "v1.<nonce>.<ciphertext+tag>" }
```

Name, keyword, tags, clock, origin, and the secure flag all live *inside* the blob, and blobs are
padded to a fixed multiple, so the backend cannot tell which records are secure or how long
anything is. `deleted` is in the clear only so a backend can garbage-collect tombstones.

**The crypto scope must never come from `Sync/state.json`.** That file is designed to regenerate
itself whenever it cannot be read, because it holds no user data — so binding ciphertext to a value
stored there would destroy every secure snippet the first time it went missing. A secure record's
scope is `VaultDocument.kid`, which lives in the same file as the records it protects. The rule
generalises: the value that unlocks a file belongs in that file.

### The wire key is not the vault key

Originally it was: `SyncCoordinator` built its sealer from `VaultSession.keyring(...)`, so sync
could not start without a vault and could not *run* without an unlocked one. Two consequences, both
bad and neither bought anything:

- Syncing an ordinary snippet required setting up Secure Snippets and saving a recovery key.
- Background rounds stopped every half hour, at the vault's absolute session ceiling, until the
  user proved presence again — for a loop whose entire job is to run unattended every two minutes.

Work out what that key actually protects and the gate collapses. Ordinary snippet bodies are
already plaintext in `snippets.json`; a secure snippet's name, keyword and tags are already
plaintext in `vault.json`; and a secure snippet's *content* is not protected by the wire key at all,
because `SnippetLibraryBridge` puts the vault's `sealed` bytes on the wire verbatim, already
encrypted under `K_rec`. So the wire key defends against Apple and against whoever ends up with the
bucket. It cannot defend against someone at the unlocked Mac — they can read both files directly.
Touch ID on it was guarding a copy of data sitting in the clear two directories away.

`SyncKeyStore` therefore owns `K_sync`, a 256-bit key with its own HKDF salt, stored in the Keychain
under the fixed account `sync-v1`, which doubles as the scope bound into every envelope's AAD. It is
read with no user-presence check, because nothing it protects justifies one. `K_lib` stays exactly
as strict as it was, and is now only ever read to reveal a secret — which is the one thing that
genuinely needs a human.

`Readiness` lost `needsVault` and `needsUnlock` as a result. What is left is `off`, `ready`, and
`cannotStart` when a start prerequisite such as the Keychain is temporarily unavailable.

### Getting a second Mac working: nothing to copy

`K_lib` already travelled — `KeychainSecretStore` stores it with `kSecAttrSynchronizable` whenever
the entitlement is present, and the shipping build has it. What did not travel was the name of the
lock it opens. A second Mac called `createVaultIfNeeded`, minted a fresh `kid`, and since `kid` is
the crypto scope, the two Macs could not read one record of each other's. Settings told the user to
copy `Vault/vault.json` across by hand — carrying about six hundred bytes of **non-secret** metadata
over a channel already open for the actual secret.

`VaultIdentityStore` publishes the vault document with its records stripped — `kid`, salt, KDF
parameters, wraps — as one more synchronizable Keychain item under the fixed account
`vault-identity`. A Mac with no vault adopts it instead of minting a rival, writing a records-free
`vault.json` and pointing the session at the shared `kid`. `K_lib` is already arriving over the same
channel, so the ordinary case needs one click and no file.

Chosen over a CloudKit record because the identity has to be readable *before* the first round — it
is what decides whether this Mac has a vault at all — and fetching it would need a sealer that needs
a vault. It also adds no schema, no entitlement, and is end-to-end encrypted between the user's
devices rather than merely encrypted to Apple.

Four rules keep it safe:

- **First publisher wins.** A published identity is never overwritten with a different `kid`. Two
  Macs that each minted a vault before this existed keep whichever published first, and the loser's
  local vault is left completely alone — its records are the only copy of secrets that exist
  nowhere else, and re-pointing it at a key it was not encrypted under would destroy them. Reported,
  not repaired; the recovery key is the way out.
- **Same-vault updates are monotonic.** A stale Mac may add a recovery/CLI wrap or an unknown
  extension that is absent, but it cannot erase a non-null wrap or overwrite an extension already
  published. The `kid`, salt and KDF parameters must match exactly; a disagreement is refused.
- **`reload` adopts only when sync is on**, because adoption writes a file and a Mac that merely
  shares an iCloud account should not spontaneously grow a vault. An explicit "make this secure"
  adopts regardless: the user is asking for a vault, and the right one to give them is the one they
  already have.
- **`applyRemote` adopts too**, before refusing an incoming secure record. That is the only moment a
  Mac with no secure snippets of its own ever learns a vault exists, and without it adoption would
  wait for the next launch.

When the key genuinely has not arrived — iCloud Keychain switched off, most likely — the vault
reports `.noKey`, ordinary snippets keep syncing, and Settings offers the recovery key. The engine
reports that as `waitingForVault` rather than as `offline`, which is what it used to say and was a
lie: iCloud is reachable, the round is fine, and the user's problem is a key.

**The residual race, stated rather than engineered around.** `addItemIfAbsent` refuses to clobber,
so two processes on one Mac cannot mint two wire keys. Two *Macs* that both mint before iCloud
Keychain has propagated either can — which needs a user enabling sync on two Macs within about a
minute, ever, and only the first time. iCloud Keychain converges on one; `SyncCoordinator` notices
the stored key no longer matches the one its engine holds, rebuilds on the winner, and discards the
agreed base so every local record is offered again under that key. The projection sidecar is kept:
its HLC/origin and unknown extension fields are independent of the wire key, and deleting it would
strip forward-compatible metadata on the replacement upload. Stale losing-key records still
need the planned zone wipe, but they no longer suppress readable replacements.

### The loop

`SyncEngine` runs one round: push, then fetch, then apply. **Push first** — fetching and applying
first would rewrite local records before this device's own changes had left it, and a crash in
between loses them with nothing to recover from. The worst case of pushing first is a duplicate
round.

A record is recorded in the base only once the backend has *accepted* it. Recording it at submit
time would make the next diff skip it, and a rejected record would never be pushed again.

`Sync/library-metadata.json` is the local projection sidecar. The frozen `snippets.json` format
cannot hold an HLC, origin, or forward-compatible wire extensions, so the bridge retains those
there and reuses the exact envelope while all persisted fields still match. It is derived state:
if it is missing or unreadable, `base.json` is the fallback and the cost is at most a conservative
re-push, not lost user data. This is what makes apply → export a fixed point instead of relabelling
every remote record as a new local edit on the next round.

Secure envelopes carry the originating vault's `kid` in that encrypted extension bag. The sealed
body is AEAD-bound to the same value but does not reveal it, so the stamp lets a receiver reject a
record from a rival vault before filing ciphertext it can never open. On merge, both the `kid` and
the keyed content hash follow the selected ciphertext rather than the whole-record HLC winner; a
plaintext result clears both. A scoped tombstone from a rival vault is classified as incompatible
and cannot delete a plaintext record that merely shares its UUID.

Deferral is per record when the vault has not arrived yet. Plaintext records in the same fetched
page still apply, while the cursor is held so that temporarily unfileable record is offered again
without backoff. A *different* `kid` cannot heal by waiting: the engine excludes its tombstones from
the deletion guard, applies the compatible records in the batch, then enters a sticky vault halt
instead of polling one cursor forever. Conversely, an unreadable or unexpectedly missing local
vault fails closed before projection: it must never appear as an empty vault and manufacture
tombstones. The engine passes its live in-memory base into that check, because a failed `base.json`
write cannot hide records the running process knows were accepted.

Turning sync off cancels and drains the retained round task before local vault removal is allowed.
Cancellation checks bracket every awaited backend operation, so a CloudKit request that finishes
after cancellation cannot rewrite local derived state or begin an apply. A synchronizable vault key
is not evidence that its records ever uploaded; the removal confirmation therefore warns that a
record which exists only on this Mac is permanently lost and promises restoration only for records
the backend actually received.

Two bugs the fake caught that a real backend would have taught us slowly and expensively:

- **A submit's cursor must not become the fetch position.** A cursor is a place in the change feed,
  and the one a submit returns points after our own writes — which is also after everything the
  backend already held and we had not fetched. Adopting it silently skipped remote records
  entirely.
- **An expired token is not a halt.** Treating a non-retryable rejection uniformly put a sticky,
  scary error in front of someone who just needed to sign in again.

`SyncTransport` is the seam. CloudKit and an object-storage backend are two implementations of it,
and `InMemoryTransport` — with fault injection for rejection, latency, partial batches, cursor
invalidation, and duplicate delivery — is what the engine is proven against **before** a single
byte reaches a real backend. The wire format cannot change after the first production deploy, so
it has to be right while it is still free to change.

A `DeletionGuard` refuses any remote change that would delete more than `max(5, 20%)` of the
library, and a halt is *sticky*: it never auto-heals, because auto-healing a mass deletion means
deleting, and auto-healing an integrity failure means trusting the thing that just failed.

---

## 7. Usage data never syncs

`README.md` promises that usage data "stays on this Mac and never travels in exports or share
links", and `docs/frecency-ranking.md` already argues that the boundary should be structural
rather than a filter. Nothing in the sync layer may reference `Usage/`. There is no opt-in toggle:
the payoff is roughly two weeks of better ranking on a new device against a 14-day half-life, and
that is not worth making a published promise conditional.

---

## 8. Before a backend can ship

Verified locally, by inspecting shipping apps rather than reading documentation:

- **CloudKit works in a non-sandboxed Developer ID app.** `Orion.app` (Kagi) is Developer ID,
  `sandbox=NO`, hardened runtime, and carries `com.apple.developer.icloud-services =
  [CloudKit, CloudDocuments]` plus `aps-environment` and `keychain-access-groups`. The app can
  never be sandboxed — it needs a session `CGEvent` tap and `AXUIElement` access — and that turns
  out not to matter for CloudKit. It *does* rule out iCloud Drive / ubiquity containers.
- **Developer ID provisioning profiles do not practically expire.** Orion's expires in 2042
  (`TimeToLive` 6570 days).
- **A bare Mach-O CLI can share a Keychain access group with the app.** `/usr/local/bin/orbctl`
  is a symlink into `OrbStack.app`, Developer ID signed with hardened runtime, carrying its own
  `application-identifier` and a shared `keychain-access-groups` — the same packaging
  `snippets-cli` already uses.
- `CKSyncEngine` is macOS 14+/iOS 17+ and `CKRecord.encryptedValues` is macOS 12+, both under the
  15.5 deployment target.

Still unverified, each with a fallback:

| Unknown | Fallback |
|---|---|
| `CKSyncEngine` specifically in a non-sandboxed Developer ID build (no shipping exemplar found) | Hand-roll `CKFetchRecordZoneChangesOperation`/`CKModifyRecordsOperation` behind the same protocol, or ship object storage first |
| Push delivery to such an app | Polling; `supportsPush` is already on the protocol |
| Data-protection Keychain + access group after a Sparkle update, on a stapled build | Keep the entitlement-free login-keychain tier; recovery keys make a missing item recoverable |

**Requires the maintainer's Apple Developer account**: enabling iCloud and Keychain Sharing on the
App IDs, and creating the container. Until then the CloudKit backend cannot be built, so the code
must gate on the entitlement at runtime (read the app's own entitlements via `SecCodeCopySelf` →
`SecCodeCopySigningInformation`) and degrade to the other backend rather than crash.

Adding any of these entitlements means the app permanently carries
`Contents/embedded.provisionprofile`, which Gatekeeper evaluates at launch. That is a new single
point of total failure for an app that currently has none, so `Distribution/common.sh` should
assert the profile is present, unexpired, and authorizes every entitlement the app claims —
notarization does **not** check that.

---

## 9. Decisions worth not relitigating

| Decision | Why | Rejected |
|---|---|---|
| `snippets.json` frozen at nine keys | Old binaries strip unknown keys and write back | A `rev`/`hlc` field on `Snippet` |
| Secure snippets in a separate file | Old builds cannot leak what they cannot see | A `secure: true` flag in `snippets.json` |
| Three-way merge against `lastKnownDiskData` | The ancestor was already being tracked, for free | `updatedAt` LWW, which loses a field per cross-device edit |
| Tie broken by payload hash | The device-id version cannot converge | "Local always wins" |
| Conflict copies for content only | Content is the only irreplaceable field | A text CRDT — content is a *template*, and character-merging `{date:yyyyMMdd}` yields garbage |
| Keep JSON + `flock` + CAS | Human-readable, git-friendly, keeps old writers first-class | SQLite, directory-per-snippet — both give a stale CLI a silent split-brain library |
| Usage never syncs | An already-published promise | An opt-in toggle |
| A separate `K_sync` for the wire | Everything it protects is already plaintext on this disk, so a presence gate cost the whole feature and bought nothing; and it lets sync work with no vault at all | Reading `K_lib` without the presence check — same exposure, but it hollows out the one gate that matters |
| Vault identity rides iCloud Keychain | It has to be readable before the first round, and it is not secret; the key was already on that channel | A CloudKit record (needs a sealer that needs a vault); `NSUbiquitousKeyValueStore` (another entitlement) |
| First publisher wins the identity slot | Deterministic without a protocol, and it can never re-point an existing vault at a key its records were not sealed under | Last writer wins; merging two vaults automatically |
| CLI reveal is app-brokered | A CLI that can decrypt unattended makes every `curl \| sh` an exfiltration primitive; routing through the app puts a human in the loop | Never revealing at all (simpler, ~900 lines lighter); giving the CLI the Keychain group unconditionally |
| Peer check anchored to the team ID | The CLI is a bare Mach-O with its own signing identifier, so a bundle-id requirement would not match it | Checking the bundle id; trusting `LOCAL_PEERPID` alone (racy — pids are reused) |
