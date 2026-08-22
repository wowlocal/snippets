import Darwin
import CryptoKit
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

    func testProviderSwitchReceiptResumesCommittedTargetAndRetiresOnlyAfterVerification() throws {
        SnippetStorageLocations.createAllDirectories()
        let defaultsName = "SyncLifecycleTests.provider-switch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: SyncBackendSelectionStore.legacyICloudEnabledDefaultsKey)
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.provider-switch-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            serverInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
            accessToken: "test-access-token")
        let http = try selection.protocolLocations()
        try selection.selectICloud()

        let prepared = try selection.prepareProviderSwitch(to: .snippetsCloud)
        XCTAssertEqual(prepared.phase, .prepared)
        XCTAssertEqual(selection.provider, .iCloud)
        try selection.commitPreparedProviderSwitch(prepared)

        XCTAssertEqual(selection.provider, .snippetsCloud)
        XCTAssertFalse(defaults.bool(
            forKey: SyncBackendSelectionStore.legacyICloudEnabledDefaultsKey))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncProviderSwitchFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: http.switchReceiptURL.path))

        let resumed = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        XCTAssertEqual(resumed.provider, .snippetsCloud)
        XCTAssertEqual(resumed.interruptedProviderSwitch?.phase, .targetSelected)
        try resumed.completeProviderSwitch()
        XCTAssertNil(resumed.interruptedProviderSwitch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: http.switchReceiptURL.path))
    }

    func testCrashBeforeProviderCommitKeepsSourceAndDiscardsPreparedReceipt() throws {
        SnippetStorageLocations.createAllDirectories()
        let defaultsName = "SyncLifecycleTests.provider-switch-prepared.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.provider-switch-prepared-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(),
            serverInstanceID: UUID(),
            accessToken: "test-access-token")
        try selection.selectICloud()
        _ = try selection.prepareProviderSwitch(to: .snippetsCloud)

        let resumed = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        XCTAssertEqual(resumed.provider, .iCloud)
        XCTAssertNil(resumed.interruptedProviderSwitch)
        XCTAssertTrue(defaults.bool(
            forKey: SyncBackendSelectionStore.legacyICloudEnabledDefaultsKey) == resumed.syncEnabled)
    }

    func testUnreadableSwitchReceiptDisablesLegacyICloudDowngradePath() throws {
        SnippetStorageLocations.createAllDirectories()
        let defaultsName = "SyncLifecycleTests.provider-switch-unreadable.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: SyncBackendSelectionStore.legacyICloudEnabledDefaultsKey)
        try Data("{not-a-switch-receipt".utf8).write(
            to: SnippetStorageLocations.syncProviderSwitchFileURL,
            options: .atomic)
        defer {
            try? FileManager.default.removeItem(
                at: SnippetStorageLocations.syncProviderSwitchFileURL)
        }

        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: KeychainSecretStore(
                tier: .deviceOnly,
                service: "com.khm.snippets.provider-switch-unreadable-tests",
                itemAccessibility: .afterFirstUnlock,
                inMemory: true),
            snippetsCloudEnabled: true)

        guard case .some(.switchStateUnreadable) = selection.providerSelectionFailure else {
            return XCTFail("Expected unreadable switch state to fail closed")
        }
        XCTAssertFalse(defaults.bool(
            forKey: SyncBackendSelectionStore.legacyICloudEnabledDefaultsKey),
            "an older build must stay local-only when the active switch cannot be proven")
        XCTAssertThrowsError(try selection.makeTransport())
    }

    func testLocalLibraryReviewWorksWhileSyncIsOffWithoutInitializingSync() throws {
        SnippetStorageLocations.createAllDirectories()
        try Data("{not-a-library".utf8).write(
            to: SnippetStorageLocations.snippetsFileURL,
            options: .atomic)
        let store = SnippetStore(
            configuration: .iOS,
            persistenceWorker: SnippetPersistenceWorker(),
            persistDelay: 0,
            persistenceRetryBaseDelay: 0)
        XCTAssertTrue(store.isLibraryQuarantined)
        XCTAssertTrue(LibraryQuarantineMarker.exists())

        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.local-recovery-tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        let session = VaultSession(keychain: keychain)
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: keychain,
            deviceID: store.deviceID)
        let library = SnippetLibraryBridge(store: store, secureStore: secureStore)
        var transportFactoryCalls = 0
        let coordinator = SyncCoordinator(
            library: library,
            keys: SyncKeyStore(keychain: keychain),
            device: store.deviceID,
            transportFactory: {
                transportFactoryCalls += 1
                return SyncLifecycleTransport()
            })

        XCTAssertFalse(SyncCoordinator.isEnabled)
        XCTAssertNil(coordinator.engine)
        XCTAssertEqual(coordinator.recoveryAction, .checkAgain)
        guard case .halted(.localLibraryQuarantined, _) = coordinator.state else {
            return XCTFail("local recovery must remain visible while cloud sync is off")
        }

        let recovered = Snippet(
            name: "Recovered",
            keyword: "recovered",
            content: "kept",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000))
        let importURL = rootURL.appendingPathComponent("recovered-library.json")
        try SnippetLibraryCodec.encode([recovered]).write(to: importURL, options: .atomic)
        let prepared = try store.prepareImport(from: importURL)
        XCTAssertEqual(try store.quarantinedLibraryRecoveryCandidateCount(prepared), 1)
        XCTAssertEqual(try store.replaceQuarantinedLibrary(with: prepared), 1)

        coordinator.performRecovery(.checkAgain)

        XCTAssertNil(coordinator.engine)
        XCTAssertNil(coordinator.recoveryAction)
        XCTAssertEqual(coordinator.state, .disabled)
        XCTAssertEqual(transportFactoryCalls, 0)
        XCTAssertFalse(LibraryQuarantineMarker.exists())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
        guard case .loaded(let reviewedState) = SyncStateFile.load() else {
            return XCTFail("review must durably clear the local-library halt")
        }
        XCTAssertNil(reviewedState.halt)
        XCTAssertNoThrow(try store.addSnippet(name: "Editable after review"))
    }

    func testBridgeProjectsAReviewedCandidateWithoutUnlockingItBeforeTheFence() throws {
        SnippetStorageLocations.createAllDirectories()
        let recovered = Snippet(
            name: "Recovered",
            keyword: "recovered",
            content: "kept",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000))
        try SnippetLibraryCodec.encode([recovered]).write(
            to: SnippetStorageLocations.snippetsFileURL,
            options: .atomic)
        try LibraryQuarantineMarker.write()
        let store = SnippetStore(
            configuration: .iOS,
            persistenceWorker: SnippetPersistenceWorker(),
            persistDelay: 0,
            persistenceRetryBaseDelay: 0)
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.bridge-recovery-tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        let secureStore = SecureSnippetStore(
            session: VaultSession(keychain: keychain),
            keychain: keychain,
            deviceID: store.deviceID)
        let bridge = SnippetLibraryBridge(store: store, secureStore: secureStore)

        let projected = try bridge.reviewRecoveredLibrary(agreedBase: SyncBase())

        XCTAssertNotNil(projected[recovered.id])
        XCTAssertTrue(store.isLibraryQuarantined)
        XCTAssertThrowsError(try store.addSnippet(name: "Still fenced"))
        XCTAssertThrowsError(try bridge.finalizeRecoveredLibraryReview(),
                             "finalize must follow marker retirement")
        try LibraryQuarantineMarker.removeDurably()
        XCTAssertNoThrow(try bridge.finalizeRecoveredLibraryReview())
        XCTAssertNoThrow(try store.addSnippet(name: "Editable after fence"))
    }

    func testAppEnvironmentStartIsIdempotentAndPublishesInitialLibraryOnce() {
        let environment = AppEnvironment()
        var initialExternalNotifications = 0
        environment.store.onChange = { change in
            if case .external = change.source { initialExternalNotifications += 1 }
        }

        environment.start()
        environment.start()

        XCTAssertEqual(initialExternalNotifications, 1)
        XCTAssertNil(environment.syncCoordinator.engine,
                     "an idempotent process start must still respect sync opt-in")
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
        environment.store.onChange = { changes.append($0.source) }

        environment.becameActive()

        XCTAssertTrue(changes.isEmpty)
        XCTAssertNil(environment.syncCoordinator.engine)
    }

    func testChangedForegroundVaultStatePublishesExactlyOneLibraryChange() throws {
        let environment = AppEnvironment()
        var changes: [SnippetStore.ChangeSource] = []
        environment.store.onChange = { changes.append($0.source) }
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

    func testOfflineRetrySchedulerUsesExactDeadlineAndCoalescesSameState() {
        let now = Date(timeIntervalSince1970: 10_000)
        let deadline = now.addingTimeInterval(2)
        let harness = OfflineRetryArmHarness()
        let scheduler = SyncOfflineRetryScheduler(
            now: { now },
            arm: harness.arm)
        var fireCount = 0

        scheduler.update(for: .offline(retryAfter: deadline)) { fireCount += 1 }
        scheduler.update(for: .offline(retryAfter: deadline)) { fireCount += 1 }

        XCTAssertEqual(harness.delays, [2],
                       "the first Core backoff must not wait for the six-hour health poll")
        XCTAssertEqual(scheduler.scheduledDeadline, deadline)
        XCTAssertEqual(harness.cancelCount, 0,
                       "publishing the same offline state must retain the one-shot")

        harness.fire(0)
        harness.fire(0)

        XCTAssertEqual(fireCount, 1)
        XCTAssertNil(scheduler.scheduledDeadline)
    }

    func testOfflineRetrySchedulerReplacementCancelsAndStaleCallbackCannotFire() {
        let now = Date(timeIntervalSince1970: 20_000)
        let firstDeadline = now.addingTimeInterval(2)
        let replacementDeadline = now.addingTimeInterval(4)
        let harness = OfflineRetryArmHarness()
        let scheduler = SyncOfflineRetryScheduler(
            now: { now },
            arm: harness.arm)
        var fired: [String] = []

        scheduler.update(for: .offline(retryAfter: firstDeadline)) {
            fired.append("stale")
        }
        scheduler.update(for: .offline(retryAfter: replacementDeadline)) {
            fired.append("replacement")
        }

        XCTAssertEqual(harness.delays, [2, 4])
        XCTAssertEqual(harness.cancelCount, 1)
        XCTAssertEqual(scheduler.scheduledDeadline, replacementDeadline)
        harness.fire(0, evenIfCancelled: true)
        XCTAssertTrue(fired.isEmpty,
                      "a callback already queued by a replaced timer must be generation-gated")

        harness.fire(1)
        harness.fire(1)
        XCTAssertEqual(fired, ["replacement"])
        XCTAssertNil(scheduler.scheduledDeadline)
    }

    func testOfflineRetrySchedulerCancelsForEveryNonOfflineTerminalOrHealthyState() {
        let now = Date(timeIntervalSince1970: 30_000)
        let nonOfflineStates: [SyncEngine.State] = [
            .idle(lastSync: now),
            .syncing,
            .needsAuthentication("review"),
            .needsAttention("repair backend"),
            .waitingForVault("unlock"),
            .halted(.accountChanged, detail: "review"),
            .disabled,
        ]

        for (index, state) in nonOfflineStates.enumerated() {
            let harness = OfflineRetryArmHarness()
            let scheduler = SyncOfflineRetryScheduler(
                now: { now },
                arm: harness.arm)
            var fireCount = 0
            scheduler.update(
                for: .offline(retryAfter: now.addingTimeInterval(3))) {
                    fireCount += 1
                }

            scheduler.update(for: state) { fireCount += 1 }
            harness.fire(0, evenIfCancelled: true)

            XCTAssertNil(scheduler.scheduledDeadline, "state index \(index)")
            XCTAssertEqual(harness.cancelCount, 1, "state index \(index)")
            XCTAssertEqual(fireCount, 0, "state index \(index)")
        }
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
        let changedID = UUID()
        var publishedChange: SnippetStore.Change?
        environment.store.onChange = { publishedChange = $0 }

        XCTAssertTrue(environment.store.syncDelegate === environment.syncCoordinator)
        environment.store.coordinatedReloadDidFinish(
            .remoteSync,
            changedIDs: [changedID])
        XCTAssertFalse(environment.syncCoordinator.hasPendingLibraryChangeSync)
        XCTAssertEqual(publishedChange?.source, .remoteSync)
        XCTAssertEqual(publishedChange?.changedIDs, [changedID])

        _ = try! environment.store.addSnippet(name: "From CLI", content: "one")
        _ = try! environment.store.addSnippet(name: "From CLI", content: "two")
        XCTAssertTrue(environment.syncCoordinator.hasPendingLibraryChangeSync)

        environment.syncCoordinator.stop()
        XCTAssertFalse(environment.syncCoordinator.hasPendingLibraryChangeSync)
    }

    func testManualSyncBypassesBackoffWhileAutomaticRequestWaits() async {
        SnippetStorageLocations.createAllDirectories()
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        let transport = SyncLifecycleTransport()
        let coordinator = makeCoordinatorForRekeyTests(transport: transport)
        defer { coordinator.setEnabled(false) }

        let initial = await coordinator.requestSync(trigger: .manual)
        guard case .completed(.offline) = initial else {
            return XCTFail("the inert transport should establish backoff, got \(initial)")
        }
        XCTAssertEqual(transport.fetchAttempts, 1)

        let automatic = await coordinator.requestSync(trigger: .poll)
        guard case .completed(.offline) = automatic else {
            return XCTFail("an automatic request should remain in backoff, got \(automatic)")
        }
        XCTAssertEqual(
            transport.fetchAttempts,
            1,
            "automatic scheduling must honor the current retry deadline")

        let manual = await coordinator.requestSync(trigger: .manual)
        guard case .completed(.offline) = manual else {
            return XCTFail("the forced attempt should establish new backoff, got \(manual)")
        }
        XCTAssertEqual(
            transport.fetchAttempts,
            2,
            "Sync Now must make exactly one immediate attempt despite existing backoff")
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
        XCTAssertEqual(detail, "The local sync checkpoint could not be read.")
        XCTAssertEqual(coordinator.recoveryAction, .repairCheckpoint)
        guard case .halted(.checkpointUnreadable, _) = coordinator.state else {
            return XCTFail("the closed startup copy must retain the typed repair state")
        }
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
        XCTAssertEqual(detail, "The local sync checkpoint could not be read.")
        XCTAssertEqual(coordinator.recoveryAction, .repairCheckpoint)
        guard case .halted(.checkpointUnreadable, _) = coordinator.state else {
            return XCTFail("the closed startup copy must retain the typed repair state")
        }
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            baseBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Self.wireKeyFingerprintDefaultsKey),
            "stale-fingerprint")
    }

    func testStartupCheckpointRepairIsCrashSafeAtEveryCommitBoundary() throws {
        enum Damage: CaseIterable {
            case missingJournal
            case unreadableJournal
            case unreadableBase
        }
        struct InjectedCrash: Error {}

        let localID = UUID(uuidString: "31000000-0000-4000-8000-000000000001")!
        let oldRemoteID = UUID(uuidString: "31000000-0000-4000-8000-000000000002")!
        func envelope(_ id: UUID, name: String) -> SyncEnvelope {
            SyncEnvelope(
                id: id,
                hlc: HLC(wallMs: 1_000, counter: 0, device: "aaaaaaa1"),
                origin: "aaaaaaa1",
                secure: false,
                deleted: false,
                fields: SyncEnvelope.Fields(
                    name: name,
                    keyword: name,
                    content: Data(name.utf8),
                    tags: [],
                    isEnabled: true,
                    isPinned: false,
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: 2)))
        }
        let local = envelope(localID, name: "local-survivor")
        let oldRemote = envelope(oldRemoteID, name: "old-remote-ancestor")
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)

        for damage in Damage.allCases {
            for boundary in SyncCoordinator.ProtocolRepairBoundary.allCases {
                try? FileManager.default.removeItem(at: SnippetStorageLocations.syncFolderURL)
                SnippetStorageLocations.createAllDirectories()
                var oldBase = SyncBase(journalEstablished: true)
                oldBase.record(local)
                oldBase.record(oldRemote)
                switch damage {
                case .missingJournal:
                    try SyncBaseFile.write(oldBase)
                case .unreadableJournal:
                    try SyncBaseFile.write(oldBase)
                    try Data("{not-a-journal".utf8).write(
                        to: SnippetStorageLocations.syncJournalFileURL,
                        options: .atomic)
                case .unreadableBase:
                    try Data("{not-a-base".utf8).write(
                        to: SnippetStorageLocations.syncBaseFileURL,
                        options: .atomic)
                    try SyncJournalFile.write(SyncJournal())
                }

                let keychain = KeychainSecretStore(
                    tier: .deviceOnly,
                    service: "com.khm.snippets.protocol-repair-tests."
                        + UUID().uuidString.lowercased(),
                    inMemory: true)
                var transportFactoryCalls = 0
                let coordinator = SyncCoordinator(
                    library: SnapshotSyncLibrary([local]),
                    keys: SyncKeyStore(keychain: keychain),
                    device: "aaaaaaa1",
                    transportFactory: {
                        transportFactoryCalls += 1
                        return SyncLifecycleTransport()
                    })
                coordinator.start()
                XCTAssertEqual(coordinator.recoveryAction, .repairCheckpoint)
                XCTAssertEqual(transportFactoryCalls, 0)
                coordinator.protocolRepairBoundaryHook = { observed in
                    if observed == boundary { throw InjectedCrash() }
                }

                coordinator.performRecovery(.repairCheckpoint)

                guard case .loaded(let fencedBase) = SyncBaseFile.load() else {
                    return XCTFail("Repair must commit a readable base before \(boundary)")
                }
                XCTAssertTrue(
                    fencedBase.requiresNonDestructiveLibraryMerge,
                    "\(damage) at \(boundary) must never expose the old deletion ancestor")
                XCTAssertEqual(fencedBase.envelope(localID), local)
                XCTAssertEqual(
                    fencedBase.nonDestructiveMergeMode,
                    .reviewedLocalSnapshot,
                    "Repair must retain the exact reviewed primary as a deletion witness")
                XCTAssertEqual(coordinator.recoveryAction, .repairCheckpoint)
                XCTAssertEqual(transportFactoryCalls, 0)

                if boundary == .journalCommitted {
                    guard case .loaded(let repairedJournal) = SyncJournalFile.load() else {
                        return XCTFail("the second boundary must leave a readable journal")
                    }
                    XCTAssertEqual(repairedJournal.entry(localID)?.desired, local)
                    let reconstructedOldDeletion = repairedJournal.entries.values.contains {
                        $0.desired.id == oldRemoteID && $0.desired.deleted
                    }
                    switch damage {
                    case .missingJournal, .unreadableJournal:
                        XCTAssertTrue(
                            reconstructedOldDeletion,
                            "a readable confirmed ancestor proves the pre-Repair deletion")
                    case .unreadableBase:
                        XCTAssertFalse(
                            reconstructedOldDeletion,
                            "an unreadable ancestor cannot authorize a deletion")
                    }
                }
                coordinator.stop()
            }
        }
    }

    func testRepeatedRepairAfterBaseCommitKeepsFirstReviewAndPostReviewDelete() async throws {
        struct InjectedCrash: Error {}

        SnippetStorageLocations.createAllDirectories()
        let id = UUID(uuidString: "31000000-0000-4000-8000-000000000003")!
        let local = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 1_000, counter: 0, device: "aaaaaaa1"),
            origin: "aaaaaaa1",
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "delete after interrupted Repair",
                keyword: "repair-crash-delete",
                content: Data("must stay deleted".utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)))
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.repeated-repair-tests."
                + UUID().uuidString.lowercased(),
            inMemory: true)
        let keys = SyncKeyStore(keychain: keychain)
        let material = try keys.materialMintingIfNeeded()
        let sealer = SnippetCryptoSealer(
            keyring: try SyncKeyStore.keyring(from: material), scopeID: keys.scopeID)
        let transport = RekeyRecoveryTransport(records: [
            try WireCodec.seal(local, using: sealer),
        ])
        let remote = try XCTUnwrap(transport.snapshot.first)
        var damagedBase = SyncBase(
            cursor: transport.currentCursor,
            journalEstablished: true)
        damagedBase.recordConfirmed(
            local, recordVersion: remote.recordVersion)
        try SyncBaseFile.write(damagedBase)
        // Missing journal is the damage which makes Repair available.
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(
            SHA256.hash(data: material).prefix(8)
                .map { String(format: "%02x", $0) }.joined(),
            forKey: Self.wireKeyFingerprintDefaultsKey)
        let library = SnapshotSyncLibrary([local])

        let interrupted = SyncCoordinator(
            library: library,
            keys: keys,
            device: "aaaaaaa1",
            transportFactory: { transport })
        interrupted.start()
        XCTAssertEqual(interrupted.recoveryAction, .repairCheckpoint)
        interrupted.protocolRepairBoundaryHook = { boundary in
            if boundary == .baseCommitted { throw InjectedCrash() }
        }
        interrupted.performRecovery(.repairCheckpoint)
        guard case .loaded(let firstReview) = SyncBaseFile.load(),
              let firstReviewID = firstReview.nonDestructiveReviewID else {
            return XCTFail("the interrupted Repair must leave its first review fence")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
        interrupted.stop()

        // Checkpoint damage freezes sync, not the primary editor. This deletion is
        // intentionally after R1 and before the user retries Repair.
        library.remove(id)
        let retry = SyncCoordinator(
            library: library,
            keys: keys,
            device: "aaaaaaa1",
            transportFactory: { transport })
        defer { retry.setEnabled(false) }
        retry.start()
        XCTAssertEqual(retry.recoveryAction, .repairCheckpoint)
        retry.performRecovery(.repairCheckpoint)

        guard case .loaded(let retriedBase) = SyncBaseFile.load(),
              case .loaded(let retriedJournal) = SyncJournalFile.load() else {
            return XCTFail("the repeated Repair must commit a readable protocol pair")
        }
        XCTAssertEqual(retriedBase.nonDestructiveReviewID, firstReviewID)
        XCTAssertTrue(retriedJournal.entry(id)?.desired.deleted == true,
                      "the deletion after R1 must become durable outbound intent")

        _ = await retry.requestSync(trigger: .manual)
        let didSubmit = await eventually { !transport.submittedBatches.isEmpty }
        XCTAssertTrue(didSubmit)
        let submitted = try transport.submittedBatches.flatMap { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertTrue(submitted.contains { $0.id == id && $0.deleted })
        XCTAssertNil(library.envelope(id),
                     "the old remote live row must not resurrect after full recovery")
    }

    func testStartupCheckpointRepairPreservesDeletionBeforeItsFirstRound() async throws {
        SnippetStorageLocations.createAllDirectories()
        let id = UUID(uuidString: "31111111-1111-4111-8111-111111111111")!
        let local = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 1_000, counter: 0, device: "aaaaaaa1"),
            origin: "aaaaaaa1",
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "delete after repair",
                keyword: "delete-after-repair",
                content: Data("must stay deleted".utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)))
        var damagedPairBase = SyncBase(journalEstablished: true)
        damagedPairBase.record(local)
        try SyncBaseFile.write(damagedPairBase)

        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.protocol-repair-delete-tests."
                + UUID().uuidString.lowercased(),
            inMemory: true)
        let keys = SyncKeyStore(keychain: keychain)
        let material = try keys.materialMintingIfNeeded()
        UserDefaults.standard.set(
            SHA256.hash(data: material).prefix(8)
                .map { String(format: "%02x", $0) }.joined(),
            forKey: Self.wireKeyFingerprintDefaultsKey)
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        let library = SnapshotSyncLibrary([local])
        let transport = SyncLifecycleTransport()
        let coordinator = SyncCoordinator(
            library: library,
            keys: keys,
            device: "aaaaaaa1",
            transportFactory: { transport })
        defer { coordinator.setEnabled(false) }

        coordinator.start()
        XCTAssertEqual(coordinator.recoveryAction, .repairCheckpoint)
        coordinator.performRecovery(.repairCheckpoint)
        // `start()` queues its first round on MainActor. This mutation is deliberately
        // made before yielding, which is the smallest Repair -> edit race window.
        library.remove(id)

        let submittedDeletion = await eventually {
            transport.submitAttempts > 0 || transport.fetchAttempts > 0
        }
        XCTAssertTrue(submittedDeletion)
        XCTAssertEqual(transport.submitAttempts, 1)
        guard case .loaded(let journal) = SyncJournalFile.load() else {
            return XCTFail("the post-Repair deletion must be durable")
        }
        XCTAssertTrue(journal.entry(id)?.desired.deleted == true)
    }

    func testCheckpointRepairReconstructsDeletionAlreadyPresentAtReview() throws {
        SnippetStorageLocations.createAllDirectories()
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        let id = UUID(uuidString: "31111111-1111-4111-8111-111111111112")!
        let confirmed = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 1_000, counter: 0, device: "aaaaaaa1"),
            origin: "aaaaaaa1",
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "deleted before Repair",
                keyword: "deleted-before-repair",
                content: Data("must remain deleted".utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)))
        try SyncBaseFile.write(SyncBase(
            envelopes: [SyncBase.key(id): confirmed],
            journalEstablished: true))

        let coordinator = SyncCoordinator(
            library: SnapshotSyncLibrary([]),
            keys: SyncKeyStore(keychain: KeychainSecretStore(
                tier: .deviceOnly,
                service: "com.khm.snippets.pre-repair-delete-tests."
                    + UUID().uuidString.lowercased(),
                inMemory: true)),
            device: "aaaaaaa1",
            transportFactory: { SyncLifecycleTransport() })
        defer { coordinator.stop() }

        coordinator.start()
        XCTAssertEqual(coordinator.recoveryAction, .repairCheckpoint)
        coordinator.performRecovery(.repairCheckpoint)

        guard case .loaded(let repairedBase) = SyncBaseFile.load(),
              case .loaded(let repairedJournal) = SyncJournalFile.load(),
              let entry = repairedJournal.entry(id) else {
            return XCTFail("Repair must durably reconstruct the reviewed deletion")
        }
        XCTAssertEqual(repairedBase.preRecoveryConfirmedEnvelopes?[SyncBase.key(id)], confirmed)
        XCTAssertTrue(entry.desired.deleted)
        XCTAssertTrue(entry.reviewedLocalSnapshotKnown)
        XCTAssertNil(entry.reviewedLocalAncestor)
        XCTAssertEqual(entry.preReviewMergeAncestor, confirmed)
    }

    func testDeletionDuringAwaitedRecoveryResetUsesDurableExistenceFence() async throws {
        SnippetStorageLocations.createAllDirectories()
        let id = UUID(uuidString: "31222222-2222-4222-8222-222222222222")!
        let local = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 1_000, counter: 0, device: "aaaaaaa1"),
            origin: "aaaaaaa1",
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "delete during reset",
                keyword: "delete-during-reset",
                content: Data("must stay deleted".utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)))
        let recoveryBase = SyncBase(
            envelopes: [SyncBase.key(id): local],
            journalEstablished: true,
            requiresNonDestructiveLibraryMerge: true,
            nonDestructiveMergeMode: .reviewedLocalSnapshot)
        try SyncBaseFile.write(recoveryBase)
        try SyncJournalFile.write(SyncJournal())

        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.async-recovery-delete-tests."
                + UUID().uuidString.lowercased(),
            inMemory: true)
        let keys = SyncKeyStore(keychain: keychain)
        let material = try keys.materialMintingIfNeeded()
        UserDefaults.standard.set(
            SHA256.hash(data: material).prefix(8)
                .map { String(format: "%02x", $0) }.joined(),
            forKey: Self.wireKeyFingerprintDefaultsKey)
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        let library = SnapshotSyncLibrary([local])
        let transport = SyncLifecycleTransport(suspendsLocalFullResync: true)
        let coordinator = SyncCoordinator(
            library: library,
            keys: keys,
            device: "aaaaaaa1",
            transportFactory: { transport })
        defer {
            transport.releaseLocalFullResync()
            coordinator.setEnabled(false)
        }

        coordinator.start()
        let resetStarted = await eventually { transport.localFullResyncIsInFlight }
        XCTAssertTrue(resetStarted)
        guard case .loaded(let beforeAwait) = SyncJournalFile.load() else {
            return XCTFail("the recovery journal must precede the awaited reset")
        }
        XCTAssertTrue(beforeAwait.entry(id)?.reviewedLocalExistence == true)

        library.remove(id)
        transport.releaseLocalFullResync()

        let resumedAfterReset = await eventually {
            transport.submitAttempts > 0 || transport.fetchAttempts > 0
        }
        XCTAssertTrue(resumedAfterReset)
        XCTAssertEqual(transport.submitAttempts, 1)
        guard case .loaded(let afterAwait) = SyncJournalFile.load() else {
            return XCTFail("the deletion observed after reset must be durable")
        }
        XCTAssertTrue(afterAwait.entry(id)?.desired.deleted == true)
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

    func testTransportRekeyStartsAFreshTransportEpochForOrdinaryAndSecureOffers() async throws {
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
        let accountIdentity = SyncAccountIdentity(Data(repeating: 0x56, count: 32))
        let datasetIdentity = SyncDatasetIdentity(Data(repeating: 0x57, count: 32))
        var confirmed = SyncBase(
            cursor: SyncCursor("rekey-cursor"),
            journalEstablished: true,
            accountIdentity: accountIdentity,
            datasetIdentity: datasetIdentity)
        confirmed.recordConfirmed(ordinary, recordVersion: ordinaryVersion)
        confirmed.recordConfirmed(secure, recordVersion: secureVersion)
        try SyncBaseFile.write(confirmed)
        try SyncJournalFile.write(SyncJournal())
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(
            "stale-fingerprint", forKey: Self.wireKeyFingerprintDefaultsKey)
        let transport = SyncLifecycleTransport(
            accountIdentity: accountIdentity,
            datasetIdentity: datasetIdentity)
        let coordinator = makeCoordinatorForRekeyTests(
            transport: transport,
            liveEnvelopes: [ordinary, secure])
        defer { coordinator.setEnabled(false) }

        // `requestSync` owns the startup round completion. The transport reset is async;
        // waiting here is deliberate and must never be implemented by blocking MainActor.
        let result = await coordinator.requestSync(trigger: .manual)
        guard case .completed(.offline) = result else {
            return XCTFail("the inert post-reset transport should finish offline, got \(result)")
        }

        guard case .loaded(let reset) = SyncBaseFile.load() else {
            return XCTFail("rekey must leave a readable base")
        }
        XCTAssertTrue(reset.envelopes.isEmpty,
                      "payload ancestry is staged into the journal for resealing")
        XCTAssertNil(reset.cursor,
                     "K1 scheduler progress cannot be used in the fresh K2 epoch")
        XCTAssertEqual(reset.accountIdentity, accountIdentity,
                       "transport rekey must not detach CloudKit ancestry from its account")
        XCTAssertEqual(reset.datasetIdentity, datasetIdentity,
                       "transport rekey must retain the exact remote dataset fence")
        XCTAssertEqual(reset.recordVersion(ordinaryID), ordinaryVersion)
        XCTAssertEqual(reset.recordVersion(secureID), secureVersion)

        guard case .loaded(let journal) = SyncJournalFile.load() else {
            return XCTFail("rekey must leave a readable journal")
        }
        XCTAssertEqual(journal.entry(ordinaryID)?.offered?.envelope, ordinary)
        XCTAssertEqual(journal.entry(secureID)?.offered?.envelope, secure)
        XCTAssertEqual(journal.entry(ordinaryID)?.offered?.recordVersion, ordinaryVersion)
        XCTAssertEqual(journal.entry(secureID)?.offered?.recordVersion, secureVersion)
        XCTAssertEqual(transport.localFullResyncAttempts, 1)
        XCTAssertGreaterThanOrEqual(transport.submitAttempts, 1)
    }

    func testTransportRekeyDuringPartialLibraryRecoveryNeverInventsRemoteDeletes() async throws {
        SnippetStorageLocations.createAllDirectories()
        let aID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let bID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        func envelope(_ id: UUID, name: String) -> SyncEnvelope {
            SyncEnvelope(
                id: id,
                hlc: HLC(wallMs: 1_000, counter: 0, device: "aaaaaaa1"),
                origin: "aaaaaaa1",
                secure: false,
                deleted: false,
                fields: SyncEnvelope.Fields(
                    name: name,
                    keyword: name,
                    content: Data(name.utf8),
                    tags: [],
                    isEnabled: true,
                    isPinned: false,
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: 2)))
        }
        let a = envelope(aID, name: "restored-a")
        let b = envelope(bID, name: "remote-only-b")
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.partial-rekey-tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        let keys = SyncKeyStore(keychain: keychain)
        let material = try keys.materialMintingIfNeeded()
        let sealer = SnippetCryptoSealer(
            keyring: try SyncKeyStore.keyring(from: material), scopeID: keys.scopeID)
        let transport = RekeyRecoveryTransport(records: [
            try WireCodec.seal(a, using: sealer),
            try WireCodec.seal(b, using: sealer),
        ])
        var confirmed = SyncBase(
            cursor: transport.currentCursor,
            journalEstablished: true,
            requiresNonDestructiveLibraryMerge: true)
        for record in transport.snapshot {
            confirmed.recordConfirmed(
                try WireCodec.open(record, using: sealer),
                recordVersion: record.recordVersion)
        }
        try SyncBaseFile.write(confirmed)
        try SyncJournalFile.write(SyncJournal())
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(
            "fingerprint-for-losing-key", forKey: Self.wireKeyFingerprintDefaultsKey)
        let library = SnapshotSyncLibrary([a])
        let coordinator = SyncCoordinator(
            library: library,
            keys: keys,
            device: "aaaaaaa1",
            transportFactory: { transport })
        defer { coordinator.setEnabled(false) }

        let result = await coordinator.requestSync(trigger: .manual)

        guard case .completed(let finalState) = result else {
            return XCTFail("recovery round did not start: \(result)")
        }
        XCTAssertFalse(finalState.isHalted)
        XCTAssertEqual(library.envelope(bID), b,
                       "the old-base absence must be restored by the full fetch")
        let submitted = try transport.submittedBatches.flatMap { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertFalse(submitted.contains { $0.id == bID && $0.deleted },
                       "wire-key convergence must not turn a partial restore into deletes")
        guard case .loaded(let completed) = SyncBaseFile.load() else {
            return XCTFail("recovery must leave a readable base")
        }
        XCTAssertFalse(completed.requiresNonDestructiveLibraryMerge)
    }

    func testWireKeyConvergenceResetsTransportInboxBeforeOldCiphertextCanReplay() async throws {
        SnippetStorageLocations.createAllDirectories()
        let id = UUID(uuidString: "91919191-9191-4191-8191-919191919191")!
        let confirmed = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 100, counter: 0, device: "aaaaaaa1"),
            origin: "aaaaaaa1",
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "confirmed under K1",
                keyword: "k1",
                content: Data("local plaintext survives".utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)))
        let account = SyncAccountIdentity(Data(repeating: 0x91, count: 32))
        let oldCursor = CloudKitSyncCursor(
            epoch: UUID(uuidString: "91919191-9191-4191-8191-919191919192")!,
            throughSequence: 1).syncCursor
        var base = SyncBase(
            cursor: oldCursor,
            cursorKind: .cloudKitSyncEngine,
            journalEstablished: true,
            accountIdentity: account)
        base.recordConfirmed(
            confirmed,
            recordVersion: SyncRecordVersion(Data("K1-CAS".utf8)))
        try SyncBaseFile.write(base)
        try SyncJournalFile.write(SyncJournal())

        // This inbox record was sealed under the losing K1. Replaying it after K_sync
        // converges to K2 would quarantine it forever while retaining the old cursor.
        let oldKeyCiphertext = WireRecord(
            id: id,
            rev: "K1-rev",
            deleted: false,
            blob: Data("ciphertext-only-K1-can-open".utf8),
            recordVersion: SyncRecordVersion(Data("K1-inbox-CAS".utf8)))
        let checkpointURL = SnippetStorageLocations.cloudKitSyncCheckpointFileURL
        let checkpointStore = CloudKitSyncCheckpointStore(
            url: checkpointURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL,
            cryptor: TestCloudKitSyncCheckpointCryptor(seed: 0x91))
        _ = try checkpointStore.appendFetched(
            records: [oldKeyCiphertext],
            physicalDeletionCount: 0,
            stateSerialization: Data("K1-scheduler-state".utf8),
            for: account)
        let oldCheckpointBytes = try Data(contentsOf: checkpointURL)

        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(
            "fingerprint-for-losing-K1",
            forKey: Self.wireKeyFingerprintDefaultsKey)
        let transport = SyncLifecycleTransport(
            accountIdentity: account,
            localFullResyncAction: {
                try checkpointStore.reset(
                    for: account,
                    allowsZoneBootstrap: false)
            })
        let coordinator = makeCoordinatorForRekeyTests(
            transport: transport,
            liveEnvelopes: [confirmed])
        defer { coordinator.setEnabled(false) }

        let result = await coordinator.requestSync(trigger: .manual)
        guard case .completed(.offline) = result else {
            return XCTFail("the inert post-reset transport should finish offline, got \(result)")
        }

        XCTAssertEqual(transport.localFullResyncAttempts, 1,
                       "journal-first wire rekey must reset its transport-private inbox")
        XCTAssertEqual(transport.beforeLocalFullResyncJournal?.entry(id)?.desired, confirmed)
        XCTAssertEqual(transport.beforeLocalFullResyncJournal?.entry(id)?.offered?.envelope, confirmed)
        XCTAssertEqual(
            transport.beforeLocalFullResyncJournal?.entry(id)?.offered?.recordVersion,
            SyncRecordVersion(Data("K1-CAS".utf8)),
            "CloudKit change tags stay valid when only the local wire key changes")
        XCTAssertNil(transport.beforeLocalFullResyncBase?.cursor)
        XCTAssertEqual(
            transport.beforeLocalFullResyncBase?.recordVersion(id),
            SyncRecordVersion(Data("K1-CAS".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path),
                      "the reset must leave a durable replacement scheduler epoch")
        XCTAssertNotEqual(try Data(contentsOf: checkpointURL), oldCheckpointBytes)
        guard case .loaded(let replacement) = checkpointStore.load(for: account) else {
            return XCTFail("the K1 inbox must be replaced by a readable K2 checkpoint")
        }
        XCTAssertNil(replacement.serialization)
        XCTAssertTrue(replacement.generations.isEmpty,
                      "the old-key inbox cannot remain available for replay")
        XCTAssertFalse(replacement.allowsZoneBootstrap,
                       "a local wire-key reset cannot authorize remote zone recreation")
    }

    func testCloudKitLocalFullResyncReplacesInboxWithoutRecreatingEstablishedZone() async throws {
        SnippetStorageLocations.createAllDirectories()
        let identity = SyncAccountIdentity(Data(repeating: 0xA4, count: 32))
        let checkpointURL = SnippetStorageLocations.cloudKitSyncCheckpointFileURL
        let checkpointStore = CloudKitSyncCheckpointStore(
            url: checkpointURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL,
            cryptor: TestCloudKitSyncCheckpointCryptor(seed: 0xA4))
        _ = try checkpointStore.appendFetched(
            records: [WireRecord(
                id: UUID(uuidString: "a4a4a4a4-a4a4-44a4-84a4-a4a4a4a4a4a4")!,
                rev: "old-wire-key-record",
                deleted: false,
                blob: Data("old-key-ciphertext".utf8),
                recordVersion: SyncRecordVersion(Data("old-key-cas".utf8)))],
            physicalDeletionCount: 0,
            stateSerialization: Data("old-scheduler-state".utf8),
            for: identity)
        guard case .loaded(let oldCheckpoint) = checkpointStore.load(for: identity) else {
            return XCTFail("expected the old scheduler inbox")
        }
        let oldCheckpointBytes = try Data(contentsOf: checkpointURL)

        // This is the persistence operation used by the transport's local-full-resync
        // path. Keep this unsigned test below CloudKitTransport: constructing a real
        // CKContainer would terminate the CODE_SIGNING_ALLOWED=NO simulator host.
        try checkpointStore.reset(
            for: identity,
            allowsZoneBootstrap: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path),
                      "reset must atomically install a replacement encrypted checkpoint")
        XCTAssertNotEqual(try Data(contentsOf: checkpointURL), oldCheckpointBytes)
        guard case .loaded(let replacement) = checkpointStore.load(for: identity) else {
            return XCTFail("a restarted store must observe the replacement checkpoint")
        }
        XCTAssertNotEqual(replacement.epoch, oldCheckpoint.epoch)
        XCTAssertNil(replacement.serialization)
        XCTAssertEqual(replacement.nextSequence, 1)
        XCTAssertTrue(replacement.generations.isEmpty)
        XCTAssertFalse(replacement.allowsZoneBootstrap,
                       "local crypto maintenance cannot authorize zone recreation")

        // Model a process restart through the adapter/fake-driver seam. Nil scheduler
        // state is intentionally not enough to make this established zone look fresh.
        let factory = LocalFullResyncDriverFactoryProbe()
        let allowInitialZoneCreation = replacement.serialization == nil
            && replacement.allowsZoneBootstrap
        let driver = factory.makeDriver(
            serialization: replacement.serialization,
            allowInitialZoneCreation: allowInitialZoneCreation)
        let restarted = try CloudKitSyncTransportAdapter(
            accountIdentity: identity,
            checkpointStore: checkpointStore,
            driver: driver)
        do {
            _ = try await restarted.fetchChanges(since: nil)
            XCTFail("the probe fetch is expected to stop after adapter construction")
        } catch let failure as SyncTransportFailure {
            guard case .unreachable = failure else {
                return XCTFail("probe stopped for the wrong reason: \(failure)")
            }
        }

        XCTAssertEqual(factory.serializations, [nil])
        XCTAssertEqual(factory.allowInitialZoneCreationValues, [false],
                       "nil K2 state must not make an established zone look fresh")
        XCTAssertEqual(factory.zoneBootstrapAttempts, 0,
                       "local rekey/forget must never recreate the remote custom zone")
        guard case .loaded(let afterRestart) = checkpointStore.load(for: identity) else {
            return XCTFail("the replacement checkpoint must survive adapter restart")
        }
        XCTAssertEqual(afterRestart, replacement,
                       "preparing an established zone must not rewrite its reset epoch")
    }

    func testRapidDisableReenableAwaitsOldCloudKitEngineQuiescence() async throws {
        SnippetStorageLocations.createAllDirectories()
        UserDefaults.standard.removeObject(forKey: Self.wireKeyFingerprintDefaultsKey)
        let account = SyncAccountIdentity(Data(repeating: 0xD5, count: 32))
        let probe = RapidReenableCloudKitLifecycleProbe(accountIdentity: account)
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.rapid-reenable-tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        let coordinator = SyncCoordinator(
            library: EmptySyncLibrary(),
            keys: SyncKeyStore(keychain: keychain),
            device: "aaaaaaa1",
            transportFactory: { probe.makeTransport() })
        defer {
            probe.releaseAllFetches()
            coordinator.setEnabled(false)
            probe.forceRetireAllEngines()
        }

        coordinator.setEnabled(true)
        let firstFetchStarted = await eventually { probe.firstFetchIsInFlight }
        XCTAssertTrue(
            firstFetchStarted,
            "the first engine must be suspended inside an awaited transport operation")
        let oldTransport = try XCTUnwrap(probe.firstTransport)
        XCTAssertEqual(probe.transportCount, 1)
        XCTAssertEqual(probe.maximumLiveEngineCount, 1)

        // This is the user-visible race: turning sync back on must remember the desired
        // state, but construction of the replacement CKSyncEngine must stay behind the
        // old transport's awaited shutdown barrier.
        coordinator.setEnabled(false)
        coordinator.setEnabled(true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(
            probe.transportCount,
            1,
            "re-enable must not construct a replacement while the old fetch is suspended")
        XCTAssertEqual(
            probe.maximumLiveEngineCount,
            1,
            "one private database must never have two live CKSyncEngine instances")

        // A driver callback can already be queued when disable occurs. Shutdown closes
        // that callback gate before waiting for the operation to return. If a new engine
        // was started too early, this callback models the old driver overwriting the new
        // scope's scheduler checkpoint.
        oldTransport.deliverLateStateCallback()
        XCTAssertEqual(
            probe.replacementScopeMutationCount,
            0,
            "a callback from the retired engine must not mutate the replacement scope")

        oldTransport.releaseFetch()
        let replacementStarted = await eventually { probe.transportCount == 2 }
        XCTAssertTrue(
            replacementStarted,
            "the remembered enable request must start after old-engine quiescence")
        XCTAssertTrue(
            probe.firstShutdownCompleted,
            "replacement construction must follow the awaited shutdown completion")
        oldTransport.deliverLateStateCallback()
        XCTAssertEqual(
            probe.replacementScopeMutationCount,
            0,
            "the retired driver's queued callback must be ignored after replacement")
        XCTAssertEqual(probe.maximumLiveEngineCount, 1)
        let coordinatorDrained = await eventually { coordinator.isQuiescent }
        XCTAssertTrue(coordinatorDrained)
    }

    func testCloudMutationWaitsForShutdownAndBlocksReplacementUntilItCompletes() async throws {
        SnippetStorageLocations.createAllDirectories()
        UserDefaults.standard.removeObject(forKey: Self.wireKeyFingerprintDefaultsKey)
        let account = SyncAccountIdentity(Data(repeating: 0xD6, count: 32))
        let probe = RapidReenableCloudKitLifecycleProbe(accountIdentity: account)
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.cloud-mutation-tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        let coordinator = SyncCoordinator(
            library: EmptySyncLibrary(),
            keys: SyncKeyStore(keychain: keychain),
            device: "aaaaaaa1",
            transportFactory: { probe.makeTransport() })
        var mutationEntered = false
        var releaseMutation: CheckedContinuation<Void, Never>?
        defer {
            releaseMutation?.resume()
            probe.releaseAllFetches()
            coordinator.setEnabled(false)
            probe.forceRetireAllEngines()
        }

        coordinator.setEnabled(true)
        let firstFetchStarted = await eventually { probe.firstFetchIsInFlight }
        XCTAssertTrue(firstFetchStarted)

        let mutation = Task { @MainActor in
            try await coordinator.withQuiescedCloudTransport {
                mutationEntered = true
                await withCheckedContinuation { releaseMutation = $0 }
            }
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(mutationEntered)
        XCTAssertEqual(probe.transportCount, 1)

        probe.firstTransport?.releaseFetch()
        let didEnterMutation = await eventually { mutationEntered }
        XCTAssertTrue(didEnterMutation)
        XCTAssertTrue(probe.firstShutdownCompleted)
        XCTAssertEqual(probe.transportCount, 1)
        XCTAssertEqual(
            coordinator.syncNow(trigger: .manual),
            .notStarted(.cannotStart("Cloud account maintenance is in progress.")))
        coordinator.libraryDidChange(.local)
        XCTAssertFalse(coordinator.hasPendingLibraryChangeSync)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(
            probe.transportCount,
            1,
            "the replacement must not be constructed while credentials/root state mutate")

        releaseMutation?.resume()
        releaseMutation = nil
        try await mutation.value
        let replacementStarted = await eventually { probe.transportCount == 2 }
        XCTAssertTrue(replacementStarted)
        XCTAssertEqual(probe.maximumLiveEngineCount, 1)
    }

    func testUnreadableSyncKeyOffersCheckAgainAndStartsAfterExternalRepair() async throws {
        SnippetStorageLocations.createAllDirectories()
        UserDefaults.standard.removeObject(forKey: Self.wireKeyFingerprintDefaultsKey)
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.sync-key-check-again-tests."
                + UUID().uuidString.lowercased(),
            inMemory: true)
        try keychain.storeItem(Data("malformed sync key".utf8), account: SyncKeyStore.account)
        let transport = SyncLifecycleTransport()
        var factoryCalls = 0
        let coordinator = SyncCoordinator(
            library: EmptySyncLibrary(),
            keys: SyncKeyStore(keychain: keychain),
            device: "aaaaaaa1",
            transportFactory: {
                factoryCalls += 1
                return transport
            })
        defer { coordinator.setEnabled(false) }

        coordinator.start()
        XCTAssertEqual(coordinator.recoveryAction, .checkAgain)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertFalse(coordinator.canRequestManualSync)
        guard case .needsAttention("sync_key_unreadable") = coordinator.state else {
            return XCTFail("the malformed key needs an actionable, non-generic stop")
        }

        try keychain.storeItem(Data(repeating: 0xA7, count: 64), account: SyncKeyStore.account)
        coordinator.performRecovery(.checkAgain)

        let repairedStart = await eventually {
            factoryCalls == 1 && coordinator.engine != nil
        }
        XCTAssertTrue(repairedStart)
        XCTAssertNil(coordinator.recoveryAction)
    }

    private func makeCoordinatorForRekeyTests(
        transport: SyncLifecycleTransport = SyncLifecycleTransport(),
        liveEnvelopes: [SyncEnvelope] = []
    ) -> SyncCoordinator {
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.sync-lifecycle-tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        return SyncCoordinator(
            library: SnapshotSyncLibrary(liveEnvelopes),
            keys: SyncKeyStore(keychain: keychain),
            device: "aaaaaaa1",
            transportFactory: { transport })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class SnapshotSyncLibrary: SyncLibraryAccess {
    private var envelopes: [UUID: SyncEnvelope]

    init(_ envelopes: [SyncEnvelope]) {
        self.envelopes = Dictionary(uniqueKeysWithValues: envelopes.map { ($0.id, $0) })
    }

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        envelopes
    }

    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
        RemoteClassification(
            applicable: envelopes, deferredIDs: [], incompatibleVaultIDs: [])
    }

    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome {
        for envelope in envelopes {
            if envelope.deleted {
                self.envelopes[envelope.id] = nil
            } else {
                self.envelopes[envelope.id] = envelope
            }
        }
        return ApplyOutcome(changedIDs: envelopes.map(\.id))
    }

    func liveIDs() -> Set<UUID> { Set(envelopes.keys) }

    func envelope(_ id: UUID) -> SyncEnvelope? { envelopes[id] }

    func remove(_ id: UUID) { envelopes[id] = nil }
}

/// A tiny stateful backend for the app-target rekey integration test. The package-only
/// `InMemoryTransport` is deliberately not linked into either product target, so this
/// fixture models just the one contract the test needs: a local scheduler reset makes
/// the next fetch an authoritative full snapshot even when push-first ordering has
/// already returned a newer cursor.
private nonisolated final class RekeyRecoveryTransport: SyncTransport, @unchecked Sendable {
    let identifier = "rekey-recovery-test"
    let supportsPush = true
    let pollInterval: TimeInterval = 3_600
    let events = AsyncStream<SyncTransportEvent> { _ in }

    private let lock = NSLock()
    private var recordsByID: [UUID: WireRecord]
    private var sequence = 1
    private var needsFullSnapshot = false
    private var submittedBatchStorage: [[WireRecord]] = []

    init(records: [WireRecord]) {
        let versioned = records.enumerated().map { index, seeded in
            var record = seeded
            record.recordVersion = SyncRecordVersion(Data("seed-\(index + 1)".utf8))
            return record
        }
        recordsByID = Dictionary(uniqueKeysWithValues: versioned.map { ($0.id, $0) })
        sequence = max(1, versioned.count)
    }

    var currentCursor: SyncCursor { lock.withLock { SyncCursor("cursor-\(sequence)") } }
    var snapshot: [WireRecord] {
        lock.withLock { recordsByID.values.sorted { $0.id.uuidString < $1.id.uuidString } }
    }
    var submittedBatches: [[WireRecord]] { lock.withLock { submittedBatchStorage } }

    func resetForLocalFullResync(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        guard expectedIdentity == nil else { throw SyncTransportFailure.accountChanged }
        guard expectedDatasetIdentity == nil else {
            throw SyncTransportFailure.remoteDataReset(detail: "unexpected dataset scope")
        }
        lock.withLock { needsFullSnapshot = true }
    }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        lock.withLock {
            sequence += 1
            let fullSnapshot = needsFullSnapshot
            needsFullSnapshot = false
            return SyncFetch(
                records: fullSnapshot
                    ? recordsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
                    : [],
                cursor: SyncCursor("cursor-\(sequence)"),
                isFullResync: fullSnapshot)
        }
    }

    func submit(
        _ records: [WireRecord],
        at cursor: SyncCursor?
    ) async throws -> SyncSubmission {
        lock.withLock {
            submittedBatchStorage.append(records)
            let results = records.map { offered -> SyncSubmitResult in
                sequence += 1
                let version = SyncRecordVersion(Data("version-\(sequence)".utf8))
                var accepted = offered
                accepted.recordVersion = version
                recordsByID[accepted.id] = accepted
                return SyncSubmitResult(
                    id: accepted.id,
                    outcome: .accepted(rev: accepted.rev, recordVersion: version))
            }
            return SyncSubmission(
                results: results,
                cursor: SyncCursor("cursor-\(sequence)"))
        }
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

/// A same-account transport factory that treats each transport construction as creation
/// of its backend CKSyncEngine. The first driver's fetch ignores task cancellation until
/// the test releases it, matching an already-entered CloudKit operation. Its `shutdown`
/// witness closes callbacks, awaits that operation, and only then retires the engine.
private nonisolated final class RapidReenableCloudKitLifecycleProbe: @unchecked Sendable {
    private let accountIdentity: SyncAccountIdentity
    private let lock = NSLock()
    private var nextGeneration = 0
    private var transports: [RapidReenableCloudKitTransport] = []
    private var liveEngineCount = 0
    private var maximumLiveEngines = 0
    private var latestStartedGeneration = 0
    private var replacementScopeMutations = 0

    init(accountIdentity: SyncAccountIdentity) {
        self.accountIdentity = accountIdentity
    }

    var firstTransport: RapidReenableCloudKitTransport? {
        lock.withLock { transports.first }
    }
    var transportCount: Int { lock.withLock { transports.count } }
    var maximumLiveEngineCount: Int { lock.withLock { maximumLiveEngines } }
    var firstFetchIsInFlight: Bool { firstTransport?.fetchIsInFlight ?? false }
    var firstShutdownCompleted: Bool { firstTransport?.shutdownCompleted ?? false }
    var replacementScopeMutationCount: Int {
        lock.withLock { replacementScopeMutations }
    }

    func makeTransport() -> any SyncTransport {
        let generation = lock.withLock { () -> Int in
            nextGeneration += 1
            return nextGeneration
        }
        let transport = RapidReenableCloudKitTransport(
            generation: generation,
            accountIdentity: accountIdentity,
            probe: self,
            suspendsFetch: generation == 1)
        lock.withLock { transports.append(transport) }
        return transport
    }

    func releaseAllFetches() {
        let current = lock.withLock { transports }
        current.forEach { $0.releaseFetch() }
    }

    func forceRetireAllEngines() {
        let current = lock.withLock { transports }
        current.forEach { $0.forceRetireForTestCleanup() }
    }

    fileprivate func engineStarted(_ generation: Int) {
        lock.withLock {
            liveEngineCount += 1
            latestStartedGeneration = max(latestStartedGeneration, generation)
            maximumLiveEngines = max(maximumLiveEngines, liveEngineCount)
        }
    }

    fileprivate func engineStopped() {
        lock.withLock { liveEngineCount -= 1 }
    }

    fileprivate func deliverStateCallback(from generation: Int) {
        lock.withLock {
            // This is the forbidden cross-generation write: both generations address
            // the same explicit account/private-database identity.
            if latestStartedGeneration > generation {
                replacementScopeMutations += 1
            }
        }
    }
}

private nonisolated final class RapidReenableCloudKitTransport:
    SyncTransport, @unchecked Sendable
{
    let identifier = "icloud-lifecycle-probe"
    let supportsPush = true
    let pollInterval: TimeInterval = 6 * 60 * 60
    let events = AsyncStream<SyncTransportEvent> { _ in }

    private let generation: Int
    private let accountIdentity: SyncAccountIdentity
    private weak var probe: RapidReenableCloudKitLifecycleProbe?
    private let suspendsFetch: Bool
    private let lock = NSLock()
    private var fetchIsInFlightStorage = false
    private var fetchWasReleased = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var fetchFinishWaiters: [CheckedContinuation<Void, Never>] = []
    private var acceptsCallbacks = true
    private var shutdownHasStarted = false
    private var shutdownCompletedStorage = false
    private var engineIsLive = true

    init(
        generation: Int,
        accountIdentity: SyncAccountIdentity,
        probe: RapidReenableCloudKitLifecycleProbe,
        suspendsFetch: Bool
    ) {
        self.generation = generation
        self.accountIdentity = accountIdentity
        self.probe = probe
        self.suspendsFetch = suspendsFetch
        probe.engineStarted(generation)
    }

    var fetchIsInFlight: Bool { lock.withLock { fetchIsInFlightStorage } }
    var shutdownCompleted: Bool { lock.withLock { shutdownCompletedStorage } }

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        accountIdentity
    }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        _ = cursor
        lock.withLock { fetchIsInFlightStorage = true }
        if suspendsFetch {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    guard !fetchWasReleased else { return true }
                    fetchContinuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            fetchIsInFlightStorage = false
            defer { fetchFinishWaiters.removeAll() }
            return fetchFinishWaiters
        }
        waiters.forEach { $0.resume() }
        try Task.checkCancellation()
        return SyncFetch(
            records: [],
            cursor: nil,
            accountIdentity: accountIdentity)
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        _ = records
        return SyncSubmission(results: [], cursor: cursor, accountIdentity: accountIdentity)
    }

    func shutdown() async {
        let shouldRun = lock.withLock { () -> Bool in
            guard !shutdownHasStarted else { return false }
            shutdownHasStarted = true
            acceptsCallbacks = false
            return true
        }
        guard shouldRun else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard fetchIsInFlightStorage else { return true }
                fetchFinishWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        retireEngineIfNeeded()
        lock.withLock { shutdownCompletedStorage = true }
    }

    func deliverLateStateCallback() {
        let accepted = lock.withLock { acceptsCallbacks }
        guard accepted else { return }
        probe?.deliverStateCallback(from: generation)
    }

    func releaseFetch() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            fetchWasReleased = true
            defer { fetchContinuation = nil }
            return fetchContinuation
        }
        continuation?.resume()
    }

    func forceRetireForTestCleanup() {
        lock.withLock { acceptsCallbacks = false }
        releaseFetch()
        retireEngineIfNeeded()
    }

    private func retireEngineIfNeeded() {
        let shouldRetire = lock.withLock { () -> Bool in
            guard engineIsLive else { return false }
            engineIsLive = false
            return true
        }
        if shouldRetire { probe?.engineStopped() }
    }
}

private nonisolated final class LocalFullResyncDriverFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var serializationStorage: [Data?] = []
    private var allowInitialZoneCreationStorage: [Bool] = []
    private var zoneBootstrapAttemptCount = 0

    var serializations: [Data?] { lock.withLock { serializationStorage } }
    var allowInitialZoneCreationValues: [Bool] {
        lock.withLock { allowInitialZoneCreationStorage }
    }
    var zoneBootstrapAttempts: Int { lock.withLock { zoneBootstrapAttemptCount } }

    func makeDriver(
        serialization: Data?,
        allowInitialZoneCreation: Bool
    ) -> any CloudKitSyncDriving {
        lock.withLock {
            serializationStorage.append(serialization)
            allowInitialZoneCreationStorage.append(allowInitialZoneCreation)
        }
        return LocalFullResyncDriverProbe(
            allowInitialZoneCreation: allowInitialZoneCreation,
            recordBootstrap: { [weak self] in
                self?.recordZoneBootstrap()
            })
    }

    private func recordZoneBootstrap() {
        lock.withLock { zoneBootstrapAttemptCount += 1 }
    }
}

private nonisolated final class LocalFullResyncDriverProbe:
    CloudKitSyncDriving, @unchecked Sendable
{
    let automaticallySync = true
    let events = AsyncStream<CloudKitSyncDriverEvent> { _ in }

    private let allowInitialZoneCreation: Bool
    private let recordBootstrap: @Sendable () -> Void
    private let lock = NSLock()
    private var pending = false

    init(
        allowInitialZoneCreation: Bool,
        recordBootstrap: @escaping @Sendable () -> Void
    ) {
        self.allowInitialZoneCreation = allowInitialZoneCreation
        self.recordBootstrap = recordBootstrap
    }

    var hasPendingUntrackedChanges: Bool {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }

    func prepareForFirstFetch() async throws {
        if allowInitialZoneCreation { recordBootstrap() }
    }

    func restart(from stateSerialization: Data?) throws { _ = stateSerialization }
    func invalidate() {}
    func sendChanges() async throws {}
    func fetchChanges() async throws {
        throw SyncTransportFailure.unreachable(detail: "local-full-resync driver probe")
    }
    func cancelOperations() async {}
    func installBatchProvider(
        _ provider: nonisolated(nonsending) @escaping @Sendable (
            CloudKitSyncSendScope, Int
        ) async -> CloudKitRecordZoneChangeBatch?
    ) {
        _ = provider
    }
    func installEventHandler(
        _ handler: nonisolated(nonsending) @escaping @Sendable (
            CloudKitSyncDriverEvent
        ) async -> Void
    ) {
        _ = handler
    }
    func start() throws {}
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
    private var localFullResyncAttemptCount = 0
    private var localFullResyncBaseStorage: SyncBase?
    private var localFullResyncJournalStorage: SyncJournal?
    private var localFullResyncIsInFlightStorage = false
    private var localFullResyncWasReleased = false
    private var localFullResyncContinuation: CheckedContinuation<Void, Never>?
    private let accountIdentity: SyncAccountIdentity?
    private let datasetIdentity: SyncDatasetIdentity?
    private let suspendsLocalFullResync: Bool
    private let localFullResyncAction: @Sendable () throws -> Void

    init(
        accountIdentity: SyncAccountIdentity? = nil,
        datasetIdentity: SyncDatasetIdentity? = nil,
        suspendsLocalFullResync: Bool = false,
        localFullResyncAction: @escaping @Sendable () throws -> Void = {}
    ) {
        self.accountIdentity = accountIdentity
        self.datasetIdentity = datasetIdentity
        self.suspendsLocalFullResync = suspendsLocalFullResync
        self.localFullResyncAction = localFullResyncAction
    }

    var fetchAttempts: Int { lock.withLock { fetchAttemptCount } }
    var submitAttempts: Int { lock.withLock { submitAttemptCount } }
    var localFullResyncAttempts: Int { lock.withLock { localFullResyncAttemptCount } }
    var beforeLocalFullResyncBase: SyncBase? {
        lock.withLock { localFullResyncBaseStorage }
    }
    var beforeLocalFullResyncJournal: SyncJournal? {
        lock.withLock { localFullResyncJournalStorage }
    }
    var localFullResyncIsInFlight: Bool {
        lock.withLock { localFullResyncIsInFlightStorage }
    }

    func releaseLocalFullResync() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            localFullResyncWasReleased = true
            defer { localFullResyncContinuation = nil }
            return localFullResyncContinuation
        }
        continuation?.resume()
    }

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        accountIdentity
    }

    func preflightScope() async throws -> SyncScopePreflight {
        SyncScopePreflight(identity: accountIdentity, datasetIdentity: datasetIdentity)
    }

    func resetForLocalFullResync(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        guard expectedIdentity == accountIdentity else {
            throw SyncTransportFailure.accountChanged
        }
        guard expectedDatasetIdentity == datasetIdentity else {
            throw SyncTransportFailure.remoteDataReset(detail: "unexpected dataset scope")
        }
        lock.withLock {
            localFullResyncAttemptCount += 1
            localFullResyncIsInFlightStorage = true
            if case .loaded(let base) = SyncBaseFile.load() {
                localFullResyncBaseStorage = base
            }
            if case .loaded(let journal) = SyncJournalFile.load() {
                localFullResyncJournalStorage = journal
            }
        }
        defer { lock.withLock { localFullResyncIsInFlightStorage = false } }
        if suspendsLocalFullResync {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    guard !localFullResyncWasReleased else { return true }
                    localFullResyncContinuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        try localFullResyncAction()
    }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        lock.withLock { fetchAttemptCount += 1 }
        throw SyncTransportFailure.unreachable(detail: "lifecycle test transport is inert")
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        lock.withLock { submitAttemptCount += 1 }
        throw SyncTransportFailure.unreachable(detail: "lifecycle test transport is inert")
    }
}

@MainActor
private final class OfflineRetryArmHarness {
    private struct Entry {
        var action: () -> Void
        var isCancelled = false
        var didFire = false
    }

    private var entries: [Entry] = []
    private(set) var delays: [TimeInterval] = []
    private(set) var cancelCount = 0

    lazy var arm: SyncOfflineRetryScheduler.Arm = { [weak self] delay, action in
        guard let self else { return {} }
        let index = entries.count
        delays.append(delay)
        entries.append(Entry(action: action))
        return { [weak self] in
            guard let self, entries.indices.contains(index), !entries[index].isCancelled else {
                return
            }
            entries[index].isCancelled = true
            cancelCount += 1
        }
    }

    func fire(_ index: Int, evenIfCancelled: Bool = false) {
        guard entries.indices.contains(index),
              !entries[index].didFire,
              evenIfCancelled || !entries[index].isCancelled else { return }
        entries[index].didFire = true
        entries[index].action()
    }
}
