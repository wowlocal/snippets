import Darwin
import XCTest
@testable import Snippets

@MainActor
final class SyncLifecycleTests: XCTestCase {
    private static let wireKeyFingerprintDefaultsKey = "SnippetsSyncWireKeyFingerprint"

    private var rootURL: URL!
    private var previousSyncPreference: Any?
    private var previousWireKeyFingerprint: Any?

    override func setUpWithError() throws {
        SyncCoordinator.runtimeEnabledOverride = nil
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey)
        previousWireKeyFingerprint = UserDefaults.standard.object(
            forKey: Self.wireKeyFingerprintDefaultsKey)
        UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
    }

    override func tearDownWithError() throws {
        SyncCoordinator.runtimeEnabledOverride = nil
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let previousSyncPreference {
            UserDefaults.standard.set(
                previousSyncPreference,
                forKey: SyncCoordinator.enabledDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncCoordinator.enabledDefaultsKey)
        }
        previousSyncPreference = nil
        if let previousWireKeyFingerprint {
            UserDefaults.standard.set(
                previousWireKeyFingerprint,
                forKey: Self.wireKeyFingerprintDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(
                forKey: Self.wireKeyFingerprintDefaultsKey)
        }
        previousWireKeyFingerprint = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testRequestSyncCompletesWithoutStartingAnythingWhenOptInIsOff() async {
        let environment = AppEnvironment()

        let result = await environment.syncCoordinator.requestSync(trigger: .manual)

        XCTAssertEqual(result, .notStarted(.off))
        XCTAssertNil(environment.syncCoordinator.engine)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
    }

    func testFireAndForgetRequestReportsThatOptInIsOff() {
        let environment = AppEnvironment()

        let disposition = environment.syncCoordinator.syncNow(trigger: .manual)

        XCTAssertEqual(disposition, .notStarted(.off))
        XCTAssertNil(environment.syncCoordinator.engine)
    }

    func testRuntimeSyncOverrideDoesNotChangePersistentPreference() {
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        SyncCoordinator.runtimeEnabledOverride = false
        let environment = AppEnvironment()

        environment.syncCoordinator.setEnabled(false)

        XCTAssertFalse(SyncCoordinator.isEnabled)
        XCTAssertEqual(SyncCoordinator.runtimeEnabledOverride, false)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SyncCoordinator.enabledDefaultsKey))
    }

    func testUnchangedForegroundReloadDoesNotPublishALibraryChange() {
        let environment = AppEnvironment()
        var changes: [SnippetStore.ChangeSource] = []
        environment.store.onChange = { changes.append($0) }

        environment.becameActive()

        XCTAssertTrue(changes.isEmpty)
        XCTAssertNil(environment.syncCoordinator.engine)
    }

    func testChangedForegroundVaultStatePublishesExactlyOneLibraryChange() throws {
        let environment = AppEnvironment()
        var changes: [SnippetStore.ChangeSource] = []
        environment.store.onChange = { changes.append($0) }
        try FileManager.default.createDirectory(
            at: SnippetStorageLocations.vaultFolderURL,
            withIntermediateDirectories: true)
        try Data("not a vault".utf8).write(to: SnippetStorageLocations.vaultFileURL)

        environment.becameActive()

        XCTAssertEqual(changes.count, 1)
        if let onlyChange = changes.first, case .external = onlyChange {
            // Expected.
        } else {
            XCTFail("A changed foreground vault should publish one external change")
        }
        XCTAssertTrue(environment.secureStore.isUnreadable)
        XCTAssertNil(environment.syncCoordinator.engine)
    }

    func testRoundRequestsCoalesceIntoOneReplay() {
        var coalescer = SyncRoundRequestCoalescer()

        coalescer.requestReplay()
        coalescer.requestReplay()
        coalescer.requestReplay()

        XCTAssertTrue(coalescer.finishRound(generation: 7, currentGeneration: 7))
        XCTAssertFalse(coalescer.finishRound(generation: 7, currentGeneration: 7))
    }

    func testOldGenerationDrainingRequestsOneReplay() {
        var coalescer = SyncRoundRequestCoalescer()

        XCTAssertTrue(coalescer.finishRound(generation: 7, currentGeneration: 8))
        XCTAssertFalse(coalescer.finishRound(generation: 8, currentGeneration: 8))
    }

    func testLibraryChangeDebouncerCollapsesABurstIntoOneAction() async throws {
        var fireCount = 0
        let fired = expectation(description: "debounced action")
        let debouncer = SyncTriggerDebouncer(delay: 0.02) {
            fireCount += 1
            fired.fulfill()
        }

        debouncer.request()
        debouncer.request()
        debouncer.request()

        XCTAssertTrue(debouncer.isPending)
        await fulfillment(of: [fired], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fireCount, 1)
        XCTAssertFalse(debouncer.isPending)
    }

    func testStoreChangesUseDebounceButRemoteSyncWritesDoNot() {
        SyncCoordinator.runtimeEnabledOverride = true
        let environment = AppEnvironment()

        XCTAssertTrue(environment.store.syncDelegate === environment.syncCoordinator)
        environment.store.coordinatedReloadDidFinish(.remoteSync)
        XCTAssertFalse(environment.syncCoordinator.hasPendingLibraryChangeSync)

        _ = environment.store.addSnippet(name: "From CLI", content: "one")
        _ = environment.store.addSnippet(name: "From CLI", content: "two")
        XCTAssertTrue(environment.syncCoordinator.hasPendingLibraryChangeSync)

        environment.syncCoordinator.stop()
        XCTAssertFalse(environment.syncCoordinator.hasPendingLibraryChangeSync)
    }

    func testTransportRekeyRefusesMissingBaseWhenJournalExists() throws {
        SnippetStorageLocations.createAllDirectories()
        try SyncJournalFile.write(SyncJournal())
        let journalBytes = try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(
            "stale-fingerprint", forKey: Self.wireKeyFingerprintDefaultsKey)
        let transport = SyncLifecycleTransport()
        let coordinator = makeCoordinatorForRekeyTests(transport: transport)
        defer { coordinator.setEnabled(false) }

        coordinator.start()

        XCTAssertNil(coordinator.engine,
                     "rekey must fail before constructing a transport over missing confirmation")
        guard case .cannotStart(let detail) = coordinator.readiness else {
            XCTFail("missing base plus existing journal must be a start prerequisite failure")
            return
        }
        XCTAssertTrue(detail.contains("confirmed sync state is missing"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL),
            journalBytes)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Self.wireKeyFingerprintDefaultsKey),
            "stale-fingerprint",
            "failed rekey must remain retryable instead of recording completion")
    }

    func testTransportRekeyRefusesMarkedBaseWhenJournalIsMissing() throws {
        SnippetStorageLocations.createAllDirectories()
        try SyncBaseFile.write(SyncBase(journalEstablished: true))
        let baseBytes = try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(
            "stale-fingerprint", forKey: Self.wireKeyFingerprintDefaultsKey)
        let transport = SyncLifecycleTransport()
        let coordinator = makeCoordinatorForRekeyTests(transport: transport)
        defer { coordinator.setEnabled(false) }

        coordinator.start()

        XCTAssertNil(coordinator.engine)
        guard case .cannotStart(let detail) = coordinator.readiness else {
            XCTFail("marked base plus missing journal must prevent rekey startup")
            return
        }
        XCTAssertTrue(detail.contains("pending sync state is missing"))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            baseBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Self.wireKeyFingerprintDefaultsKey),
            "stale-fingerprint")
    }

    func testFreshTransportRekeyDoesNotManufactureProtocolFiles() {
        SnippetStorageLocations.createAllDirectories()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(
            "stale-fingerprint", forKey: Self.wireKeyFingerprintDefaultsKey)
        let transport = SyncLifecycleTransport()
        let coordinator = makeCoordinatorForRekeyTests(transport: transport)

        // This method is intentionally synchronous. The startup round is enqueued on
        // MainActor but cannot run until this test yields, so these assertions isolate
        // the rekey migration itself; stop then cancels that not-yet-started round.
        coordinator.start()
        XCTAssertNotNil(coordinator.engine)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
        XCTAssertNotEqual(
            UserDefaults.standard.string(forKey: Self.wireKeyFingerprintDefaultsKey),
            "stale-fingerprint")
        XCTAssertEqual(transport.fetchAttempts, 0)
        XCTAssertEqual(transport.submitAttempts, 0)
        coordinator.setEnabled(false)
    }

    func testTransportRekeyRetainsPerRecordVersionsForOrdinaryAndSecureOffers() throws {
        SnippetStorageLocations.createAllDirectories()
        let ordinaryID = UUID(uuidString: "56565656-5656-4656-8656-565656565656")!
        let secureID = UUID(uuidString: "78787878-7878-4878-8878-787878787878")!
        func envelope(_ id: UUID, secure: Bool) -> SyncEnvelope {
            SyncEnvelope(
                id: id,
                hlc: HLC(wallMs: secure ? 200 : 100, counter: 0, device: "aaaaaaa1"),
                origin: "aaaaaaa1",
                secure: secure,
                deleted: false,
                fields: SyncEnvelope.Fields(
                    name: secure ? "Secure" : "Ordinary",
                    keyword: secure ? "secure" : "ordinary",
                    content: Data((secure ? "sealed secure" : "ordinary body").utf8),
                    tags: [],
                    isEnabled: true,
                    isPinned: false,
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: 2)),
                x: secure ? [
                    SyncEnvelope.vaultKeyIDExtensionKey: .string("test-vault"),
                ] : [:])
        }
        let ordinary = envelope(ordinaryID, secure: false)
        let secure = envelope(secureID, secure: true)
        let ordinaryVersion = SyncRecordVersion(Data("ordinary-system-fields".utf8))
        let secureVersion = SyncRecordVersion(Data("secure-system-fields".utf8))
        var confirmed = SyncBase(
            cursor: SyncCursor("rekey-cursor"), journalEstablished: true)
        confirmed.recordConfirmed(ordinary, recordVersion: ordinaryVersion)
        confirmed.recordConfirmed(secure, recordVersion: secureVersion)
        try SyncBaseFile.write(confirmed)
        try SyncJournalFile.write(SyncJournal())
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(
            "stale-fingerprint", forKey: Self.wireKeyFingerprintDefaultsKey)
        let transport = SyncLifecycleTransport()
        let coordinator = makeCoordinatorForRekeyTests(transport: transport)
        defer { coordinator.setEnabled(false) }

        // `start()` performs the migration synchronously and only schedules the startup
        // round. These assertions therefore observe the crash-safe rekey checkpoint,
        // before the inert transport can run.
        coordinator.start()

        guard case .loaded(let reset) = SyncBaseFile.load() else {
            return XCTFail("rekey must leave a readable base")
        }
        XCTAssertTrue(reset.envelopes.isEmpty,
                      "payload ancestry is staged into the journal for resealing")
        XCTAssertEqual(reset.cursor, confirmed.cursor)
        XCTAssertEqual(reset.recordVersion(ordinaryID), ordinaryVersion)
        XCTAssertEqual(reset.recordVersion(secureID), secureVersion)

        guard case .loaded(let journal) = SyncJournalFile.load() else {
            return XCTFail("rekey must leave a readable journal")
        }
        XCTAssertEqual(journal.entry(ordinaryID)?.offered?.envelope, ordinary)
        XCTAssertEqual(journal.entry(secureID)?.offered?.envelope, secure)
        XCTAssertEqual(
            journal.entry(ordinaryID)?.offered?.recordVersion, ordinaryVersion)
        XCTAssertEqual(
            journal.entry(secureID)?.offered?.recordVersion, secureVersion)
        XCTAssertEqual(transport.fetchAttempts, 0)
        XCTAssertEqual(transport.submitAttempts, 0)
    }

    private func makeCoordinatorForRekeyTests(
        transport: SyncLifecycleTransport = SyncLifecycleTransport()
    ) -> SyncCoordinator {
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.sync-lifecycle-tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        return SyncCoordinator(
            library: EmptySyncLibrary(),
            keys: SyncKeyStore(keychain: keychain),
            device: "aaaaaaa1",
            transportFactory: { transport })
    }
}

@MainActor
private final class EmptySyncLibrary: SyncLibraryAccess {
    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] { [:] }

    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
        RemoteClassification(
            applicable: envelopes, deferredIDs: [], incompatibleVaultIDs: [])
    }

    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome {
        ApplyOutcome(changedIDs: envelopes.map(\.id))
    }

    func liveIDs() -> Set<UUID> { [] }
}

/// A deliberately inert transport for coordinator lifecycle tests. It proves the
/// transport factory seam is used without asking CloudKit to validate entitlements in
/// an unsigned simulator test process. Any accidentally scheduled call fails before it
/// can advance protocol files, and the counters keep the synchronous rekey assertion
/// honest.
nonisolated final class SyncLifecycleTransport: SyncTransport, @unchecked Sendable {
    let identifier = "lifecycle-test"
    let supportsPush = true
    let pollInterval: TimeInterval = 3_600
    let events = AsyncStream<SyncTransportEvent> { _ in }

    private let lock = NSLock()
    private var fetchAttemptCount = 0
    private var submitAttemptCount = 0

    var fetchAttempts: Int { lock.withLock { fetchAttemptCount } }
    var submitAttempts: Int { lock.withLock { submitAttemptCount } }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        lock.withLock { fetchAttemptCount += 1 }
        throw SyncTransportFailure.unreachable(detail: "lifecycle test transport is inert")
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        lock.withLock { submitAttemptCount += 1 }
        throw SyncTransportFailure.unreachable(detail: "lifecycle test transport is inert")
    }
}
