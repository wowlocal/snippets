import CryptoKit
import Foundation
import Testing

@testable import SnippetsCore

// The wire layer's job is to be boring: identical content in, identical bytes out, on
// every machine, forever. Every test below names the failure it prevents rather than
// the code path it happens to walk.

// MARK: - Fixtures

/// A fixed epoch. Nothing in this file may depend on when the suite ran.
private let epoch = Date(timeIntervalSince1970: 1_785_312_000)

private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

/// Ids laid out so `uuidString` order is `id(0) < id(1) < …`.
private func id(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index))!
}

private let thisDevice = "aabbccdd"

private func clock(_ wallMs: UInt64, counter: UInt16 = 0, device: String = thisDevice) -> HLC {
    HLC(wallMs: wallMs, counter: counter, device: device)
}

private func snippet(
    _ index: Int,
    name: String = "Signature",
    keyword: String = "sig",
    content: String = "Best,\nMike",
    tags: [String] = ["email", "work"],
    isEnabled: Bool = true,
    isPinned: Bool = false,
    createdAt: Double = 0,
    updatedAt: Double = 0
) -> Snippet {
    Snippet(
        id: id(index), name: name, keyword: keyword, content: content, tags: tags,
        isEnabled: isEnabled, isPinned: isPinned, createdAt: at(createdAt), updatedAt: at(updatedAt))
}

// MARK: - Sealers
//
// `SnippetCrypto` owns key derivation and the Keychain. The wire layer only ever sees
// `SyncBlobSealing`, which is the point: this whole file runs with no Keychain, no
// entitlements, and no signed bundle.

/// A minimal conformer, so the wire tests exercise the seam rather than
/// `SnippetCrypto`'s internals — and so a bug in one is not hidden by the other.
private struct TestSealer: SyncBlobSealing {
    var key: SymmetricKey

    init(seed: UInt8 = 7) {
        key = SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    func seal(_ plaintext: Data, for identity: WireIdentity) throws -> Data {
        let box = try AES.GCM.seal(
            plaintext, using: key, authenticating: try identity.associatedData())
        guard let combined = box.combined else {
            throw SyncEnvelope.Failure.malformed("AES.GCM produced no combined representation")
        }
        return combined
    }

    func open(_ ciphertext: Data, for identity: WireIdentity) throws -> Data {
        try AES.GCM.open(
            AES.GCM.SealedBox(combined: ciphertext), using: key,
            authenticating: try identity.associatedData())
    }
}

/// The shipping sealer, with a keyring generated in the test rather than unwrapped
/// from the Keychain.
private func productionSealer(seed: UInt8 = 3) -> SnippetCryptoSealer {
    SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data(repeating: seed, count: 32)),
            salt: Data(repeating: 0xA5, count: 16)),
        scopeID: "test-scope")
}

// MARK: - A latency sink that records instead of waiting

private final class LatencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var durations: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// The recording is a synchronous call: `NSLock` is not async-safe, and a test
    /// helper that models the thing being tested badly is worse than no helper.
    private func record(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(duration)
    }

    var sleeper: @Sendable (Duration) async throws -> Void {
        { [self] duration in record(duration) }
    }
}

// MARK: - Deterministic shuffling
//
// The xorshift used throughout the suite, so a failure reproduces from its seed.

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func int(_ upperBound: Int) -> Int {
        upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
    }

    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var copy = items
        guard copy.count > 1 else { return copy }
        for index in stride(from: copy.count - 1, to: 0, by: -1) {
            copy.swapAt(index, int(index + 1))
        }
        return copy
    }
}

private func firstEvent(of transport: InMemoryTransport) async -> SyncTransportEvent? {
    var iterator = transport.events.makeAsyncIterator()
    return await iterator.next()
}

// MARK: - Suite

@Suite("Canonical JSON, envelopes, tombstones, and the wire")
struct WireTests {

    // MARK: 1. Canonical JSON

    @Suite("Canonical JSON")
    struct Canonical {

        /// The whole reason the type exists. Dictionary iteration order is randomly
        /// seeded per process, so an emitter that walked the dictionary would produce
        /// different bytes on every run — and these bytes are hashed, so different
        /// bytes means two devices permanently disagreeing about a record they both
        /// hold identically.
        @Test func objectBytesAreIdenticalNoMatterWhatOrderTheKeysWereInserted() throws {
            let members: [(String, CanonicalJSON.Value)] = [
                ("zeta", 1), ("alpha", "one"), ("Mid", true), ("nested", ["b": 2, "a": 3]),
                ("ärger", nil), ("m", [1, 2, 3]), ("0", 0.5),
            ]

            var random = SeededRandom(seed: 0xC0FF_EE01)
            var produced = Set<Data>()
            for _ in 0..<64 {
                var object: [String: CanonicalJSON.Value] = [:]
                for (key, value) in random.shuffled(members) { object[key] = value }
                produced.insert(try CanonicalJSON.data(.object(object)))
            }

            #expect(produced.count == 1, "insertion order leaked into the canonical bytes")
        }

        /// Byte-stability across *processes* cannot be observed from inside one process,
        /// so it is pinned as a literal: this string was produced by a different run of
        /// a different binary, and the day it stops matching, every device on the old
        /// build stops agreeing with every device on the new one.
        @Test func theByteLayoutIsPinnedToALiteralRatherThanToWhateverThisRunProduces() throws {
            let value: CanonicalJSON.Value = .object([
                "b": .int(2),
                "a": .string("x"),
                "ä": .bool(true),
                "A": .null,
            ])

            // Sorted by UTF-8 bytes: "A" (0x41), "a" (0x61), "b" (0x62), "ä" (0xC3 0xA4).
            // No whitespace. Non-ASCII emitted raw rather than as ä.
            #expect(try CanonicalJSON.string(value) == #"{"A":null,"a":"x","b":2,"ä":true}"#)
        }

        /// The sort is over UTF-8 bytes — code-point order — and not over UTF-16 code
        /// units, which is what RFC 8785 specifies and what a JavaScript implementation
        /// would reach for by default. The two orders disagree for exactly one class of
        /// key, and this is it: surrogates (D800–DFFF) sort below U+E000, so in UTF-16
        /// order a supplementary-plane key sorts *before* U+FFFD, and in ours it sorts
        /// after. A second implementation of this format that gets this wrong produces
        /// records that no existing device can verify.
        @Test func keysSortByUTF8BytesAndNotByUTF16CodeUnits() throws {
            let text = try CanonicalJSON.string(.object(["\u{FFFD}": 1, "\u{10000}": 2]))

            #expect(text == #"{"�":1,"𐀀":2}"#)
            #expect(
                Array(text.utf8).firstIndex(of: 0xEF) ?? .max
                    < (Array(text.utf8).firstIndex(of: 0xF0) ?? .max),
                "U+FFFD must come first; UTF-16 ordering would have put U+10000 first")
        }

        /// Latin-1 keys, where UTF-8 byte order happens to agree with everything else.
        /// Pinned anyway: it is the case that actually occurs, and the day it changes
        /// nobody would notice from the surrogate test alone.
        @Test func ordinaryKeysSortByTheirBytesToo() throws {
            let text = try CanonicalJSON.string(.object(["ä": 1, "b": 2, "a": 3, "Z": 4]))
            #expect(text == #"{"Z":4,"a":3,"b":2,"ä":1}"#)
        }

        @Test func stringsEscapeOnlyWhatJSONRequires() throws {
            let text = try CanonicalJSON.string(
                .string("quote\" back\\ slash/ tab\t nl\n cr\r bs\u{8} ff\u{c} nul\u{0} unit\u{1f} é 😀"))

            // A raw literal, so every backslash below is a byte the emitter produced.
            let expected =
                #""quote\" back\\ slash/ tab\t nl\n cr\r bs\b ff\f "#
                + #"nul\u0000 unit\u001f é 😀""#
            #expect(text == expected)
        }

        /// `.string` and `.utf8` are the same JSON value. If they emitted differently, a
        /// secure record's body would hash differently depending on whether it had been
        /// through the parser, and every secure snippet would resync forever.
        @Test func aStringAndItsBytesProduceIdenticalOutputAndCompareEqual() throws {
            let text = "Best,\nMike — ✍️"
            #expect(CanonicalJSON.Value.string(text) == .utf8(Data(text.utf8)))
            #expect(
                try CanonicalJSON.data(.string(text)) == CanonicalJSON.data(.utf8(Data(text.utf8))))
        }

        /// A double must survive the round trip bit-for-bit: `Date` is a `Double`, and a
        /// timestamp that shifted by one ulp per sync would make every record look
        /// changed on every pass and rewrite the library forever.
        @Test func everyDoubleRoundTripsExactlyThroughEmitAndParse() throws {
            let numbers: [Double] = [
                0, -0.0, 1, -1, 0.5, 1e-300, 1e300, .leastNormalMagnitude, .leastNonzeroMagnitude,
                .greatestFiniteMagnitude, 795_312_000.123_456_78,
                epoch.timeIntervalSinceReferenceDate,
                at(0.000_000_123).timeIntervalSinceReferenceDate,
            ]

            for number in numbers {
                let data = try CanonicalJSON.data(.double(number))
                let parsed = try CanonicalJSON.value(data)
                #expect(parsed.double?.bitPattern == number.bitPattern, "lost bits on \(number)")
            }
        }

        /// A double always carries a `.` or an `e`, so `1.0` comes back as a double and
        /// `1` comes back as an integer. Without that, `.double(1)` would parse as
        /// `.int(1)` and the value would not equal what produced it.
        @Test func integersAndWholeDoublesStayDistinguishable() throws {
            #expect(try CanonicalJSON.string(.int(1)) == "1")
            #expect(try CanonicalJSON.string(.double(1)) == "1.0")
            #expect(try CanonicalJSON.value(Data("1".utf8)) == .int(1))
            #expect(try CanonicalJSON.value(Data("1.0".utf8)) == .double(1))
        }

        @Test func nonFiniteNumbersAreRefusedRatherThanEmittedAsSomethingUnparseable() {
            #expect(throws: CanonicalJSON.Failure.nonFiniteNumber) {
                try CanonicalJSON.data(.double(.nan))
            }
            #expect(throws: CanonicalJSON.Failure.nonFiniteNumber) {
                try CanonicalJSON.data(.double(.infinity))
            }
        }

        /// A duplicate key has no canonical meaning, and "last one wins" is a silent
        /// choice between two different documents. Refusing is the only answer that
        /// cannot pick the wrong one.
        @Test func duplicateObjectKeysAreAParseErrorRatherThanALastOneWinsMerge() {
            #expect(throws: CanonicalJSON.Failure.duplicateKey("a")) {
                try CanonicalJSON.value(Data(#"{"a":1,"a":2}"#.utf8))
            }
        }

        /// Two spellings of the same character are distinct byte sequences but a single
        /// Swift `String`. Refusing is the honest answer: silently folding them would
        /// mean the parsed value cannot be re-emitted as the bytes that produced it, and
        /// the hash would not survive a round trip.
        @Test func canonicallyEquivalentKeysCountAsDuplicatesRatherThanBeingFoldedTogether() {
            #expect(throws: (any Error).self) {
                try CanonicalJSON.value(Data(#"{"é":1,"é":2}"#.utf8))  // U+00E9, then e + U+0301
            }
        }

        @Test func trailingBytesAfterTheTopLevelValueAreRejected() {
            #expect(throws: (any Error).self) {
                try CanonicalJSON.value(Data(#"{"a":1} {"b":2}"#.utf8))
            }
        }

        /// A hostile blob must not be able to overflow the stack in a recursive-descent
        /// parser. The blob is decrypted before it is parsed, so this only fires on our
        /// own bug or a key compromise — but a stack overflow is a crash, not an error.
        @Test func nestingDeeperThanTheLimitIsRefusedRatherThanOverflowingTheStack() {
            let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
            #expect(throws: CanonicalJSON.Failure.tooDeep) {
                try CanonicalJSON.value(Data(deep.utf8))
            }
        }

        @Test func malformedJSONNumbersAreRejectedRatherThanCoerced() {
            for bad in ["01", "+1", ".5", "1.", "1e", "NaN", "Infinity", "-"] {
                #expect(throws: (any Error).self, "\(bad) parsed") {
                    try CanonicalJSON.value(Data(bad.utf8))
                }
            }
        }

        @Test func surrogatePairsDecodeToOneScalarAndLoneSurrogatesAreRejected() throws {
            let parsed = try CanonicalJSON.value(Data(#""😀""#.utf8))
            #expect(parsed.text == "😀")

            #expect(throws: (any Error).self) {
                try CanonicalJSON.value(Data(#""\ud83d""#.utf8))
            }
        }

        /// Invalid UTF-8 cannot be escaped into valid JSON, and over-long encodings are
        /// the classic way to smuggle a `"` past an escaper.
        @Test func invalidUTF8IsRefusedRatherThanEmittedAsBrokenJSON() {
            #expect(throws: CanonicalJSON.Failure.invalidUTF8) {
                try CanonicalJSON.data(.utf8(Data([0xC0, 0x22])))
            }
            #expect(throws: CanonicalJSON.Failure.invalidUTF8) {
                try CanonicalJSON.data(.utf8(Data([0xED, 0xA0, 0x80])))  // lone surrogate
            }
        }

        @Test func anEmptyObjectAndAnEmptyArrayHaveTheObviousSpelling() throws {
            #expect(try CanonicalJSON.string(.object([:])) == "{}")
            #expect(try CanonicalJSON.string(.array([])) == "[]")
        }
    }

    // MARK: 2. The envelope's frozen key set

    @Suite("Envelope shape")
    struct Shape {

        private func canonicalObject(_ envelope: SyncEnvelope) throws -> [String: CanonicalJSON.Value] {
            let value = try CanonicalJSON.value(envelope.canonicalData())
            return try #require(value.object)
        }

        /// Recomputes the self-hash after a test changes one of the nine covered
        /// members. This models bytes emitted by an older implementation rather than
        /// manufacturing a value through today's normalizing initializers.
        private func canonicalDataRefreshingHash(
            _ original: [String: CanonicalJSON.Value]
        ) throws -> Data {
            var object = original
            object.removeValue(forKey: "hash")
            let digest = SHA256.hash(data: try CanonicalJSON.data(.object(object)))
            object["hash"] = .string(SyncEnvelope.hex(digest))
            return try CanonicalJSON.data(.object(object))
        }

        /// The same discipline `snippets.json` has at nine keys, for the same reason: a
        /// build that does not know a key strips it and writes the stripped version
        /// back. A key set that cannot grow cannot be stripped. Future fields go in `x`.
        @Test func theEnvelopeHasExactlyTenTopLevelKeysAndTheyAreTheseTen() throws {
            let envelope = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            let object = try canonicalObject(envelope)

            #expect(object.count == 10)
            #expect(SyncEnvelope.topLevelKeys.count == 10)
            #expect(Set(object.keys) == SyncEnvelope.topLevelKeys)
            #expect(Set(object.keys) == [
                "schemaVersion", "id", "hlc", "origin", "secure", "deleted",
                "hash", "contentHash", "fields", "x",
            ])
        }

        @Test func theFieldsObjectHasExactlyEightKeysAndTheyAreTheseEight() throws {
            let envelope = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            let fields = try #require(try canonicalObject(envelope)["fields"]?.object)

            #expect(fields.count == 8)
            #expect(SyncEnvelope.Fields.keys.count == 8)
            #expect(Set(fields.keys) == SyncEnvelope.Fields.keys)
            #expect(Set(fields.keys) == [
                "name", "keyword", "content", "tags", "isEnabled", "isPinned",
                "createdAt", "updatedAt",
            ])
        }

        /// These are wire spellings now, not merely UI cleanup choices. Pinning both
        /// the normalized values and the resulting hash makes an intentional format
        /// migration necessary before either domain normalizer can change.
        @Test func locallyProducedTagAndDeviceSpellingsArePinnedToLiterals() throws {
            let envelope = SyncEnvelope.plain(
                snippet(0, tags: ["  Team\n Notes  ", "TEAM NOTES", "Café", "CAFE", " \t "]),
                hlc: HLC(wallMs: 1_000, counter: 2, device: "AA-BB-CC-DD"),
                origin: "AB-CD-EF-01")

            #expect(envelope.fields?.tags == ["Team Notes", "Café"])
            #expect(envelope.hlc.string == "0000000003e8-0002-aabbccdd")
            #expect(envelope.origin == "abcdef01")
            #expect(try envelope.envelopeHash()
                == "dbc644e2963dccd24f99ff4919e1a61b03216d80bf0459b01977c2855560ec4c")
        }

        /// Parsing is the compatibility boundary: a future build may choose different
        /// tag cleanup rules for newly created snippets, but it must still verify and
        /// re-emit every already-hashed spelling byte-for-byte.
        @Test func parsedTagsBypassDomainNormalizationBeforeHashVerification() throws {
            let envelope = SyncEnvelope.plain(
                snippet(0), hlc: clock(1_000), origin: thisDevice)
            var object = try canonicalObject(envelope)
            var fields = try #require(object["fields"]?.object)
            let legacyTags = ["  Legacy\n Tag  ", "LEGACY TAG", ""]
            fields["tags"] = .array(legacyTags.map(CanonicalJSON.Value.string))
            object["fields"] = .object(fields)
            let legacyBytes = try canonicalDataRefreshingHash(object)

            let parsed = try SyncEnvelope.parse(legacyBytes)
            let declaredHash = try CanonicalJSON.value(legacyBytes).object?["hash"]?.text

            #expect(parsed.fields?.tags == legacyTags)
            #expect(try parsed.canonicalData() == legacyBytes)
            #expect(try parsed.envelopeHash() == declaredHash)
        }

        /// `origin` has a frozen lowercase-ASCII spelling. Refusing a different
        /// spelling is safer than silently changing a hash-covered value.
        @Test func aNoncanonicalOriginIsRejectedRatherThanNormalized() throws {
            let envelope = SyncEnvelope.plain(
                snippet(0), hlc: clock(1_000), origin: thisDevice)
            var object = try canonicalObject(envelope)
            object["origin"] = .string("AABBCCDD")
            let bytes = try canonicalDataRefreshingHash(object)

            #expect(throws: SyncEnvelope.Failure.malformed(
                "\"origin\" is not an eight-character lowercase hexadecimal device id")) {
                try SyncEnvelope.parse(bytes)
            }
        }

        /// A tombstone still emits all ten keys, with `fields` and `contentHash` null. A
        /// key set that varies by record is a key set nobody can assert on.
        @Test func aTombstoneStillHasTenKeysWithFieldsAndContentHashNull() throws {
            let envelope = SyncEnvelope.tombstone(
                id: id(0), secure: true, hlc: clock(2_000), origin: thisDevice)
            let object = try canonicalObject(envelope)

            #expect(object.count == 10)
            #expect(object["fields"]?.isNull == true)
            #expect(object["contentHash"]?.isNull == true)
            #expect(object["deleted"]?.bool == true)
        }

        /// An unknown top-level key is quarantined, never ignored. Ignoring it means
        /// re-emitting the record without it, which is the silent strip the frozen key
        /// set exists to prevent.
        @Test func anUnknownTopLevelKeyIsRefusedRatherThanSilentlyStripped() throws {
            let envelope = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            var object = try canonicalObject(envelope)
            object["surprise"] = .int(1)

            #expect(throws: (any Error).self) {
                try SyncEnvelope.parse(CanonicalJSON.data(.object(object)))
            }
        }

        /// A future build bumping the schema must land in "this build is too old" and
        /// not in "the record is corrupt" — the same rule `SyncStateFile` applies to
        /// `state.json`, because an older build that treats a newer record as garbage
        /// quarantines the entire library.
        @Test func aRecordFromANewerSchemaReportsTooNewRatherThanMalformed() throws {
            let envelope = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            var object = try canonicalObject(envelope)
            object["schemaVersion"] = .int(99)

            #expect(throws: SyncEnvelope.Failure.tooNew(version: 99)) {
                try SyncEnvelope.parse(CanonicalJSON.data(.object(object)))
            }
        }

        /// `x` is the growth path, and its whole value is that a build which does not
        /// understand a key still hands it back untouched.
        @Test func thePassthroughBagSurvivesARoundTripByteForByte() throws {
            let bag: [String: CanonicalJSON.Value] = [
                "futureFlag": true,
                "futureCount": 42,
                "futureNested": ["a": [1, 2.5, "three", nil]],
            ]
            let envelope = SyncEnvelope.plain(
                snippet(0), hlc: clock(1_000), origin: thisDevice, x: bag)

            let reopened = try SyncEnvelope.parse(envelope.canonicalData())
            #expect(reopened.x == bag)
            #expect(try reopened.canonicalData() == envelope.canonicalData())
        }

        /// The hash covers the nine-key form, so it cannot cover itself, and a record
        /// whose plaintext was edited after sealing fails to parse even if the AEAD tag
        /// somehow verified.
        @Test func anEditedPlaintextIsCaughtByTheEnvelopesOwnHash() throws {
            let envelope = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            var object = try canonicalObject(envelope)
            var fields = try #require(object["fields"]?.object)
            fields["name"] = .string("Tampered")
            object["fields"] = .object(fields)

            #expect(throws: SyncEnvelope.Failure.hashMismatch) {
                try SyncEnvelope.parse(CanonicalJSON.data(.object(object)))
            }
        }

        /// Two devices holding the same record must compute the same hash, or they will
        /// each think the other is behind and push forever.
        @Test func twoDevicesWithIdenticalContentComputeTheSameHash() throws {
            let one = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            let two = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            #expect(try one.envelopeHash() == two.envelopeHash())

            let elsewhere = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: "11112222")
            #expect(
                try elsewhere.envelopeHash() != one.envelopeHash(),
                "origin is part of the record, so it must be part of its hash")
        }

        @Test func contentHashChangesWithTheBodyAndNotWithTheName() throws {
            let base = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            let renamed = SyncEnvelope.plain(
                snippet(0, name: "Different"), hlc: clock(1_000), origin: thisDevice)
            let rewritten = SyncEnvelope.plain(
                snippet(0, content: "Different"), hlc: clock(1_000), origin: thisDevice)

            #expect(base.contentHash == renamed.contentHash)
            #expect(base.contentHash != rewritten.contentHash)
        }
    }

    // MARK: 3. Conversions

    @Suite("Snippet and vault conversions")
    struct Conversions {

        /// The core round trip. Anything lost here is lost on every sync, permanently.
        @Test func aSnippetSurvivesTheEnvelopeUnchanged() throws {
            let original = snippet(
                3, name: "Grüße 😀", keyword: "hi", content: "line1\nline2\ttab \"quoted\" / slash",
                tags: ["Deutsch", "email"], isEnabled: false, isPinned: true,
                createdAt: 12.5, updatedAt: 900.25)

            let envelope = SyncEnvelope.plain(original, hlc: clock(1_000), origin: thisDevice)
            let reopened = try SyncEnvelope.parse(envelope.canonicalData())
            let restored = try #require(reopened.plainSnippet)

            #expect(restored == original)
        }

        /// `Date` is a `Double`, and the envelope stores exactly the number `Date`
        /// stores. Milliseconds-since-1970 or ISO 8601 would both round here, and a
        /// timestamp that moves by a hair on every pass means every record looks
        /// changed on every sync — an endless rewrite loop, not a rounding nit.
        @Test func timestampsSurviveToTheLastBitRatherThanToTheNearestMillisecond() throws {
            var random = SeededRandom(seed: 0x5EED_0042)
            for _ in 0..<200 {
                let jitter = Double(random.int(1_000_000_000)) / 1_000_000_000
                let original = snippet(0, createdAt: jitter, updatedAt: 1_000 + jitter)

                let envelope = SyncEnvelope.plain(original, hlc: clock(1), origin: thisDevice)
                let restored = try #require(SyncEnvelope.parse(envelope.canonicalData()).plainSnippet)

                #expect(
                    restored.updatedAt.timeIntervalSinceReferenceDate.bitPattern
                        == original.updatedAt.timeIntervalSinceReferenceDate.bitPattern)
                #expect(
                    restored.createdAt.timeIntervalSinceReferenceDate.bitPattern
                        == original.createdAt.timeIntervalSinceReferenceDate.bitPattern)
            }
        }

        /// A secure record's body is `Data` on the way in, `Data` in the envelope,
        /// `Data` in the canonical bytes, and `Data` on the way out. It becomes a
        /// `String` only where the characters are actually typed, which is not here.
        @Test func aVaultRecordRoundTripsWithItsBodyNeverLeavingData() throws {
            let secret = Data("correct horse battery staple".utf8)
            let envelope = SyncEnvelope.secureRecord(
                id: id(5), name: "Router admin", keyword: "rtr", plaintext: secret,
                tags: ["infra"], isEnabled: true, isPinned: false,
                createdAt: at(1), updatedAt: at(2), hlc: clock(3_000), origin: thisDevice)

            let reopened = try SyncEnvelope.parse(envelope.canonicalData())
            let fields = try #require(reopened.vaultFields)

            #expect(fields.content == secret)
            #expect(fields.name == "Router admin")
            #expect(fields.keyword == "rtr")
            #expect(reopened.secure)
        }

        /// A secure record must not be convertible into a `Snippet`: `Snippet.content`
        /// is a `String` bound for `snippets.json`, and that file is readable by every
        /// old build, every export, and every share link.
        @Test func aSecureRecordRefusesToBecomeAPlainSnippet() throws {
            let envelope = SyncEnvelope.secureRecord(
                id: id(5), name: "Router admin", keyword: "rtr",
                plaintext: Data("hunter2".utf8), createdAt: at(1), updatedAt: at(2),
                hlc: clock(3_000), origin: thisDevice)

            #expect(envelope.plainSnippet == nil)
            #expect(envelope.vaultFields != nil)
        }

        /// The invariant, enforced in `init` rather than checked at call sites: a
        /// deleted secret must not linger in the blob, in the backend's tombstone, or
        /// in a debug dump somebody pastes into an issue.
        @Test func aTombstoneCarriesNoFieldsEvenWhenTheCallerSuppliesThem() throws {
            let secret = "correct horse battery staple"
            let live = SyncEnvelope.secureRecord(
                id: id(5), name: "Router admin", keyword: "rtr", plaintext: Data(secret.utf8),
                createdAt: at(1), updatedAt: at(2), hlc: clock(3_000), origin: thisDevice)

            // Both routes: the initialiser handed fields it must drop, and the
            // conversion from a live record.
            let direct = SyncEnvelope(
                id: live.id, hlc: live.hlc, origin: live.origin, secure: true,
                deleted: true, fields: live.fields)
            let converted = live.tombstoned(hlc: clock(4_000), origin: thisDevice)

            for tombstone in [direct, converted] {
                #expect(tombstone.fields == nil)
                #expect(
                    tombstone.contentHash == nil,
                    "a SHA-256 of a short secret is an offline brute-force oracle")
                #expect(tombstone.secure, "which store it left is still needed to remove it")

                let text = String(decoding: try tombstone.canonicalData(), as: UTF8.self)
                #expect(!text.contains(secret))
                #expect(!text.contains("Router admin"))
                #expect(!text.contains("rtr"))
            }
        }

        /// The `x` bag does not survive a deletion. A future build could have put
        /// anything in there, including something derived from the body, and a tombstone
        /// is the last record that should be carrying a souvenir.
        @Test func thePassthroughBagDoesNotTravelIntoATombstone() {
            let live = SyncEnvelope.plain(
                snippet(0), hlc: clock(1_000), origin: thisDevice, x: ["derived": "secret-ish"])

            #expect(live.tombstoned(hlc: clock(2_000), origin: thisDevice).x.isEmpty)
        }

        /// The vault scope is structural rather than content-derived. It is the one bag
        /// entry a secure tombstone must retain so a different vault cannot apply the
        /// deletion to a record its key never owned.
        @Test func aSecureTombstoneRetainsOnlyItsVaultScope() {
            let live = SyncEnvelope.secureRecord(
                id: id(5), name: "Router admin", keyword: "rtr",
                plaintext: Data("sealed bytes".utf8), createdAt: at(1), updatedAt: at(2),
                hlc: clock(3_000), origin: thisDevice,
                x: [
                    SyncEnvelope.vaultKeyIDExtensionKey: .string("k-origin"),
                    "derived": .string("must disappear"),
                ])

            let tombstone = live.tombstoned(hlc: clock(4_000), origin: thisDevice)
            #expect(tombstone.x == [
                SyncEnvelope.vaultKeyIDExtensionKey: .string("k-origin")
            ])
        }

        @Test func aTombstoneThatArrivesCarryingFieldsIsRefusedRatherThanTrusted() throws {
            let live = SyncEnvelope.plain(snippet(0), hlc: clock(1_000), origin: thisDevice)
            var object = try #require(CanonicalJSON.value(live.canonicalData()).object)
            object["deleted"] = .bool(true)

            #expect(throws: (any Error).self) {
                try SyncEnvelope.parse(CanonicalJSON.data(.object(object)))
            }
        }
    }

    // MARK: 4. Sealing

    @Suite("Sealing a wire record")
    struct Sealing {

        @Test func sealingAndOpeningIsLossless() throws {
            let sealer = TestSealer()
            let envelope = SyncEnvelope.plain(
                snippet(1, content: "Best,\nMike"), hlc: clock(1_234, counter: 7), origin: thisDevice)

            let record = try WireCodec.seal(envelope, using: sealer)
            #expect(try WireCodec.open(record, using: sealer) == envelope)
        }

        /// The four fields are the entire outside of the record. Anything else visible
        /// on the wire is a leak, and the test that proves it is the crude one: look for
        /// the plaintext in the bytes that leave.
        @Test func nothingButIdRevAndTheDeletionFlagIsReadableFromOutsideTheBlob() throws {
            let sealer = TestSealer()
            let envelope = SyncEnvelope.secureRecord(
                id: id(9), name: "Router admin", keyword: "rtr",
                plaintext: Data("hunter2".utf8), tags: ["infra"],
                createdAt: at(1), updatedAt: at(2), hlc: clock(3_000), origin: thisDevice)

            let record = try WireCodec.seal(envelope, using: sealer)
            let onTheWire = record.blob + Data(record.rev.utf8) + Data(record.id.uuidString.utf8)
            let text = String(decoding: onTheWire, as: UTF8.self)

            for secret in ["hunter2", "Router admin", "rtr", "infra", thisDevice] {
                #expect(!text.contains(secret), "\"\(secret)\" is legible on the wire")
            }
            #expect(record.deleted == false, "the deletion flag is the one thing left in the clear")
        }

        /// A backend that moves a blob onto a different id must fail, not silently
        /// overwrite the wrong snippet. The AEAD tag covers `{id, rev, deleted}` for
        /// exactly this.
        @Test func aBlobMovedOntoAnotherRecordIdWillNotOpen() throws {
            let sealer = TestSealer()
            let envelope = SyncEnvelope.plain(snippet(1), hlc: clock(1_000), origin: thisDevice)
            var record = try WireCodec.seal(envelope, using: sealer)
            record.id = id(2)

            #expect(throws: (any Error).self) { try WireCodec.open(record, using: sealer) }
        }

        /// Flipping the clear-text deletion flag must not turn a live record into a
        /// tombstone. This is the concession `deleted` costs, and it is bounded here.
        @Test func flippingTheClearTextDeletionFlagWillNotOpen() throws {
            let sealer = TestSealer()
            let envelope = SyncEnvelope.plain(snippet(1), hlc: clock(1_000), origin: thisDevice)
            var record = try WireCodec.seal(envelope, using: sealer)
            record.deleted = true

            #expect(throws: (any Error).self) { try WireCodec.open(record, using: sealer) }
        }

        @Test func aBlobResealedUnderAnotherKeyWillNotOpen() throws {
            let envelope = SyncEnvelope.plain(snippet(1), hlc: clock(1_000), origin: thisDevice)
            let record = try WireCodec.seal(envelope, using: TestSealer(seed: 1))

            #expect(throws: (any Error).self) {
                try WireCodec.open(record, using: TestSealer(seed: 2))
            }
        }

        /// A deterministic rev is what makes re-pushing unchanged content a no-op
        /// instead of an infinite loop. A random one would make every sync look like a
        /// change to every other device.
        @Test func revIsDeterministicInTheContentAndMovesWhenTheContentDoes() throws {
            let sealer = TestSealer()
            let envelope = SyncEnvelope.plain(snippet(1), hlc: clock(1_000), origin: thisDevice)
            let edited = SyncEnvelope.plain(
                snippet(1, content: "changed"), hlc: clock(1_000), origin: thisDevice)

            let first = try WireCodec.seal(envelope, using: sealer)
            let second = try WireCodec.seal(envelope, using: sealer)
            let third = try WireCodec.seal(edited, using: sealer)

            #expect(first.rev == second.rev)
            #expect(first.rev != third.rev)
            // The ciphertext still differs — the nonce is fresh every time, so identical
            // content does not produce identical bytes on the wire.
            #expect(first.blob != second.blob)
        }

        /// The same contract through the sealer that actually ships, so the seam is
        /// proven against `SnippetCrypto` and not only against a test double.
        @Test func theShippingSealerHonoursTheSameContract() throws {
            let sealer = productionSealer()
            let envelope = SyncEnvelope.secureRecord(
                id: id(6), name: "Router admin", keyword: "rtr",
                plaintext: Data("hunter2".utf8), createdAt: at(1), updatedAt: at(2),
                hlc: clock(3_000), origin: thisDevice)

            let record = try WireCodec.seal(envelope, using: sealer)
            #expect(try WireCodec.open(record, using: sealer) == envelope)

            var moved = record
            moved.id = id(7)
            #expect(throws: (any Error).self) { try WireCodec.open(moved, using: sealer) }

            var flipped = record
            flipped.deleted = true
            #expect(throws: (any Error).self) { try WireCodec.open(flipped, using: sealer) }

            #expect(throws: (any Error).self) {
                try WireCodec.open(record, using: productionSealer(seed: 9))
            }
        }

        /// `SnippetCrypto` pads to 256-byte boundaries, so the wire does not publish
        /// the precise length of every secret. Worth asserting from this side too: the
        /// envelope wraps the body in JSON, and a wire layer that leaked length would
        /// undo the padding without anyone noticing.
        @Test func theWireDoesNotPublishThePreciseLengthOfASecret() throws {
            let sealer = productionSealer()

            let sizes = try [1, 2, 3, 40].map { count -> Int in
                let envelope = SyncEnvelope.secureRecord(
                    id: id(6), name: "n", keyword: "k",
                    plaintext: Data(repeating: UInt8(ascii: "x"), count: count),
                    createdAt: at(1), updatedAt: at(2), hlc: clock(3_000), origin: thisDevice)
                return try WireCodec.seal(envelope, using: sealer).blob.count
            }

            #expect(Set(sizes).count == 1, "blob size tracked the secret's length: \(sizes)")
        }

        @Test func aTombstoneSealsAndOpensWithNoFields() throws {
            let sealer = TestSealer()
            let envelope = SyncEnvelope.tombstone(
                id: id(4), secure: true, hlc: clock(5_000), origin: thisDevice)

            let record = try WireCodec.seal(envelope, using: sealer)
            #expect(record.deleted)

            let reopened = try WireCodec.open(record, using: sealer)
            #expect(reopened.fields == nil)
            #expect(reopened.secure, "which store the record left is still needed to remove it")
        }
    }

    // MARK: 5. The deletion circuit breaker

    @Suite("Deletion guard")
    struct Guard {

        /// The floor of five is what makes the guard usable: a pure percentage would
        /// refuse to delete one snippet out of four.
        @Test func theFloorGovernsSmallLibrariesAndThePercentageGovernsLargeOnes() {
            #expect(DeletionGuard.allowedDeletions(liveCount: 0) == 5)
            #expect(DeletionGuard.allowedDeletions(liveCount: 1) == 5)
            #expect(DeletionGuard.allowedDeletions(liveCount: 24) == 5)
            // 25 is where ceil(0.2 * n) finally reaches the floor.
            #expect(DeletionGuard.allowedDeletions(liveCount: 25) == 5)
            #expect(DeletionGuard.allowedDeletions(liveCount: 26) == 6)
            #expect(DeletionGuard.allowedDeletions(liveCount: 50) == 10)
            #expect(DeletionGuard.allowedDeletions(liveCount: 100) == 20)
            #expect(DeletionGuard.allowedDeletions(liveCount: 101) == 21)
        }

        /// The boundary is the only part of a safety limit anybody ever reads, so it is
        /// stated three times: at the floor, at the percentage, and one over each.
        @Test func exactlyFiveIsAllowedAndSixIsNotWhenTheFloorGoverns() {
            #expect(DeletionGuard.evaluate(liveCount: 3, deletions: 5).isAllowed)
            #expect(!DeletionGuard.evaluate(liveCount: 3, deletions: 6).isAllowed)
            #expect(DeletionGuard.evaluate(liveCount: 25, deletions: 5).isAllowed)
            #expect(!DeletionGuard.evaluate(liveCount: 25, deletions: 6).isAllowed)
        }

        @Test func exactlyTwentyPercentIsAllowedAndOneMoreIsNot() {
            #expect(DeletionGuard.evaluate(liveCount: 100, deletions: 20).isAllowed)
            #expect(!DeletionGuard.evaluate(liveCount: 100, deletions: 21).isAllowed)
            #expect(DeletionGuard.evaluate(liveCount: 500, deletions: 100).isAllowed)
            #expect(!DeletionGuard.evaluate(liveCount: 500, deletions: 101).isAllowed)
        }

        @Test func deletingNothingIsAlwaysAllowedIncludingAgainstAnEmptyLibrary() {
            #expect(DeletionGuard.evaluate(liveCount: 0, deletions: 0).isAllowed)
            #expect(DeletionGuard.evaluate(liveCount: 10_000, deletions: 0).isAllowed)
        }

        /// The scenario the guard exists for: a bucket restored from an old snapshot,
        /// where every missing record reads as a deletion.
        @Test func aBackendThatLostMostOfTheLibraryIsRefusedWithTheNumbersItWasRefusedOn() throws {
            let decision = DeletionGuard.evaluate(liveCount: 48, deletions: 40)
            let refusal = try #require(decision.refusal)

            #expect(refusal.liveCount == 48)
            #expect(refusal.requestedDeletions == 40)
            #expect(refusal.allowedDeletions == 10)
            #expect(refusal.requestedFraction > 0.8)
            #expect(refusal.description.contains("40 of 48"))
            #expect(refusal.description.contains("paused before completing"))
            #expect(refusal.description.contains("at least 8"))
        }

        /// An at-least-once transport delivers duplicates, and a duplicate-inflated
        /// count would trip the breaker on a batch that deletes nothing new.
        @Test func duplicatedAndUnknownDeletionsDoNotInflateTheCount() {
            let live = Set((0..<10).map(id))
            let deleting = [id(0), id(0), id(0), id(1), id(99), id(98)]

            // Two of those are real: id(0) three times over, and id(1). The rest are for
            // records we do not hold and cannot lose.
            #expect(DeletionGuard.evaluate(live: live, deleting: deleting).isAllowed)

            let wipe = (0..<10).map(id) + (0..<10).map(id)
            #expect(!DeletionGuard.evaluate(live: live, deleting: wipe).isAllowed)
        }

        @Test func aBatchOfEnvelopesIsCountedByItsTombstonesAlone() {
            let live = Set((0..<10).map(id))
            let incoming = (0..<8).map {
                SyncEnvelope.tombstone(id: id($0), secure: false, hlc: clock(1), origin: thisDevice)
            } + (8..<10).map {
                SyncEnvelope.plain(snippet($0), hlc: clock(1), origin: thisDevice)
            }

            let decision = DeletionGuard.evaluate(live: live, incoming: incoming)
            #expect(decision.refusal?.requestedDeletions == 8)
            #expect(decision.refusal?.allowedDeletions == 5)
        }
    }

    // MARK: 6. Tombstones

    @Suite("Tombstone ledger")
    struct Tombstones {

        @Test func recordingIsIdempotentAndKeepsTheLaterClock() {
            var ledger = TombstoneLedger()
            ledger.record(id(0), hlc: clock(1_000), deletedAt: at(0))
            ledger.record(id(0), hlc: clock(500), deletedAt: at(100))
            #expect(ledger[id(0)]?.hlc == clock(1_000))
            #expect(ledger.count == 1)

            ledger.record(id(0), hlc: clock(2_000), deletedAt: at(200))
            #expect(ledger[id(0)]?.hlc == clock(2_000))
            #expect(ledger[id(0)]?.deletedAt == at(200))
            #expect(ledger.count == 1)
        }

        /// The horizon is a contract, not a cleanup interval: every device promises to
        /// reconcile within it, and in exchange every other device remembers its
        /// deletions for that long.
        @Test func tombstonesOlderThanTheHorizonAreCollectedAndNewerOnesAreNot() {
            let now = at(0)
            let horizon = TombstoneLedger.defaultHorizon
            var ledger = TombstoneLedger()

            ledger.record(id(0), hlc: clock(1), deletedAt: now.addingTimeInterval(-horizon - 1))
            ledger.record(id(1), hlc: clock(2), deletedAt: now.addingTimeInterval(-horizon))
            ledger.record(id(2), hlc: clock(3), deletedAt: now.addingTimeInterval(-horizon + 1))
            ledger.record(id(3), hlc: clock(4), deletedAt: now)

            let collected = ledger.collect(now: now)

            // Strictly older than the cutoff. Exactly at the horizon survives, so a
            // device that reconciles precisely on schedule is never caught out by a
            // rounding difference between two machines' clocks.
            #expect(collected == [id(0)])
            #expect(ledger.count == 3)
            #expect(ledger.contains(id(1)))
            #expect(!ledger.contains(id(0)))
        }

        @Test func collectingNothingLeavesTheFloorWhereItWas() {
            var ledger = TombstoneLedger()
            ledger.record(id(0), hlc: clock(1), deletedAt: at(0))

            #expect(ledger.collect(now: at(1)).isEmpty)
            #expect(ledger.collectedThrough == nil, "the floor moves on a collection, not on time")
            #expect(ledger.recognize(id: id(1), hlc: clock(1)) == .unseen)
        }

        /// The failure this whole type exists to prevent. A Mac closed for a year offers
        /// a record whose tombstone we collected months ago; "no tombstone, therefore
        /// new, therefore write it back" is a silent, self-propagating resurrection.
        @Test func aRecordOlderThanTheCollectionFloorIsIndeterminateRatherThanNew() {
            let now = at(0)
            let horizon = TombstoneLedger.defaultHorizon
            var ledger = TombstoneLedger()

            let ancient = now.addingTimeInterval(-horizon - 1)
            ledger.record(id(0), hlc: clock(ancient.millisecondsSince1970), deletedAt: ancient)
            ledger.collect(now: now)

            #expect(ledger.collectedThrough == ancient)

            // The very record whose tombstone we dropped.
            #expect(
                ledger.recognize(id: id(0), hlc: clock(ancient.millisecondsSince1970))
                    == .indeterminate(collectedThrough: ancient))
            // Any other record from before the floor is equally unknowable.
            #expect(
                ledger.recognize(id: id(7), hlc: clock(1_000))
                    == .indeterminate(collectedThrough: ancient))
            // Something written after the floor is genuinely new, and saying so is what
            // stops every fetch turning into a full reconcile.
            #expect(ledger.recognize(id: id(8), hlc: clock(now.millisecondsSince1970)) == .unseen)
        }

        @Test func aLiveTombstoneIsRecognisedWithItsClockSoAnEditCanStillBeatIt() {
            var ledger = TombstoneLedger()
            ledger.record(id(0), hlc: clock(5_000), deletedAt: at(0))

            guard case .deleted(let tombstone) = ledger.recognize(id: id(0), hlc: clock(9_000)) else {
                Issue.record("a tombstone we hold must be recognised")
                return
            }
            #expect(tombstone.hlc == clock(5_000))
        }

        /// The only sanctioned resurrection: a local, explicit act by the user.
        @Test func forgettingIsTheOnlyWayARecordComesBack() {
            var ledger = TombstoneLedger()
            ledger.record(id(0), hlc: clock(1), deletedAt: at(0))
            ledger.forget(id(0))

            #expect(!ledger.contains(id(0)))
            #expect(ledger.recognize(id: id(0), hlc: clock(1)) == .unseen)
        }

        @Test func theLedgerRoundTripsThroughItsFileWithReadableStringKeys() throws {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("snippets-wire-tombs-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            var ledger = TombstoneLedger()
            ledger.record(id(0), hlc: clock(1_000), deletedAt: at(5))
            ledger.record(id(1), hlc: clock(2_000), deletedAt: at(6))

            let url = scratch.appendingPathComponent("tombstones.json")
            try TombstoneFile.write(ledger, to: url, temporaryDirectory: scratch.appendingPathComponent("Tmp"))

            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains(id(0).uuidString.lowercased()), "keys must be readable, not an array")

            guard case .loaded(let reloaded) = TombstoneFile.load(from: url) else {
                Issue.record("the ledger did not reload")
                return
            }
            #expect(reloaded == ledger)
        }

        /// A missing ledger is empty; an unreadable one is a reason to halt. Conflating
        /// them means a transient read error silently forgets every deletion the device
        /// knew about, and every one of them comes back.
        @Test func aMissingLedgerIsEmptyButAnUnreadableOneIsNot() throws {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("snippets-wire-tombs-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            let missing = scratch.appendingPathComponent("nothing.json")
            guard case .empty = TombstoneFile.load(from: missing) else {
                Issue.record("a missing ledger must load as empty")
                return
            }

            let damaged = scratch.appendingPathComponent("damaged.json")
            try Data("{not json".utf8).write(to: damaged)
            guard case .unreadable = TombstoneFile.load(from: damaged) else {
                Issue.record("a damaged ledger must not be mistaken for an empty one")
                return
            }

            let future = scratch.appendingPathComponent("future.json")
            try Data(#"{"schemaVersion":99,"entries":{}}"#.utf8).write(to: future)
            guard case .tooNew(let version) = TombstoneFile.load(from: future) else {
                Issue.record("a newer ledger must not be written back with fewer deletions in it")
                return
            }
            #expect(version == 99)
        }
    }

    // MARK: 7. The fake backend

    @Suite("In-memory transport")
    struct Fake {

        private func records(_ indices: [Int]) throws -> [WireRecord] {
            let sealer = TestSealer()
            return try indices.map {
                try WireCodec.seal(
                    SyncEnvelope.plain(snippet($0), hlc: clock(UInt64($0) + 1), origin: thisDevice),
                    using: sealer)
            }
        }

        @Test func aQuietBackendDeliversEverythingOnceAndThenNothing() async throws {
            let transport = InMemoryTransport()
            transport.seed(try records([0, 1, 2]))

            let first = try await transport.fetchChanges(since: nil)
            #expect(first.records.map(\.id) == [id(0), id(1), id(2)])
            #expect(first.hasMore == false)
            #expect(first.isFullResync == false)

            let second = try await transport.fetchChanges(since: first.cursor)
            #expect(second.records.isEmpty)
            #expect(second.cursor == first.cursor)
        }

        @Test func pagingStopsAtThePageSizeAndSaysThereIsMore() async throws {
            let transport = InMemoryTransport(pageSize: 2)
            transport.seed(try records([0, 1, 2, 3, 4]))

            var cursor: SyncCursor?
            var seen: [UUID] = []
            var pages = 0
            repeat {
                let page = try await transport.fetchChanges(since: cursor)
                seen.append(contentsOf: page.records.map(\.id))
                cursor = page.cursor
                pages += 1
                if !page.hasMore { break }
            } while pages < 10

            #expect(seen == (0..<5).map(id))
            #expect(pages == 3)
        }

        // MARK: Fault: rejection

        @Test func aBlanketRejectionRefusesEveryRecordAndStoresNone() async throws {
            let transport = InMemoryTransport()
            transport.configure { $0.rejectEverything = .permanent(detail: "record too large") }

            let submission = try await transport.submit(try records([0, 1]), at: nil)

            #expect(submission.acceptedIDs.isEmpty)
            #expect(submission.rejections.count == 2)
            #expect(submission.rejections.allSatisfy { !$0.rejection.isRetryable })
            #expect(transport.snapshot.isEmpty)
        }

        @Test func aPerRecordRejectionLetsTheRestOfTheBatchThrough() async throws {
            let transport = InMemoryTransport()
            transport.configure { $0.rejectRecords[id(1)] = .conflict(remote: nil) }

            let submission = try await transport.submit(try records([0, 1, 2]), at: nil)

            #expect(submission.acceptedIDs == [id(0), id(2)])
            #expect(submission.rejections.map(\.id) == [id(1)])
            #expect(submission.isPartial)
            #expect(transport.snapshot.map(\.id) == [id(0), id(2)])
        }

        // MARK: Fault: network failure

        @Test func anUnreachableBackendFailsFetchAndSubmitUntilItIsCleared() async throws {
            let transport = InMemoryTransport()
            transport.configure { $0.unreachable = true }

            await #expect(throws: (any Error).self) { try await transport.fetchChanges(since: nil) }
            await #expect(throws: (any Error).self) { try await transport.submit(try records([0]), at: nil) }

            transport.configure { $0.unreachable = false }
            _ = try await transport.submit(try records([0]), at: nil)
            #expect(transport.snapshot.count == 1)
        }

        @Test func countedFlakinessFailsExactlyTheNumberOfCallsItWasToldTo() async throws {
            let transport = InMemoryTransport()
            transport.configure { $0.failFetches = 2 }

            await #expect(throws: (any Error).self) { try await transport.fetchChanges(since: nil) }
            await #expect(throws: (any Error).self) { try await transport.fetchChanges(since: nil) }
            _ = try await transport.fetchChanges(since: nil)

            #expect(transport.fetchAttempts == 3)
            #expect(transport.faults.failFetches == 0)
        }

        // MARK: Fault: latency

        @Test func configuredLatencyIsAppliedToEveryCallThroughTheInjectedSleeper() async throws {
            let recorder = LatencyRecorder()
            let transport = InMemoryTransport(sleeper: recorder.sleeper)
            transport.configure { $0.latency = .milliseconds(250) }

            _ = try await transport.fetchChanges(since: nil)
            _ = try await transport.submit(try records([0]), at: nil)

            // Recorded, not slept: the suite stays fast and the assertion stays exact.
            #expect(recorder.durations == [.milliseconds(250), .milliseconds(250)])
        }

        @Test func zeroLatencyDoesNotTouchTheSleeperAtAll() async throws {
            let recorder = LatencyRecorder()
            let transport = InMemoryTransport(sleeper: recorder.sleeper)

            _ = try await transport.fetchChanges(since: nil)
            #expect(recorder.durations.isEmpty)
        }

        // MARK: Fault: partial batch acceptance

        /// The single most valuable fault here. An engine that assumes a submission is
        /// all-or-nothing drops the unaccepted tail silently, and no real backend will
        /// reproduce that on request.
        @Test func aPartiallyAcceptedBatchStoresThePrefixAndRejectsTheTail() async throws {
            let transport = InMemoryTransport()
            transport.configure {
                $0.acceptAtMostPerBatch = 2
                $0.partialBatchRejection = .rateLimited(retryAfter: 30)
            }

            let submission = try await transport.submit(try records([0, 1, 2, 3]), at: nil)

            #expect(submission.acceptedIDs == [id(0), id(1)])
            #expect(submission.rejections.map(\.id) == [id(2), id(3)])
            #expect(submission.rejections.allSatisfy { $0.rejection == .rateLimited(retryAfter: 30) })
            #expect(submission.isPartial)
            #expect(transport.snapshot.map(\.id) == [id(0), id(1)])
        }

        // MARK: Fault: cursor invalidation

        @Test func aninvalidatedCursorForcesAFullResyncAndAnnouncesItself() async throws {
            let transport = InMemoryTransport()
            transport.seed(try records([0, 1, 2]))
            let first = try await transport.fetchChanges(since: nil)
            #expect(first.records.count == 3)

            transport.configure { $0.invalidateCursorOnNextFetch = true }
            let resync = try await transport.fetchChanges(since: first.cursor)

            #expect(resync.isFullResync)
            #expect(resync.records.count == 3, "a resync is a snapshot, not a delta")

            let event = await firstEvent(of: transport)
            #expect(event == .cursorInvalidated(reason: "injected cursor invalidation"))

            // And it fires exactly once.
            let after = try await transport.fetchChanges(since: resync.cursor)
            #expect(!after.isFullResync)
            #expect(after.records.isEmpty)
        }

        /// A cursor minted before the backend was rewound points past the end of the
        /// store. Serving it as-is returns an empty page forever while the whole library
        /// sits there unfetched.
        @Test func aCursorFromTheFutureIsTreatedAsAResyncRatherThanAsSilence() async throws {
            let transport = InMemoryTransport()
            transport.seed(try records([0, 1]))

            let fetch = try await transport.fetchChanges(since: SyncCursor("9999"))

            #expect(fetch.isFullResync)
            #expect(fetch.records.count == 2)
        }

        @Test func aDroppedCursorDoesNotLookLikeStartOver() async throws {
            let transport = InMemoryTransport()
            transport.seed(try records([0, 1]))
            transport.configure { $0.dropCursorOnNextFetch = true }

            let fetch = try await transport.fetchChanges(since: nil)

            #expect(fetch.cursor == nil)
            #expect(fetch.isFullResync == false, "losing the cursor is not the same as a resync")
        }

        // MARK: Fault: duplicate delivery

        /// Every real backend is at-least-once. The engine is required to be idempotent;
        /// the transport is not required to be exactly-once.
        @Test func duplicateDeliveryRepeatsThePageAsABlockJustLikeARetriedRequest() async throws {
            let transport = InMemoryTransport()
            transport.seed(try records([0, 1]))
            transport.configure { $0.deliverPagesTimes = 3 }

            let fetch = try await transport.fetchChanges(since: nil)

            #expect(fetch.records.map(\.id) == [id(0), id(1), id(0), id(1), id(0), id(1)])
            #expect(Set(fetch.records.map(\.id)).count == 2)
        }

        // MARK: Fault: a backend that assigns its own revisions

        @Test func aBackendThatRewritesRevsIsReportedRatherThanAssumedAway() async throws {
            let transport = InMemoryTransport()
            transport.configure { $0.rewriteAcceptedRevs = true }
            let submitted = try records([0])

            let submission = try await transport.submit(submitted, at: nil)

            guard case .accepted(let rev, let recordVersion) = submission.results[0].outcome else {
                Issue.record("the record should have been accepted")
                return
            }
            #expect(rev != submitted[0].rev)
            #expect(transport.snapshot[0].rev == rev)
            #expect(transport.snapshot[0].recordVersion == recordVersion)
        }

        // MARK: Conflicts and push support

        /// Two devices pushing the same record from stale views is a conflict, not a
        /// lost update.
        @Test func pushingOverARecordWrittenAfterOurCursorIsAConflict() async throws {
            let transport = InMemoryTransport()
            let sealer = TestSealer()

            let mine = try WireCodec.seal(
                SyncEnvelope.plain(snippet(0, content: "mine"), hlc: clock(1), origin: thisDevice),
                using: sealer)
            let theirs = try WireCodec.seal(
                SyncEnvelope.plain(snippet(0, content: "theirs"), hlc: clock(2), origin: "11112222"),
                using: sealer)

            // Our view of the world predates their write.
            let staleCursor = transport.currentCursor
            transport.seed([theirs])

            let submission = try await transport.submit([mine], at: staleCursor)

            #expect(submission.acceptedIDs.isEmpty)
            guard case .conflict(let authoritative?) =
                    submission.rejections.first?.rejection else {
                Issue.record("the stale write must disclose the authoritative record")
                return
            }
            #expect(authoritative.id == theirs.id)
            #expect(authoritative.rev == theirs.rev)
            #expect(authoritative.deleted == theirs.deleted)
            #expect(authoritative.blob == theirs.blob)
            #expect(authoritative.recordVersion != nil)

            // Re-reading first, then resubmitting, succeeds.
            let fresh = try await transport.fetchChanges(since: staleCursor)
            var retriedMine = mine
            retriedMine.recordVersion = fresh.records.first(where: { $0.id == mine.id })?.recordVersion
            let retried = try await transport.submit([retriedMine], at: fresh.cursor)
            #expect(retried.acceptedIDs == [id(0)])
        }

        @Test func aPollOnlyBackendRefusesAPushRatherThanPretendingToAcceptIt() async throws {
            let transport = InMemoryTransport(supportsPush: false)

            #expect(!transport.supportsPush)
            await #expect(throws: SyncTransportFailure.pushUnsupported) {
                try await transport.submit(try records([0]), at: nil)
            }
        }

        @Test func everySubmissionIsLoggedIncludingTheRejectedOnes() async throws {
            let transport = InMemoryTransport()
            transport.configure { $0.rejectEverything = .permanent(detail: "nope") }

            _ = try await transport.submit(try records([0]), at: nil)
            _ = try await transport.submit(try records([1, 2]), at: nil)

            #expect(transport.submittedBatches.map(\.count) == [1, 2])
        }

        @Test func aPushHintReachesTheEventStream() async throws {
            let transport = InMemoryTransport()
            transport.notify(.changesAvailable)

            #expect(await firstEvent(of: transport) == .changesAvailable)
        }
    }
}
