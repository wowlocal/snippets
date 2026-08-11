import Darwin
import XCTest
@testable import Snippets

@MainActor
final class SyncLifecycleTests: XCTestCase {
    private var rootURL: URL!
    private var previousSyncPreference: Any?

    override func setUpWithError() throws {
        SyncCoordinator.runtimeEnabledOverride = nil
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey)
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
}
