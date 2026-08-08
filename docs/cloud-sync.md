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
| 2. Wire record model, transport protocol, fake transport | Core types landed; not wired to the app. |
| 3. Secure snippets — crypto core | Landed; the Keychain wrapper, unlock UX, and UI are not. |
| 4. Sync engine driven by the fake | Not started. |
| 5. First real backend (CloudKit **or** object storage) | Not started; gated on §8. |
| 6. Second backend, conflict UI | Not started. |
| 7. Hosted server tier | Optional; not started. |
| 8. iOS app | Not started. `snippets/Core/` is already platform-agnostic for it. |

Phase 1 was worth shipping on its own and does not depend on anything after it.

---

## 2. The bug Phase 1 fixed

The app and `snippets-cli` each did an unlocked read-modify-write of the whole file: decode the
array, edit a private copy, rename a complete replacement into place. Concurrently, that loses
most of the writes — measured at a realistic read-to-write gap, 60 concurrent writers keep 10–18
of their edits. The CLI printed a success receipt for every one.

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

The lock lives on its own zero-byte file that is created once and never unlinked or replaced.
`flock` attaches to an inode, and an atomic write renames the inode away — so locking
`snippets.json` itself measures the same as no lock at all.

`flock` failing because the filesystem does not implement it (some network-mounted home
directories) is **not** fatal: the write proceeds and the generation counter catches the
collision afterwards. A *timeout* is fatal, because it means a peer genuinely holds the lock.

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
writer just added — undo would delete someone else's snippets. So the stacks are rebased through
the same merge. Above a size threshold this degrades to the previous behaviour of clearing them,
which loses undo history but never data.

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
├── Sync/                  state.json, base.json, tombstones.json, library.lock, Quarantine/
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

A random 256-bit library key `K_lib` is the root and is never used to encrypt anything directly.
Per-purpose subkeys come from HKDF-SHA256:

- `K_rec(id)` — per record, so a 96-bit GCM nonce cannot collide across the library.
- `K_hash` — for the keyed content hash.

`K_lib` itself is wrapped under a passphrase (PBKDF2-HMAC-SHA512, 600 000 iterations, pinned and
recorded in the file so a future Argon2id is purely additive) and, separately, under a printable
recovery key. Apple ships no memory-hard KDF; vendoring one into a target set that includes a bare
Mach-O CLI and standalone `swiftc` tests costs three bridging setups, so the `alg` field carries
the upgrade path instead.

Every AEAD operation binds an AAD covering version, scope, record id, and the deleted flag, so a
ciphertext cannot be replayed under another record's identity. There is deliberately no
"verifier" field: the AEAD tag already rejects a wrong passphrase, and a second oracle buys
nothing.

### The content hash is keyed

`contentHash` is `HMAC-SHA256(K_hash, plaintext)` truncated, **not** a bare SHA-256. `vault.json`
is plaintext on an unsandboxed disk, and an unkeyed hash of a six-digit code or `hunter2` is
recoverable offline in seconds. The hash exists so a **locked** vault can still take part in a
merge, and so a fresh GCM nonce does not look like an edit.

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
  kept as `Data` end-to-end and converted at the final hop only.

### Expansion

`enabledSnippetsSorted()` — the auto-expansion path — must **not** include secure records. Its not
containing them is the structural gate that makes "a secret is never typed by an unauthenticated
keystroke trigger" true, rather than a policy a later refactor can quietly drop.

---

## 6. Sync

Only four fields leave the device:

```json
{ "id": "…", "rev": "12", "deleted": false, "blob": "v1.<nonce>.<ciphertext+tag>" }
```

Name, keyword, tags, clock, origin, and the secure flag all live *inside* the blob, and blobs are
padded to a fixed multiple, so the backend cannot tell which records are secure or how long
anything is. `deleted` is in the clear only so a backend can garbage-collect tombstones.

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
| Data-protection Keychain + access group after a Sparkle update, on a stapled build | Passphrase-only vault, no Keychain, no biometrics, no entitlements, no embedded profile |

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
| CLI cannot decrypt by default | Otherwise every `curl \| sh` becomes a silent exfiltration primitive | Giving the CLI the Keychain group unconditionally |
