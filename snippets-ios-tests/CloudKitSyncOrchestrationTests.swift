import CloudKit
import Foundation
import XCTest

@testable import Snippets

/// Deterministic tests for the project-owned adapter around `CKSyncEngine`.
///
/// The fake driver never creates a `CKContainer`.  It models delegate callbacks and
/// immediate manual operations only, so passing these tests says nothing about push
/// delivery on a physical device (and intentionally does not need an iCloud account).
@MainActor
final class CloudKitSyncOrchestrationTests: XCTestCase {
    private var rootURL: URL!
    private var checkpointURL: URL!
    private var temporaryDirectory: URL!
    private let account = SyncAccountIdentity(Data(repeating: 0x42, count: 32))

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudKitSyncOrchestrationTests-\(UUID().uuidString)", isDirectory: true)
        checkpointURL = rootURL.appendingPathComponent(
            "cksync-checkpoint.json", isDirectory: false)
        temporaryDirectory = rootURL.appendingPathComponent("Tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
        checkpointURL = nil
        temporaryDirectory = nil
    }

    func testStateUpdateOutsideFetchPersistsImmediately() async throws {
        let fixture = try makeAdapter()

        try await fixture.adapter.handle(
            .stateUpdate(Data("scheduled-state".utf8)))

        let checkpoint = try loadedCheckpoint()
        XCTAssertEqual(checkpoint.serialization, Data("scheduled-state".utf8))
        XCTAssertTrue(checkpoint.generations.isEmpty)
    }

    func testUnreadableEncryptedCheckpointRoutesTypedReviewedFailure() throws {
        try store().saveStateSerialization(Data("authenticated-state".utf8), for: account)
        let wrongKeyStore = CloudKitSyncCheckpointStore(
            url: checkpointURL,
            temporaryDirectory: temporaryDirectory,
            cryptor: TestCloudKitSyncCheckpointCryptor(seed: 0xE8))

        do {
            _ = try CloudKitSyncTransportAdapter(
                accountIdentity: account,
                checkpointStore: wrongKeyStore,
                driver: FakeCloudKitSyncDriver())
            XCTFail("authenticated checkpoint failure must stop for its reviewed reset")
        } catch let failure as SyncTransportFailure {
            guard case .checkpointUnreadable = failure else {
                return XCTFail("expected checkpointUnreadable, got \(failure)")
            }
        }
    }

    func testFetchEventsStageUntilDidFetchThenCommitLatestStateAndRecordsAtomically() async throws {
        try store().saveStateSerialization(Data("old-state".utf8), for: account)
        let fixture = try makeAdapter()
        let r1 = wire(id: "11111111-1111-4111-8111-111111111111", rev: "R1")
        let r2 = wire(id: "22222222-2222-4222-8222-222222222222", rev: "R2")

        try await fixture.adapter.handle(.willFetch)
        try await fixture.adapter.handle(
            .fetchedRecords([r1], physicalDeletionCount: 0))
        try await fixture.adapter.handle(.stateUpdate(Data("intermediate".utf8)))
        try await fixture.adapter.handle(
            .fetchedRecords([r2], physicalDeletionCount: 0))
        try await fixture.adapter.handle(.stateUpdate(Data("S1".utf8)))

        var checkpoint = try loadedCheckpoint()
        XCTAssertEqual(checkpoint.serialization, Data("old-state".utf8))
        XCTAssertTrue(checkpoint.generations.isEmpty,
                      "a crash before didFetch must safely repeat the old fetch")

        try await fixture.adapter.handle(.didFetch)

        checkpoint = try loadedCheckpoint()
        let generation = try XCTUnwrap(checkpoint.generations.first)
        XCTAssertEqual(checkpoint.serialization, Data("S1".utf8))
        XCTAssertEqual(generation.serialization, Data("S1".utf8))
        XCTAssertEqual(generation.records, [r1, r2])
        XCTAssertEqual(generation.physicalDeletionCount, 0)
    }

    func testStateUpdateAfterDidFetchCommitsExactlyOneGenerationWithNewWatermark() async throws {
        try store().saveStateSerialization(Data("old-watermark".utf8), for: account)
        let fixture = try makeAdapter()
        let remote = wire(
            id: "12121212-1212-4212-8212-121212121212", rev: "late-state")

        await fixture.driver.deliver(.willFetch)
        await fixture.driver.deliver(.fetchedRecords([remote], physicalDeletionCount: 0))
        await fixture.driver.deliver(.didFetch)

        var checkpoint = try loadedCheckpoint()
        XCTAssertEqual(checkpoint.serialization, Data("old-watermark".utf8))
        XCTAssertTrue(checkpoint.generations.isEmpty,
                      "didFetch alone cannot pair new records with the old scheduler state")

        await fixture.driver.deliver(.stateUpdate(Data("new-watermark".utf8)))

        checkpoint = try loadedCheckpoint()
        XCTAssertEqual(checkpoint.serialization, Data("new-watermark".utf8))
        XCTAssertEqual(checkpoint.generations.count, 1)
        XCTAssertEqual(checkpoint.generations.first?.records, [remote])
        XCTAssertEqual(
            checkpoint.generations.first?.serialization,
            Data("new-watermark".utf8))
    }

    func testEmptyManualFetchWithoutStateUpdateCreatesNoGeneration() async throws {
        try store().saveStateSerialization(Data("unchanged-watermark".utf8), for: account)
        let fixture = try makeAdapter()
        fixture.driver.onFetch = { [driver = fixture.driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.didFetch)
        }

        let fetched = try await fixture.adapter.fetchChanges(since: nil)

        XCTAssertTrue(fetched.records.isEmpty)
        XCTAssertNil(fetched.cursor)
        XCTAssertNil(fetched.cursorKind)
        let checkpoint = try loadedCheckpoint()
        XCTAssertEqual(checkpoint.serialization, Data("unchanged-watermark".utf8))
        XCTAssertTrue(checkpoint.generations.isEmpty)
    }

    func testNonemptyManualFetchWithoutStateUpdateFailsClosed() async throws {
        try store().saveStateSerialization(Data("old-watermark".utf8), for: account)
        let fixture = try makeAdapter()
        let remote = wire(
            id: "13131313-1313-4313-8313-131313131313", rev: "unsafe-no-state")
        fixture.driver.onFetch = { [driver = fixture.driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.fetchedRecords([remote], physicalDeletionCount: 0))
            await driver.deliver(.didFetch)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }

        let checkpoint = try loadedCheckpoint()
        XCTAssertEqual(checkpoint.serialization, Data("old-watermark".utf8))
        XCTAssertTrue(checkpoint.generations.isEmpty,
                      "records without their new CKSyncEngine state must never enter the inbox")
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }
        XCTAssertEqual(fixture.driver.manualCalls, [.fetchChanges],
                       "the ambiguous fetch failure must remain sticky")
    }

    func testPhysicalRecordDeletionIsStickyAndCannotAdvanceTheCheckpoint() async throws {
        try store().reset(for: account, allowsZoneBootstrap: false)
        try store().saveStateSerialization(Data("before-physical-delete".utf8), for: account)
        let fixture = try makeAdapter()
        let before = try loadedCheckpoint()
        fixture.driver.onFetch = { [driver = fixture.driver] in
            await driver.deliver(.remoteDataLoss(.physicalRecordDeletion))
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }
        XCTAssertEqual(
            try loadedCheckpoint(),
            before,
            "an unexplained physical deletion must not publish its scheduler watermark")

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }
        XCTAssertEqual(
            fixture.driver.manualCalls,
            [.fetchChanges],
            "remote data loss must remain sticky instead of fetching past the deletion")
    }

    func testCloudKitDatabaseDeletionReasonsMapToDistinctTypedLossEvents() {
        let mappings: [(CKDatabase.DatabaseChange.Deletion.Reason, CloudKitRemoteDataLoss)] = [
            (.deleted, .zoneDeleted),
            (.purged, .zonePurged),
            (.encryptedDataReset, .encryptedDataReset),
        ]

        for (cloudKitReason, expected) in mappings {
            XCTAssertEqual(
                CloudKitSyncEngineDriver.remoteDataLoss(for: cloudKitReason),
                expected,
                "the driver boundary must not collapse CloudKit's deletion reason")
        }
    }

    func testEveryTypedRemoteDataLossEventUsesTheSameNonrecoverableFailure() async throws {
        try store().saveStateSerialization(Data("before-remote-data-loss".utf8), for: account)
        let reasons: [CloudKitRemoteDataLoss] = [
            .physicalRecordDeletion,
            .zoneDeleted,
            .zonePurged,
            .encryptedDataReset,
        ]

        for reason in reasons {
            let fixture = try makeAdapter()
            let before = try loadedCheckpoint()
            await fixture.driver.deliver(.remoteDataLoss(reason))

            do {
                _ = try await fixture.adapter.fetchChanges(since: nil)
                XCTFail("\(reason) must stop before another fetch")
            } catch let failure as SyncTransportFailure {
                guard case .remoteDataReset = failure else {
                    XCTFail("\(reason) must map to remoteDataReset, got \(failure)")
                    continue
                }
            }
            XCTAssertEqual(try loadedCheckpoint(), before)
            let cancelled = await eventually { fixture.driver.cancelCount == 1 }
            XCTAssertTrue(cancelled)
            XCTAssertTrue(
                fixture.driver.reentrantOperations.isEmpty,
                "remote loss may invalidate inside the callback but cannot re-enter CKSyncEngine")
        }
    }

    func testR1S1R2S2CallbacksNeverPairFirstGenerationWithSecondWatermark() async throws {
        let fixture = try makeAdapter()
        let r1 = wire(id: "33333333-3333-4333-8333-333333333333", rev: "R1")
        let r2 = wire(id: "44444444-4444-4444-8444-444444444444", rev: "R2")

        try await fixture.adapter.handle(.willFetch)
        try await fixture.adapter.handle(.fetchedRecords([r1], physicalDeletionCount: 0))
        try await fixture.adapter.handle(.stateUpdate(Data("S1".utf8)))
        try await fixture.adapter.handle(.didFetch)
        try await fixture.adapter.handle(.willFetch)
        try await fixture.adapter.handle(.fetchedRecords([r2], physicalDeletionCount: 0))
        try await fixture.adapter.handle(.stateUpdate(Data("S2".utf8)))
        try await fixture.adapter.handle(.didFetch)

        let generations = try loadedCheckpoint().generations
        XCTAssertEqual(generations.map(\.records), [[r1], [r2]])
        XCTAssertEqual(
            generations.map(\.serialization),
            [Data("S1".utf8), Data("S2".utf8)])
    }

    func testRecordsArrivingAfterStateRequireANewerWatermarkBeforeCommit() async throws {
        try store().saveStateSerialization(Data("old-durable-state".utf8), for: account)
        let fixture = try makeAdapter()
        let r1 = wire(id: "45454545-4545-4545-8545-454545454545", rev: "R1")
        let r2 = wire(id: "46464646-4646-4646-8646-464646464646", rev: "R2")
        fixture.driver.onFetch = { [driver = fixture.driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.fetchedRecords([r1], physicalDeletionCount: 0))
            await driver.deliver(.stateUpdate(Data("S1-before-R2".utf8)))
            await driver.deliver(.fetchedRecords([r2], physicalDeletionCount: 0))
            await driver.deliver(.didFetch)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }

        let checkpoint = try loadedCheckpoint()
        XCTAssertEqual(checkpoint.serialization, Data("old-durable-state".utf8))
        XCTAssertTrue(checkpoint.generations.isEmpty,
                      "R2 must never be persisted under the earlier S1 watermark")
    }

    func testRestartReplaysAdvancedGenerationByteForByteUntilCursorIsAcknowledged() async throws {
        let remote = wire(
            id: "55555555-5555-4555-8555-555555555555", rev: "unapplied")
        _ = try store().appendFetched(
            records: [remote], physicalDeletionCount: 0,
            stateSerialization: Data("advanced-before-crash".utf8), for: account)

        let firstProcess = try makeAdapter()
        let first = try await firstProcess.adapter.fetchChanges(since: nil)
        let restarted = try makeAdapter()
        let replay = try await restarted.adapter.fetchChanges(since: nil)

        XCTAssertEqual(first.records, [remote])
        XCTAssertEqual(replay, first,
                       "not returning the cursor means apply was not durable; restart must replay")
        XCTAssertEqual(firstProcess.driver.manualCalls, [])
        XCTAssertEqual(restarted.driver.manualCalls, [],
                       "durable inbox recovery must happen before any network fetch")
    }

    func testFetchReturnsEntireDurableInboxWithNoUnsafeIntraRoundPagination() async throws {
        let r1 = wire(id: "66666666-6666-4666-8666-666666666666", rev: "R1")
        let r2 = wire(id: "77777777-7777-4777-8777-777777777777", rev: "R2")
        _ = try store().appendFetched(
            records: [r1], physicalDeletionCount: 0,
            stateSerialization: Data("S1".utf8), for: account)
        let second = try store().appendFetched(
            records: [r2], physicalDeletionCount: 0,
            stateSerialization: Data("S2".utf8), for: account)
        let fixture = try makeAdapter()

        let fetched = try await fixture.adapter.fetchChanges(since: nil)

        XCTAssertEqual(fetched.records, [r1, r2])
        XCTAssertFalse(fetched.hasMore,
                       "SyncEngine follows hasMore before apply/base fsync; pagination cannot ACK")
        XCTAssertEqual(
            CloudKitSyncCursor.decode(try XCTUnwrap(fetched.cursor))?.throughSequence,
            second.sequence)
        XCTAssertEqual(try loadedCheckpoint().generations.count, 2,
                       "returning a cursor is not yet a durable acknowledgement")
    }

    func testCoreCompactsInboxOnlyAfterCursorBaseFsyncSucceeds() async throws {
        let paths = try makeEnginePaths("ack-after-base-fsync")
        try SyncBaseFile.write(
            SyncBase(journalEstablished: true, accountIdentity: account),
            to: paths.baseURL,
            temporaryDirectory: paths.temporaryDirectory)
        try SyncJournalFile.write(
            SyncJournal(),
            to: paths.journalURL,
            temporaryDirectory: paths.temporaryDirectory)
        let sealer = AdapterPassthroughSealer()
        let remoteEnvelope = envelope(
            id: "67676767-6767-4767-8767-676767676767",
            content: "remote-before-base-fsync",
            milliseconds: 100)
        var remote = try WireCodec.seal(remoteEnvelope, using: sealer)
        remote.recordVersion = SyncRecordVersion(Data("remote-cas".utf8))
        let generation = try store().appendFetched(
            records: [remote],
            physicalDeletionCount: 0,
            stateSerialization: Data("remote-S1".utf8),
            for: account)
        let fixture = try makeAdapter()
        let library = BasePersistenceSabotageLibrary(baseURL: paths.baseURL)
        let engine = makeEngine(
            transport: fixture.adapter,
            library: library,
            sealer: sealer,
            paths: paths)

        let result = await engine.sync()

        guard case .halted(.localLibraryQuarantined, _) = result else {
            return XCTFail("injected base rename failure must halt, got \(result)")
        }
        XCTAssertEqual(library.readAttempts, 2,
                       "the base was damaged only after the durable inbox was returned")
        XCTAssertEqual(try loadedCheckpoint().generations, [generation],
                       "a cursor returned to Core is not an ACK until base.json fsync succeeds")
        XCTAssertEqual(try loadedCheckpoint().serialization, Data("remote-S1".utf8))
    }

    func testSuccessfulBaseFsyncAcknowledgesExactlyTheReturnedInboxPrefix() async throws {
        let paths = try makeEnginePaths("ack-after-successful-base-fsync")
        try SyncBaseFile.write(
            SyncBase(journalEstablished: true, accountIdentity: account),
            to: paths.baseURL,
            temporaryDirectory: paths.temporaryDirectory)
        try SyncJournalFile.write(
            SyncJournal(),
            to: paths.journalURL,
            temporaryDirectory: paths.temporaryDirectory)
        let sealer = AdapterPassthroughSealer()
        let remoteEnvelope = envelope(
            id: "68686868-6868-4868-8868-686868686868",
            content: "remote-after-base-fsync",
            milliseconds: 200)
        var remote = try WireCodec.seal(remoteEnvelope, using: sealer)
        remote.recordVersion = SyncRecordVersion(Data("remote-success-cas".utf8))
        let generation = try store().appendFetched(
            records: [remote],
            physicalDeletionCount: 0,
            stateSerialization: Data("remote-success-S1".utf8),
            for: account)
        let fixture = try makeAdapter()
        let library = AdapterLibrary()
        let engine = makeEngine(
            transport: fixture.adapter,
            library: library,
            sealer: sealer,
            paths: paths)

        let result = await engine.sync()

        guard case .idle = result else {
            return XCTFail("durable apply/ACK should complete, got \(result)")
        }
        let expectedCursor = CloudKitSyncCursor(
            epoch: try loadedCheckpoint().epoch,
            throughSequence: generation.sequence).syncCursor
        XCTAssertEqual(try loadedBase(at: paths.baseURL).cursor, expectedCursor)
        XCTAssertTrue(try loadedCheckpoint().generations.isEmpty,
                      "only the prefix represented by the durable base may compact")
        XCTAssertEqual(library.envelopes[remoteEnvelope.id], remoteEnvelope)
    }

    func testLaterRoundCursorAcknowledgesOnlyReturnedPrefixAndIsIdempotent() async throws {
        let r1 = wire(id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", rev: "R1")
        let r2 = wire(id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", rev: "R2")
        let firstGeneration = try store().appendFetched(
            records: [r1], physicalDeletionCount: 0,
            stateSerialization: Data("S1".utf8), for: account)
        let fixture = try makeAdapter()
        let firstRound = try await fixture.adapter.fetchChanges(since: nil)
        let firstCursor = try XCTUnwrap(firstRound.cursor)

        // This arrives after round 1 returned its cursor but before a later durable-base
        // round presents that cursor back to the adapter.
        let secondGeneration = try store().appendFetched(
            records: [r2], physicalDeletionCount: 0,
            stateSerialization: Data("S2".utf8), for: account)
        let secondRound = try await fixture.adapter.fetchChanges(since: firstCursor)

        XCTAssertEqual(secondRound.records, [r2])
        XCTAssertFalse(secondRound.hasMore)
        XCTAssertEqual(
            try loadedCheckpoint().generations.map(\.sequence),
            [secondGeneration.sequence])

        let repeated = try await fixture.adapter.fetchChanges(since: firstCursor)
        XCTAssertEqual(repeated, secondRound,
                       "an old ACK token must not compact the next unacknowledged page")
        XCTAssertEqual(
            CloudKitSyncCursor.decode(firstCursor)?.throughSequence,
            firstGeneration.sequence)
    }

    func testAcknowledgedCursorRemainsStableAcrossRepeatedEmptyFetches() async throws {
        let remote = wire(
            id: "dededede-dede-4ded-8ded-dededededede", rev: "R1")
        _ = try store().appendFetched(
            records: [remote], physicalDeletionCount: 0,
            stateSerialization: Data("S1".utf8), for: account)
        let fixture = try makeAdapter()
        fixture.driver.onFetch = { [driver = fixture.driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.didFetch)
        }

        let first = try await fixture.adapter.fetchChanges(since: nil)
        let c1 = try XCTUnwrap(first.cursor)
        XCTAssertEqual(first.records, [remote])

        let acknowledged = try await fixture.adapter.fetchChanges(since: c1)
        XCTAssertTrue(acknowledged.records.isEmpty)
        XCTAssertEqual(acknowledged.cursor, c1)
        XCTAssertEqual(acknowledged.cursorKind, .cloudKitSyncEngine)
        XCTAssertFalse(acknowledged.isFullResync)

        let repeated = try await fixture.adapter.fetchChanges(since: c1)
        XCTAssertTrue(repeated.records.isEmpty)
        XCTAssertEqual(repeated.cursor, c1)
        XCTAssertEqual(repeated.cursorKind, .cloudKitSyncEngine)
        XCTAssertFalse(repeated.isFullResync)
        XCTAssertEqual(fixture.driver.manualCalls, [.fetchChanges, .fetchChanges])
    }

    func testWrongEpochCursorForcesFullResyncWithoutAcknowledgingInbox() async throws {
        let remote = wire(
            id: "88888888-8888-4888-8888-888888888888", rev: "still-pending")
        _ = try store().appendFetched(
            records: [remote], physicalDeletionCount: 0,
            stateSerialization: Data("current".utf8), for: account)
        let before = try loadedCheckpoint()
        let wrongCursor = CloudKitSyncCursor(
            epoch: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            throughSequence: UInt64.max).syncCursor
        let fixture = try makeAdapter()

        let fetched = try await fixture.adapter.fetchChanges(since: wrongCursor)

        XCTAssertTrue(fetched.isFullResync)
        XCTAssertEqual(fetched.records, [remote])
        XCTAssertEqual(try loadedCheckpoint(), before,
                       "a stale process/account epoch has no authority to ACK")
    }

    func testIncompatibleCursorCannotClaimFullResyncUsingRestoredIncrementalState() async throws {
        try store().saveStateSerialization(
            Data("restored-incremental-scheduler-state".utf8), for: account)
        let fixture = try makeAdapter()
        fixture.driver.onFetch = { [driver = fixture.driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.didFetch)
        }
        let incompatible = SyncCursor("legacy-server-change-token")

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: incompatible)
        }
        XCTAssertTrue(
            fixture.driver.manualCalls.isEmpty,
            "a full resync must recreate CKSyncEngine from nil or stop for review; "
                + "it cannot continue the restored incremental scheduler token")
    }

    func testMissingMigratedCKStateReportsFullResync() async throws {
        try store().resetAfterAccountReview(for: account)
        let fixture = try makeAdapter()
        fixture.driver.onFetch = { [adapter = fixture.adapter] in
            try await adapter.handle(.willFetch)
            try await adapter.handle(.stateUpdate(Data("fresh-S1".utf8)))
            try await adapter.handle(.didFetch)
        }

        let fetched = try await fixture.adapter.fetchChanges(since: nil)

        XCTAssertTrue(fetched.isFullResync,
                      "nil migrated serialization cannot masquerade as a delta cursor")
        XCTAssertEqual(fixture.driver.manualCalls, [.fetchChanges])
    }

    func testFreshDriverPreparesZoneBeforeFirstFetch() async throws {
        let checkpointStore = store()
        let account = account
        let driver = FakeCloudKitSyncDriver(
            requiresZoneBootstrap: true,
            allowsZoneBootstrapAtCompletion: {
                guard case .loaded(let checkpoint) = checkpointStore.load(for: account)
                else { return nil }
                return checkpoint.allowsZoneBootstrap
            })
        driver.onFetch = { [driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.didFetch)
        }
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: checkpointStore,
            driver: driver)
        guard case .loaded(let fresh) = checkpointStore.load(for: account) else {
            return XCTFail("a fresh adapter must create its durable scheduler checkpoint")
        }
        XCTAssertTrue(fresh.allowsZoneBootstrap)

        _ = try await adapter.fetchChanges(since: nil)

        XCTAssertEqual(
            driver.orderedOperations,
            [.bootstrapZone, .completeFirstFetchPreparation, .fetchChanges],
            "zone save, durable checkpoint, and engine start must precede the first fetch")
        XCTAssertEqual(
            driver.allowsZoneBootstrapObservedAtCompletion,
            false,
            "the automatically scheduling engine may start only after the bootstrap grant is durable")
        guard case .loaded(let prepared) = checkpointStore.load(for: account) else {
            return XCTFail("successful preparation must leave a readable checkpoint")
        }
        XCTAssertFalse(prepared.allowsZoneBootstrap,
                       "awaited zone creation must durably consume its one-shot authority")
    }

    func testAdapterShutdownRejectsStaleFetchBeforeDriverPreparation() async throws {
        let driver = FakeCloudKitSyncDriver(requiresZoneBootstrap: true)
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: store(),
            driver: driver)
        let staleCallerGate = TransportReplacementGate()
        let staleCallerReady = LockedBox(false)
        defer { staleCallerGate.open() }

        // The fetch caller exists before shutdown but has not yet registered fresh-zone
        // preparation. Releasing it after shutdown models an old task whose executor did
        // not schedule it until after the close-and-drain boundary completed.
        let staleFetch = Task {
            staleCallerReady.set(true)
            await staleCallerGate.wait()
            do {
                _ = try await adapter.fetchChanges(since: nil)
                return "completed"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected-error"
            }
        }
        let callerExists = await eventually { staleCallerReady.value }
        XCTAssertTrue(callerExists)

        await adapter.shutdown()

        XCTAssertEqual(driver.cancelCount, 1)
        XCTAssertFalse(driver.orderedOperations.contains(.bootstrapZone))
        XCTAssertFalse(
            driver.orderedOperations.contains(.completeFirstFetchPreparation))
        XCTAssertTrue(driver.manualCalls.isEmpty)
        XCTAssertTrue(driver.restartSerializations.isEmpty)

        staleCallerGate.open()
        let outcome = await staleFetch.value

        XCTAssertEqual(outcome, "cancelled")
        XCTAssertFalse(
            driver.orderedOperations.contains(.bootstrapZone),
            "a stale fetch must not create a zone after adapter shutdown")
        XCTAssertFalse(
            driver.orderedOperations.contains(.completeFirstFetchPreparation),
            "a stale fetch must not construct its automatically scheduling engine")
        XCTAssertTrue(driver.manualCalls.isEmpty)
        XCTAssertTrue(driver.restartSerializations.isEmpty)
    }

    func testPreparationCloseRejectsStaleCallerBeforeOperationRegistration() async {
        let preparation = CloudKitSyncDriverPreparation()
        let staleCallerGate = TransportReplacementGate()
        let staleCallerReady = LockedBox(false)
        let bootstrapCount = LockedBox(0)
        defer { staleCallerGate.open() }

        let staleCaller = Task {
            staleCallerReady.set(true)
            await staleCallerGate.wait()
            do {
                try await preparation.run {
                    bootstrapCount.update { $0 += 1 }
                }
                return "completed"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected-error"
            }
        }
        let callerExists = await eventually { staleCallerReady.value }
        XCTAssertTrue(callerExists)

        preparation.stopAccepting()
        await preparation.waitUntilIdle()
        XCTAssertEqual(bootstrapCount.value, 0)

        staleCallerGate.open()
        let outcome = await staleCaller.value

        XCTAssertEqual(outcome, "cancelled")
        XCTAssertEqual(
            bootstrapCount.value,
            0,
            "close must reject a stale caller before its CloudKit operation starts")
    }

    func testPreparationCloseRejectsStaleRunAfterCachedCompletion() async throws {
        let preparation = CloudKitSyncDriverPreparation()
        let bootstrapCount = LockedBox(0)

        try await preparation.run {
            bootstrapCount.update { $0 += 1 }
        }
        XCTAssertEqual(bootstrapCount.value, 1)

        preparation.stopAccepting()
        await preparation.waitUntilIdle()

        do {
            try await preparation.run {
                bootstrapCount.update { $0 += 1 }
            }
            XCTFail("cached completion must not let a stale caller bypass shutdown")
        } catch is CancellationError {
            // Expected: close wins even though the prior preparation completed.
        } catch {
            XCTFail("expected CancellationError, got \(type(of: error))")
        }

        XCTAssertEqual(
            bootstrapCount.value,
            1,
            "a stale post-shutdown run must not execute another CloudKit operation")
    }

    func testPreparationShutdownDrainWaitsForRegisteredOperation() async throws {
        let preparation = CloudKitSyncDriverPreparation()
        let bootstrapGate = TransportReplacementGate()
        let bootstrapStarted = LockedBox(false)
        let bootstrapFinished = LockedBox(false)
        let drainFinished = LockedBox(false)
        let bootstrapCount = LockedBox(0)
        defer { bootstrapGate.open() }

        let registered = Task {
            try await preparation.run {
                bootstrapCount.update { $0 += 1 }
                bootstrapStarted.set(true)
                await bootstrapGate.wait()
                bootstrapFinished.set(true)
            }
        }
        let operationRegistered = await eventually { bootstrapStarted.value }
        XCTAssertTrue(operationRegistered)

        preparation.stopAccepting()
        let drain = Task {
            await preparation.waitUntilIdle()
            drainFinished.set(true)
        }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(bootstrapCount.value, 1)
        XCTAssertFalse(bootstrapFinished.value)
        XCTAssertFalse(
            drainFinished.value,
            "shutdown must wait for every preparation registered before close")

        do {
            try await preparation.run {
                bootstrapCount.update { $0 += 1 }
            }
            XCTFail("preparation registered after close must be cancelled")
        } catch is CancellationError {
            // Expected: the registered operation remains the only CloudKit bootstrap.
        } catch {
            XCTFail("expected CancellationError, got \(type(of: error))")
        }
        XCTAssertEqual(bootstrapCount.value, 1)

        bootstrapGate.open()
        try await registered.value
        await drain.value

        XCTAssertTrue(bootstrapFinished.value)
        XCTAssertTrue(drainFinished.value)
        XCTAssertEqual(bootstrapCount.value, 1)
    }

    func testRepairOrLocalResetWithNilStateNeverBootstrapsZone() async throws {
        let checkpointStore = store()
        try checkpointStore.reset(
            for: account,
            allowsZoneBootstrap: false)
        guard case .loaded(let reset) = checkpointStore.load(for: account) else {
            return XCTFail("reviewed repair/local reset must install a checkpoint")
        }
        XCTAssertNil(reset.serialization)
        XCTAssertFalse(reset.allowsZoneBootstrap)

        let driver = FakeCloudKitSyncDriver(
            requiresZoneBootstrap: reset.serialization == nil
                && reset.allowsZoneBootstrap)
        driver.onFetch = { [driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.didFetch)
        }
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: checkpointStore,
            driver: driver)

        _ = try await adapter.fetchChanges(since: nil)

        XCTAssertEqual(driver.orderedOperations, [.fetchChanges],
                       "nil repaired/reset state must not recreate an established zone")
        guard case .loaded(let afterFetch) = checkpointStore.load(for: account) else {
            return XCTFail("the reset checkpoint must remain readable")
        }
        XCTAssertFalse(afterFetch.allowsZoneBootstrap)
    }

    func testInitialSignInWithNilSchedulerStateRemainsFreshBootstrap() async throws {
        let driver = FakeCloudKitSyncDriver(requiresZoneBootstrap: true)
        driver.onFetch = { [driver] in
            await driver.deliver(.accountChange(.signIn))
            await driver.deliver(.willFetch)
            await driver.deliver(.didFetch)
        }
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: store(),
            driver: driver)

        let fetched = try await adapter.fetchChanges(since: nil)

        XCTAssertTrue(fetched.isFullResync)
        XCTAssertEqual(driver.invalidationCount, 0,
                       "CKSyncEngine's initial signIn is initialization, not account loss")
        XCTAssertEqual(
            driver.orderedOperations,
            [.bootstrapZone, .completeFirstFetchPreparation, .fetchChanges])
        XCTAssertEqual(driver.cancelCount, 0)
    }

    func testSignOutAndSwitchAccountsSynchronouslyInvalidateAndMapToAccountChanged() async throws {
        for change in [
            CloudKitSyncAccountChange.signOut,
            .switchAccounts,
        ] {
            let fixture = try makeAdapter()
            await fixture.driver.deliver(.accountChange(change))

            XCTAssertEqual(fixture.driver.invalidationCount, 1)
            XCTAssertTrue(fixture.driver.invalidatedDuringCallback)
            do {
                _ = try await fixture.adapter.resolveAccountIdentity()
                XCTFail("\(change) must poison the account-scoped scheduler epoch")
            } catch let failure as SyncTransportFailure {
                XCTAssertEqual(failure, .accountChanged)
            }
            let cancelled = await eventually { fixture.driver.cancelCount == 1 }
            XCTAssertTrue(cancelled)
            XCTAssertTrue(fixture.driver.reentrantOperations.isEmpty)
        }
    }

    func testDriverPreservesEverySDKAccountChangeType() {
        XCTAssertEqual(
            CloudKitSyncEngineDriver.accountChange(
                for: .signIn(currentUser: CKRecord.ID(recordName: "new-user"))),
            .signIn)
        XCTAssertEqual(
            CloudKitSyncEngineDriver.accountChange(
                for: .signOut(previousUser: CKRecord.ID(recordName: "old-user"))),
            .signOut)
        XCTAssertEqual(
            CloudKitSyncEngineDriver.accountChange(for: .switchAccounts(
                previousUser: CKRecord.ID(recordName: "old-user"),
                currentUser: CKRecord.ID(recordName: "new-user"))),
            .switchAccounts)
    }

    func testEstablishedDriverNeverRecreatesZoneBeforeFetch() async throws {
        try store().saveStateSerialization(Data("established-state".utf8), for: account)
        let driver = FakeCloudKitSyncDriver(requiresZoneBootstrap: false)
        driver.onFetch = { [driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.didFetch)
        }
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: store(),
            driver: driver)

        _ = try await adapter.fetchChanges(since: nil)

        XCTAssertEqual(
            driver.orderedOperations,
            [.fetchChanges],
            "an established library must never enqueue or send a replacement zone")
    }

    func testFreshDriverPreparesZoneBeforeFirstRecordSubmit() async throws {
        let offered = wire(
            id: "abababab-abab-4bab-8bab-abababababab", rev: "first-local-record")
        let driver = FakeCloudKitSyncDriver(requiresZoneBootstrap: true)
        driver.onSend = { [driver] in
            await driver.deliver(.sentRecords([
                .accepted(
                    id: offered.id,
                    rev: offered.rev,
                    recordVersion: SyncRecordVersion(Data("first-version".utf8))),
            ]))
            await driver.deliver(.didSend)
        }
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: store(),
            driver: driver)

        _ = try await adapter.submit([offered], at: nil)

        XCTAssertEqual(
            driver.orderedOperations,
            [.bootstrapZone, .completeFirstFetchPreparation, .sendChanges],
            "a fresh local record cannot be sent until custom-zone creation completes")
    }

    func testSchemaTwoCloudKitTokenGetsOneFullResyncThenWritesSchemaThreeCursorFence() async throws {
        let paths = try makeEnginePaths("legacy-cloudkit-cursor")
        let legacyCursor = SyncCursor("legacy-ckserver-change-token-sentinel")
        try writeSchemaTwoBase(
            cursor: legacyCursor,
            accountIdentity: account,
            to: paths.baseURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: paths.journalURL,
            temporaryDirectory: paths.temporaryDirectory)

        // With no restored scheduler serialization, a legacy Core cursor may safely
        // migrate through a genuinely fresh CKSyncEngine epoch. The separate
        // incompatible-cursor test fences the unsafe non-nil serialization case.
        try store().resetAfterAccountReview(for: account)
        let fixture = try makeAdapter()
        fixture.driver.onFetch = { [adapter = fixture.adapter] in
            try await adapter.handle(.willFetch)
            try await adapter.handle(.stateUpdate(Data("first-cksync-state".utf8)))
            try await adapter.handle(.didFetch)
        }

        let migrationFetch = try await fixture.adapter.fetchChanges(since: legacyCursor)
        XCTAssertTrue(migrationFetch.isFullResync)
        let syntheticCursor = try XCTUnwrap(migrationFetch.cursor)
        XCTAssertNotNil(CloudKitSyncCursor.decode(syntheticCursor))

        // The inbox stays durable, so the real domain round consumes exactly that first
        // snapshot without making a second CloudKit request.
        let engine = makeEngine(
            transport: fixture.adapter,
            library: AdapterLibrary(),
            sealer: AdapterPassthroughSealer(),
            paths: paths)
        guard case .idle = await engine.sync() else {
            return XCTFail("legacy cursor migration should complete its full-resync round")
        }
        XCTAssertEqual(fixture.driver.manualCalls, [.fetchChanges])

        let migratedBytes = try Data(contentsOf: paths.baseURL)
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedBytes) as? [String: Any])
        XCTAssertEqual(migratedObject["schemaVersion"] as? Int, 3)
        XCTAssertEqual(
            migratedObject["cursorKind"] as? String,
            "cloudKitSyncEngine")
        XCTAssertEqual(migratedObject["cursor"] as? String, syntheticCursor.rawValue)

        let migrated = try loadedBase(at: paths.baseURL)
        XCTAssertEqual(migrated.cursor, syntheticCursor)
        XCTAssertThrowsError(try JSONDecoder().decode(
            SchemaTwoSyncBaseReader.self, from: migratedBytes))
    }

    func testPendingAddIsOneUntrackedWakeupAndNeverASecondOutbox() async throws {
        let fixture = try makeAdapter()

        fixture.adapter.localChangesAvailable()
        fixture.adapter.localChangesAvailable()
        fixture.adapter.localChangesAvailable()

        XCTAssertTrue(fixture.driver.hasPendingUntrackedChanges)
        XCTAssertTrue(fixture.driver.pendingRecordZoneChanges.isEmpty,
                      "SyncJournal remains the only durable outbound source")
    }

    func testSubmitUsesImmutableLeaseDedupesBatchAndSavesTombstone() async throws {
        let live = wire(id: "99999999-9999-4999-8999-999999999999", rev: "live")
        let tombstone = wire(
            id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", rev: "deleted", deleted: true)
        let fixture = try makeAdapter()
        let observedBatches = LockedBox<[CloudKitRecordZoneChangeBatch]>([])
        fixture.driver.onSend = { [adapter = fixture.adapter] in
            let firstValue = adapter.nextRecordZoneChangeBatch(scope: .all, limit: 200)
            let first = try XCTUnwrap(firstValue)
            let repeatedValue = adapter.nextRecordZoneChangeBatch(
                scope: .all, limit: 200)
            let repeated = try XCTUnwrap(repeatedValue)
            observedBatches.set([first, repeated])
            try await adapter.handle(.sentRecords([
                .accepted(
                    id: tombstone.id, rev: tombstone.rev,
                    recordVersion: SyncRecordVersion(Data("V-delete".utf8))),
                .accepted(
                    id: live.id, rev: live.rev,
                    recordVersion: SyncRecordVersion(Data("V-live".utf8))),
            ]))
            try await adapter.handle(.didSend)
        }

        let submission = try await fixture.adapter.submit([live, tombstone], at: nil)
        let batches = observedBatches.value

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0], batches[1],
                       "the active lease is immutable when CKSyncEngine asks again")
        XCTAssertEqual(batches[0].recordsToSave, [live, tombstone])
        XCTAssertTrue(batches[0].recordIDsToDelete.isEmpty,
                      "a snippet deletion is a saved tombstone, never CK physical delete")
        XCTAssertEqual(submission.results.map(\.id), [live.id, tombstone.id],
                       "sent results are matched by UUID, not callback order")
    }

    func testAwaitedProductionHandlerCommitsFetchBeforeManualFetchReturns() async throws {
        let remote = wire(
            id: "10101010-1010-4010-8010-101010101010", rev: "awaited-fetch")
        let fixture = try makeAdapter()
        fixture.driver.onFetch = { [driver = fixture.driver] in
            await driver.deliver(.willFetch)
            await driver.deliver(.fetchedRecords([remote], physicalDeletionCount: 0))
            await driver.deliver(.stateUpdate(Data("awaited-fetch-state".utf8)))
            await driver.deliver(.didFetch)
        }

        let fetched = try await fixture.adapter.fetchChanges(since: nil)

        XCTAssertEqual(fetched.records, [remote])
        XCTAssertEqual(fetched.cursorKind, .cloudKitSyncEngine)
        XCTAssertEqual(
            try loadedCheckpoint().serialization,
            Data("awaited-fetch-state".utf8),
            "manual fetch may return only after its awaited delegate callback is durable")
    }

    func testAwaitedProductionHandlerFinishesSendBeforeManualSendReturns() async throws {
        let offered = wire(
            id: "20202020-2020-4020-8020-202020202020", rev: "awaited-send")
        let acceptedVersion = SyncRecordVersion(Data("awaited-send-version".utf8))
        let fixture = try makeAdapter()
        fixture.driver.onSend = { [adapter = fixture.adapter, driver = fixture.driver] in
            let batch = try XCTUnwrap(
                adapter.nextRecordZoneChangeBatch(scope: .all, limit: 200))
            XCTAssertEqual(batch.recordsToSave, [offered])
            await driver.deliver(.sentRecords([
                .accepted(
                    id: offered.id,
                    rev: offered.rev,
                    recordVersion: acceptedVersion),
            ]))
            await driver.deliver(.didSend)
        }

        let submission = try await fixture.adapter.submit([offered], at: nil)

        XCTAssertEqual(submission.results, [
            SyncSubmitResult(
                id: offered.id,
                outcome: .accepted(
                    rev: offered.rev,
                    recordVersion: acceptedVersion)),
        ], "manual send may return only after its awaited delegate result is consumed")
    }

    func testTransientFetchOperationFailureRejectsOnlyCurrentOperation() async throws {
        let recovered = wire(
            id: "30303030-3030-4030-8030-303030303030", rev: "recovered-fetch")
        let fixture = try makeAdapter()
        let attempts = LockedBox(0)
        fixture.driver.onFetch = { [driver = fixture.driver] in
            let attempt = attempts.update { value in
                value += 1
                return value
            }
            if attempt == 1 {
                await driver.deliver(.operationFailed(
                    .unreachable(detail: "one-shot fetch outage")))
                return
            }
            await driver.deliver(.willFetch)
            await driver.deliver(.fetchedRecords([recovered], physicalDeletionCount: 0))
            await driver.deliver(.stateUpdate(Data("recovered-fetch-state".utf8)))
            await driver.deliver(.didFetch)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }
        let fetched = try await fixture.adapter.fetchChanges(since: nil)

        XCTAssertEqual(fetched.records, [recovered])
        XCTAssertEqual(fixture.driver.manualCalls, [.fetchChanges, .fetchChanges])
        XCTAssertEqual(fixture.driver.cancelCount, 0,
                       "a retryable operation failure must not poison CKSyncEngine")
    }

    func testTransientFailureAfterR1S1CannotDropPrefixOrContinueFromInMemoryS1() async throws {
        try store().saveStateSerialization(Data("S0-durable".utf8), for: account)
        let remote = wire(
            id: "31313131-3131-4131-8131-313131313131", rev: "R1-before-failure")
        let fixture = try makeAdapter()
        let attempts = LockedBox(0)
        fixture.driver.onFetch = { [driver = fixture.driver] in
            let attempt = attempts.update { value in
                value += 1
                return value
            }
            if attempt == 1 {
                await driver.deliver(.willFetch)
                await driver.deliver(.fetchedRecords([remote], physicalDeletionCount: 0))
                await driver.deliver(.stateUpdate(Data("S1-in-memory".utf8)))
                await driver.deliver(.operationFailed(
                    .unreachable(detail: "transient after R1/S1")))
                return
            }
            await driver.deliver(.willFetch)
            await driver.deliver(.fetchedRecords([remote], physicalDeletionCount: 0))
            await driver.deliver(.stateUpdate(Data("S1-replayed".utf8)))
            await driver.deliver(.didFetch)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }

        let afterFailure = try loadedCheckpoint()
        XCTAssertEqual(afterFailure.serialization, Data("S0-durable".utf8),
                       "failed transaction cannot publish S1 without its complete prefix")
        XCTAssertTrue(afterFailure.generations.isEmpty,
                      "R1 is either atomically durable with S1 or must replay from S0")
        XCTAssertEqual(fixture.driver.cancelCount, 1,
                       "the engine holding in-memory S1 must be poisoned before retry")
        XCTAssertEqual(fixture.driver.restartSerializations, [Data("S0-durable".utf8)],
                       "retry must reconstruct scheduling from the last durable state")

        let retried = try await fixture.adapter.fetchChanges(since: nil)

        XCTAssertEqual(retried.records, [remote],
                       "the R1 prefix must survive exactly once through durable replay")
        XCTAssertEqual(try loadedCheckpoint().generations.first?.records, [remote])
        XCTAssertEqual(fixture.driver.manualCalls, [.fetchChanges, .fetchChanges])
    }

    func testShutdownPreventsLateRestartAfterSuspendedCallbackRecoveryCancellation() async throws {
        let durableState = Data("shutdown-before-late-restart-S0".utf8)
        try store().saveStateSerialization(durableState, for: account)
        let remote = wire(
            id: "32323232-3232-4232-8232-323232323232",
            rev: "late-restart-race")
        let fixture = try makeAdapter()
        let recoveryCancellationGate = TransportReplacementGate()
        let cancellationCalls = LockedBox(0)
        let recoveryCancellationStarted = LockedBox(false)
        let recoveryCancellationReturned = LockedBox(false)
        let shutdownCancellationCompleted = LockedBox(false)
        let shutdownFinished = LockedBox(false)
        defer { recoveryCancellationGate.open() }

        // Cancellation call one belongs to restartAfterCallback recovery and remains
        // suspended. Shutdown must stop the lifecycle, wait for that registered
        // maintenance, and only then enter cancellation call two.
        fixture.driver.onCancel = {
            let call = cancellationCalls.update { value in
                value += 1
                return value
            }
            if call == 1 {
                recoveryCancellationStarted.set(true)
                await recoveryCancellationGate.wait()
                recoveryCancellationReturned.set(true)
            } else if call == 2 {
                shutdownCancellationCompleted.set(true)
            }
        }

        // Advancing a scheduler transaction before a transient failure creates a
        // rollback request and schedules restartAfterCallback on the real adapter.
        await fixture.driver.deliver(.willFetch)
        await fixture.driver.deliver(
            .fetchedRecords([remote], physicalDeletionCount: 0))
        await fixture.driver.deliver(.stateUpdate(Data("in-memory-S1".utf8)))
        await fixture.driver.deliver(
            .operationFailed(.unreachable(detail: "suspend recovery cancellation")))
        let recoveryReachedCancellation = await eventually {
            recoveryCancellationStarted.value
        }
        XCTAssertTrue(recoveryReachedCancellation)
        XCTAssertTrue(fixture.driver.restartSerializations.isEmpty)

        let shutdown = Task {
            await fixture.adapter.shutdown()
            shutdownFinished.set(true)
        }
        let shutdownReachedStopFence = await eventually {
            fixture.driver.invalidationCount == 2
        }
        XCTAssertTrue(
            shutdownReachedStopFence,
            "shutdown must stop accepting work before waiting on recovery maintenance")
        for _ in 0..<100 { await Task.yield() }

        XCTAssertFalse(
            shutdownFinished.value,
            "shutdown must await the already registered recovery cancellation")
        XCTAssertFalse(shutdownCancellationCompleted.value)
        XCTAssertFalse(recoveryCancellationReturned.value)
        XCTAssertEqual(
            cancellationCalls.value,
            1,
            "shutdown's final cancellation must remain behind recovery maintenance")
        XCTAssertTrue(fixture.driver.restartSerializations.isEmpty)

        // The delayed recovery now returns from cancelOperations after shutdown. Its
        // restart request must be consumed as a no-op by the stopped lifecycle gate;
        // shutdown can then drain maintenance and perform its final cancellation.
        recoveryCancellationGate.open()
        let recoveryReturned = await eventually { recoveryCancellationReturned.value }
        XCTAssertTrue(recoveryReturned)
        await shutdown.value

        XCTAssertTrue(shutdownFinished.value)
        XCTAssertTrue(shutdownCancellationCompleted.value)
        XCTAssertEqual(cancellationCalls.value, 2)
        XCTAssertTrue(
            fixture.driver.restartSerializations.isEmpty,
            "a callback recovery task must never construct an engine after shutdown")
        await fixture.driver.deliver(.stateUpdate(Data("post-shutdown-state".utf8)))
        XCTAssertEqual(fixture.driver.ignoredLateEventCount, 1)
        XCTAssertEqual(try loadedCheckpoint().serialization, durableState)
    }

    func testLifecycleGateStopDeterministicallyRejectsLateRecoveryRestart() async {
        let lifecycle = CloudKitAdapterLifecycleGate()
        let recoveryCancellationGate = TransportReplacementGate()
        let recoveryCancellationStarted = LockedBox(false)
        let shutdownCancellationCompleted = LockedBox(false)
        let restartCount = LockedBox(0)
        defer { recoveryCancellationGate.open() }

        let recovery = Task {
            recoveryCancellationStarted.set(true)
            await recoveryCancellationGate.wait()
            return lifecycle.restartIfActive {
                restartCount.update { $0 += 1 }
            }
        }
        let cancellationStarted = await eventually {
            recoveryCancellationStarted.value
        }
        XCTAssertTrue(cancellationStarted)

        lifecycle.stop()
        shutdownCancellationCompleted.set(true)
        XCTAssertTrue(shutdownCancellationCompleted.value)
        XCTAssertFalse(lifecycle.acceptsEvents)

        recoveryCancellationGate.open()
        let didRestart = await recovery.value

        XCTAssertFalse(didRestart)
        XCTAssertEqual(restartCount.value, 0)
        XCTAssertFalse(lifecycle.acceptsEvents)
    }

    func testTransientSendOperationFailureAbortsLeaseAndNextSendRecovers() async throws {
        let offered = wire(
            id: "40404040-4040-4040-8040-404040404040", rev: "recovered-send")
        let fixture = try makeAdapter()
        let attempts = LockedBox(0)
        fixture.driver.onSend = { [adapter = fixture.adapter, driver = fixture.driver] in
            let batch = try XCTUnwrap(
                adapter.nextRecordZoneChangeBatch(scope: .all, limit: 200))
            XCTAssertEqual(batch.recordsToSave, [offered])
            let attempt = attempts.update { value in
                value += 1
                return value
            }
            if attempt == 1 {
                await driver.deliver(.operationFailed(
                    .rejected(.rateLimited(retryAfter: 12))))
                return
            }
            await driver.deliver(.sentRecords([
                .accepted(
                    id: offered.id,
                    rev: offered.rev,
                    recordVersion: SyncRecordVersion(Data("recovered-version".utf8))),
            ]))
            await driver.deliver(.didSend)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.submit([offered], at: nil)
        }
        let recovered = try await fixture.adapter.submit([offered], at: nil)

        XCTAssertEqual(recovered.results.map(\.id), [offered.id])
        XCTAssertEqual(fixture.driver.manualCalls, [.sendChanges, .sendChanges])
        XCTAssertEqual(fixture.driver.cancelCount, 0)
    }

    func testPerRecordRetryUsesExactEarliestDelayAndEmitsOneCoalescedWake() async throws {
        let first = wire(
            id: "41414141-4141-4141-8141-414141414141", rev: "rate-limit-first")
        let second = wire(
            id: "42424242-4242-4242-8242-424242424242", rev: "rate-limit-second")
        let sleeper = RetrySleeperProbe()
        let fixture = try makeAdapter(retrySleeper: { delay in
            try await sleeper.sleep(delay)
        })
        fixture.driver.onSend = { [adapter = fixture.adapter, driver = fixture.driver] in
            let batch = try XCTUnwrap(
                adapter.nextRecordZoneChangeBatch(scope: .all, limit: 200))
            XCTAssertEqual(batch.recordsToSave, [first, second])
            await driver.deliver(.sentRecords([
                .rejected(id: first.id, rejection: .rateLimited(retryAfter: 37)),
                .rejected(id: second.id, rejection: .rateLimited(retryAfter: 12)),
            ]))
            await driver.deliver(.didSend)
        }
        let recordedEvents = LockedBox<[SyncTransportEvent]>([])
        let eventTask = Task {
            for await event in fixture.adapter.events {
                recordedEvents.update { $0.append(event) }
            }
        }
        defer { eventTask.cancel() }

        let submission = try await fixture.adapter.submit([first, second], at: nil)

        XCTAssertEqual(submission.results.count, 2)
        let didArmEarliestRetry = await eventually { sleeper.delays == [12] }
        XCTAssertTrue(didArmEarliestRetry,
                      "one batch must arm only its earliest backend retry deadline")
        sleeper.resume(0)
        let didEmitRetry = await eventually { recordedEvents.value.count == 1 }
        XCTAssertTrue(didEmitRetry)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recordedEvents.value, [.changesAvailable],
                       "the one-shot wake must not manufacture duplicate replays")
    }

    func testSuccessfulSubmissionCancelsPendingPerRecordRetry() async throws {
        let offered = wire(
            id: "43434343-4343-4343-8343-434343434343", rev: "retry-then-success")
        let sleeper = RetrySleeperProbe()
        let fixture = try makeAdapter(retrySleeper: { delay in
            try await sleeper.sleep(delay)
        })
        let attempts = LockedBox(0)
        fixture.driver.onSend = { [adapter = fixture.adapter, driver = fixture.driver] in
            _ = try XCTUnwrap(
                adapter.nextRecordZoneChangeBatch(scope: .all, limit: 200))
            let attempt = attempts.update { value in
                value += 1
                return value
            }
            if attempt == 1 {
                await driver.deliver(.sentRecords([
                    .rejected(id: offered.id, rejection: .rateLimited(retryAfter: 9)),
                ]))
            } else {
                await driver.deliver(.sentRecords([
                    .accepted(
                        id: offered.id,
                        rev: offered.rev,
                        recordVersion: SyncRecordVersion(Data("success-version".utf8))),
                ]))
            }
            await driver.deliver(.didSend)
        }
        let recordedEvents = LockedBox<[SyncTransportEvent]>([])
        let eventTask = Task {
            for await event in fixture.adapter.events {
                recordedEvents.update { $0.append(event) }
            }
        }
        defer { eventTask.cancel() }

        _ = try await fixture.adapter.submit([offered], at: nil)
        let didArmRetry = await eventually { sleeper.delays == [9] }
        XCTAssertTrue(didArmRetry)
        let recovered = try await fixture.adapter.submit([offered], at: nil)
        XCTAssertEqual(recovered.results.map(\.id), [offered.id])

        sleeper.resume(0)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(recordedEvents.value.isEmpty,
                      "success must cancel the stale retry before its sleeper returns")
    }

    func testTerminalAccountEventCancelsPendingPerRecordRetry() async throws {
        let offered = wire(
            id: "44434343-4343-4343-8343-434343434344", rev: "retry-then-account")
        let sleeper = RetrySleeperProbe()
        let fixture = try makeAdapter(retrySleeper: { delay in
            try await sleeper.sleep(delay)
        })
        fixture.driver.onSend = { [driver = fixture.driver] in
            await driver.deliver(.sentRecords([
                .rejected(id: offered.id, rejection: .rateLimited(retryAfter: 8)),
            ]))
            await driver.deliver(.didSend)
        }
        let recordedEvents = LockedBox<[SyncTransportEvent]>([])
        let eventTask = Task {
            for await event in fixture.adapter.events {
                recordedEvents.update { $0.append(event) }
            }
        }
        defer { eventTask.cancel() }

        _ = try await fixture.adapter.submit([offered], at: nil)
        let didArmRetry = await eventually { sleeper.delays == [8] }
        XCTAssertTrue(didArmRetry)
        await fixture.driver.deliver(.accountChange(.switchAccounts))
        let didEmitTerminalEvent = await eventually { recordedEvents.value.count == 1 }
        XCTAssertTrue(didEmitTerminalEvent)

        sleeper.resume(0)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(recordedEvents.value, [.changesAvailable],
                       "the terminal notification is immediate; its cancelled retry must not fire")
        XCTAssertEqual(fixture.driver.cancelCount, 1)
    }

    func testAccountChangeViaProductionHandlerPoisonsDataPlaneAndCancels() async throws {
        try store().saveStateSerialization(Data("account-A-state".utf8), for: account)
        let fixture = try makeAdapter()
        let late = wire(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", rev: "late")

        await fixture.driver.deliver(.willFetch)
        await fixture.driver.deliver(.fetchedRecords([late], physicalDeletionCount: 0))
        await fixture.driver.deliver(.stateUpdate(Data("must-not-land".utf8)))
        await fixture.driver.deliver(.accountChange(.switchAccounts))

        XCTAssertEqual(try loadedCheckpoint().serialization, Data("account-A-state".utf8))
        XCTAssertTrue(try loadedCheckpoint().generations.isEmpty)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.submit([late], at: nil)
        }
        XCTAssertEqual(fixture.driver.cancelCount, 1)
        XCTAssertEqual(fixture.driver.manualCalls, [],
                       "a sticky failure must reject before invoking CKSyncEngine again")
    }

    func testPermanentOperationFailureViaProductionHandlerIsStickyAndCancels() async throws {
        let fixture = try makeAdapter()
        let offered = wire(
            id: "50505050-5050-4050-8050-505050505050", rev: "permanent")

        await fixture.driver.deliver(.operationFailed(
            .rejected(.permanent(detail: "schema rejected"))))

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.submit([offered], at: nil)
        }
        XCTAssertEqual(fixture.driver.cancelCount, 1)
        XCTAssertEqual(fixture.driver.manualCalls, [])
    }

    func testZoneDeletionViaProductionHandlerIsStickyAndCancels() async throws {
        let fixture = try makeAdapter()
        let offered = wire(
            id: "60606060-6060-4060-8060-606060606060", rev: "invalid-zone")

        await fixture.driver.deliver(.remoteDataLoss(.zoneDeleted))

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.fetchChanges(since: nil)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.adapter.submit([offered], at: nil)
        }
        XCTAssertEqual(fixture.driver.cancelCount, 1)
        XCTAssertEqual(fixture.driver.manualCalls, [])
    }

    func testTerminalDelegateCallbacksNeverReenterDriverOperations() async throws {
        let terminalEvents: [CloudKitSyncDriverEvent] = [
            .accountChange(.switchAccounts),
            .remoteDataLoss(.zoneDeleted),
            .operationFailed(.rejected(.permanent(detail: "terminal"))),
        ]

        for event in terminalEvents {
            let fixture = try makeAdapter()
            let checkpointBeforeTerminal = try Data(contentsOf: checkpointURL)
            await fixture.driver.deliver(event)

            XCTAssertEqual(fixture.driver.invalidationCount, 1,
                           "every terminal event must synchronously poison one driver epoch")
            XCTAssertTrue(
                fixture.driver.invalidatedDuringCallback,
                "engine/provider detachment is local state and must finish before callback return")
            let eventuallyCancelled = await eventually {
                fixture.driver.cancelCount == 1
            }
            XCTAssertTrue(
                eventuallyCancelled,
                "terminal invalidation must still cancel the retired engine after callback return")
            XCTAssertTrue(
                fixture.driver.reentrantOperations.isEmpty,
                "an awaited CKSyncEngine delegate callback may only invalidate state; "
                    + "cancel/send/fetch must happen after that callback unwinds")
            await fixture.driver.deliver(.stateUpdate(Data("late-retired-state".utf8)))
            XCTAssertEqual(fixture.driver.ignoredLateEventCount, 1,
                           "callbacks from the detached epoch must be ignored")
            XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointBeforeTerminal)
            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.adapter.fetchChanges(since: nil)
            }
        }
    }

    func testSingleFlightCancellationQueuesShutdownBehindTerminalCancellation() async {
        let barrier = CloudKitSingleFlightCancellationBarrier()
        let firstCancellationGate = TransportReplacementGate()
        let firstOperationEntered = LockedBox(false)
        let terminalCallerFinished = LockedBox(false)
        let shutdownCallerInvoked = LockedBox(false)
        let shutdownOperationEntered = LockedBox(false)
        let shutdownCallerFinished = LockedBox(false)
        let replacementStarted = LockedBox(false)
        let order = LockedBox<[String]>([])
        defer { firstCancellationGate.open() }

        // Models the fire-and-forget cancellation scheduled by a terminal delegate
        // callback after its CKSyncEngine epoch has been moved to retiredEngines.
        let terminalCancellation = Task {
            await barrier.perform {
                order.update { $0.append("terminal-start") }
                firstOperationEntered.set(true)
                await firstCancellationGate.wait()
                order.update { $0.append("terminal-finish") }
            }
            terminalCallerFinished.set(true)
        }
        let terminalCancellationStarted = await eventually { firstOperationEntered.value }
        XCTAssertTrue(terminalCancellationStarted)

        // Models adapter shutdown's second cancelOperations() call. Replacement may
        // start only after this caller returns from the same production barrier.
        let shutdown = Task {
            shutdownCallerInvoked.set(true)
            await barrier.perform {
                order.update { $0.append("shutdown-start") }
                shutdownOperationEntered.set(true)
                order.update { $0.append("shutdown-finish") }
            }
            shutdownCallerFinished.set(true)
            replacementStarted.set(true)
        }
        let shutdownWasInvoked = await eventually { shutdownCallerInvoked.value }
        XCTAssertTrue(shutdownWasInvoked)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertFalse(terminalCallerFinished.value)
        XCTAssertFalse(
            shutdownOperationEntered.value,
            "shutdown must join the already in-flight retired-engine cancellation")
        XCTAssertFalse(shutdownCallerFinished.value)
        XCTAssertFalse(
            replacementStarted.value,
            "a replacement CKSyncEngine must not start while terminal cancellation is in flight")
        XCTAssertEqual(order.value, ["terminal-start"])

        firstCancellationGate.open()
        await terminalCancellation.value
        await shutdown.value

        XCTAssertTrue(terminalCallerFinished.value)
        XCTAssertTrue(shutdownCallerFinished.value)
        XCTAssertTrue(replacementStarted.value)
        XCTAssertEqual(
            order.value,
            ["terminal-start", "terminal-finish", "shutdown-start", "shutdown-finish"],
            "cancellation maintenance must complete in FIFO order")
    }

    func testAdapterShutdownJoinsFireAndForgetTerminalCancellation() async throws {
        let driver = FakeCloudKitSyncDriver()
        let cancellation = SingleFlightCancellationProbe()
        driver.onCancel = { await cancellation.cancel() }
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: store(),
            driver: driver)
        let shutdownFinished = LockedBox(false)
        let replacementStarted = LockedBox(false)
        defer { cancellation.releaseFirstCancellation() }

        // The terminal callback returns before its scheduled cancellation finishes.
        await driver.deliver(.accountChange(.switchAccounts))
        let terminalCancellationStarted = await eventually {
            cancellation.operationStartCount == 1
        }
        XCTAssertTrue(terminalCancellationStarted)

        let shutdown = Task {
            await adapter.shutdown()
            shutdownFinished.set(true)
            replacementStarted.set(true)
        }
        let shutdownReachedStopFence = await eventually {
            driver.invalidationCount == 2
        }
        XCTAssertTrue(
            shutdownReachedStopFence,
            "shutdown must stop and invalidate before awaiting terminal maintenance")
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(
            driver.cancelCount,
            1,
            "shutdown's final cancellation must wait for terminal maintenance to drain")
        XCTAssertEqual(
            cancellation.operationStartCount,
            1,
            "only the terminal drain may start before its cancellation is released")
        XCTAssertFalse(shutdownFinished.value)
        XCTAssertFalse(replacementStarted.value)

        cancellation.releaseFirstCancellation()
        await shutdown.value

        XCTAssertTrue(shutdownFinished.value)
        XCTAssertTrue(replacementStarted.value)
        XCTAssertEqual(driver.cancelCount, 2)
        XCTAssertEqual(cancellation.operationStartCount, 2)
        XCTAssertEqual(cancellation.operationCompletionCount, 2)
        XCTAssertEqual(
            cancellation.order,
            ["cancel-1-start", "cancel-1-finish", "cancel-2-start", "cancel-2-finish"])
    }

    func testSanitizedCloudKitFailureCannotReachDurableHaltText() async throws {
        let canary = "private-record-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let error = CKError(
            .missingEntitlement,
            userInfo: [NSLocalizedDescriptionKey: canary])
        let fixture = try makeAdapter()
        await fixture.driver.deliver(
            .operationFailed(CloudKitErrorMapping.failure(for: error)))
        let paths = try makeEnginePaths("sanitized-cloudkit-error")
        let engine = makeEngine(
            transport: fixture.adapter,
            library: AdapterLibrary(),
            sealer: AdapterPassthroughSealer(),
            paths: paths)

        let state = await engine.sync()

        guard case .halted(_, let detail) = state else {
            return XCTFail("the permanent CloudKit failure must remain a sticky halt")
        }
        XCTAssertFalse(detail.contains(canary))
        XCTAssertNil(
            try Data(contentsOf: paths.stateURL).range(of: Data(canary.utf8)),
            "CKError localizedDescription/userInfo must never reach durable UI state")
    }

    func testExplicitSyncNowIsImmediatePushFirstThenFetchWhileAutomaticSchedulingStaysOn() async throws {
        let fixture = try makeAdapter()

        try await fixture.adapter.syncNow()

        XCTAssertEqual(fixture.driver.manualCalls, [.sendChanges, .fetchChanges])
        XCTAssertTrue(fixture.driver.automaticallySync)
    }

    func testSyncEngineMutationDuringSendKeepsAThenReplaysBWithACASVersion() async throws {
        let paths = try makeEnginePaths("mutation-during-send")
        let library = AdapterLibrary()
        let sealer = AdapterPassthroughSealer()
        let id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let offeredA = envelope(id: id, content: "A", milliseconds: 100)
        let desiredB = envelope(id: id, content: "B", milliseconds: 200)
        library.envelopes[offeredA.id] = offeredA
        let fixture = try makeAdapter()
        fixture.driver.onSend = { [adapter = fixture.adapter, driver = fixture.driver] in
            let batchValue = adapter.nextRecordZoneChangeBatch(scope: .all, limit: 200)
            let batch = try XCTUnwrap(batchValue)
            driver.record(batch)
            if driver.observedBatches.count == 1 {
                await MainActor.run { library.envelopes[offeredA.id] = desiredB }
            }
            let accepted = batch.recordsToSave.map { record in
                CloudKitSentResult.accepted(
                    id: record.id,
                    rev: record.rev,
                    recordVersion: SyncRecordVersion(Data("server-\(record.rev)".utf8)))
            }
            try await adapter.handle(.sentRecords(accepted))
            try await adapter.handle(.didSend)
        }
        fixture.driver.onFetch = { [adapter = fixture.adapter] in
            try await adapter.handle(.willFetch)
            try await adapter.handle(.stateUpdate(Data("empty-fetch-state".utf8)))
            try await adapter.handle(.didFetch)
        }
        let engine = makeEngine(
            transport: fixture.adapter,
            library: library,
            sealer: sealer,
            paths: paths)

        _ = await engine.sync()

        let firstWire = try XCTUnwrap(fixture.driver.observedBatches.first?.recordsToSave.first)
        XCTAssertEqual(try WireCodec.open(firstWire, using: sealer), offeredA)
        let afterFirst = try loadedJournal(at: paths.journalURL)
        XCTAssertNil(afterFirst.entry(offeredA.id)?.offered)
        XCTAssertEqual(afterFirst.entry(offeredA.id)?.desired, desiredB,
                       "ACK A must not acknowledge B observed while send was in flight")

        _ = await engine.sync()

        XCTAssertEqual(fixture.driver.observedBatches.count, 2)
        let secondWire = try XCTUnwrap(fixture.driver.observedBatches[1].recordsToSave.first)
        XCTAssertEqual(try WireCodec.open(secondWire, using: sealer), desiredB)
        XCTAssertEqual(
            secondWire.recordVersion,
            SyncRecordVersion(Data("server-\(firstWire.rev)".utf8)),
            "B must replace exactly the server generation returned for A")
    }

    func testCrashRestartResubmitsFrozenAByteForByteEvenWhenLibraryNowContainsB() async throws {
        let paths = try makeEnginePaths("crash-restart")
        let library = AdapterLibrary()
        let sealer = AdapterPassthroughSealer()
        let id = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let offeredA = envelope(id: id, content: "A", milliseconds: 100)
        let desiredB = envelope(id: id, content: "B", milliseconds: 200)
        library.envelopes[offeredA.id] = offeredA
        let firstProcess = try makeAdapter()
        firstProcess.driver.onSend = { [adapter = firstProcess.adapter,
                                       driver = firstProcess.driver] in
            let batchValue = adapter.nextRecordZoneChangeBatch(scope: .all, limit: 200)
            let batch = try XCTUnwrap(batchValue)
            driver.record(batch)
            throw SyncTransportFailure.unreachable(detail: "simulated process loss")
        }
        let firstEngine = makeEngine(
            transport: firstProcess.adapter,
            library: library,
            sealer: sealer,
            paths: paths)

        _ = await firstEngine.sync()
        let frozenWire = try XCTUnwrap(
            firstProcess.driver.observedBatches.first?.recordsToSave.first)
        library.envelopes[offeredA.id] = desiredB
        XCTAssertNotNil(try loadedJournal(at: paths.journalURL).entry(offeredA.id)?.offered)

        let restartedProcess = try makeAdapter()
        restartedProcess.driver.onSend = { [adapter = restartedProcess.adapter,
                                           driver = restartedProcess.driver] in
            let batchValue = adapter.nextRecordZoneChangeBatch(scope: .all, limit: 200)
            let batch = try XCTUnwrap(batchValue)
            driver.record(batch)
            throw SyncTransportFailure.unreachable(detail: "stop after observing replay")
        }
        let restartedEngine = makeEngine(
            transport: restartedProcess.adapter,
            library: library,
            sealer: sealer,
            paths: paths)

        _ = await restartedEngine.sync()

        XCTAssertEqual(
            restartedProcess.driver.observedBatches.first?.recordsToSave,
            [frozenWire],
            "restart retries the journal offer A exactly; newer desired B waits for ACK/refetch")
    }

    func testAccountReviewReplacementAwaitsRetiredEngineShutdown() async throws {
        try await assertTransportReplacementAwaitsRetiredEngine(.accountReview)
    }

    func testCheckpointReviewReplacementAwaitsRetiredEngineShutdown() async throws {
        try await assertTransportReplacementAwaitsRetiredEngine(.checkpointReview)
    }

    func testLocalFullResyncReplacementAwaitsRetiredEngineShutdown() async throws {
        try await assertTransportReplacementAwaitsRetiredEngine(.localFullResync)
    }

    func testAccountNotificationPreflightAwaitsRetiredEngineShutdown() async throws {
        try await assertTransportReplacementAwaitsRetiredEngine(.accountNotification)
    }

    // MARK: - Fixtures

    private enum TransportReplacementTrigger: String {
        case accountReview
        case checkpointReview
        case localFullResync
        case accountNotification
    }

    private func assertTransportReplacementAwaitsRetiredEngine(
        _ trigger: TransportReplacementTrigger
    ) async throws {
        let recordID = CKRecord.ID(recordName: "transport-replacement-test-user")
        let identity = CloudKitAccountIdentity.derive(
            containerIdentifier: CloudKitSchema.containerIdentifier,
            databaseScope: .private,
            environment: .production,
            userRecordID: recordID)
        let checkpointStore = store()
        try checkpointStore.reset(for: identity, allowsZoneBootstrap: false)
        let driverFactory = TransportReplacementDriverFactory()
        let transport = CloudKitTransport(
            accountStatusProvider: { .available },
            userRecordIDProvider: { recordID },
            environmentProvider: { .production },
            checkpointStore: checkpointStore,
            driverProvider: { _, _ in driverFactory.makeDriver() })
        defer { driverFactory.releaseAllBarriers() }

        _ = try await transport.preflightScope()
        _ = try await transport.fetchChanges(since: nil)
        let retired = try XCTUnwrap(driverFactory.firstDriver)
        XCTAssertEqual(driverFactory.constructedDriverCount, 1)
        XCTAssertEqual(driverFactory.startedDriverCount, 1)
        XCTAssertEqual(driverFactory.maximumLiveDriverCount, 1)

        let staleSerialization = Data("stale-retired-\(trigger.rawValue)".utf8)
        let staleCallback = Task {
            await retired.deliverSuspendedStateUpdate(staleSerialization)
        }
        let callbackEntered = await eventually { retired.callbackIsSuspended }
        XCTAssertTrue(callbackEntered)

        if trigger == .accountNotification {
            NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        }
        let workflowFinished = LockedBox(false)
        let replacementWorkflow = Task { @MainActor in
            defer { workflowFinished.set(true) }
            switch trigger {
            case .accountReview:
                try await transport.resetAfterAccountReview()
            case .checkpointReview:
                try await transport.resetAfterCheckpointReview()
            case .localFullResync:
                try await transport.resetForLocalFullResync()
            case .accountNotification:
                _ = try await transport.preflightScope()
            }
            return try await transport.fetchChanges(since: nil)
        }

        let shutdownReachedCallbackFence = await eventually {
            retired.eventHandlerReturnWaitStarted
                || driverFactory.constructedDriverCount > 1
                || workflowFinished.value
        }
        XCTAssertTrue(shutdownReachedCallbackFence)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(
            driverFactory.constructedDriverCount,
            1,
            "\(trigger.rawValue) must not construct an adapter/driver before old shutdown")
        XCTAssertEqual(
            driverFactory.startedDriverCount,
            1,
            "\(trigger.rawValue) must not start a replacement CKSyncEngine early")
        XCTAssertEqual(driverFactory.maximumLiveDriverCount, 1)
        XCTAssertFalse(
            workflowFinished.value,
            "the reset/preflight must remain suspended behind old callback quiescence")

        retired.releaseCallback()
        await staleCallback.value
        let cancellationEntered = await eventually { retired.cancellationIsSuspended }
        XCTAssertTrue(cancellationEntered)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(driverFactory.constructedDriverCount, 1)
        XCTAssertEqual(driverFactory.startedDriverCount, 1)
        XCTAssertEqual(driverFactory.maximumLiveDriverCount, 1)
        XCTAssertFalse(
            workflowFinished.value,
            "replacement must also wait for cancelOperations to return")

        retired.releaseCancellation()
        _ = try await replacementWorkflow.value

        XCTAssertTrue(retired.cancellationCompleted)
        XCTAssertEqual(driverFactory.constructedDriverCount, 2)
        XCTAssertEqual(driverFactory.startedDriverCount, 2)
        XCTAssertEqual(
            driverFactory.maximumLiveDriverCount,
            1,
            "one private database must never own two live CKSyncEngine drivers")
        guard case .loaded(let replacementCheckpoint) = checkpointStore.load(for: identity) else {
            await transport.shutdown()
            return XCTFail("replacement checkpoint must remain readable")
        }
        XCTAssertNotEqual(
            replacementCheckpoint.serialization,
            staleSerialization,
            "the queued callback from the retired adapter must not mutate replacement state")
        await transport.shutdown()
    }

    private struct AdapterFixture {
        let driver: FakeCloudKitSyncDriver
        let adapter: CloudKitSyncTransportAdapter
    }

    private func makeAdapter() throws -> AdapterFixture {
        let driver = FakeCloudKitSyncDriver()
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: store(),
            driver: driver)
        return AdapterFixture(driver: driver, adapter: adapter)
    }

    private func makeAdapter(
        retrySleeper: @escaping @Sendable (TimeInterval) async throws -> Void
    ) throws -> AdapterFixture {
        let driver = FakeCloudKitSyncDriver()
        let adapter = try CloudKitSyncTransportAdapter(
            accountIdentity: account,
            checkpointStore: store(),
            driver: driver,
            retrySleeper: retrySleeper)
        return AdapterFixture(driver: driver, adapter: adapter)
    }

    private func store() -> CloudKitSyncCheckpointStore {
        CloudKitSyncCheckpointStore(
            url: checkpointURL,
            temporaryDirectory: temporaryDirectory,
            cryptor: TestCloudKitSyncCheckpointCryptor(seed: 0xD7))
    }

    private func loadedCheckpoint() throws -> CloudKitSyncCheckpoint {
        guard case .loaded(let checkpoint) = store().load(for: account) else {
            throw OrchestrationTestFailure.missingCheckpoint
        }
        return checkpoint
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func wire(id: String, rev: String, deleted: Bool = false) -> WireRecord {
        WireRecord(
            id: UUID(uuidString: id)!, rev: rev, deleted: deleted,
            blob: Data("blob-\(rev)".utf8),
            recordVersion: SyncRecordVersion(Data("version-\(rev)".utf8)))
    }

    private struct EnginePaths {
        let baseURL: URL
        let journalURL: URL
        let stateURL: URL
        let lockURL: URL
        let temporaryDirectory: URL
    }

    private func makeEnginePaths(_ label: String) throws -> EnginePaths {
        let directory = rootURL.appendingPathComponent(label, isDirectory: true)
        let temporary = directory.appendingPathComponent("Tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        return EnginePaths(
            baseURL: directory.appendingPathComponent("base.json"),
            journalURL: directory.appendingPathComponent("journal.json"),
            stateURL: directory.appendingPathComponent("state.json"),
            lockURL: directory.appendingPathComponent("library.lock"),
            temporaryDirectory: temporary)
    }

    private func makeEngine(
        transport: any SyncTransport,
        library: any SyncLibraryAccess,
        sealer: AdapterPassthroughSealer,
        paths: EnginePaths
    ) -> SyncEngine {
        SyncEngine(
            transport: transport,
            library: library,
            sealer: sealer,
            device: "adapter1",
            baseURL: paths.baseURL,
            journalURL: paths.journalURL,
            stateURL: paths.stateURL,
            lockURL: paths.lockURL,
            temporaryDirectory: paths.temporaryDirectory,
            stateLockTimeout: 0.1)
    }

    private func loadedJournal(at url: URL) throws -> SyncJournal {
        guard case .loaded(let journal) = SyncJournalFile.load(from: url) else {
            throw OrchestrationTestFailure.missingJournal
        }
        return journal
    }

    private func loadedBase(at url: URL) throws -> SyncBase {
        guard case .loaded(let base) = SyncBaseFile.load(from: url) else {
            throw OrchestrationTestFailure.missingBase
        }
        return base
    }

    private func writeSchemaTwoBase(
        cursor: SyncCursor,
        accountIdentity: SyncAccountIdentity,
        to url: URL
    ) throws {
        let encodedIdentity = try JSONEncoder().encode(accountIdentity)
        let identityObject = try JSONSerialization.jsonObject(with: encodedIdentity)
        let object: [String: Any] = [
            "schemaVersion": 2,
            "envelopes": [:],
            "recordVersions": [:],
            "cursor": cursor.rawValue,
            "journalEstablished": true,
            "accountIdentity": identityObject,
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
            .write(to: url)
    }

    private func envelope(
        id: String,
        content: String,
        milliseconds: UInt64
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: UUID(uuidString: id)!,
            hlc: HLC(wallMs: milliseconds, counter: 0, device: "adapter1"),
            origin: "adapter1",
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: content,
                keyword: content,
                content: Data(content.utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)))
    }
}

private enum OrchestrationTestFailure: Error {
    case missingBase
    case missingCheckpoint
    case missingDriverEventHandler
    case missingJournal
}

/// The strict schema fence implemented by the release immediately before CKSyncEngine.
/// Unknown fields alone are not sufficient because synthesized Codable ignores them;
/// the schema bump is what makes this reader reject a synthetic inbox cursor.
private struct SchemaTwoSyncBaseReader: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...2).contains(schemaVersion) else {
            throw OrchestrationTestFailure.missingBase
        }
        _ = try container.decodeIfPresent(SyncCursor.self, forKey: .cursor)
    }
}

private nonisolated final class FakeCloudKitSyncDriver: CloudKitSyncDriving, @unchecked Sendable {
    enum ManualCall: Equatable {
        case sendChanges
        case fetchChanges
    }

    enum DriverOperation: Equatable {
        case bootstrapZone
        case completeFirstFetchPreparation
        case sendChanges
        case fetchChanges
        case cancelOperations
    }

    let automaticallySync = true
    let events = AsyncStream<CloudKitSyncDriverEvent> { _ in }
    private let lock = NSLock()
    private var pendingUntracked = false
    private var calls: [ManualCall] = []
    private var cancellations = 0
    private var batches: [CloudKitRecordZoneChangeBatch] = []
    private var callbackDepth = 0
    private var reentrantOperationsStorage: [DriverOperation] = []
    private var orderedOperationsStorage: [DriverOperation] = []
    private var restartSerializationsStorage: [Data] = []
    private var invalidationCountStorage = 0
    private var invalidatedDuringCallbackStorage = false
    private var acceptsEvents = true
    private var ignoredLateEventCountStorage = 0
    private var eventHandlerReturnWaiters: [CheckedContinuation<Void, Never>] = []
    private let requiresZoneBootstrap: Bool
    private let allowsZoneBootstrapAtCompletion: @Sendable () -> Bool?
    private var allowsZoneBootstrapObservedAtCompletionStorage: Bool?
    private var installedBatchProvider: (@Sendable (
        CloudKitSyncSendScope, Int
    ) async -> CloudKitRecordZoneChangeBatch?)?
    private var installedEventHandler: (@Sendable (
        CloudKitSyncDriverEvent
    ) async -> Void)?

    var onSend: (@Sendable () async throws -> Void)?
    var onFetch: (@Sendable () async throws -> Void)?
    var onCancel: (@Sendable () async -> Void)?

    init(
        requiresZoneBootstrap: Bool = false,
        allowsZoneBootstrapAtCompletion: @escaping @Sendable () -> Bool? = { nil }
    ) {
        self.requiresZoneBootstrap = requiresZoneBootstrap
        self.allowsZoneBootstrapAtCompletion = allowsZoneBootstrapAtCompletion
    }

    /// Deliberately exposed forbidden state: it must stay empty in every test.
    private(set) var pendingRecordZoneChanges: [UUID] = []

    var hasPendingUntrackedChanges: Bool {
        get { lock.withLock { pendingUntracked } }
        set { lock.withLock { pendingUntracked = newValue } }
    }

    var manualCalls: [ManualCall] { lock.withLock { calls } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var observedBatches: [CloudKitRecordZoneChangeBatch] { lock.withLock { batches } }
    var reentrantOperations: [DriverOperation] {
        lock.withLock { reentrantOperationsStorage }
    }
    var orderedOperations: [DriverOperation] { lock.withLock { orderedOperationsStorage } }
    var restartSerializations: [Data] { lock.withLock { restartSerializationsStorage } }
    var invalidationCount: Int { lock.withLock { invalidationCountStorage } }
    var invalidatedDuringCallback: Bool {
        lock.withLock { invalidatedDuringCallbackStorage }
    }
    var ignoredLateEventCount: Int { lock.withLock { ignoredLateEventCountStorage } }
    var allowsZoneBootstrapObservedAtCompletion: Bool? {
        lock.withLock { allowsZoneBootstrapObservedAtCompletionStorage }
    }

    func record(_ batch: CloudKitRecordZoneChangeBatch) {
        lock.withLock { batches.append(batch) }
    }

    func prepareForFirstFetch() async throws {
        guard requiresZoneBootstrap else { return }
        lock.withLock {
            orderedOperationsStorage.append(.bootstrapZone)
            if callbackDepth > 0 { reentrantOperationsStorage.append(.bootstrapZone) }
        }
    }

    func completeFirstFetchPreparation() throws {
        guard requiresZoneBootstrap else { return }
        let observed = allowsZoneBootstrapAtCompletion()
        lock.withLock {
            allowsZoneBootstrapObservedAtCompletionStorage = observed
            orderedOperationsStorage.append(.completeFirstFetchPreparation)
            if callbackDepth > 0 {
                reentrantOperationsStorage.append(.completeFirstFetchPreparation)
            }
        }
    }

    func restart(from stateSerialization: Data?) throws {
        lock.withLock {
            restartSerializationsStorage.append(stateSerialization ?? Data())
            acceptsEvents = true
        }
    }

    func invalidate() {
        lock.withLock {
            invalidationCountStorage += 1
            invalidatedDuringCallbackStorage = callbackDepth > 0
            acceptsEvents = false
        }
    }

    func waitForEventHandlerReturn() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard callbackDepth > 0 else { return true }
                eventHandlerReturnWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func sendChanges() async throws {
        lock.withLock {
            calls.append(.sendChanges)
            orderedOperationsStorage.append(.sendChanges)
            if callbackDepth > 0 { reentrantOperationsStorage.append(.sendChanges) }
        }
        try await onSend?()
    }

    func fetchChanges() async throws {
        lock.withLock {
            calls.append(.fetchChanges)
            orderedOperationsStorage.append(.fetchChanges)
            if callbackDepth > 0 { reentrantOperationsStorage.append(.fetchChanges) }
        }
        try await onFetch?()
    }

    func cancelOperations() async {
        lock.withLock {
            cancellations += 1
            orderedOperationsStorage.append(.cancelOperations)
            if callbackDepth > 0 { reentrantOperationsStorage.append(.cancelOperations) }
        }
        await onCancel?()
    }

    func installBatchProvider(
        _ provider: nonisolated(nonsending) @escaping @Sendable (
            CloudKitSyncSendScope, Int
        ) async -> CloudKitRecordZoneChangeBatch?
    ) {
        lock.withLock { installedBatchProvider = provider }
    }

    func installEventHandler(
        _ handler: nonisolated(nonsending) @escaping @Sendable (
            CloudKitSyncDriverEvent
        ) async -> Void
    ) {
        lock.withLock { installedEventHandler = handler }
    }

    func start() throws {
        guard lock.withLock({ installedBatchProvider != nil }) else {
            throw OrchestrationTestFailure.missingJournal
        }
        guard lock.withLock({ installedEventHandler != nil }) else {
            throw OrchestrationTestFailure.missingDriverEventHandler
        }
    }

    /// Matches the production driver's serial delegate: the callback is awaited before
    /// the enclosing manual send/fetch operation is allowed to return.
    func deliver(_ event: CloudKitSyncDriverEvent) async {
        let handler = lock.withLock { () -> (
            @Sendable (CloudKitSyncDriverEvent) async -> Void
        )? in
            guard acceptsEvents else {
                ignoredLateEventCountStorage += 1
                return nil
            }
            callbackDepth += 1
            return installedEventHandler
        }
        guard let handler else { return }
        defer {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                callbackDepth -= 1
                guard callbackDepth == 0 else { return [] }
                let waiters = eventHandlerReturnWaiters
                eventHandlerReturnWaiters.removeAll(keepingCapacity: false)
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
        await handler(event)
    }
}

/// Models one CKSyncEngine per driver. Generation one holds both a callback-return fence
/// and `cancelOperations()` open so CloudKitTransport replacement paths can prove that
/// they await full retirement before invoking their adapter/driver factory again.
private nonisolated final class TransportReplacementDriverFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var drivers: [TransportReplacementDriver] = []
    private var startedCount = 0
    private var liveCount = 0
    private var maximumLiveCount = 0

    var firstDriver: TransportReplacementDriver? { lock.withLock { drivers.first } }
    var constructedDriverCount: Int { lock.withLock { drivers.count } }
    var startedDriverCount: Int { lock.withLock { startedCount } }
    var maximumLiveDriverCount: Int { lock.withLock { maximumLiveCount } }

    func makeDriver() -> any CloudKitSyncDriving {
        let generation = lock.withLock { drivers.count + 1 }
        let driver = TransportReplacementDriver(
            generation: generation,
            factory: self,
            suspendsCancellation: generation == 1)
        lock.withLock { drivers.append(driver) }
        return driver
    }

    func releaseAllBarriers() {
        let current = lock.withLock { drivers }
        current.forEach {
            $0.releaseCallback()
            $0.releaseCancellation()
        }
    }

    fileprivate func driverStarted() {
        lock.withLock {
            startedCount += 1
            liveCount += 1
            maximumLiveCount = max(maximumLiveCount, liveCount)
        }
    }

    fileprivate func driverStopped() {
        lock.withLock { liveCount -= 1 }
    }
}

private nonisolated final class TransportReplacementDriver:
    CloudKitSyncDriving, @unchecked Sendable
{
    let automaticallySync = true
    let events = AsyncStream<CloudKitSyncDriverEvent> { _ in }

    private let generation: Int
    private weak var factory: TransportReplacementDriverFactory?
    private let suspendsCancellation: Bool
    private let callbackGate = TransportReplacementGate()
    private let cancellationGate = TransportReplacementGate()
    private let lock = NSLock()
    private var pending = false
    private var started = false
    private var stopped = false
    private var acceptsEvents = true
    private var callbackSuspendedStorage = false
    private var callbackInFlight = false
    private var handlerReturnWaitStartedStorage = false
    private var handlerReturnWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationSuspendedStorage = false
    private var cancellationCompletedStorage = false
    private var installedEventHandler: (@Sendable (CloudKitSyncDriverEvent) async -> Void)?

    init(
        generation: Int,
        factory: TransportReplacementDriverFactory,
        suspendsCancellation: Bool
    ) {
        self.generation = generation
        self.factory = factory
        self.suspendsCancellation = suspendsCancellation
    }

    var callbackIsSuspended: Bool { lock.withLock { callbackSuspendedStorage } }
    var eventHandlerReturnWaitStarted: Bool {
        lock.withLock { handlerReturnWaitStartedStorage }
    }
    var cancellationIsSuspended: Bool {
        lock.withLock { cancellationSuspendedStorage }
    }
    var cancellationCompleted: Bool {
        lock.withLock { cancellationCompletedStorage }
    }

    var hasPendingUntrackedChanges: Bool {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }

    func prepareForFirstFetch() async throws {}
    func completeFirstFetchPreparation() throws {}
    func restart(from stateSerialization: Data?) throws { _ = stateSerialization }

    func invalidate() {
        lock.withLock { acceptsEvents = false }
    }

    func waitForEventHandlerReturn() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                handlerReturnWaitStartedStorage = true
                guard callbackInFlight else { return true }
                handlerReturnWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func sendChanges() async throws {}
    func fetchChanges() async throws {}

    func cancelOperations() async {
        if suspendsCancellation {
            lock.withLock { cancellationSuspendedStorage = true }
            await cancellationGate.wait()
        }
        let shouldStop = lock.withLock { () -> Bool in
            cancellationSuspendedStorage = false
            cancellationCompletedStorage = true
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldStop { factory?.driverStopped() }
    }

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
        lock.withLock { installedEventHandler = handler }
    }

    func start() throws {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        if shouldStart { factory?.driverStarted() }
    }

    /// Captures the handler before invalidation, exactly like a delegate callback that
    /// was already dequeued by CKSyncEngine when account/reset retirement began.
    func deliverSuspendedStateUpdate(_ serialization: Data) async {
        let handler = lock.withLock { () -> (
            @Sendable (CloudKitSyncDriverEvent) async -> Void
        )? in
            guard acceptsEvents, let installedEventHandler else { return nil }
            callbackInFlight = true
            callbackSuspendedStorage = true
            return installedEventHandler
        }
        guard let handler else { return }
        await callbackGate.wait()
        await handler(.stateUpdate(serialization))
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            callbackInFlight = false
            callbackSuspendedStorage = false
            defer { handlerReturnWaiters.removeAll() }
            return handlerReturnWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func releaseCallback() {
        callbackGate.open()
    }

    func releaseCancellation() {
        cancellationGate.open()
    }
}

private nonisolated final class TransportReplacementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isOpen else { return [] }
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// Runs the fake driver's cancellation bodies through the same production single-flight
/// primitive as CloudKitSyncEngineDriver while keeping the first retired-engine drain
/// suspended. This lets the adapter lifecycle test exercise terminal callback scheduling
/// and shutdown without constructing a real CKContainer or CKSyncEngine.
private nonisolated final class SingleFlightCancellationProbe: @unchecked Sendable {
    private let barrier = CloudKitSingleFlightCancellationBarrier()
    private let firstCancellationGate = TransportReplacementGate()
    private let lock = NSLock()
    private var starts = 0
    private var completions = 0
    private var orderedEvents: [String] = []

    var operationStartCount: Int { lock.withLock { starts } }
    var operationCompletionCount: Int { lock.withLock { completions } }
    var order: [String] { lock.withLock { orderedEvents } }

    func cancel() async {
        await barrier.perform { [self] in
            let operation = lock.withLock { () -> Int in
                starts += 1
                orderedEvents.append("cancel-\(starts)-start")
                return starts
            }
            if operation == 1 { await firstCancellationGate.wait() }
            lock.withLock {
                completions += 1
                orderedEvents.append("cancel-\(operation)-finish")
            }
        }
    }

    func releaseFirstCancellation() {
        firstCancellationGate.open()
    }
}

private nonisolated final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value { lock.withLock { storage } }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }

    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&storage) }
    }
}

private nonisolated final class RetrySleeperProbe: @unchecked Sendable {
    private struct Waiter {
        let delay: TimeInterval
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []

    var delays: [TimeInterval] { lock.withLock { waiters.map(\.delay) } }

    func sleep(_ delay: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                waiters.append(Waiter(delay: delay, continuation: continuation))
            }
        }
    }

    func resume(_ index: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard waiters.indices.contains(index),
                  let continuation = waiters[index].continuation else { return nil }
            waiters[index].continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class AdapterLibrary: SyncLibraryAccess {
    var envelopes: [UUID: SyncEnvelope] = [:]

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        envelopes
    }

    func classifyRemote(_ incoming: [SyncEnvelope]) -> RemoteClassification {
        RemoteClassification(
            applicable: incoming,
            deferredIDs: [],
            incompatibleVaultIDs: [])
    }

    func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
        for envelope in incoming {
            envelopes[envelope.id] = envelope.deleted ? nil : envelope
        }
        return ApplyOutcome(changedIDs: incoming.map(\.id))
    }

    func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
}

@MainActor
private final class BasePersistenceSabotageLibrary: SyncLibraryAccess {
    private let baseURL: URL
    private(set) var readAttempts = 0
    private var envelopes: [UUID: SyncEnvelope] = [:]

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        _ = agreedBase
        readAttempts += 1
        if readAttempts == 2 {
            try FileManager.default.removeItem(at: baseURL)
            try FileManager.default.createDirectory(
                at: baseURL,
                withIntermediateDirectories: false)
        }
        return envelopes
    }

    func classifyRemote(_ incoming: [SyncEnvelope]) -> RemoteClassification {
        RemoteClassification(
            applicable: incoming,
            deferredIDs: [],
            incompatibleVaultIDs: [])
    }

    func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
        for envelope in incoming {
            envelopes[envelope.id] = envelope.deleted ? nil : envelope
        }
        return ApplyOutcome(changedIDs: incoming.map(\.id))
    }

    func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
}

private nonisolated struct AdapterPassthroughSealer: SyncBlobSealing {
    func seal(_ plaintext: Data, for identity: WireIdentity) throws -> Data { plaintext }
    func open(_ ciphertext: Data, for identity: WireIdentity) throws -> Data { ciphertext }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
