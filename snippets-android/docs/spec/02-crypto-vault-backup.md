# 02 — Cryptography, wire envelope, secure-snippet vault, backups, key storage

Porting brief for the pure-Kotlin Android rebuild. The Swift sources are the authority; the Rust
port (`snippets-linux/src`) is the second reference and the source of independent fixtures.
All paths are relative to the repository root. `file:line` pointers are to the tree at the time
of writing (2026-11-25, `main` at `66e7c7f`).

Conventions: `‖` is byte concatenation, `u32be(n)` a 4-byte big-endian length, `b64url` is
unpadded URL-safe base64, `b64std` is padded standard base64, `uuid16(id)` is the 16 raw UUID bytes
in RFC 4122 order (the order of the hex digits in the string form), `lower(id)` is the lowercase
36-character string form.
Inside tables a literal pipe character is written `\|` because of Markdown table syntax; the
actual strings contain a bare `|` (see the code blocks in §2 for the unescaped spelling).

Names used throughout:

| Name | What it is | Size |
|---|---|---|
| `K_lib` | Vault library key. Root of secure-snippet bodies. Never encrypts directly. | 32 bytes |
| `vaultSalt` | Per-vault public HKDF salt, stored in `vault.json` | 32 bytes |
| `kid` | Vault key id, the crypto scope of every secure body (`"k-" + 12 chars`) | string |
| `K_sync` material | Wire key of one sync library: key ‖ HKDF salt | 32 + 32 bytes |
| `K_rec(id)` | Per-record AES key derived from a root key and salt | 32 bytes |
| `K_hash` | HMAC key for the vault content hash | 32 bytes |
| recovery key / recovery code | 128 random bits, shown as 27 Crockford symbols | 16 bytes |

---

## 1. Primitive inventory

### 1.1 Table

| # | Primitive | Exact parameters | Swift API and pointer | Android (API 28+, no native code) |
|---|---|---|---|---|
| 1 | AES-256-GCM | 32-byte key, 12-byte nonce, 16-byte tag, AAD always supplied. Output handled as `ciphertext ‖ tag`. | `AES.GCM.seal/open`, `SnippetCrypto.swift:377-386`, `:405-414` | JCA: `Cipher.getInstance("AES/GCM/NoPadding")`, `GCMParameterSpec(128, nonce)`, `updateAAD(aad)`, `doFinal` returns `ct‖tag`. Use a fresh `Cipher` per call. |
| 2 | Nonce generation | 12 random bytes from the system CSPRNG for every seal. Never a counter, never derived. Injectable only in tests (`NonceSource`). | `AES.GCM.Nonce()`, `SnippetCrypto.swift:272-283` | `SecureRandom().nextBytes(ByteArray(12))`. Keep the injectable nonce source for vectors. |
| 3 | HKDF-SHA256 (RFC 5869, extract then expand) | Output always 32 bytes. Salts and info strings in §1.2. | `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)` | Not in JCA on Android. Pure Kotlin over `Mac.getInstance("HmacSHA256")` (about 20 lines). An empty salt never occurs (guarded, `KeyWrap.swift:132`). |
| 4 | HMAC-SHA256, truncated | First 16 bytes of the MAC, lowercase hex (32 chars). | `HMAC<SHA256>.authenticationCode`, `SnippetCrypto.swift:463-468` | JCA `Mac("HmacSHA256")`. |
| 5 | SHA-256 | Lowercase hex, 64 chars. Envelope hash, wire `contentHash`, conflict fingerprints, Git key account name. | `SHA256.hash`, `SyncEnvelope.swift:1088-1091`, `:1132-1138` | JCA `MessageDigest("SHA-256")`. |
| 6 | SHA-1 (not for security) | Name-based UUID for conflict copies: SHA-1(namespace uuid16 ‖ name UTF-8), first 16 bytes, version nibble 5, RFC 4122 variant. | `Insecure.SHA1`, `SyncMerge.swift:468-479` | JCA `MessageDigest("SHA-1")`. Do not use `UUID.nameUUIDFromBytes` (that is MD5/v3). |
| 7 | PBKDF2-HMAC-SHA512 | 600 000 iterations (pinned), salt 16 random bytes, dkLen 32. Password = UTF-8 of the NFC-normalised passphrase. Reader accepts 1...20 000 000 iterations, refuses empty password and empty salt. | `CCKeyDerivationPBKDF`, `PassphraseKDF.swift:55-73`, `:183-219` | JCA `SecretKeyFactory.getInstance("PBKDF2WithHmacSHA512")` exists on API 26+ and encodes `char[]` as UTF-8. Must be proven against the vectors (non-ASCII, supplementary plane). Fallback: pure Kotlin PBKDF2 over `Mac("HmacSHA512")` on raw bytes. Measure both: 600 000 rounds may take seconds on a phone; run off the main thread. |
| 8 | Unicode NFC | `precomposedStringWithCanonicalMapping` | `PassphraseKDF.swift:184` | `java.text.Normalizer.normalize(s, Form.NFC)`. |
| 9 | ISO/IEC 7816-4 padding | Append `0x80`, then `0x00` up to the next multiple of 256. Always at least one pad byte. | `SnippetCrypto.swift:491-519` | Pure Kotlin. |
| 10 | Text envelope | `"v1." ‖ b64url(nonce) ‖ "." ‖ b64url(ct‖tag)` | `SnippetCrypto.swift:293-316` | Pure Kotlin. |
| 11 | AES-GCM "combined" framing | `nonce(12) ‖ ct ‖ tag(16)`, then `b64std`. Used by the Git key files and Snippets Cloud recovery envelopes. No padding scheme there. | `AES.GCM.SealedBox.combined`, `GitSyncRecovery.swift:72-77`, `GitSyncVault.swift:131-137` | JCA, concatenate manually. |
| 12 | base64url, unpadded, strict | Alphabet `A-Za-z0-9-_`. Decoder rejects empty input, `=`, `+`, `/`, and length `4n+1`. | `SnippetCrypto.swift:556-582` | `java.util.Base64.getUrlEncoder().withoutPadding()` to encode. Pre-validate the alphabet and length yourself before `getUrlDecoder()`, which is more lenient (accepts `=`). |
| 13 | base64 standard, padded, canonical | Readers decode then require `encode(decode(x)) == x`. | `GitSyncRecovery.swift:92-93`, `LibraryKeyBootstrap.swift:81-86` | `java.util.Base64.getEncoder()/getDecoder()` plus the same re-encode check. |
| 14 | Hex | Always lowercase (`%02x`). Readers of hashes require lowercase where stated. | `SyncEnvelope.swift:1136-1146` | Pure Kotlin. |
| 15 | Crockford base32 with check symbol | §2.8 | `RecoveryKey.swift` | Pure Kotlin. |
| 16 | Canonical JSON | Hand-written emitter and parser, including Swift's `Double.description`. §2.9 | `SyncEnvelope.swift:63-475` | Pure Kotlin. `Double.toString()` is not usable (different format, and not shortest-round-trip on older ART). Port a shortest-digits algorithm (Ryu or Schubfach) plus the Swift formatting rule in §2.9. |
| 17 | Randomness | Keys `SymmetricKey(size: .bits256)`, salts and recovery keys `SystemRandomNumberGenerator`. | `SnippetCrypto.swift:166-168`, `:541-544` | `SecureRandom`. |
| 18 | Constant-time comparison | The Swift code has none of its own. Tags are verified inside CryptoKit. Content hashes and the backup key comparison use ordinary `==` (`SecureSnippetStore.swift:1578`, `EncryptedSnippetBackup.swift:370`). | — | Use `MessageDigest.isEqual` for key and MAC comparisons. Behaviour is unchanged, timing is better. |
| 19 | Memory hygiene | Best-effort `memset_s` of `Data`; `SecurePlaintextLease` owns a raw allocation that is wiped. Plaintext bodies are `Data`, converted to `String` only at the last hop. | `SecurePlaintextLease.swift:10-83` | Keep bodies and keys as `ByteArray`/`CharArray`, `fill(0)` after use. A JVM `String` cannot be wiped; same honest limit as Swift. |
| 20 | P-256 ECDH + HKDF-SHA256 | Snippets Cloud pairing only: ephemeral keys, X9.63 uncompressed public keys (65 bytes, `0x04` prefix), raw 32-byte private scalar, HKDF over the shared X coordinate with salt = invitation nonce, info = pairing AAD. | `LibraryKeyBootstrap.swift:559-621` | JCA `KeyPairGenerator("EC")` secp256r1 + `KeyAgreement("ECDH")`; encode and decode the X9.63 point by hand. Covered by the Cloud brief. |
| 21 | Ed25519 | Snippets Cloud library-action proof: seed = HKDF(K_sync key, salt = K_sync salt, info = context). | `LibraryKeyBootstrap.swift:835-875` | **Not in JCA on API 28.** Needs a pure-Kotlin Ed25519 or BouncyCastle (`bcprov-jdk18on`, `Ed25519PrivateKeyParameters(seed)`). Covered by the Cloud brief. |
| 22 | P-256 signing key for SSH | iOS per-device key, Secure Enclave when available, never synced. | `GitSSHDeviceIdentity` (Git brief) | Android Keystore EC key, non-exportable. Covered by the Git brief. |

Not available in plain JCA on API 28: **HKDF** (trivial to write), **Ed25519** (library or own code,
Cloud only), **Swift-compatible shortest double formatting** (own code), plus the small format
codecs (Crockford, canonical JSON, padding). Everything in this brief's own scope (vault, wire,
backup, Git key files) needs only AES-GCM, HMAC-SHA256, SHA-256, SHA-1 and PBKDF2-HMAC-SHA512 from
the platform.

### 1.2 Every HKDF-SHA256 derivation (all output 32 bytes)

| Purpose | IKM | Salt | Info (bytes) | Pointer |
|---|---|---|---|---|
| Record key `K_rec(id)` | root key (`K_lib`, or the key half of `K_sync`) | `vaultSalt`, or the salt half of `K_sync` | `"snip.wire.v1\|"` ‖ `uuid16(id)` | `SnippetCrypto.swift:96`, `:177-183` |
| Content-hash key `K_hash` | `K_lib` | `vaultSalt` | `"snip.chash.v1"` | `SnippetCrypto.swift:97`, `:188-192` |
| Key-wrap key | wrap material, at least 16 bytes (recovery key: 16) | `vaultSalt` | `"snip.wrap.v1\|"` ‖ purpose, purpose is `"recovery"` or `"cli"` | `KeyWrap.swift:67`, `:128-141` |
| Backup vault-key wrap | backup export key (32 random bytes) | `vaultSalt` | `"snip.backup.vault-key.v1\|"` ‖ backupID UTF-8 ‖ `0x00` ‖ `kid` UTF-8 | `EncryptedSnippetBackup.swift:20`, `:288-303` |
| Git recovery envelope key | recovery code secret (16 bytes) | ASCII `"snippets-git-recovery-salt-v1"` | the AAD: `"snippets-git-recovery-v1"` ‖ `0x00` ‖ `lower(datasetID)` | `GitSyncRecovery.swift:110-120` |
| Git vault-file key | `material[0..<32]` | `material[32..<64]` | the AAD: `"snippets-git-vault-v1"` ‖ `0x00` ‖ `lower(datasetID)` | `GitSyncVault.swift:191-203` |
| Cloud recovery envelope key | recovery kit secret (32 bytes) | ASCII `"snippets-recovery-salt-v1"` | recovery AAD (Cloud brief) | `LibraryKeyBootstrap.swift:631-635` |
| Cloud pairing key | ECDH shared secret | invitation nonce (32 bytes) | pairing AAD (Cloud brief) | `LibraryKeyBootstrap.swift:568-572` |
| Cloud action signing seed | `material[0..<32]` | `material[32..<64]` | `"snippets-library-action-signing-v1\n"` ‖ serverURL ‖ `"\n"` ‖ `lower(serverInstanceID)` ‖ `"\n"` ‖ `lower(spaceID)` | `LibraryKeyBootstrap.swift:847-853` |

### 1.3 Domain-separation strings (verbatim)

| String | Role | Pointer |
|---|---|---|
| `v1` | `SnippetCrypto.wireVersion`: envelope prefix and an AAD field | `SnippetCrypto.swift:84` |
| `snip.aad.v1` | record AAD domain | `SnippetCrypto.swift:101` |
| `snip.wire.v1\|` | record-key HKDF info prefix | `SnippetCrypto.swift:96` |
| `snip.chash.v1` | content-hash HKDF info | `SnippetCrypto.swift:97` |
| `snip.wrap.v1` | key-wrap AAD domain | `KeyWrap.swift:63` |
| `snip.wrap.v1\|` | key-wrap HKDF info prefix | `KeyWrap.swift:67` |
| `snip.kdf.v1` | passphrase-wrap AAD domain | `PassphraseKDF.swift:78` |
| `pbkdf2-hmac-sha512` | passphrase KDF `alg` | `PassphraseKDF.swift:55` |
| `snip.backup.payload.v1` | backup payload AAD domain | `EncryptedSnippetBackup.swift:19` |
| `snip.backup.vault-key.v1\|` | backup vault-wrap HKDF info prefix | `EncryptedSnippetBackup.swift:20` |
| `snip.backup.vault-key-aad.v1` | backup vault-wrap AAD domain | `EncryptedSnippetBackup.swift:21` |
| `com.khm.snippets.encrypted-backup` | backup `format` | `EncryptedSnippetBackup.swift:15` |
| `snippets-git-recovery-hkdf-sha256-aes256gcm-v1` | `keys/recovery.json` `algorithm` | `GitSyncRecovery.swift:27` |
| `snippets-git-recovery-v1`, `snippets-git-recovery-salt-v1` | Git recovery AAD prefix, HKDF salt | `GitSyncRecovery.swift:111`, `:117` |
| `snippets-git-vault-hkdf-sha256-aes256gcm-v1` | `keys/vault.json` `algorithm` | `GitSyncVault.swift:33` |
| `snippets-git-vault-v1` | Git vault-file AAD prefix | `GitSyncVault.swift:192` |
| `snippets-git-key-v1` | Git key Keychain account preimage prefix | `GitSyncKeyStore.swift:40` |
| `sync-v1` | wire crypto scope for every provider, also `PortableKeyBundle.scopeID` | `SyncKeyStore.swift:54`, `LibraryKeyBootstrap.swift:42-43` |
| `sync-content-conflict-v1\|` | name prefix of the conflict-copy UUID | `SyncMerge.swift:900-902` |
| `vaultContentHash`, `vaultKID`, `userDeletion.v1` | reserved keys in the envelope `x` bag | `SyncEnvelope.swift:789`, `:806`, `:819` |
| `contentConflict.`, `contentConflict.v1.`, `contentConflictOpaque.v1.`, `conflictCopy.v1` | conflict extension prefixes and keys | `SyncMerge.swift:591-594` |
| `local.syncConflictC0Receipts.` (+ `v1`) | device-local key in the vault document `x` bag | `VaultDocument.swift:242-243` |

---

## 2. Byte layouts

### 2.1 Length-prefixed field list (`domainSeparated`)

`SnippetCrypto.swift:251-260`. Used for every `snip.*` AAD.

```
domainSeparated(domain, [f1 … fn]) =
    u32be(len(domain)) ‖ domain_utf8 ‖ u32be(len(f1)) ‖ f1 ‖ … ‖ u32be(len(fn)) ‖ fn
```

### 2.2 Sealed envelope text (`SnippetCrypto.seal` / `open`)

`SnippetCrypto.swift:293-417`.

```
envelope   = "v1" "." b64url(nonce) "." b64url(ciphertext ‖ tag)
ciphertext = AES-256-GCM(key, nonce, plaintext = pad(body), aad)
```

- Exactly three dot-separated fields (split keeps empty fields, so `"v1..x"` is malformed).
- Version field must equal `v1`, otherwise `unsupportedWireVersion`.
- Nonce must decode to exactly 12 bytes; body must decode to more than 16 bytes.
- Every authentication failure (wrong key, AAD, nonce, tampering) is the single error
  `authenticationFailed`. Padding errors after a valid tag are `malformedPadding`.
- Key must be exactly 32 bytes (`wrongKeySize`).
- Length: a body of `P` bytes seals to `20 + ceil(4 * (256 * ceil((P + 1) / 256) + 16) / 3)`
  characters (unpadded base64). A 32-byte key therefore always seals to 383 characters.
- The largest plaintext accepted on the wire is 674 815 bytes (`SyncMerge.swift:606`), which seals
  to 899 796 characters, below the 900 000-byte field ceiling.

Padding (`SnippetCrypto.swift:491-519`): `pad(p) = p ‖ 0x80 ‖ 0x00*` to the next multiple of 256
(a 255-byte body becomes 256, a 256-byte body becomes 512). `unpad` requires a non-empty multiple
of 256, strips trailing `0x00`, requires the next byte to be `0x80`, returns everything before it.

### 2.3 Record sealing (vault bodies and wire blobs use the same construction)

```
key = HKDF(ikm = root, salt = salt, info = "snip.wire.v1|" ‖ uuid16(recordID))
aad = domainSeparated("snip.aad.v1",
        [ "v1", scopeID_utf8, uuid16(recordID), byte(isDeleted ? 1 : 0) ])
```

`SnippetCrypto.swift:177-183`, `:239-246`. Two instantiations:

| Use | root, salt | scopeID | plaintext | isDeleted |
|---|---|---|---|---|
| Vault body (`VaultRecord.sealed`) | `K_lib`, `vaultSalt` | the vault's `kid` | the UTF-8 snippet body | always `false` (`SecureSnippetStore.swift:2485-2487`) |
| Wire blob (`WireRecord.blob`) | key and salt halves of `K_sync` | the constant `sync-v1` | canonical envelope JSON (§2.10) | the record's tombstone flag |

`scopeID` must never come from `Sync/state.json` (`SnippetCrypto.swift:200-215`).

### 2.4 Vault content hash

`SnippetCrypto.swift:463-472`:
`contentHash = hex_lower( HMAC-SHA256(K_hash, plaintext_body)[0..<16] )`, 32 characters, with
`K_hash` from §1.2. Computed over the unpadded body. Stored in `VaultRecord.contentHash` and carried
on the wire as `x.vaultContentHash`. It is not the envelope's top-level `contentHash` (§2.10).

### 2.5 Key wrap under random material (`KeyWrap`)

`KeyWrap.swift:109-190`. Wraps the 32 raw bytes of `K_lib`.

```
wrapKey  = HKDF(ikm = material, salt = vaultSalt, info = "snip.wrap.v1|" ‖ purpose)
aad      = domainSeparated("snip.wrap.v1", [ "v1", purpose_utf8, kid_utf8 ])
wrapText = SnippetCrypto.seal(K_lib_bytes, key = wrapKey, aad)       // §2.2, 383 chars
```

- `purpose` raw values: `recovery` (the only one a shipping path writes) and `cli` (reserved).
- `material.count >= 16`, otherwise `materialTooShort`. Empty salt is `invalidParameters`.
- Unwrap maps `authenticationFailed` to `wrongKey(purpose)`; any other structural error keeps its
  own type. The recovered plaintext must be exactly 32 bytes.
- The recovery door is 128 bits strong, not 256 (`KeyWrap.swift:26-35`).

### 2.6 Passphrase wrap (`PassphraseKDF`)

`PassphraseKDF.swift:122-280`. Used today only by the encrypted backup (to wrap its export key);
`vault.json` reserves the fields but no UI writes `wrapPass`.

```
pw       = UTF-8( NFC(passphrase) )                       // must be non-empty
wrapKey  = PBKDF2-HMAC-SHA512(pw, salt, iterations, dkLen = 32)
aad      = domainSeparated("snip.kdf.v1",
             [ alg_utf8, u64be(iterations), salt_bytes, kid_utf8 ])
envelope = SnippetCrypto.seal(key32, key = wrapKey, aad)
WrappedKey = { "alg": "pbkdf2-hmac-sha512", "iterations": 600000,
               "salt": b64url(salt16), "envelope": envelope }
```

- `salt` in the AAD is the decoded bytes, not the base64url text.
- Unwrap: `alg` must equal `pbkdf2-hmac-sha512` (`unsupportedAlgorithm`), salt must be valid
  non-empty base64url, `1 <= iterations <= 20_000_000`. `authenticationFailed` becomes
  `wrongPassphrase`. Result must be 32 bytes.
- For the backup, `kid` is the `backupID`; for a vault it would be the vault `kid`.

### 2.7 `K_sync` material and the portable key bundle

- Material: `key(32) ‖ salt(32)` = 64 bytes (`SyncKeyStore.swift:56-59`, `:241-249`;
  `GitSyncKeyStore.swift:131-135`). The keyring is `Keyring(libraryKey: material[0..<32],
  salt: material[32..<64])`.
- `PortableKeyBundle` (`LibraryKeyBootstrap.swift:36-87`) is the JSON that recovery envelopes carry:
  compact, keys sorted, slashes not escaped:

```
{"key":"<b64std 32 bytes>","salt":"<b64std 32 bytes>","schemaVersion":1,"scopeID":"sync-v1"}
```

  Reader: at most 2 048 bytes, exactly these four keys, `schemaVersion == 1`,
  `scopeID == "sync-v1"`, both values canonical padded base64 of 32 bytes.

### 2.8 Recovery key / recovery code text

`RecoveryKey.swift`. The same format is used for the vault recovery key and the Git library
recovery code.

- 16 bytes become 26 payload symbols (big-endian bit stream, 5 bits per symbol; the 26th symbol
  holds the last 3 bits in its high bits, low 2 bits zero), plus 1 check symbol: 27 symbols.
- Alphabet (index = value): `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (`:61`).
- Check symbol: `sum over i in 0..<26 of (2*i + 1) * symbol[i]`, modulo 32 (`:195-201`).
- Canonical form: 27 uppercase characters, no separators. Display form: groups of 4 joined by `-`,
  last group 3 characters: `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX` (`:118-125`).
- Decode normalisation (`:163-178`): uppercase the whole string, then drop space, tab, LF, CR,
  U+00A0, `-`, U+2010, U+2011, U+2012, U+2013, U+2014, U+2212 and `_`; map `I` and `L` to `1`,
  `O` to `0`. Then require exactly 27 characters (`wrongLength`), each in the alphabet
  (`invalidCharacter`, so `U` is rejected), the check symbol to match (`checksumMismatch`), and
  the two spare bits of symbol 26 to be zero (`nonCanonical`).
- Errors are distinct on purpose: a typo is reported as a typo, not as a wrong key.

### 2.9 Canonical JSON (`CanonicalJSON`)

`SyncEnvelope.swift:44-62` (rules), `:137-201` (emitter), `:261-474` (parser). These bytes are
hashed and sealed, so they must be reproduced exactly.

Emitter:

1. No whitespace.
2. Object keys sorted by their UTF-8 bytes (unsigned lexicographic). This is code-point order, not
   UTF-16 order: do not sort Kotlin `String`s with `compareTo`.
3. Strings: `"` becomes `\"`, `\` becomes `\\`, 0x08 `\b`, 0x09 `\t`, 0x0A `\n`, 0x0C `\f`,
   0x0D `\r`, any other byte below 0x20 becomes `\u00xx` with lowercase hex. Everything else,
   including `/`, 0x7F, U+2028 and all non-ASCII, is emitted as raw UTF-8. Invalid UTF-8 is an
   error (`invalidUTF8`); the validator rejects over-long forms, surrogates and values above
   U+10FFFF (`:209-241`).
4. `int`: `Int64` decimal. `double`: Swift `Double.description`; non-finite is an error.
5. `null`, `true`, `false` literals. Arrays keep their order.

Swift `Double.description`, as mirrored by `snippets-linux/src/canonical.rs:162-216` and pinned by
`snippets-linux/tests/fixtures/swift-double-v1.tsv` (11 903 cases):

- Take the shortest decimal digit string that round-trips (digits `d1 d2 … dn`, decimal exponent
  `order` such that the value is `d1.d2…dn × 10^order`).
- Zero prints `0.0` or `-0.0`.
- If `order < -4` or `|value| > 2^53` (9 007 199 254 740 992): scientific form
  `d1[.d2…dn]e±XX`, exponent sign always present, at least two exponent digits
  (`1e-05`, `1e+16`, `5e-324`, `1.7976931348623157e+308`).
- Otherwise fixed form with at least one digit on each side of the point (`1.0`, `0.0001`,
  `1000000000000000.0`, `123.25`).

Parser (used when opening an envelope):

- Whitespace allowed between tokens is space, tab, LF, CR. Trailing bytes after the top-level value
  are an error. Nesting deeper than 32 is an error (`maximumDepth`, `:117`).
- Every string value is returned as bytes (`utf8`), never as a `String`. Raw bytes below 0x20 inside
  a string are an error. Escapes accepted: `\" \\ \/ \b \f \n \r \t \uXXXX` (either hex case),
  surrogate pairs must be complete and ordered; a lone surrogate is an error.
- Numbers are strict JSON (no leading `+`, no leading zeros, digits required after `.` and after
  the exponent). A token with `.` or an exponent is a double. Otherwise it is an `Int64`, falling
  back to a double when it overflows.
- Duplicate object keys are an error. Swift compares keys with canonical equivalence, so two keys
  that differ only in Unicode normalisation count as duplicates (`:57-62`, `:315`).

### 2.10 Sync envelope, its hash, `rev`, and the wire record

`SyncEnvelope.swift:777-1251`. The plaintext inside every wire blob is one canonical JSON object with
exactly ten keys (`topLevelKeys`, `:823-826`):

| Key | Type | Value |
|---|---|---|
| `schemaVersion` | int | `1` (`currentSchemaVersion`, `:779`) |
| `id` | string | `lower(id)` |
| `hlc` | string | HLC text, for example `019face339f4-0003-aabbccdd` |
| `origin` | string | eight lowercase hex characters (device id) |
| `secure` | bool | record belongs in the vault |
| `deleted` | bool | tombstone |
| `hash` | string | envelope hash, see below |
| `contentHash` | string or null | `hex(SHA-256(fields.content bytes))`; `null` for a tombstone |
| `fields` | object or null | eight keys, below; `null` for a tombstone |
| `x` | object | extension bag, preserved verbatim |

`fields` has exactly these keys (`:834-837`, `:906-928`): `name` string, `keyword` string,
`content` string (the body bytes emitted as a JSON string), `tags` array of strings, `isEnabled`
bool, `isPinned` bool, `createdAt` double, `updatedAt` double. Dates are seconds since
2001-01-01T00:00:00Z as an IEEE double (`timeIntervalSinceReferenceDate`), emitted with the
`Double.description` rule. Converting through milliseconds or `Instant` loses bits and changes the
hash; keep the double.

```
envelopeHash = hex( SHA-256( canonical(object without the "hash" key) ) )     // nine keys
blobPlain    = canonical(object with "hash")                                  // ten keys
rev          = envelopeHash[0..<32]                                           // first 32 hex chars
blob         = UTF-8( SnippetCrypto.seal(blobPlain, K_rec(id) from K_sync,
                     aad for scope "sync-v1", id, deleted) )                  // §2.3
WireRecord   = { id, rev, deleted, blob, recordVersion? }                     // clear-text beside blob
```

`:1099-1134`, `:651-653`, `:672-712`, `:1382-1387`. `rev` is not in the AAD; it is checked after
opening. `WireIdentity.associatedData()` (`:604-610`, a canonical JSON AAD) exists for the protocol
seam but the shipping sealer does not use it: do not port it into the AAD.

Opening (`WireCodec.open`, `:1396-1412`, and `SyncEnvelope.parse`, `:1152-1250`), in order:

1. Blob must be UTF-8 text; open it with §2.3 (AEAD binds id, scope and the deleted flag).
2. Parse canonical JSON; must be an object.
3. `schemaVersion` must be an integer. If it is greater than 1: `tooNew(version)`, checked before
   anything else so a newer record is not reported as corrupt.
4. Any top-level key outside the ten is `malformed` (never silently stripped).
5. `id` parses as a UUID; `hlc` parses; `origin` is exactly eight lowercase hex characters;
   `secure`, `deleted` are booleans; `hash` is a string; `x` is an object.
6. `x["userDeletion.v1"]`, when present, requires `deleted == true` and an array of 1 to 8 unique
   lowercase 64-hex strings.
7. `fields` is null or an object with no unknown keys and all eight members with the right types
   (`createdAt`/`updatedAt` accept an integer token as a number). A tombstone must have
   `fields == null` and `contentHash == null`; a live record must have `fields`.
8. Recompute the envelope hash from the parsed values (parsed values are not re-normalised:
   tags and origin are taken as they are, `:886-904`, `:1047-1068`) and compare with `hash`;
   recompute `contentHash` and compare. Mismatch is `hashMismatch`.
9. `envelope.id == record.id`, `envelope.deleted == record.deleted`,
   `rev == envelopeHash[0..<32]`; otherwise `identityMismatch`.

Constructing a new envelope (not parsing) normalises `origin` with `HLC.normalizedDevice`, tags
with `SnippetTagging.normalizedTags`, forces `fields = nil` for a tombstone and removes
`userDeletion.v1` from a live record (`:1020-1045`). `tombstoned(hlc:origin:)` drops the whole `x`
bag except `vaultKID` on a secure record (`:1342-1350`).

### 2.11 `Vault/vault.json` (`VaultDocument`)

`VaultDocument.swift:229-760`. Written with Foundation's `JSONEncoder` using `.prettyPrinted` and
`.sortedKeys` (`:922-934`). The bytes are local to the device and are not hashed by any protocol,
so Kotlin needs field-level compatibility, not byte equality (but see hazard H7 for the
compare-and-swap write loop).

Document keys. Required on read: `schemaVersion`, `kid`, `vaultSalt`, `kdf`, `records`. The three
wraps may be absent or `null` (`:658-661`; the comment at `:632-638` calls two of them required,
the code is the authority). Unknown keys are kept in the `x` bag and re-emitted at the same level:

| Key | Type | Notes |
|---|---|---|
| `schemaVersion` | int | `1`. A file with a larger value is `tooNew`: show, never write (`:976-978`, `:1077-1081`). |
| `kid` | string | `"k-"` + first 12 characters of a lowercase UUID string, for example `k-7f3a91c0-1b2` (`SecureSnippetStore.swift:689-691`). Treat as opaque. |
| `vaultSalt` | string | `b64url` of 32 bytes |
| `kdf` | object | `alg` (`pbkdf2-hmac-sha512`), `iterations` (600000), `saltP` (`b64url`, 16 bytes), plus its own passthrough keys (`:684-700`) |
| `wrapPass` | string or null | always written, as `null` today (no UI creates a passphrase wrap) |
| `wrapRecovery` | string or null | §2.5 with purpose `recovery` |
| `wrapCLI` | string or null | reserved; written as explicit `null` |
| `records` | array | required; a missing array is a decode failure, never "empty vault" |
| `local.syncConflictC0Receipts.v1` | object | device-local, in the `x` bag: `{ "<64 hex envelope hash>": "<lowercase uuid>" }` (`:242-243`, `:338-365`). Never exported, never shared. |

Record keys (`:705-760`): `id` (UUID string; Foundation writes it uppercase, readers accept either
case), `name`, `keyword`, `tags`, `isEnabled`, `isPinned`, `createdAt`, `updatedAt`, `hlc` (HLC
string), `contentHash` (§2.4, may be `""`), `sealed` (§2.2 text), plus passthrough keys in the
record's `x` bag (`conflictCopy.v1`, `contentConflictOpaque.v1.<fingerprint>`, anything newer).

- Read leniency: only `id` and `sealed` are required. Any other field that is missing or has the
  wrong type takes a default: `name ""`, `keyword ""`, `tags []` (then normalised), `isEnabled
  true`, `isPinned false`, `contentHash ""`, `createdAt = updatedAt ?? distantPast`,
  `updatedAt = createdAt`, `hlc = HLC.foreign(updatedAt:)` (`:710-742`).
- Timestamps in `vault.json` are ISO-8601 UTC strings with milliseconds
  (`2026-07-29T08:00:00.500Z`); the reader also accepts whole seconds (`:890-916`). This differs
  from the wire (doubles) and from the backup payload (hazard H2).
- Passthrough values round-trip by value: `1.0` may come back as `1`, integers beyond `Int64`
  become doubles (`:31-34`).
- Metadata-only load for listing never reads `kdf` or the wraps and never refuses a newer file
  (`:773-797`, `:989-1004`).

### 2.12 `keys/recovery.json` (Git library recovery envelope)

`GitSyncRecovery.swift:61-120`, mirrored by `snippets-linux/src/git_recovery.rs`.

```
aad        = "snippets-git-recovery-v1" ‖ 0x00 ‖ lower(datasetID)
key        = HKDF(ikm = secret16, salt = "snippets-git-recovery-salt-v1", info = aad)
plaintext  = PortableKeyBundle JSON (§2.7)                       // no padding
combined   = nonce(12) ‖ AES-256-GCM(key, nonce, plaintext, aad) ‖ tag(16)
file bytes = Foundation JSON, [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes], then "\n":

{
  "algorithm" : "snippets-git-recovery-hkdf-sha256-aes256gcm-v1",
  "ciphertext" : "<b64std(combined)>",
  "datasetID" : "<lower(datasetID)>",
  "schemaVersion" : 1
}
```

The exact framing (two-space indent, `" : "` separators, final newline) is what Rust emits by
string formatting (`git_recovery.rs`, comment "Foundation's `[.sortedKeys, .prettyPrinted,
.withoutEscapingSlashes]`"); match it.

Reader: file at most 8 192 bytes; a JSON object with exactly the four keys; `schemaVersion == 1`
(integer); `algorithm` equal; `datasetID` equal to the expected library's; `ciphertext` canonical
`b64std` of at least 28 bytes. AEAD failure is `incorrectCode`; every structural failure is
`invalidEnvelope`; a code that does not parse is `invalidCode`. The opened bundle is validated as
in §2.7.

### 2.13 `keys/vault.json` (Git library vault file)

`GitSyncVault.swift:104-203`, mirrored by `snippets-linux/src/git_vault.rs`.

```
aad       = "snippets-git-vault-v1" ‖ 0x00 ‖ lower(datasetID)
key       = HKDF(ikm = material[0..<32], salt = material[32..<64], info = aad)
plaintext = compact JSON, keys sorted, slashes not escaped:
  {"kdf":{"alg":"…","iterations":600000,"saltP":"…"},"kid":"…","schemaVersion":1,
   "vaultSalt":"…","wrapRecovery":"v1.….…"}
combined  = nonce(12) ‖ ct ‖ tag(16)
file      = same four-key pretty framing as §2.12 with
            "algorithm" : "snippets-git-vault-hkdf-sha256-aes256gcm-v1"
```

- `wrapRecovery` is §2.5 (purpose `recovery`) of the vault key under the **library's recovery
  code** bytes, salt `vaultSalt`, bound to `kid`.
- Well-formedness, enforced by writer and reader (`:84-101`): `kid` 1...128 bytes; `vaultSalt`
  decodes to exactly 32 bytes; `kdf.alg` 1...64 bytes; `kdf.iterations` in 1...100 000 000;
  `kdf.saltP` 1...128 bytes and valid base64url; `wrapRecovery` 1...1 024 bytes. Every text field
  is printable ASCII 0x21...0x7E without `"` and `\`.
- Reader: at most 8 192 bytes. Probe `schemaVersion` first: greater than 1 is `unsupportedVersion`
  and the file must never be replaced by this build. Then exactly four outer keys; values as in
  §2.12. AEAD failure is `incorrectKey`. Inner object must have exactly `kdf`, `kid`,
  `schemaVersion`, `vaultSalt`, `wrapRecovery`, and `kdf` exactly `alg`, `iterations`, `saltP`.
- Never published: `wrapPass`, `wrapCLI`, any `x` extension (`docs/git-sync.md:595-596`).

### 2.14 Encrypted backup file (`.snippetsbackup`)

`EncryptedSnippetBackup.swift`. One JSON object (pretty, sorted keys; formatting is not
authenticated, field values are):

```
{
  "backupID": "b-<lowercase uuid>",
  "format": "com.khm.snippets.encrypted-backup",
  "payload": "<envelope text §2.2>",
  "schemaVersion": 1,
  "wrappedKey": { "alg": "pbkdf2-hmac-sha512", "envelope": "<§2.6>",
                  "iterations": 600000, "salt": "<b64url 16 bytes>" }
}
```

```
exportKey      = 32 random bytes
wrappedKey     = PassphraseKDF.wrap(exportKey, passphrase, salt16, kid = backupID)      // §2.6
payloadAAD     = domainSeparated("snip.backup.payload.v1",
                   [ "com.khm.snippets.encrypted-backup", u64be(schemaVersion), backupID_utf8,
                     wrappedKey.alg_utf8, u64be(wrappedKey.iterations),
                     wrappedKey.salt TEXT utf8, wrappedKey.envelope TEXT utf8 ])
payload        = SnippetCrypto.seal(payloadJSON, key = exportKey, aad = payloadAAD)
vaultWrapKey   = HKDF(exportKey, salt = vaultSalt,
                   info = "snip.backup.vault-key.v1|" ‖ backupID ‖ 0x00 ‖ kid)
vaultKeyAAD    = domainSeparated("snip.backup.vault-key-aad.v1", [ "v1", backupID_utf8, kid_utf8 ])
wrappedVaultKey= SnippetCrypto.seal(K_lib_bytes, key = vaultWrapKey, aad = vaultKeyAAD)
```

`:272-311`. Note that the payload AAD uses the salt and envelope as their **text** (unlike §2.6,
which uses the salt bytes).

Payload JSON (`:67-72`), sealed with padding like any other body:

```
{ "schemaVersion": 1,
  "snippets": [ <Snippet> … ],            // ordinary library records, nine keys each
  "vault": <VaultDocument> | absent,      // whole document: kid, salt, kdf, wraps, records
  "wrappedVaultKey": "<envelope>" | absent }
```

- Swift omits `vault` and `wrappedVaultKey` when there is no vault (synthesized `Codable`); Rust
  writes them as `null`. Accept both.
- Dates inside the payload: Swift encodes with a plain `JSONEncoder`, so `Snippet.createdAt`,
  `updatedAt` and also the **vault records'** `createdAt`/`updatedAt` are JSON numbers (seconds
  since 2001). The Rust writer and the Python reference fixture write the vault records' dates as
  ISO strings. See hazard H2; this needs a decision before the Kotlin writer is fixed.
- `local.syncConflictC0Receipts.*` is stripped from the exported vault and again on import
  (`SecureSnippetStore.swift:2252-2255`, `:2279`).
- The Linux reader rejects unknown keys in the container, in `wrappedKey` and in the payload
  (`snippets-linux/src/backup.rs:19-44`); write exactly the keys shown.

Open (`:171-264`): empty passphrase is `emptyPassphrase`; not JSON or wrong `format` is
`invalidFormat`; `schemaVersion != 1` is `unsupportedSchemaVersion`; empty `backupID` is
`invalidPayload`; a failing passphrase unwrap is `wrongPassphrase`; any other unwrap problem
(unknown `alg`, bad salt, iteration count out of range) is `invalidFormat`; every later
authentication or decode failure is `damagedBackup`. After decoding, the library is validated
(below), the vault key is unwrapped and **every** record is opened and its content hash checked
(`:353-374`) before anything is returned.

Library validation, on seal and on open (`:313-351`): no duplicate ids across ordinary and secure
records; no duplicate non-empty keyword after `Snippet.sanitizedKeyword` and
`SnippetTagging.filterKey` (case and diacritic folding, see the library brief); vault
`schemaVersion <= 1`; a vault with zero records must be omitted, not included.

---

## 3. Vault model

### 3.1 Where things live

Correction to a common assumption: a secure snippet has **no** row in the ordinary library.
`snippets.json` never contains it, not even with empty content (`docs/cloud-sync.md:316-319`). Its
metadata (name, keyword, tags, flags, timestamps, HLC) and its sealed body both live in
`Vault/vault.json`. The rest of the app sees secure snippets as *shells*: ordinary `Snippet` values
with `content == ""` produced by `VaultRecord.shell` (`VaultDocument.swift:596-618`) and handed out
through `SecureSnippetProviding` (`SecureSnippetProviding.swift`). The list, search and keyword
collision checks merge shells with ordinary snippets; export, share links, undo and auto-expansion
only ever see the ordinary array, which is the structural guarantee
(`SecureSnippetStore.swift:504-513`).

Files under the support root:

| Path | Content |
|---|---|
| `Vault/vault.json` | the document, §2.11, mode 0600, atomic writes |
| `Vault/Quarantine/vault-<yyyyMMdd-HHmmss>[-n].json` (+ `.txt` note) | a vault that could not be decoded, moved aside, never deleted (`VaultDocument.swift:1185-1252`) |
| library lock file | one lock covers `snippets.json` and `vault.json` (`VaultDocument.swift:1044-1047`) |

Load outcomes (`VaultLoadOutcome`, `VaultDocument.swift:838-876`): `loaded`, `missing` (the only
state in which creating a vault is allowed), `tooNew(version)` (read-only), `unreadable` (I/O;
change nothing, retry), `corrupt` (quarantine; never overwrite). There is deliberately no "fresh"
outcome. `SecureSnippetStore.reload` maps the last three to `isUnreadable = true`, which blocks
every write (`SecureSnippetStore.swift:304-347`).

Writes: every change goes through `VaultFile.update` (`VaultDocument.swift:1051-1105`): take the
library lock (timeout 2 s, `SecureSnippetStore.swift:254`), re-read the file inside the lock, apply
a side-effect-free transform, refuse `schemaVersion > 1`, compare the file bytes with what was read,
write atomically, verify the bytes on disk are the ones written, retry up to 8 times.

Schema versions and migrations: only schema 1 exists. Additive fields go into the `x` bags and are
preserved by older builds. One repair runs on load: `healLegacyPlainSyncMetadata`
(`SecureSnippetStore.swift:393`) removes a plaintext projection envelope that an old promotion
build left in the sync sidecar. A new Android install has nothing to heal but must preserve unknown
keys at all three levels (document, `kdf`, record).

### 3.2 What works locked and what needs the key

| Operation | Needs `K_lib` | Pointer |
|---|---|---|
| List, search, keyword uniqueness, rename, retag, enable, pin | no | `updateMetadata`, `:1434-1449` |
| Delete a secure snippet | no | `delete`, `:1454-1458` |
| Sync (upload and download of secure records, merges) | no | §4 |
| Read body, edit body, add a secure snippet, promote, demote | yes | `contentData`, `setContent`, `addSecure`, `promote`, `demote` |
| Materialise a secure conflict copy | yes, but only an already-open session, without extending it | `unlockedKeyringForSync`, `:2474-2480` |
| Export an encrypted backup that contains secure records | yes, fresh authentication every time | `makeEncryptedBackup`, `:1469-1505` |

Every body write updates `sealed`, `contentHash`, `updatedAt` and `hlc` together (`:1416-1431`).
`addSecure` requires a non-empty sanitised keyword and a UTF-8 body, and checks keyword uniqueness
against both files inside one transaction (`:1385-1414`).

### 3.3 Vault creation and the recovery key

`SecureSnippetStore.swift:613-737`.

1. `prepareVaultCreationIfNeeded()` returns `nil` when a vault already exists and its key is on
   the device (after `requireUsableKey`), otherwise a `PendingVaultCreation` holding a fresh
   16-byte recovery key and its display text. Nothing is stored yet.
2. The UI shows the code once and commits only on an explicit acknowledgement; cancelling leaves
   nothing behind (`setupCancelled`).
3. `commitVaultCreation` re-checks that no vault appeared meanwhile (`setupChanged`), then
   `createVault`: generate `K_lib` and `vaultSalt`; mint `kid`; `wrapRecovery = KeyWrap.wrap(...)`;
   **store the key first**, then write `vault.json` with fresh KDF parameters and
   `wrapPass = wrapCLI = null`; if the file write fails, delete the key again.
4. While **Git is the selected provider nothing here may mint a vault**:
   `existingVaultForCreation` throws `libraryVaultSetupRequired` (`:682-686`), and a vault whose key
   is missing reports `libraryVaultSetupRequired` instead of `sharedVaultKeyMissing` (`:581-586`).
5. Older vaults without a recovery wrap: `prepareRecoveryKeyAddition` /
   `commitRecoveryKeyAddition` add one while unlocked (`:754-803`).
6. Restore: `restoreKey(fromRecoveryKey:)` decodes the text, unwraps `wrapRecovery` (authenticated
   against `kid`), stores the key, re-adopts the session (`:808-823`). A typo can never replace a
   good key.

The recovery key is shown once and never stored. On macOS it is copied only with concealed
pasteboard markers; on iOS as local-only and expiring (repository `AGENTS.md`).

### 3.4 Session: lock, unlock, timeouts

`VaultSession.swift`. Confirmed constants: idle window **5 minutes** (`defaultDuration`, `:64`),
absolute ceiling **30 minutes** from the authentication (`maximumWindow`, `:68`).

- States: `noKey` (no key for this `kid` on the device), `locked`, `unlocked(until:)`.
- `unlock(reason:)` (`:208-277`): if already unlocked and not expired, slide the window and return
  the key. Otherwise evaluate device-owner authentication (`LAPolicy.deviceOwnerAuthentication`,
  biometrics or device passcode, reuse duration 0, `:226-243`), then read the key from the Keychain.
  A second caller while a prompt is up gets `locked` (prompts are never stacked, `:224`).
- Window (`extendWindow`, `:454-491`): `deadline = min(now + 5 min, authenticatedAt + 30 min)`.
  A one-shot timer locks at the deadline; in addition **every key access re-checks the stored
  deadline** (`:376-403`), because a timer can be late.
- `currentKey()` slides the idle window (user-facing use). `currentKeyWithoutExtendingSession()`
  does not (background sync) (`:364-374`).
- `withOneUseAuthentication(reason:operation:)` (`:285-300`): lock, authenticate freshly, run one
  synchronous operation, lock again on every exit. Used for secure copy/expansion, backup export
  and import, publishing a vault to a Git library, re-sealing.
- `lock()` (`:418-451`): first posts `snippetsVaultWillLock` while the key is still usable, so an
  open editor can flush a pending edit synchronously; then drops the key, the authentication
  context and the timer; then posts `snippetsVaultStateChanged`, on which every screen hides
  revealed plaintext.
- Lock triggers: the deadline; iOS `UIApplication.didEnterBackgroundNotification` (`:538-544`);
  macOS sleep, session resign, screen lock, screensaver. Explicitly **not** resign-active
  (`:513-515`).
- `adopt(keyID:)` re-points the session when the vault is created, reloaded or replaced; a changed
  or missing key id locks; the same id with the key present leaves an open session alone
  (`:127-148`). iOS checks key presence off the main thread (`checksKeychainInBackground`).

### 3.5 Reveal, edit and copy on iPhone/iPad

Sources: `snippets-ios/SecureSnippetReveal.swift` (policy), `SecureUIKit.swift` (text view, notice,
pasteboard helpers), `SecureSnippetCaptureRenderer.swift`, `SnippetActionService.swift`,
`PhoneSnippetEditorViewController.swift` ("Phone"), `SnippetEditorViewController.swift` ("iPad").
There is no auto-lock setting, no biometrics toggle and no app-wide app-switcher cover. Exact UI
strings are in the UX inventory; only behaviour is listed here.

| Action | Authentication | Reason string | Pointer |
|---|---|---|---|
| Reveal body in the editor | `unlock`: no prompt inside an open 5/30-minute session | `Reveal “<name>”` | Phone:1178, iPad:1309 |
| Copy a secure snippet | one-use: always prompts, locks before and after | `Copy <displayName>` | `SnippetActionService.swift:96-127` |
| Make secure (promotion) | `unlock` | `Make this snippet secure` | Phone:1063-1110 |
| Make ordinary (demotion), after a destructive confirmation | one-use | `Make this secure snippet ordinary` | Phone:1112-1143 |
| Add recovery key | one-use | `Create and display a recovery key` | `SettingsViewController.swift:1504-1518` |
| Backup export with secure records; import into an existing vault | one-use | §5 | `SecureSnippetStore.swift:1482-1484`, `:1573-1575` |

A one-use authentication ends any open reveal session, because it locks first.

Reveal policy (`SecureSnippetReveal.swift:15-185`): states `ordinary`, `locked`, `authenticating`,
`authenticatedRedacted`, `presentingPlaintext`, `protectedPlaintext`, `failedClosed`. Generation
tokens discard a stale authentication result. Plaintext may be shown only while the app and scene
are active, no screen capture is active and the protected renderer is healthy; editing is allowed
only in `protectedPlaintext`. Reveal sequence (Phone:1227-1295): re-check the environment, read
the body, arm the protected presentation, put the text in the view, wait for the renderer to
confirm. Any failure returns to `locked` and redacts.

| What hides the body again | Effect | Pointer |
|---|---|---|
| Session deadline or Lock Now | pre-lock hook saves the pending edit, then redact and clear | Phone:1619-1637 |
| App enters background | vault session locks | `VaultSession.swift:538-544` |
| App or scene resigns active | the editor's reveal policy locks and redacts; the vault session stays open; an in-flight Face ID prompt is preserved. Returning does not re-reveal: the user taps Reveal again, without a prompt if the session is still open | Phone:1639-1694 |
| Leaving the editor; iPad selection change; any modal (alert, share, copy) | reveal policy locks first | Phone:107-116, `:1337-1351`; iPad:312-321 |
| Screen capture, recording or mirroring | forced redaction, with an explanatory overlay | `SecureUIKit.swift:126-130`, `:1004-1019` |
| Protected renderer fails or the display is not protected | fail closed | `SecureSnippetCaptureRenderer.swift:88-106` |
| Record removed while open | clear and re-arm redacted | Phone:597-620 |

Capture protection on iOS draws the visible text into a capture-protected video layer and hides
the real text view's layer (`SecureSnippetCaptureRenderer.swift:38-44`, `SecureUIKit.swift:1040-1050`).
Android gets the same result from `FLAG_SECURE` (§7.4); the ordering rules still apply.

Editing: body saves are debounced 0.3 s and flushed on end-editing, disappear, pre-lock and
deactivation (Phone:1368-1383, `:1794-1816`); each save calls `setContent`. There is no secure
draft buffer. Metadata edits and delete work while locked. The secure text view blocks copy and
cut, allows only delete, paste, select and select all, and disables autocorrect, spell check,
smart punctuation, Writing Tools, find, drag and undo (`SecureUIKit.swift:101-106`, `:339-357`,
`:1098-1114`). Third-party keyboards are refused app-wide (`snippets-ios/AppDelegate.swift:85-98`).
Share and Duplicate are not offered for secure snippets (Phone:817-822).

Copy (`SnippetActionService.swift:12-27`, `:53`, `:96-127`):

- Ordinary: plain write to the general pasteboard.
- Secure: fresh one-use authentication; the plaintext moves into a `SecurePlaintextLease`;
  placeholders are resolved; an empty result is reported and nothing is copied; otherwise one
  UTF-8 plain-text item with `localOnly = true` and `expirationDate = now + 60 s`
  (`secureClipboardLifetime = 60`, confirmed). The lease and the intermediate strings are cleared
  on every exit. Nothing clears the clipboard explicitly; expiry is the system's. The toast says
  the secure clipboard expires in 60 seconds.
- Other clipboard lifetimes: vault recovery key 5 minutes, local-only
  (`SecureUIKit.swift:1236-1255`); Git recovery code 120 s, local-only
  (`snippets-ios/GitSyncSettingsViewController.swift:1307-1309`).

Setup UI: no wizard. The first "make secure" shows the recovery key in an alert with "Copy &
Continue", "I’ve Saved It" and "Cancel" (Phone:1145-1163); no typed confirmation. With Git selected
the same action reports `libraryVaultSetupRequired` and the Git settings own the recovery-code
sheet, which hides itself when the app resigns active. Settings, Secure Snippets pane
(`SettingsViewController.swift:570-604`): status, key-storage line and, when a vault exists, Lock
Now, Add Recovery Key (only without a recovery wrap), Restore with Recovery Key, Remove Secure
Snippets from This Device (refused while sync is on).

Promotion and demotion on iOS run through `SecureSnippetTransitionCoordinator`
(`snippets-ios/SecureSnippetTransitionCoordinator.swift`): flush pending ordinary writes, run the
move with change notification off, reload both in-memory stores, then publish one change, so the
UI and sync never observe a duplicated or missing record. Android has no file observer either and
needs the same sequencing.

Accessibility on iOS: the secure body view and its subtree are excluded from the accessibility
tree for the whole secure session, including while shown; a separate metadata-free element states
only whether the body is hidden, being prepared or shown
(`docs/ios-secure-accessibility-protection.md`, `SecureUIKit.swift:1167-1234`). Screen readers and
UI automation cannot read or edit a secure body; metadata fields stay accessible.

### 3.6 Promotion and demotion

`SecureSnippetStore.swift:1614-1739`, inside one `LibraryTransaction` over both files (library
brief): destination written before the source is removed, with a crash marker
(`promoting(id)` / `demoting(id)`), so an interruption duplicates and never loses.

- Promote (needs the key): seal the body under `K_rec(id)` with the vault `kid`; keep the same id,
  `createdAt`, tags and flags; `name` is the explicit name only (never the display-name fallback,
  which is derived from content); `keyword` normalised; `updatedAt = now`; new HLC stamped above
  the source's. The secure sync envelope (ciphertext body, `vaultContentHash`, `vaultKID`) is
  written to the sync sidecar **before** the move.
- Demote (needs the key): decrypt the record as read inside the transaction; insert the plaintext
  snippet at index 0 with `updatedAt = now`. The sidecar is pre-written with the **secure source**,
  never with the plaintext destination. Refused when the record's `x` bag holds keys this build
  does not understand (`supportsDemotion`, `:1836`).

### 3.7 Replacing the vault key (`resealVault`)

`SecureSnippetStore.swift:1289-1362`. The only way a vault's key ever changes. One
`VaultFile.update`:

1. If the file already names the target identity, return (idempotent retry).
2. Require the file to still name the source `kid` and salt.
3. For every record: open with the old keyring and old `kid`, seal with the new keyring and new
   `kid` (fresh nonce), recompute `contentHash` under the new key.
4. Set `kid`, `vaultSalt`, `kdf` from the new identity; set `wrapRecovery` to the library's wrap;
   clear `wrapPass` and `wrapCLI`; remove the local conflict receipts.
5. Afterwards delete the old key **only** from a device-only store (`:1355-1360`).

Preconditions (`checkCanReseal`, `:1152-1165`, `hasUnresolvedSecureConflicts`, `:1265-1285`): every
record opens under the old key, and no secure conflict is pending anywhere (record `x` bags, sync
sidecar, journal); anything unreadable counts as pending. Callers: `commitVaultRotation` (this
device rotates a Git library's keys) and `resealIntoLibraryVault` (this device follows its library
to the one that replaced it). A device vault that is in use is never re-pointed any other way.

### 3.8 Keychain inventory and the Android question each item raises

`KeychainSecretStore.swift`. Generic-password items, told apart by service and account. Apple has
two tiers chosen at run time (`:145-164`): device-only, or synchronizable through iCloud Keychain in
the shared access group. Device-owner authentication is an app-level gate in `VaultSession`, not an
item attribute (`:59-63`).

| Item | Service / account | Bytes | Accessibility | Synchronizable on Apple | Android consequence |
|---|---|---|---|---|---|
| Vault key `K_lib` | `com.khm.snippets.vault` / the vault `kid` | 32 raw | WhenUnlocked | yes when entitled | Device-only on Android. Obtained by creating the vault, by a recovery key/code, or by a backup import. Read only after user authentication. |
| Vault identity | `com.khm.snippets.vault` / `vault-identity` | `vault.json` without records, without `wrapPass`, without local receipts (`VaultIdentityStore.swift:102-170`) | WhenUnlocked | yes; used only when iCloud is the provider (`SecureSnippetStore.swift:213`) | Does not exist on Android. Its job (stop a second device minting a rival `kid`) is done by `keys/vault.json` for Git. Nothing replaces it for other providers (open question Q3). |
| iCloud wire key | `com.khm.snippets.vault` / `sync-v1` | 64 | AfterFirstUnlock | yes | Not used on Android (no iCloud provider). Android must never mint a `sync-v1` key by this path. |
| Git library key | `com.khm.snippets.git-sync` / `git-library-v1-<32 hex>` | JSON record, §6.2 | AfterFirstUnlock | yes when entitled | Device-only. Obtained by creating the library or from `keys/recovery.json` + code. Readable in the background without user presence. |
| Snippets Cloud library root | Cloud service / `sync-v1` | JSON record bound to server, space, instance, protocol (`SyncKeyStore.swift:291-298`) | AfterFirstUnlock | never | Device-only; obtained by pairing or the recovery kit (Cloud brief). |
| Git token, SSH device key, SSH host keys | other services (Git brief) | — | — | — | Git brief. |

Store semantics worth keeping (`KeychainSecretStore.swift`): replace-in-place without a
delete-first window (`storeItem`, `:203-226`); add-if-absent returns the incumbent (`:237-265`);
length is validated before any migration write (`:281-319`); `hasItem` answers "present" on a store
error so a locked store is never read as "no key" (`:339-350`); the vault key must be exactly 32
bytes (`:462-480`).

Forget (`forgetEverything`, `:1854`): only with sync off and quiescent; removes local records; a
device-only key and identity are deleted last, a synchronizable key is deliberately kept. On
Android every key is device-only, so forgetting deletes the key; the confirmation must say the
bodies are unrecoverable unless another device or a backup holds them.

---

## 4. Sync of secure records

### 4.1 Double sealing

A secure record's envelope (`SyncLibraryProjection.swift:88-183`) has `secure = true` and
`fields.content` = the UTF-8 bytes of `VaultRecord.sealed` (the `v1.….…` text), **verbatim**. The
envelope's top-level `contentHash` is therefore SHA-256 of ciphertext text. The `x` bag carries:

- `vaultContentHash`: the vault's keyed HMAC (§2.4), omitted when the record's hash is empty;
- `vaultKID`: the `kid` of the vault that sealed the body.

The whole envelope is then sealed again with `K_sync` (§2.10). Consequences: sync runs with the
vault locked; an unchanged secure record is byte-stable (its inner nonce does not change); the
backend sees neither which records are secure nor their names.

### 4.2 A device without the vault or without its key

Classification of incoming secure envelopes (`SnippetLibraryBridge.swift:478-530`, applied again
inside the transaction at `:1341-1426`):

| Situation | Result |
|---|---|
| Live secure record, no local vault | **deferred**: kept on the backend, reported as waiting; nothing is written. A vault is never invented to hold it. |
| Live secure record, `vaultKID` differs from the local `kid` | **incompatible**: not applied; sync reports a rival vault instead of filing a record that can never be revealed. |
| Live secure record, `vaultKID` absent (legacy peer) | assumed to match; the local `kid` is stamped into the stored envelope |
| Live secure record, same vault, key missing (`noKey`) or locked | **applied**: `sealed` is stored verbatim; `contentHash` taken from `vaultContentHash`, or kept from the existing record if `sealed` is unchanged, else `""` (`SyncLibraryProjection.swift:245-311`). Never the SHA of ciphertext. |
| Secure tombstone for an id that exists locally | applied only when its `vaultKID` equals the local `kid`; missing stamp is incompatible, no local vault is deferred |
| Secure tombstone for an absent id | applied as a no-op |
| Envelope carrying secure conflict variants of another vault | incompatible; with no local vault, deferred |

So "opaque preservation" means: ciphertext, keyed hash, scope stamp and unknown `x` members are
stored and re-emitted unchanged by a device that cannot open them. The merge compares bodies by
`secure:<vaultKID or "legacy">:<vaultContentHash>` (`SyncMerge.swift:814-824`), which is why two
devices that re-seal the same plaintext do not conflict.

### 4.3 Conflict materialisation for secure records

When two sides changed a secure body, the HLC loser is not dropped. `SyncMerge`
(`:894-945`) stores it inside the survivor's `x` bag as one member per losing version:

```
key   = "contentConflict.v1." + fingerprint
value = { "version": 1, "copyID": lower(copyID), "sourceID": lower(id),
          "sourceHLC": "<hlc>", "sourceOrigin": "<8 hex>", "secure": true,
          "fields": <the loser's eight fields, content = its sealed text>,
          "x": { "vaultContentHash": "…", "vaultKID": "…" } }          // exactly these two
fingerprint = hex( SHA-256( canonical(value without "copyID") ) )
copyID      = uuid5like( namespace = sourceID, name = "sync-content-conflict-v1|" + fingerprint )
```

Limits: at most 128 variants and 512 KiB of variant data per envelope (`:595-599`); extension
values at most 256 bytes each (`:990-993`). Validation recomputes fingerprint and `copyID`
(`:947-1014`).

Device-side handling:

- A locked or keyless device mirrors each variant into the vault record's passthrough bag as
  `contentConflictOpaque.v1.<fingerprint>` = `b64std(canonical(value))`
  (`SyncLibraryProjection.swift:281-289`), so it survives loss of the sync sidecar. The projection
  restores it into the envelope on the way out (`:118-133`).
- Once the vault is unlocked (never prompting, never extending the session),
  `SyncSecureConflictMaterializer.materialize` (`:28-123`) turns each variant into a real vault
  record: check `vaultKID` equals the local `kid`; open the loser's ciphertext under the **source**
  id; verify the keyed hash; re-seal under the **copy** id; write a record with
  `name = "<name or Untitled> (conflict yyyy-MM-dd HH:mm UTC)"` (UTC, `en_US_POSIX`, from the
  loser's `updatedAt`), `keyword = ""`, `tags = normalised(tags + ["conflict"])`,
  `isEnabled = false`, `isPinned = false`, the loser's timestamps and HLC, `contentHash` = the
  carried keyed hash, and `x["conflictCopy.v1"] = {"version":1,"sourceID":…,"fingerprint":…}`.
- Failure cases: `incompatibleVault`, `identifierCollision` (the copy id is occupied by something
  without matching provenance, or duplicated), `contentHashMismatch`, `malformedVariant`.
- Until materialised, sync reports that it is waiting for the vault; key rotation and re-seal are
  refused (`pendingConflicts`).

The durability protocol around this (C0 receipts in `local.syncConflictC0Receipts.v1`, prepared
evidence, journal dependencies) belongs to the engine brief; the crypto facts it relies on are the
ones above.

---

## 5. Backups and import/export

### 5.1 Encrypted backup: what is in it

Format: §2.14. Created by `SecureSnippetStore.makeEncryptedBackup` (`:1469-1505`).

- Included: every ordinary snippet (after flushing pending writes) and, when the vault has at least
  one record, the whole vault document (identity, `kdf`, `wrapRecovery`, all records as ciphertext,
  unknown keys) plus `K_lib` wrapped under the backup's export key. Secure bodies are **never
  decrypted** during export.
- Excluded: usage data, sync state, journals, device-local conflict receipts, a zero-record vault,
  the Git/Cloud library keys, tokens.
- A snapshot that contains secure records requires fresh device-owner authentication
  (`withOneUseAuthentication`, reason "Export an encrypted backup including secure snippets").
- Refused while the ordinary library is quarantined (`libraryRecoveryRequired`).
- The KDF (600 000 rounds) runs off the main thread on an immutable snapshot.

### 5.2 Restore semantics: merge, never blind replace

`importPreparedEncryptedBackup` and `mergeEncryptedBackup` (`:1539-1606`, `:2272-2403`). Two phases:
`prepareEncryptedBackupImport` authenticates and validates everything and returns exact counts for
the confirmation UI; nothing is written until the second call. The two files change in one
transaction; any preflight error leaves both untouched.

Vault compatibility:

| Local state | Backup has a vault | Outcome |
|---|---|---|
| no vault | yes | the backup's vault document is installed; its key is stored in the key store first (an orphaned key is harmless, a vault without key is not) |
| vault with the same `kid` and the key present | yes | fresh authentication; the stored key must equal the backup's key byte for byte, else `vaultKeyMismatch`; then merge |
| vault with the same `kid`, key missing | yes | the backup's key is stored (this is a legitimate way to restore a lost key), then merge |
| vault with a different `kid`, or same `kid` but different salt or schema | yes | `incompatibleVault`; nothing imported. No re-encryption across vaults. |
| any | no | ordinary snippets merge only |

Merge rules:

- Conflicts are collected first (at most 8 reported) and abort the whole import: an ordinary
  incoming id equal to a secure local id or the reverse; a keyword that belongs to a record of the
  other kind; an id match whose keyword belongs to a different local record of the same kind.
- Ordinary snippets are normalised (keyword, tags, `updatedAt >= createdAt`), then upserted: same
  id replaces; otherwise same keyword replaces **keeping the local id and `createdAt`**; otherwise
  inserted at the front (`:2413-2428`).
- Secure records: same id and identical in everything except merge clocks is skipped; otherwise the
  incoming record replaces or is appended, with `updatedAt = max(importTime, incoming.updatedAt)`
  and a fresh local HLC at least as large as the incoming one (`:2374-2386`). Local records that
  are not in the backup stay.
- Vault doors: the local `wrapRecovery` is kept; filled from the backup only when absent. `wrapPass`
  and `wrapCLI` are never imported. Unknown document keys are filled only when absent.
- The only replace mode is the explicit quarantine recovery (`authoritativeRecovery`), where the
  ordinary half replaces a library that could not be read; the vault half still follows the rules
  above (`:1534-1549`).

### 5.3 Plain JSON export, import and limits

Plain export ("Export for Sharing", `SnippetStore.exportSnippets`, `snippets/SnippetStore.swift:1058-1071`,
encoder at `:475`): `{"snippets":[ … ]}`, pretty-printed with sorted keys, each element the nine
library keys `id`, `name`, `keyword`, `content`, `tags`, `isEnabled`, `isPinned`, `createdAt`,
`updatedAt` (`snippets/Core/Snippet.swift:503-539`), dates as numbers (seconds since 2001, the
Foundation default). **Secure snippets are excluded**; the iOS confirmation says so ("Exporting N
ordinary snippets. Secure snippets are excluded."). Refused while the library is quarantined.

Plain import (`snippets/Core/SnippetImportParser.swift:33-67`, `SnippetStore.importSnippets`,
`snippets/SnippetStore.swift:951-962`, `:1021-1056`, preflight `:1270-1362`): accepts a bare array
of snippets, `{"snippets":[…]}`, or a Raycast export (name, text, optional keyword; when keywords
start with `!` the user chooses to keep or remove the prefix). It **merges**: same id replaces;
else same folded keyword replaces, keeping the local id and `createdAt`; else insert at the top;
one undo entry. Preflight refuses duplicate ids or keywords inside the file, any id or keyword
that collides with a secure snippet, an id match whose keyword belongs to another snippet, and an
empty import; at most 8 conflicts are listed. Replacement happens only for a quarantined library
after an explicit confirmation. Details of the library model are in the library brief.

Limits and UI rules:

| Limit | Value | Pointer |
|---|---|---|
| JSON import file | 16 MiB | `snippets-ios/IncomingDocumentLoader.swift:7` |
| Encrypted backup file | 32 MiB (also the Linux limit) | `IncomingDocumentLoader.swift:8`, `snippets-linux/src/model.rs:17` |
| Backup password, export UI | at least 12 characters, confirmed twice | `snippets-ios/PhoneRootViewController.swift:449-483` |
| Backup password, format | non-empty; Linux also caps it at 4 096 bytes | `EncryptedSnippetBackup.swift:105`, `snippets-linux/src/backup.rs:195` |
| Backup `backupID`, Linux reader | 1...256 bytes, no NUL | `backup.rs:199-203` |
| Backup KDF salt, Linux reader | 1...128 bytes | `backup.rs:209-212` |
| Records per library, Linux | 100 000 | `model.rs:19` |
| Conflicts reported per import | 8 | `SecureSnippetStore.swift:2351` |
| File recognition | extension `snippetsbackup`, or the `format` probe | `EncryptedSnippetBackup.swift:17`, `:80-82` |
| Exported file on iOS | `Snippets-Backup.snippetsbackup`, complete file protection, temporary copy removed after 24 h | `PhoneRootViewController.swift:285-295` |

The Linux caps are stricter than Swift's (Swift's core has no size, id-length or salt-length cap).
A Kotlin reader that adopts the Linux caps rejects nothing Swift writes in practice; a Kotlin
writer must stay inside them.

---

## 6. Key stores

### 6.1 `SyncKeyStore` (`sync-v1`)

`SyncKeyStore.swift:49-264`. One facade the sync coordinator asks for the wire key; where the bytes
come from depends on the selected provider.

| Provider | Source of the 64 bytes | May mint? | Failure when absent |
|---|---|---|---|
| iCloud (Apple only) | Keychain item `sync-v1`, synchronizable | yes, on first use, add-if-absent | — |
| Git | `GitSyncKeyStore` record for the configured scope | **never** | `gitKeyRequired` (surfaced as `git_key_required`); `gitRecordUnreadable` when the record fails validation |
| Snippets Cloud | `SnippetsCloudKeyStore` record | never | `cloudBootstrapRequired`, `cloudRecordUnreadable` |

- `scopeID` is the constant `sync-v1` for every provider (`:87`); the sealer is
  `SnippetCryptoSealer(keyring: keyring(from: material), scopeID: "sync-v1")`
  (`SyncCoordinator.swift:676-678`).
- No user presence is ever required for the wire key (`:166-170`): it protects data from the
  backend, not from someone at the device.
- When the stored material differs from what the running engine was built with, the coordinator
  rebuilds the engine and discards the agreed base, so everything is offered again under the new
  key (engine brief, `discardAgreedBaseIfWireKeyChanged`).

### 6.2 `GitSyncKeyStore`

`GitSyncKeyStore.swift`. One record per connected library.

- Scope = `(location, refName, datasetID)` (`:23-36`): `remote.canonicalLocation` (the repository
  identity the repository `AGENTS.md` describes as lowercase host + path without scheme, user, port
  or `.git`; exact rule in the Git brief), the branch ref name, and the library's random dataset
  id from the manifest.
- Account name (opaque, so listings name no repository):

```
"git-library-v1-" + hex( SHA-256( "snippets-git-key-v1\n" + location + "\n" + refName + "\n"
                                  + lower(datasetID) )[0..<16] )
```

- Stored value: JSON `{ "schemaVersion": 1, "location", "refName", "datasetID" (lowercase),
  "material" (b64std of 64 bytes) }`. Reader: at most 2 048 bytes, exactly these five keys,
  `schemaVersion == 1`, 64 bytes, and all three scope fields equal to the requested scope
  (a record for another scope under the same account is tampering: `malformedRecord`).
- `mintMaterial()` = 32 random key bytes ‖ 32 random salt bytes; called only by library creation
  and key rotation.

This is the Apple Keychain representation. Android is free to choose its own at-rest form, but
must keep the binding check (scope equality on read) and the 64-byte length check.

### 6.3 Rules a client must obey

1. `SyncKeyStore` never mints for Git. A missing key stops sync with `git_key_required`.
2. Order on create: mint the library key (and the vault key), **store both locally, then push**;
   coordinates and token are saved only after library and key both exist
   (`docs/git-sync.md:597-601`, repository `AGENTS.md`).
3. Joining: read `keys/recovery.json`, open it with the user's code (bound to the dataset id),
   install the 64 bytes for the scope; read `keys/vault.json` with the library key, then
   `joinLibraryVault(identity, recoveryKey: codeBytes)` (`SecureSnippetStore.swift:1003-1059`):
   refuse when the device's vault is a different one that is in use (`differentVault`); an unused
   vault (no records, no secure envelope in sidecar or base, `:976-991`) is replaced; unwrap the
   vault key with the same code and store it before writing the records-free `vault.json`. A code
   that opens the library but not the vault wrap still joins; secure snippets then wait.
4. The recovery code is shown once, never stored, never logged. Replacing it rewrites
   `keys/recovery.json` and `keys/vault.json` in one commit or neither. Older codes stay valid for
   old history; only key rotation revokes.
5. New Recovery Code and Replace Keys perform their owner check inside the operation: the vault
   unlock when a vault key is wrapped or re-sealed, otherwise an explicit device-owner prompt.
6. Rotation (Replace Keys) creates a new dataset with a new library key, vault key and code in one
   fast-forward commit (manifest `schemaVersion` 2). Both new keys are stored before the push and
   forgotten only when the repository provably still holds the old library. Other devices stop with
   `git_library_replaced`, reconnect with the new code and re-seal (`resealIntoLibraryVault`).
7. Never delete a retired key from a store that syncs between devices. Android stores are
   device-only, so a retired key is deleted once the device has moved.
8. A file `keys/vault.json` with a newer `schemaVersion` is never replaced; a damaged one does not
   block ordinary snippets.
9. The library key alone never yields the vault key: opening `keys/vault.json` needs the library
   key, opening the wrap inside needs the recovery code.

---

## 7. Android mapping (proposal)

Everything in this section is a **proposal** for review, not a description of existing code.

### 7.1 Storage of each secret

| Secret | Proposal |
|---|---|
| `K_lib` (per `kid`) | Raw bytes must reach app memory (they are HKDF input), so the key cannot itself be a Keystore key. Store `AES-256-GCM(KEK_vault, K_lib)` in a private file `no_backup/keys/vault-<sha256(kid) prefix>.bin` = `version(1) ‖ iv(12) ‖ ct ‖ tag`, AAD = `"snip.android.klib.v1" ‖ 0x00 ‖ kid`. `KEK_vault` is an Android Keystore AES-256 key, alias `snippets.vault.kek.v1`, non-exportable, `setUserAuthenticationRequired(true)`, StrongBox when available with fallback to TEE. |
| Git library key record | `AES-256-GCM(KEK_sync, record)` in `no_backup/keys/<account>.bin`, `<account>` as in §6.2. `KEK_sync`: Keystore AES-256, alias `snippets.sync.kek.v1`, **no** user authentication and **no** unlocked-device requirement, so background sync works after first unlock (the Apple `AfterFirstUnlock` equivalent comes from credential-encrypted app storage). |
| Git token | same wrapping as the library key |
| Snippets Cloud root | same as the Git key record, separate file |
| SSH device key | Keystore EC P-256 signing key (Git brief) |
| Recovery key / code | never stored |

Authentication binding for `KEK_vault` (choose one, see Q5):

- A. Time-bound: `setUserAuthenticationParameters(10, AUTH_BIOMETRIC_STRONG or
  AUTH_DEVICE_CREDENTIAL)` on API 30+ (`setUserAuthenticationValidityDurationSeconds(10)` on
  28-29); prompt with `BiometricPrompt` allowing device credential, then unwrap immediately. One
  code path, same semantics as `deviceOwnerAuthentication`.
- B. Per-use `CryptoObject`: strongest, but device-credential fallback with a `CryptoObject` exists
  only on API 30+.

With a symmetric KEK, *storing* `K_lib` (vault creation, recovery, backup import) also needs an
authentication, which Apple does not require. If that prompt is unwanted, wrap with a Keystore
RSA-2048 OAEP key instead: public-key encryption needs no prompt, decryption does.

The 5-minute/30-minute session stays app-level logic exactly as in §3.4, holding the unwrapped
`K_lib` in memory; the Keystore prompt replaces `LAContext.evaluatePolicy`.

### 7.2 Invalidation and loss

- `KeyPermanentlyInvalidatedException` (new biometric enrolled with a biometric-bound key, or the
  secure lock screen removed) and a missing key file both map to the Swift state `noKey`: keep
  `vault.json`, offer "enter recovery key" (`restoreKey`) or, with Git, "Set Up Secure Snippets".
  Never create a new vault in this state.
- A device without a secure lock screen cannot hold `KEK_vault`: secure snippets are unavailable
  until one is set (the Swift app has the same dependency on a device passcode).
- Keystore keys do not survive backup/restore or device transfer. Exclude the wrapped key files
  from Auto Backup and device-to-device transfer. Whether `vault.json` itself is backed up is Q6.

### 7.3 Files

- App-private internal storage, credential-encrypted (default). `vault.json` mode equivalent to
  0600 (private app files already are). Atomic replace (`write temp, fsync, rename`), and the same
  lock + compare-and-swap loop as `VaultFile.update`.
- Diagnostics rules of the repository apply unchanged: a secure keyword may be logged through the
  typed facade; never bodies, names, ciphertext, keys, recovery material, record ids.

### 7.4 Screen and input surfaces

- `WindowManager.LayoutParams.FLAG_SECURE` on any window that can show a secure body or a recovery
  code (blocks screenshots, screen recording, casting, and the Recents thumbnail). Set it before
  the plaintext enters the view tree and clear it only after the plaintext is gone, mirroring the
  ordering rule of `SecureCapturePresentationPolicy` (`SecureCapturePresentationPolicy.swift:9-67`:
  ordinary, protected-redacted, protected-plaintext, failed-closed; plaintext may exist in the text
  storage only in the two protected phases).
- Accessibility: iOS removes the secure body from the accessibility tree for the whole secure
  session and exposes a metadata-free sibling that only says the body is protected and whether it
  is shown (`docs/ios-secure-accessibility-protection.md`). Android options: the same exclusion
  (`importantForAccessibility = NO_HIDE_DESCENDANTS` plus a describing sibling), or on API 34+
  `accessibilityDataSensitive`, which keeps real assistive tools working. Decision needed (Q7).
- Input: `importantForAutofill = NO`, `IME_FLAG_NO_PERSONALIZED_LEARNING`, no suggestions, no
  spell check, no drag, no share, no text-processing actions on the secure body field.
- Clipboard: set `ClipDescription.EXTRA_IS_SENSITIVE` (API 33+; set the same extra name on older
  versions, where it is ignored). Android has no expiry or local-only flag, so the expiry is a
  scheduled `clearPrimaryClip()` (API 28+); see §3.5 for the iOS behaviour to match and Q8 for the
  "is the clip still ours" problem.
- Lock when the app goes to the background (`ProcessLifecycleOwner` `ON_STOP`), which is the
  equivalent of `didEnterBackground`; not on focus loss, so the system authentication sheet and
  the share sheet do not lock the vault (`VaultSession.swift:132-136`).

---

## 8. Test vectors

Two kinds exist. **Literals inside Swift tests**, and **fixture files** under
`snippets-linux/tests/fixtures/` that were generated independently of the Rust code (Python with
OpenSSL, or the Swift 6.2 runtime's own double formatter; provenance in that folder's `README.md`,
generators in `snippets-linux/tests/reference/`). All values are fictional public test data. The
fixture files are plain JSON/TSV and can be read by Kotlin tests directly.

"Seal direction" means the test seals with a fixed nonce and compares output bytes; "open
direction" means it opens a fixed ciphertext. Because the nonce is inside every envelope, an
open-direction vector can also be used in the seal direction by a port that injects that nonce.

### 8.1 Fixture files (Rust reads them; copy them into Kotlin test resources)

| Fixture | Used at | Pins | Inputs |
|---|---|---|---|
| `crypto-v1.json` | `snippets-linux/src/crypto.rs:583-595`, `:665-683`, `:685-727` | A whole schema-1 vault document: record key HKDF, record AAD, padding, AES-GCM (open direction), content hash value (compute direction), PBKDF2 passphrase wrap at 600 000 rounds with an NFD-typed password, recovery wrap | root `0x11`×32, `vaultSalt` `0x22`×32, `kid` `public-interop-fixture`, record nonce `0x44`×12, `saltP` `0x55`×16, recovery material `0x66`×16 |
| `sync-wire-v1.json` | `snippets-linux/src/wire.rs:475-524` | Two wire records (one plain, one secure whose content is the `crypto-v1` sealed text verbatim): blob opens with scope `sync-v1`; canonical ten-key bytes including the doubles `-0.0` and `812578800.123456`; envelope hash; `rev == hash[0..<32]`; a secure tombstone keeping `vaultKID` and `userDeletion.v1` | sync root `0x99`×32, salt `0xaa`×32, fixed nonces |
| `swift-double-v1.tsv` | `snippets-linux/src/canonical.rs:550-566` | 11 903 lines: binary64 bit pattern, exact Swift spelling. Covers zero and sign, subnormals, the maximum, the 2^53 switch, powers of ten, and a 10 000-value pseudo-random stream | — |
| `backup-v1.json` | `snippets-linux/src/backup_tests.rs:28-58` | A whole backup (open direction): container fields, passphrase wrap with `kid = backupID`, payload AAD, vault-key wrap (HKDF info and AAD), receipt stripping, unknown-field passthrough. Vault dates in the payload are ISO strings (hazard H2) | password `Café public backup fixture` (opened with the decomposed spelling), salt `0x99`×16, export key `0x88`×32, nonces `0xaa`, `0xbb`, `0xcc` |
| `conflict-copy-v1.json` | `Tests/Core/SyncConflictCopyVectorTests.swift:35-71`, `snippets-linux/src/merge_tests.rs:757-780` | Two plain conflict copies: canonical bytes, `copyID`, provenance fingerprint. **Checked by both Swift and Rust.** | — |
| `merge-v1.json` | `snippets-linux/src/merge_tests.rs:121-150`, `:646-662` | Conflict snapshot canonical bytes, fingerprint, name-based copy id, conflict name `(conflict 2001-01-01 00:02 UTC)`, deletion-set fingerprint | — |
| `bootstrap-v1.json` | `snippets-linux/src/bootstrap_tests.rs:45-70`, `:93-116` | Portable key bundle JSON for material bytes 0...63 (the plaintext of `keys/recovery.json`); Cloud pairing, recovery and Ed25519 vectors (Cloud brief) | material = bytes 0...63 |
| `restoration-current-vault-v1.json`, `restoration-additional-vault-v1.json` | Linux live suites | Two more independent vaults with 600 000-round wraps; useful as extra `KeyWrap`/`PassphraseKDF` open-direction cases | — |
| `git-plain-v1.json` | `snippets-linux/src/git_plain_tests.rs` | Plain-text Git library (Git brief), generated from the Swift sources | — |

### 8.2 Literals in tests

| Where | Test | Pins | Both sides? |
|---|---|---|---|
| `Tests/Core/GitSyncVaultTests.swift:146-175`; `snippets-linux/src/git_tests.rs:825-868`, `:891-893` | `knownAnswerMatchesTheLinuxMirror` / `vault_file_known_answer_matches_the_apple_apps` | (a) recovery code text for bytes `0xa0…0xaf` = `M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ`; (b) `KeyWrap.wrap(.recovery)` of key `0x80…0x9f`, salt `0x40…0x5f`, kid `k-0f1e2d3c-4b5`, nonce `0x10…0x1b`: full envelope text (seal direction, so it also pins HKDF, AAD, padding and GCM for a 32-byte body); (c) the complete `keys/vault.json` bytes for material bytes 0...63, dataset `617a0001-0000-4000-8000-0000000000aa`, nonce `0x20…0x2b` | **yes** (Rust checks (b) in the open direction only) |
| `Tests/Core/WireTests.swift:180-191` | canonical object literal `{"A":null,"a":"x","b":2,"ä":true}` | key order, no whitespace, raw non-ASCII | Swift only |
| `WireTests.swift:200-208`, `:213-216` | UTF-8 versus UTF-16 key order (U+FFFD before U+10000); `{"Z":4,"a":3,"b":2,"ä":1}` | sort rule | Swift only |
| `WireTests.swift:218-227` | escape table | §2.9 rule 3 | Swift only |
| `WireTests.swift:260-265`, `:339-342` | `1` versus `1.0`; `{}` and `[]` | int/double distinction | Swift only |
| `WireTests.swift:442-453` | envelope hash `dbc644e2…ec4c` for a fixed plain snippet; HLC text `0000000003e8-0002-aabbccdd`; origin `abcdef01`; tag normalisation | whole nine-key canonical form through SHA-256 | Swift only |
| `Tests/Core/VaultDocumentTests.swift:274-291` | substring `2026-07-29T08:00:00.123Z` | vault timestamp format | Swift only |
| `VaultDocumentTests.swift:232-238`, `Tests/Core/VaultIntegrationTests.swift:334` | substrings `"wrapCLI" : null`, `"keyword" : "k"` | explicit null, Foundation pretty spacing | Swift only |
| `VaultDocumentTests.swift:786-810` | passthrough value encoding `{"d":12.5,"f":false,"i":600000,"n":null,"s":"1","t":true}` | `JSONValue` type fidelity | Swift only |
| `snippets-linux/src/canonical.rs:522-548` | eight double spellings (`0.0`, `-0.0`, `1.0`, `0.0001`, `1e-05`, `1000000000000000.0`, `1e+16`, `5e-324`) | thresholds | Rust only |
| `snippets-linux/src/git_tests.rs:511-619` | manifest bytes and a Git record file literal | Git brief | Rust only |
| `Tests/Core/LibraryKeyBootstrapTests.swift:18-30`, `:108-123`; old Android `app/src/test/java/com/khm/snippets/android/LibraryKeyBootstrapTest.kt:79-92` | Ed25519 authority key and signature, Cloud recovery ciphertext | Cloud brief | Swift, Rust and the old Android tests |

### 8.3 Formats with no frozen vector: the Swift vector emitter must produce these

The plan says byte compatibility is proven by vectors emitted from Swift. Today most fixtures were
produced by independent reimplementations and are checked only by Rust. The emitter should write,
from the unmodified `CorePackage` sources with fixed keys and injected nonces:

| # | Format | Why it is missing today |
|---|---|---|
| V1 | `SnippetCrypto.additionalData` bytes for a live and a deleted context | only implied by opens |
| V2 | `Keyring.recordKey` and `contentHashKey` raw bytes | only implied |
| V3 | `SnippetCrypto.seal(for:keyring:)` full text, seal direction, for bodies of 0, 1, 255, 256, 257 bytes and a multi-byte UTF-8 body | no record seal-direction vector anywhere |
| V4 | `Padding.pad` outputs at the block boundaries | none |
| V5 | `contentHash` hex from Swift | value exists only in the Python fixture |
| V6 | `PassphraseKDF.derive` raw 32 bytes for ASCII, `Café` in both normal forms, and a non-BMP password, at a low count and at 600 000 | none standalone |
| V7 | `PassphraseKDF.wrap` full `WrappedKey` with a fixed nonce | open direction only |
| V8 | `KeyWrap.wrap` with purpose `cli` | none at all |
| V9 | `RecoveryKey` encode/format for several byte patterns, and decode outcomes for each failure case | one literal only |
| V10 | `CanonicalJSON.data` for a value exercising every escape, nested bags, integer limits and doubles | Swift literals are small; doubles come only from the TSV |
| V11 | `SyncEnvelope` canonical bytes, hash and `rev` for: plain, secure (with `vaultContentHash`, `vaultKID`), tombstone, tombstone with `userDeletion.v1`, an envelope with unknown `x` members | no vector shared by Swift and another reader |
| V12 | `WireCodec.seal` blob with fixed nonce for the V11 envelopes | open direction only, Rust only |
| V13 | Secure conflict variant: the `contentConflict.v1.<fp>` key and value, fingerprint and `copyID`; and the materialised copy's metadata | formula tested with random keys only |
| V14 | `VaultFile.encode` full file bytes for a document with passthrough keys, plus the same document as decoded field values | substrings only; Swift and Rust bytes differ by design |
| V15 | `EncryptedSnippetBackup.seal` full container with fixed export key, backup id and three nonces, **with a vault**, plus the decrypted payload JSON | settles hazard H2; no Swift-side vector exists |
| V16 | `GitSyncRecovery.seal` full `keys/recovery.json` with a fixed nonce (the Swift API has no nonce parameter today; add a test seam like `GitSyncVault.seal` has) | only the plaintext bundle is pinned |
| V17 | `GitSyncKeyStore.Scope.account` hex for fixed scope values | formula only |
| V18 | `SyncKeyStore.keyring(from:)` split followed by one sealed wire record | not pinned end to end |
| V19 | `PortableKeyBundle.jsonData` from Swift | pinned by the Python fixture only |

Also useful from the emitter: the 11 903-line double corpus re-emitted by the Swift toolchain in
use, to confirm the TSV still matches.

---

## 9. Porting hazards and open questions

### 9.1 Hazards

| # | Hazard | Pointer | What the port must do |
|---|---|---|---|
| H1 | **Double formatting.** Envelope hashes cover `createdAt`/`updatedAt` printed with Swift's `Double.description`. Kotlin prints `1.0E16` and uses other thresholds. One wrong digit makes every record fail `hashMismatch` on the other platform. | `SyncEnvelope.swift:145-150`, `:925-926` | Implement §2.9; pass all 11 903 lines of `swift-double-v1.tsv`. |
| H2 | **Backup payload dates disagree between implementations.** Swift encodes and decodes the payload with a default `JSONEncoder`/`JSONDecoder`, so vault-record dates are numbers (seconds since 2001); its lenient record reader turns an ISO string into `nil`, then `distantPast`, with no error. Rust writes and requires ISO strings for the vault part, and `backup-v1.json` was generated with ISO strings. The fixture README says live execution between the Apple and Linux apps is unverified. Established by reading the code, not by running both apps. | `EncryptedSnippetBackup.swift:150`, `:218`, `:266-270`; `VaultDocument.swift:729-736`; `snippets-linux/src/vault.rs:30-45`, `backup.rs:39-44` | Reader accepts both forms. Writer: Q1. |
| H3 | **Dates must stay doubles.** `Fields.createdAt` is the raw `timeIntervalSinceReferenceDate`. A model that stores epoch milliseconds or `Instant` cannot reproduce the hash of a record made on Apple. | `SyncEnvelope.swift:914-926` | Carry the double end to end. |
| H4 | **Key sort order.** Canonical JSON sorts keys by UTF-8 bytes; Kotlin string comparison is UTF-16 order. They differ for supplementary-plane characters against U+E000...U+FFFF. Defined keys are ASCII, but `x` and conflict keys are data. | `SyncEnvelope.swift:166-168` | Sort on encoded bytes, unsigned. |
| H5 | **Duplicate keys.** Swift treats canonically equivalent strings as the same dictionary key, so they are rejected as duplicates. A Kotlin map does not. | `SyncEnvelope.swift:57-62`, `:315` | NFC-normalise for the duplicate check (Rust does, `canonical.rs:117`). |
| H6 | **UUID parsing and case.** `java.util.UUID.fromString` accepts malformed input such as `1-1-1-1-1`. Envelope ids, dataset ids in AADs and Git files are lowercase; Foundation writes ids in `vault.json` and the backup payload uppercase; several readers require `text == lower(parsed)`. HKDF info and AAD use the 16 raw bytes, most significant first. | `SyncMerge.swift:971-975`, `VaultDocument.swift:358-361` | Strict 8-4-4-4-12 parser; explicit case per format. |
| H7 | **Compare-and-swap on file bytes.** `VaultFile.update` verifies its write by comparing bytes. A non-deterministic encoder makes the loop fail after 8 attempts. | `VaultDocument.swift:1091-1101` | Deterministic encoder: sorted keys, stable numbers and dates. |
| H8 | **Explicit nulls.** `wrapPass`, `wrapRecovery`, `wrapCLI` are always written, `null` when absent. `schemaVersion`, `kid`, `vaultSalt`, `kdf`, `records` are required on read. | `VaultDocument.swift:647-679` | Do not configure the serializer to drop nulls. |
| H9 | **Unknown keys must survive** in the three vault bags and the envelope `x` bag: a stripped copy is what syncs next. The envelope is the opposite at its top level and in `fields`: an unknown key is an error, never ignored. | `VaultDocument.swift:13-34`; `SyncEnvelope.swift:934-938`, `:1168-1176` | No `ignoreUnknownKeys` shortcuts in either direction. |
| H10 | **Two different content hashes.** Top-level `contentHash` is SHA-256 of `fields.content` (ciphertext text for secure records). `VaultRecord.contentHash` is the keyed HMAC of the plaintext. | `SyncEnvelope.swift:1070-1087`, `SyncLibraryProjection.swift:305-308` | Never copy one into the other. |
| H11 | **Scope strings.** Vault bodies use the `kid`; wire blobs use `sync-v1`. Mixing them yields only `authenticationFailed`. | `SnippetCrypto.swift:200-215`, `SyncKeyStore.swift:51-54` | Separate types for the two sealers. |
| H12 | **Salt as bytes versus text.** The `snip.kdf.v1` AAD takes the decoded salt bytes; the `snip.backup.payload.v1` AAD takes the salt and the envelope as text. | `PassphraseKDF.swift:166-173`, `EncryptedSnippetBackup.swift:277-285` | Follow §2.6 and §2.14 literally. |
| H13 | **Two base64 dialects.** Envelopes, `vaultSalt`, `saltP`: unpadded base64url, strict decoder. Git key files and the portable bundle: padded standard base64 with a re-encode check. `java.util.Base64` decoders are more lenient than both. | `SnippetCrypto.swift:571-582`, `GitSyncRecovery.swift:92-93` | Own strict wrappers. |
| H14 | **Padding boundary.** A body of exactly `256k` bytes grows by a whole block; `256k - 1` bytes grows by one byte. An empty body is legal and seals to one block. The Git key files and Cloud envelopes are not padded. | `SnippetCrypto.swift:494-501` | Test 0, 1, 255, 256, 257. |
| H15 | **PBKDF2 password encoding.** Password is NFC, then UTF-8. `PBEKeySpec` takes `char[]`; the provider's conversion is unverified for non-ASCII and non-BMP input. Old ICU versions may normalise very new characters differently. | `PassphraseKDF.swift:184` | Vector-test the provider; keep a pure-Kotlin fallback. |
| H16 | **Recovery-code normalisation.** JVM uppercasing with a default locale breaks on Turkish `i`. | `RecoveryKey.swift:163-178`, `:63-72` | `uppercase(Locale.ROOT)`; keep the five distinct errors. |
| H17 | **Key before document.** Store `K_lib` before writing a `vault.json` that names it; store Git keys before the creating push. | `SecureSnippetStore.swift:710-728`, `:1017-1019` | Same order; roll the key back only when the file write fails. |
| H18 | **Never mint a second vault.** With Git selected, vault creation fails with `libraryVaultSetupRequired`. A second `kid` is a second crypto scope that other devices refuse. | `SecureSnippetStore.swift:581-586`, `:682-686` | Gate creation on the selected provider. |
| H19 | **Deadline, not timer.** The session deadline is enforced on every key access; a late timer or a frozen process must not leave the key usable. | `VaultSession.swift:376-394` | Check on access; see Q9 for the clock. |
| H20 | **Pre-lock flush.** `lock()` gives editors one synchronous chance to save while the key is valid. Without it the last edit before backgrounding is lost. | `VaultSession.swift:426-435` | Synchronous hook before the key is dropped. |
| H21 | **Background sync must not extend the session and must never prompt.** | `VaultSession.swift:368-374` | Separate non-extending accessor. |
| H22 | **Tombstones** carry no body and no digest and keep only `vaultKID` from `x`. A secure tombstone without `vaultKID` cannot delete an existing local record. | `SyncEnvelope.swift:1036-1044`, `:1342-1350` | Enforce in the constructor and the parser. |
| H23 | **Keystore provider versus in-app keys.** Format keys (`K_rec`, wrap keys) are in-memory keys with caller-supplied nonces. The Android Keystore provider insists on its own IV unless randomized encryption is disabled. | — | Use the default provider with `SecretKeySpec` for all format crypto. |
| H24 | **Error collapsing.** One `authenticationFailed` for wrong key, AAD, nonce and tampering; `wrongPassphrase` and `incorrectCode` distinct from structural errors, so a truncated file is never reported as a wrong password. | `SnippetCrypto.swift:108-119`, `PassphraseKDF.swift:266-274` | Mirror the error taxonomy. |
| H25 | **Key-store errors are not "no key".** `hasItem` answers "present" on a store error so a locked store never leads into vault creation or overwriting recovery state. | `KeychainSecretStore.swift:334-350` | Three-valued result internally; fail closed. |
| H26 | **Salt length is not uniform.** Swift accepts any non-empty `vaultSalt`; `GitSyncVault` and the Rust decoder require exactly 32 bytes. Some Swift test fixtures use 16. | `KeyWrap.swift:132`, `GitSyncVault.swift:86`, `snippets-linux/src/vault.rs` (`Document::decode`) | Always write 32; Q12 for reading. |
| H27 | **`WireIdentity.associatedData()` is a decoy.** It builds a canonical-JSON AAD with `rev`, but the shipping sealer authenticates the record context of §2.3 and checks `rev` after opening. | `SyncEnvelope.swift:604-610`, `:666-671` | Do not put `rev` in the AAD. |

### 9.2 Open questions

| # | Question | Proposed direction |
|---|---|---|
| Q1 | Backup payload dates (H2): which form does Kotlin write? Numbers match Swift, the authority, but the current Linux reader rejects them; ISO strings match Linux and the fixture, but Swift silently loses the secure records' dates. | Make the Swift and Rust readers accept both, then write numbers. Needs an owner decision and a Swift-emitted vector (V15). |
| Q2 | Does `SecretKeyFactory("PBKDF2WithHmacSHA512")` on API 28 reproduce the vectors for non-ASCII passwords, and how long do 600 000 rounds take on a low-end device? | Measure in wave 1. If the provider is wrong and pure Kotlin is too slow, a library is needed. |
| Q3 | Vault identity outside Git. On Apple a second device joins the existing vault through the iCloud Keychain identity item, used only when iCloud is the provider (`SecureSnippetStore.swift:210-213`). For Snippets Cloud I found no identity channel in the Swift code: each device would mint its own `kid` and the other's secure records would be classified incompatible. Is that the intended behaviour, and should Android offer secure snippets under Snippets Cloud at all? | Encrypted backup import is the only cross-device path I found. Confirm with the Cloud brief. |
| Q4 | A local-only Android device creates its own vault (§3.3). When it later joins an existing Git library with another vault, Apple refuses (`differentVault`) until the secure snippets are made ordinary or deleted (`docs/git-sync.md:637-642`). Same UX on Android? | Same refusal and wording. |
| Q5 | Keystore binding for `KEK_vault`: time-bound or per-use `CryptoObject`; symmetric or RSA wrapping; `setInvalidatedByBiometricEnrollment` true or false. | §7.1 option A, symmetric, invalidation on, recovery code as the way back. |
| Q6 | Auto Backup and device transfer: include `vault.json` (ciphertext plus `wrapRecovery`, so a restored phone recovers with the code) or exclude it with the keys? | Include `vault.json`, exclude key files. |
| Q7 | Accessibility: full exclusion of the secure body as on iOS, or `accessibilityDataSensitive` on API 34+ with exclusion below? | Owner decision. |
| Q8 | Clipboard expiry: Android cannot read the clipboard from the background (API 29+), so "clear only if it is still our clip" cannot be checked there. Clear unconditionally after 60 s, clear only in the foreground, or rely on the sensitive flag alone? | Owner decision. |
| Q9 | Session clock: Swift uses wall-clock `Date()` for the deadline. A monotonic clock (`SystemClock.elapsedRealtime`) is safer on Android. | Monotonic; confirm the intentional difference. |
| Q10 | Base64 trailing bits: neither Foundation nor `java.util.Base64` rejects non-zero unused bits in the last symbol, so an envelope still has more than one accepted spelling. Not tested on either side. | Match Swift (accept) unless the owner wants strictness everywhere. |
| Q11 | `wrapCLI` and `wrapPass` are reserved formats with no writer. | Android preserves them and never writes them. |
| Q12 | `vaultSalt` length on read (H26): accept any non-empty salt like Swift, or require 32 bytes like Linux? | Require 32 for Git-published identities (already enforced); accept non-empty for a local `vault.json`. |
| Q13 | `GitSyncRecovery.seal` has no nonce seam, so `keys/recovery.json` cannot be pinned in the seal direction without a small Swift change. | Add the test seam with the vector emitter (V16). |

---

## 10. Test inventory and Kotlin decomposition

### 10.1 Tests to port

P0 = byte format and cryptographic correctness; P1 = behavioural invariants; P2 = platform-specific,
port the idea only. Counts are approximate.

| Test file | What it pins | Tests | Priority |
|---|---|---|---|
| `Tests/Core/CryptoTests.swift` | seal/open, tampering of each envelope field, AAD binding to scope, id and deleted flag, nonce source, key hierarchy separation, padding, keyed content hash, PBKDF2 wrap and its limits, recovery-key checksum and folding, strict base64url. Round trips, no known answers | 74 | P0 (add the §8 vectors) |
| `Tests/Core/WireTests.swift` | canonical JSON literals, ten-key and eight-key sets, envelope hash literal, tombstone invariants, `x` rules, `WireCodec` identity checks | 80 | P0 for canonical JSON, envelope and codec; P1 for the deletion guard and ledger parts; skip the in-memory transport |
| `Tests/Core/VaultDocumentTests.swift` | passthrough bags at three levels, explicit nulls, leniency defaults, version probe, quarantine, metadata-only load, shells, `JSONValue`, `SecretStore` | 35 | P0 format, P1 file safety, P2 `SecretStore` |
| `Tests/Core/VaultIntegrationTests.swift` | passphrase, recovery and CLI wraps open the same key; purpose and `kid` binding; nothing secret legible in the file; byte-identical rewrite | 18 | P0 |
| `Tests/Core/EncryptedSnippetBackupTests.swift` | round trip, wrong password, tampering, duplicate ids, empty vault refused | 6 | P0 |
| `Tests/Core/GitSyncVaultTests.swift` | known-answer file, layout, well-formedness limits, code to vault key | 4 | P0 |
| `Tests/Core/GitSyncTransportTests.swift` (recovery suite from `:799`) | recovery envelope round trip, typed-code folding, wrong code versus bad envelope | 8 of about 40 | P0 for the envelope |
| `Tests/Core/SyncConflictCopyVectorTests.swift` | cross-client conflict-copy vectors | 2 | P0 |
| `Tests/Core/SyncSecureConflictMaterializationContractTests.swift` | re-seal under the copy id, provenance, idempotence, collisions, hash mismatch | 8 | P1 |
| `Tests/Core/SyncSecureConflictVariantDurabilityTests.swift` | opaque carrier survives through `vault.json`, fail-closed paths | 15 | P1 |
| `Tests/Core/SyncLibraryProjectionTests.swift`, `SyncConflictCopyTests.swift`, `SyncMergeTests.swift` | keyed hash versus SHA projection, copy-id recipes, merge by keyed hash | 10 / 11 / 45 | P1 (shared with the engine brief) |
| `Tests/Core/SecureCapturePresentationPolicyTests.swift` | phase ordering for protected display | — | P1 (maps to `FLAG_SECURE` ordering) |
| `Tests/SecurePlaintextLeaseTests.swift` | lease wipe semantics | — | P2 |
| `Tests/Core/LibraryKeyBootstrapTests.swift`, `SnippetsCloudAccountKeyTests.swift` | Cloud vectors | 4 / 9 | Cloud brief |
| `Tests/Harnesses/VaultSessionAutoLockTest.swift`, `KeychainSelfTest.swift`, `VaultIdentityTest.swift` | executable harnesses for session expiry and Keychain behaviour | — | P1 for the session rules, P2 otherwise |
| `snippets-ios-tests/SecureVaultProviderIsolationTests.swift`, `SecureRemediationTests.swift`, `KeychainAccessibilityPolicyTests.swift` | no rival vault under Git, key-missing remediation, protection classes | 13 / 24 / 32 | P1 / P1 / P2 |
| `snippets-ios-tests/SecureSnippetRevealTests.swift`, `SnippetsIOSTests.swift` (secure parts) | reveal policy state machine, secure copy options and expiry, one-use authentication | — | P1 |
| `snippets-linux/src/crypto.rs` tests (`:576-728`) | `crypto-v1.json`, AAD and scope binding, padding bounds, strict base64url, every single-symbol recovery typo | 6 | P0 |
| `snippets-linux/src/canonical.rs` tests (`:465-618`) | Swift doubles, grammar, depth 32, duplicate and NFC-equivalent keys | 6 | P0 |
| `snippets-linux/src/wire.rs` tests | `sync-wire-v1.json`, size ceiling | 4 | P0 |
| `snippets-linux/src/backup_tests.rs` | `backup-v1.json`, tamper of each header field, limits | 7 | P0 |
| `snippets-linux/src/git_tests.rs` (`:472-893`) | vault-file known answer, key scope shape, recovery envelope | part of 30 | P0 |
| `snippets-linux/src/vault.rs` tests | strict document decode, session timeouts (300 s / 1 800 s, `vault.rs:22-23`) | 16 | P1 |

Note for whoever ports `VaultDocumentTests`: several Swift fixtures use placeholder `sealed`
strings and a 16-byte `vaultSalt`. Swift accepts any non-empty salt; `GitSyncVault` and the Rust
decoder require exactly 32 bytes. Kotlin should always write 32 and decide deliberately whether to
accept other lengths on read (see Q12).

### 10.2 Suggested Kotlin decomposition

`:core` only (pure JVM, API 28 subset). Dependency order top to bottom; each line depends only on
lines above it.

```
com.khm.snippets.core.crypto
  Bytes            hex (lowercase), constant-time equals, wipe helpers, strict UUID <-> 16 bytes
  Base64Url        strict unpadded codec (§1 #12); Base64Std canonical codec (§1 #13)
  Hkdf             HKDF-SHA256 (extract, expand)
  Pbkdf2           PBKDF2-HMAC-SHA512 behind an interface (provider or pure Kotlin)
  AesGcm           seal/open with explicit nonce and AAD; combined framing helper
  NonceSource      system + test-injectable
  DomainSeparated  §2.1
  Padding          §2.2
  SealedEnvelope   text grammar, parse/format                       (SnippetCrypto.Envelope)
  SnippetCrypto    Keyring(root, salt), recordKey, contentHashKey, RecordContext, AAD,
                   seal/open (record and raw-key forms), contentHash
  KeyWrap          purposes, wrap/unwrap                             (KeyWrap.swift)
  PassphraseKdf    WrappedKey, wrap/unwrap                           (PassphraseKDF.swift)
  RecoveryKey      generate/encode/format/decode + failures          (RecoveryKey.swift)
  SwiftDouble      shortest digits + Swift formatting                (§2.9)
  CanonicalJson    Value (with a bytes-string case), emitter, parser
  DeterministicUuid SHA-1 name-based id                              (SyncMerge.deterministicUUID)

com.khm.snippets.core.sync   (envelope part only; merge/engine are in brief 01)
  SyncEnvelope     ten-key model, Fields, hash, parse, tombstone rules
  WireRecord, SyncBlobSealer (interface), SnippetCryptoSealer, WireCodec
  PortableKeyBundle

com.khm.snippets.core.git    (key files only; transport is in brief 03)
  GitSyncRecovery  Kit, seal/open keys/recovery.json
  GitSyncVault     Identity, seal/open keys/vault.json
  GitKeyScope      account derivation, record validation (§6.2)

com.khm.snippets.core.vault
  JsonValue        lossless passthrough value
  VaultDocument, VaultKdfParameters, VaultRecord (+ shell), codec with ISO-ms timestamps
  VaultFile        load outcomes, locked update loop, quarantine
  KeyStore         interface: store/load/has/delete by key id, addIfAbsent (in-memory impl for tests)
  VaultSession     state machine, 5/30-minute window, one-use authentication, pre-lock hook;
                   authentication and clock injected
  SecureSnippetStore create/commit, recovery add/restore, content ops, promote/demote hooks,
                   library-vault join, rotation, reseal
  SecureConflictMaterializer

com.khm.snippets.core.backup
  EncryptedBackup  container, payload, AADs, seal/open, validation
  BackupMerge      conflict detection and upsert rules (§5.2)
```

`:app` supplies: the Keystore-backed `KeyStore`, the `BiometricPrompt` authenticator, lifecycle
lock triggers, `FLAG_SECURE`, clipboard handling.

Build order that keeps every step testable against a fixture: `Bytes`/`Base64` → `Hkdf`, `AesGcm`,
`Padding`, `SealedEnvelope` → `SnippetCrypto` (fixture `crypto-v1.json`) → `KeyWrap`,
`PassphraseKdf`, `RecoveryKey` → `SwiftDouble` (fixture `swift-double-v1.tsv`) → `CanonicalJson` →
`SyncEnvelope`/`WireCodec` (fixture `sync-wire-v1.json`) → `GitSyncRecovery`/`GitSyncVault` →
`VaultDocument` → `EncryptedBackup` (fixture `backup-v1.json`) → session and store.
