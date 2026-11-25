# 03 — Git sync provider: porting brief (Swift → Kotlin)

Scope: everything Android needs to speak to a Snippets Git library that the Mac, iOS and Linux apps already use. Pure Kotlin, no JNI, no
`git` binary. The Swift sources are the behavioural reference; `snippets-linux/src/git_*.rs` is the second reference wherever the text
says "byte for byte". Pointers are `path:line` at commit `66e7c7f` (main, 2026-11-25).

Conventions used below:

- `LF` is byte `0x0a`, `NUL` is `0x00`. `<uuid>` is always 36 lowercase characters, 8-4-4-4-12.
- `<hex40>` is a lowercase SHA-1. Uppercase hex is rejected everywhere (`GitObjects.swift:31-41`).
- "closed code" means a fixed ASCII token; nothing a server sent is ever kept, shown or logged.
- Hard invariants from `AGENTS.md` ("Git sync transport") are marked **[INV]**.
- Things owned by other briefs and only referenced here: `WireRecord`/`WireCodec`/`SyncEnvelope`/ `CanonicalJSON`/`HLC`/`SnippetTagging`
  (01 library+engine), `RecoveryKey`/`KeyWrap`/ `SnippetCrypto`/`SecureSnippetStore`/`VaultSession` (02 crypto+vault).

---

## 1. Component map

### 1.1 Core (`snippets/Core/Git/`, compiled into apps and CorePackage, not the CLI)

| File | Purpose | Public surface | Depends on | Tests |
|---|---|---|---|---|
| `GitObjects.swift` (351) | SHA-1 object ids, object header, tree parse/serialize, commit parse/serialize, pkt-line | `GitObjectID` :16, `GitObjectType` :78, `GitObject` :112, `GitFormatError` :121, `GitTreeEntry` :132, `GitTree` :169, `GitCommit` :230, `GitPktLine` :278 | SHA-1 only | `Tests/Core/GitPrimitivesTests.swift` |
| `GitPack.swift` (345) | zlib, delta application, pack v2/v3 parse, undeltified pack build | `GitZlib` :12, `GitDelta` :70, `GitPack.Limits` :127, `GitPack.parse` :147, `GitPack.build` :314 | zlib, SHA-1 | `GitPrimitivesTests` (pack*, delta*, zlib*) |
| `GitSmartHTTPClient.swift` (707) | locations, remote, failure enum, advertisement, upload-pack and receive-pack requests and responses, HTTP send, redirect guard | `GitSSHLocation` :10, `GitRepositoryLocation` :54, `GitRemote` :138, `GitRemoteFailure` :256, `GitRefAdvertisement` :275, `GitPushResult` :286, `GitSmartHTTPClient` :296, `GitRedirectGuard` :685 | URLSession | `GitPrimitivesTests`, `GitSSHTests` (location, framing) |
| `GitSSHClient.swift` (572) | wire-client protocol, SSH connector protocol, SSH wire client, stderr classification, macOS system-ssh connector | `GitWireClient` :8, `GitSSHExchange` :21, `GitSSHConnector` :36, `GitSSHClient` :55, `GitPktLine.advertisementEnd` :127, `GitSSHDiagnosis` :150, `GitSystemSSHConnector` :207 (macOS only) | the above | `Tests/Core/GitSSHTests.swift` |
| `GitObjectCache.swift` (232) | content-addressed snapshot cache with retained/pinned commits | `GitObjectCache` :15 | filesystem | `GitSyncTransportTests` (cache*) |
| `GitSyncTransport.swift` (1840) | the `SyncTransport`; setup operations; commit planning; plain-text fetch/normalize; layout, manifest, record file, cursor; failure mapping | `GitSyncTransport` :45, `GitSnapshot` :1573, `GitSyncLayoutError` :1585, `GitSyncLayout` :1601, `GitSyncManifest` :1673, `GitRecordFile` :1738, `GitSyncCursor` :1773 | all of the above, `SyncTransport` | `GitSyncTransportTests.swift`, `GitIncrementalFetchTests.swift`, `GitPlainTextTests.swift` |
| `GitPlainText.swift` (449) | library mode, Markdown file render/parse/derive | `GitLibraryMode` :9, `GitPlainCodec` :21, `GitPlainSnippetFile` :48 | `SyncEnvelope`, `CanonicalJSON`, `HLC`, `SnippetTagging` | `GitPlainTextTests.swift`; vectors `snippets-linux/tests/fixtures/git-plain-v1.json` |
| `GitSyncRecovery.swift` (121) | `keys/recovery.json` | `GitSyncRecovery.Kit` :40, `seal` :69, `open` :84 | `RecoveryKey`, `PortableKeyBundle`, HKDF, AES-GCM | `GitSyncTransportTests` :803 |
| `GitSyncVault.swift` (204) | `keys/vault.json` | `GitSyncVault.Identity` :49, `seal` :121, `open` :145 | `SnippetCrypto`, HKDF, AES-GCM | `GitSyncVaultTests.swift` (known answer :146) |

### 1.2 App layer (shared by macOS and iOS)

| File | Purpose | Notes |
|---|---|---|
| `snippets/Sync/GitSyncSetup.swift` (1652) | onboarding state machine, all user-facing texts, failure mapping | §5 |
| `snippets/Sync/GitSyncKeyStore.swift` (136) | per-library 64-byte key in the Keychain | service `com.khm.snippets.git-sync` :19 |
| `snippets/Sync/GitSSHSupport.swift` (262) | host-key trust store, published fingerprints, per-device P-256 identity | §6 |
| `snippets/Sync/SyncBackendSelectionStore.swift` | `GitCoordinates` :372, defaults keys :481-487, token record :727, `configureGit` :770, `makeTransport` :1405, protocol location key :1592, cache dir :1613 | §4.9 |
| `snippets/Sync/SyncCoordinator.swift` | pacing use :557-570, :973-1001; status texts :2066-2143 | §4.8, §5.8 |
| `snippets-ios/GitNIOSSHConnector.swift` (598) | SwiftNIO SSH connector | §6.3 |
| `snippets-ios/GitSyncSettingsViewController.swift` (1335) | iOS screen: connect loop :673, host-key prompt :711, steps :742, recovery sheet :1138 and :1304 | §5.7 |

### 1.3 Rust mirrors and tests

| File | Mirrors |
|---|---|
| `snippets-linux/src/git_layout.rs` | manifest :99, READMEs :44-46, record file :148, paths :199, versions :217-231, cursor :270, digests :319-355 |
| `snippets-linux/src/git_location.rs` | parsing :211, `canonical_identity` :196, SSH value rules :46, `same_endpoint` :173, branch/user/token rules :361-385 |
| `snippets-linux/src/git_recovery.rs` | recovery envelope bytes :81 |
| `snippets-linux/src/git_vault.rs` | vault envelope bytes :149, payload field order :92 |
| `snippets-linux/src/git_plain.rs` | Markdown file; Foundation-compatible whitespace :553, base64 :640, strict UUID :629, tag folding :701-971 |
| `snippets-linux/src/git_tests.rs`, `git_plain_tests.rs` | vectors and live git tests |
| `Tests/Core/GitTestServer.swift` | `git http-backend` URLProtocol :8, `GitFixture` :193, fake ssh :318, real loopback sshd :377 |
| `scripts/git-http-test-server.py`, `scripts/test-git-sync-integration.sh` | loopback HTTP server; multi-process mac/iOS phases |
| `snippets-cross-platform-tests/GitSync*`, `GitSSHSupportTests.swift` | app-hosted setup, vault, rotation and SSH identity tests |

---

## 2. Repository layout, byte-exact

One branch holds one library.

```text
snippets-sync.json                 manifest
README.md                          mode-specific README
keys/recovery.json                 library key under the recovery code
keys/vault.json                    vault identity + vault key under the same code
records/<2 hex>/<uuid>.json        one WireRecord (always; in plain mode: secure, tombstones, x-carrying)
snippets/<slug>-<id8>.md           plain-text mode only: one live ordinary snippet
```

Any other entry in any tree this client rewrites is preserved byte for byte, including its raw mode and raw (possibly non-UTF-8) name
(`GitObjects.swift:136-146`).

### 2.1 Branch and remote rules
- Ref name is `refs/heads/<branch>` (`GitSmartHTTPClient.swift:159`). Default branch `main`; suggested branch when the chosen one is
  foreign: `snippets` (`GitSyncSetup.swift:53`).
- Branch validation (`GitSmartHTTPClient.swift:237-251`, mirror `git_location.rs:361-375`): 1 to 200 bytes; only `[0-9A-Za-z-_./]`; must
  not start with `-` or `/`; must not end with `/`, `.` or `.lock`; must not contain `..` or `//`; must not equal `HEAD`; no path
  component may start with `.`.
- **[INV]** Never create, overwrite or force-push implicitly. Only `initializeRepository()` creates a branch, and only when it is
  absent. Every push is `old → new` with `old` equal to the head the commit was built on; `old = 0{40}` only for creation.
- SHA-256 object-format repositories are refused: an advertised `object-format` capability other than `sha1` is
  `unsupportedServer("object_format")` (`GitSmartHTTPClient.swift:389-391`).

### 2.2 Manifest `snippets-sync.json`
Written by Foundation `JSONEncoder` with `[.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]` plus one `LF`
(`GitSyncTransport.swift:1705-1713`). Foundation's pretty printer puts a space on both sides of the colon and indents two spaces. The
exact bytes (`git_layout.rs:99-106`):

```text
{LF
  "datasetID" : "<uuid>",LF
  "format" : "snippets-git-sync",LF
  "recordProfile" : "<profile>",LF
  "schemaVersion" : <1|2>LF
}LF
```

- `format` marker: `snippets-git-sync` (`:1674`).
- `recordProfile`: `snippets-wire-v1` (encrypted) or `snippets-plain-v1` (plain text) (`GitPlainText.swift:9-16`).
- `schemaVersion`: `1` as created (`currentSchemaVersion`, `:1676`); `2` after the keys were replaced (`rotatedSchemaVersion`, `:1681`).
  Same layout. Supported range `1...2` (`:1682`). Linux never writes 2; Android must write 2 from `replaceLibrary`.
- Decoding (`:1718-1733`), in this order:
  1. more than 16,384 bytes, not a JSON object, or `format` not exactly the marker → `notALibrary` (the branch is *foreign*; note that
     garbage JSON is foreign, not a schema error);
  2. key set not exactly `{datasetID, format, recordProfile, schemaVersion}`, `schemaVersion` outside 1...2, unknown `recordProfile`, or
     `datasetID` not a UUID that round-trips to the same lowercase text → `incompatibleSchema` (`git_sync_schema_unsupported`).
- A root tree with no *regular file* entry named `snippets-sync.json` is also `notALibrary` (`:1012-1014`).

### 2.3 README.md
Mode-specific, never rewritten after creation except by `replaceLibrary` (which writes the README of the same mode again). The exact
text is the string literal with single `LF` line breaks and a trailing `LF`; long lines are *not* wrapped (the Swift literal uses `\`
continuations). Authoritative single-line forms: `git_layout.rs:44` (encrypted) and `git_layout.rs:46` (plain). Swift:
`GitSyncTransport.swift:1639-1653` and `:1612-1637`. Copy the Rust constants verbatim into Kotlin and assert the blob ids in a test:
both platforms must produce the identical blob.

### 2.4 Record file `records/<xx>/<uuid>.json`
- Path: `xx` = first two characters of the lowercase uuid; file name `<uuid>.json` (`GitSyncTransport.swift:1655-1658`).
- A fanout directory is recognized only if its name is exactly two characters of `[0-9a-f]` (`:1660-1662`). A file in it is a record
  only if its name is `<uuid>.json`, the uuid round-trips lowercase and starts with the directory name (`:1664-1670`). Everything else
  is ignored and preserved.
- Bytes: `JSONEncoder` `[.sortedKeys, .withoutEscapingSlashes]` (compact, no spaces) plus `LF` (`:1746-1754`, mirror
  `git_layout.rs:148-158`):

```text
{"blob":"<standard base64 with padding>","deleted":<true|false>,"id":"<uuid>","rev":"<rev>"}LF
```

- Decoding (`:1756-1769`): at most `2 × 900_000` bytes; exactly the four keys; `id` equals the id the path names; `rev` 1 to 256 UTF-8
  bytes; `blob` strict standard base64 that re-encodes to the same text; decoded blob at most 900,000 bytes. Anything else is
  `malformedRecord`, which the transport converts into an *unopenable record* instead of failing (§4.4).
- The transport never interprets `blob`: it is the sealed envelope from `WireCodec`.
- Identical bytes produce the identical blob id, so re-uploading an unchanged record is a no-op.
- JSON string escaping matters only for `rev` (everything else is base64, uuid or bool). Use the same escaping as the core's canonical
  JSON; `/` is never escaped.

### 2.5 Tombstones
**[INV]** A deletion is a record save with `"deleted":true`. The record file is never removed. A record file that disappears from a
fanout tree between two commits is remote data loss: `remoteDataReset("git_record_removed")` (`:1061-1064`, `:832-835`).

### 2.6 Plain-text mode: `snippets/<slug>-<id8>.md`
Only a *direct* regular-file child of `snippets/` whose name ends in `.md` (case-insensitive) is a snippet file
(`GitSyncTransport.swift:1146-1148`). Sub-directories are ignored.

#### 2.6.1 What is rendered as Markdown
An envelope is rendered only if all hold (`GitPlainText.swift:70-80`): not deleted; not secure; `x` is empty; `schemaVersion` is the
current one; it has `fields`; body shorter than `1_100_000 − 4_096` bytes; body is valid UTF-8; **and** the rendered file reads back as
exactly that envelope with `edited == false`. Everything else is a ciphertext record under `records/`.

#### 2.6.2 Bytes written (`GitPlainText.swift:82-106`)

```text
---LF
name: <canonical JSON string>LF
keyword: <canonical JSON string>LF
tags: <canonical JSON array of strings>LF
enabled: <true|false>LF
pinned: <true|false>LF
id: <uuid>LF
sync: <base64url, no padding, of canonical JSON object>LF
---LF
<body bytes verbatim>LF
```

The `sync` object has exactly eight keys, canonical JSON (sorted keys): `createdAt` (double, seconds since 2001-01-01T00:00:00Z, i.e.
`timeIntervalSinceReferenceDate`), `hash` (the envelope hash, hex), `hlc` (string), `id` (lowercase uuid), `origin` (string),
`schemaVersion` (int), `updatedAt` (double), `x` (object, always `{}` when rendered). base64url = standard base64 with `+`→`-`, `/`→`_`,
`=` removed (`:437-442`).

File name: `<slug(name)>-<first 8 chars of lowercase uuid>.md` (`:110-112`). Slug (`:117-137`): on Apple, ICU `toLatin` then
`stripDiacritics`; then lowercase; keep ASCII letters and digits; any run of other characters becomes one `-` between kept runs; stop
once 48 characters are reached; strip trailing `-`; empty → `snippet`. Linux only strips diacritics (NFD, drop marks) and so maps
`Привет` to `snippet` (`git_plain.rs:147-178`). **The path is cosmetic**: identity never depends on it, and an existing file keeps its
path until the snippet is renamed. Collisions: append `-2`, `-3`, … before `.md` (`GitSyncTransport.swift:1438-1444`).

#### 2.6.3 Reading (`GitPlainText.swift:188-234`, parser `:280-339`)
1. More than 1,100,000 bytes → malformed.
2. Front matter is present iff, after an optional UTF-8 BOM, the file starts with `---` followed only by spaces, tabs or `\r` up to the
   first `LF` (`:150-156`).
3. No front matter: the whole file is the body (minus one final `LF`), the name is the file name without `.md`.
4. Front-matter grammar (lenient):
   - lines split on `LF`; one trailing `\r` per line is dropped; invalid UTF-8 is decoded lossily;
   - opening line trimmed of Foundation `.whitespaces` must equal `---`; the closing line likewise; no closing line → malformed;
   - blank lines and lines starting with `#` are skipped; a line with no `:` is skipped;
   - key = text before the first `:`, trimmed, lowercased; value = the rest, trimmed;
   - `name`, `keyword`: if the value starts with `"` and parses as a JSON string, that string; else if it is at least two characters,
     starts and ends with `'`: the inside with `''`→`'`; else the bare value (`:353-359`);
   - `tags`: if it starts with `[` and parses as a JSON array of strings, that array; otherwise strip one surrounding `[`…`]` if
     present, split on `,`, apply the string rule to each trimmed part, drop empties (`:361-371`); an empty value starts a YAML block
     list: following lines that start with `-` add items until any other non-list line (`:308-313`, `:321-323`);
   - `enabled`, `pinned`: `true|yes|on|1` / `false|no|off|0`, case-insensitive; anything else makes the whole file malformed
     (`:373-379`);
   - `id`: the first line holding a valid UUID wins; invalid ones are ignored (`:326-329`);
   - `sync`: parsed into the eight-key metadata, or nil if anything is off (`:393-404`); the *last* `sync` line decides; also sets
     `newerSync` (`:383-391`): the value decodes to a JSON object whose integer `schemaVersion` is above the current one, or whose key
     set is a strict superset of the eight;
   - unknown keys are ignored.
5. Body = bytes after the closing line, minus one final `LF` (or minus one final `\r\n` when the closing `---` line itself ended in
   `\r\n`) (`:343-351`).
6. `newerSync` → `tooNew`: delivered as unreadable, never normalized (`:197`).
7. Identity: `assignedID ?? sync.id ?? first valid id line ?? derivedID(path)` (`:205`). `derivedID` = first 16 bytes of
   `SHA256("snippets-git-plain-file-v1" LF path)` with `b[6] = (b[6] & 0x0f) | 0x80` and `b[8] = (b[8] & 0x3f) | 0x80` (`:177-183`);
   `path` is `snippets/<file name>`. **[INV]** identity comes from the file alone, never from history.
8. Exact (not edited) iff `sync` exists, its `schemaVersion` is current, `sync.id == id`, the `id` line equals `sync.id`, and the
   ten-key envelope rebuilt from the file hashes to `sync.hash` (`:213-221`). Rebuilt envelope (`:408-435`): `schemaVersion`, `id`,
   `hlc`, `origin`, `secure:false`, `deleted:false`, `contentHash` = hex SHA-256 of the body, `fields` `{name, keyword, content, tags,
   isEnabled, isPinned, createdAt, updatedAt}`, `x`, then `hash` = hex SHA-256 of the canonical JSON of the other nine keys. It is
   validated with `SyncEnvelope.parse`, so a file can never produce an envelope the wire layer would refuse. Missing values default to:
   name `""`, keyword `""`, tags `[]`, enabled `true`, pinned `false`.
9. Otherwise it is a hand edit (`:223-233`): `hlc` = `sync.hlc` bumped (`counter + 1`, or `wallMs + 1, counter 0` on overflow of UInt16;
   `:237-241`) on device `00000000`; with no usable `sync`: `wallMs 0, counter 0, device 00000000` (`000000000000-0000-00000000`);
   `origin` `00000000`; tags through `SnippetTagging.normalizedTags`; timestamps from `sync` or `0`; `x` from `sync` or `{}`.
10. A file whose front matter starts but does not parse is matched by a byte-level scan of the first 16,384 bytes for a parseable
    `sync:` line, else the first valid `id:` line (`:160-175`).

Record versions in plain mode: `git-md-blob-sha1:<hex40>` for a Markdown file, `git-blob-sha1:<hex40>` for a file under `records/`
(`GitSyncTransport.swift:1489-1497`).

### 2.7 `keys/recovery.json` (`GitSyncRecovery.swift`, mirror `git_recovery.rs`)
Outer file, pretty-printed as the manifest, plus `LF` (`git_recovery.rs:81-85`):

```text
{LF
  "algorithm" : "snippets-git-recovery-hkdf-sha256-aes256gcm-v1",LF
  "ciphertext" : "<standard base64 of nonce(12) ‖ ciphertext ‖ tag(16)>",LF
  "datasetID" : "<uuid>",LF
  "schemaVersion" : 1LF
}LF
```

- Plaintext: the portable key bundle, compact sorted JSON `{"key":"<b64 32 bytes>","salt":"<b64 32
  bytes>","schemaVersion":1,"scopeID":"sync-v1"}` (`LibraryKeyBootstrap.swift:36-74`). Material is 64 bytes: key then salt.
- Key: `HKDF-SHA256(ikm = 16-byte recovery secret, salt = "snippets-git-recovery-salt-v1", info = AAD, 32 bytes)` (`:114-120`).
- AAD: `"snippets-git-recovery-v1" NUL <uuid>` (`:110-112`).
- Recovery code: `RecoveryKey` format, 27 Crockford symbols shown `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX` (`:57-58`); input is normalized by
  `RecoveryKey.decode` (brief 02).
- Open (`:84-108`): at most 8,192 bytes; exactly four keys; version 1; algorithm string; dataset id equals the expected one; canonical
  base64 → else `invalidEnvelope`. GCM failure → `incorrectCode`. Bundle not strict → `invalidEnvelope`.

### 2.8 `keys/vault.json` (`GitSyncVault.swift`, mirror `git_vault.rs`)
Same four-key outer framing, with `"algorithm" : "snippets-git-vault-hkdf-sha256-aes256gcm-v1"` (`git_vault.rs:149-153`).

- Plaintext, compact sorted JSON (`git_vault.rs:92-103`):
  `{"kdf":{"alg":"…","iterations":N,"saltP":"…"},"kid":"…","schemaVersion":1,"vaultSalt":"…","wrapRecovery":"…"}`.
- Key: `HKDF-SHA256(ikm = material[0..32], salt = material[32..64], info = AAD, 32 bytes)` (`GitSyncVault.swift:196-203`). AAD:
  `"snippets-git-vault-v1" NUL <uuid>` (`:191-193`).
- Well-formedness, enforced on write and read (`:84-101`): `kid` token ≤ 128; `vaultSalt` base64url decoding to 32 bytes; `kdf.alg`
  token ≤ 64; `kdf.iterations` in 1...100,000,000; `kdf.saltP` token ≤ 128 and valid base64url; `wrapRecovery` token ≤ 1,024. A token is
  printable ASCII `0x21...0x7e` without `"` and `\`.
- Open (`:145-189`): probe `schemaVersion > 1` **before** the shape → `unsupportedVersion` (never replaced from this build). GCM failure
  → `incorrectKey`. Inner key sets must be exact.
- **[INV]** Never publish a passphrase wrap, `wrapCLI` or any `x` extension. The vault key is only ever wrapped under the recovery code
  (`KeyWrap`, purpose `recovery`), never under the library key.
- Known answer shared with Linux: `Tests/Core/GitSyncVaultTests.swift:146-175` (fixed key, salt, secret, nonces, expected code
  `M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ`, expected file text). Port it first.

### 2.9 Auxiliary path rule
`readFile`/`writeFiles`/`initializeRepository(files:)`/`replaceLibrary(files:)` accept only paths with 2 to 4 components, first
component `keys`, each component non-empty, not starting with `.`, at most 128 bytes, characters `[0-9A-Za-z-_.]`
(`GitSyncTransport.swift:437-452`). Anything else is `git_invalid_path`.

### 2.10 Tree objects
- Entry bytes: `<mode ASCII> SP <name bytes> NUL <20 raw id bytes>` (`GitObjects.swift:207-217`).
- Modes written: `40000` for trees, `100644` for blobs (`:133-134`). A parsed `040000` is still a tree (leading zeros ignored, `:158`);
  a regular file is `100644` or `100755` (`:159`). Symlinks and gitlinks are neither and are just preserved.
- Order: bytewise ascending on the name, with `/` appended to tree names (`:219-225`). Servers fsck this. Test vector: names `B`, `a-b`,
  `a.b`, tree `a` sort as `B, a-b, a.b, a` (`GitPrimitivesTests.swift:19-40`).
- Parse limits: mode at most 6 bytes of `[0-7]`, non-empty name without `/`, at most 1,000,000 entries (`:170-203`).
- Setting a path removes *every* existing entry with that name, whatever its type, then appends the new one
  (`GitSyncTransport.swift:465-467`, `:491-492`). `editTree` drops a directory that becomes empty (`:478`); `rewriteTree` never removes.

### 2.11 Commit objects (`GitObjects.swift:263-272`)

```text
tree <hex40>LF
parent <hex40>LF                      (absent for the creating commit; never more than one)
author Snippets Sync <sync@snippets.invalid> <unix seconds> +0000LF
committer Snippets Sync <sync@snippets.invalid> <unix seconds> +0000LF
LF
<message>LF
```

`<unix seconds>` = `floor(now)` clamped at 0. **[INV]** fixed authorship; never a device, account, path or other stable identifier in a
commit, file name or failure detail.

Messages (complete list):

| Message | Written by |
|---|---|
| `Create Snippets library` | `initializeRepository` `:234` |
| `Sync 1 record` / `Sync <n> records` (n = accepted results in the commit) | `plan` `:871`, `planPlain` `:1472` |
| `Replace recovery envelope` | `GitSyncSetup.issueRecoveryCode` `GitSyncSetup.swift:1214` |
| `Replace library keys` | `replaceLibrary` `:389` |
| `Normalize <n> file(s) edited outside Snippets` | `normalize` `:1362` |

Commit parsing reads only `tree` (exactly one) and `parent` headers up to the first empty line (`GitObjects.swift:235-259`).

### 2.12 Identities derived from the layout (all mirrored by Linux, `git_layout.rs:319-355`)

| Value | Definition | Swift |
|---|---|---|
| account identity | `SHA256("snippets-git-account-v1" LF canonicalIdentity LF refName)` | `GitSyncTransport.swift:1513-1516` |
| dataset identity | `SHA256("snippets-git-dataset-v1" LF canonicalIdentity LF refName LF <uuid>)` | `:1506-1511` |
| key-store account | `"git-library-v1-" + hex(first 16 bytes of SHA256("snippets-git-key-v1" LF canonicalIdentity LF refName LF <uuid>))` | `GitSyncKeyStore.swift:39-43` |
| local sync-state folder key | `hex(first 16 bytes of SHA256(join(NUL, ["snippets.sync.provider.v1","git",canonicalIdentity,refName,<uuid>])))` | `SyncBackendSelectionStore.swift:1592-1600` |
| cache scope | lowercase hex of the 32-byte account digest | `GitSyncTransport.swift:173-177` |
| cursor | `git1.<uuid>.<hex40>` | `:1773-1795` |
| record version | `git-blob-sha1:<hex40>`; Markdown: `git-md-blob-sha1:<hex40>` | `:1489-1497` |

---

## 3. Wire protocol actually used

### 3.1 Protocol version and framing
Protocol **v0/v1** only, over smart HTTP or SSH (`GitSmartHTTPClient.swift:293-295`). The client never sends a `Git-Protocol` header and
the SSH connector removes `GIT_PROTOCOL` from the environment (`GitSSHClient.swift:291`). Do not add v2: `git-receive-pack` has no v2
form.

pkt-line (`GitObjects.swift:278-351`): four lowercase hex digits = total length including the four; `0000` flush, `0001` delimiter,
`0002` response-end, `0003` invalid; max payload 65,516. The reader requires exactly four hex digits (a sign or space is rejected;
`Int(…, radix:)` would accept `-005`) and accepts upper-case hex. `text()` strips one trailing `LF`.

### 3.2 Discovery
HTTP: `GET <repo>/info/refs?service=git-upload-pack` or `…=git-receive-pack` (`GitSmartHTTPClient.swift:320-334`). Response
`Content-Type` (media type only) must be `application/x-<service>-advertisement`, otherwise `unsupportedServer("not_smart_http")` (dumb
HTTP, login page, proxy error).

Advertisement parsing (`:347-393`), shared with SSH:

- optional first packet `# service=<service>` followed by a flush (HTTP only); a mismatching service name is
  `protocolViolation("advertisement_header")`;
- then ref lines `<hex40> SP <name>` until a flush or end of data; the first line carries `NUL <capabilities separated by spaces>`;
  capability `k=v` is stored as key with value;
- `capabilities^{}` and any name ending `^{}` are skipped (so an empty repository has no refs);
- malformed line → `protocolViolation("advertisement_ref")`; trailing non-flush → `protocolViolation("advertisement_end")`.

Redirects (`:685-707`): followed only for `GET`, only to the same scheme, host and port (case-insensitive scheme/host). Otherwise the
redirect is **not followed** and the 3xx status surfaces as `protocolViolation("http_<status>")`. If discovery was redirected, later
POSTs go to the redirected base: final URL minus the `/info/refs` suffix and query (`serviceURL`, `:337-345`). Tests:
`GitSyncTransportTests.swift:73` and `:93` (cross-host redirect never sees `Authorization`).

### 3.3 HTTP request construction
Every request (`:597-607`):

| Header | Value |
|---|---|
| `Authorization` | `Basic base64(username ":" token)` (UTF-8, standard base64) |
| `User-Agent` | `git/2.0 (Snippets)` (`:308`); some hosts gate smart HTTP on a `git/` agent |
| `Pragma`, `Cache-Control` | `no-cache` |
| `Accept` | `*/*` (discovery); `application/x-git-upload-pack-result`; `application/x-git-receive-pack-result` |
| `Content-Type` | `application/x-git-upload-pack-request`; `application/x-git-receive-pack-request` |

Auth is **identical for every host**: HTTP Basic, sent pre-emptively on every request. The only per-host difference is the default user
name when the field is empty (`GitSyncSetup.swift:182-188`): `x-access-token` for `github.com` and `*.github.com`, `oauth2` for
`gitlab.com`, none elsewhere (Gitea/Forgejo/GitVerse need the account name → `invalidUsername`). Token guidance per host:
`GitSyncSetup.swift:93-106`. User name rule: 1 to 256 bytes, no `:`, no control characters; token: 1 to 4,096 bytes, no control
characters (`:226-234`).

Session (`GitSyncTransport.swift:182-193`): ephemeral; no cache, cookies or credential storage; request (idle) timeout 60 s;
whole-resource timeout 600 s; TLS 1.2 minimum.

Status mapping (`GitSmartHTTPClient.swift:637-678`):

| Status | Failure | Engine sees |
|---|---|---|
| 200 | body, streamed with the size limit enforced while it arrives | |
| 401, 403 | `authenticationRequired(status)` | `rejected(.authenticationRequired("git_http_401|403"))` |
| 404 | `repositoryNotFound` | `rejected(.authenticationRequired("git_repository_not_found"))` |
| 413 | `requestTooLarge` | `rejected(.permanent("git_push_too_large"))` |
| 429, 503 | `rateLimited(Retry-After seconds, default 30, clamped 1...3600)` | `rejected(.rateLimited)` |
| other 5xx | `serverError(status)` | `unreachable("git_http_<status>")` |
| anything else | `protocolViolation("http_<status>")` | `unreachable("git_protocol_http_<status>")` |
| transport error | `unreachable("network_<code>")` or `"network"`; cancellation stays cancellation | `unreachable("git_network…")` |

Size limits: 8 MiB for advertisements **and** push reports (`maximumAdvertisementBytes`, `:302`); packs 128 MiB on iOS, 512 MiB on macOS
(`:303-307`). Android should take the iOS numbers. Over the limit → `responseTooLarge` →
`rejected(.permanent("git_response_too_large"))`.

### 3.4 Fetch: `POST <serviceURL>/git-upload-pack` (`:399-446`)

```text
pkt("want <hex40> <caps>" LF)
[pkt("deepen 1" LF)]            only when haves is empty AND the server advertises "shallow"
0000
pkt("have <hex40>" LF) ...      one per held snapshot commit, plain haves
pkt("done" LF)
```

Capabilities requested, in this order, each only if advertised (except `agent`): `ofs-delta`, `no-progress`, `agent=snippets/1`, then
`side-band-64k` (else `side-band`), then `shallow` (only in the shallow case). Never `multi_ack`, never `thin-pack`.

- **Empty cache** → `deepen 1`: the tip only. History would only add superseded ciphertext.
- **Has snapshots** → `haves = cache.snapshotCommits` (retained then pinned, deduplicated, `GitObjectCache.swift:101-106`), no `deepen`,
  no `shallow`. **[INV]** incremental fetches send plain haves; declaring them shallow makes servers resend the whole snapshot
  (`GitSSHTests.swift:154`, `GitIncrementalFetchTests.swift:7`).

Response parsing (`extractPack`, `:448-490`):

1. If shallow was requested: read `shallow <id>` / `unshallow <id>` lines up to a flush. A first line that is neither rewinds (some
   servers omit the section). `ERR …` → `protocolViolation("upload_pack_error")`.
2. One `NAK` or `ACK <id>` line (else `protocolViolation("acknowledgement")`).
3. With side-band only: skip any further `NAK`/`ACK` lines (GitHub acknowledges every common have; `GitSSHTests.swift:135`).
4. No side-band: the pack is the raw remainder. Side-band: demultiplex until flush/end; band 1 data, band 2 ignored, band 3 →
   `protocolViolation("remote_error")`, other → `protocolViolation("side_band")` (`:493-514`).

Fallbacks (`GitSyncTransport.swift:929-965`): if the fetch with haves fails with `git_response_too_large`, or the pack parses but the
snapshot cannot be completed from pack plus cache (the server assumed history this device never kept), the fetch is repeated **once with
no haves**. A pack that does not parse is `unreachable("git_pack_invalid")`; an incomplete snapshot after the retry is
`unreachable("git_snapshot_incomplete")`.

### 3.5 Pack parsing (`GitPack.swift:147-309`)
- Header `PACK`, big-endian version 2 or 3, big-endian object count. Trailer: SHA-1 of everything before it; verified before any object
  is read.
- Entry header: first byte `1 TTT SSSS` (type 3 bits, size low 4 bits), continuation bytes add 7 bits each (shift guard `< 57`).
- Types 1 commit, 2 tree, 3 blob, 4 tag: one zlib stream that must inflate to exactly the declared size. Type 6 `OFS_DELTA`: offset
  varint with the `((d + 1) << 7) | low7` rule, base at `entryOffset − d`, must be ≥ 12 and name a real entry. Type 7 `REF_DELTA`:
  20-byte base id. Type 5 and 0 are invalid.
- A pack records no compressed lengths: the inflater must report exactly how many input bytes the stream consumed (`GitZlib.inflate`,
  `:35-66`). The output buffer is `size + 1` so a longer stream is an error, not a truncation.
- Delta format (`:70-123`): base-size varint must equal the base length; target-size varint bounded; copy opcode (`0x80` set) with up to
  4 offset and 3 size bytes selected by bits, size 0 means `0x10000`; insert opcode 1...127; opcode 0 invalid; result length must equal
  the target size.
- Resolution is breadth-first from whole objects, each delta applied once; reference deltas may name objects produced by other deltas;
  leftovers are resolved against `externalBase` (the cache) as a defensive fallback only. All entries must resolve (`unresolved_delta`).
- Limits (`:127-136`): 2,000,000 objects; 64 MiB per object; total inflated 384 MiB (iOS) or 1 GiB (macOS), counting delta results;
  delta depth 10,000. After the last entry the offset must equal the trailer start (`trailing_data`).
- The whole pack is held in memory.

### 3.6 Pack generation (`GitPack.swift:314-332`)
Version 2, **undeltified**, every object whole, zlib default level, SHA-1 trailer. Contents of a push: exactly the new blobs, every
rewritten tree on the path to the root, and the one commit. Nothing the server already has is sent. Pack bytes are not mirrored across
platforms (only object ids are), so the deflate output need not match Swift's.

### 3.7 Push: `POST <serviceURL>/git-receive-pack` (`:522-563`)

```text
pkt("<old hex40> <new hex40> <refName>" NUL "<caps>" LF)
0000
<pack bytes>                     (empty when new is all zeros: a delete, tests only)
```

Capabilities: `report-status`, `agent=snippets/1`, plus `side-band-64k` and `quiet` if advertised. A server without `report-status` →
`unsupportedServer("report_status")`; a delete without `delete-refs` → `unsupportedServer("delete_refs")`. Never `atomic`, never
`push-options`.

Report parsing (`:565-593`): demultiplex first if `side-band-64k` was used; first line must start with `unpack `; anything but `unpack
ok` → `protocolViolation("remote_unpack_failed")`; then `ok <refName>` → `.updated`, `ng <refName> <reason>` → `.rejected`; neither →
`protocolViolation("report_status")`. The reason text is discarded.

`.rejected` covers both a lost race and a refusal (protected branch, hook, permission). The caller tells them apart by re-reading the
head (§4.5).

### 3.8 "An idle round is one discovery request" **[INV]**
A sync round is `preflightScope()` then `fetchChanges(since:)`.

- `preflightScope` (`GitSyncTransport.swift:531-542`) does one upload-pack discovery, finds the head snapshot in the cache (no fetch),
  and remembers `(advertisement, operationSequence, now)`.
- `fetchChanges` calls `currentSnapshot(reusingPreflight: true)` (`:885-895`): the remembered advertisement is reused only if this is
  the **very next** serialized operation (`sequence == operationSequence − 1`) **and** it is younger than 3 s (`preflightReuseWindow`,
  `:151`). It is cleared on every use. Any push, another preflight or a later fetch asks again.
- Cursor commit equals head → empty result, no pack request (`:630-635`).

Guards: `GitIncrementalFetchTests.swift:45`, `GitSyncTransportTests.swift:552` (a bare fetch with an unchanged head is exactly `["GET
refs?git-upload-pack"]`).

### 3.9 Snapshot cache (`GitObjectCache.swift`)
- Directory layout: `<cache>/objects/<2 hex>/<38 hex>` and `<cache>/state.json`. Directories mode 0700, excluded from backup. Each
  object file is `"<type> <size>" NUL <content>`; it is re-hashed on every read and deleted on mismatch (`:64-79`). Writes are atomic.
- `state.json` (sorted keys): `{"pinned":[{commit,tree}],"retained":[{commit,tree}],"schemaVersion":1,"scope":"<hex>"}`. A file with
  another scope or schema empties the cache (`:48-54`).
- `retained`: the 4 most recently used complete snapshots (`maximumRetainedCommits`, `:17`). `pinned`: what the next fetch may diff
  against (the head the last fetch returned and the base it diffed from); replaced wholesale by each `pin`; never evicted by submit
  commits (`:116-125`).
- `prune` (`:162-188`) removes every object not reachable from a complete retained or pinned snapshot and drops incomplete entries.
- `install` (`GitSyncTransport.swift:970-1007`) walks commit → trees → blobs, requires every reachable tree and regular-file blob to be
  in the new objects or already cached, stores children before parents, then `retain`s. Returns false and stores nothing if anything is
  missing.
- **[INV]** Disposable: no credential, cursor or plaintext is ever stored there. (In a plain-text library the Markdown blobs are in the
  cache because the host holds them too.) A missing or corrupt object throws `missingObject`; `healingCache` empties the cache and runs
  the operation once more (`:1553-1560`).

### 3.10 SSH differences in the wire client (`GitSSHClient.swift:55-123`)
Same request bodies, same response parsers. Differences:

- The service speaks first. Each operation is one exec; `discover` answers the advertisement with a lone flush packet.
- `fetchPack`: if `want` is not among the live advertisement's ref values, send only a flush and fail `unreachable("ref_moved")`
  (retryable `git_ref_moved`).
- `push`: if the live head is not `old`, send only a flush and return `.rejected` **without uploading the pack**
  (`GitSSHTests.swift:248`).
- Capabilities are taken from the live advertisement of that exec, not from the one passed in.

---

## 4. Mapping to the sync engine

### 4.1 Transport properties
`identifier = "git"`, `supportsPush = true`, `pollInterval = 60` (`:112-114`), `events` is a finished stream (no push notifications).
Every public operation runs through `serialized` (`:1526-1548`): one at a time, counts `operationSequence`, fails with
`unreachable("git_transport_shut_down")` after `shutdown()`.

### 4.2 Scope
`preflightScope` returns `SyncScopePreflight(identity: accountIdentity, datasetIdentity:)` and pins the dataset id on first use
(`:537`). The four reset hooks call `adoptReviewedScope` (`:599-613`): identity mismatch → `accountChanged`; the cache is discarded for
the account, checkpoint and remote-reset reviews and kept for the local full resync; the dataset identity must match the expected one or
it throws `remoteDataReset("dataset_reset")`; then the new dataset is pinned.

Dataset checks on every head (`currentSnapshot` `:905-910`, `validateDataset` `:916-926`):

| Condition | Failure |
|---|---|
| manifest dataset ≠ `configuration.expectedDatasetID` | `rejected(.permanent("git_library_replaced"))` |
| manifest mode ≠ `configuration.expectedMode` | `rejected(.permanent("git_library_mode_changed"))` |
| manifest dataset ≠ the dataset pinned this session | `remoteDataReset("dataset_reset")` |
| branch absent | `rejected(.permanent("git_repository_not_initialized"))` |
| no manifest marker | `rejected(.permanent("git_branch_not_snippets_library"))` |
| unknown schema or profile | `rejected(.permanent("git_sync_schema_unsupported"))` |

**[INV]** Each device pins the mode the user agreed to. Never follow a changed mode silently, and never give an encrypted library's
transport the plain-text codec (`makeTransport` builds the codec only when the agreed mode is plain text,
`SyncBackendSelectionStore.swift:1420-1427`). A plain-text library reached without a codec is `git_key_required` (`:1133-1138`).

### 4.3 Fetch (encrypted mode, `:617-656`)
- Cursor parses, same dataset, commit == head → `records: []`, same cursor, pin head.
- Cursor parses, same dataset, base snapshot still cached → `changedRecords(base → head)`: for each fanout prefix whose tree id differs
  (sorted), every id in the old directory must still exist in the new one (else `remoteDataReset("git_record_removed")`); every id whose
  blob id differs is read and returned. Any number of commits in between collapses to one diff. Pin head and base.
- Otherwise (no cursor, other dataset, base no longer cached): all records of the head, `isFullResync: true`, `replacesPriorPages:
  cursor != nil`, `hasMore: false`.
- `cursorKind` is `.legacy`; next cursor is `git1.<dataset>.<head>`.

### 4.4 Unopenable records
A record file that fails `GitRecordFile.decode` is delivered as `WireRecord(id, rev: "git-unreadable-<blob hex>", deleted: false, blob:
empty, recordVersion)` so the engine quarantines that one snippet (`:1083-1096`). Same for an unreadable or too-new Markdown file, with
the Markdown version (`:1211-1216`). (Linux halts instead; Android follows Swift.)

### 4.5 Submit (`:658-789`)
- Empty batch → `rejected(.permanent("invalid_batch_size"))` before any request.
- Chunking (`:716-731`): at most 50 records and 24 MiB of blob bytes per commit (`maximumBatchRecords`, `maximumCommitBlobBytes`,
  `:106-110`).
- Per chunk, up to 5 attempts (`maximumPushAttempts`):
  1. discover receive-pack; branch absent → `git_repository_not_initialized`;
  2. if the head equals the head of the previous rejected attempt → `git_push_rejected` (permanent: the branch did not move, so it was
     not a race);
  3. snapshot of the head, dataset checks, `plan`;
  4. no commit needed → results with cursor at the head; else build pack and push;
  5. `.updated` → install the new snapshot locally (failure ignored), cursor at the new commit; `.rejected` → remember the head and
     loop.
  After 5 attempts → `rejected(.rateLimited(retryAfter: 5))`.
- `plan` (`:801-874`) applies records **in order**, each CAS-checked against the head plus the records accepted earlier in the same
  chunk:

| Case | Outcome |
|---|---|
| blob > 900,000 bytes, or rev not 1...256 bytes | `rejected(.permanent("record_too_large"))` for that record only |
| file exists and `record.recordVersion != git-blob-sha1:<current>` (including a blind create, `recordVersion == nil`) | `rejected(.conflict(remote: <the current record>))` |
| file absent and `record.recordVersion != nil` | throws `remoteDataReset("git_record_removed")` |
| otherwise | new blob; `accepted(rev, recordVersion: git-blob-sha1:<new>)` |

  If the root tree is unchanged (every accepted record already had identical bytes) no commit is made and the results stand (`:862-865`;
  test `:223`).
- HTTP 413 (`git_push_too_large`) halves the chunk; a single record that still does not fit is rejected alone with that code
  (`:682-693`).
- If a later chunk fails after earlier ones landed, the earlier acceptances are returned and the remaining records get a rejection: the
  failure's own rejection, or `rateLimited(5)` for unreachable/reset/account failures (`:694-707`, `:733-741`). A whole-call throw
  happens only when nothing was accepted yet.
- Returned cursor: the last commit written (or the head, for a no-op chunk).

### 4.6 Plain-text mode
`locations` (`:1176-1187`): every id's file; a record under `records/` wins over a Markdown file with the same id. `plainIndex`
(`:1142-1172`): several files declaring one id → the one whose name ends `-<id8>.md` owns it, else the first by name; every other copy
gets `derivedID(path)` if that id is free.

Fetch (`plainFetch`, `:1255-1330`):

- cursor at head and no pending hand deletions → empty;
- with a cached base: read every id whose blob changed; an id that vanished must have been a Markdown file (else `git_record_removed`)
  and becomes a derived tombstone: the deleted file's envelope `tombstoned(hlc: bumped, origin: "00000000")`, without the in-app
  deletion marker (`handDeletion`, `:1225-1246`);
- without a base: read everything, `isFullResync`;
- then one best-effort **normalize** commit (`:1335-1380`): rewrite hand-edited files with fresh `sync` metadata, and write tombstone
  record files for hand deletions (including earlier ones still pending in memory). It is skipped when the branch moved, the push is
  refused or the device cannot push; after an `authenticationRequired` failure normalizing pauses for 3,600 s. When it lands the
  returned cursor is the normalize commit and the affected records carry the new versions.
- records are sorted by uppercase uuid string.

Submit (`planPlain`, `:1386-1475`): same size and CAS rules with `version(of: location)`. Extra cases:

- edit naming a Markdown version whose file is gone → answer `conflict(remote: <derived tombstone>)`; with the deleted blob no longer
  cached the tombstone uses the lowest clock (`wallMs 0, counter 0`), so the edit wins; the deletion is queued for normalize. A vanished
  *ciphertext* version is still `git_record_removed`.
- A record that opens (with the library sealer), renders and has fields becomes Markdown; anything else is a record file. A record that
  changes kind moves between directories in the same commit (old path removed, new path set).
- File name: keep the existing name unless the snippet's `name` changed; if the record was under `records/` and a hand-restored Markdown
  file still claims the id (and no other id uses that path), overwrite that file; otherwise a new name with `-2`, `-3` suffixes against
  the names in use.

### 4.7 Setup-only operations

| Operation | Behaviour | Swift |
|---|---|---|
| `inspectRepository()` | upload-pack discovery; no ref → `.empty`; manifest → `.library(dataset, mode)`; `notALibrary` → `.foreign`; writes nothing | `:197-209` |
| `initializeRepository(datasetID, files, mode)` | up to 5 passes: discover receive-pack; branch exists → return **its** dataset id (adopt; foreign → `git_branch_not_snippets_library`); else push `0{40} → commit` with manifest, README and `keys/` files; `.updated` → return the given id; rejected and branch still absent → `git_push_rejected`; rejected and branch now exists → next pass adopts. Then `rateLimited(5)` | `:215-254` |
| `verifyWriteAccess()` | receive-pack discovery only; hosts authorize it only for writers | `:259-263` |
| `readFile("keys/…")` | blob at that path in the current head, nil if absent | `:267-287` |
| `writeFiles(files, message)` | CAS commit on the head replacing those `keys/` files; up to 5 attempts; same-head rejection → `git_push_rejected`; unchanged tree → no commit | `:291-328` |
| `replaceLibrary(current, with:, files, mode, expectedHead)` | below | `:346-408` |

`replaceLibrary` (key rotation) in order: discover receive-pack; head snapshot; head already holds the new dataset → success (idempotent
retry); head not `current` → `git_library_replaced`; mode differs → `git_library_mode_changed`; `expectedHead` given and ≠ head →
`unreachable("git_ref_moved")` and nothing written; then **one** commit: remove `records/`, remove `keys/`, in plain mode remove
`snippets/`, write the manifest (new dataset id, same mode, `schemaVersion` 2), the README and the given `keys/` files; foreign files
stay. On rejection: re-discover; head unchanged → `git_push_rejected`; moved → `git_ref_moved`. It is an ordinary fast-forward; history
is never rewritten.

### 4.8 Round pacing (confirmed constants)

| Constant | Value | Swift |
|---|---|---|
| `pollInterval` | 60 s | `GitSyncTransport.swift:114` |
| `localChangeDebounce` | 30 s after the last local change | `:121` |
| `localChangeMaximumWait` | 120 s after the first change of a burst | `:123` |
| `activationRefreshInterval` | 30 s after a successful round | `:126` |
| `preflightReuseWindow` | 3 s | `:151` |
| default debounce of other providers | 1 s | `SyncCoordinator.swift:234` |
| push attempts per chunk / setup write | 5, then `rateLimited(5 s)` | `:109` |
| normalize pause after auth failure | 3,600 s | `:1375` |

Coordinator rules (`SyncCoordinator.swift:557-570`, `:973-1001`): with a paced transport, a local change schedules the round with (30 s,
120 s); a poll or app activation is skipped while a paced change is waiting; an activation is also skipped within 30 s of the last
successful round; a waiting change is flushed when the app goes to the background (iOS: under a background task,
`snippets-ios/AppEnvironment.swift:257`) or quits (macOS, `AppDelegate.swift:646`, capped at 5 s by `pendingSyncQuitTimeout`, `:633`).
**[INV]** explicit actions (Sync Now, setup, recovery, provider switch) are never paced; other providers declare no pacing.

**[INV]** CPU-bound round work (projection, journal reconcile, base encoding) runs off the main thread; the transport itself is an
actor. On Android: a single-threaded coroutine context or a `Mutex` reproduces `serialized`.

### 4.9 Configuration persistence (app layer)
- Coordinates (non-secret preferences, `SyncBackendSelectionStore.swift:481-485`): `SnippetsGitSyncRepositoryURL` (the normalized
  `spec`), `SnippetsGitSyncBranch`, `SnippetsGitSyncUsername` (absent for SSH), `SnippetsGitSyncDatasetID` (lowercase),
  `SnippetsGitSyncMode` (the `recordProfile` string; absent → encrypted). Loading requires the stored repository text to re-parse to the
  identical `spec` (`:701-725`).
- Token (`:727-760`): device-only secret, service `com.khm.snippets.git-sync.credentials`, account `git-access-token-v1`, JSON
  `{schemaVersion:1, location:<exact spec>, username, token}`. It is returned only when `location` and `username` equal the current
  coordinates: a token is bound to the exact address (port included), not to the canonical identity. Configuring an SSH address deletes
  any stored token (`:787-790`).
- Library key (`GitSyncKeyStore.swift`): service `com.khm.snippets.git-sync`, account = key-store account (§2.12), JSON
  `{schemaVersion:1, location, refName, datasetID, material(64 bytes)}`; a record whose scope fields do not match the requested scope is
  `malformedRecord` (`:93-111`). **[INV]** `SyncKeyStore` never mints a key for Git; a missing key is `git_key_required`.
- One base/journal per library: the sync-state folder key of §2.12; the cache lives in its `GitCache/` sub-folder (`:1613-1621`).
- `Configuration ==` ignores `sshConnector`, `plainText` and `expectedMode` (`GitSyncTransport.swift:82-85`): do not use it to decide
  whether a transport must be rebuilt.

---

## 5. Setup and onboarding (`GitSyncSetup`)

### 5.1 Form validation (`validated`, `GitSyncSetup.swift:1434-1473`)
1. Trim; parse the location (§6.2); failure → `invalidURL`.
2. Branch trimmed and valid, else `invalidBranch`.
3. SSH: needs an SSH capability on this platform, else `sshUnavailable`; no user name, no token.
4. HTTPS: user name trimmed; empty → host default (§3.3); invalid → `invalidUsername`. Token trimmed; empty → the saved token, **only**
   if the saved coordinates have the identical location, branch and user name; still invalid → `missingToken`.

### 5.2 State machine

```text
inspect(form) ──► .empty ──► user picks mode ──► [plain: visibility check] ──► createLibrary ──► .created(code)
              ├─► .foreign ──► offer "Use Branch “snippets”" ──► inspect again
              └─► .library(dataset, keyAvailable, recoveryAvailable, mode)
                      ├─ plain-text consent if needed (needsPlainTextConsent)
                      ├─ "Reconnect and Merge" confirmation if it replaces the active library
                      ├─ keyAvailable ──► connect(form, dataset, mode)
                      └─ else recoveryAvailable? ──► prompt code ──► connect(form, dataset, code, mode)
then: save coordinates + token ──► (Git not active) Switch and Sync confirmation | (active) Sync Now
```

`inspect` (`:566-583`): `keyAvailable` = the key store holds this scope; `recoveryAvailable` = `keyAvailable || keys/recovery.json
exists`.

### 5.3 `createLibrary(form, mode, confirmedPrivate)` (`:589-659`) — exact order
1. Validate the form.
2. Plain text only: `visibility` (§5.6). Public → `publicRepository`; unknown and not confirmed → `visibilityUnknown`.
3. `requireReconnectable` (§5.5).
4. Mint: dataset id (random UUID), 64-byte material, recovery kit (16 random bytes).
5. Seal `keys/recovery.json`.
6. `prepareVault` (may prompt the device owner; a refusal leaves nothing behind): the device's existing vault, or a freshly minted one;
   its key wrapped under the kit secret; seal `keys/vault.json`.
7. **Install the library key in the key store** (failure → discard minted vault, `keyUnavailable`). **[INV]** the key exists before the
   creating push.
8. `initializeRepository(datasetID, files, mode)`.
   - On error, re-inspect: the library with our dataset id exists → treat as created; any other definite state → forget the key, discard
     the vault, rethrow; inspection itself failed → `creationUncertain(recoveryCode)` (keys kept, code shown with a warning).
9. Returned id ≠ ours (another device won the race) → forget the key, discard, `libraryExists`.
10. Adopt the vault document locally; **save coordinates and token** (§5.5). Failure → `createdButNotSaved(recoveryCode)`.
11. Return `.created(recoveryCode)`. **[INV]** coordinates and token are saved only after both the library and its key exist.

### 5.4 `connect(form, datasetID, recoveryCode?, mode)` (`:665-753`) — exact order
1. Validate; inspect again; the branch must hold exactly `datasetID` in exactly the agreed mode, else `libraryChanged`.
2. `requireReconnectable`; `verifyWriteAccess` (a read-only token fails here, not at first sync).
3. If a non-blank code was given: parse it → `invalidRecoveryCode` on a malformed code. The code is parsed even when the library key is
   already held, because its secret also opens the vault key.
4. No key in the store: code required (`recoveryCodeRequired`); read `keys/recovery.json` (`recoveryUnavailable` if absent or unusable);
   open → `incorrectRecoveryCode` on a wrong code. **Nothing is saved before this point.**
5. `replaced` = the scope of the library Git was actively syncing on this same endpoint and branch, if the dataset differs
   (`:1392-1397`).
6. Vault check before saving: read and open `keys/vault.json` with the library material. If readable: when `replaced != nil` and the
   device's vault needs re-sealing → `checkCanResealIntoLibraryVault`, else `checkCanJoinLibraryVault` (`differentVault(secureCount)`
   when the device's secure snippets belong to another vault in use). An absent, damaged or too-new file does not block ordinary
   snippets.
7. Install the recovered key.
8. Vault step: reseal into the library vault (one owner prompt) or `joinLibraryVault(identity, recoveryKey: kit.secret)`. If the code
   opens the library but not the wrap (`incorrectRecoveryCode` from the vault): join without the key; secure snippets then wait for Set
   Up Secure Snippets.
9. Save coordinates and token.
10. If `replaced`: forget the retired library key, **unless** the key store syncs between devices (`:759-762`). On Android the key store
    is device-only, so the retired key is always forgotten.

### 5.5 Guards on saving
- `requireReconnectable` (`:1346-1351`): while Git is the active provider, only the same endpoint (`sameEndpoint`, §6.2) and branch may
  be (re)connected; otherwise `otherLibraryActive(display)`.
- `save` (`:1409-1432`): re-checks the guard, then `configureGit` inside `withQuiescedCloudTransport` when Git is active. **[INV]**
  rewriting the active provider's coordinates must happen with sync quiesced. Mapping: unfinished provider switch pinning another
  location → `switchInProgress`; other store failures → `saveFailed`; coordinator busy → `busy`.
- `disconnect` (`:1330-1338`): removes coordinates and token only; refused while Git is active (`removeWhileActive`) or a switch is
  unfinished (`switchInProgress`). The library key stays.

### 5.6 Repository visibility (plain-text creation only, `:1512-1576`)
Anonymous `GET <base>/info/refs?service=git-upload-pack`, no credentials, cookies or cache, 10 s timeout, `User-Agent` as §3.3,
redirects only within the probed origin. 200 with `application/x-git-upload-pack-advertisement` → public; 401, 403, 404 → private;
anything else → unknown. An SSH address is probed only when it maps to a well-known forge: `github.com:22`, `ssh.github.com:22|443` →
`github.com`; `gitlab.com:22`, `altssh.gitlab.com:443` → `gitlab.com`; `codeberg.org:22`; `bitbucket.org:22`; base
`https://<forge>/<path without surrounding slashes>`.

### 5.7 Recovery code display rules
- Shown exactly once, large and monospaced; never stored; **[INV]** never logged (nor the token, nor the repository URL).
- iOS sheet (`GitSyncSettingsViewController.swift:1138-1312`): cannot be swiped away (`isModalInPresentation`), hides its content on
  `willResignActive` (app-switcher snapshot), Copy writes local-only with a 120 s expiry. Explanation text:
  `GitSyncSetup.swift:136-140`; copied text `:141`.
- Android equivalents: `FLAG_SECURE` on that screen; non-dismissible dialog/sheet; `ClipDescription.EXTRA_IS_SENSITIVE` on the clip and
  an explicit clear after 120 s (Android has no clipboard expiry API).
- The code is also surfaced by `createdButNotSaved`, `creationUncertain`, `rotatedButNotSaved`, `rotationUncertain`: the UI must show it
  before the error (`:791-798`, `:913-921`).

### 5.8 New Recovery Code (`replaceRecoveryCode` → `issueRecoveryCode`, `:1191-1265`)
1. `activeLibrary()`: saved coordinates, token (HTTPS), stored key, transport pinned to the dataset.
2. New kit; seal `keys/recovery.json` with the *existing* material.
3. `vaultForNewCode`: published vault too new → `vaultUnavailable`; published and readable → `joinLibraryVault(identity)` must yield
   `.ready` (else `vaultKeyUnavailable`); absent/damaged → publish the device's vault if it is ready, else leave `keys/vault.json` alone
   (unless minting). Then wrap the vault key under the new kit (this unlocks the vault: the owner check).
4. If nothing was unlocked (no vault wrapped, or it was minted here) and the owner was not asked yet → `authenticateOwner(reason)`.
   **[INV]** the owner check is made inside the operation; a screen never skips it from display state.
5. `writeFiles({recovery, vault?}, "Replace recovery envelope")`: both envelopes in one commit or neither **[INV]**.
6. Lost response: read `keys/recovery.json` back; if the new kit opens it, return the code. Discard a minted vault key only when the
   repository proves the write did not land.

`setUpSecureSnippets` (`:1112-1157`): published vault → join with the stored key or the entered code (`recoveryCodeRequired` until
`.ready`); no published vault and no local vault → requires Git to be the active provider, runs a sync round **at that moment**, fails
`vaultHeldElsewhere` if sync is waiting for a vault and `syncBeforeSecureSetup` unless the round ended idle with a last-sync date, then
asks the owner and issues a code while minting a vault. **[INV]** nothing mints a vault while Git is the provider except these paths
(`SecureSnippetStore.swift:584`, `:685`: `libraryVaultSetupRequired`).

### 5.9 Replace Keys (`rotateKeys` → `replaceKeys`, `:795-1031`)
Preconditions: Git is the active provider (`syncBeforeRotation`); no unfinished provider switch (`switchInProgress`); sync not waiting
for a vault (`pendingSecureConflicts` / `vaultKeyUnavailable` / `vaultHeldElsewhere`, `:952-964`); published vault not too new.

1. Mint dataset id, material, kit; seal the new recovery envelope.
2. `prepareVaultRotation(wrappingUnder: kit.secret)`: unlocks the vault (owner prompt), opens every secure snippet once, mints the new
   vault key. If it did not authenticate the owner → `authenticateOwner`.
3. Seal the new vault file; **install the new library key** (before any push).
4. Up to 3 attempts: `requestSync(.manual)` must end `.completed(.idle)`; then, with sync quiesced:
   - read the engine's base cursor; its commit is `expectedHead` (`GitSyncTransport.commit(of:)`, `:425`); re-check the vault
     (`checkVaultRotation`);
   - `transport.replaceLibrary(old, with: new, files, mode, expectedHead)`;
   - on error inspect: new dataset there → continue as success; old dataset there → `git_ref_moved` means retry the loop, anything else
     gives up the new keys; another state → `libraryChanged`; cannot inspect → `rotationUncertain(code)` (keys kept);
   - commit the vault rotation locally (one write re-sealing every record) and `configureGit` with the new dataset → failure is
     `rotatedButNotSaved(code)`;
   - forget the retired key (unless the store syncs between devices).
5. Diagnostics: one `git_key_rotation` event with outcome `replaced | not_replaced | replaced_not_saved | uncertain` and a closed reason
   (`Diagnostics.swift:257-284`).

Other devices stop with `git_library_replaced`; reconnecting (`connect` with the new code) re-seals their secure snippets. **[INV]**
re-seal only when a device follows the library Git was syncing to its replacement; never delete a retired key from a synchronizable
store.

### 5.10 Failure codes
Transport details (closed list; the engine and status line see these):

| Detail | Class | Meaning / handling |
|---|---|---|
| `git_http_401`, `git_http_403` | authenticationRequired | token missing, expired or read-only; enter a new token |
| `git_repository_not_found` | authenticationRequired | wrong address or the credential cannot see it |
| `git_ssh_host_key_unknown`, `git_ssh_host_key_changed` | authenticationRequired | confirm the fingerprint in Settings |
| `git_ssh_permission_denied` | authenticationRequired | device key not accepted or read-only |
| `git_credential_required` | needsAuthentication (coordinator) | token missing on this device |
| `git_key_required` | needsAttention (coordinator) / permanent (plain codec missing) | enter the recovery code; Reconnect |
| `git_configuration_required` | needsAttention | no repository connected |
| `git_repository_not_initialized` | permanent | branch absent; Reconnect |
| `git_branch_not_snippets_library` | permanent | foreign branch, never touched |
| `git_sync_schema_unsupported` | permanent | newer build wrote it; update |
| `git_library_replaced` | permanent | other library on the branch; Reconnect with the newest code |
| `git_library_mode_changed` | permanent | mode differs from the agreed one; Reconnect to review |
| `git_push_rejected` | permanent | refused without the branch moving |
| `git_push_too_large` | permanent (per chunk/record) | HTTP 413 |
| `git_response_too_large` | permanent | over the response limit |
| `git_invalid_path` | permanent | programming error |
| `git_record_malformed` | permanent | only if it escapes the quarantine path |
| `record_too_large`, `invalid_batch_size` | permanent | per record / empty batch |
| `git_unsupported_not_smart_http`, `…_object_format`, `…_report_status`, `…_delete_refs` | permanent | server lacks a capability |
| `git_unsupported_ssh`, `…_ssh_unavailable`, `…_ssh_algorithms`, `…_ssh_handshake`, `…_ssh_no_git`, `…_ssh_exec` | permanent | SSH not usable; use HTTPS |
| `dataset_reset`, `git_record_removed` | remoteDataReset | reviewed reset |
| `git_protocol_*`, `git_pack_invalid`, `git_snapshot_incomplete`, `git_format_{object,pack,pkt_line,delta,limit,zlib}`, `git_http_5xx`, `git_network*`, `git_ssh_connection`, `git_ssh_timeout`, `git_ssh_failed`, `git_ssh_remote_failed`, `git_ssh_remote_temporary`, `git_ssh_channel`, `git_ssh_device_key_unavailable`, `git_ref_moved`, `git_local_storage`, `git_transport_shut_down` | unreachable | retryable with backoff |

Mapping source: `GitSyncTransport.swift:1797-1840`, `:1585-1599`, `:1541-1547`. User-facing status texts:
`SyncCoordinator.swift:2066-2143`.

Setup failures (`GitSyncSetup.Failure`, `:249-331`; messages `:341-442`; mapping from transport failures `:1602-1635`): `invalidURL`,
`sshUnavailable`, `sshHostKeyUnknown(host)`, `sshHostKeyChanged(host)`, `sshPermissionDenied(host)`, `sshIncompatible(host)`,
`sshNoGit(host)`, `invalidBranch`, `invalidUsername`, `missingToken`, `foreignBranch`, `publicRepository`, `visibilityUnknown`,
`notALibrary`, `libraryExists(datasetID)`, `libraryChanged`, `recoveryCodeRequired`, `invalidRecoveryCode`, `incorrectRecoveryCode`,
`recoveryUnavailable`, `keyUnavailable`, `notConfigured`, `authentication`, `repositoryNotFound`, `unsupportedServer`, `unreachable`,
`rateLimited`, `pushRejected`, `refused`, `createdButNotSaved(code)`, `creationUncertain(code)`, `pushTooLarge`,
`otherLibraryActive(location)`, `busy`, `switchInProgress`, `saveFailed`, `removeWhileActive`, `differentVault(secureCount)`,
`vaultKeyUnavailable`, `vaultAuthentication`, `vaultUnavailable`, `localVaultUnreadable`, `incorrectVaultRecoveryCode`,
`vaultHeldElsewhere`, `syncBeforeSecureSetup`, `syncBeforeRotation`, `pendingSecureConflicts`, `rotatedButNotSaved(code)`,
`rotationUncertain(code)`.

Port the message strings from `GitSyncSetup` as one shared table (the Mac/iOS strings differ only in `click`/`tap` and the SSH wording,
`:471-509`); Android takes the iOS variants with its own device noun. `needsReconnect` (`:1055-1063`): no key for the saved scope, or
the active state is needs-attention with one of `git_library_replaced`, `git_repository_not_initialized`, `git_library_mode_changed`,
`git_key_required`. `connectedSummary`: `:1067-1090`.

---

## 6. SSH

### 6.1 What the transport needs from a connector (`GitSSHClient.swift:36-43`)

```text
exchange(command, location, maximumBytes, request: (advertisementBytes) -> ByteArray?) -> (advertisement, response)
```

- `command` is exactly what git runs: `git-upload-pack '<path>'` or `git-receive-pack '<path>'`, single quotes, no escaping (the path
  character set was validated). For an `ssh://` location whose path starts with `/~`, the leading `/` is dropped (`:68-73`).
- One exec channel per exchange. No pty, no agent or X11 forwarding, **no environment request** (`GIT_PROTOCOL` must not be sent).
- Framing: read stdout until the first top-level flush packet (`advertisementEnd`, `:127-141`); call `request` once with those bytes;
  write its result, or a lone `0000` when it returns nil or throws; **send EOF** on the channel input; keep reading stdout to EOF;
  collect the exit status.
- Writing must not block reading (a large pack is written while the server may already be talking).
- Limits: advertisement at most 8 MiB before its flush; total stdout at most `maximumBytes + 8 MiB`; stderr capped at 65,536 bytes and
  never returned or logged.
- Success requires a complete advertisement and exit status 0. Otherwise classify with `GitSSHDiagnosis` (`:150-193`): exit 255 is the
  SSH client's own failure (macOS system ssh only); any other status is the remote git's. Remote-side rules Android needs: text
  containing `temporarily`, `try again later`, `maintenance` → `unreachable("ssh_remote_temporary")`; exit 127 with `not found` →
  `unsupportedServer("ssh_no_git")`; `repository not found`, `does not appear to be a git repository`, `could not be found`, `not a git
  repository`, `project not found` → `repositoryNotFound`; `permission denied`, `not allowed to push`, `denied to deploy key`, `you are
  not allowed`, `access denied`, `write access`, `marked as read only`, `read-only key`, `deploy key is read` → `sshPermissionDenied`;
  else `unreachable("ssh_remote_failed")`. Matching is on lowercased text.
- No exit status and empty stderr → the connection died: `unreachable("ssh_connection")` (`GitNIOSSHConnector.swift:581-583`).
- Timeouts (iOS connector): TCP connect 20 s (`:169`); handshake and authentication 30 s (`:192`); exec channel must open within 15 s or
  the connection is retired and the exchange retried once on a fresh connection (`:246-251`, `:42-55`); an exchange fails only after 120
  s **without progress** (bytes read, or the send window reopening), checked every 5 s (`:233-242`); pooled connection per
  `user@hostID`, closed 90 s after its last exchange (`:26`, `:316-321`).
- Cancellation must surface as cancellation, not as a network failure.

### 6.2 Locations (`GitSmartHTTPClient.swift:10-130`, mirror `git_location.rs`)
Parsing, after trimming; any character ≤ `0x20` or `0x7f` anywhere → invalid:

1. Starts with `ssh://` or `git+ssh://` (case-insensitive): URL with host, optional user, optional port, no password, no query, no
   fragment; path percent-decoded once and must start with `/`; brackets around an IPv6 host removed; `scpStyle = false`.
2. Contains `://`: HTTPS normalization (`:202-224`): scheme and host lowercased; no user, password, query or fragment; trailing slashes
   removed; non-empty path; scheme `https`, or `http` only when the loopback flag is set **and** the host is loopback (§7.3).
3. scp-like: the first `:` occurs before any `/` → `[user@]host:path` (user = text before the **last** `@` of the destination), no port,
   `scpStyle = true`.
4. Otherwise prefix `https://` and normalize.

SSH value rules (`:20-40`): user (optional) non-empty `[A-Za-z0-9._-]`, not starting with `-`; host non-empty `[A-Za-z0-9._:-]`, not
starting with `-` or `.`; port 1...65535; path 1...1024 bytes, not starting with `-`, every scalar `> 0x20` and `≠ 0x7f`, none of `' \ "
` $ ; & | < > ( ) { } * ? [ ] ! # %`, and no `..` segment. `%` is refused because the saved address would decode differently.

`spec` (saved and displayed form, `:45-50`): scp-like `user@host:path`; otherwise `ssh://[user@]host[:port]path` with an IPv6 host in
brackets; HTTPS: the normalized URL.

`canonicalIdentity` (`:71-86`) **[INV]** shared with Linux: lowercase host; path (HTTPS: the percent-decoded URL path); strip all
leading `/`; strip one trailing `.git`; strip all trailing `/`; result `host/path`. No scheme, user or port. Vectors:
`GitSSHTests.swift:6-23`, `git_tests.rs` identity vectors.

`sameEndpoint` (`GitSyncSetup.swift:1357-1367`): equal canonical identity, and SSH↔SSH also equal user (nil = empty) and port (default
22); HTTPS↔HTTPS also equal port (default 443); mixed → true.

### 6.3 iOS model (the behaviour Android copies)
- **Device key** (`GitSSHSupport.swift:143-262`): one ECDSA P-256 key per device, created on first use; Secure Enclave when available,
  else a software key in the device-only Keychain; usable after first unlock; never synced. Stored record: service
  `com.khm.snippets.git-ssh`, account `git-ssh-device-key-v1`, JSON `{schemaVersion:1, kind:"secure-enclave"|"software", key}`. An
  unreadable stored key is an error, never silently replaced (`GitSSHSupportTests.swift:95`).
- **Public key display** (`:201-221`): `ecdsa-sha2-nistp256 <base64> <comment>` where the blob is `string("ecdsa-sha2-nistp256") ‖
  string("nistp256") ‖ string(0x04 ‖ X(32) ‖ Y(32))`, each `string` = 4-byte big-endian length + bytes; standard base64 with padding.
  Comment `snippets-iphone` or `snippets-ipad` (`AppEnvironment.swift:307-309`). Shown on one line with Copy and Share; for
  GitHub/GitLab a deploy-key link (`GitSyncSetup.swift:171-178`).
- **User name** for authentication: the location's user, default `git` (`GitNIOSSHConnector.swift:166`). One public-key offer; a refusal
  fails immediately with `sshPermissionDenied` instead of waiting for the server's login grace time (`:412-427`).
- **Host-key store** (`GitSSHSupport.swift:37-133`): preferences key `SnippetsGitSSHTrustedHostKeys`, a map `hostID → "<key type>
  <base64 blob>"` (no comment). `hostID` = lowercase host, or `[host]:port` when the port is not 22 (`:82-86`). `check(hostID, key)`:
  equal to the trusted entry → trusted; no entry → unknown; different → changed. An untrusted key is remembered in memory as "presented"
  so Settings can show it.
- **Fingerprint** (`:88-93`): `"SHA256:" + base64(SHA256(key blob))` with `=` padding removed, exactly what `ssh-keygen -lf` prints
  (`GitSSHSupportTests.swift:30`).
- **Trust flow** (`GitSyncSettingsViewController.swift:673-740`): the first connection fails with
  `sshHostKeyUnknown`/`sshHostKeyChanged`; the screen shows the presented fingerprint; on confirm, `trustPresentedKey(location,
  fingerprint)` stores exactly the presented key (only if the fingerprint still matches) and the same steps run again (at most 3
  passes). A changed key gets a destructive "Trust New Key" prompt. **[INV]** a changed key is never accepted silently; the user always
  confirms.
- **Published fingerprints** (`GitSSHSupport.swift:51-72`), matched only for port 22 (or no port) and the exact lowercase host; a match
  changes the prompt text to "matches the one <Name> publishes", nothing else:

| Host | Name | Fingerprints |
|---|---|---|
| `github.com` | GitHub | `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`, `SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM`, `SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s` |
| `gitlab.com` | GitLab | `SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8`, `SHA256:HbW3g8zUjNSksFbqTiUWPWg2Bq1x8xdGUrliXFzSnUw`, `SHA256:ROQFvPThGrW4RuWLoL9tq9I9zJ42fK4XywyRtbOz/EQ` |
| `codeberg.org` | Codeberg | `SHA256:mIlxA9k46MmM6qdJOdMnAQpzGxF4WIVVL+fj+wZbw0g`, `SHA256:T9FYDEHELhVkulEKKwge5aVhVTbqCW0MIRwAfpARs/E`, `SHA256:6QQmYi4ppFS4/+zSZ5S4IU+4sa6rwvQ4PbhCtPEBekQ` |
| `bitbucket.org` | Bitbucket | `SHA256:ybgmFkzwOSotHTHLJgHO0QN8L0xErw6vd0VhFA9m3SM`, `SHA256:FC73VB6C4OQLSCrjEayhMp9UMxS97caD/Yyi2bhW/J0`, `SHA256:46OSHA1Rmj8E8ERTC6xkNcmGOw9oFxYr0WF6zWW8l1E` |

  **[INV]** update this table only from the host's documentation, checked against a live scan.
- Handshake failure with no better reason → `unsupportedServer("ssh_handshake")` (`GitNIOSSHConnector.swift:446-451`); exec refused →
  `unsupportedServer("ssh_exec")`.

### 6.4 Android proposal
**Key.** Android Keystore EC key, alias `git-ssh-device-key-v1`: `KeyPairGenerator("EC", "AndroidKeyStore")`,
`KeyGenParameterSpec(alias, PURPOSE_SIGN)` with `secp256r1`, `DIGEST_SHA256`, no user-authentication requirement (background sync must
sign; this matches iOS "usable after first unlock"), StrongBox requested and silently retried without it on
`StrongBoxUnavailableException`. The private key is non-exportable and is not part of any backup, so a restored device gets a new key
(matches "never synced"). JVM unit tests need a software signer, so define the seam in `:core`:

```kotlin
interface GitSshSigner {
    val publicKeyBlob: ByteArray                 // string(alg) ‖ string("nistp256") ‖ string(Q)
    fun sign(data: ByteArray): ByteArray         // DER ECDSA-Sig-Value over SHA-256(data)
}
```

SSH signature blob = `string("ecdsa-sha2-nistp256") ‖ string(mpint(r) ‖ mpint(s))`: the DER `SEQUENCE{INTEGER r, INTEGER s}` from
`Signature("SHA256withECDSA")` must be re-encoded as two mpints (big-endian two's complement, minimal, a leading `0x00` when the top bit
is set). `Q` must be built from `ECPublicKey.w` with both coordinates left-padded to 32 bytes.

**Library candidates** (facts marked ✔ were checked against the projects' sources or documents on 2026-11-25; others are from memory and
must be re-checked when pinning a version):

| | mwiede/jsch | Apache MINA SSHD | hierynomus/sshj |
|---|---|---|---|
| External signer | ✔ `Identity` interface: `getPublicKeyBlob()`, `getSignature(data, alg)`, `getAlgName()`; the library never sees a private key. ✔ `getSignature` returns the complete signature blob (`KeyPairECDSA` builds `[alg name, signature]`) | `KeyPair`-based identities; signing goes through JCA `Signature`, so a Keystore `PrivateKey` handle may work if no provider is forced; a custom agent (`SshAgent.sign`) is the clean seam | `KeyProvider` returns a JCA `PrivateKey`; works with Keystore handles only if no provider (BouncyCastle) is forced for `Signature`; release notes mention Android Keystore compatibility work |
| Host-key callback with raw key | ✔ `HostKeyRepository.check(host, byte[] key)` gets the wire blob; ✔ host is passed as `[host]:port` for a non-22 port (same as `hostID`); ✔ typed `JSchUnknownHostKeyException` / `JSchChangedHostKeyException` with `StrictHostKeyChecking=yes` | `ServerKeyVerifier.verifyServerKey(session, address, PublicKey)`: a JCA key that must be re-encoded | `HostKeyVerifier.verify(host, port, PublicKey)`: re-encode needed |
| Exec streaming | ✔ `ChannelExec` streams; ✔ closing the channel's output stream sends `SSH_MSG_CHANNEL_EOF` and leaves the channel open; `getExtInputStream()` for stderr; `getExitStatus()` | `ChannelExec` with inverted streams | `Session.exec` → `Command` streams, exit status |
| Android API 28 | ✔ Java 8 baseline, no mandatory dependencies. ✔ `ssh-ed25519` host keys need Java 15 or BouncyCastle; `curve25519-sha256` needs Java 11 or BouncyCastle; `chacha20-poly1305` needs BouncyCastle. Without BouncyCastle: `ecdh-sha2-nistp*` kex, `ecdsa-sha2-*` / `rsa-sha2-*` host keys, AES-CTR/GCM | ✔ project documents Android as unverified: "has not checked the compatibility and usability of the libraries for the Android O/S"; needs explicit home/user/cwd resolvers; NIO2 async sockets; slf4j | Java 8 minimum; slf4j 2 mandatory; BouncyCastle optional since 0.39 but needed for curve25519/ed25519 |
| Licence | BSD-3-Clause | Apache-2.0 | Apache-2.0 |
| Size (rough, before R8) | about 0.6 MB, one jar | about 2 MB+ (`sshd-common` + `sshd-core`) plus slf4j | under 1 MB plus slf4j; plus about 8 MB if BouncyCastle is added |

**Recommendation: `com.github.mwiede:jsch`.** It is the only candidate whose signing seam is an interface taking the bytes to sign (so
the Keystore key never has to be presented as a library-compatible `PrivateKey`), it hands the verification callback the raw host-key
blob that the SHA-256 fingerprint is defined over, its host identifier is already the `known_hosts` form the iOS store uses, it has no
mandatory dependencies and a Java 8 baseline, and its blocking stream model maps directly onto the connector contract (reader on one
coroutine, writer on another). MINA is the most capable but is the largest, async, and explicitly unverified on Android by its own
project. sshj is comparable in size to JSch but forces slf4j and routes signing through its provider selection.

Design notes for the JSch connector:

- `StrictHostKeyChecking=yes`, `PreferredAuthentications=publickey`, no `UserInfo`, no known-hosts file, a custom `HostKeyRepository`
  backed by `GitSshHostKeyStore`. Its `check` must lowercase the host, record the presented key on `NOT_INCLUDED`/`CHANGED`, and map the
  two typed exceptions to `sshHostKeyUnknown` / `sshHostKeyChanged`.
- JSch reorders its host-key algorithm preference from `HostKeyRepository.getHostKey(host, null)`. Return the trusted entry there, so a
  server with several key types keeps presenting the type that was trusted. Otherwise a library or provider change could surface a
  different key type and look like a changed key.
- Decide deliberately whether to bundle BouncyCastle: without it a server that offers **only** an Ed25519 host key, or only curve25519
  kex, cannot be used and must map to `git_unsupported_ssh_algorithms` (JSch `JSchAlgoNegoFailException`). GitHub, GitLab, Codeberg and
  Bitbucket all offer ECDSA or RSA host keys and NIST ECDH. iOS has the mirror-image limitation (no RSA host keys).
- "Auth fail" → `sshPermissionDenied`. Offer exactly one identity.
- Reproduce the timeouts of §6.1 with a watchdog over a "last progress" timestamp, not with a socket read timeout alone (a long upload
  makes no reads).
- Pool one `Session` per `user@hostID`; one `ChannelExec` per exchange; close the session 90 s after its last exchange; on "channel
  open" failure retire the session and retry once.
- Keep R8 rules for JSch's reflective optional classes (JNA, junixsocket, GSS, loggers).

### 6.5 Android storage for SSH

| iOS | Android |
|---|---|
| Keychain record with enclave handle | Keystore alias `git-ssh-device-key-v1` (no record needed); `hasKey` = alias exists |
| `SnippetsGitSSHTrustedHostKeys` in UserDefaults | a non-secret preferences file; same map, same `hostID`, same value format |
| comment `snippets-iphone` / `snippets-ipad` | proposal: `snippets-android` (open question) |

---

## 7. Test seams

### 7.1 Real `git http-backend`
Swift runs the CGI in-process through a `URLProtocol` (`GitTestServer.swift:8-189`); the integration script runs it behind a loopback
HTTP server (`scripts/git-http-test-server.py`). A Kotlin/JVM harness on macOS needs:

- binary `/usr/bin/git`, arguments `http-backend`;
- environment (nothing inherited): `GIT_PROJECT_ROOT=<dir containing repo.git>`, `GIT_HTTP_EXPORT_ALL=1`, `PATH_INFO=<URL path>`,
  `QUERY_STRING=<query or empty>`, `REQUEST_METHOD`, `REMOTE_USER=<user>` (required: http-backend enables receive-pack only for an
  authenticated user), `REMOTE_ADDR=127.0.0.1`, `CONTENT_TYPE` (if sent), `CONTENT_LENGTH` (POST), `HOME=<scratch>`,
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`, and
  `DEVELOPER_DIR` passed through when set (`:290-302`, `:147-158`);
- request body on stdin; stdout = CGI headers, blank line (`\r\n\r\n` or `\n\n`), body; a `Status:` header carries the status, default
  200 (`:172-187`);
- the harness itself checks `Authorization` against the expected Basic value and answers 401 before running the CGI (`:120-125`);
- hooks the Swift tests rely on: a request log of `"<METHOD> <last path component>[?<service>]"` (`:110-111`), a one-shot
  `beforeNextReceivePack` callback to stage a lost race (`:112-115`), a redirect rule (`:82-96`), and the list of `Authorization`
  headers seen (`:86-87`);
- fixture: `git init --bare --quiet --initial-branch=main`, and "another writer" via clone, edit, `commit`, `push` with `-c
  user.name=Other -c user.email=other@example.invalid -c commit.gpgsign=false` (`:249-262`).

Recommended shape: put the HTTP engine behind an interface in `:core`, test the transport against a `com.sun.net.httpserver.HttpServer`
on `127.0.0.1` that shells out to the CGI (this exercises the real HTTP engine, redirects and size limits), and keep a direct in-process
fake for the redirect and header tests. For emulator tests use `adb reverse tcp:<port> tcp:<port>` so the device reaches the host server
as `127.0.0.1` (the loopback rule does not admit `10.0.2.2`).

### 7.2 SSH
- Fake ssh (`GitTestServer.swift:318-343`): a shell script that runs the last argument with `/bin/sh -c` in the fixture root with
  `HOME=$PWD PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null`, logs its arguments, can fail with a scripted status
  and stderr, and can leave a lingering child. For Kotlin: a `GitSshConnector` test double that spawns `/bin/sh -c "<command>"` with
  `ProcessBuilder` and implements the §6.1 framing. It covers `GitSshClient`, the stale-push rule, `GitSshDiagnosis` and SSH+HTTPS
  devices sharing a library.
- Real loopback `sshd` (`:377-553`): unprivileged, `ListenAddress 127.0.0.1`, throwaway host key, `AuthorizedKeysFile` with `restrict
  <key>`, `PasswordAuthentication no`, `UsePAM no`, `StrictModes no`. For the JSch connector test: authorize a software P-256 key
  generated in the test (through the `GitSshSigner` seam) and give the fixture an **ECDSA** host key unless BouncyCastle is on the test
  classpath.
- **[INV]** SSH tests never reach the user's real agent, keys, config or `known_hosts`. With a library-based client this holds by
  construction; keep any spawned `ssh`/`sshd`/`ssh-agent` pinned to private files and a short socket path.

### 7.3 Loopback `http://` rule **[INV]**
Plain `http://` is a test seam: loopback hosts only (`localhost`, `127.0.0.1`, `::1`, `*.localhost`;
`GitSmartHTTPClient.swift:210-213`), DEBUG builds only, and only behind an explicit flag: `SNIPPETS_GIT_ALLOW_LOOPBACK_HTTP=1`
(`AppDelegate.swift:178-184`) or the iOS `--ui-testing-reset` launch, whose launches also keep Git keys and tokens in memory and reset
the Git preferences (`snippets-ios/AppEnvironment.swift:88-110`). Linux is stricter (literal loopback IPs only,
`git_location.rs:335-339`). Android: a `BuildConfig.DEBUG`-guarded flag passed by the instrumentation runner; release builds must
compile the HTTP branch out of reach, and the release network-security configuration must not permit cleartext.

---

## 8. Porting hazards, tests, decomposition, open questions

### 8.1 Hazards
1. **Foundation pretty JSON** (`GitSyncTransport.swift:1707`, `GitSyncRecovery.swift:75`, `GitSyncVault.swift:135`): `"key" : value`
   with spaces around the colon, two-space indent, sorted keys, `/` unescaped, trailing `LF`. No Kotlin JSON library prints this by
   default. Write the three files with string templates, as Rust does (`git_layout.rs:101`).
2. **Strict UUID** (`GitSyncTransport.swift:1667`, `:1728`, `:1786`): `java.util.UUID.fromString` accepts short groups. Write an
   8-4-4-4-12 parser (`git_plain.rs:629-637`) and always compare the lowercase re-encoding with the input.
3. **Canonical base64** (`:1763-1764`): Java's decoder accepts missing padding and stray trailing bits. Always re-encode and compare.
   The `sync` line is the opposite: deliberately lenient (`GitPlainText.swift:444-448`, `git_plain.rs:640-653`).
4. **Exact inflate consumption** (`GitPack.swift:35-66`): with `java.util.zip.Inflater`, feed the remaining pack bytes and compute
   consumed = given − `getRemaining()` after `finished()`. Do not wrap in `InflaterInputStream` (it over-reads). Enforce the `size + 1`
   rule.
5. **Tree order and raw names** (`GitObjects.swift:219-225`): compare unsigned bytes with `/` appended for trees; Kotlin `Byte` is
   signed. Keep names and modes as byte arrays end to end.
6. **Removing same-named entries of any type** when setting a path (`GitSyncTransport.swift:465-467`, `:491-492`, `:855`, `:859`).
7. **`git_push_rejected` vs race** depends on comparing the head of consecutive attempts (`:766-768`, `:301-303`). Do not "simplify"
   into a retry counter.
8. **`remoteDataReset` vs conflict** (`:832-835`, `:1408-1417`): a vanished ciphertext version is a reset; a vanished Markdown version
   is a conflict. The decision uses the version's prefix, never the cache.
9. **Preflight reuse** (`:885-895`): sequence adjacency **and** 3 s. A push between preflight and fetch must not be hidden
   (`GitIncrementalFetchTests.swift:58-62`).
10. **Stale upload-pack advertisement** (`:931-937`): `snapshot(at:)` reuses the last upload-pack advertisement for capabilities and
    `serviceURL` even on submit paths. Harmless over HTTP if the redirect base is stable; keep the same behaviour rather than adding
    requests (cost invariant).
11. **Shallow section rewind** (`GitSmartHTTPClient.swift:452-468`) and **extra ACK skipping only with side-band** (`:480-487`).
12. **Report-status over side-band**: demultiplex first, then parse pkt-lines inside (`:565-571`).
13. **HTTP client behaviour**: disable automatic redirects and implement §3.2 by hand; never let the client retry a POST; with
    `HttpURLConnection` in fixed-length streaming mode a 401 throws `HttpRetryException` and must map to `git_http_401`; transparent
    gzip must count decoded bytes against the limit; do not let the client add or drop `Authorization` on its own.
14. **Timeout semantics**: 60 s is an idle timeout, 600 s the whole-request cap (`GitSyncTransport.swift:189-190`). A plain 60 s call
    timeout would break large first uploads.
15. **Swift string semantics in the Markdown parser** (`GitPlainText.swift:291-333`): `hasPrefix`, `firstIndex(of:)`, `==` work on
    grapheme clusters and canonical equivalence. Rust reproduces this with grapheme segmentation (`git_plain.rs:567-620`). Kotlin
    `String` is UTF-16 code units: `"#́…".startsWith("#")` is true in Kotlin and false in Swift.
16. **Foundation whitespace set** (`git_plain.rs:551-563`): tab, U+0020, U+00A0, U+1680, U+2000...U+200B, U+202F, U+205F, U+3000 for
    `.whitespaces`; plus U+000A...U+000D, U+0085, U+2028, U+2029 for `.whitespacesAndNewlines`. Kotlin `trim()` differs.
17. **Tag normalization** (`GitPlainText.swift:230`): Foundation case- and diacritic-insensitive folding decides which tags are
    duplicates, and therefore the hash of a hand-edited file. Port `git_plain.rs:701-971` (measured against Foundation) and run the tag
    vectors.
18. **Name comparison for rename** (`GitSyncTransport.swift:1478-1485`) and **"first by name"** for copies (`:1161`): canonical
    equivalence and Swift's ordering (code points of the NFC form, as Linux reproduces it in `git_transport.rs:1118-1119`), not UTF-16
    order.
19. **Slug divergence** (`GitPlainText.swift:117-137`): Apple transliterates with ICU; `:core` has no ICU (and
    `android.icu.text.Transliterator` needs API 29). Follow the Linux rule; paths are cosmetic. Never derive identity or equality from a
    file name except the `-<id8>.md` owner rule.
20. **Double formatting in `sync`** (`GitPlainText.swift:84-90`): `createdAt`/`updatedAt` go through `CanonicalJSON` as Swift doubles.
    `Double.toString()` in Kotlin prints differently. Bytes must match so that devices racing to normalize converge. Vectors:
    `snippets-linux/tests/fixtures/swift-double-v1.tsv` (owned by brief 01).
21. **Body bytes**: never decode the body lossily; it must round-trip byte for byte and be valid UTF-8 to render (`:74-75`, `:425`).
    CRLF inside a body is kept; only the final newline rule of §2.6.3 applies.
22. **Booleans throw**: an unknown `enabled`/`pinned` value makes the file malformed (quarantine), not "default true" (`:373-379`).
23. **Render must verify read-back** (`:76-79`): skipping this lets a snippet that does not round-trip (for example a name the parser
    reads differently) be written as Markdown and then look hand-edited forever.
24. **Plain codec scope**: the Markdown path seals with the library keyring and `scopeID` `sync-v1`
    (`SyncBackendSelectionStore.swift:1423-1426`), the same sealer the engine uses.
25. **Token binding** (`SyncBackendSelectionStore.swift:755-759`): by exact `spec` and user name; the library key binds by canonical
    identity. Mixing these up either leaks a token to another port or loses the key when switching HTTPS↔SSH
    (`GitSyncSettingsMacTests.swift:169`).
26. **Order of key install, push, save** (`GitSyncSetup.swift:616-658`, `:905-914`) and the lost-response re-inspection (`:631-646`,
    `:1000-1019`, `:1216-1228`). Each branch has a test (`GitSyncSettingsMacTests.swift:415`, `:1158-1306`).
27. **SSH push must not upload after a stale advertisement** (`GitSSHClient.swift:111-119`), and the writer must not block the reader
    (`:469-474`).
28. **Host-key algorithm stickiness** with a library that negotiates among several server keys (§6.4): a naive store reports "changed"
    when only the negotiated type changed.
29. **DER → SSH signature conversion** and 32-byte coordinate padding (§6.4): the classic source of intermittent "permission denied"
    (one signature in 256 has a short `r` or `s`).
30. **Linux/Swift differences to pick a side on**: an empty decoded blob is accepted by Swift (`GitSyncTransport.swift:1763-1765`) and
    rejected by Rust (`git_layout.rs:187`); loopback hosts (§7.3); Rust caps the address at 2,048 bytes (`git_location.rs:214`); a
    malformed record halts Linux but is quarantined by Swift. Android follows Swift unless noted.
31. **`Int` width**: pack sizes, offsets and varints use 64-bit `Int` in Swift (`GitPack.swift:182-189`, `:204-212`). Use `Long` for
    shifts and bounds, then range-check before indexing.
32. **Memory**: the pack, its inflated objects and the push body are all in memory. Keep the iOS limits (128 MiB pack, 384 MiB inflated)
    or lower them for low-RAM devices, and build the push body without an extra copy.
33. **Cache directory hygiene**: mode 0700, excluded from backup, never credentials or cursors (`GitObjectCache.swift:55-59`,
    `:227-231`). On Android put it under `noBackupFilesDir`.
34. **Never log** the token, the recovery code, the repository URL, stderr text or server text. `GitRemote` redacts itself
    (`GitSmartHTTPClient.swift:161-166`); give the Kotlin class a redacting `toString()` and keep the token out of data-class
    `toString()`/`equals` debugging.

### 8.2 Test inventory to port

| Pri | Swift test | What it proves |
|---|---|---|
| P0 | `GitPrimitivesTests` all 13 (`:7-269`) | object ids, tree order vs `git mktree`, commit bytes, pack round trip, corruption, git-made deltified packs, delta bounds, zlib consumption, pkt-line, advertisements, token redaction, remote validation |
| P0 | `GitSyncVaultTests.knownAnswerMatchesTheLinuxMirror` `:146`; `fileOpensOnlyWithItsLibraryKeyAndLibrary` `:24`; `onlyWellFormedIdentitiesAreWritten` `:78`; `oneRecoveryCodeOpensTheLibraryAndItsVaultKey` `:107` | vault file bytes and binding |
| P0 | `GitSyncTransportTests.recoveryEnvelopeOpensOnlyWithItsCodeAndLibrary` `:803` | recovery envelope |
| P0 | `GitRepositoryLocationTests` (`GitSSHTests.swift:6-123`) + `git_tests.rs` identity vectors | parsing, canonical identity, unsafe values, round trip, remote command quoting |
| P0 | `GitPlainSnippetFileTests` (`GitPlainTextTests.swift:18-158`) + fixture `git-plain-v1.json` (15 renders, 122 reads, 13 assigned-id reads, file names, tags, README, manifest) | Markdown format |
| P0 | `GitSyncTransportTests` `:10-552` (init/adopt, uninitialized, foreign, redirects, wrong credential, submit/fetch, CAS, identical re-upload, delta across commits, lost race, conflict on retry, permanent rejection, tombstone, cache loss, corrupt cache, manual revert, removed record, replaced manifest, newer schema, empty batch, chunking, oversized record, malformed record, deleted branch, shutdown, one-request poll) | transport contract against real git |
| P0 | `GitIncrementalFetchTests` both | cost invariants |
| P0 | `GitSSHFramingTests` (`GitSSHTests.swift:135-183`) | ACK skipping, raw pack, shallow only when empty, advertisement end, stderr classification |
| P1 | `GitSyncTransportTests` library files `:836-1029` (key files, write race, path rule, `replaceLibrary`, moved branch, schema 2, replaced library stops the data plane) | setup operations and rotation |
| P1 | `GitPlainTextTransportTests` `:210-565` (18 tests) | plain-text transport behaviour |
| P1 | `GitSSHTransportTests` `:213-345` (shared library, stale push, failure codes, lingering process, early exit, cancellation, idle timeout) | connector contract (adapt process-specific ones) |
| P1 | "Git sync end to end" suite `:593-799` (two engines converge, large library, plain text, concurrent edits vs reference transport) | engine integration; needs brief 01 |
| P1 | `GitSSHSupportTests` (6) | fingerprints, host ids, trust-on-confirm, device key persistence, public key encoding, unreadable key not replaced |
| P1 | `GitSyncSettingsMacTests` setup subset `:50-503` | create/switch/join, SSH address, HTTPS↔SSH move, plain text, guidance, wrong token, foreign branch, new code, lost push response, retarget refused, recreate on same branch, token binding |
| P2 | `GitSyncSettingsMacTests` vault and rotation `:543-1622`, pacing `:1656` | vault adoption, rotation edge cases, main-thread responsiveness, debounce |
| P2 | `GitRealSSHTests` (`GitSSHTests.swift:359-434`) | real sshd; rewrite for the JSch connector |
| P2 | interop phases of `scripts/test-git-sync-integration.sh` with Android in the iOS role | cross-platform proof required by `PLAN.md` |
| — | `GitSyncHostBenchmarkTests`, `GitSyncLiveHostTests` | opt-in, hosted; port later |

### 8.3 Suggested Kotlin decomposition (`com.khm.snippets.core.git`, in dependency order)
1. `GitObjectId`, `GitObjectType`, `GitObject`, `GitFormatException(code)`.
2. `GitPktLine` (encode, `Reader`, `advertisementEnd`).
3. `GitTreeEntry`, `GitTree`, `GitCommit`.
4. `GitZlib`, `GitDelta`, `GitPack` (+ `Limits`).
5. `GitSshLocation`, `GitRepositoryLocation`, `GitRemote`, `GitRemoteFailure`.
6. `GitWire`: pure functions `parseAdvertisement`, `uploadRequest`, `extractPack`, `demultiplex`, `pushRequest`, `parseReportStatus`;
   `GitRefAdvertisement`, `GitPushResult`; interface `GitWireClient`.
7. `GitHttpEngine` (interface: one request, streamed, size-limited) and `GitSmartHttpClient`.
8. `GitSshConnector` (interface), `GitSshExchange`, `GitSshClient`, `GitSshDiagnosis`.
9. `GitObjectCache`.
10. `GitLibraryMode`, `GitSyncLayout` (paths, READMEs), `GitSyncManifest`, `GitRecordFile`, `GitSyncCursor`, `GitIdentities` (digests of
    §2.12).
11. `FoundationText` (whitespace sets, grapheme-aware prefix/index, strict UUID, lenient base64), `GitPlainSnippetFile`,
    `GitPlainCodec`.
12. `GitSyncRecovery`, `GitSyncVault`.
13. `GitSyncTransport`, split internally into `GitSnapshotStore` (snapshot/install/cached view), `GitTreeEditor`
    (`editTree`/`rewriteTree`), `GitCommitPlanner` (`plan`/`planPlain`), `GitPlainFetch` (locations, hand deletions, normalize).
14. `GitCoordinates`, `GitSettingsStore`, `GitCredentialStore`, `GitSyncKeyStore` (interfaces over the app's secret store).
15. `GitSshHostKeyStore`, `GitSshPresentedHostKey`, `OpenSshFormat` (public key line, fingerprint, signature re-encoding),
    `GitSshSigner`, `JschGitSshConnector`.
16. `GitSyncSetup`, `GitSetupFailure`, `GitSetupTexts`.

`:app` only: `AndroidKeystoreSshSigner`, the `HttpURLConnection`/OkHttp engine if it is not kept in `:core`, secret-store
implementations, the settings screen.

Steps 1–8, 10 and 12 are self-contained and can be ported nearly file for file (see the report). Step 13 depends on the engine types of
brief 01; step 16 on the vault API of brief 02.

### 8.4 Open questions
1. BouncyCastle for SSH: bundle it (Ed25519 host keys, curve25519, larger APK) or ship without and document the limitation as iOS
   documents RSA?
2. SSH key comment on Android: `snippets-android`, or a phone/tablet split like iOS?
3. Should the device-key choice prefer StrongBox when present, given its latency on each sign?
4. Pack and inflate limits for Android: iOS numbers (128 MiB / 384 MiB), or lower?
5. HTTP engine: `HttpURLConnection` (no dependency, awkward streaming/401 behaviour) or OkHttp? `PLAN.md` says `:core` uses only APIs
   present on API 28; a third-party HTTP client is a dependency decision for the orchestrator.
6. Empty decoded blob in a record file: follow Swift (accept) or Linux (reject)?
7. `git_sync_schema_unsupported` during setup maps to the generic `refused` message (`GitSyncSetup.swift:1625-1626`); should Android
   show the "update Snippets" text instead?
8. Flushing a waiting paced change when the app leaves the screen: macOS caps the quit-time flush at 5 s and iOS runs it under a
   background task. Which Android mechanism (expedited WorkManager work, or a plain `onStop` flush), and with what deadline?
9. Background polling on Android: iOS polls only in the foreground. Is a periodic background round wanted, and if so at what interval?
10. Retired-key deletion: Android's key store is device-only, so `forgetRetiredKey` always deletes. Confirm no Android backup/transfer
    path makes the key store "sync between devices".
11. JSON number strictness: Foundation's decoder accepts `1.0` for an `Int` field, Rust requires an integer (`git_layout.rs:128-130`).
    Not verified which the Swift tests pin; choose the strict form unless a vector says otherwise.
12. Lossy UTF-8 decoding of front-matter lines: Swift and the JVM may emit a different number of U+FFFD for the same malformed sequence.
    Only relevant to files with invalid UTF-8 in front matter; no vector found.
13. JSch facts not re-verified here: exact jar size, its licence file at the pinned version, and that `Session` exposes the negotiated
    host key after a rejected check (the design above does not depend on it, because `HostKeyRepository.check` receives the blob).
14. Diagnostics: `git_key_rotation` is the only Git diagnostics event on Apple. Does Android ship the same event schema in its first
    release?
