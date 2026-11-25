# swift-interop

Swift-side tool for the pure-Kotlin Android rebuild. The Swift sources are the authority;
this tool runs them, unmodified, to

1. **emit** golden vectors that the Kotlin tests read, and
2. **check** artifacts written by Kotlin (a sealed record, a `vault.json`, a backup, a Git
   key file …) with the Swift code.

Nothing under `snippets/`, `CorePackage/`, `Tests/` or the Xcode project is changed or
copied. Every key, password, code and body in the vectors is fictional public test data
(`0x11`×32, `Café public fixture` …). Fixed nonces are for vectors only.

## Run

```sh
# from snippets-android/
tools/swift-interop/emit.sh                 # build, then write core/src/test/resources/vectors/swift
tools/swift-interop/emit.sh /some/dir       # write somewhere else
tools/swift-interop/emit.sh --only V,G03    # only some files (prefix match; MANIFEST is not rewritten)
```

`emit.sh` prints one line per file and a few `drift-check` lines (see below). Output:

```text
core/src/test/resources/vectors/swift/
  sealed/   deterministic; a second run writes the same bytes
  sealed/MANIFEST.json   case count and SHA-256 of every sealed file
  open/     produced through Swift APIs that draw their own randomness; differs per run
```

To prove determinism:

```sh
tools/swift-interop/emit.sh && (cd core/src/test/resources/vectors/swift/sealed && shasum -a 256 *.json) > /tmp/a
tools/swift-interop/emit.sh && (cd core/src/test/resources/vectors/swift/sealed && shasum -a 256 *.json) > /tmp/b
cmp /tmp/a /tmp/b
```

Checking Kotlin output:

```sh
B=tools/swift-interop/.build/debug/swift-interop
$B kinds
$B check canonical-json envelope.json
$B check sealed-record --id 11111111-2222-4333-8444-555555555555 sealed.txt
$B check wire-record records/11/11111111-2222-4333-8444-555555555555.json
$B check vault-document --key 1111…11 --code M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ vault.json
$B check backup --password 'Café public backup fixture' library.snippetsbackup
$B check git-recovery --code M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ --dataset 617a0001-0000-4000-8000-0000000000aa keys/recovery.json
$B check git-vault --material <hex64> --dataset <uuid> keys/vault.json
$B check git-manifest snippets-sync.json
$B check git-markdown --path snippets/greeting-617a0002.md greeting-617a0002.md
$B check library-json snippets.json
```

One JSON object per file on stdout, one line each (`"ok": true|false`, `"error"` is a Swift
`Type.case`). Exit status 0 when every file passed, 1 when one failed, 2 for a usage error.
Options default to the fixtures in `Sources/swift-interop/Support.swift` (`Fixture`).
Recovered keys are reported as SHA-256 digests, never as bytes. `-` reads stdin.

| Kind | Swift code that judges the file | Reports |
|---|---|---|
| `canonical-json` | `CanonicalJSON.value` then `CanonicalJSON.data` must equal the file | byte count, SHA-256, or the first differing byte |
| `envelope` | `SyncEnvelope.parse` | hash, rev, contentHash, `isCanonical` |
| `sealed-record` | `SnippetCrypto.open(_:for:keyring:)` | plaintext length and SHA-256, keyed content hash |
| `wire-record` | `GitRecordFile.decode` + `WireCodec.open` | envelope hash, path, git blob id, `fileIsByteExact` |
| `vault-document` | `VaultFile.decode` / `encode`; with `--key` opens every record | record count, re-encode and round-trip results, lost dates |
| `backup` | `EncryptedSnippetBackup.open` | counts, ids, `vaultRecordsWithDistantPastDates` (hazard H2) |
| `git-recovery` | `GitSyncRecovery.open` | material SHA-256; `--expect-material` compares |
| `git-vault` | `GitSyncVault.open`; `--code` also unwraps `wrapRecovery` | identity fields |
| `git-manifest` | `GitSyncManifest.decode` | fields, `fileIsByteExact` |
| `git-markdown` | `GitPlainSnippetFile.read` | canonical envelope, `edited`, `fileIsByteExact` |
| `library-json` | `SnippetLibraryCodec.decode` | count, file digest, `summarySHA256` (canonical JSON of the nine fields; `--verbose` prints it) |

## How it links the Swift core

`Sources/SnippetsCore` is a **symlink overlay** in the style of `CorePackage`:

```text
Sources/SnippetsCore/Core                  -> snippets/Core            (the whole shared core)
Sources/SnippetsCore/GitSyncKeyStore.swift -> snippets/Sync/GitSyncKeyStore.swift
Sources/SnippetsCore/SyncKeyStore.swift    -> snippets/Sync/SyncKeyStore.swift
Sources/SnippetsCore/KeychainSecretStore.swift -> snippets/Vault/KeychainSecretStore.swift
Sources/SnippetsCore/Shims/AppLayerShims.swift    (the only file written here)
Sources/swift-interop/Harness/GitTestServer.swift -> Tests/Core/GitTestServer.swift
Sources/git-plain-reference/main.swift     -> snippets-linux/tests/reference/git-plain-vectors.swift
```

A path dependency on `../../../CorePackage` with `@testable import SnippetsCore` is the
lighter option and is enough for the core alone (it is how
`snippets-linux/tests/reference/git-plain-vectors.swift` describes its own use). It is not
used here for one reason: V17 and V18 need `GitSyncKeyStore.Scope.account` and
`SyncKeyStore.keyring(from:)`, which live in the app layer. Those files have no `import`
of the core (in the apps they are in the same module), so they compile only inside the
module that also holds `snippets/Core`. The overlay keeps the module name `SnippetsCore`,
which lets two existing files compile unmodified against it: the `git http-backend` test
harness and the repository's own plain-text vector generator.

`AppLayerShims.swift` declares two types that `SyncKeyStore.swift` names
(`SnippetsCloudKeychainScope`, `SyncBackendSelectionStore.CloudCoordinates`). Their real
home, `SyncBackendSelectionStore.swift`, needs CloudKit and most of the app. The tool calls
only `SyncKeyStore.keyring(from:)`, which touches neither; no Keychain is opened anywhere.

Everything in the core is `internal`, so the tool uses `@testable import`, which works in
**debug** builds only (SwiftPM passes `-enable-testing` there). Do not build with
`-c release`.

Where the Swift API hides something the vector needs, the tool says so in the file's
`notes`:

- **Transcribed and proven** (V15, V16): `EncryptedSnippetBackup.seal` draws its passphrase
  salt and `GitSyncRecovery.seal` its nonce with no seam. The tool assembles the same bytes
  from the public pieces (`PassphraseKDF.wrap`, `SnippetCrypto.seal`, CryptoKit, a
  field-for-field mirror of the private container struct). Before writing, it asserts that
  this assembly is **byte-identical to the real Swift output** at that run's random
  salt/nonce, then writes the fixed-salt/nonce version to `sealed/` after opening it with
  the real Swift reader. The real, random output goes to `open/`.
- **Transcribed formulas** (G06): the account and dataset identities are private members
  of `GitSyncTransport`; G04 reads the same values from a running transport and the tool
  asserts they agree. The local sync-state folder key comes from
  `SyncBackendSelectionStore.gitProtocolLocations` (not compilable here) and is transcribed
  only.

## Self-checks

`emit` fails, and writes nothing for that file, unless: every sealed text reopens to its
plaintext; every envelope reparses to itself; every wire record reopens; every vault and
library file decodes and re-encodes; V15/V16 assemblies equal the real Swift output; G04's
trees and commits equal `GitTree.serialize` / `GitCommit.serialize`, hash to their ids and
pass `git fsck --strict`; HLC order equals string order; the ISO-8601 timestamp model
below holds for every case; case names are unique.

## Drift checks

With `--linux-fixtures snippets-linux/tests/fixtures` (which `emit.sh` passes), the current
Swift code is also run over the independent fixtures there. Result on the toolchain below:

| Fixture | Result |
|---|---|
| `git-plain-v1.json` | regenerated output is byte-identical |
| `swift-double-v1.tsv` | `Double.description` matches all 11 903 lines |
| `sync-wire-v1.json` | both records open; canonical bytes and hashes agree |
| `crypto-v1.json` | vault decodes; record, recovery wrap and passphrase wrap open |
| `conflict-copy-v1.json`, `merge-v1.json` | reproduced |
| `bootstrap-v1.json` | `bundleJSON` reproduced |
| `backup-v1.json` | opens, but its secure record comes back with `Date.distantPast` (H2, below) |

## Vector files

Every file: `{"format", "generator": {tool, swift, source}, "direction", "pins", "notes", "cases": [...]}`.
Each case has a stable `name`. Conventions:

- `…Hex` is lowercase hex of bytes; `…Text` the same bytes as UTF-8 text when they are text.
- `{"text", "utf8Hex"}` is used wherever normalisation form or an invisible character matters.
- A double is `{"bits": "<16 hex, IEEE-754>", "swift": "<Double.description>"}`. Dates are
  doubles of seconds since 2001-01-01T00:00:00Z, as the Swift model stores them.
- An outcome is `"ok": <value>` or `"error": "Type.case"`; payloads of errors are not recorded.
- Invisible characters in JSON strings are written as `\uXXXX` so no editor can lose them.

| File | Cases | Pins |
|---|---:|---|
| `V01-record-aad` | 12 | `SnippetCrypto.additionalData`, `domainSeparated` |
| `V02-record-keys` | 20 | `Keyring.recordKey`, `contentHashKey` (HKDF) |
| `V03-record-seal` | 29 | `SnippetCrypto.seal(for:keyring:)` text for bodies of 0, 1, 255, 256, 257, 511, 512 bytes, multi-byte, non-UTF-8; `open` failures |
| `V04-padding` | 26 | `Padding.pad` / `unpad` at block boundaries and every refusal |
| `V05-content-hash` | 12 | keyed content hash |
| `V06-pbkdf2` | 35 | `PassphraseKDF.derive`: ASCII, `Café` NFC and NFD, non-BMP, Å, Hangul jamo, ligature; 1, 2, 4096 and 600 000 rounds; refusals |
| `V07-passphrase-wrap` | 16 | `PassphraseKDF.wrap` with fixed nonce, AAD; `unwrap` outcomes |
| `V08-key-wrap` | 16 | `KeyWrap.wrap` for `recovery` and `cli`; `unwrap` outcomes |
| `V09-recovery-key` | 47 | `RecoveryKey` encode, format, normalise, decode; all five failures |
| `V10-canonical-json` | 149 | emitter (escapes, key order, int limits, 43 doubles), emitter refusals, 72 parser inputs |
| `V11-sync-envelope` | 65 | canonical bytes, hash preimage, hash, rev for 9 envelopes; constructor normalisation; 54 `parse` outcomes |
| `V12-wire-record` | 19 | `WireCodec.seal` blobs for the V11 envelopes; `open` outcomes |
| `V13-secure-conflict` | 7 | `contentConflict.v1.<fp>` key and value, fingerprint, copy id, materialised copy metadata, `deterministicUUID` |
| `V14-vault-document` | 86 | `VaultFile.encode` bytes with passthrough keys; decode leniency; ISO-8601 timestamp format and parse tables |
| `V15-encrypted-backup` | 18 | container, wrapped key, payload AAD, vault-key wrap, decrypted payload JSON, with and without a vault; H2 case; `open` outcomes |
| `V16-git-recovery` | 30 | `keys/recovery.json` bytes, key, AAD, plaintext; `open` and `Kit` outcomes |
| `V17-git-key-account` | 8 | `GitSyncKeyStore.Scope.account` |
| `V18-sync-key-split` | 7 | `SyncKeyStore.keyring(from:)` then one sealed wire record |
| `V19-portable-key-bundle` | 20 | `PortableKeyBundle.jsonData` and its strict reader |
| `L01-library-json` | 55 | `snippets.json` bytes (array and collection), digest, decode outcomes, display order, `displayName`, secure shell |
| `L02-hlc` | 193 | HLC init, string, parse, order, `normalizedDevice`, `millisecondsSince1970`, generator scripts |
| `L03-keyword-and-tags` | 201 | `sanitizedKeyword`, `normalizedTags`, `filterKey`, Foundation character sets |
| `L03b-filterkey-table` | 2 | `filterKey` of every Unicode scalar (1 943 change), and base + U+0301 for every base below U+30000 |
| `L04-search` | 134 | `FuzzyMatch` scores and ranges, `PreparedSubstringSearch`, search results and tag list for a fixed library |
| `L05-placeholders-<locale>-<zone>` (6 files) | 349 each | `PlaceholderResolver`, `RaycastPlaceholders` for en_US, fr_FR, th_TH × UTC, Europe/Paris |
| `L06-keywords-import-links` | 127 | `KeywordSuggestions`, `KeywordRelation`, `SnippetImportParser`, `SnippetDeepLink` |
| `L07-merge` | 147 | `SyncMerge.mergeEnvelopeOutcome` per field rule, conflict copies, `mergeLocal`, `DeletionGuard` |
| `G01-git-manifest` | 31 | manifest bytes, schema 1 and 2, both modes; decode outcomes |
| `G02-git-readme` | 2 | README bytes and blob ids |
| `G03-git-record-file` | 89 | record file bytes, paths, fanout and file-name rules, decode outcomes, Foundation base64 leniency |
| `G04-git-repository` | 10 | two whole repositories written by `GitSyncTransport` through `git http-backend`: every commit, tree, blob, id; tree and commit primitives |
| `G05-git-location` | 161 | `GitRepositoryLocation.parse`, `canonicalIdentity`, SSH remote command, branch and credential rules |
| `G06-git-identities` | 18 | account, dataset, cache, key-store, folder identities; cursor and record-version strings |
| `G07-git-plain-text` | 295 | Markdown render and read: the repository's own generator, run unmodified (each case's `entry` is one entry of `git-plain-v1.json`), plus slug and render cases |

### Open-direction files

| File | Why Swift cannot pin it |
|---|---|
| `open/V15-encrypted-backup` | `EncryptedSnippetBackup.seal` calls `PassphraseKDF.makeSalt()` internally. Export key, backup id and all three nonces are fixed through its parameters; the 16-byte passphrase salt is not. |
| `open/V16-git-recovery` | `GitSyncRecovery.seal` has no nonce parameter (`GitSyncVault.seal` has one). |

Both also have a deterministic sibling in `sealed/` (see "Transcribed and proven").
Also not pinned: the `sealed` text of a materialised secure conflict copy in V13
(`SyncSecureConflictMaterializer` reseals with a system nonce); the tool opens it and
records the plaintext and the rest of the record.

### Data that belongs to the OS, not to Snippets

These vectors record what Foundation/ICU did on the machine that ran the emitter. They are
deterministic there; an OS update may change them, and Android's CLDR will differ:

- `L05`: localised date text (medium styles, month names, digits, U+202F before AM/PM).
  The grammar outcomes, offset arithmetic and numeric patterns are the contract.
- `L03b`, and the `filterKey` columns elsewhere: `String.folding` data.
- `G05`: `URLComponents` / `URL(string:)` behaviour for IDN, IPv6 and percent-encoding.
- `G07` slugs: ICU `toLatin` / `stripDiacritics`.

## What the vectors show that the code does not say out loud

- **Backup payload dates (H2).** Swift writes snippet dates and vault-record dates as JSON
  numbers (seconds since 2001); ids uppercase; `vault` and `wrappedVaultKey` absent, not
  `null`, when there is no vault (`V15`, `payloadJSONText`). A payload with ISO-8601 strings
  for the vault records opens without error and the dates become `Date.distantPast`
  (`-63114076800.0`). `snippets-linux/tests/fixtures/backup-v1.json` is such a payload.
- **`vault.json` timestamps are not bit-exact.** Foundation's ISO-8601 formatter goes
  through whole milliseconds since 1970 held in a double: on write
  `ms = round((t + 978307200.0) * 1000.0)`, on read `t = Double(ms) / 1000.0 - 978307200.0`
  (digits past the third are dropped). `812578800.123` is written `…00.123Z` and read back
  as `812578800.1229999`; `0.001` comes back as `0.001000046730041504`. These read-back
  doubles are what a secure record's `createdAt`/`updatedAt` carry onto the wire, where
  they are hashed. The tool asserts the model for every case in `V14`.
- **Recovery code and CRLF.** `RecoveryKey.normalized` walks Swift `Character`s; CR LF is one
  `Character`, so a code pasted with a Windows line ending fails with `wrongLength`. Lone CR
  or LF is stripped.
- **A changed `backupID` reads as a wrong password** (`wrongPassphrase`): it is in the
  passphrase-wrap AAD.
- **`SyncEnvelope.parse` accepts `schemaVersion` 0 and negative values** when the hash was
  computed over them; an integer token for a date parses only when the hash was computed
  over the double spelling.
- **`CanonicalJSON`**: `1e400` parses (to infinity) and then cannot be re-emitted; raw
  U+007F in a string is accepted; 33 nested arrays parse, 34 do not; 32 nested objects with
  a value parse, 33 do not.
- **JSON written by Foundation** (`snippets.json`, `vault.json`, backup payload): `/` is
  written `\/`, an empty array is `[`, blank line, `]`, `-0.0` is `-0`, whole doubles have
  no fraction. Foundation's reader accepts a UTF-8 BOM and a trailing comma.
- **`GitRepositoryLocation`**: `C:/Users/me/repo.git` is an scp-style SSH location with host
  `C`; an scp-style or `ssh://` path ending in `.git/` keeps `.git` in `canonicalIdentity`
  while the same HTTPS URL loses it; `http://[::1]/…` is refused even on the loopback seam.
- **`GitSyncManifest.decode`** accepts a BOM, CRLF, duplicate keys and `"schemaVersion": 1.0`.
- **Fuzzy match in Turkish and Azeri locales**: `title` does not match `TITLE`.
- **Placeholders**: `{date format="it''s"}` resolves to an empty string (ICU returns
  nothing), it does not stay literal; a clipboard value containing `{date}` is not rescanned.

## Toolchain

- Use `xcrun swift` (Apple Swift 6.4 here). The swiftly toolchain selected by the
  repository's `.swift-version` (6.3.3) cannot load CryptoKit from the current Xcode SDK.
- macOS 14 or later. `/usr/bin/git` must provide `http-backend` (Xcode's git does) for G04.
- A clean build takes well under a minute; a full emit about 10 s (600 000-round PBKDF2
  cases dominate).
- Build products go to `tools/swift-interop/.build` (git-ignored here). G04 creates and
  removes bare repositories in the system temporary directory.
- L05 starts six child processes of the tool itself with `-AppleLocale`, `-AppleLanguages`
  (NSArgumentDomain) and `TZ`, because `PlaceholderResolver` uses the process locale, zone
  and calendar and offers a seam for the clock only.

## Adding a vector

Add a function returning `VectorFile` in `Sources/swift-interop/Vectors*.swift`, register it
in `allVectors` in `main.swift`, give every case a unique `name`, re-open whatever you seal
with `require(…)`, sort any dictionary you walk (`sortedByUTF8`), and never read the clock or
generate an id without recording that the value is not pinned.
