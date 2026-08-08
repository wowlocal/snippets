import Foundation
import CryptoKit
import Testing

@testable import SnippetsCore

// The crypto for secure ("vault") snippets: `SnippetCrypto.swift` (the AEAD wire
// layer), `PassphraseKDF.swift` (wrapping the library key under a passphrase), and
// `RecoveryKey.swift` (the written-down second door).
//
// Every test below names the failure it prevents rather than the code path it walks.
// The failures in this file are not "a function returned the wrong number" — they are
// "someone's OTP seed was recoverable from a Time Machine backup" and "the user typed
// their recovery key correctly and we told them it was wrong". They are written to
// read that way.
//
// Nothing here touches the filesystem, so there is no scratch directory: these types
// take their key material, their salt, and their nonces as parameters precisely so a
// test never has to reach for the real support folder.

// MARK: - Fixtures

/// A fixed root key. Deliberately not `Keyring.generate()`: a random key per run means
/// a failure that reproduces only sometimes, and none of the properties below depend
/// on the key being unpredictable.
private func keyring(
    libraryByte: UInt8 = 0x11,
    saltByte: UInt8 = 0x22
) -> SnippetCrypto.Keyring {
    SnippetCrypto.Keyring(
        libraryKey: SymmetricKey(data: Data(repeating: libraryByte, count: SnippetCrypto.keyByteCount)),
        salt: Data(repeating: saltByte, count: SnippetCrypto.saltByteCount))
}

private let scope = "e3b0c442-98fc-4c14-9afb-f4c8996fb924"

/// Ids laid out so a test can say "record 0" and "record 1" and mean it.
private func id(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index))!
}

private func context(_ index: Int, deleted: Bool = false, scopeID: String = scope) -> SnippetCrypto.RecordContext {
    SnippetCrypto.RecordContext(scopeID: scopeID, recordID: id(index), isDeleted: deleted)
}

private func body(_ text: String) -> Data { Data(text.utf8) }

// MARK: - A nonce source the test drives by hand
//
// `SnippetCrypto.NonceSource` deliberately ships no `.fixed(_:)` convenience — a
// stationary GCM nonce leaks the authentication subkey, so the decision to use one has
// to be visible in the code making it. Here it is, visible.

private final class CountedNonces: @unchecked Sendable {
    private let lock = NSLock()
    private var issued: UInt32 = 0

    /// A distinct, predictable nonce per call: eleven zero bytes and a counter.
    var source: SnippetCrypto.NonceSource {
        SnippetCrypto.NonceSource { [self] in
            lock.lock()
            defer { lock.unlock() }
            issued &+= 1
            var bytes = Data(repeating: 0, count: SnippetCrypto.nonceByteCount)
            bytes[SnippetCrypto.nonceByteCount - 1] = UInt8(truncatingIfNeeded: issued)
            return bytes
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(issued)
    }
}

/// The one nonce nobody may ship: the same twelve bytes every time.
private func stationaryNonces(_ byte: UInt8 = 0x5A) -> SnippetCrypto.NonceSource {
    SnippetCrypto.NonceSource { Data(repeating: byte, count: SnippetCrypto.nonceByteCount) }
}

// MARK: - Deterministic randomness
//
// The xorshift from `SyncMergeTests.swift`, so a property failure reproduces exactly
// from the seed printed in the failure message.

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }

    mutating func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in byte() }) }
}

// MARK: - Envelope surgery
//
// Tampering has to be done on the *decoded* bytes and re-encoded, not by poking a
// character in the base64: flipping a base64 character can change padding bits and
// produce a length change rather than the single-bit edit the test means to make.

private func rebuilt(
    _ envelope: String,
    version: String? = nil,
    nonce: ((inout Data) -> Void)? = nil,
    sealed: ((inout Data) -> Void)? = nil
) throws -> String {
    let parsed = try SnippetCrypto.Envelope.parse(envelope)
    var nonceBytes = parsed.nonce
    var sealedBytes = parsed.sealed
    nonce?(&nonceBytes)
    sealed?(&sealedBytes)
    return SnippetCrypto.Envelope(
        version: version ?? parsed.version, nonce: nonceBytes, sealed: sealedBytes).text
}

private func flippingFirstBit(_ data: inout Data) {
    data[data.startIndex] ^= 0x01
}

// MARK: - Suite

@Suite("Vault crypto")
struct CryptoTests {

    // MARK: 1. Seal and open

    @Suite("Seal and open")
    struct SealAndOpen {

        /// The floor: what goes in comes out, byte for byte, across the lengths a
        /// snippet body actually takes — a PIN, a password, a paragraph, and something
        /// long enough to cross several padding blocks.
        @Test(arguments: [0, 1, 6, 16, 255, 256, 257, 1024, 10_000])
        func aSealedBodyOpensBackToTheExactBytesItWentInAs(length: Int) throws {
            var random = SeededRandom(seed: UInt64(length) &+ 1)
            let plaintext = random.bytes(length)
            let ring = keyring()

            let envelope = try SnippetCrypto.seal(plaintext, for: context(0), keyring: ring)
            let opened = try SnippetCrypto.open(envelope, for: context(0), keyring: ring)

            #expect(opened == plaintext)
        }

        /// Non-ASCII bodies are the case a naive `String`-based implementation breaks
        /// on, and a snippet body is very often an emoji-bearing signature block.
        @Test func aUTF8BodySurvivesTheRoundTripThroughDataAndBack() throws {
            let ring = keyring()
            let plaintext = body("café ☕️ — naïve 🔐 \u{1F1EF}\u{1F1F5}")

            let envelope = try SnippetCrypto.seal(plaintext, for: context(0), keyring: ring)
            let opened = try SnippetCrypto.open(envelope, for: context(0), keyring: ring)

            #expect(SnippetCrypto.plaintextString(opened) == "café ☕️ — naïve 🔐 \u{1F1EF}\u{1F1F5}")
        }

        /// The envelope has to survive being a JSON string, a log line, and an S3
        /// object body, so it must stay one line of URL-safe ASCII with a legible
        /// version prefix. A format change here is a compatibility break, and this test
        /// is what makes that break loud.
        @Test func theEnvelopeIsThreeDotSeparatedURLSafeFieldsBehindAVersionPrefix() throws {
            let ring = keyring()
            let envelope = try SnippetCrypto.seal(body("hunter2"), for: context(0), keyring: ring)

            let parts = envelope.split(separator: ".", omittingEmptySubsequences: false)
            #expect(parts.count == 3)
            #expect(parts[0] == "v1")

            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            #expect(parts[1].allSatisfy { allowed.contains($0) })
            #expect(parts[2].allSatisfy { allowed.contains($0) })

            let parsed = try SnippetCrypto.Envelope.parse(envelope)
            #expect(parsed.nonce.count == SnippetCrypto.nonceByteCount)
            #expect(parsed.text == envelope)
        }

        /// A future format must fail at the first character rather than decode into
        /// garbage — that is the entire reason the version is in the string.
        @Test func anEnvelopeFromAFutureWireVersionIsRefusedRatherThanGuessedAt() throws {
            let ring = keyring()
            let envelope = try SnippetCrypto.seal(body("secret"), for: context(0), keyring: ring)
            let future = try rebuilt(envelope, version: "v2")

            #expect(throws: SnippetCrypto.Failure.unsupportedWireVersion("v2")) {
                try SnippetCrypto.open(future, for: context(0), keyring: ring)
            }
        }

        @Test(arguments: [
            "", "v1", "v1.abc", "v1.abc.def.ghi", "v1..", "v1.$$$$.abcd", "v1.abcd.$$$$",
        ])
        func aStringThatIsNotAnEnvelopeIsRejectedWithoutTouchingAnyKeyMaterial(text: String) throws {
            let ring = keyring()
            #expect(throws: (any Error).self) {
                try SnippetCrypto.open(text, for: context(0), keyring: ring)
            }
        }

        /// A truncated body — the classic result of a partial upload or a truncated
        /// file — must not be mistaken for a tag failure or, worse, opened.
        @Test func anEnvelopeTooShortToHoldATagIsRejected() throws {
            let ring = keyring()
            let stub = SnippetCrypto.Envelope(
                version: "v1",
                nonce: Data(repeating: 0, count: SnippetCrypto.nonceByteCount),
                sealed: Data(repeating: 0, count: SnippetCrypto.tagByteCount)).text

            #expect(throws: (any Error).self) {
                try SnippetCrypto.open(stub, for: context(0), keyring: ring)
            }
        }
    }

    // MARK: 2. Tampering

    @Suite("Tampering")
    struct Tampering {

        /// One flipped bit anywhere in the ciphertext must fail the tag. Without this,
        /// the sync backend operator — who by the threat model sees only ciphertext —
        /// could still *change* what a user's snippet expands to, which is arguably
        /// worse than reading it.
        @Test func aFlippedBitInTheCiphertextFailsToOpen() throws {
            let ring = keyring()
            let envelope = try SnippetCrypto.seal(body("hunter2"), for: context(0), keyring: ring)
            let tampered = try rebuilt(envelope, sealed: flippingFirstBit)

            #expect(tampered != envelope)
            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(tampered, for: context(0), keyring: ring)
            }
        }

        /// The tag itself is at the end of the same field; edits there must fail too,
        /// rather than being treated as "no tag, so nothing to check".
        @Test func aFlippedBitInTheAuthenticationTagFailsToOpen() throws {
            let ring = keyring()
            let envelope = try SnippetCrypto.seal(body("hunter2"), for: context(0), keyring: ring)
            let tampered = try rebuilt(envelope) { sealed in
                sealed[sealed.endIndex - 1] ^= 0x01
            }

            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(tampered, for: context(0), keyring: ring)
            }
        }

        /// The nonce travels in the clear beside the ciphertext, so it is the easiest
        /// field to edit. GCM authenticates it implicitly — this test is what proves we
        /// did not accidentally build a construction where it does not.
        @Test func aFlippedBitInTheNonceFailsToOpen() throws {
            let ring = keyring()
            let envelope = try SnippetCrypto.seal(body("hunter2"), for: context(0), keyring: ring)
            let tampered = try rebuilt(envelope, nonce: flippingFirstBit)

            #expect(tampered != envelope)
            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(tampered, for: context(0), keyring: ring)
            }
        }

        /// Changing the AAD without changing anything else must fail. This is the
        /// property every identity-binding test below rests on, isolated: same key,
        /// same ciphertext, one byte different in the authenticated-but-unencrypted
        /// context.
        @Test func aCiphertextDoesNotOpenUnderDifferentAdditionalData() throws {
            let ring = keyring()
            let key = ring.recordKey(for: id(0))
            let envelope = try SnippetCrypto.seal(
                body("hunter2"), key: key, aad: SnippetCrypto.additionalData(for: context(0)))

            var altered = context(0)
            altered.scopeID += "x"

            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(
                    envelope, key: key, aad: SnippetCrypto.additionalData(for: altered))
            }
            // …and the untouched context still works, so the failure above is the AAD
            // and not something incidental about the fixture.
            #expect(try SnippetCrypto.open(
                envelope, key: key, aad: SnippetCrypto.additionalData(for: context(0))) == body("hunter2"))
        }

        /// Empty AAD is the shape an accidental `aad: Data()` takes, and AES-GCM accepts
        /// it perfectly happily. Nothing in `seal`/`open` can detect the mistake at
        /// runtime, so this test stands in for the rule.
        @Test func aCiphertextSealedWithRealAADDoesNotOpenWithEmptyAAD() throws {
            let ring = keyring()
            let key = ring.recordKey(for: id(0))
            let envelope = try SnippetCrypto.seal(
                body("hunter2"), key: key, aad: SnippetCrypto.additionalData(for: context(0)))

            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(envelope, key: key, aad: Data())
            }
        }
    }

    // MARK: 3. Identity binding

    @Suite("Identity binding")
    struct IdentityBinding {

        /// The positive control for every `#expect(throws:)` in this suite.
        ///
        /// Every other test here asserts only that the *wrong* context fails to open. A
        /// suite made entirely of negative assertions is satisfied by a build in which
        /// nothing decrypts at all — so it would pass with the protection it exists to
        /// test completely removed.
        ///
        /// That is not hypothetical. Sealing with an empty AAD while opening with the
        /// real one makes every open fail, which makes all six assertions below pass;
        /// the break was introduced deliberately and this suite did not notice. The rest
        /// of the crypto suite did, but a suite that cannot fail on its own subject is
        /// not doing its job. One positive assertion is the whole fix.
        @Test func thematchingContextOpensWhatItSealed() throws {
            let ring = keyring()
            let envelope = try SnippetCrypto.seal(body("123456"), for: context(0), keyring: ring)

            #expect(try SnippetCrypto.open(envelope, for: context(0), keyring: ring) == body("123456"))
        }

        /// The replay this whole AAD design exists to stop: lift the sealed body out of
        /// the "Bank OTP" record, paste it into the "Email signature" record, and wait
        /// for the user to expand their signature into a chat window.
        @Test func aBodySealedForOneRecordCannotBeOpenedAsAnother() throws {
            let ring = keyring()
            let envelope = try SnippetCrypto.seal(body("123456"), for: context(0), keyring: ring)

            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(envelope, for: context(1), keyring: ring)
            }
        }

        /// Belt and braces: the record id changes both the derived key *and* the AAD,
        /// so the previous test would still pass if one of the two bindings were
        /// missing. These two pin each binding separately.
        @Test func theRecordIdBindsThroughTheKeyEvenWhenTheAADIsHeldConstant() throws {
            let ring = keyring()
            let aad = SnippetCrypto.additionalData(for: context(0))
            let envelope = try SnippetCrypto.seal(body("123456"), key: ring.recordKey(for: id(0)), aad: aad)

            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(envelope, key: ring.recordKey(for: id(1)), aad: aad)
            }
        }

        @Test func theRecordIdBindsThroughTheAADEvenWhenTheKeyIsHeldConstant() throws {
            let ring = keyring()
            let key = ring.recordKey(for: id(0))
            let envelope = try SnippetCrypto.seal(
                body("123456"), key: key, aad: SnippetCrypto.additionalData(for: context(0)))

            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(
                    envelope, key: key, aad: SnippetCrypto.additionalData(for: context(1)))
            }
        }

        /// A tombstone seals an empty body with `isDeleted` set. Binding the flag stops
        /// both directions of the resurrection replay: putting a live record's old
        /// ciphertext back over its tombstone, and blanking a live record by pushing the
        /// tombstone's body at it.
        @Test func theDeletedFlagIsBoundSoATombstoneAndALiveRecordCannotBeSwapped() throws {
            let ring = keyring()
            let live = try SnippetCrypto.seal(body("still here"), for: context(0), keyring: ring)
            let dead = try SnippetCrypto.seal(Data(), for: context(0, deleted: true), keyring: ring)

            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(live, for: context(0, deleted: true), keyring: ring)
            }
            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(dead, for: context(0), keyring: ring)
            }
        }

        /// The scope exists so a shared/team vault can be added later without
        /// re-encrypting anything. It is only worth having if a record cannot be moved
        /// between scopes by editing a JSON field.
        @Test func theScopeIsBoundSoARecordCannotBeMovedBetweenVaults() throws {
            let ring = keyring()
            let envelope = try SnippetCrypto.seal(body("secret"), for: context(0), keyring: ring)

            #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
                try SnippetCrypto.open(
                    envelope, for: context(0, scopeID: "some-other-scope"), keyring: ring)
            }
        }

        /// A hand-rolled AAD that concatenates without length prefixes lets
        /// `scopeID: "ab"` + id `X` collide with `scopeID: "a"` + id `bX`. The single
        /// canonical builder is length-prefixed precisely so that cannot happen; this
        /// pins it.
        @Test func adjacentFieldsCannotBeShuffledAcrossTheAADBoundary() throws {
            let left = SnippetCrypto.domainSeparated("d", [body("ab"), body("c")])
            let right = SnippetCrypto.domainSeparated("d", [body("a"), body("bc")])
            #expect(left != right)

            let movedDomain = SnippetCrypto.domainSeparated("da", [body("b"), body("c")])
            #expect(movedDomain != left)
        }

        /// A key-wrapping envelope and a record envelope must never be interchangeable,
        /// or a `vault.json` edit could feed the wrapped library key to the record
        /// reader (and vice versa).
        @Test func theKeyWrappingDomainCannotCollideWithTheRecordDomain() {
            #expect(SnippetCrypto.additionalDataDomain != PassphraseKDF.additionalDataDomain)

            let record = SnippetCrypto.additionalData(for: context(0))
            let wrap = PassphraseKDF.additionalData(
                alg: PassphraseKDF.algorithm, iterations: 1, salt: Data(repeating: 0, count: 16),
                kid: "k-test")
            #expect(record != wrap)
        }
    }

    // MARK: 4. Nonces

    @Suite("Nonces")
    struct Nonces {

        /// Sealing the same bytes twice must produce two entirely different envelopes.
        /// If it did not, `vault.json` would publish "these two records hold the same
        /// secret" and an observer diffing the file over time would see exactly when a
        /// body was edited back to a previous value.
        @Test func theSamePlaintextSealedTwiceProducesDifferentBytes() throws {
            let ring = keyring()
            let plaintext = body("hunter2")

            let first = try SnippetCrypto.seal(plaintext, for: context(0), keyring: ring)
            let second = try SnippetCrypto.seal(plaintext, for: context(0), keyring: ring)

            #expect(first != second)
            #expect(try SnippetCrypto.Envelope.parse(first).nonce
                != SnippetCrypto.Envelope.parse(second).nonce)
            #expect(try SnippetCrypto.Envelope.parse(first).sealed
                != SnippetCrypto.Envelope.parse(second).sealed)

            // …and both still open, so the difference is nonce freshness rather than
            // one of them being broken.
            #expect(try SnippetCrypto.open(first, for: context(0), keyring: ring) == plaintext)
            #expect(try SnippetCrypto.open(second, for: context(0), keyring: ring) == plaintext)
        }

        /// A hundred seals of the same body under the same key produce a hundred
        /// distinct nonces. This is the property per-record subkeys exist to keep true
        /// over a library's lifetime.
        @Test func repeatedSealsNeverReuseANonce() throws {
            let ring = keyring()
            var nonces = Set<Data>()
            for _ in 0..<100 {
                let envelope = try SnippetCrypto.seal(body("same"), for: context(0), keyring: ring)
                nonces.insert(try SnippetCrypto.Envelope.parse(envelope).nonce)
            }
            #expect(nonces.count == 100)
        }

        /// The injected source is what makes the tests above reproducible, so it has to
        /// actually be consulted — once per seal, for exactly twelve bytes.
        @Test func theInjectedNonceSourceIsTheOnlyThingConsultedForNonces() throws {
            let ring = keyring()
            let nonces = CountedNonces()

            let first = try SnippetCrypto.seal(
                body("a"), for: context(0), keyring: ring, nonces: nonces.source)
            let second = try SnippetCrypto.seal(
                body("a"), for: context(0), keyring: ring, nonces: nonces.source)

            #expect(nonces.count == 2)
            var expected = Data(repeating: 0, count: SnippetCrypto.nonceByteCount)
            expected[SnippetCrypto.nonceByteCount - 1] = 1
            #expect(try SnippetCrypto.Envelope.parse(first).nonce == expected)
            expected[SnippetCrypto.nonceByteCount - 1] = 2
            #expect(try SnippetCrypto.Envelope.parse(second).nonce == expected)
        }

        /// A stationary nonce under one key is the catastrophic case. It is not
        /// detectable inside `seal` — this test documents what it looks like so nobody
        /// later mistakes the identical output for a caching win.
        @Test func aStationaryNonceProducesIdenticalCiphertextWhichIsWhyThereIsNoFixedConvenience() throws {
            let ring = keyring()
            let first = try SnippetCrypto.seal(
                body("hunter2"), for: context(0), keyring: ring, nonces: stationaryNonces())
            let second = try SnippetCrypto.seal(
                body("hunter2"), for: context(0), keyring: ring, nonces: stationaryNonces())

            #expect(first == second)
        }

        /// A source that hands back the wrong width must be refused rather than
        /// silently truncated or padded into a nonce that collides with another.
        @Test func aNonceSourceOfTheWrongWidthIsRefused() throws {
            let ring = keyring()
            let short = SnippetCrypto.NonceSource { Data(repeating: 0, count: 8) }

            #expect(throws: SnippetCrypto.Failure.malformedNonce(8)) {
                try SnippetCrypto.seal(body("x"), for: context(0), keyring: ring, nonces: short)
            }
        }
    }

    // MARK: 5. Key hierarchy

    @Suite("Key hierarchy")
    struct KeyHierarchy {

        /// `K_lib` is the root and must never encrypt anything. The type system cannot
        /// enforce that — both are `SymmetricKey` — so at minimum the derived keys must
        /// be provably different from it and from each other.
        @Test func everySubkeyDiffersFromTheRootAndFromEveryOtherSubkey() {
            let ring = keyring()
            let root = ring.libraryKey.withUnsafeBytes { Data($0) }
            let hash = ring.contentHashKey.withUnsafeBytes { Data($0) }
            let recordKeys = (0..<8).map { index in
                ring.recordKey(for: id(index)).withUnsafeBytes { Data($0) }
            }

            #expect(!recordKeys.contains(root))
            #expect(hash != root)
            #expect(!recordKeys.contains(hash))
            #expect(Set(recordKeys).count == recordKeys.count)
            #expect(recordKeys.allSatisfy { $0.count == SnippetCrypto.keyByteCount })
        }

        /// Derivation has to be a pure function of (root, salt, id): the same three
        /// inputs on another Mac must produce the same key, or a synced record only
        /// opens on the machine that wrote it.
        @Test func derivationIsDeterministicAcrossIndependentKeyringInstances() {
            let first = keyring().recordKey(for: id(3)).withUnsafeBytes { Data($0) }
            let second = keyring().recordKey(for: id(3)).withUnsafeBytes { Data($0) }
            #expect(first == second)
        }

        /// The salt is what separates two vaults that might otherwise derive related
        /// material — a cloned disk image, a restored backup, a future shared scope.
        @Test func adifferentSaltDerivesCompletelyDifferentSubkeys() {
            let a = keyring(saltByte: 0x22).recordKey(for: id(0)).withUnsafeBytes { Data($0) }
            let b = keyring(saltByte: 0x33).recordKey(for: id(0)).withUnsafeBytes { Data($0) }
            #expect(a != b)

            let hashA = keyring(saltByte: 0x22).contentHashKey.withUnsafeBytes { Data($0) }
            let hashB = keyring(saltByte: 0x33).contentHashKey.withUnsafeBytes { Data($0) }
            #expect(hashA != hashB)
        }

        /// A generated keyring must actually be random — a fixture-shaped bug here
        /// (returning a zero key, say) would be invisible in every other test in this
        /// file, all of which supply their own key material.
        @Test func aGeneratedKeyringIsFullWidthAndNotRepeatable() {
            let a = SnippetCrypto.Keyring.generate()
            let b = SnippetCrypto.Keyring.generate()

            #expect(a.salt.count == SnippetCrypto.saltByteCount)
            #expect(a.libraryKey.bitCount == SnippetCrypto.keyByteCount * 8)
            #expect(a.salt != b.salt)
            #expect(a.libraryKey.withUnsafeBytes { Data($0) } != b.libraryKey.withUnsafeBytes { Data($0) })
            #expect(a.libraryKey.withUnsafeBytes { Data($0) } != Data(repeating: 0, count: 32))
        }

        /// A short key is a programming error that must not reach AES-GCM, where it
        /// would either trap or quietly encrypt under something weaker than advertised.
        @Test func aKeyOfTheWrongWidthIsRefusedBySealAndOpen() throws {
            let stunted = SymmetricKey(data: Data(repeating: 0, count: 16))

            #expect(throws: SnippetCrypto.Failure.wrongKeySize(16)) {
                try SnippetCrypto.seal(body("x"), key: stunted, aad: Data())
            }
            #expect(throws: SnippetCrypto.Failure.wrongKeySize(16)) {
                try SnippetCrypto.open("v1.AAAAAAAAAAAAAAAA.AAAAAAAAAAAAAAAAAAAAAA", key: stunted, aad: Data())
            }
        }
    }

    // MARK: 6. Padding

    @Suite("Padding")
    struct PaddingTests {

        /// The lengths that break a naive implementation: empty, one byte, exactly one
        /// byte short of a block, exactly a block (where a zero-length pad would be
        /// ambiguous), one over, and something large.
        @Test(arguments: [0, 1, 255, 256, 257, 10_000])
        func paddingRoundTripsAtEveryAwkwardLength(length: Int) throws {
            var random = SeededRandom(seed: UInt64(length) &+ 7)
            let plaintext = random.bytes(length)

            let padded = SnippetCrypto.Padding.pad(plaintext)
            #expect(padded.count % SnippetCrypto.Padding.blockSize == 0)
            #expect(padded.count > length)
            #expect(try SnippetCrypto.Padding.unpad(padded) == plaintext)
        }

        /// A body ending in zero bytes is the case a "strip trailing zeros" scheme gets
        /// wrong: the content's own zeros are indistinguishable from the pad. The `0x80`
        /// marker is what makes it unambiguous, and this is the test that would catch
        /// its removal.
        @Test(arguments: [0, 1, 200, 255, 256])
        func aBodyThatEndsInItsOwnZeroBytesStillRoundTrips(trailingZeros: Int) throws {
            let plaintext = body("payload") + Data(repeating: 0, count: trailingZeros)
            let padded = SnippetCrypto.Padding.pad(plaintext)
            #expect(try SnippetCrypto.Padding.unpad(padded) == plaintext)
        }

        /// A body ending in `0x80` — perfectly legal UTF-8 continuation byte territory
        /// — must not be mistaken for the pad marker.
        @Test func aBodyThatEndsInTheMarkerByteStillRoundTrips() throws {
            let plaintext = Data([0x41, 0x80, 0x80])
            #expect(try SnippetCrypto.Padding.unpad(SnippetCrypto.Padding.pad(plaintext)) == plaintext)
        }

        /// The point of the exercise: short secrets must be indistinguishable by length.
        /// A four-digit PIN and a sixteen-character wifi password have to produce the
        /// same number of ciphertext bytes, or the padding is decoration.
        @Test func everyShortSecretSealsToTheSameNumberOfBytes() throws {
            let ring = keyring()
            let bodies = ["1234", "hunter2", "correct horse battery staple", String(repeating: "x", count: 200)]

            let sizes = try Set(bodies.map { text -> Int in
                let envelope = try SnippetCrypto.seal(body(text), for: context(0), keyring: ring)
                return try SnippetCrypto.Envelope.parse(envelope).sealed.count
            })

            #expect(sizes == [SnippetCrypto.Padding.blockSize + SnippetCrypto.tagByteCount])
        }

        /// Padding that we did not write means a peer speaking a format we do not
        /// understand. Applying a half-understood body to the user's library is worse
        /// than refusing it, so `unpad` is strict.
        @Test(arguments: [
            Data(),                                            // nothing at all
            Data(repeating: 0, count: 255),                    // not a block multiple
            Data(repeating: 0, count: 256),                    // all zeros: no marker
            Data(repeating: 0x41, count: 256),                 // no marker anywhere
        ])
        func malformedPaddingIsRefusedRatherThanTruncatedIntoSomething(padded: Data) {
            #expect(throws: SnippetCrypto.Failure.malformedPadding) {
                try SnippetCrypto.Padding.unpad(padded)
            }
        }

        /// `unpad` runs on `Data` handed back by CryptoKit today, but a future caller
        /// could pass a slice with a non-zero `startIndex`, and index arithmetic that
        /// assumes zero would silently return the wrong bytes.
        @Test func unpadHandlesASliceWhoseIndicesDoNotStartAtZero() throws {
            let plaintext = body("hunter2")
            let padded = Data(repeating: 0xEE, count: 9) + SnippetCrypto.Padding.pad(plaintext)
            #expect(try SnippetCrypto.Padding.unpad(padded.dropFirst(9)) == plaintext)
        }
    }

    // MARK: 7. Content hash

    @Suite("Content hash")
    struct ContentHash {

        /// Equal bodies hash equally — this is what lets the merge see "unchanged".
        @Test func equalPlaintextAlwaysProducesTheSameHash() {
            let ring = keyring()
            let first = SnippetCrypto.contentHash(of: body("hunter2"), keyring: ring)
            let second = SnippetCrypto.contentHash(of: body("hunter2"), keyring: ring)

            #expect(first == second)
            #expect(first.count == SnippetCrypto.contentHashByteCount * 2)
            #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }

        @Test func differentPlaintextProducesADifferentHash() {
            let ring = keyring()
            #expect(SnippetCrypto.contentHash(of: body("hunter2"), keyring: ring)
                != SnippetCrypto.contentHash(of: body("hunter3"), keyring: ring))
            // A one-byte body and the empty body are the pair a length-only or
            // prefix-only implementation would collide.
            #expect(SnippetCrypto.contentHash(of: Data(), keyring: ring)
                != SnippetCrypto.contentHash(of: Data([0]), keyring: ring))
        }

        /// The whole reason the hash is keyed. Two vaults holding the same six-digit
        /// code must not publish the same fingerprint of it — otherwise anyone with a
        /// Time Machine copy recovers the secret by hashing a million candidates, and
        /// every byte of AES-GCM above is decoration.
        @Test func adifferentKeyProducesADifferentHashOfTheSamePlaintext() {
            let plaintext = body("123456")
            let underLibraryKeyA = SnippetCrypto.contentHash(of: plaintext, keyring: keyring(libraryByte: 0x11))
            let underLibraryKeyB = SnippetCrypto.contentHash(of: plaintext, keyring: keyring(libraryByte: 0x12))
            let underSaltB = SnippetCrypto.contentHash(of: plaintext, keyring: keyring(saltByte: 0x23))

            #expect(underLibraryKeyA != underLibraryKeyB)
            #expect(underLibraryKeyA != underSaltB)
        }

        /// Concretely: the hash must not be the bare SHA-256 anybody can compute
        /// offline. A regression to `SHA256.hash(data:)` would pass every other test in
        /// this suite and quietly undo the file's main security claim.
        @Test func theHashIsNotSomethingAnAttackerCanComputeWithoutTheKey() {
            let plaintext = body("123456")
            let unkeyed = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
            let keyed = SnippetCrypto.contentHash(of: plaintext, keyring: keyring())

            #expect(keyed != String(unkeyed.prefix(keyed.count)))
        }

        /// The second job of the hash: a re-seal draws a fresh nonce and produces
        /// entirely different ciphertext, and without a stable hash every sync round
        /// would see every record as edited and two devices would rewrite the file at
        /// each other forever.
        @Test func aResealChangesTheCiphertextButNotTheContentHash() throws {
            let ring = keyring()
            let plaintext = body("unchanged body")

            let first = try SnippetCrypto.seal(plaintext, for: context(0), keyring: ring)
            let second = try SnippetCrypto.seal(plaintext, for: context(0), keyring: ring)

            #expect(first != second)
            #expect(SnippetCrypto.contentHash(of: plaintext, keyring: ring)
                == SnippetCrypto.contentHash(of: plaintext, keyring: ring))
        }

        /// A locked vault holds no key material at all, so it can only compare stored
        /// hashes — which is exactly what makes merging possible while locked. Pin the
        /// property the merge relies on: hashes are comparable as opaque strings.
        @Test func aLockedVaultCanTellChangedFromUnchangedUsingOnlyStoredHashes() {
            let ring = keyring()
            let storedLocally = SnippetCrypto.contentHash(of: body("v1 body"), keyring: ring)
            let arrivedFromRemoteUnchanged = SnippetCrypto.contentHash(of: body("v1 body"), keyring: ring)
            let arrivedFromRemoteEdited = SnippetCrypto.contentHash(of: body("v2 body"), keyring: ring)

            #expect(storedLocally == arrivedFromRemoteUnchanged)
            #expect(storedLocally != arrivedFromRemoteEdited)
        }
    }

    // MARK: 8. Passphrase wrapping

    @Suite("Passphrase wrapping")
    struct PassphraseWrapping {

        /// A cheap iteration count for the tests that are about *behaviour*. The pinned
        /// 600 000 is exercised once, below, where the cost is the point.
        static let fastIterations = 2_000

        static let salt = Data(repeating: 0x5E, count: PassphraseKDF.saltByteCount)

        /// Every wrap of `K_lib` authenticates the vault it belongs to. Fixed here so
        /// the tests that tamper with a field are tampering with that field alone.
        static let kid = "k-test"

        /// The number is a shipped security parameter, not a tuning knob. If somebody
        /// lowers it, that has to be a deliberate commit that also edits this line.
        @Test func theIterationCountAndAlgorithmAreThePinnedOnes() {
            #expect(PassphraseKDF.iterations == 600_000)
            #expect(PassphraseKDF.algorithm == "pbkdf2-hmac-sha512")
        }

        @Test func wrappingAndUnwrappingRecoversTheExactLibraryKey() throws {
            let libraryKey = SymmetricKey(size: .bits256)
            let wrapped = try PassphraseKDF.wrap(
                libraryKey, passphrase: "correct horse battery staple",
                salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)

            let recovered = try PassphraseKDF.unwrap(wrapped, passphrase: "correct horse battery staple", kid: Self.kid)

            #expect(recovered.withUnsafeBytes { Data($0) } == libraryKey.withUnsafeBytes { Data($0) })
        }

        /// At full strength, once. This is the only test that pays the real half-second,
        /// and it is here so the pinned parameters are known to actually work end to end
        /// rather than only in their cheap form.
        @Test func wrappingAndUnwrappingWorksAtThePinnedIterationCount() throws {
            let libraryKey = SymmetricKey(size: .bits256)
            let wrapped = try PassphraseKDF.wrap(
                libraryKey, passphrase: "a real passphrase", salt: Self.salt, kid: Self.kid)

            #expect(wrapped.iterations == PassphraseKDF.iterations)
            #expect(try PassphraseKDF.unwrap(wrapped, passphrase: "a real passphrase", kid: Self.kid)
                .withUnsafeBytes { Data($0) } == libraryKey.withUnsafeBytes { Data($0) })
        }

        /// The one that matters: a wrong passphrase must *throw*, never return
        /// plausible-looking bytes. A KDF that returned garbage on failure would hand
        /// the caller a key that decrypts nothing, and the resulting "your vault is
        /// corrupt" is a far worse thing to show a user than "wrong passphrase".
        @Test func awrongPassphraseThrowsRatherThanReturningGarbageBytes() throws {
            let libraryKey = SymmetricKey(size: .bits256)
            let wrapped = try PassphraseKDF.wrap(
                libraryKey, passphrase: "the right one",
                salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)

            #expect(throws: PassphraseKDF.Failure.wrongPassphrase) {
                try PassphraseKDF.unwrap(wrapped, passphrase: "the wrong one", kid: Self.kid)
            }
            // Including the near-miss cases a case-folding or trimming bug would let
            // through.
            for nearMiss in ["The right one", "the right one ", "the right on", "therightone"] {
                #expect(throws: PassphraseKDF.Failure.wrongPassphrase) {
                    try PassphraseKDF.unwrap(wrapped, passphrase: nearMiss, kid: Self.kid)
                }
            }
        }

        /// There is no verifier field, deliberately — the AEAD tag is the only gate. So
        /// the stored record must contain nothing beyond the four fields, and in
        /// particular nothing derived from the key that an attacker could check against
        /// offline more cheaply than the ciphertext.
        @Test func theStoredRecordCarriesNoSecondOracle() throws {
            let wrapped = try PassphraseKDF.wrap(
                SymmetricKey(size: .bits256), passphrase: "p",
                salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)

            let encoded = try JSONEncoder().encode(wrapped)
            let fields = try #require(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

            #expect(Set(fields.keys) == ["alg", "iterations", "salt", "envelope"])
        }

        /// An attacker who can write to `vault.json` must not be able to rewrite
        /// 600 000 to 1, hand the file back, and make every subsequent guess cost one
        /// HMAC.
        ///
        /// What stops it is the **derivation**, not the AAD: `iterations` is an input to
        /// PBKDF2, so a different count yields a different key and the tag fails. This
        /// test used to claim the AAD was the mechanism; deleting `iterations` from
        /// `PassphraseKDF.additionalData` leaves the whole suite green, which is how the
        /// claim was found to be false. The property below is the one that matters and
        /// it holds either way — only the explanation was wrong.
        @Test func loweringTheIterationCountInTheFileBreaksTheUnwrapRatherThanCheapeningIt() throws {
            let libraryKey = SymmetricKey(size: .bits256)
            var wrapped = try PassphraseKDF.wrap(
                libraryKey, passphrase: "p", salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)

            wrapped.iterations = 1

            #expect(throws: PassphraseKDF.Failure.wrongPassphrase) {
                try PassphraseKDF.unwrap(wrapped, passphrase: "p", kid: Self.kid)
            }
        }

        /// Same argument for the salt: swapping in another record's salt must not
        /// produce a working unwrap under some other passphrase.
        @Test func editingTheSaltInTheFileBreaksTheUnwrap() throws {
            var wrapped = try PassphraseKDF.wrap(
                SymmetricKey(size: .bits256), passphrase: "p",
                salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)

            wrapped.salt = SnippetCrypto.base64URL(Data(repeating: 0x01, count: PassphraseKDF.saltByteCount))

            #expect(throws: PassphraseKDF.Failure.wrongPassphrase) {
                try PassphraseKDF.unwrap(wrapped, passphrase: "p", kid: Self.kid)
            }
        }

        /// A structural problem with the file must not be reported as a wrong
        /// passphrase, or the user retypes a correct passphrase forever while the real
        /// fault is a truncated download.
        @Test func atruncatedFileIsReportedAsStructuralRatherThanAsAWrongPassphrase() throws {
            var wrapped = try PassphraseKDF.wrap(
                SymmetricKey(size: .bits256), passphrase: "p",
                salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)
            wrapped.envelope = "v1.notanenvelope"

            #expect(throws: SnippetCrypto.Failure.self) {
                try PassphraseKDF.unwrap(wrapped, passphrase: "p", kid: Self.kid)
            }

            wrapped.alg = "argon2id"
            #expect(throws: PassphraseKDF.Failure.unsupportedAlgorithm("argon2id")) {
                try PassphraseKDF.unwrap(wrapped, passphrase: "p", kid: Self.kid)
            }
        }

        /// A hostile or corrupted file claiming two billion rounds would wedge the
        /// unlock path inside an uninterruptible C call.
        @Test func anAbsurdIterationCountIsRefusedBeforeAnyWorkHappens() throws {
            var wrapped = try PassphraseKDF.wrap(
                SymmetricKey(size: .bits256), passphrase: "p",
                salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)
            wrapped.iterations = PassphraseKDF.maximumIterations + 1

            #expect(throws: PassphraseKDF.Failure.self) {
                try PassphraseKDF.unwrap(wrapped, passphrase: "p", kid: Self.kid)
            }
        }

        /// "é" is one code point or two depending on the keyboard, the input method, and
        /// whether a password manager autofilled it. Two spellings of a visually
        /// identical passphrase must not derive two different keys — that failure looks
        /// to the user like "the app rejected my correct passphrase".
        ///
        /// The trap is sharper than it looks, and the two assertions below are the whole
        /// story: Swift's `==` on `String` compares by *canonical equivalence*, so these
        /// two are the same string as far as every `if` statement in the app is
        /// concerned — while their UTF-8 bytes, which are what PBKDF2 actually consumes,
        /// are different lengths. Without the NFC pass in `derive`, the app would
        /// cheerfully agree the user typed the right passphrase and still fail to unlock.
        @Test func twoUnicodeSpellingsOfTheSamePassphraseUnlockTheSameVault() throws {
            let composed = "caf\u{00E9} r\u{00E9}sum\u{00E9}"          // é as one code point
            let decomposed = "cafe\u{0301} re\u{0301}sume\u{0301}"     // é as e + combining acute
            #expect(composed == decomposed)
            #expect(Array(composed.utf8) != Array(decomposed.utf8))

            let libraryKey = SymmetricKey(size: .bits256)
            let wrapped = try PassphraseKDF.wrap(
                libraryKey, passphrase: composed, salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)

            #expect(try PassphraseKDF.unwrap(wrapped, passphrase: decomposed, kid: Self.kid)
                .withUnsafeBytes { Data($0) } == libraryKey.withUnsafeBytes { Data($0) })
        }

        /// An empty passphrase protects nothing, and a wrapped key that appears
        /// protected but is not is worse than an unwrapped one.
        @Test func anEmptyPassphraseIsRefused() {
            #expect(throws: PassphraseKDF.Failure.emptyPassphrase) {
                try PassphraseKDF.wrap(
                    SymmetricKey(size: .bits256), passphrase: "",
                    salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)
            }
        }

        /// The wrapped key is a real AEAD envelope over exactly 32 bytes, and the
        /// padding hides even that — so the file does not advertise the key length.
        @Test func theWrappedKeyIsAPaddedEnvelopeLikeAnyOtherRecord() throws {
            let wrapped = try PassphraseKDF.wrap(
                SymmetricKey(size: .bits256), passphrase: "p",
                salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)

            let parsed = try SnippetCrypto.Envelope.parse(wrapped.envelope)
            #expect(parsed.version == SnippetCrypto.wireVersion)
            #expect(parsed.sealed.count == SnippetCrypto.Padding.blockSize + SnippetCrypto.tagByteCount)
        }

        /// Derivation must be a pure function of (passphrase, salt, iterations) —
        /// otherwise a passphrase that works on one Mac fails on another.
        @Test func derivationIsDeterministicAndSaltSeparated() throws {
            let a = try PassphraseKDF.derive(passphrase: "p", salt: Self.salt, iterations: 1_000)
            let b = try PassphraseKDF.derive(passphrase: "p", salt: Self.salt, iterations: 1_000)
            let otherSalt = try PassphraseKDF.derive(
                passphrase: "p", salt: Data(repeating: 0x01, count: 16), iterations: 1_000)
            let otherCount = try PassphraseKDF.derive(passphrase: "p", salt: Self.salt, iterations: 1_001)

            #expect(a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) })
            #expect(a.withUnsafeBytes { Data($0) } != otherSalt.withUnsafeBytes { Data($0) })
            #expect(a.withUnsafeBytes { Data($0) } != otherCount.withUnsafeBytes { Data($0) })
            #expect(a.bitCount == PassphraseKDF.derivedKeyByteCount * 8)
        }

        /// The record has to survive a round trip through `vault.json`, which is JSON.
        @Test func theWrappedRecordRoundTripsThroughJSON() throws {
            let libraryKey = SymmetricKey(size: .bits256)
            let wrapped = try PassphraseKDF.wrap(
                libraryKey, passphrase: "p", salt: Self.salt, kid: Self.kid, iterations: Self.fastIterations)

            let encoded = try JSONEncoder().encode(wrapped)
            let decoded = try JSONDecoder().decode(PassphraseKDF.WrappedKey.self, from: encoded)

            #expect(decoded == wrapped)
            #expect(try PassphraseKDF.unwrap(decoded, passphrase: "p", kid: Self.kid)
                .withUnsafeBytes { Data($0) } == libraryKey.withUnsafeBytes { Data($0) })
        }

        /// Two wraps of the same key under the same passphrase must differ, or the file
        /// advertises "these two vaults share a passphrase".
        @Test func twoWrapsOfTheSameKeyUnderTheSamePassphraseAreNotIdentical() throws {
            let libraryKey = SymmetricKey(size: .bits256)
            let saltA = PassphraseKDF.makeSalt()
            let saltB = PassphraseKDF.makeSalt()
            #expect(saltA != saltB)

            let a = try PassphraseKDF.wrap(
                libraryKey, passphrase: "p", salt: saltA, kid: Self.kid, iterations: Self.fastIterations)
            let b = try PassphraseKDF.wrap(
                libraryKey, passphrase: "p", salt: saltB, kid: Self.kid, iterations: Self.fastIterations)

            #expect(a.envelope != b.envelope)
        }
    }

    // MARK: 9. Recovery key

    @Suite("Recovery key")
    struct RecoveryKeyTests {

        @Test func ageneratedKeyRoundTripsThroughItsPrintedForm() throws {
            let bytes = RecoveryKey.generate()
            #expect(bytes.count == RecoveryKey.byteCount)

            let printed = try RecoveryKey.formatted(bytes)
            #expect(try RecoveryKey.decode(printed) == bytes)
        }

        /// Every 128-bit value has to survive, including the ones a bit-packing bug
        /// mangles: all zeros, all ones, and the alternating patterns that expose an
        /// off-by-one in the 5-bit accumulator.
        @Test(arguments: [
            Data(repeating: 0x00, count: 16),
            Data(repeating: 0xFF, count: 16),
            Data(repeating: 0xAA, count: 16),
            Data(repeating: 0x55, count: 16),
            Data((0..<16).map { UInt8($0) }),
            Data((0..<16).map { UInt8(255 - $0) }),
        ])
        func everyExtremeBitPatternRoundTrips(bytes: Data) throws {
            #expect(try RecoveryKey.decode(RecoveryKey.encode(bytes)) == bytes)
        }

        @Test func athousandRandomKeysRoundTrip() throws {
            var random = SeededRandom(seed: 0xDEC0_DE01)
            for _ in 0..<1_000 {
                let bytes = random.bytes(RecoveryKey.byteCount)
                #expect(try RecoveryKey.decode(RecoveryKey.encode(bytes)) == bytes)
            }
        }

        /// The shape a user sees. 27 characters, not 26: 26 symbols hold the 128 bits
        /// and leave only 2 spare, and 2 bits provably cannot catch every typo — see the
        /// note in `RecoveryKey.swift`.
        @Test func theCanonicalFormIsTwentySevenCrockfordCharactersAndTheGroupedFormIsFours() throws {
            let printed = try RecoveryKey.encode(Data(repeating: 0xA5, count: 16))
            #expect(printed.count == 27)
            #expect(printed.allSatisfy { RecoveryKey.alphabet.contains($0) })

            let grouped = try RecoveryKey.formatted(Data(repeating: 0xA5, count: 16))
            #expect(grouped.split(separator: "-").map(\.count) == [4, 4, 4, 4, 4, 4, 3])
        }

        /// The alphabet must be Crockford's, or the confusable folding below folds onto
        /// characters that are themselves in use.
        @Test func theAlphabetOmitsTheGlyphsCrockfordOmits() {
            #expect(RecoveryKey.alphabet.count == 32)
            #expect(Set(RecoveryKey.alphabet).count == 32)
            for excluded in ["I", "L", "O", "U"] as [Character] {
                #expect(!RecoveryKey.alphabet.contains(excluded))
            }
        }

        // MARK: The checksum

        /// **The** property. A user who mistypes one character must be told they
        /// mistyped it, not told their recovery key is wrong — because "your recovery
        /// key is wrong" means "your secure snippets are gone forever", and a user who
        /// believes that throws the paper away.
        ///
        /// Exhaustive over a sample: for each key, every position, every other symbol in
        /// the alphabet. 27 × 31 = 837 substitutions per key.
        @Test func everySingleCharacterSubstitutionIsCaught() throws {
            var random = SeededRandom(seed: 0xC0FF_EE42)

            for sample in 0..<12 {
                let bytes = sample == 0
                    ? Data(repeating: 0, count: RecoveryKey.byteCount)
                    : random.bytes(RecoveryKey.byteCount)
                let canonical = Array(try RecoveryKey.encode(bytes))

                for position in canonical.indices {
                    for replacement in RecoveryKey.alphabet where replacement != canonical[position] {
                        var mutated = canonical
                        mutated[position] = replacement

                        #expect(throws: (any Error).self, "seed sample \(sample), position \(position), '\(canonical[position])' -> '\(replacement)'") {
                            try RecoveryKey.decode(String(mutated))
                        }
                    }
                }
            }
        }

        /// The weighted, position-dependent sum also catches transpositions, which a
        /// plain XOR or unweighted sum would not. Not every one — neighbours differing
        /// by exactly 16 slip through — so this asserts the overwhelming majority rather
        /// than a total, which is the honest claim.
        @Test func mostAdjacentTranspositionsAreCaught() throws {
            var random = SeededRandom(seed: 0x7A50_0001)
            var attempts = 0
            var caught = 0

            for _ in 0..<50 {
                let bytes = random.bytes(RecoveryKey.byteCount)
                var canonical = Array(try RecoveryKey.encode(bytes))
                for position in 0..<(canonical.count - 1) where canonical[position] != canonical[position + 1] {
                    canonical.swapAt(position, position + 1)
                    attempts += 1
                    if (try? RecoveryKey.decode(String(canonical))) == nil { caught += 1 }
                    canonical.swapAt(position, position + 1)
                }
            }

            #expect(attempts > 500)
            #expect(Double(caught) / Double(attempts) > 0.9)
        }

        /// A dropped or doubled character changes the length, which is caught before the
        /// checksum ever runs — but it must be caught, not silently zero-padded.
        @Test func adroppedOrDoubledCharacterIsCaught() throws {
            let canonical = try RecoveryKey.encode(Data(repeating: 0x3C, count: 16))

            #expect(throws: RecoveryKey.Failure.wrongLength(26)) {
                try RecoveryKey.decode(String(canonical.dropLast()))
            }
            #expect(throws: RecoveryKey.Failure.wrongLength(28)) {
                try RecoveryKey.decode(canonical + "0")
            }
        }

        @Test func acharacterOutsideTheAlphabetIsNamedInTheError() throws {
            let canonical = try RecoveryKey.encode(Data(repeating: 0x3C, count: 16))
            let withU = "U" + canonical.dropFirst()

            #expect(throws: RecoveryKey.Failure.invalidCharacter("U")) {
                try RecoveryKey.decode(withU)
            }
        }

        // MARK: What a human actually types

        /// Read off a photo of a scrap of paper, at midnight, by someone who is already
        /// annoyed. Every one of these spellings is the same key.
        @Test func caseSeparatorsAndConfusableGlyphsAllDecodeToTheSameKey() throws {
            let bytes = RecoveryKey.generate()
            let canonical = try RecoveryKey.encode(bytes)
            let grouped = RecoveryKey.grouped(canonical)

            let spellings = [
                canonical,
                canonical.lowercased(),
                grouped,
                grouped.lowercased(),
                grouped.replacingOccurrences(of: "-", with: " "),
                grouped.replacingOccurrences(of: "-", with: "\u{2014}"),   // em dash, courtesy of Notes
                grouped.replacingOccurrences(of: "-", with: "\u{00A0}"),   // non-breaking space
                "  " + grouped + "\n",
                canonical.replacingOccurrences(of: "1", with: "I"),
                canonical.replacingOccurrences(of: "1", with: "l"),
                canonical.replacingOccurrences(of: "0", with: "O"),
                canonical.replacingOccurrences(of: "0", with: "o"),
            ]

            for spelling in spellings {
                #expect(try RecoveryKey.decode(spelling) == bytes, "spelling: \(spelling)")
            }
        }

        /// Folding has to be exhaustive, not just for the characters that happen to be
        /// in one sample key: fold every `1` and `0` in the same string at once.
        @Test func allConfusablesFoldAtOnceAcrossAWholeKey() throws {
            var random = SeededRandom(seed: 0x1101_0011)
            for _ in 0..<200 {
                let bytes = random.bytes(RecoveryKey.byteCount)
                let canonical = try RecoveryKey.encode(bytes)
                let misread = canonical
                    .replacingOccurrences(of: "1", with: "l")
                    .replacingOccurrences(of: "0", with: "O")
                #expect(try RecoveryKey.decode(misread) == bytes)
            }
        }

        /// Two different strings must never decode to the same key. The 26th symbol
        /// carries only 3 payload bits, so its low 2 bits are structurally zero;
        /// accepting non-zero ones would give every key four spellings, three of which
        /// look valid and open nothing.
        @Test func anEncodingWithNonZeroTrailingBitsIsRefusedRatherThanSilentlyTruncated() throws {
            let bytes = Data(repeating: 0x00, count: RecoveryKey.byteCount)
            var symbols = RecoveryKey.symbolsFromBytes(bytes)
            #expect(symbols.count == RecoveryKey.payloadCharacterCount)

            // Set the padding bits without disturbing the 3 payload bits above them.
            symbols[RecoveryKey.payloadCharacterCount - 1] |= 0b11
            symbols.append(RecoveryKey.checkSymbol(symbols))
            let forged = String(symbols.map { RecoveryKey.alphabet[Int($0)] })

            // The checksum is recomputed over the mutated payload, so it agrees — this
            // string is rejected by the canonical-encoding rule alone.
            #expect(throws: RecoveryKey.Failure.nonCanonical) {
                try RecoveryKey.decode(forged)
            }
        }

        @Test func encodingRefusesAnythingThatIsNotSixteenBytes() {
            #expect(throws: RecoveryKey.Failure.wrongByteCount(15)) {
                try RecoveryKey.encode(Data(repeating: 0, count: 15))
            }
            #expect(throws: RecoveryKey.Failure.wrongByteCount(0)) {
                try RecoveryKey.encode(Data())
            }
        }

        /// The recovery key is the door that is not guessable, so it has to actually be
        /// random — 128 bits from the CSPRNG, not a counter or a zero-filled buffer.
        @Test func generatedKeysAreFullWidthAndDistinct() {
            let keys = (0..<64).map { _ in RecoveryKey.generate() }
            #expect(Set(keys).count == 64)
            #expect(keys.allSatisfy { $0.count == RecoveryKey.byteCount })
            #expect(!keys.contains(Data(repeating: 0, count: RecoveryKey.byteCount)))
        }

        /// End to end: a recovery key written on paper, typed back in badly, and used to
        /// unwrap the same library key the passphrase protects.
        ///
        /// This goes through `KeyWrap`, not `PassphraseKDF`. It used to do the latter —
        /// handing `RecoveryKey.encode(…)` to `wrap(passphrase:)` with a comment
        /// conceding that the iteration count was "doing nothing here beyond format
        /// uniformity". That is exactly the hand-roll the two types exist to keep apart:
        /// stretching a value that is already 128 bits of CSPRNG output buys nothing at
        /// all, and charges the user half a second of PBKDF2 on the one door they only
        /// ever reach in an emergency.
        @Test func arecoveryKeyTypedBackInBadlyStillUnwrapsTheLibraryKey() throws {
            let libraryKey = SymmetricKey(size: .bits256)
            let recovery = RecoveryKey.generate()
            let salt = SnippetCrypto.randomBytes(SnippetCrypto.saltByteCount)

            let wrapped = try KeyWrap.wrap(
                libraryKey, under: recovery, purpose: .recovery, kid: "k-1", salt: salt)

            // Off the card in lower case, with the grouping dashes the UI printed.
            let asWrittenDown = try RecoveryKey.formatted(recovery).lowercased()
            let retyped = try RecoveryKey.decode(asWrittenDown)

            #expect(try KeyWrap.unwrap(
                wrapped, under: retyped, purpose: .recovery, kid: "k-1", salt: salt)
                .withUnsafeBytes { Data($0) } == libraryKey.withUnsafeBytes { Data($0) })
        }
    }

    // MARK: 10. base64url

    @Suite("base64url")
    struct Base64URL {

        /// The envelope is compared for equality by the merge, so it must have exactly
        /// one spelling: no `=` padding, no `+`, no `/`.
        @Test func encodingIsURLSafeAndUnpadded() {
            var random = SeededRandom(seed: 0xB64B_64B6)
            for length in 0..<40 {
                let text = SnippetCrypto.base64URL(random.bytes(length))
                #expect(!text.contains("="))
                #expect(!text.contains("+"))
                #expect(!text.contains("/"))
            }
        }

        @Test func decodingInvertsEncodingAtEveryLength() throws {
            var random = SeededRandom(seed: 0x4B64_B64B)
            for length in 1..<200 {
                let data = random.bytes(length)
                #expect(SnippetCrypto.data(fromBase64URL: SnippetCrypto.base64URL(data)) == data)
            }
        }

        @Test(arguments: ["", "a", "ab=", "a+b", "a/b", "abc=", "!!!!", "AAAAA "])
        func anythingOutsideTheCanonicalAlphabetIsRefused(text: String) {
            #expect(SnippetCrypto.data(fromBase64URL: text) == nil)
        }
    }
}
