import Foundation
import Testing

@testable import SnippetsCore

// `Vault/vault.json` is the only file in this project that can hold something the
// user cannot reconstruct. Every test below names the loss it prevents rather than
// the code path it happens to walk.
//
// Nothing here needs a key: `VaultDocument` treats `sealed`, the wrap blobs and
// `contentHash` as opaque strings, which is exactly what lets `swift test` — unsigned,
// with no keychain — cover the format completely.

// MARK: - Fixtures

/// A fixed epoch, chosen on a millisecond boundary that is also exactly representable
/// as a binary `Double`. Timestamps are stored to millisecond resolution, so a fixture
/// with, say, `.123` seconds would fail an exact round-trip comparison for reasons
/// that have nothing to do with the format. Millisecond *fidelity* gets its own test
/// below, with the tolerance stated out loud.
private let epoch = Date(timeIntervalSince1970: 1_785_312_000)

private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

private func id(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index))!
}

private let thisDevice = "aabbccdd"

private func clock(_ wallMs: UInt64, _ counter: UInt16 = 0) -> HLC {
    HLC(wallMs: wallMs, counter: counter, device: thisDevice)
}

private func record(
    _ index: Int,
    name: String = "AWS root password",
    keyword: String = "awsroot",
    tags: [String] = ["work", "prod"],
    isEnabled: Bool = true,
    isPinned: Bool = false,
    createdAt: Double = 0,
    updatedAt: Double = 0.5,
    contentHash: String = "9d2b7c41f0a3",
    sealed: String = "v1.k-7f3a91c0.bm9uY2U.Y2lwaGVy",
    x: [String: JSONValue] = [:]
) -> VaultRecord {
    VaultRecord(
        id: id(index), name: name, keyword: keyword, tags: tags,
        isEnabled: isEnabled, isPinned: isPinned,
        createdAt: at(createdAt), updatedAt: at(updatedAt),
        hlc: clock(1_785_312_000_500, UInt16(index)),
        contentHash: contentHash, sealed: sealed, x: x)
}

private func document(
    schemaVersion: Int = VaultDocument.currentSchemaVersion,
    wrapCLI: String? = nil,
    x: [String: JSONValue] = [:],
    kdfX: [String: JSONValue] = [:],
    records: [VaultRecord] = [record(0), record(1, name: "Recovery codes", keyword: "codes")]
) -> VaultDocument {
    VaultDocument(
        schemaVersion: schemaVersion,
        kid: "k-7f3a91c0",
        // base64url, unpadded — the spelling `SnippetCrypto` emits and the only one it
        // will decode. These used to carry standard-base64 `==` tails, which the crypto
        // layer's decoder rejects outright.
        vaultSalt: "3Qk5Yy1xQfC0Zr8mHn2pQw",
        kdf: VaultKDFParameters(
            alg: PassphraseKDF.algorithm,
            iterations: PassphraseKDF.iterations,
            saltP: "Yh8pQm4kL1sTz0Wc7Vb9Ng",
            x: kdfX),
        wrapPass: "v1.k-7f3a91c0.pass.bm9uY2U.d3JhcA",
        wrapRecovery: "v1.k-7f3a91c0.recovery.bm9uY2U.d3JhcA",
        wrapCLI: wrapCLI,
        x: x,
        records: records)
}

// MARK: - Scratch directory
//
// Tests run in parallel and the real `~/Library/Application Support/SnippetsClone`
// belongs to the user's running app, so every filesystem test gets its own tree and
// takes it away again. Nothing below ever names a default path.

private struct VaultScratch {
    let root: URL

    init(_ label: String) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippets-vault-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
    }

    var vaultFolder: URL { root.appendingPathComponent("Vault", isDirectory: true) }
    var vault: URL { vaultFolder.appendingPathComponent("vault.json", isDirectory: false) }
    var quarantineFolder: URL { vaultFolder.appendingPathComponent("Quarantine", isDirectory: true) }
    var tmpFolder: URL { root.appendingPathComponent("Tmp", isDirectory: true) }

    func put(_ bytes: Data) throws { try bytes.write(to: vault) }
    func put(_ json: String) throws { try put(Data(json.utf8)) }
    func bytes() -> Data? { try? Data(contentsOf: vault) }

    func destroy() { try? FileManager.default.removeItem(at: root) }
}

/// The inode is load-bearing: an atomic write always renames a *new* one into place,
/// so an unchanged inode is proof the file was never republished.
private struct FileIdentity: Equatable {
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
}

private func identity(of url: URL) -> FileIdentity? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return FileIdentity(
        inode: UInt64(info.st_ino), size: Int64(info.st_size),
        modifiedSeconds: info.st_mtimespec.tv_sec,
        modifiedNanoseconds: info.st_mtimespec.tv_nsec)
}

private func entries(of url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

// MARK: - Deterministic randomness
//
// The xorshift used by `SyncMergeTests` and `ClockAndStateTests`, so a property
// failure reproduces exactly from the seed printed in the message.

private struct BagRandom {
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

    /// An arbitrary JSON value. Key names deliberately include ones that *look* like
    /// fields this build knows, plus non-ASCII and an empty string, because a bag
    /// implementation that special-cases names is exactly the bug worth catching.
    mutating func json(depth: Int) -> JSONValue {
        switch int(depth <= 0 ? 5 : 7) {
        case 0: return .null
        case 1: return .bool(int(2) == 0)
        case 2: return .integer(Int64(int(2_000_001)) - 1_000_000)
        // Half-integral, so it is exact in binary *and* never an integer — an integral
        // `Double` legitimately comes back as `.integer`, which
        // `anIntegralDoubleIsRewrittenAsAnInteger` pins down separately.
        case 3: return .double(Double(int(100_000)) + 0.5)
        case 4: return .string(["", "sealed", "ünïcode 🔐", "x", "a\nb", "\"quoted\""][int(6)])
        case 5:
            return .array((0..<int(4)).map { _ in json(depth: depth - 1) })
        default:
            var object: [String: JSONValue] = [:]
            for _ in 0..<int(4) {
                object[["", "id", "future", "ü", "nested"][int(5)]] = json(depth: depth - 1)
            }
            return .object(object)
        }
    }

    mutating func bag() -> [String: JSONValue] {
        var bag: [String: JSONValue] = [:]
        for index in 0..<int(5) {
            bag["future\(index)"] = json(depth: 3)
        }
        return bag
    }
}

// MARK: - Tests

@Suite struct VaultDocumentTests {

    // MARK: Round trip

    @Test func aDocumentSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = document(wrapCLI: "v1.k-7f3a91c0.cli.bm9uY2U.d3JhcA")

        let decoded = try VaultFile.decode(VaultFile.encode(original))

        #expect(decoded == original)
        // Named explicitly rather than left to `==`, so a future field added without a
        // matching encode line fails here with a readable message instead of a
        // whole-struct inequality dump.
        #expect(decoded.kid == original.kid)
        #expect(decoded.vaultSalt == original.vaultSalt)
        #expect(decoded.kdf == original.kdf)
        #expect(decoded.wrapPass == original.wrapPass)
        #expect(decoded.wrapRecovery == original.wrapRecovery)
        #expect(decoded.wrapCLI == original.wrapCLI)
        #expect(decoded.records.map(\.id) == original.records.map(\.id))
        #expect(decoded.records.map(\.sealed) == original.records.map(\.sealed))
        #expect(decoded.records.map(\.hlc) == original.records.map(\.hlc))
    }

    /// The encoder is the sync layer's byte digest input. If the same document could
    /// produce two different files, every device would see every other device's write
    /// as a change and the fleet would rewrite the vault at each other forever.
    @Test func theSameDocumentAlwaysProducesTheSameBytes() throws {
        var random = BagRandom(seed: 0xC0FFEE)
        let subject = document(
            x: random.bag(), kdfX: random.bag(),
            records: [record(0, x: random.bag()), record(1, x: random.bag())])

        let first = try VaultFile.encode(subject)
        let second = try VaultFile.encode(subject)
        let afterRoundTrip = try VaultFile.encode(VaultFile.decode(first))

        #expect(first == second)
        #expect(first == afterRoundTrip, "a decode/encode cycle is not a fixed point")
    }

    /// `null` rather than an absent key. A key that simply vanishes is
    /// indistinguishable from an older build having stripped it, and telling those two
    /// apart is the entire premise of the `x` bags.
    @Test func theCLIWrapIsWrittenAsAnExplicitNullWhenTheUserHasNotOptedIn() throws {
        let bytes = try VaultFile.encode(document(wrapCLI: nil))
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(text.contains("\"wrapCLI\" : null"))
        #expect(try VaultFile.decode(bytes).wrapCLI == nil)
    }

    @Test func timestampsKeepMillisecondResolution() throws {
        // Milliseconds, not seconds: `HLC.wallMs` is in milliseconds and `updatedAt`
        // feeds it, so truncating here would manufacture merge ties the writer never
        // had. Sub-millisecond precision is knowingly discarded.
        let odd = Date(timeIntervalSince1970: 1_785_312_000.123)
        let subject = document(records: [
            VaultRecord(
                id: id(9), name: "n", keyword: "k", createdAt: odd, updatedAt: odd,
                hlc: clock(1_785_312_000_123), contentHash: "h", sealed: "s"),
        ])

        let decoded = try VaultFile.decode(VaultFile.encode(subject))
        let delta = abs(try #require(decoded.records.first).updatedAt.timeIntervalSince(odd))

        #expect(delta < 0.001, "millisecond resolution was lost; drift was \(delta)s")
        #expect(String(decoding: try VaultFile.encode(subject), as: UTF8.self)
            .contains("2026-07-29T08:00:00.123Z"))
    }

    // MARK: Unknown-key passthrough

    /// The failure this prevents: build 61 adds `records[].expiresAt`, the user opens
    /// build 60 once, build 60 decodes the vault without that key, saves, and syncs the
    /// stripped copy to every other Mac. `snippets.json` avoids this by being frozen at
    /// nine keys forever; the vault cannot be frozen, so it carries the unknowns
    /// instead.
    @Test func unknownKeysSurviveDecodeAndReEncode() throws {
        let json = """
            {
              "schemaVersion": 1,
              "kid": "k-7f3a91c0",
              "vaultSalt": "c2FsdA==",
              "kdf": {
                "alg": "argon2id",
                "iterations": 3,
                "saltP": "cGVwcGVy",
                "memoryKiB": 65536,
                "parallelism": 4
              },
              "wrapPass": "wp",
              "wrapRecovery": "wr",
              "wrapCLI": null,
              "teamScope": {"id": "t-1", "members": ["a", "b"], "quota": 12.5, "trial": null},
              "records": [
                {
                  "id": "00000000-0000-4000-8000-000000000000",
                  "name": "n",
                  "keyword": "k",
                  "tags": ["t"],
                  "isEnabled": true,
                  "isPinned": false,
                  "createdAt": "2026-07-29T20:00:00.000Z",
                  "updatedAt": "2026-07-29T20:00:00.500Z",
                  "hlc": "0000019a1b2c-0000-aabbccdd",
                  "contentHash": "h",
                  "sealed": "s",
                  "expiresAt": "2027-01-01T00:00:00.000Z",
                  "revealCount": 7,
                  "policy": {"requireTouchID": true, "maxAgeDays": 30}
                }
              ]
            }
            """
        let decoded = try VaultFile.decode(Data(json.utf8))

        #expect(decoded.x["teamScope"] == .object([
            "id": .string("t-1"),
            "members": .array([.string("a"), .string("b")]),
            "quota": .double(12.5),
            "trial": .null,
        ]))
        #expect(decoded.kdf.x == ["memoryKiB": .integer(65536), "parallelism": .integer(4)])

        let onlyRecord = try #require(decoded.records.first)
        #expect(onlyRecord.x["expiresAt"] == .string("2027-01-01T00:00:00.000Z"))
        #expect(onlyRecord.x["revealCount"] == .integer(7))
        #expect(onlyRecord.x["policy"] == .object([
            "requireTouchID": .bool(true), "maxAgeDays": .integer(30),
        ]))

        // And the point of all of it: re-encoding puts them back.
        let text = String(decoding: try VaultFile.encode(decoded), as: UTF8.self)
        for survivor in ["teamScope", "memoryKiB", "parallelism", "expiresAt", "revealCount",
                         "requireTouchID", "maxAgeDays", "t-1"] {
            #expect(text.contains(survivor), "'\(survivor)' was stripped by a decode/encode cycle")
        }
        #expect(try VaultFile.decode(Data(text.utf8)) == decoded)
    }

    /// A bag entry named after a real field must never be re-emitted. Two keys with the
    /// same name in one object makes the file mean different things to different
    /// parsers, which for `sealed` would be a vault that unlocks on one machine and not
    /// another.
    @Test func aBagEntryCannotShadowARealField() throws {
        var subject = document(records: [record(0)])
        subject.x["kid"] = .string("attacker")
        subject.records[0].x["sealed"] = .string("attacker")

        let text = String(decoding: try VaultFile.encode(subject), as: UTF8.self)
        let decoded = try VaultFile.decode(Data(text.utf8))

        #expect(!text.contains("attacker"))
        #expect(decoded.kid == "k-7f3a91c0")
        #expect(try #require(decoded.records.first).sealed == record(0).sealed)
    }

    @Test(arguments: [1, 2, 3, 5, 8, 13, 21, 34] as [UInt64])
    func arbitraryPassthroughBagsRoundTripUnchanged(seed: UInt64) throws {
        var random = BagRandom(seed: seed)
        let subject = document(
            x: random.bag(), kdfX: random.bag(),
            records: [record(0, x: random.bag()), record(1, x: random.bag())])

        let encoded = try VaultFile.encode(subject)
        let decoded = try VaultFile.decode(encoded)

        #expect(decoded.x == subject.x, "seed \(seed)")
        #expect(decoded.kdf.x == subject.kdf.x, "seed \(seed)")
        #expect(decoded.records.map(\.x) == subject.records.map(\.x), "seed \(seed)")
        // The property that has to hold even where the value round-trip does not:
        // decoding and re-encoding must be a fixed point, or two builds that merely
        // opened the file would keep producing different bytes for the same content.
        #expect(try VaultFile.encode(decoded) == encoded, "seed \(seed)")
    }

    /// The one documented lossy edge, tested rather than merely claimed: JSON has a
    /// single number type, so `12.0` and `12` are the same value and come back as an
    /// integer. Nothing in this format cares, and the alternative — keeping the raw
    /// literal text — buys nothing for a field this build does not understand anyway.
    @Test func anIntegralDoubleIsRewrittenAsAnIntegerAndThenStaysPut() throws {
        var subject = document(records: [record(0)])
        subject.records[0].x = ["whole": .double(12), "fractional": .double(12.5)]

        let once = try VaultFile.decode(VaultFile.encode(subject))
        #expect(try #require(once.records.first).x == [
            "whole": .integer(12), "fractional": .double(12.5),
        ])

        let twice = try VaultFile.decode(VaultFile.encode(once))
        #expect(twice == once, "the normalization must happen at most once")
    }

    // MARK: Version probe

    /// The probe must run *before* the decode, and it must not depend on the decode
    /// succeeding. Get this backwards and an older build calls a newer vault corrupt,
    /// quarantines it, and shows the user an empty vault plus an alarming dialog for a
    /// file that was never damaged — and, if anything downstream is less careful than
    /// this one, writes over it.
    @Test func aNewerSchemaVersionIsReadOnlyEvenWhenTheRestOfTheFileIsUnintelligible() throws {
        let scratch = VaultScratch("too-new")
        defer { scratch.destroy() }

        try scratch.put("""
            {
              "schemaVersion": 99,
              "kdf": "this is not an object",
              "wrapPass": 12345,
              "records": "not an array either",
              "sealedEnvelope": {"v": 2}
            }
            """)
        let before = identity(of: scratch.vault)

        let outcome = VaultFile.load(from: scratch.vault)

        #expect(outcome.tooNewVersion == 99)
        #expect(!outcome.isCorrupt, "a newer file must not be mistaken for a damaged one")
        #expect(identity(of: scratch.vault) == before, "loading a newer vault touched it")
        #expect(entries(of: scratch.quarantineFolder) == [], "a newer vault was quarantined")
    }

    @Test func aDocumentFromANewerBuildCannotBeWrittenBack() throws {
        let scratch = VaultScratch("write-refused")
        defer { scratch.destroy() }

        // The structural half of the same rule: even a caller that ignored `.tooNew`
        // and hand-built the document cannot land it on disk.
        let failure = #expect(throws: VaultFileError.self) {
            try VaultFile.write(
                document(schemaVersion: VaultDocument.currentSchemaVersion + 1),
                to: scratch.vault, temporaryDirectory: scratch.tmpFolder)
        }
        guard case .writeRefused = try #require(failure) else {
            Issue.record("expected a refusal, got \(String(describing: failure))")
            return
        }
        #expect(scratch.bytes() == nil, "the refused write created a file anyway")
    }

    @Test func aFileAtOrBelowThisSchemaVersionLoadsNormally() throws {
        let scratch = VaultScratch("current-version")
        defer { scratch.destroy() }

        try VaultFile.write(document(), to: scratch.vault, temporaryDirectory: scratch.tmpFolder)

        #expect(VaultFile.load(from: scratch.vault).value == document())
        #expect(VaultFile.load(from: scratch.vault).tooNewVersion == nil)
    }

    // MARK: Missing versus unreadable versus corrupt

    /// Three outcomes, kept apart because only one of them permits creating a vault.
    @Test func noVaultYetIsMissingRatherThanCorrupt() {
        let scratch = VaultScratch("missing")
        defer { scratch.destroy() }

        #expect(VaultFile.load(from: scratch.vault).isMissing)
        #expect(VaultFile.loadMetadata(from: scratch.vault).isMissing)
    }

    /// An I/O failure is not corruption. Quarantining on a read error would move a
    /// perfectly good vault aside because a volume was slow to mount.
    @Test func anUnreadableVaultIsNotReportedAsCorrupt() throws {
        let scratch = VaultScratch("unreadable")
        defer { scratch.destroy() }

        // A directory where the file should be: reliably unreadable, and unlike a
        // `chmod 000` file it behaves the same when the suite is run as root.
        try FileManager.default.createDirectory(at: scratch.vault, withIntermediateDirectories: true)

        let outcome = VaultFile.load(from: scratch.vault)

        #expect(!outcome.isCorrupt)
        #expect(!outcome.isMissing)
        guard case .unreadable = outcome else {
            Issue.record("expected .unreadable, got \(outcome)")
            return
        }
    }

    /// Reading a missing `records` array as "empty vault" is the same mistake
    /// `LibraryWriter.read` documents for `snippets.json`: the emptiness is taken at
    /// face value and saved, turning a damaged file into permanent loss.
    @Test func aDocumentWithoutItsRecordsArrayIsCorruptRatherThanEmpty() throws {
        let scratch = VaultScratch("no-records")
        defer { scratch.destroy() }

        try scratch.put("""
            {"schemaVersion": 1, "kid": "k", "vaultSalt": "s",
             "kdf": {"alg": "a", "iterations": 1, "saltP": "p"},
             "wrapPass": "wp", "wrapRecovery": "wr"}
            """)

        #expect(VaultFile.load(from: scratch.vault).isCorrupt)
    }

    /// The other half of the leniency rule: metadata may be damaged and the record
    /// still survives, because the ciphertext is the part that cannot be retyped.
    @Test func damagedMetadataKeepsTheRecordButAMissingSealedBlobDoesNot() throws {
        let lenient = """
            {"schemaVersion": 1, "kid": "k", "vaultSalt": "s",
             "kdf": {"alg": "a", "iterations": 1, "saltP": "p"},
             "wrapPass": "wp", "wrapRecovery": "wr",
             "records": [{
               "id": "00000000-0000-4000-8000-000000000007",
               "name": 42, "keyword": ["not", "a", "string"], "tags": "work",
               "isEnabled": "yes", "isPinned": 1,
               "createdAt": "not a date", "updatedAt": {},
               "hlc": "nonsense",
               "sealed": "the irreplaceable part"
             }]}
            """
        let decoded = try VaultFile.decode(Data(lenient.utf8))
        let only = try #require(decoded.records.first)

        #expect(only.sealed == "the irreplaceable part")
        #expect(only.id == id(7))
        #expect(only.name == "")
        #expect(only.keyword == "")
        #expect(only.tags == [])
        #expect(only.isEnabled)
        #expect(!only.isPinned)
        // `.distantPast`, never a fabricated `Date()`: an undated record must lose every
        // merge and every ranking comparison rather than win them all.
        #expect(only.createdAt == .distantPast)
        #expect(only.hlc.device == HLC.foreignDevice, "a damaged clock must fall back to foreign")

        let withoutSealed = lenient.replacingOccurrences(
            of: "\"sealed\": \"the irreplaceable part\"", with: "\"revealCount\": 3")
        #expect(throws: (any Error).self) {
            try VaultFile.decode(Data(withoutSealed.utf8))
        }
    }

    // MARK: Quarantine

    /// The rule this whole file exists to enforce: a vault we cannot read is moved
    /// aside with its bytes intact. It is never deleted, never truncated, and — above
    /// all — never replaced by a fresh empty one, because "this build cannot parse it"
    /// is a statement about the build, not about the data.
    @Test func aCorruptVaultIsQuarantinedIntactAndNeverOverwritten() throws {
        let scratch = VaultScratch("quarantine")
        defer { scratch.destroy() }

        let damaged = Data("{\"schemaVersion\": 1, \"kid\": \"k\", trunca".utf8)
        try scratch.put(damaged)
        let before = try #require(identity(of: scratch.vault))

        let outcome = VaultFile.load(from: scratch.vault)
        #expect(outcome.isCorrupt)
        #expect(outcome.failure != nil)
        // Loading must be a pure read. No inode change means nothing was republished.
        #expect(identity(of: scratch.vault) == before, "merely loading a damaged vault rewrote it")
        #expect(scratch.bytes() == damaged)

        let moved = try VaultFile.quarantine(
            at: scratch.vault, reason: "truncated JSON", now: at(0))

        #expect(try Data(contentsOf: moved) == damaged, "quarantine altered the bytes")
        #expect(moved.deletingLastPathComponent().lastPathComponent == "Quarantine")
        #expect(moved.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent == "Vault", "the vault was quarantined outside its own folder")
        #expect(!FileManager.default.fileExists(atPath: scratch.vault.path),
                "quarantine left the damaged file in place, so it will fail again every launch")
        #expect(VaultFile.load(from: scratch.vault).isMissing)

        // The note beside it, so a folder of timestamped JSON is not a mystery later.
        let note = moved.deletingPathExtension().appendingPathExtension("txt")
        let text = String(decoding: try Data(contentsOf: note), as: UTF8.self)
        #expect(text.contains("truncated JSON"))
        #expect(text.contains("NOT deleted"))
    }

    @Test func quarantiningTwiceInTheSameSecondKeepsBothCopies() throws {
        let scratch = VaultScratch("quarantine-twice")
        defer { scratch.destroy() }

        try scratch.put("first")
        let firstMove = try VaultFile.quarantine(at: scratch.vault, reason: "one", now: at(0))
        try scratch.put("second")
        let secondMove = try VaultFile.quarantine(at: scratch.vault, reason: "two", now: at(0))

        #expect(firstMove != secondMove)
        #expect(String(decoding: try Data(contentsOf: firstMove), as: UTF8.self) == "first")
        #expect(String(decoding: try Data(contentsOf: secondMove), as: UTF8.self) == "second")
    }

    @Test func quarantiningNothingIsAnError() {
        let scratch = VaultScratch("quarantine-nothing")
        defer { scratch.destroy() }

        #expect(throws: VaultFileError.self) {
            try VaultFile.quarantine(at: scratch.vault, reason: "nothing here", now: at(0))
        }
    }

    // MARK: Metadata-only decode

    /// `snippets-cli list` must work on a machine where no key exists, the keychain is
    /// locked, or the binary is unsigned. So the metadata path never looks at `kdf` or
    /// the wrap blobs — proven here by making every one of them unintelligible and
    /// checking the listing still comes out.
    @Test func metadataOnlyDecodeNeedsNoKeyAndNoKDF() throws {
        let scratch = VaultScratch("metadata-only")
        defer { scratch.destroy() }

        try scratch.put("""
            {
              "schemaVersion": 1,
              "kdf": "not an object at all",
              "wrapPass": 42,
              "wrapRecovery": {"unexpected": true},
              "records": [
                {"id": "00000000-0000-4000-8000-000000000000", "name": "AWS root password",
                 "keyword": "awsroot", "tags": ["work"], "isEnabled": true, "isPinned": true,
                 "createdAt": "2026-07-29T20:00:00.000Z", "updatedAt": "2026-07-29T20:00:00.500Z",
                 "hlc": "0000019a1b2c-0000-aabbccdd", "contentHash": "h", "sealed": "s"},
                {"id": "00000000-0000-4000-8000-000000000001", "name": "Recovery codes",
                 "keyword": "codes", "sealed": "s2"}
              ]
            }
            """)

        // The full load cannot make sense of this file...
        #expect(VaultFile.load(from: scratch.vault).isCorrupt)

        // ...and the CLI can still list it.
        let metadata = try #require(VaultFile.loadMetadata(from: scratch.vault).value)
        #expect(metadata.schemaVersion == 1)
        #expect(!metadata.isNewerThanThisBuild)
        #expect(metadata.shells.map(\.name) == ["AWS root password", "Recovery codes"])
        #expect(metadata.shells.map(\.keyword) == ["awsroot", "codes"])
        #expect(metadata.shells.map(\.content) == ["", ""])
        #expect(metadata.shells.map(\.isPinned) == [true, false])
    }

    /// Reading is safe at any schema version, so a newer file lists rather than
    /// refusing — the CLI just says so. Only *writing* is version-gated.
    @Test func metadataOnlyDecodeReadsANewerVaultAndSaysSo() throws {
        let scratch = VaultScratch("metadata-newer")
        defer { scratch.destroy() }

        try scratch.put("""
            {"schemaVersion": 99, "records": [
              {"id": "00000000-0000-4000-8000-000000000000", "name": "From the future",
               "keyword": "future", "sealed": "s", "quantumField": {"a": [1, 2, 3]}}
            ]}
            """)

        let metadata = try #require(VaultFile.loadMetadata(from: scratch.vault).value)
        #expect(metadata.isNewerThanThisBuild)
        #expect(metadata.shells.map(\.name) == ["From the future"])
        #expect(VaultFile.load(from: scratch.vault).tooNewVersion == 99)
    }

    // MARK: Shells

    /// A shell is handed to code that also handles ordinary snippets — the expander,
    /// the exporter, the share sheet. `content` is `""` rather than a placeholder like
    /// `"••••"` precisely because an empty expansion is inert everywhere, whereas a
    /// placeholder is a string that eventually gets typed into somebody's chat window.
    @Test func shellsCarryEmptyContentAndEveryPlaintextField() {
        let subject = record(
            3, name: "AWS root password", keyword: "  \\awsroot  ",
            tags: ["work", "prod"], isEnabled: false, isPinned: true,
            createdAt: 10, updatedAt: 20)

        let shell = subject.shell

        #expect(shell.content == "")
        #expect(shell.id == subject.id)
        #expect(shell.name == "AWS root password")
        #expect(shell.keyword == "  \\awsroot  ", "the shell must carry the keyword verbatim")
        // …and the ordinary normalization still applies on top of it, which is what
        // makes the shell usable for the editor's keyword-uniqueness check with the
        // vault locked.
        #expect(shell.normalizedKeyword == "awsroot")
        #expect(shell.tags == ["work", "prod"])
        #expect(!shell.isEnabled)
        #expect(shell.isPinned)
        #expect(shell.createdAt == at(10))
        #expect(shell.updatedAt == at(20))
    }

    /// Tags are normalized on *decode* and left alone by the in-memory initializer —
    /// exactly the split `Snippet` has, so a record and a snippet built the same way
    /// behave the same way. Anything else and the same tag list would compare unequal
    /// depending on whether it had been through a file.
    @Test func tagsAreNormalizedWhereSnippetNormalizesThem() throws {
        let messy = record(0, tags: ["Work", "work", " prod ", "", "  "])
        #expect(messy.tags == ["Work", "work", " prod ", "", "  "],
                "the in-memory initializer must not silently rewrite what it was handed")

        let decoded = try VaultFile.decode(VaultFile.encode(document(records: [messy])))
        #expect(try #require(decoded.records.first).tags == ["Work", "prod"])
    }

    @Test func documentShellsAreOnePerRecordInFileOrder() {
        let subject = document(records: [
            record(2, name: "second", keyword: "b"),
            record(1, name: "first", keyword: "a"),
        ])

        #expect(subject.shells.map(\.name) == ["second", "first"])
        #expect(subject.shells.allSatisfy { $0.content.isEmpty })
        #expect(subject.record(id(1))?.name == "first")
        #expect(subject.record(id(99)) == nil)
    }

    /// A shell must be safe to feed to the keyword-collision pass alongside ordinary
    /// snippets: that is the whole reason metadata is plaintext.
    @Test func shellsParticipateInKeywordCollisionResolution() {
        let plain = Snippet(
            id: id(50), name: "Plain", keyword: "awsroot", content: "hello",
            createdAt: at(0), updatedAt: at(0))
        var library = [plain, record(0, keyword: "awsroot", updatedAt: 100).shell]

        let disabled = SyncMerge.resolveKeywordCollisions(&library)

        #expect(disabled == [plain.id], "the older plain snippet should have lost the keyword")
        #expect(library.first(where: { $0.id == id(0) })?.isEnabled == true)
    }

    // MARK: Writing

    @Test func aWrittenVaultIsAtomicPrivateAndStagedOutsideItsOwnFolder() throws {
        let scratch = VaultScratch("write")
        defer { scratch.destroy() }

        try VaultFile.write(document(), to: scratch.vault, temporaryDirectory: scratch.tmpFolder)

        var info = stat()
        #expect(stat(scratch.vault.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o600, "the vault must not be group- or world-readable")
        #expect(entries(of: scratch.vaultFolder) == ["vault.json"],
                "the write left staging debris in the folder the app monitors")
        #expect(entries(of: scratch.tmpFolder) == [])
        #expect(VaultFile.load(from: scratch.vault).value == document())
    }

    /// `Vault/` may not exist yet on a machine that has never used the feature.
    @Test func writingCreatesTheVaultFolderWhenItIsMissing() throws {
        let scratch = VaultScratch("mkdir")
        defer { scratch.destroy() }

        let nested = scratch.root
            .appendingPathComponent("Fresh", isDirectory: true)
            .appendingPathComponent("vault.json", isDirectory: false)

        try VaultFile.write(document(), to: nested, temporaryDirectory: scratch.tmpFolder)

        #expect(VaultFile.load(from: nested).value == document())
    }
}

// MARK: - JSONValue

@Suite struct JSONValueTests {

    /// `true` must not become `1`, and `600000` must not become `600000.0`. Both would
    /// be silent rewrites of somebody else's field.
    @Test func scalarsKeepTheirJSONType() throws {
        let json = #"{"t": true, "f": false, "i": 600000, "d": 12.5, "s": "1", "n": null}"#
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))

        #expect(decoded["t"] == .bool(true))
        #expect(decoded["f"] == .bool(false))
        #expect(decoded["i"] == .integer(600_000))
        #expect(decoded["d"] == .double(12.5))
        #expect(decoded["s"] == .string("1"))
        #expect(decoded["n"] == .null)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        #expect(text == #"{"d":12.5,"f":false,"i":600000,"n":null,"s":"1","t":true}"#)
    }

    @Test func nestingAndEmptyContainersSurvive() throws {
        let json = #"{"a":[],"b":{},"c":[[],[{"d":[null,{"e":1}]}]]}"#
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(decoded), as: UTF8.self) == json)
    }
}

// MARK: - SecretStore

@Suite struct SecretStoreTests {

    private func key(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: SecretStoreLimits.secretByteCount)
    }

    @Test func secretsRoundTripAndOverwrite() throws {
        let store = InMemorySecretStore()

        #expect(try store.secret(named: "vault.cli") == nil, "absence must not throw")
        try store.setSecret(key(0xAB), named: "vault.cli")
        #expect(try store.secret(named: "vault.cli") == key(0xAB))

        try store.setSecret(key(0xCD), named: "vault.cli")
        #expect(try store.secret(named: "vault.cli") == key(0xCD))
        #expect(store.storedNames == ["vault.cli"])
    }

    /// Deleting something that is not there succeeds: the postcondition the caller
    /// wants is "there is no secret under this name", and making that throw pushes a
    /// pointless `try?` into every teardown path.
    @Test func deletingIsIdempotent() throws {
        let store = InMemorySecretStore(["vault.cli": key(1)])

        try store.deleteSecret(named: "vault.cli")
        try store.deleteSecret(named: "vault.cli")

        #expect(try store.secret(named: "vault.cli") == nil)
        #expect(store.storedNames == [])
    }

    /// Checked at the *store* rather than only at the reader: a 31-byte key written
    /// once is a vault that fails to unlock forever after, and the failure surfaces
    /// nowhere near the bug.
    @Test func aSecretThatIsNotThirtyTwoBytesIsRejected() throws {
        let store = InMemorySecretStore()

        for count in [0, 16, 31, 33, 64] {
            let failure = #expect(throws: SecretStoreError.self) {
                try store.setSecret(Data(repeating: 0, count: count), named: "vault.cli")
            }
            #expect(failure == .wrongLength(expected: 32, actual: count))
        }
        #expect(throws: SecretStoreError.emptyName) {
            try store.setSecret(key(1), named: "")
        }
        #expect(store.storedNames == [], "a rejected secret was stored anyway")
    }

    @Test func requireSecretTurnsAbsenceIntoAnError() throws {
        let store = InMemorySecretStore()

        #expect(throws: SecretStoreError.self) { try store.requireSecret(named: "vault.cli") }

        try store.setSecret(key(7), named: "vault.cli")
        #expect(try store.requireSecret(named: "vault.cli") == key(7))
    }

    /// The reason the protocol exists: `swift test` runs unsigned, so the real Keychain
    /// answers `errSecMissingEntitlement` (-34018) to every call. Code that must cope
    /// with that needs a way to reproduce it without a keychain.
    @Test func theStoreCanBeMadeToFailTheWayAnUnsignedKeychainDoes() throws {
        let store = InMemorySecretStore(["vault.cli": key(3)])
        let missingEntitlement = SecretStoreError.unavailable(
            detail: "keychain unavailable", status: -34018)
        store.failEveryOperation(with: missingEntitlement)

        #expect(throws: missingEntitlement) { try store.secret(named: "vault.cli") }
        #expect(throws: missingEntitlement) { try store.setSecret(key(4), named: "vault.cli") }
        #expect(throws: missingEntitlement) { try store.deleteSecret(named: "vault.cli") }
        #expect("\(missingEntitlement)".contains("-34018"))

        store.failEveryOperation(with: nil)
        #expect(try store.secret(named: "vault.cli") == key(3), "the stub must be reversible")
    }
}
