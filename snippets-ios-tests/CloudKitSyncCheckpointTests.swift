import CryptoKit
import Foundation
import XCTest

@testable import Snippets

/// Durable protocol tests for CKSyncEngine's opaque state and inbound receipts.
///
/// Apple can advance `CKSyncEngine.State.Serialization` past records the app has not
/// applied yet.  The serialization and every record belonging to that watermark must
/// therefore share one atomic, account-scoped checkpoint.  Opaque `Data` keeps these
/// tests deterministic and completely independent of a signed iCloud container.
final class CloudKitSyncCheckpointTests: XCTestCase {
    private var rootURL: URL!
    private var checkpointURL: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        let testSupportDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        rootURL = testSupportDirectory.appendingPathComponent(
            "CloudKitSyncCheckpointTests-\(UUID().uuidString)", isDirectory: true)
        checkpointURL = rootURL.appendingPathComponent(
            "cksync-checkpoint.json", isDirectory: false)
        temporaryDirectory = rootURL.appendingPathComponent("Tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
        checkpointURL = nil
        temporaryDirectory = nil
    }

    func testStateUpdateIsAtomicAndRestoredAfterProcessRestart() throws {
        let account = identity(0x11)
        let store = makeStore()

        try store.saveStateSerialization(Data("state-v1".utf8), for: account)
        var checkpoint = try loaded(store.load(for: account))
        XCTAssertEqual(checkpoint.serialization, Data("state-v1".utf8))
        XCTAssertTrue(checkpoint.generations.isEmpty)

        // A new instance models process restart and must recover the same engine epoch.
        checkpoint = try loaded(makeStore().load(for: account))
        let epoch = checkpoint.epoch
        try makeStore().saveStateSerialization(Data("state-v2".utf8), for: account)

        checkpoint = try loaded(makeStore().load(for: account))
        XCTAssertEqual(checkpoint.epoch, epoch)
        XCTAssertEqual(checkpoint.serialization, Data("state-v2".utf8))
        XCTAssertTrue(try contents(of: temporaryDirectory).isEmpty,
                      "an atomic state update must not orphan staging files")
    }

    func testEntireCheckpointIsAuthenticatedCiphertextAndRestartsWithSameKey() throws {
        let account = identity(0x19)
        let serialization = Data("state-stable-user-record-name".utf8)
        let record = WireRecord(
            id: UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!,
            rev: "plaintext-rev-sentinel",
            deleted: false,
            blob: Data("plaintext-blob-sentinel".utf8),
            recordVersion: SyncRecordVersion(Data("plaintext-version-sentinel".utf8)))
        let cryptor = TestCloudKitSyncCheckpointCryptor(seed: 0x19)
        let store = makeStore(cryptor: cryptor)

        _ = try store.appendFetched(
            records: [record], physicalDeletionCount: 2,
            stateSerialization: serialization, for: account)
        let expected = try loaded(store.load(for: account))
        let sealedBytes = try Data(contentsOf: checkpointURL)

        for sentinel in [
            "stable-user-record-name",
            "plaintext-rev-sentinel",
            "plaintext-blob-sentinel",
            "plaintext-version-sentinel",
            record.id.uuidString.lowercased(),
            record.id.uuidString.uppercased(),
            "schemaVersion",
            "accountIdentity",
            "epoch",
            "serialization",
            "nextSequence",
            "generations",
            "records",
            "physicalDeletionCount",
            "recordVersion",
            "blob",
            "rev",
        ] {
            XCTAssertNil(
                sealedBytes.range(of: Data(sentinel.utf8)),
                "the complete checkpoint envelope must be encrypted; leaked \(sentinel)")
        }

        XCTAssertEqual(
            try loaded(makeStore(cryptor: cryptor).load(for: account)),
            expected,
            "a restarted process with the same local key must restore state and inbox")

        let wrongKeyStore = makeStore(
            cryptor: TestCloudKitSyncCheckpointCryptor(seed: 0x29))
        guard case .unreadable = wrongKeyStore.load(for: account) else {
            return XCTFail("an authenticated checkpoint must reject a different key")
        }
        XCTAssertEqual(try Data(contentsOf: checkpointURL), sealedBytes,
                       "wrong-key recovery must not rewrite or silently reset evidence")

        var tamperedBytes = sealedBytes
        let tamperedIndex = tamperedBytes.index(
            tamperedBytes.startIndex, offsetBy: tamperedBytes.count / 2)
        tamperedBytes[tamperedIndex] ^= 0x01
        try tamperedBytes.write(to: checkpointURL)

        guard case .unreadable = makeStore(cryptor: cryptor).load(for: account) else {
            return XCTFail("authenticated ciphertext must fail closed after tampering")
        }
        XCTAssertEqual(try Data(contentsOf: checkpointURL), tamperedBytes,
                       "a failed authentication must leave the exact bytes untouched")
    }

    func testLostOrUnavailableLocalKeyCannotResetDurableInboxWithoutReview() throws {
        let account = identity(0x1A)
        let originalCryptor = TestCloudKitSyncCheckpointCryptor(seed: 0x3A)
        _ = try makeStore(cryptor: originalCryptor).appendFetched(
            records: [wire(
                id: "87654321-4321-4321-8321-cba987654321",
                rev: "durable-unapplied-record")],
            physicalDeletionCount: 0,
            stateSerialization: Data("durable-state".utf8),
            for: account)
        let originalBytes = try Data(contentsOf: checkpointURL)
        let unavailableStore = makeStore(
            cryptor: TestCloudKitSyncCheckpointCryptor(seed: 0x3A, isAvailable: false))

        guard case .unreadable = unavailableStore.load(for: account) else {
            return XCTFail("a nonempty checkpoint without its key must fail closed")
        }
        XCTAssertEqual(try Data(contentsOf: checkpointURL), originalBytes)
        XCTAssertThrowsError(
            try unavailableStore.resetAfterAccountReview(for: account),
            "review cannot claim success while the replacement key is unavailable")
        XCTAssertEqual(try Data(contentsOf: checkpointURL), originalBytes)

        let replacementStore = makeStore(
            cryptor: TestCloudKitSyncCheckpointCryptor(seed: 0x4A))
        try replacementStore.resetAfterAccountReview(for: account)

        let reset = try loaded(replacementStore.load(for: account))
        XCTAssertNil(reset.serialization)
        XCTAssertTrue(reset.generations.isEmpty)
        XCTAssertNotEqual(try Data(contentsOf: checkpointURL), originalBytes,
                          "only the explicit reviewed reset may replace lost-key ciphertext")
    }

    func testCheckpointFileIsProtectedUntilFirstUnlockAndExcludedFromBackup() throws {
        let protection = CheckpointFileProtectionProbe()
        let store = CloudKitSyncCheckpointStore(
            url: checkpointURL,
            temporaryDirectory: temporaryDirectory,
            cryptor: TestCloudKitSyncCheckpointCryptor(seed: 0xC7),
            applyFileProtection: { url in protection.record(url) })

        try store.saveStateSerialization(Data("protected-state".utf8), for: identity(0x1B))

        XCTAssertEqual(
            protection.urls,
            [rootURL, temporaryDirectory, checkpointURL],
            "protection must cover both staging directories and the final file after rename")

        #if os(iOS) && !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: checkpointURL.path)
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication)
        #endif
        XCTAssertEqual(
            try checkpointURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true)
    }

    func testCorruptTruncatedOrFutureCheckpointFailsClosedWithoutRewrite() throws {
        let account = identity(0x22)
        let cryptor = TestCloudKitSyncCheckpointCryptor(seed: 0xC7)
        let documents = [
            Data("{not-json".utf8),
            Data("{\"schemaVersion\":1}".utf8),
            Data("""
                {"schemaVersion":999,"accountIdentity":{"schemaVersion":1,"data":"IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI="},"epoch":"11111111-1111-4111-8111-111111111111","serialization":"c3RhdGU=","nextSequence":1,"generations":[]}
                """.utf8),
        ]

        for document in documents {
            let sealedDocument = try cryptor.seal(document)
            try sealedDocument.write(to: checkpointURL)
            guard case .unreadable = makeStore(cryptor: cryptor).load(for: account) else {
                XCTFail("damaged/future checkpoint must fail closed")
                continue
            }
            XCTAssertEqual(try Data(contentsOf: checkpointURL), sealedDocument,
                           "load must not normalize evidence it cannot understand")
        }
    }

    func testWrongScopeIsPreservedUntilExplicitAccountReviewReset() throws {
        let accountA = identity(0x31)
        let accountB = identity(0x32)
        try makeStore().saveStateSerialization(Data("account-a-token".utf8), for: accountA)
        let accountABytes = try Data(contentsOf: checkpointURL)

        guard case .scopeMismatch = makeStore().load(for: accountB) else {
            return XCTFail("a different private database must not inherit this checkpoint")
        }
        XCTAssertEqual(try Data(contentsOf: checkpointURL), accountABytes)

        try makeStore().resetAfterAccountReview(for: accountB)

        let reset = try loaded(makeStore().load(for: accountB))
        XCTAssertNil(reset.serialization)
        XCTAssertTrue(reset.generations.isEmpty)
        XCTAssertNotEqual(try Data(contentsOf: checkpointURL), accountABytes)
        guard case .scopeMismatch = makeStore().load(for: accountA) else {
            return XCTFail("review reset must establish the replacement scope")
        }
    }

    func testFetchedGenerationPersistsExactStateRecordsAndMetadataTogether() throws {
        let account = identity(0x41)
        let first = wire(id: "11111111-1111-4111-8111-111111111111", rev: "r1")
        let second = wire(id: "22222222-2222-4222-8222-222222222222", rev: "r2")
        try makeStore().saveStateSerialization(Data("before-fetch".utf8), for: account)

        let generation = try makeStore().appendFetched(
            records: [first, second],
            physicalDeletionCount: 3,
            stateSerialization: Data("after-fetch".utf8),
            for: account)

        let restarted = try loaded(makeStore().load(for: account))
        XCTAssertEqual(restarted.serialization, Data("after-fetch".utf8))
        XCTAssertEqual(restarted.generations, [generation])
        XCTAssertEqual(generation.records, [first, second])
        XCTAssertEqual(generation.physicalDeletionCount, 3,
                       "physical deletes are ignored by merge but must remain auditable input")
        XCTAssertEqual(generation.serialization, Data("after-fetch".utf8))
        XCTAssertEqual(generation.sequence, 1)
    }

    func testR1S1R2S2KeepExactWatermarksAndAckOnlyPrefix() throws {
        let account = identity(0x51)
        let r1 = wire(id: "33333333-3333-4333-8333-333333333333", rev: "R1")
        let r2 = wire(id: "44444444-4444-4444-8444-444444444444", rev: "R2")
        let store = makeStore()

        let first = try store.appendFetched(
            records: [r1], physicalDeletionCount: 0,
            stateSerialization: Data("S1".utf8), for: account)
        let second = try store.appendFetched(
            records: [r2], physicalDeletionCount: 0,
            stateSerialization: Data("S2".utf8), for: account)

        var checkpoint = try loaded(makeStore().load(for: account))
        XCTAssertEqual(checkpoint.generations.map(\.records), [[r1], [r2]])
        XCTAssertEqual(
            checkpoint.generations.map(\.serialization),
            [Data("S1".utf8), Data("S2".utf8)],
            "committing generation 1 must never pair R1 with the later S2 watermark")
        XCTAssertEqual(checkpoint.serialization, Data("S2".utf8))

        try store.acknowledge(
            through: first.sequence, epoch: checkpoint.epoch, for: account)

        checkpoint = try loaded(makeStore().load(for: account))
        XCTAssertEqual(checkpoint.generations, [second],
                       "an ACK racing generation 2 may compact only generation 1")
        XCTAssertEqual(checkpoint.serialization, Data("S2".utf8))
    }

    func testWrongEpochAcknowledgementCannotDropInbox() throws {
        let account = identity(0x61)
        let generation = try makeStore().appendFetched(
            records: [wire(id: "55555555-5555-4555-8555-555555555555", rev: "remote")],
            physicalDeletionCount: 0,
            stateSerialization: Data("advanced".utf8),
            for: account)
        let before = try loaded(makeStore().load(for: account))

        XCTAssertThrowsError(try makeStore().acknowledge(
            through: generation.sequence,
            epoch: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            for: account))

        XCTAssertEqual(try loaded(makeStore().load(for: account)), before)
    }

    func testFabricatedSameEpochAcknowledgementCannotSkipAGenerationGap() throws {
        let account = identity(0x62)
        let epoch = UUID(uuidString: "62626262-6262-4262-8262-626262626262")!
        let cryptor = TestCloudKitSyncCheckpointCryptor(seed: 0xC7)
        let first = CloudKitSyncCheckpoint.Generation(
            sequence: 1,
            serialization: Data("S1".utf8),
            records: [wire(
                id: "61616161-6161-4161-8161-616161616161",
                rev: "retained-one")],
            physicalDeletionCount: 0)
        let third = CloudKitSyncCheckpoint.Generation(
            sequence: 3,
            serialization: Data("S3".utf8),
            records: [wire(
                id: "63636363-6363-4363-8363-636363636363",
                rev: "retained-three")],
            physicalDeletionCount: 0)
        let seeded = CloudKitSyncCheckpoint(
            accountIdentity: account,
            epoch: epoch,
            serialization: Data("S3".utf8),
            nextSequence: 4,
            generations: [first, third])
        let plaintext = try JSONEncoder().encode(seeded)
        let originalCiphertext = try cryptor.seal(plaintext)
        try originalCiphertext.write(to: checkpointURL)

        XCTAssertThrowsError(
            try makeStore(cryptor: cryptor).acknowledge(
                through: 2,
                epoch: epoch,
                for: account)
        ) { error in
            XCTAssertEqual(
                error as? CloudKitSyncCheckpointStore.Failure,
                .invalidAcknowledgement)
        }

        XCTAssertEqual(try Data(contentsOf: checkpointURL), originalCiphertext,
                       "a cursor the adapter never issued must not rewrite the inbox")
        XCTAssertEqual(
            try loaded(makeStore(cryptor: cryptor).load(for: account)),
            seeded,
            "a fabricated in-range receipt must not drop an unseen prefix")
    }

    func testDuplicateFetchedRecordsRemainOrderedUntilAcknowledged() throws {
        let account = identity(0x71)
        let duplicate = wire(
            id: "66666666-6666-4666-8666-666666666666", rev: "same")

        let generation = try makeStore().appendFetched(
            records: [duplicate, duplicate],
            physicalDeletionCount: 0,
            stateSerialization: Data("duplicate-state".utf8),
            for: account)

        XCTAssertEqual(generation.records, [duplicate, duplicate],
                       "the durable inbox preserves at-least-once delivery order")
    }

    func testStateUpdateOutsideFetchNeverErasesUnacknowledgedGenerations() throws {
        let account = identity(0x81)
        let store = makeStore()
        let generation = try store.appendFetched(
            records: [wire(id: "77777777-7777-4777-8777-777777777777", rev: "remote")],
            physicalDeletionCount: 0,
            stateSerialization: Data("fetch-state".utf8), for: account)

        try store.saveStateSerialization(Data("later-scheduler-state".utf8), for: account)

        let checkpoint = try loaded(makeStore().load(for: account))
        XCTAssertEqual(checkpoint.serialization, Data("later-scheduler-state".utf8))
        XCTAssertEqual(checkpoint.generations, [generation])
    }

    // MARK: - Fixtures

    private func makeStore(
        cryptor: any CloudKitSyncCheckpointCrypting = TestCloudKitSyncCheckpointCryptor(seed: 0xC7)
    ) -> CloudKitSyncCheckpointStore {
        CloudKitSyncCheckpointStore(
            url: checkpointURL,
            temporaryDirectory: temporaryDirectory,
            cryptor: cryptor)
    }

    private func identity(_ byte: UInt8) -> SyncAccountIdentity {
        SyncAccountIdentity(Data(repeating: byte, count: 32))
    }

    private func wire(id: String, rev: String) -> WireRecord {
        WireRecord(
            id: UUID(uuidString: id)!, rev: rev, deleted: false,
            blob: Data("blob-\(rev)".utf8),
            recordVersion: SyncRecordVersion(Data("version-\(rev)".utf8)))
    }

    private func loaded(
        _ outcome: CloudKitSyncCheckpointStore.LoadOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CloudKitSyncCheckpoint {
        guard case .loaded(let checkpoint) = outcome else {
            XCTFail("expected loaded checkpoint, got \(outcome)", file: file, line: line)
            throw CheckpointTestFailure.notLoaded
        }
        return checkpoint
    }

    private func contents(of directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }
}

private enum CheckpointTestFailure: Error {
    case notLoaded
}

private nonisolated final class CheckpointFileProtectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] { lock.withLock { recordedURLs } }

    func record(_ url: URL) {
        lock.withLock { recordedURLs.append(url) }
    }
}

/// Deterministic only so disk assertions and restart fixtures are reproducible. The
/// shipping cryptor must generate a fresh nonce; this deliberately fixed nonce is never
/// used outside a throwaway test directory.
nonisolated struct TestCloudKitSyncCheckpointCryptor: CloudKitSyncCheckpointCrypting {
    enum Failure: Error {
        case unavailable
        case malformedCiphertext
    }

    private let key: SymmetricKey
    private let isAvailable: Bool

    init(seed: UInt8, isAvailable: Bool = true) {
        key = SymmetricKey(data: Data(repeating: seed, count: 32))
        self.isAvailable = isAvailable
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard isAvailable else { throw Failure.unavailable }
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0xA5, count: 12))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let combined = box.combined else { throw Failure.malformedCiphertext }
        return combined
    }

    func open(_ sealed: Data) throws -> Data {
        guard isAvailable else { throw Failure.unavailable }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }
}
