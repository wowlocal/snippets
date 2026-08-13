import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.
// Foundation and CryptoKit only: no AppKit (the CLI has no GUI) and no
// Security.framework (the Keychain wrapper is app-side, because only the app has an
// entitled, signed bundle identity to scope a keychain item to).

/// The wire crypto for secure ("vault") snippets: one AEAD envelope per record,
/// keyed by a hierarchy rooted in a single random library key.
///
/// ## What this defends, and what it does not
///
/// **Defended.** The sync backend operator sees only ciphertext, and so does Apple if
/// the backend is CloudKit. A copy of `Vault/vault.json` **on its own** — a Time Machine
/// copy of the support directory, a stolen powered-off Mac — yields ciphertext, because
/// `K_lib` is not in that file. Its primary home is the Keychain
/// (`KeychainSecretStore`); the wraps in the document are escape hatches under a
/// recovery key, unwrapped only into memory.
///
/// **Not defended: anything that carries the Keychain along with the file.** Migration
/// Assistant and a whole-volume restore move `~/Library/Keychains` next to
/// `Vault/vault.json`, so the vault opens on the destination Mac for whoever can log in
/// there; on the synchronizable tier iCloud Keychain does the same, deliberately.
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` does not prevent this — on the
/// file-based login keychain that attribute is inert, and what keeps the item local is
/// only that the login keychain does not sync.
///
/// This paragraph used to claim the opposite, and said the key lived wrapped under a
/// passphrase. That was written before the vault moved to the Keychain and no shipping
/// path writes a passphrase wrap any more; it is the comment a future reader would have
/// reasoned from.
///
/// **Not defended.** Someone sitting at the unlocked Mac with the vault unlocked.
/// Any process running as the same user: this app is not sandboxed, so a peer process
/// can read our memory with `task_for_pid`, drive our own CLI, or simply type the
/// keyword into a text field and read what we expand. Root, obviously. None of that
/// is fixable in this file, and pretending otherwise would be worse than saying so.
///
/// **Metadata is deliberately in the clear.** A secure snippet's name, keyword, and
/// tags are plaintext in `vault.json`. This is not laziness: the keystroke matcher
/// has to run with the vault *locked* and the app in the background, so it must be
/// able to recognise a trigger without any key material at all. Encrypting the
/// keyword would mean trigger detection could not exist — the feature would be "type
/// the keyword, get nothing, go unlock the vault, type it again". So an attacker with
/// the file learns that a snippet named "Bank OTP" with keyword `otp` exists, and
/// learns roughly nothing else: the body is sealed and its length is padded (see
/// `Padding`).
///
/// **Plaintext stays `Data`.** Every function here takes and returns `Data`, never
/// `String`. A Swift `String` cannot be reliably zeroed — small strings live inline
/// in the struct, the standard library copies them freely, and there is no supported
/// way to overwrite the buffer. `Data` is not much better, but at least it is one
/// heap allocation we can point at. Call `plaintextString(_:)` at the final hop only,
/// and be aware that the resulting `String` is unrecoverable once it exists.
///
/// ## Key hierarchy
///
/// ```
/// K_lib  (256 random bits; the only long-term secret, never used to encrypt)
///   ├── K_rec(id) = HKDF-SHA256(ikm: K_lib, salt: vaultSalt, info: "snip.wire.v1|" ‖ id)
///   └── K_hash    = HKDF-SHA256(ikm: K_lib, salt: vaultSalt, info: "snip.chash.v1")
/// ```
///
/// `K_lib` never encrypts anything itself. That is not ceremony: AES-GCM's 96-bit
/// nonce is only safe while nonce reuse under one key is impossible, and "impossible"
/// is a strong claim for a random 96-bit value across a library that syncs, restores
/// from backup, and re-seals on every edit for years. Birthday bounds put a single key
/// at meaningful collision risk somewhere around 2^32 seals; per-record subkeys move
/// that bound to "2^32 edits *of one snippet*", which no human will reach. It also
/// means a subkey leaked by some future bug (a log line, a crash dump) exposes one
/// record rather than the library.
nonisolated enum SnippetCrypto {

    // MARK: - Constants

    /// Bumped only for a format change that an older build must refuse rather than
    /// misread. It appears both as the envelope prefix and inside the AAD, so a
    /// version cannot be edited in the file without breaking the tag.
    static let wireVersion = "v1"

    static let nonceByteCount = 12
    static let tagByteCount = 16
    static let keyByteCount = 32
    /// The per-vault HKDF salt stored in the clear in `vault.json`. Its job is domain
    /// separation between two vaults that (through a restore, a clone, a shared team
    /// scope) might otherwise derive from related material — not secrecy.
    static let saltByteCount = 32

    /// HKDF `info` strings. Distinct, self-describing, and versioned so a future
    /// algorithm change cannot silently derive the same bytes for a different purpose.
    static let recordKeyInfoPrefix = "snip.wire.v1|"
    static let contentHashInfo = "snip.chash.v1"
    /// Domain tag for the AAD builder below. Also versioned, and distinct from the
    /// one `PassphraseKDF` uses, so a key-wrapping AAD can never collide with a
    /// record AAD.
    static let additionalDataDomain = "snip.aad.v1"

    /// 128 bits of an HMAC, hex-encoded — see `contentHash(of:key:)`.
    static let contentHashByteCount = 16

    // MARK: - Errors

    /// Deliberately coarse where it matters.
    ///
    /// `authenticationFailed` covers a wrong key, a tampered ciphertext, a tampered
    /// nonce, a mismatched AAD, and a ciphertext lifted from another record. Splitting
    /// those apart would hand an attacker with the file a free oracle telling them
    /// *which* thing they got wrong, which is exactly how a padding-oracle attack
    /// starts. There is nothing a caller can usefully do differently between them
    /// anyway: all five mean "do not apply this record".
    enum Failure: Error, Equatable, CustomStringConvertible {
        case malformedEnvelope(String)
        case unsupportedWireVersion(String)
        case authenticationFailed
        case malformedPadding
        case malformedNonce(Int)
        case wrongKeySize(Int)

        var description: String {
            switch self {
            case .malformedEnvelope(let detail):
                return "the sealed record is not a well-formed envelope: \(detail)"
            case .unsupportedWireVersion(let version):
                return "sealed record uses wire version \"\(version)\"; this build understands \"\(SnippetCrypto.wireVersion)\""
            case .authenticationFailed:
                return "the sealed record did not authenticate"
            case .malformedPadding:
                return "the decrypted record was not padded by a build that speaks this format"
            case .malformedNonce(let count):
                return "a nonce source produced \(count) bytes; AES-GCM needs \(SnippetCrypto.nonceByteCount)"
            case .wrongKeySize(let count):
                return "expected a \(SnippetCrypto.keyByteCount)-byte key, got \(count)"
            }
        }
    }

    // MARK: - Key hierarchy

    /// `K_lib` plus the salt it is bound to. Everything else is derived on demand.
    ///
    /// Deliberately a value type with no caching. Deriving a subkey is one HKDF —
    /// microseconds — and a cache would mean a long-lived dictionary of live key
    /// material keyed by record id, which is precisely the thing we do not want
    /// sitting in the heap after the vault is locked.
    struct Keyring: Sendable {

        /// The root. **Never** passed to `seal` or `open`; the type system cannot
        /// enforce that (it is just a `SymmetricKey`), so this comment has to.
        let libraryKey: SymmetricKey

        /// Public, per-vault, stored in the clear alongside the wrapped key.
        let salt: Data

        init(libraryKey: SymmetricKey, salt: Data) {
            self.libraryKey = libraryKey
            self.salt = salt
        }

        /// A brand-new library: 256 random bits and a fresh salt, both from the
        /// system CSPRNG.
        static func generate() -> Keyring {
            Keyring(libraryKey: SymmetricKey(size: .bits256), salt: randomBytes(saltByteCount))
        }

        /// `K_rec(id)`. One key per record, so a 96-bit nonce can never collide
        /// across the library however many times a record is re-sealed.
        ///
        /// The info string mixes in the record's **raw 16 UUID bytes**, not its
        /// `uuidString`: the byte form is canonical, whereas the string form has a
        /// case convention that a future refactor could flip and silently re-key
        /// every record in the vault.
        func recordKey(for recordID: UUID) -> SymmetricKey {
            var info = Data(recordKeyInfoPrefix.utf8)
            withUnsafeBytes(of: recordID.uuid) { info.append(contentsOf: $0) }
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: libraryKey, salt: salt, info: info,
                outputByteCount: keyByteCount)
        }

        /// `K_hash`. Separate from every record key so that publishing a content
        /// hash (which `vault.json` does, in the clear) leaks nothing usable about
        /// the key that actually encrypts anything.
        var contentHashKey: SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: libraryKey, salt: salt, info: Data(contentHashInfo.utf8),
                outputByteCount: keyByteCount)
        }
    }

    // MARK: - Additional authenticated data

    /// Everything a ciphertext is pinned to. Not secret — all of it is already
    /// plaintext in `vault.json` — but authenticated, which is the point.
    struct RecordContext: Sendable, Equatable, Hashable {
        /// **Must come from the vault document (`VaultDocument.kid`), never from
        /// `SyncState.scopeID`.**
        ///
        /// This string is inside the AAD of every record, so getting it wrong makes
        /// every secure snippet permanently undecryptable. `Sync/state.json` is exactly
        /// the wrong home for it: `SyncStateFile.load` deliberately returns a *fresh*
        /// state — with a newly minted `scopeID` — whenever that file is missing or
        /// unreadable, because it holds no user data and regenerating it is normally
        /// free. Sourcing the scope from there would turn "the sync bookkeeping file
        /// was lost" into "every secret is gone", with no warning and no recovery.
        ///
        /// The rule: the value that unlocks a file must live in that file. `kid` does.
        ///
        /// Reserved so a shared/team vault can exist later
        /// without re-encrypting anything; today it is one value per install.
        var scopeID: String
        var recordID: UUID
        /// A tombstone seals an empty body with this set. Binding it stops the two
        /// interesting replays: reinstating a deleted record by copying its old live
        /// ciphertext back over the tombstone, and blanking a live record by doing
        /// the reverse.
        var isDeleted: Bool

        init(scopeID: String, recordID: UUID, isDeleted: Bool = false) {
            self.scopeID = scopeID
            self.recordID = recordID
            self.isDeleted = isDeleted
        }
    }

    /// **The** AAD builder. There is exactly one, on purpose.
    ///
    /// AAD is only useful if both sides compute identical bytes, and "identical" is
    /// fragile: a call site that joins fields with `"|"` and another that joins with
    /// `":"` produce ciphertexts that cannot be opened by the other, and the failure
    /// surfaces months later as "some records won't decrypt on my other Mac". Worse,
    /// a hand-rolled builder that concatenates without length prefixes lets
    /// `scopeID: "ab", id: X` collide with `scopeID: "a", id: bX` — the exact identity
    /// confusion the AAD exists to prevent.
    static func additionalData(for context: RecordContext) -> Data {
        domainSeparated(additionalDataDomain, [
            Data(wireVersion.utf8),
            Data(context.scopeID.utf8),
            uuidBytes(context.recordID),
            Data([context.isDeleted ? 1 : 0]),
        ])
    }

    /// Length-prefixed concatenation: `u32be(len) ‖ bytes` for the domain tag and for
    /// every field. Injective by construction, so no two different field lists can
    /// ever produce the same output.
    static func domainSeparated(_ domain: String, _ fields: [Data]) -> Data {
        var out = Data()
        func append(_ field: Data) {
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(field)
        }
        append(Data(domain.utf8))
        for field in fields { append(field) }
        return out
    }

    // MARK: - Nonces

    /// Where the 12 bytes of every GCM nonce come from.
    ///
    /// Injected rather than hardwired so tests can assert on exact bytes. There is no
    /// `.fixed(_:)` convenience here and there must never be one: a reused nonce under
    /// a reused key in GCM does not merely leak the plaintext XOR, it leaks the
    /// authentication subkey and lets an attacker forge arbitrary records. Tests that
    /// want a stationary nonce construct the closure themselves, where the choice is
    /// visible in the test.
    struct NonceSource: Sendable {
        let nextNonce: @Sendable () -> Data

        init(_ nextNonce: @escaping @Sendable () -> Data) {
            self.nextNonce = nextNonce
        }

        /// CryptoKit's own random nonce, which is the system CSPRNG.
        static var system: NonceSource {
            NonceSource { Data(AES.GCM.Nonce()) }
        }
    }

    // MARK: - Envelope

    /// The on-disk / on-the-wire form: `"v1.<b64url nonce>.<b64url ct‖tag>"`.
    ///
    /// One line of URL-safe ASCII, because it has to survive being a JSON string, a
    /// log line, an S3 object body, and the odd copy/paste — and because a
    /// human-readable version prefix means a future format change fails loudly at the
    /// first character instead of decoding into garbage.
    struct Envelope: Sendable, Equatable {
        let version: String
        let nonce: Data
        /// AES-GCM ciphertext with its 16-byte tag appended.
        let sealed: Data

        var text: String {
            "\(version).\(base64URL(nonce)).\(base64URL(sealed))"
        }

        static func parse(_ text: String) throws -> Envelope {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                throw Failure.malformedEnvelope("expected 3 dot-separated fields, found \(parts.count)")
            }
            guard let nonce = data(fromBase64URL: String(parts[1])) else {
                throw Failure.malformedEnvelope("nonce is not base64url")
            }
            guard let sealed = data(fromBase64URL: String(parts[2])) else {
                throw Failure.malformedEnvelope("body is not base64url")
            }
            return Envelope(version: String(parts[0]), nonce: nonce, sealed: sealed)
        }
    }

    // MARK: - Seal and open

    /// Seals a record body for a specific record identity.
    ///
    /// This is the entry point call sites should use: it derives the record key and
    /// builds the AAD from the same `context`, so the two cannot drift apart. The
    /// lower-level `seal(_:key:aad:nonces:)` exists for `PassphraseKDF`, which seals
    /// something that is not a record.
    static func seal(
        _ plaintext: Data,
        for context: RecordContext,
        keyring: Keyring,
        nonces: NonceSource = .system
    ) throws -> String {
        try seal(
            plaintext,
            key: keyring.recordKey(for: context.recordID),
            aad: additionalData(for: context),
            nonces: nonces)
    }

    /// Opens a record body sealed by `seal(_:for:keyring:nonces:)`.
    ///
    /// A ciphertext sealed under a different `context` — a different record id, a
    /// different scope, or the opposite `isDeleted` — fails here, because the id
    /// changes the key *and* the AAD and the other two change the AAD.
    static func open(
        _ envelope: String,
        for context: RecordContext,
        keyring: Keyring
    ) throws -> Data {
        try open(
            envelope,
            key: keyring.recordKey(for: context.recordID),
            aad: additionalData(for: context))
    }

    /// Pads, then seals with a fresh nonce.
    ///
    /// - Parameter aad: **must** come from `additionalData(for:)` (or, for the key
    ///   wrapper, from `PassphraseKDF.additionalData(alg:iterations:salt:)`). AES-GCM
    ///   accepts empty AAD happily and nothing here can tell the difference, so this
    ///   is a rule rather than a check.
    static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        aad: Data,
        nonces: NonceSource = .system
    ) throws -> String {
        guard key.bitCount == keyByteCount * 8 else { throw Failure.wrongKeySize(key.bitCount / 8) }

        let nonceBytes = nonces.nextNonce()
        guard nonceBytes.count == nonceByteCount else {
            throw Failure.malformedNonce(nonceBytes.count)
        }
        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes) else {
            throw Failure.malformedNonce(nonceBytes.count)
        }

        guard let box = try? AES.GCM.seal(
            Padding.pad(plaintext), using: key, nonce: nonce, authenticating: aad)
        else {
            // CryptoKit only fails here for inputs no caller can produce (a > 2^36-byte
            // message). Reported as a malformed envelope rather than crashing: this
            // runs on the sync path, and a crash loop is worse than a quarantined record.
            throw Failure.malformedEnvelope("AES-GCM refused a \(plaintext.count)-byte body")
        }

        return Envelope(version: wireVersion, nonce: nonceBytes, sealed: box.ciphertext + box.tag).text
    }

    /// Parses, authenticates, decrypts, and unpads. Returns the exact bytes handed to
    /// `seal`.
    static func open(_ envelope: String, key: SymmetricKey, aad: Data) throws -> Data {
        guard key.bitCount == keyByteCount * 8 else { throw Failure.wrongKeySize(key.bitCount / 8) }

        let parsed = try Envelope.parse(envelope)
        guard parsed.version == wireVersion else {
            throw Failure.unsupportedWireVersion(parsed.version)
        }
        guard parsed.nonce.count == nonceByteCount else {
            throw Failure.malformedEnvelope("nonce is \(parsed.nonce.count) bytes, expected \(nonceByteCount)")
        }
        guard parsed.sealed.count > tagByteCount else {
            throw Failure.malformedEnvelope("body is too short to contain a tag")
        }

        let ciphertext = parsed.sealed.prefix(parsed.sealed.count - tagByteCount)
        let tag = parsed.sealed.suffix(tagByteCount)

        // One error for every failure mode below — see the note on `Failure`.
        guard let nonce = try? AES.GCM.Nonce(data: parsed.nonce),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let padded = try? AES.GCM.open(box, using: key, authenticating: aad)
        else {
            throw Failure.authenticationFailed
        }

        return try Padding.unpad(padded)
    }

    // MARK: - Content hash

    /// A **keyed** hash of the plaintext body: HMAC-SHA256 under `K_hash`, truncated
    /// to 128 bits and hex-encoded.
    ///
    /// ## Why keyed, and why this is not paranoia
    ///
    /// This hash is written to `vault.json` in the clear, and `vault.json` sits in an
    /// unsandboxed `~/Library/Application Support` directory that Time Machine copies,
    /// Migration Assistant carries to the next Mac, and any process running as the
    /// user can read. A bare `SHA256(plaintext)` of the things people actually put in
    /// a secure snippet — a six-digit OTP seed, a four-digit PIN, `hunter2`, a
    /// wifi password, a recovery phrase from a printed card — is recoverable by
    /// exhaustive search in *seconds*, and by rainbow table instantly. Every byte of
    /// AES-GCM above would be decoration if the file shipped an unkeyed fingerprint of
    /// the same plaintext next to it. Under HMAC with a key derived from `K_lib`, the
    /// hash is a pseudorandom 128-bit label to anyone without the vault key.
    ///
    /// ## What it is for
    ///
    /// Two things the sync layer cannot do without:
    ///
    /// 1. **A locked vault can still merge.** With the vault locked we hold no key and
    ///    cannot read any body — but we can compare our stored hash against the remote
    ///    one and answer "did the body change?", which is all `SyncMerge` needs to
    ///    decide whether this is a conflict. Without it, locking the vault would mean
    ///    suspending sync.
    /// 2. **A re-seal is not an edit.** Every `seal` draws a fresh nonce, so sealing
    ///    identical plaintext twice produces completely different ciphertext. Compare
    ///    envelopes and every record looks edited on every sync, forever, and two
    ///    devices ping-pong rewrites at each other. Compare hashes and an unchanged
    ///    body is visibly unchanged.
    ///
    /// ## What it leaks
    ///
    /// Two records with byte-identical bodies get identical hashes, so an attacker
    /// with the file learns "these two secure snippets have the same content" — and,
    /// across a history of the file, learns *when* a body changed. Binding the record
    /// id into the hash would hide the first but destroy the second use above (a body
    /// moved between records would look changed). The leak is small and the
    /// alternative costs a real feature, so: stated, not fixed.
    ///
    /// 128 bits is truncation, not weakness: this is a change detector, and second
    /// preimages at 2^128 under a secret key are not a threat anyone can mount.
    static func contentHash(of plaintext: Data, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: plaintext, using: key)
            .prefix(contentHashByteCount)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func contentHash(of plaintext: Data, keyring: Keyring) -> String {
        contentHash(of: plaintext, key: keyring.contentHashKey)
    }

    // MARK: - Padding

    /// Length hiding. Everything is sealed at a multiple of 256 bytes.
    ///
    /// GCM is a stream cipher mode: ciphertext length equals plaintext length exactly.
    /// Without padding, `vault.json` publishes the precise byte length of every secret
    /// it holds — and a 6-byte body is a PIN, a 16-byte body is very likely a wifi
    /// password, a 300-byte body is a note, and watching one record go from 44 bytes
    /// to 45 tells an observer the user just changed a password by one character.
    /// Rounding to 256 collapses all of that into "small", "medium", "large".
    ///
    /// The scheme is ISO/IEC 7816-4: append `0x80`, then `0x00` to the next multiple.
    /// It is unambiguous (there is exactly one `0x80` after the last content byte, and
    /// only zeros follow it), it never has a zero-length pad to get confused about,
    /// and it needs no length field that a future format change could disagree on.
    /// The cost is that a 3-byte snippet occupies 256 bytes on the wire, which for a
    /// library of a few hundred secure snippets is well under a megabyte.
    enum Padding {
        static let blockSize = 256

        static func pad(_ plaintext: Data) -> Data {
            var padded = plaintext
            padded.append(0x80)
            let remainder = padded.count % blockSize
            if remainder != 0 {
                padded.append(contentsOf: repeatElement(UInt8(0), count: blockSize - remainder))
            }
            return padded
        }

        /// Strict on purpose. This only ever runs on bytes that already passed the GCM
        /// tag, so malformed padding cannot be an attacker probing an oracle — it means
        /// a peer sealed with a padding scheme we do not speak, and applying a
        /// half-understood body to the user's library is worse than refusing it.
        static func unpad(_ padded: Data) throws -> Data {
            guard !padded.isEmpty, padded.count % blockSize == 0 else {
                throw Failure.malformedPadding
            }
            var index = padded.endIndex - 1
            while index >= padded.startIndex, padded[index] == 0x00 { index -= 1 }
            guard index >= padded.startIndex, padded[index] == 0x80 else {
                throw Failure.malformedPadding
            }
            return Data(padded[padded.startIndex..<index])
        }
    }

    // MARK: - Plumbing

    /// The final hop, and the only place plaintext becomes a `String`.
    ///
    /// Returns `nil` for invalid UTF-8 rather than substituting replacement
    /// characters: a body that does not decode is a body we do not understand, and
    /// typing U+FFFD into someone's terminal is not an improvement.
    ///
    /// Once this returns, the secret is in a `String` and **cannot be wiped**. Swift
    /// strings under 16 bytes live inline in the value and get copied by every
    /// assignment; larger ones sit in a refcounted buffer with no supported way to
    /// overwrite it. Call this as late as possible, keep the result in the narrowest
    /// scope you can, and do not pretend that scope is a security boundary.
    static func plaintextString(_ plaintext: Data) -> String? {
        String(data: plaintext, encoding: .utf8)
    }

    /// System CSPRNG bytes. `SystemRandomNumberGenerator` is `arc4random_buf` on
    /// Darwin, which is what `SecRandomCopyBytes` also is — and this way the file
    /// keeps its promise not to link Security.framework.
    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func uuidBytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    // MARK: - base64url
    //
    // Written out rather than pulled from a dependency because the envelope has to be
    // byte-stable across builds forever, and because the padding-stripping detail is
    // exactly the kind of thing two libraries disagree about.

    private static let base64URLAlphabet = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func base64URL(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-")
        text = text.replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    /// Rejects anything outside the URL-safe alphabet, including the `=` padding and
    /// the standard `+` and `/`. The encoder above never emits them, so accepting them
    /// would mean two spellings of the same envelope — and an envelope that is
    /// compared for equality (which `SyncMerge` does) must have exactly one spelling.
    static func data(fromBase64URL text: String) -> Data? {
        guard !text.isEmpty, text.allSatisfy({ base64URLAlphabet.contains($0) }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 0: break
        case 2: base64 += "=="
        case 3: base64 += "="
        default: return nil   // a length of 4n+1 cannot be base64 of anything
        }
        return Data(base64Encoded: base64)
    }
}
