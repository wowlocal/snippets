import Foundation
import XCTest

@testable import Snippets

/// The ordinary library is the durable source a restarted process projects.
///
/// A sync journal is deliberately more durable than one process: once it records B as
/// offered, a restart must not be able to rediscover A from `snippets.json` and stamp it
/// as a fresh local edit. These tests keep the store's long debounce pending so that the
/// bridge is the only boundary capable of closing that crash window.
@MainActor
final class SyncSnapshotDurabilityTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SyncSnapshotDurabilityTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testPendingEditIsDurableBeforeJournalOfferAndSurvivesCrashRestart() async throws {
        let original = snippet(content: "disk A")
        try seed([original])

        let store = makeStore()
        let bridge = makeBridge(store: store)
        var edited = try XCTUnwrap(store.snippet(id: original.id))
        edited.content = "offered B"
        store.update(edited)

        XCTAssertEqual(try diskLibrary().first?.content, "disk A",
                       "the fixture must enter sync with a real debounce window")

        let transport = CancelAfterObservingSubmitTransport(
            libraryURL: SnippetStorageLocations.snippetsFileURL)
        let engine = SyncEngine(
            transport: transport,
            library: bridge,
            sealer: SnapshotPassthroughSealer(),
            device: store.deviceID)

        _ = await engine.sync()

        XCTAssertEqual(transport.submitCount, 1)
        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertEqual(transport.libraryAtSubmit?.first?.content, "offered B",
                       "the primary file must contain B before transport can observe a batch")
        XCTAssertEqual(try diskLibrary().first?.content, "offered B")

        let base = try loadedBase()
        let journal = try loadedJournal()
        let offered = try XCTUnwrap(journal.entry(original.id)?.offered?.envelope)
        XCTAssertEqual(offered.fields?.content, Data("offered B".utf8))

        // Model a process death after the offer was made durable but before its
        // acknowledgement. Derived projection metadata is intentionally removed: the
        // restarted process must agree with the frozen offer from primary-file B alone.
        try? FileManager.default.removeItem(
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)
        let restartedStore = SnippetStore(configuration: .iOS)
        let restartedBridge = makeBridge(store: restartedStore)
        XCTAssertEqual(restartedStore.snippet(id: original.id)?.content, "offered B")

        let restartedProjection = try restartedBridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        XCTAssertEqual(restartedProjection[original.id], offered,
                       "restart must retry B, not manufacture a newer envelope for disk A")
    }

    func testPrimaryWriteFailureStopsBeforeJournalMetadataOrTransportAndCreatesNoRescue() async throws {
        let original = snippet(content: "disk A")
        try seed([original])

        let attempts = LockedCounter()
        let worker = SnippetPersistenceWorker(
            label: "test.sync-snapshot.primary-failure",
            hooks: .init(overrideResult: { _ in
                attempts.increment()
                return .failure(.busy)
            }))
        let store = makeStore(worker: worker)
        let bridge = makeBridge(store: store)
        var edited = try XCTUnwrap(store.snippet(id: original.id))
        edited.content = "must not be offered B"
        store.update(edited)

        let transport = CancelAfterObservingSubmitTransport(
            libraryURL: SnippetStorageLocations.snippetsFileURL)
        let engine = SyncEngine(
            transport: transport,
            library: bridge,
            sealer: SnapshotPassthroughSealer(),
            device: store.deviceID)

        let state = await engine.sync()

        guard case .halted(.localLibraryQuarantined, _) = state else {
            return XCTFail("expected a fail-closed durable-snapshot halt, got \(state)")
        }
        XCTAssertEqual(attempts.value, 3)
        XCTAssertEqual(try diskLibrary().first?.content, "disk A")
        XCTAssertEqual(transport.submitCount, 0)
        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertNil(try loadedJournal().entry(original.id),
                     "B must not become desired/offered state when its source file is still A")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncLibraryMetadataFileURL.path),
            "derived metadata must not get ahead of the primary library either")

        let backupNames = try FileManager.default.contentsOfDirectory(
            atPath: SnippetStorageLocations.backupsFolderURL.path)
        XCTAssertFalse(backupNames.contains { $0.hasPrefix("unsaved-") },
                       "a rescue copy is useful at termination but is not sync durability")
    }

    func testSynchronousChangeObserverCannotProjectBeforeDirtyOwnershipIsPublished() throws {
        let original = snippet(content: "disk A")
        try seed([original])

        let store = makeStore()
        let bridge = makeBridge(store: store)
        var callbackProjection: Result<[UUID: SyncEnvelope], Error>?
        store.onChange = { change in
            guard case .local = change.source, callbackProjection == nil else { return }
            callbackProjection = Result {
                try bridge.currentEnvelopes(agreedBase: SyncBase())
            }
        }

        var edited = try XCTUnwrap(store.snippet(id: original.id))
        edited.content = "observer B"
        store.update(edited)

        let projection = try XCTUnwrap(callbackProjection).get()
        XCTAssertEqual(projection[original.id]?.fields?.content, Data("observer B".utf8))
        XCTAssertEqual(try diskLibrary().first?.content, "observer B",
                       "a synchronous Sync Now callback must see dirty ownership and flush B")
    }

    // MARK: - Fixtures

    private func makeStore(
        worker: SnippetPersistenceWorker = SnippetPersistenceWorker()
    ) -> SnippetStore {
        SnippetStore(
            configuration: .iOS,
            persistenceWorker: worker,
            persistDelay: 60,
            persistenceRetryBaseDelay: 60)
    }

    private func makeBridge(store: SnippetStore) -> SnippetLibraryBridge {
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        let session = VaultSession(
            keychain: keychain,
            authenticationEvaluator: { _ in true })
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: keychain,
            deviceID: store.deviceID)
        store.secureProvider = secureStore
        return SnippetLibraryBridge(store: store, secureStore: secureStore)
    }

    private func seed(_ snippets: [Snippet]) throws {
        try SnippetLibraryCodec.encode(snippets)
            .write(to: SnippetStorageLocations.snippetsFileURL, options: .atomic)
    }

    private func diskLibrary() throws -> [Snippet] {
        try SnippetLibraryCodec.decode(
            Data(contentsOf: SnippetStorageLocations.snippetsFileURL))
    }

    private func loadedBase() throws -> SyncBase {
        guard case .loaded(let base) = SyncBaseFile.load() else {
            throw SnapshotTestFailure.expectedReadableBase
        }
        return base
    }

    private func loadedJournal() throws -> SyncJournal {
        guard case .loaded(let journal) = SyncJournalFile.load() else {
            throw SnapshotTestFailure.expectedReadableJournal
        }
        return journal
    }

    private func snippet(content: String) -> Snippet {
        Snippet(
            name: "Durability",
            keyword: "durability",
            content: content,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000))
    }
}

private enum SnapshotTestFailure: Error {
    case expectedReadableBase
    case expectedReadableJournal
}

private struct SnapshotPassthroughSealer: SyncBlobSealing {
    nonisolated func seal(_ plaintext: Data, for identity: WireIdentity) throws -> Data {
        plaintext
    }

    nonisolated func open(_ ciphertext: Data, for identity: WireIdentity) throws -> Data {
        ciphertext
    }
}

private final class CancelAfterObservingSubmitTransport: SyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let libraryURL: URL
    private var submitCountStorage = 0
    private var fetchCountStorage = 0
    private var libraryAtSubmitStorage: [Snippet]?

    nonisolated let identifier = "snapshot-observer"
    nonisolated let supportsPush = true
    nonisolated let pollInterval: TimeInterval = 60
    nonisolated let events = AsyncStream<SyncTransportEvent> { continuation in
        continuation.finish()
    }

    init(libraryURL: URL) {
        self.libraryURL = libraryURL
    }

    var submitCount: Int {
        lock.withLock { submitCountStorage }
    }

    var fetchCount: Int {
        lock.withLock { fetchCountStorage }
    }

    var libraryAtSubmit: [Snippet]? {
        lock.withLock { libraryAtSubmitStorage }
    }

    nonisolated func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        lock.withLock { fetchCountStorage += 1 }
        return SyncFetch(records: [], cursor: cursor)
    }

    nonisolated func submit(
        _ records: [WireRecord], at cursor: SyncCursor?
    ) async throws -> SyncSubmission {
        let snapshot = try SnippetLibraryCodec.decode(Data(contentsOf: libraryURL))
        lock.withLock {
            submitCountStorage += 1
            libraryAtSubmitStorage = snapshot
        }
        throw CancellationError()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
