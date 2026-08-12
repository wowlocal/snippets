import Darwin
import Foundation
import XCTest

@testable import Snippets

@MainActor
final class SyncSecureConflictDependencyIntegrationTests: XCTestCase {
    private static let sourceID = UUID(
        uuidString: "40000000-0000-4000-8000-000000000001")!
    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"

    private var rootURL: URL!
    private var previousRuntimeSyncOverride: Bool?

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SyncSecureConflictDependencyIntegrationTests-\(UUID().uuidString)",
            isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        SnippetStorageLocations.createAllDirectories()
        previousRuntimeSyncOverride = SyncCoordinator.runtimeEnabledOverride
        SyncCoordinator.runtimeEnabledOverride = nil
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        SyncCoordinator.runtimeEnabledOverride = previousRuntimeSyncOverride
        previousRuntimeSyncOverride = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testMaterializedSecureCopyIsTheOnlySubmissionBeforeSourceCarrierRelease()
        async throws
    {
        let harness = try await makeConflictHarness()
        let projected = try harness.fixture.bridge.currentEnvelopes(
            agreedBase: harness.engine.agreedBase)
        let source = try XCTUnwrap(projected[Self.sourceID])
        XCTAssertEqual(source.x[harness.scenario.variant.extensionKey],
                       harness.scenario.carrierValue)
        XCTAssertNotNil(try loadedVault().record(harness.scenario.variant.copyID),
                        "the real bridge must materialize the deterministic vault copy")
        let beforeCopy = harness.backend.submittedBatches.count

        _ = await harness.engine.sync()

        let batches = try openedBatches(after: beforeCopy, in: harness)
        let copy = try XCTUnwrap(batches.only?.only)
        XCTAssertEqual(copy.id, harness.scenario.variant.copyID)
        XCTAssertFalse(copy.deleted)
        XCTAssertTrue(copy.secure)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            copy,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.id == Self.sourceID },
                       "the carrier source is withheld until the copy ACK is durable")
    }

    func testCopyACKRemovesExactCarrierBeforeSourceSubmissionAndRestartStaysClean()
        async throws
    {
        let harness = try await makeConflictHarness()
        let initialJournal = try loadedJournal()
        let exactC0 = try XCTUnwrap(initialJournal.dependency(Self.sourceID)?
            .requirements[harness.scenario.variant.fingerprint]?.snapshot)
        XCTAssertEqual(
            try loadedVault().localConflictInstallReceipts,
            [harness.scenario.variant.copyID: try exactC0.envelopeHash()])

        _ = await harness.engine.sync()
        XCTAssertNotNil(harness.engine.agreedBase.envelope(harness.scenario.variant.copyID),
                        "the first dependency round must durably confirm the copy")
        let stillCarrying = try XCTUnwrap(
            harness.fixture.bridge.currentEnvelopes(
                agreedBase: harness.engine.agreedBase)[Self.sourceID])
        XCTAssertEqual(stillCarrying.x[harness.scenario.variant.extensionKey],
                       harness.scenario.carrierValue)
        XCTAssertNotNil(try loadedJournal().dependency(Self.sourceID),
                        "C0 ACK alone does not complete the source fence")
        XCTAssertEqual(
            try loadedVault().localConflictInstallReceipts,
            [harness.scenario.variant.copyID: try exactC0.envelopeHash()],
            "the receipt remains live until the journal retires the dependency")
        let beforeSource = harness.backend.submittedBatches.count

        _ = await harness.engine.sync()

        let releaseBatches = try openedBatches(after: beforeSource, in: harness)
        let released = try XCTUnwrap(releaseBatches.only?.only)
        XCTAssertEqual(released.id, Self.sourceID)
        XCTAssertFalse(released.deleted)
        XCTAssertNil(released.x[harness.scenario.variant.extensionKey])
        XCTAssertFalse(SyncMerge.hasUnresolvedContentConflict(released))
        XCTAssertEqual(released.fields?.content, harness.scenario.remotePlainEdit.fields?.content)
        XCTAssertNotNil(try loadedVault().record(harness.scenario.variant.copyID))
        XCTAssertNil(try loadedJournal().dependency(Self.sourceID),
                     "source ACK durably retires the completed dependency")
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, [:],
                       "receipt pruning follows durable dependency retirement")

        let restartedBridge = SnippetLibraryBridge(
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)
        let restarted = makeEngine(
            backend: harness.backend,
            bridge: restartedBridge,
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        let afterRestart = try XCTUnwrap(
            restartedBridge.currentEnvelopes(
                agreedBase: restarted.agreedBase)[Self.sourceID])
        XCTAssertNil(afterRestart.x[harness.scenario.variant.extensionKey])
        XCTAssertFalse(SyncMerge.hasUnresolvedContentConflict(afterRestart))
        let beforeRestartRound = harness.backend.submittedBatches.count

        _ = await restarted.sync()

        XCTAssertEqual(harness.backend.submittedBatches.count, beforeRestartRound,
                       "restart must not restore or resubmit an acknowledged carrier")
        let afterRestartRound = try XCTUnwrap(
            restartedBridge.currentEnvelopes(
                agreedBase: restarted.agreedBase)[Self.sourceID])
        XCTAssertNil(afterRestartRound.x[harness.scenario.variant.extensionKey])
    }

    func testReceiptPruneFailureFollowsDurableDependencyRetirementAndRestartCleansUp()
        async throws
    {
        let harness = try await makeConflictHarness()
        let copyID = harness.scenario.variant.copyID
        let frozenC0 = try XCTUnwrap(loadedJournal().dependency(Self.sourceID)?
            .requirements[harness.scenario.variant.fingerprint]?.snapshot)
        let expectedReceipt = [copyID: try frozenC0.envelopeHash()]
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, expectedReceipt)

        let pruningFailure = ReceiptPruneFailureLibrary(inner: harness.fixture.bridge)
        let engine = makeEngine(
            backend: harness.backend,
            bridge: pruningFailure,
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)

        _ = await engine.sync()
        XCTAssertNotNil(try loadedJournal().dependency(Self.sourceID),
            "C0 ACK retains the edge until the carrier-free source is accepted")
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, expectedReceipt)

        guard case .halted(.localLibraryQuarantined, _) = await engine.sync() else {
            return XCTFail("injected post-journal receipt-prune failure must halt safely")
        }
        XCTAssertEqual(pruningFailure.injectedFailureCount, 1)
        XCTAssertNil(try loadedJournal().dependency(Self.sourceID),
            "dependency retirement must already be durable before receipt pruning runs")
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, expectedReceipt,
            "a failed prune leaves only harmless stale local install evidence")
        XCTAssertNotNil(try loadedVault().record(copyID),
            "receipt cleanup may never remove the preserved conflict copy")

        let submissionsBeforeRestart = harness.backend.submittedBatches.count
        let restarted = makeEngine(
            backend: harness.backend,
            bridge: SnippetLibraryBridge(
                store: harness.fixture.store,
                secureStore: harness.fixture.secureStore),
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        guard case .halted(.localLibraryQuarantined, _) = restarted.state else {
            return XCTFail("restart must retain the explicit safety stop for review")
        }
        restarted.clearHaltAfterUserReview()
        let restartedState = await restarted.sync()

        XCTAssertFalse(restartedState.isHalted)
        XCTAssertNil(try loadedJournal().dependency(Self.sourceID))
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, [:],
            "restart prunes stale receipts against the already-durable empty active set")
        XCTAssertNotNil(try loadedVault().record(copyID))
        XCTAssertEqual(harness.backend.submittedBatches.count, submissionsBeforeRestart,
            "cleanup alone must not reopen or resubmit the completed dependency")
    }

    func testSourceEditsBetweenMaterializationAndCleanupSurviveExactCarrierRemoval()
        async throws
    {
        let harness = try await makeConflictHarness()
        _ = await harness.engine.sync()
        var edited = try XCTUnwrap(harness.fixture.store.snippet(id: Self.sourceID))
        edited.name = "Edited after copy ACK"
        edited.keyword = "latest-source"
        edited.content = "latest body written after materialization"
        edited.tags = ["latest", "user"]
        edited.isEnabled = false
        edited.isPinned = false
        harness.fixture.store.update(edited)
        try harness.fixture.store.flushPendingWritesForSync()
        let beforeSource = harness.backend.submittedBatches.count

        _ = await harness.engine.sync()

        let submitted = try XCTUnwrap(
            openedBatches(after: beforeSource, in: harness).only?.only)
        XCTAssertEqual(submitted.id, Self.sourceID)
        XCTAssertNil(submitted.x[harness.scenario.variant.extensionKey])
        XCTAssertEqual(submitted.fields?.name, edited.name)
        XCTAssertEqual(submitted.fields?.keyword, edited.keyword)
        XCTAssertEqual(submitted.fields?.content, Data(edited.content.utf8))
        XCTAssertEqual(submitted.fields?.tags, edited.tags)
        XCTAssertEqual(submitted.fields?.isEnabled, edited.isEnabled)
        XCTAssertEqual(submitted.fields?.isPinned, edited.isPinned)

        let retained = try XCTUnwrap(harness.fixture.store.snippet(id: Self.sourceID))
        XCTAssertEqual(retained.name, edited.name)
        XCTAssertEqual(retained.keyword, edited.keyword)
        XCTAssertEqual(retained.content, edited.content)
        XCTAssertEqual(retained.tags, edited.tags)
        XCTAssertEqual(retained.isEnabled, edited.isEnabled)
        XCTAssertEqual(retained.isPinned, edited.isPinned)
        let projected = try XCTUnwrap(
            harness.fixture.bridge.currentEnvelopes(
                agreedBase: harness.engine.agreedBase)[Self.sourceID])
        XCTAssertNil(projected.x[harness.scenario.variant.extensionKey])
        XCTAssertFalse(SyncMerge.hasUnresolvedContentConflict(projected))
    }

    func testDeletingSourceAndCopyBeforeACKPublishesLiveCopyThenOrderedTombstones()
        async throws
    {
        let harness = try await makeConflictHarness()
        harness.fixture.store.delete(snippetID: Self.sourceID)
        try harness.fixture.secureStore.delete(id: harness.scenario.variant.copyID)
        XCTAssertNil(harness.fixture.store.snippet(id: Self.sourceID))
        XCTAssertNil(try loadedVault().record(harness.scenario.variant.copyID))
        var offset = harness.backend.submittedBatches.count

        _ = await harness.engine.sync()

        var submitted = try XCTUnwrap(
            openedBatches(after: offset, in: harness).only?.only)
        XCTAssertEqual(submitted.id, harness.scenario.variant.copyID)
        XCTAssertFalse(submitted.deleted,
                       "the journal snapshot must preserve the copy even after local deletion")
        XCTAssertTrue(submitted.secure)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            submitted,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        let sealedCopy = try XCTUnwrap(submitted.fields).content
        XCTAssertEqual(
            try SnippetCrypto.open(
                try XCTUnwrap(String(data: sealedCopy, encoding: .utf8)),
                for: SnippetCrypto.RecordContext(
                    scopeID: harness.scenario.vaultKID,
                    recordID: harness.scenario.variant.copyID),
                keyring: harness.scenario.keyring),
            Data("secure edit that must survive".utf8))

        offset = harness.backend.submittedBatches.count
        _ = await harness.engine.sync()
        submitted = try XCTUnwrap(openedBatches(after: offset, in: harness).only?.only)
        XCTAssertEqual(submitted.id, Self.sourceID)
        XCTAssertTrue(submitted.deleted,
                      "the source tombstone is released only after the live copy ACK")

        offset = harness.backend.submittedBatches.count
        _ = await harness.engine.sync()
        submitted = try XCTUnwrap(openedBatches(after: offset, in: harness).only?.only)
        XCTAssertEqual(submitted.id, harness.scenario.variant.copyID)
        XCTAssertTrue(submitted.deleted,
                      "the copy tombstone waits for the source tombstone ACK")

        let backend = try openedBackend(in: harness)
        XCTAssertEqual(backend[Self.sourceID]?.deleted, true)
        XCTAssertEqual(backend[harness.scenario.variant.copyID]?.deleted, true)
        XCTAssertNil(harness.fixture.store.snippet(id: Self.sourceID))
        XCTAssertNil(try loadedVault().record(harness.scenario.variant.copyID))

        let restartedBridge = SnippetLibraryBridge(
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)
        let restarted = makeEngine(
            backend: harness.backend,
            bridge: restartedBridge,
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        let beforeRestart = harness.backend.submittedBatches.count
        _ = await restarted.sync()
        XCTAssertEqual(harness.backend.submittedBatches.count, beforeRestart)
        XCTAssertNil(harness.fixture.store.snippet(id: Self.sourceID))
        XCTAssertNil(try loadedVault().record(harness.scenario.variant.copyID))
    }

    func testCarrierAndCopyTombstoneInOneFetchPreserveImmutableCopyThroughRestart()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare same-fetch tombstone fixture")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("same-fetch ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("immutable C0 body from same fetch".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let remoteWinner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Same-fetch plain winner",
                keyword: "same-fetch-winner",
                content: "winning body beside a copy tombstone",
                tags: ["same-fetch"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: remoteWinner)
        let carryingSource = try XCTUnwrap(merge.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: carryingSource).only)
        let copyTombstone = SyncEnvelope.tombstone(
            id: variant.copyID,
            secure: true,
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [SyncEnvelope.vaultKeyIDExtensionKey: .string(document.kid)])

        _ = try fixture.bridge.applyRemote([ancestor])
        _ = try await fixture.session.unlock(
            reason: "Materialize carrier before applying its same-fetch tombstone")
        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "same-fetch-carrier-and-copy-tombstone")
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let storedAncestor = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        backend.seed([
            try WireCodec.seal(carryingSource, using: sealer),
            try WireCodec.seal(copyTombstone, using: sealer),
        ])
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)

        let fetched = await engine.sync()

        XCTAssertFalse(fetched.isHalted)
        XCTAssertNil(try loadedVault().record(variant.copyID),
                     "the explicit fetched tombstone remains the latest local intent")
        let staged = try loadedJournal()
        let durableC0 = try XCTUnwrap(
            staged.dependency(Self.sourceID)?
                .requirements[variant.fingerprint]?.snapshot,
            "same-transaction materialize-then-delete must freeze C0 before it disappears")
        XCTAssertEqual(durableC0.id, variant.copyID)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            durableC0,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        XCTAssertEqual(
            try decryptedSecureContent(
                durableC0, vaultKID: document.kid, keyring: keyring),
            Data("immutable C0 body from same fetch".utf8))
        let finalTombstone = try XCTUnwrap(staged.entry(variant.copyID)?.desired)
        XCTAssertEqual(finalTombstone.id, variant.copyID)
        XCTAssertTrue(finalTombstone.secure)
        XCTAssertTrue(finalTombstone.deleted)
        XCTAssertEqual(
            finalTombstone.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text,
            document.kid)
        XCTAssertEqual(finalTombstone, copyTombstone,
                       "the explicit authenticated remote T remains exact later intent")
        XCTAssertEqual(engine.agreedBase.envelope(variant.copyID), copyTombstone)

        // Restart at the narrowest evidence boundary: primary C is absent and only the
        // durable dependency snapshot can prove what must precede E and the final T.
        let restartedBridge = SnippetLibraryBridge(
            store: fixture.store,
            secureStore: fixture.secureStore)
        let restarted = makeEngine(
            backend: backend,
            bridge: restartedBridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        var offset = backend.submittedBatches.count

        var state = await restarted.sync()
        if case .waitingForVault = state {
            _ = try await fixture.session.unlock(
                reason: "Resume same-fetch dependency after restart")
            state = await restarted.sync()
        }
        XCTAssertFalse(state.isHalted)
        var submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertEqual(submitted.only?.only, durableC0,
                       "restart must resurrect immutable C0 against the fetched tombstone CAS")

        offset = backend.submittedBatches.count
        _ = await restarted.sync()
        submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        let release = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(release.id, Self.sourceID)
        XCTAssertNil(release.x[variant.extensionKey])

        offset = backend.submittedBatches.count
        _ = await restarted.sync()
        submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertEqual(submitted.only?.only, finalTombstone,
                       "the explicit deletion remains ordered after C0 and carrier-free E")

        let finalBackend = try backend.snapshot.reduce(into: [UUID: SyncEnvelope]()) {
            $0[$1.id] = try WireCodec.open($1, using: sealer)
        }
        XCTAssertEqual(finalBackend[variant.copyID], finalTombstone)
        XCTAssertNil(finalBackend[Self.sourceID]?.x[variant.extensionKey])
        XCTAssertNil(try loadedVault().record(variant.copyID))

        let finalRestart = makeEngine(
            backend: backend,
            bridge: SnippetLibraryBridge(
                store: fixture.store,
                secureStore: fixture.secureStore),
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        let beforeFinalRestart = backend.submittedBatches.count
        _ = await finalRestart.sync()
        XCTAssertEqual(backend.submittedBatches.count, beforeFinalRestart,
                       "completed C0 → E → T ordering must stay quiescent after restart")
    }

    func testRestartAfterPreparedEvidenceJournalFsyncInstallsExactC0WithoutSynthesizingTombstone()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare post-journal pre-apply crash evidence")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("prepared evidence ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("exact prepared C0 bytes".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let remoteWinner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Prepared-evidence plain survivor",
                keyword: "prepared-evidence-survivor",
                content: "source carrying prepared evidence",
                tags: ["crash", "restart"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let merged = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: remoteWinner)
        let source = try XCTUnwrap(merged.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: source).only)
        let preparedC0 = try XCTUnwrap(
            fixture.bridge.prepareConflictCopyEvidence(from: [source]).only)
        let preparedC0Hash = try preparedC0.envelopeHash()
        XCTAssertEqual(preparedC0.id, variant.copyID)
        XCTAssertEqual(preparedC0.hlc, variant.sourceHLC,
                       "prepared evidence preserves the losing generation clock")
        XCTAssertEqual(preparedC0.origin, variant.sourceOrigin,
                       "prepared evidence preserves the losing generation origin")
        XCTAssertEqual(
            try decryptedSecureContent(
                preparedC0, vaultKID: document.kid, keyring: keyring),
            Data("exact prepared C0 bytes".utf8))

        _ = try fixture.bridge.applyRemote([ancestor])
        _ = try await fixture.session.unlock(
            reason: "Finish durable restart fixture")
        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "prepared-evidence-fsync-crash")
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let storedAncestor = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: source,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([preparedC0])
        XCTAssertEqual(journal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot, preparedC0)
        XCTAssertNil(journal.entry(variant.copyID),
                     "there is no later T/C1 intent in this crash window")
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let beforeApply = try fixture.bridge.currentSnapshot(
            agreedBase: journal.projectionKnowledge(over: base))
        XCTAssertNil(beforeApply.primaryStates[variant.copyID])
        XCTAssertNil(try loadedVault().record(variant.copyID),
                     "the fixture stops after journal fsync and before primary apply")
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, [:],
                       "evidence fsync alone may not claim primary installation")
        backend.seed([try WireCodec.seal(source, using: sealer)])

        let restarted = recreateFixture(using: fixture)
        _ = try await restarted.session.unlock(
            reason: "Resume exact prepared evidence after restart")
        let engine = makeEngine(
            backend: backend,
            bridge: restarted.bridge,
            sealer: sealer,
            deviceID: restarted.store.deviceID)
        let state = await engine.sync()

        XCTAssertFalse(state.isHalted)
        let loaded = try loadedJournal()
        XCTAssertNil(loaded.entry(variant.copyID),
                     "dependency existence proof is not a user deletion event")
        XCTAssertEqual(loaded.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot, preparedC0)
        let projected = try restarted.bridge.currentEnvelopes(
            agreedBase: loaded.projectionKnowledge(over: engine.agreedBase))
        XCTAssertEqual(projected[variant.copyID], preparedC0,
                       "restart must install the exact fsynced C0, not derive a new generation")
        XCTAssertNotNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts,
                       [variant.copyID: preparedC0Hash],
                       "recovery must atomically persist the exact C0 install receipt")
    }

    func testRestartAfterInstalledC0IsDeletedWithNoJournalEntryKeepsDeletionAndStagesTombstone()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare installed-then-deleted C0 crash fixture")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("installed-delete ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("installed C0 deleted before restart".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let remoteWinner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Installed-delete plain survivor",
                keyword: "installed-delete-survivor",
                content: "source survives the crash boundary",
                tags: ["crash", "installed", "deleted"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: remoteWinner)
        let source = try XCTUnwrap(merge.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: source).only)
        let preparedC0 = try XCTUnwrap(
            fixture.bridge.prepareConflictCopyEvidence(from: [source]).only)
        let preparedC0Hash = try preparedC0.envelopeHash()

        _ = try fixture.bridge.applyRemote([ancestor])
        _ = try await fixture.session.unlock(
            reason: "Finish installed-delete primary fixture")
        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "installed-c0-delete-before-restart")
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let storedAncestor = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        var journal = SyncJournal()
        try journal.stageConflictDependency(source: source, conflictCopies: [])
        try journal.recordConflictCopyEvidence([preparedC0])
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // Simulate process death after the primary transaction committed source+C0 but
        // before any ordinary C entry or backend acceptance receipt reached the journal.
        let beforeApply = try fixture.bridge.currentSnapshot(
            agreedBase: journal.projectionKnowledge(over: base))
        let applied = try fixture.bridge.applyRemote(
            [source],
            expectedPrimary: [
                Self.sourceID: beforeApply.primaryState(for: Self.sourceID),
                variant.copyID: beforeApply.primaryState(for: variant.copyID),
            ],
            heldConflictCopyIntents: [:],
            preparedConflictCopyEvidence: [preparedC0])
        XCTAssertTrue(applied.retryIDs.isEmpty)
        XCTAssertEqual(applied.conflictCopyEvidence, [preparedC0])
        XCTAssertEqual(
            try fixture.bridge.currentEnvelopes(
                agreedBase: journal.projectionKnowledge(over: base))[variant.copyID],
            preparedC0)
        XCTAssertNotNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts,
                       [variant.copyID: preparedC0Hash],
                       "normal carrier apply and its receipt must share one vault transaction")
        let postInstallJournal = try loadedJournal()
        XCTAssertNil(postInstallJournal.entry(variant.copyID),
                     "the crash happens before an ordinary copy intent is persisted")
        XCTAssertNil(postInstallJournal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.acceptedRecordVersion,
            "primary installation is not a backend acceptance receipt")
        XCTAssertEqual(postInstallJournal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot, preparedC0)

        // The user/external writer deletes the installed prerequisite while the legacy
        // journal shape is still entry=nil. A primary-atomic install fact must survive
        // this deletion; otherwise it is indistinguishable from the pre-install crash
        // covered by the preceding test and restart will incorrectly resurrect C0.
        try fixture.secureStore.delete(id: variant.copyID)
        XCTAssertNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts,
                       [variant.copyID: preparedC0Hash],
                       "secure deletion preserves the primary-install fact")
        XCTAssertEqual(try loadedJournal(), postInstallJournal,
                       "the deletion deliberately does not repair the sync journal")
        backend.seed([try WireCodec.seal(source, using: sealer)])

        let restartedFixture = recreateFixture(using: fixture)
        _ = try await restartedFixture.session.unlock(
            reason: "Resume after installed C0 was deleted")
        let restarted = makeEngine(
            backend: backend,
            bridge: restartedFixture.bridge,
            sealer: sealer,
            deviceID: restartedFixture.store.deviceID)
        let state = await restarted.sync()

        XCTAssertFalse(state.isHalted)
        XCTAssertNil(try loadedVault().record(variant.copyID),
                     "restart must not resurrect a C0 which primary proves was deleted")
        XCTAssertNil(restartedFixture.store.snippet(id: variant.copyID))
        let recoveredJournal = try loadedJournal()
        XCTAssertTrue(recoveredJournal.entry(variant.copyID)?.desired.deleted == true,
                      "installed-then-absent C0 must become durable T even when entry was nil")
        XCTAssertEqual(recoveredJournal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot, preparedC0,
            "T still waits behind the exact immutable C0 prerequisite")
    }

    func testVaultIdentityPublishReadAndAdoptionNeverTransportLocalC0Receipt()
        throws
    {
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.tests.receipt-identity.\(UUID().uuidString)",
            inMemory: true)
        let receiptID = UUID(
            uuidString: "50000000-0000-4000-8000-000000000009")!
        let receiptHash = String(repeating: "a", count: 64)
        let receiptValue = JSONValue.object([
            receiptHash: .string(receiptID.uuidString.lowercased()),
        ])
        let futureReceiptKey = VaultDocument.localConflictInstallReceiptsPrefix + "v2"
        var local = VaultDocument(
            kid: "receipt-identity-vault",
            vaultSalt: "3Qk5Yy1xQfC0Zr8mHn2pQw",
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: "Yh8pQm4kL1sTz0Wc7Vb9Ng"),
            x: [
                VaultDocument.localConflictInstallReceiptsKey: receiptValue,
                futureReceiptKey: .object([
                    "opaque": .string("must-stay-on-originating-device"),
                ]),
                "safeSharedFuture": .string("preserve"),
            ])
        XCTAssertNil(local.localConflictInstallReceipts,
                     "a future reserved version makes even adjacent valid v1 history unreadable")

        let identities = VaultIdentityStore(keychain: keychain)
        XCTAssertTrue(identities.publish(local))
        let publishedBytes = try XCTUnwrap(
            keychain.loadItem(account: VaultIdentityStore.account))
        let rawPublished = try VaultFile.decode(publishedBytes)
        XCTAssertEqual(rawPublished.localConflictInstallReceipts, [:],
                       "publish must scrub the device-local receipt before keychain write")
        XCTAssertNil(rawPublished.x[futureReceiptKey],
                     "publish must scrub unknown future receipt versions too")
        XCTAssertEqual(rawPublished.x["safeSharedFuture"], .string("preserve"))

        // Model a historical writer which accidentally put the local marker in the
        // synchronizable slot. Both read and fresh-vault adoption must scrub it.
        local.x["historicalSharedFuture"] = .string("also-preserve")
        try keychain.storeItem(
            try VaultFile.encode(local),
            account: VaultIdentityStore.account)
        let sanitizedRead = try XCTUnwrap(identities.published())
        XCTAssertEqual(sanitizedRead.localConflictInstallReceipts, [:])
        XCTAssertNil(sanitizedRead.x[futureReceiptKey],
                     "identity read may not adopt a future device-local receipt")
        XCTAssertEqual(sanitizedRead.x["safeSharedFuture"], .string("preserve"))
        XCTAssertEqual(sanitizedRead.x["historicalSharedFuture"],
                       .string("also-preserve"))

        SyncCoordinator.runtimeEnabledOverride = true
        let adopted = makeFixture(keychain: keychain)
        XCTAssertEqual(adopted.secureStore.document?.kid, local.kid)
        XCTAssertEqual(adopted.secureStore.document?.localConflictInstallReceipts, [:])
        XCTAssertNil(adopted.secureStore.document?.x[futureReceiptKey])
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, [:],
                       "another device's receipt may not enter this device's vault file")
        XCTAssertNil(try loadedVault().x[futureReceiptKey])
        XCTAssertEqual(try loadedVault().x["historicalSharedFuture"],
                       .string("also-preserve"))
    }

    func testMalformedLocalC0InstallReceiptMakesBridgeSnapshotFailClosed()
        throws
    {
        for (label, key, value) in [
            (
                "malformed-v1",
                VaultDocument.localConflictInstallReceiptsKey,
                JSONValue.object([
                    "not-a-canonical-envelope-hash":
                        .string(Self.sourceID.uuidString.lowercased()),
                ])),
            (
                "unknown-v2",
                VaultDocument.localConflictInstallReceiptsPrefix + "v2",
                JSONValue.object(["opaque": .string("future-shape")])) ,
        ] {
            let fixture = makeFixture()
            let pending = try XCTUnwrap(
                fixture.secureStore.prepareVaultCreationIfNeeded())
            var vault = try fixture.secureStore.commitVaultCreation(pending)
            if label == "unknown-v2" {
                vault.x[VaultDocument.localConflictInstallReceiptsKey] = .object([
                    String(repeating: "a", count: 64):
                        .string(Self.sourceID.uuidString.lowercased()),
                ])
            }
            vault.x[key] = value
            try VaultFile.write(vault)
            fixture.secureStore.reload(notifyChange: false)
            let malformedBytes = try Data(
                contentsOf: SnippetStorageLocations.vaultFileURL)

            XCTAssertNil(try loadedVault().localConflictInstallReceipts,
                         "\(label) cannot be interpreted as empty local history")
            XCTAssertThrowsError(
                try fixture.bridge.currentSnapshot(agreedBase: SyncBase())
            ) { error in
                guard let failure = error as? SyncEngineFailure else {
                    return XCTFail("expected typed local quarantine, got \(error)")
                }
                XCTAssertEqual(failure.reason, .localLibraryQuarantined)
            }
            XCTAssertEqual(
                try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
                malformedBytes,
                "fail-closed \(label) validation may not rewrite durable bytes")
            try? FileManager.default.removeItem(
                at: SnippetStorageLocations.vaultFileURL)
            try? FileManager.default.removeItem(
                at: SnippetStorageLocations.snippetsFileURL)
        }
    }

    func testEncryptedBackupExportAndImportNeverTransportLocalC0InstallReceipt()
        async throws
    {
        let harness = try await makeConflictHarness()
        let copyID = harness.scenario.variant.copyID
        var localVault = try loadedVault()
        let localReceipts = try XCTUnwrap(localVault.localConflictInstallReceipts)
        XCTAssertNotNil(localReceipts[copyID],
                        "fixture must begin after a primary-atomic C0 install")
        XCTAssertNotNil(localVault.record(copyID))
        let futureReceiptKey = VaultDocument.localConflictInstallReceiptsPrefix + "v2"
        localVault.x["safeBackupFuture"] = .string("preserve")
        try VaultFile.write(localVault)
        harness.fixture.secureStore.reload(notifyChange: false)
        let passphrase = "receipt portability regression"

        let exported = try await harness.fixture.secureStore.makeEncryptedBackup(
            store: harness.fixture.store,
            passphrase: passphrase,
            iterations: 1)
        let openedExport = try EncryptedSnippetBackup.open(
            exported.data,
            passphrase: passphrase)
        XCTAssertEqual(openedExport.vault?.localConflictInstallReceipts, [:],
                       "portable export must omit device-local primary history")
        XCTAssertNil(openedExport.vault?.x[futureReceiptKey])
        XCTAssertEqual(openedExport.vault?.x["safeBackupFuture"], .string("preserve"))
        XCTAssertNotNil(openedExport.vault?.record(copyID))

        // Build the historical/malicious inverse: a portable payload which contains
        // the receipt. Import must strip it even though it adds the associated record.
        var incomingVault = localVault
        incomingVault.x[futureReceiptKey] = .object([
            "opaque": .string("future-device-local-receipt"),
        ])
        XCTAssertNil(incomingVault.localConflictInstallReceipts,
                     "future reserved versions are invalid as local state")
        let incomingWithReceipt = try EncryptedSnippetBackup.seal(
            snippets: harness.fixture.store.snippets,
            vault: incomingVault,
            vaultKey: harness.scenario.keyring.libraryKey,
            passphrase: passphrase,
            iterations: 1)
        var localWithoutCopy = localVault
        localWithoutCopy.records.removeAll { $0.id == copyID }
        localWithoutCopy.removeLocalConflictInstallReceipts()
        try VaultFile.write(localWithoutCopy)
        harness.fixture.secureStore.reload(notifyChange: false)
        XCTAssertNil(try loadedVault().record(copyID))
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, [:])

        _ = try await harness.fixture.secureStore.importEncryptedBackup(
            incomingWithReceipt,
            passphrase: passphrase,
            into: harness.fixture.store)

        XCTAssertNotNil(try loadedVault().record(copyID))
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, [:],
                       "an imported device's receipt cannot suppress local recovery")
        XCTAssertNil(try loadedVault().x[futureReceiptKey])
        XCTAssertEqual(try loadedVault().x["safeBackupFuture"], .string("preserve"))
    }

    func testPlainC1FinalizationWritesPrimaryBeforeC0ReceiptAcrossSecondWriteFailure()
        throws
    {
        let orderingRoot = rootURL.appendingPathComponent(
            "plain-c1-receipt-ordering", isDirectory: true)
        let libraryDirectory = orderingRoot.appendingPathComponent(
            "Library", isDirectory: true)
        let vaultDirectory = orderingRoot.appendingPathComponent(
            "Vault", isDirectory: true)
        let temporaryDirectory = orderingRoot.appendingPathComponent(
            "Tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: libraryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: vaultDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)

        let libraryURL = libraryDirectory.appendingPathComponent("snippets.json")
        let vaultURL = vaultDirectory.appendingPathComponent("vault.json")
        let stateURL = orderingRoot.appendingPathComponent("state.json")
        let lockURL = orderingRoot.appendingPathComponent("library.lock")
        try AtomicFileWriter.write(
            try SnippetLibraryCodec.encode([]),
            to: libraryURL,
            temporaryDirectory: temporaryDirectory)
        let initialVault = VaultDocument(
            kid: "receipt-order-vault",
            vaultSalt: "3Qk5Yy1xQfC0Zr8mHn2pQw",
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: "Yh8pQm4kL1sTz0Wc7Vb9Ng"))
        try VaultFile.write(
            initialVault,
            to: vaultURL,
            temporaryDirectory: temporaryDirectory)
        let initialVaultBytes = try Data(contentsOf: vaultURL)

        let fingerprint = String(repeating: "c", count: 64)
        let copyID = SyncMerge.deterministicUUID(
            namespace: Self.sourceID,
            name: "sync-content-conflict-v1|\(fingerprint)")
        let preparedC0 = SyncEnvelope(
            id: copyID,
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceA),
            origin: Self.deviceA,
            secure: true,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Prepared immutable C0",
                keyword: "prepared-c0",
                content: Data("sealed-c0-placeholder".utf8),
                tags: ["conflict"],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            x: [
                SyncEnvelope.vaultKeyIDExtensionKey: .string(initialVault.kid),
                SyncMerge.plainConflictCopyExtensionKey:
                    SyncMerge.conflictCopyProvenance(
                        sourceID: Self.sourceID,
                        fingerprint: fingerprint),
            ])
        XCTAssertTrue(SyncMerge.hasValidConflictCopyIdentity(preparedC0))
        let receiptHash = try preparedC0.envelopeHash()
        let finalPlainSnippet = Snippet(
            id: copyID,
            name: "Final held plain C1",
            keyword: "plain-c1",
            content: "the user's demoted generation survives",
            tags: ["conflict", "demoted"],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 0.4))
        let heldPlainC1 = SyncEnvelope.plain(
            finalPlainSnippet,
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [
                SyncMerge.plainConflictCopyExtensionKey:
                    SyncMerge.conflictCopyProvenance(
                        sourceID: Self.sourceID,
                        fingerprint: fingerprint),
            ])
        XCTAssertEqual(heldPlainC1.id, preparedC0.id)

        var restoreVaultPermissions = false
        defer {
            if restoreVaultPermissions {
                _ = chmod(vaultDirectory.path, 0o700)
            }
        }
        XCTAssertThrowsError(try LibraryTransaction.perform(
            libraryURL: libraryURL,
            vaultURL: vaultURL,
            stateURL: stateURL,
            lockURL: lockURL,
            temporaryDirectory: temporaryDirectory,
            lockTimeout: 1
        ) { contents in
            // This is the final state of prepared C0 followed by held plain C1:
            // primary is plaintext, while the exact C0 install fact remains in vault.x.
            contents.snippets = [finalPlainSnippet]
            var vault = try XCTUnwrap(contents.vault)
            try vault.recordLocalConflictInstallReceipts(for: [preparedC0])
            contents.vault = vault
            contents.marker = .demoting(copyID)
            XCTAssertEqual(chmod(vaultDirectory.path, 0o500), 0)
            restoreVaultPermissions = true
        }) { error in
            guard case LibraryTransaction.Failure.writeFailed = error else {
                return XCTFail("expected the injected second-file failure, got \(error)")
            }
        }
        XCTAssertEqual(chmod(vaultDirectory.path, 0o700), 0)
        restoreVaultPermissions = false

        let afterCrashLibrary = try SnippetLibraryCodec.decode(
            Data(contentsOf: libraryURL))
        XCTAssertEqual(afterCrashLibrary, [finalPlainSnippet],
                       "final C1 must land before the vault receipt write is attempted")
        XCTAssertEqual(try Data(contentsOf: vaultURL), initialVaultBytes)
        XCTAssertEqual(
            try VaultFile.decode(Data(contentsOf: vaultURL))
                .localConflictInstallReceipts,
            [:],
            "a second-write failure must never publish receipt-present/primary-absent")

        _ = try LibraryTransaction.perform(
            libraryURL: libraryURL,
            vaultURL: vaultURL,
            stateURL: stateURL,
            lockURL: lockURL,
            temporaryDirectory: temporaryDirectory,
            lockTimeout: 1
        ) { contents in
            contents.snippets = [finalPlainSnippet]
            var vault = try XCTUnwrap(contents.vault)
            try vault.recordLocalConflictInstallReceipts(for: [preparedC0])
            contents.vault = vault
            contents.marker = .demoting(copyID)
        }
        XCTAssertEqual(
            try VaultFile.decode(Data(contentsOf: vaultURL))
                .localConflictInstallReceipts,
            [copyID: receiptHash])
        XCTAssertEqual(
            try SnippetLibraryCodec.decode(Data(contentsOf: libraryURL)),
            [finalPlainSnippet])
    }

    func testBridgeRecoveryWritesHeldPlainC1BeforeReceiptWhenVaultWriteFails()
        async throws
    {
        let harness = try await makeStagedLocalFullResyncHarness()
        let variant = harness.scenario.variant
        let preparedC0 = try XCTUnwrap(
            harness.fixture.bridge.prepareConflictCopyEvidence(
                from: [harness.scenario.survivor]).only)
        var heldPlainC1 = SyncEnvelope.plain(
            Snippet(
                id: variant.copyID,
                name: "Held plain C1 at recovery write fence",
                keyword: "recovery-write-fence",
                content: "primary must land before receipt",
                tags: ["conflict", "demoted", "crash"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.9)),
            hlc: HLC(wallMs: 900, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        heldPlainC1.x[SyncMerge.plainConflictCopyExtensionKey] = try XCTUnwrap(
            preparedC0.x[SyncMerge.plainConflictCopyExtensionKey])

        // Model the durable recovery input: exact C0 evidence and the later plain C1
        // are already journaled while primary still has no deterministic-copy row.
        var journal = try loadedJournal()
        try journal.recordConflictCopyEvidence([preparedC0])
        var journalProjection = try harness.fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: harness.engine.agreedBase))
        journalProjection[variant.copyID] = heldPlainC1
        journal.reconcile(
            current: journalProjection,
            confirmed: harness.engine.agreedBase,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        XCTAssertNotNil(journal.entry(variant.copyID))
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let journalBytes = try Data(
            contentsOf: SnippetStorageLocations.syncJournalFileURL)
        let vaultBytes = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let vaultDirectory = SnippetStorageLocations.vaultFileURL
            .deletingLastPathComponent()
        var restoreVaultPermissions = false
        defer {
            if restoreVaultPermissions {
                _ = chmod(vaultDirectory.path, 0o700)
            }
        }
        XCTAssertEqual(chmod(vaultDirectory.path, 0o500), 0)
        restoreVaultPermissions = true

        XCTAssertThrowsError(
            try harness.fixture.bridge.materializeConflictPrerequisites(
                from: [harness.scenario.survivor],
                preparedConflictCopyEvidence: [preparedC0],
                heldConflictCopyIntents: [variant.copyID: heldPlainC1],
                expectedPrimary: [variant.copyID: .absent])
        ) { error in
            guard case LibraryTransaction.Failure.writeFailed = error else {
                return XCTFail("expected injected vault write failure, got \(error)")
            }
        }
        XCTAssertEqual(chmod(vaultDirectory.path, 0o700), 0)
        restoreVaultPermissions = false

        let primary = try SnippetLibraryCodec.decode(
            Data(contentsOf: SnippetStorageLocations.snippetsFileURL))
        XCTAssertEqual(
            primary.first(where: { $0.id == variant.copyID })?.content,
            "primary must land before receipt",
            "the bridge must select library-before-vault for final plain C1")
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytes,
            "the failed second write cannot publish the receipt")
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts, [:])
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL),
            journalBytes,
            "the failed primary transaction cannot rewrite durable held C1 intent")
    }

    func testRestartWithBarePrimaryAfterPreparedEvidenceDoesNotInventSourceOrCopyDeletes()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare bare-primary evidence crash")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("bare-primary ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("bare-primary exact C0".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let remoteWinner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Bare-primary source",
                keyword: "bare-primary-source",
                content: "source refetched after crash",
                tags: ["crash", "bare"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: remoteWinner)
        let source = try XCTUnwrap(merge.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: source).only)
        let preparedC0 = try XCTUnwrap(
            fixture.bridge.prepareConflictCopyEvidence(from: [source]).only)

        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "bare-primary-prepared-evidence-crash")
        let base = SyncBase(journalEstablished: true)
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        var journal = SyncJournal()
        try journal.stageConflictDependency(source: source, conflictCopies: [])
        try journal.recordConflictCopyEvidence([preparedC0])
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        let bare = try fixture.bridge.currentSnapshot(
            agreedBase: journal.projectionKnowledge(over: base))
        XCTAssertEqual(bare.primaryState(for: Self.sourceID), .absent)
        XCTAssertEqual(bare.primaryState(for: variant.copyID), .absent)
        var hypotheticalRestartReconcile = journal
        hypotheticalRestartReconcile.reconcile(
            current: bare.envelopes,
            confirmed: base,
            deviceID: fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        XCTAssertNil(hypotheticalRestartReconcile.entry(Self.sourceID),
                     "a staged source snapshot is not existence proof")
        XCTAssertNil(hypotheticalRestartReconcile.entry(variant.copyID),
                     "prepared-but-unapplied C0 is not existence proof")
        backend.seed([try WireCodec.seal(source, using: sealer)])

        let restartedFixture = recreateFixture(using: fixture)
        _ = try await restartedFixture.session.unlock(
            reason: "Resume bare-primary evidence crash")
        let engine = makeEngine(
            backend: backend,
            bridge: restartedFixture.bridge,
            sealer: sealer,
            deviceID: restartedFixture.store.deviceID)
        for _ in 0..<3 {
            var state = await engine.sync()
            if case .waitingForVault = state {
                _ = try await restartedFixture.session.unlock(
                    reason: "Continue bare-primary recovery")
                state = await engine.sync()
            }
            XCTAssertFalse(state.isHalted)
            let durable = try loadedJournal()
            XCTAssertFalse(durable.entry(Self.sourceID)?.desired.deleted == true)
            XCTAssertFalse(durable.entry(variant.copyID)?.desired.deleted == true)
        }

        let durable = try loadedJournal()
        if let retainedSnapshot = durable.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot {
            XCTAssertEqual(retainedSnapshot, preparedC0)
        } else {
            XCTAssertEqual(engine.agreedBase.envelope(variant.copyID), preparedC0,
                           "a pruned dependency requires exact C0 backend acceptance")
        }
        let projected = try restartedFixture.bridge.currentEnvelopes(
            agreedBase: durable.projectionKnowledge(over: engine.agreedBase))
        XCTAssertNotNil(projected[Self.sourceID])
        XCTAssertEqual(projected[variant.copyID], preparedC0)
        XCTAssertNotNil(try loadedVault().record(variant.copyID))
    }

    func testStaleSameLineageReceiptForDifferentC0NonceDoesNotSuppressRecovery()
        async throws
    {
        let harness = try await makeConflictHarness()
        let variant = harness.scenario.variant
        let journal = try loadedJournal()
        let frozenC0 = try XCTUnwrap(journal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        XCTAssertNil(journal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.offered)
        XCTAssertNil(journal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.acceptedRecordVersion)
        _ = try await harness.fixture.session.unlock(
            reason: "Prepare a different exact C0 nonce for stale receipt")
        let differentC0 = try XCTUnwrap(
            harness.fixture.bridge.prepareConflictCopyEvidence(
                from: [harness.scenario.survivor]).only)
        let frozenHash = try frozenC0.envelopeHash()
        let staleHash = try differentC0.envelopeHash()
        XCTAssertEqual(differentC0.id, frozenC0.id)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            differentC0,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        XCTAssertNotEqual(staleHash, frozenHash)

        var absentWithStaleReceipt = try loadedVault()
        absentWithStaleReceipt.records.removeAll { $0.id == variant.copyID }
        try absentWithStaleReceipt.recordLocalConflictInstallReceipts(
            for: [differentC0])
        try VaultFile.write(absentWithStaleReceipt)
        harness.fixture.secureStore.reload(notifyChange: false)
        XCTAssertNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts,
                       [variant.copyID: staleHash])

        let restartedFixture = recreateFixture(using: harness.fixture)
        _ = try await restartedFixture.session.unlock(
            reason: "Recover frozen C0 despite stale same-lineage receipt")
        let restarted = makeEngine(
            backend: harness.backend,
            bridge: restartedFixture.bridge,
            sealer: harness.sealer,
            deviceID: restartedFixture.store.deviceID)
        var state = await restarted.sync()
        if case .waitingForVault = state {
            _ = try await restartedFixture.session.unlock(
                reason: "Continue exact-hash receipt recovery")
            state = await restarted.sync()
        }

        XCTAssertFalse(state.isHalted)
        let durable = try loadedJournal()
        let projected = try restartedFixture.bridge.currentEnvelopes(
            agreedBase: durable.projectionKnowledge(over: restarted.agreedBase))
        XCTAssertEqual(projected[variant.copyID], frozenC0,
                       "only the journal's exact frozen bytes satisfy recovery")
        XCTAssertNotNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts,
                       [variant.copyID: frozenHash],
                       "successful recovery replaces the stale epoch receipt")
    }

    func testCarrierEvidencePrecedesAuthenticatedEditedCopyWhenSnapshotStartsMissing()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare edited-copy carrier fixture")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("edited-copy ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("immutable carrier-derived C0".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let remoteWinner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Edited-copy plain winner",
                keyword: "edited-copy-winner",
                content: "carrier-bearing source E",
                tags: ["winner"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let conflict = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: remoteWinner)
        let carryingSource = try XCTUnwrap(conflict.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: carryingSource).only)
        let frozenC0 = try materializedSecureConflictCopy(
            source: carryingSource,
            variant: variant,
            keyring: keyring,
            vaultKID: document.kid)

        // Primary already contains a legitimate user generation C1 at the deterministic
        // id. Its provenance identifies the same conflict, while its own authenticated
        // body and metadata are deliberately different from carrier-derived C0.
        _ = try fixture.bridge.applyRemote([ancestor])
        _ = try await fixture.session.unlock(
            reason: "Install the deterministic copy before its user edit")
        _ = try fixture.bridge.applyRemote([frozenC0])
        _ = try await fixture.session.unlock(
            reason: "Authenticate the later deterministic-copy edit")
        try fixture.secureStore.setContent(
            "authenticated user edit C1",
            for: variant.copyID)
        try fixture.secureStore.updateMetadata(
            id: variant.copyID,
            name: "User-edited conflict copy C1",
            keyword: "edited-c1",
            tags: ["conflict", "user-edited"],
            isEnabled: true,
            isPinned: true)
        let primaryC1 = try XCTUnwrap(
            fixture.bridge.currentEnvelopes(agreedBase: SyncBase())[variant.copyID])
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            primaryC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        XCTAssertNotEqual(primaryC1, frozenC0)
        XCTAssertNotEqual(primaryC1.fields?.content, frozenC0.fields?.content)
        XCTAssertEqual(
            try SnippetCrypto.open(
                try XCTUnwrap(String(data: try XCTUnwrap(primaryC1.fields).content,
                                     encoding: .utf8)),
                for: SnippetCrypto.RecordContext(
                    scopeID: document.kid,
                    recordID: variant.copyID),
                keyring: keyring),
            Data("authenticated user edit C1".utf8))

        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "carrier-evidence-before-edited-copy")
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let storedAncestor = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // This is the dangerous restartable state: the dependency knows which carrier
        // must be materialized, but has not frozen C0. Matching provenance on primary C1
        // is identity evidence only and must not be mistaken for the missing C0 bytes.
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: carryingSource,
            conflictCopies: [])
        XCTAssertNil(
            journal.dependency(Self.sourceID)?
                .requirements[variant.fingerprint]?.snapshot)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        backend.seed([try WireCodec.seal(carryingSource, using: sealer)])
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)

        let fetched = await engine.sync()

        XCTAssertFalse(fetched.isHalted)
        XCTAssertTrue(backend.submittedBatches.isEmpty,
                      "C1 must not be offered as though it were immutable C0")
        guard backend.submittedBatches.isEmpty else { return }
        let staged = try loadedJournal()
        let durableC0 = try XCTUnwrap(
            staged.dependency(Self.sourceID)?
                .requirements[variant.fingerprint]?.snapshot,
            "the authenticated carrier, not C1's self-authenticating body, freezes C0")
        XCTAssertNotEqual(durableC0, primaryC1)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            durableC0,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        XCTAssertEqual(
            try decryptedSecureContent(
                durableC0, vaultKID: document.kid, keyring: keyring),
            Data("immutable carrier-derived C0".utf8))
        XCTAssertEqual(staged.entry(variant.copyID)?.desired, primaryC1,
                       "the later local generation remains ordinary pending intent")
        let retainedC1 = try XCTUnwrap(
            fixture.bridge.currentEnvelopes(
                agreedBase: staged.projectionKnowledge(over: engine.agreedBase))[
                    variant.copyID])
        XCTAssertEqual(retainedC1, primaryC1,
                       "materializing evidence must not resurrect C0 into primary storage")

        // Restart after C0 is known only by the durable dependency. The three backend
        // generations must remain strictly C0, carrier-free E, then the user's C1.
        let restarted = makeEngine(
            backend: backend,
            bridge: SnippetLibraryBridge(
                store: fixture.store,
                secureStore: fixture.secureStore),
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        var offset = backend.submittedBatches.count
        var state = await restarted.sync()
        if case .waitingForVault = state {
            _ = try await fixture.session.unlock(
                reason: "Resume edited-copy ordering after restart")
            state = await restarted.sync()
        }
        XCTAssertFalse(state.isHalted)
        var submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertEqual(submitted.only?.only, durableC0)

        offset = backend.submittedBatches.count
        _ = await restarted.sync()
        submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        let releasedSource = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(releasedSource.id, Self.sourceID)
        XCTAssertNil(releasedSource.x[variant.extensionKey])

        offset = backend.submittedBatches.count
        _ = await restarted.sync()
        submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertEqual(submitted.only?.only, primaryC1)

        let finalBackend = try backend.snapshot.reduce(into: [UUID: SyncEnvelope]()) {
            $0[$1.id] = try WireCodec.open($1, using: sealer)
        }
        XCTAssertNil(finalBackend[Self.sourceID]?.x[variant.extensionKey])
        XCTAssertEqual(finalBackend[variant.copyID], primaryC1)
        XCTAssertNil(try loadedJournal().dependency(Self.sourceID),
                     "C1 acceptance should leave no source-release dependency to replay")
        let beforeFinalRestart = backend.submittedBatches.count
        let finalRestart = makeEngine(
            backend: backend,
            bridge: SnippetLibraryBridge(
                store: fixture.store,
                secureStore: fixture.secureStore),
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        _ = await finalRestart.sync()
        let replayed = try backend.submittedBatches.dropFirst(beforeFinalRestart).map {
            try $0.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertTrue(replayed.isEmpty,
                      "fully acknowledged C0 → E → C1 must remain quiescent; "
                        + "replayed IDs: \(replayed.flatMap { $0.map(\.id) })")
    }

    func testCarrierAndAuthenticatedEditedCopyInOneFetchStillOfferC0First()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare same-fetch edited copy")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("same-fetch C1 ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("carrier-derived C0 before fetched C1".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let remoteWinner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Same-fetch C1 plain winner",
                keyword: "same-fetch-c1-winner",
                content: "carrier-bearing source beside C1",
                tags: ["same-fetch", "c1"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let conflict = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: remoteWinner)
        let carryingSource = try XCTUnwrap(conflict.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: carryingSource).only)
        let generatedShape = try materializedSecureConflictCopy(
            source: carryingSource,
            variant: variant,
            keyring: keyring,
            vaultKID: document.kid)
        var fetchedC1 = try secureEnvelope(
            plaintext: Data("authenticated fetched user edit C1".utf8),
            id: variant.copyID,
            revision: 400,
            device: Self.deviceB,
            vaultKID: document.kid,
            keyring: keyring)
        fetchedC1.x[SyncMerge.plainConflictCopyExtensionKey] = try XCTUnwrap(
            generatedShape.x[SyncMerge.plainConflictCopyExtensionKey])
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            fetchedC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))

        _ = try fixture.bridge.applyRemote([ancestor])
        _ = try await fixture.session.unlock(
            reason: "Apply same-fetch carrier and edited copy")
        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "same-fetch-carrier-and-authenticated-c1")
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let storedAncestor = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: carryingSource,
            conflictCopies: [])
        XCTAssertNil(journal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        backend.seed([
            try WireCodec.seal(carryingSource, using: sealer),
            try WireCodec.seal(fetchedC1, using: sealer),
        ])
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)

        let fetched = await engine.sync()

        XCTAssertFalse(fetched.isHalted)
        XCTAssertTrue(backend.submittedBatches.isEmpty,
                      "the same-fetch C1 cannot be mistaken for an already-ACKed C0")
        guard backend.submittedBatches.isEmpty else { return }
        let staged = try loadedJournal()
        let durableC0 = try XCTUnwrap(staged.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        XCTAssertNotEqual(durableC0, fetchedC1)
        XCTAssertEqual(
            try decryptedSecureContent(
                durableC0, vaultKID: document.kid, keyring: keyring),
            Data("carrier-derived C0 before fetched C1".utf8))
        let finalC1 = try XCTUnwrap(staged.entry(variant.copyID)?.desired,
            "fetched C1 remains final intent while C0 owns the prerequisite slot")
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            finalC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        XCTAssertEqual(
            try decryptedSecureContent(
                finalC1, vaultKID: document.kid, keyring: keyring),
            Data("authenticated fetched user edit C1".utf8))
        XCTAssertEqual(engine.agreedBase.envelope(variant.copyID), fetchedC1)
        XCTAssertEqual(
            try fixture.bridge.currentEnvelopes(
                agreedBase: staged.projectionKnowledge(over: engine.agreedBase))[
                    variant.copyID],
            finalC1)

        let restarted = makeEngine(
            backend: backend,
            bridge: SnippetLibraryBridge(
                store: fixture.store,
                secureStore: fixture.secureStore),
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        var offset = backend.submittedBatches.count
        var state = await restarted.sync()
        if case .waitingForVault = state {
            _ = try await fixture.session.unlock(
                reason: "Resume same-fetch C1 ordering")
            state = await restarted.sync()
        }
        XCTAssertFalse(state.isHalted)
        var submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertEqual(submitted.only?.only, durableC0)

        offset = backend.submittedBatches.count
        _ = await restarted.sync()
        submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        let releasedSource = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(releasedSource.id, Self.sourceID)
        XCTAssertNil(releasedSource.x[variant.extensionKey])

        offset = backend.submittedBatches.count
        _ = await restarted.sync()
        submitted = try backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertEqual(submitted.only?.only, finalC1)
        let finalBackend = try backend.snapshot.reduce(into: [UUID: SyncEnvelope]()) {
            $0[$1.id] = try WireCodec.open($1, using: sealer)
        }
        XCTAssertNil(finalBackend[Self.sourceID]?.x[variant.extensionKey])
        XCTAssertEqual(finalBackend[variant.copyID], finalC1)
    }

    func testCarrierAndPlainDemotedCopyInOneFetchStillOfferC0ThenSourceThenC1()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare same-fetch plain C1")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("same-fetch demoted C1 ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("carrier C0 before demoted C1".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let remoteWinner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Same-fetch demoted-copy winner",
                keyword: "same-fetch-demoted-winner",
                content: "carrier-bearing source beside a plain C1",
                tags: ["same-fetch", "demoted"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let conflict = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: remoteWinner)
        let carryingSource = try XCTUnwrap(conflict.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: carryingSource).only)
        let generatedShape = try materializedSecureConflictCopy(
            source: carryingSource,
            variant: variant,
            keyring: keyring,
            vaultKID: document.kid)
        var fetchedPlainC1 = SyncEnvelope.plain(
            Snippet(
                id: variant.copyID,
                name: "User-demoted conflict copy C1",
                keyword: "plain-c1",
                content: "legitimate plaintext after demotion",
                tags: ["conflict", "demoted", "edited"],
                isEnabled: true,
                isPinned: true,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.4)),
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        fetchedPlainC1.x[SyncMerge.plainConflictCopyExtensionKey] = try XCTUnwrap(
            generatedShape.x[SyncMerge.plainConflictCopyExtensionKey])
        XCTAssertFalse(fetchedPlainC1.secure)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            fetchedPlainC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))

        _ = try fixture.bridge.applyRemote([ancestor])
        _ = try await fixture.session.unlock(
            reason: "Apply carrier beside fetched demoted C1")
        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "same-fetch-carrier-and-plain-c1")
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let storedAncestor = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: carryingSource,
            conflictCopies: [])
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        backend.seed([
            try WireCodec.seal(carryingSource, using: sealer),
            try WireCodec.seal(fetchedPlainC1, using: sealer),
        ])
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)

        let fetched = await engine.sync()

        XCTAssertFalse(fetched.isHalted,
                       "a valid plain/demoted C1 is held intent, not a materializer collision")
        XCTAssertTrue(backend.submittedBatches.isEmpty)
        guard !fetched.isHalted, backend.submittedBatches.isEmpty else { return }
        let staged = try loadedJournal()
        let durableC0 = try XCTUnwrap(staged.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        XCTAssertNotEqual(durableC0, fetchedPlainC1)
        XCTAssertEqual(
            try decryptedSecureContent(
                durableC0, vaultKID: document.kid, keyring: keyring),
            Data("carrier C0 before demoted C1".utf8))
        XCTAssertEqual(staged.entry(variant.copyID)?.desired, fetchedPlainC1)
        XCTAssertEqual(fixture.store.snippet(id: variant.copyID)?.content,
                       "legitimate plaintext after demotion")
        XCTAssertNil(try loadedVault().record(variant.copyID),
                     "holding demoted C1 may not transiently leave C0 in the vault")
        XCTAssertEqual(
            try loadedVault().localConflictInstallReceipts,
            [variant.copyID: try durableC0.envelopeHash()],
            "same-fetch C0 then plain C1 must retain the exact primary-install fact")

        let restarted = makeEngine(
            backend: backend,
            bridge: SnippetLibraryBridge(
                store: fixture.store,
                secureStore: fixture.secureStore),
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        var emitted: [SyncEnvelope] = []
        for _ in 0..<5 {
            let offset = backend.submittedBatches.count
            var state = await restarted.sync()
            if case .waitingForVault = state {
                _ = try await fixture.session.unlock(
                    reason: "Resume C0 to source to demoted C1 ordering")
                state = await restarted.sync()
            }
            XCTAssertFalse(state.isHalted)
            emitted.append(contentsOf: try backend.submittedBatches.dropFirst(offset)
                .flatMap { batch in
                    try batch.map { try WireCodec.open($0, using: sealer) }
                })
            if emitted.count >= 3 { break }
        }
        XCTAssertEqual(emitted.map(\.id), [
            variant.copyID,
            Self.sourceID,
            variant.copyID,
        ])
        XCTAssertEqual(emitted.first, durableC0)
        XCTAssertNil(emitted.dropFirst().first?.x[variant.extensionKey])
        XCTAssertEqual(emitted.last, fetchedPlainC1)
        XCTAssertEqual(fixture.store.snippet(id: variant.copyID)?.content,
                       "legitimate plaintext after demotion")
        XCTAssertNil(try loadedVault().record(variant.copyID))
    }

    func testCarrierOnlyFetchPreservesConfirmedPrimaryPlainC1AndReordersC0SourceC1()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare confirmed primary plain C1")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("confirmed plain C1 ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("carrier C0 before confirmed plain C1".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let winner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Carrier-only source winner",
                keyword: "carrier-only-source",
                content: "carrier arrives after confirmed C1",
                tags: ["carrier-only"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let conflict = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winner)
        let carryingSource = try XCTUnwrap(conflict.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: carryingSource).only)
        let c0Shape = try materializedSecureConflictCopy(
            source: carryingSource,
            variant: variant,
            keyring: keyring,
            vaultKID: document.kid)
        var plainC1 = SyncEnvelope.plain(
            Snippet(
                id: variant.copyID,
                name: "Already-confirmed demoted C1",
                keyword: "confirmed-plain-c1",
                content: "confirmed plaintext must remain primary",
                tags: ["conflict", "confirmed", "demoted"],
                isEnabled: true,
                isPinned: true,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.4)),
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        plainC1.x[SyncMerge.plainConflictCopyExtensionKey] = try XCTUnwrap(
            c0Shape.x[SyncMerge.plainConflictCopyExtensionKey])
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            plainC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))

        _ = try fixture.bridge.applyRemote([ancestor, plainC1])
        _ = try await fixture.session.unlock(
            reason: "Project confirmed plain C1 before carrier-only fetch")
        XCTAssertEqual(fixture.store.snippet(id: variant.copyID)?.content,
                       "confirmed plaintext must remain primary")
        XCTAssertNil(try loadedVault().record(variant.copyID))

        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "carrier-only-after-confirmed-plain-c1")
        backend.seed([
            try WireCodec.seal(ancestor, using: sealer),
            try WireCodec.seal(plainC1, using: sealer),
        ])
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        for wire in backend.snapshot {
            let envelope = try WireCodec.open(wire, using: sealer)
            base.recordConfirmed(
                envelope,
                recordVersion: try XCTUnwrap(wire.recordVersion))
        }
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        backend.seed([try WireCodec.seal(carryingSource, using: sealer)])
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)

        let fetched = await engine.sync()

        XCTAssertFalse(fetched.isHalted)
        XCTAssertTrue(backend.submittedBatches.isEmpty)
        guard !fetched.isHalted, backend.submittedBatches.isEmpty else { return }
        XCTAssertEqual(fixture.store.snippet(id: variant.copyID)?.content,
                       "confirmed plaintext must remain primary")
        XCTAssertNil(try loadedVault().record(variant.copyID))
        let staged = try loadedJournal()
        let durableC0 = try XCTUnwrap(staged.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        XCTAssertNotEqual(durableC0, plainC1)
        XCTAssertEqual(staged.entry(variant.copyID)?.desired, plainC1,
                       "dependency ordering retains C1 even though generic intent was confirmed")

        var emitted: [SyncEnvelope] = []
        for _ in 0..<5 {
            let offset = backend.submittedBatches.count
            var state = await engine.sync()
            if case .waitingForVault = state {
                _ = try await fixture.session.unlock(
                    reason: "Continue confirmed plain C1 dependency ordering")
                state = await engine.sync()
            }
            XCTAssertFalse(state.isHalted)
            emitted.append(contentsOf: try backend.submittedBatches.dropFirst(offset)
                .flatMap { batch in
                    try batch.map { try WireCodec.open($0, using: sealer) }
                })
            if emitted.count >= 3 { break }
        }
        XCTAssertEqual(emitted.map(\.id), [
            variant.copyID,
            Self.sourceID,
            variant.copyID,
        ])
        XCTAssertEqual(emitted.first, durableC0)
        XCTAssertNil(emitted.dropFirst().first?.x[variant.extensionKey])
        XCTAssertEqual(emitted.last, plainC1)
        XCTAssertEqual(fixture.store.snippet(id: variant.copyID)?.content,
                       "confirmed plaintext must remain primary")
        XCTAssertNil(try loadedVault().record(variant.copyID))
    }

    func testSameFetchPlainC1DoesNotApplyWhenCarrierWaitsForMissingVault()
        async throws
    {
        try await assertSameFetchPlainC1IsHeldWithUnavailableCarrier(
            createRivalVault: false)
    }

    func testSameFetchPlainC1DoesNotApplyWhenCarrierBelongsToRivalVault()
        async throws
    {
        try await assertSameFetchPlainC1IsHeldWithUnavailableCarrier(
            createRivalVault: true)
    }

    func testSameFetchCopyTombstoneDoesNotApplyWhenCarrierWaitsForMissingVault()
        async throws
    {
        try await assertSameFetchCopyTombstoneIsHeldWithUnavailableCarrier(
            createRivalVault: false)
    }

    func testSameFetchCopyTombstoneDoesNotApplyWhenCarrierBelongsToRivalVault()
        async throws
    {
        try await assertSameFetchCopyTombstoneIsHeldWithUnavailableCarrier(
            createRivalVault: true)
    }

    func testUnknownFutureCarrierIsNeverAutomaticallyResolved() async throws {
        let harness = try await makeConflictHarness()
        let futureKey = "contentConflict.v2." + String(repeating: "a", count: 64)
        let futureValue = CanonicalJSON.Value.object([
            "version": .int(2),
            "opaque": .utf8(Data("future conflict contract".utf8)),
        ])
        var metadata = try loadedMetadata()
        var carryingSource = try XCTUnwrap(metadata.envelope(Self.sourceID))
        carryingSource.x[futureKey] = futureValue
        metadata.record(carryingSource)
        try SyncBaseFile.write(
            metadata,
            to: SnippetStorageLocations.syncLibraryMetadataFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        let bridge = SnippetLibraryBridge(
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)
        let engine = makeEngine(
            backend: harness.backend,
            bridge: bridge,
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        var offset = harness.backend.submittedBatches.count
        _ = await engine.sync()
        var emitted = try openedBatches(after: offset, in: harness)
        XCTAssertEqual(emitted.only?.only?.id, harness.scenario.variant.copyID)

        offset = harness.backend.submittedBatches.count
        _ = await engine.sync()
        emitted = try openedBatches(after: offset, in: harness)
        for source in emitted.flatMap({ $0 }).filter({ $0.id == Self.sourceID }) {
            XCTAssertEqual(source.x[futureKey], futureValue)
        }
        let projected = try XCTUnwrap(
            bridge.currentEnvelopes(agreedBase: engine.agreedBase)[Self.sourceID])
        XCTAssertEqual(projected.x[futureKey], futureValue)
        XCTAssertTrue(SyncMerge.hasUnknownContentConflictVersion(projected))

        let restartedBridge = SnippetLibraryBridge(
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)
        let restarted = makeEngine(
            backend: harness.backend,
            bridge: restartedBridge,
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        let afterRestart = try XCTUnwrap(
            restartedBridge.currentEnvelopes(
                agreedBase: restarted.agreedBase)[Self.sourceID])
        XCTAssertEqual(afterRestart.x[futureKey], futureValue)
        XCTAssertTrue(SyncMerge.hasUnknownContentConflictVersion(afterRestart))
        offset = harness.backend.submittedBatches.count
        _ = await restarted.sync()
        for source in try openedBatches(after: offset, in: harness)
            .flatMap({ $0 }).filter({ $0.id == Self.sourceID }) {
            XCTAssertEqual(source.x[futureKey], futureValue)
        }
        let final = try XCTUnwrap(
            restartedBridge.currentEnvelopes(
                agreedBase: restarted.agreedBase)[Self.sourceID])
        XCTAssertEqual(final.x[futureKey], futureValue)
        XCTAssertTrue(SyncMerge.hasUnknownContentConflictVersion(final))
    }

    func testPlainCarrierMetadataWriteFailureDoesNotReleaseSource() async throws {
        try XCTSkipIf(getuid() == 0, "permission fault injection is ineffective as root")
        let harness = try await makeConflictHarness()
        _ = await harness.engine.sync()
        let carryingMetadata = try loadedMetadata()
        XCTAssertEqual(
            carryingMetadata.envelope(Self.sourceID)?
                .x[harness.scenario.variant.extensionKey],
            harness.scenario.carrierValue)

        let metadataDirectory = rootURL.appendingPathComponent(
            "read-only-metadata", isDirectory: true)
        let metadataURL = metadataDirectory.appendingPathComponent(
            "library-metadata.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: metadataDirectory, withIntermediateDirectories: true)
        try SyncBaseFile.write(
            carryingMetadata,
            to: metadataURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let bridge = SnippetLibraryBridge(
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore,
            metadataURL: metadataURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let beforeFailure = try XCTUnwrap(
            bridge.currentEnvelopes(
                agreedBase: harness.engine.agreedBase)[Self.sourceID])
        XCTAssertEqual(beforeFailure.x[harness.scenario.variant.extensionKey],
                       harness.scenario.carrierValue)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: metadataDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: metadataDirectory.path)
        }

        var edited = try XCTUnwrap(harness.fixture.store.snippet(id: Self.sourceID))
        edited.name = "Must remain behind failed metadata fence"
        edited.content = "new source body after copy ACK"
        harness.fixture.store.update(edited)
        try harness.fixture.store.flushPendingWritesForSync()
        let engine = makeEngine(
            backend: harness.backend,
            bridge: bridge,
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        let beforeRound = harness.backend.submittedBatches.count

        _ = await engine.sync()

        let submittedSources = try openedBatches(after: beforeRound, in: harness)
            .flatMap { $0 }
            .filter { $0.id == Self.sourceID }
        XCTAssertTrue(submittedSources.isEmpty,
                      "a carrier-free source may not cross a failed durability fence")
        guard case .loaded(let durableMetadata) = SyncBaseFile.load(from: metadataURL) else {
            return XCTFail("the previous carrier-bearing metadata must remain readable")
        }
        XCTAssertEqual(
            durableMetadata.envelope(Self.sourceID)?
                .x[harness.scenario.variant.extensionKey],
            harness.scenario.carrierValue)
    }

    func testVaultForgetScrubsV1CarrierAndDependencyButPreservesFutureCarrier()
        async throws
    {
        let harness = try await makeConflictHarness()
        let futureKey = "contentConflict.v2." + String(repeating: "b", count: 64)
        let futureValue = CanonicalJSON.Value.object([
            "version": .int(2),
            "opaque": .utf8(Data("future carrier survives vault forget".utf8)),
        ])
        var metadata = try loadedMetadata()
        var source = try XCTUnwrap(metadata.envelope(Self.sourceID))
        source.x[futureKey] = futureValue
        metadata.record(source)
        try SyncBaseFile.write(
            metadata,
            to: SnippetStorageLocations.syncLibraryMetadataFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // Model the running app's bridge cache after it observed the future member.
        // Settings invokes this same instance after SecureSnippetStore finishes the
        // durable protocol/vault transaction.
        let forgetBridge = SnippetLibraryBridge(
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)
        var current = try forgetBridge.currentEnvelopes(
            agreedBase: harness.engine.agreedBase)
        source = try XCTUnwrap(current[Self.sourceID])
        XCTAssertEqual(source.x[harness.scenario.variant.extensionKey],
                       harness.scenario.carrierValue)
        XCTAssertEqual(source.x[futureKey], futureValue)

        var journal = try loadedJournal()
        journal.reconcile(
            current: current,
            confirmed: harness.engine.agreedBase,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 10))
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        XCTAssertNotNil(journal.dependency(Self.sourceID))
        XCTAssertEqual(
            journal.entry(Self.sourceID)?.desired
                .x[harness.scenario.variant.extensionKey],
            harness.scenario.carrierValue)
        XCTAssertEqual(journal.entry(Self.sourceID)?.desired.x[futureKey], futureValue)

        SyncCoordinator.runtimeEnabledOverride = false
        try harness.fixture.secureStore.forgetEverything(syncIsQuiescent: true)
        forgetBridge.forgetSecureProjectionMetadata()

        let retainedJournal = try loadedJournal()
        XCTAssertNil(retainedJournal.dependency(Self.sourceID),
                     "forget must remove the copy-before-source edge owned by the vault")
        let retainedDesired = try XCTUnwrap(retainedJournal.entry(Self.sourceID)?.desired)
        XCTAssertFalse(retainedDesired.secure)
        XCTAssertNil(retainedDesired.x[harness.scenario.variant.extensionKey])
        XCTAssertEqual(retainedDesired.x[futureKey], futureValue,
                       "forget may scrub understood v1 ciphertext, not opaque future state")

        let retainedMetadata = try loadedMetadata()
        let retainedSource = try XCTUnwrap(retainedMetadata.envelope(Self.sourceID))
        XCTAssertNil(retainedSource.x[harness.scenario.variant.extensionKey])
        XCTAssertEqual(retainedSource.x[futureKey], futureValue)
        XCTAssertTrue(SyncMerge.hasUnknownContentConflictVersion(retainedSource))
        XCTAssertNil(retainedMetadata.envelope(harness.scenario.variant.copyID))
        XCTAssertNil(harness.fixture.secureStore.document)
        current = try forgetBridge.currentEnvelopes(
            agreedBase: retainedJournal.projectionKnowledge(over: harness.engine.agreedBase))
        XCTAssertNil(current[Self.sourceID]?.x[harness.scenario.variant.extensionKey])
        XCTAssertEqual(current[Self.sourceID]?.x[futureKey], futureValue)
    }

    func testVaultForgetMetadataFailureWithoutProtocolFilesRollsBackThenRetryIsSafe()
        async throws
    {
        var metadataWriteAttempts = 0
        let fixture = makeFixture(syncMetadataWriter: { metadata, url, temporary in
            metadataWriteAttempts += 1
            if metadataWriteAttempts == 1 {
                throw SecureDependencyFixtureFailure.injectedMetadataWrite
            }
            try SyncBaseFile.write(
                metadata, to: url, temporaryDirectory: temporary)
        })
        let harness = try await makeConflictHarness(fixture: fixture)
        let futureKey = "contentConflict.v2." + String(repeating: "d", count: 64)
        let futureValue = CanonicalJSON.Value.object([
            "version": .int(2),
            "opaque": .utf8(Data("future metadata survives retry".utf8)),
        ])
        var metadata = try loadedMetadata()
        var source = try XCTUnwrap(metadata.envelope(Self.sourceID))
        source.x[futureKey] = futureValue
        metadata.record(source)
        try SyncBaseFile.write(
            metadata,
            to: SnippetStorageLocations.syncLibraryMetadataFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // Prime the exact bridge instance that an in-process re-enable will reuse.
        // Its cache must be explicitly published after the successful forget below.
        let sameProcessBridge = SnippetLibraryBridge(
            store: fixture.store,
            secureStore: fixture.secureStore)
        let beforeForget = try sameProcessBridge.currentEnvelopes(
            agreedBase: harness.engine.agreedBase)
        XCTAssertEqual(
            beforeForget[Self.sourceID]?
                .x[harness.scenario.variant.extensionKey],
            harness.scenario.carrierValue)
        XCTAssertEqual(beforeForget[Self.sourceID]?.x[futureKey], futureValue)

        // This is a valid pre-opt-in shape: projection metadata can exist before the
        // transport protocol has ever established base.json or journal.json.
        try FileManager.default.removeItem(
            at: SnippetStorageLocations.syncBaseFileURL)
        try FileManager.default.removeItem(
            at: SnippetStorageLocations.syncJournalFileURL)
        let vaultBytes = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let metadataBytes = try Data(
            contentsOf: SnippetStorageLocations.syncLibraryMetadataFileURL)
        let keyID = try XCTUnwrap(fixture.secureStore.document?.kid)
        SyncCoordinator.runtimeEnabledOverride = false

        var failedAtMetadataFence = false
        do {
            try fixture.secureStore.forgetEverything(syncIsQuiescent: true)
        } catch {
            failedAtMetadataFence = true
            guard case SecureSnippetStore.Failure.transaction(let detail) = error else {
                return XCTFail("expected a transactional metadata failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("could not durably preserve ordinary sync state"))
            XCTAssertTrue(detail.contains("original state was restored"))
        }
        XCTAssertTrue(
            failedAtMetadataFence,
            "metadata must be a pre-destruction durability fence even when base and journal are absent")
        guard failedAtMetadataFence else { return }

        XCTAssertEqual(metadataWriteAttempts, 2,
                       "the failed prune is followed by an exact metadata rollback")
        XCTAssertTrue(fixture.secureStore.hasVault)
        XCTAssertTrue(fixture.keychain.hasKey(keyID: keyID))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytes)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncLibraryMetadataFileURL),
            metadataBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))

        try fixture.secureStore.forgetEverything(syncIsQuiescent: true)
        sameProcessBridge.forgetSecureProjectionMetadata()

        XCTAssertEqual(metadataWriteAttempts, 3)
        XCTAssertFalse(fixture.secureStore.hasVault)
        XCTAssertFalse(fixture.keychain.hasKey(keyID: keyID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path),
            "forget must not manufacture an agreed checkpoint before first opt-in")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path),
            "forget must not manufacture an outbox before first opt-in")
        let retainedMetadata = try loadedMetadata()
        let retainedSource = try XCTUnwrap(retainedMetadata.envelope(Self.sourceID))
        XCTAssertNil(retainedSource.x[harness.scenario.variant.extensionKey])
        XCTAssertEqual(retainedSource.x[futureKey], futureValue)
        XCTAssertNil(retainedMetadata.envelope(harness.scenario.variant.copyID))

        // Model Settings re-enabling sync in the same process. No stale bridge cache
        // may recreate the forgotten secure copy or the understood v1 ciphertext.
        SyncCoordinator.runtimeEnabledOverride = true
        let backend = SecureDependencyTransport()
        let reenabled = makeEngine(
            backend: backend,
            bridge: sameProcessBridge,
            sealer: harness.sealer,
            deviceID: fixture.store.deviceID)
        _ = await reenabled.sync()
        let submitted = try backend.submittedBatches.flatMap { batch in
            try batch.map { try WireCodec.open($0, using: harness.sealer) }
        }
        XCTAssertFalse(submitted.contains { $0.id == harness.scenario.variant.copyID })
        for submittedSource in submitted.filter({ $0.id == Self.sourceID }) {
            XCTAssertNil(submittedSource.x[harness.scenario.variant.extensionKey])
            XCTAssertEqual(submittedSource.x[futureKey], futureValue)
        }
        let afterReenable = try sameProcessBridge.currentEnvelopes(
            agreedBase: reenabled.agreedBase)
        XCTAssertNil(afterReenable[harness.scenario.variant.copyID])
        XCTAssertNil(afterReenable[Self.sourceID]?
            .x[harness.scenario.variant.extensionKey])
        XCTAssertEqual(afterReenable[Self.sourceID]?.x[futureKey], futureValue)
    }

    func testVaultForgetDropsStalePlainIntentForActualVaultIDButKeepsDemotion()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare vault-forget ownership fixture")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let demotedID = UUID(
            uuidString: "40000000-0000-4000-8000-0000000000d0")!
        let stillSecure = try secureEnvelope(
            plaintext: Data("actual vault occupant".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let beforeDemotion = try secureEnvelope(
            plaintext: Data("legitimate completed local demotion".utf8),
            id: demotedID,
            revision: 110,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([stillSecure, beforeDemotion])
        _ = try await fixture.session.unlock(reason: "Complete genuine local demotion")
        try SecureSnippetTransitionCoordinator.demote(
            recordID: demotedID,
            store: fixture.store,
            secureStore: fixture.secureStore)
        let demotedSnippet = try XCTUnwrap(fixture.store.snippet(id: demotedID))
        let demotedEnvelope = try XCTUnwrap(
            fixture.bridge.currentEnvelopes(
                agreedBase: SyncBase())[demotedID])
        XCTAssertFalse(demotedEnvelope.secure)
        XCTAssertEqual(demotedEnvelope.fields?.content, Data(demotedSnippet.content.utf8))

        // The stale plain A value models projection metadata/journal intent written by
        // an older ownership decision. The primary vault is the authority during an
        // explicit forget: A must be scrubbed even though its stale envelope says plain.
        let stalePlainForVaultID = SyncEnvelope.plain(
            Snippet(
                id: stillSecure.id,
                name: "Stale plain metadata for secure A",
                keyword: "stale-a",
                content: "must not survive vault forget",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        var base = SyncBase(journalEstablished: true)
        base.recordConfirmed(
            stillSecure,
            recordVersion: SyncRecordVersion(Data("secure-A-generation".utf8)))
        base.recordConfirmed(
            beforeDemotion,
            recordVersion: SyncRecordVersion(Data("secure-B-generation".utf8)))
        var journal = SyncJournal()
        journal.reconcile(
            current: [
                stillSecure.id: stalePlainForVaultID,
                demotedID: demotedEnvelope,
            ],
            confirmed: base,
            deviceID: fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        var metadata = SyncBase()
        metadata.record(stalePlainForVaultID)
        metadata.record(demotedEnvelope)
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncBaseFile.write(
            metadata,
            to: SnippetStorageLocations.syncLibraryMetadataFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        XCTAssertEqual(journal.entry(stillSecure.id)?.desired, stalePlainForVaultID)
        XCTAssertEqual(journal.entry(demotedID)?.desired, demotedEnvelope)
        XCTAssertNotNil(try loadedVault().record(stillSecure.id))
        XCTAssertNil(try loadedVault().record(demotedID))

        SyncCoordinator.runtimeEnabledOverride = false
        try fixture.secureStore.forgetEverything(syncIsQuiescent: true)

        let retainedBase: SyncBase
        switch SyncBaseFile.load(from: SnippetStorageLocations.syncBaseFileURL) {
        case .loaded(let value):
            retainedBase = value
        case .missing, .tooNew, .unreadable:
            XCTFail("forget must leave a readable sync base")
            return
        }
        let retainedJournal = try loadedJournal()
        let retainedMetadata = try loadedMetadata()
        XCTAssertNil(retainedBase.envelope(stillSecure.id))
        XCTAssertNil(retainedBase.recordVersion(stillSecure.id))
        XCTAssertNil(retainedJournal.entry(stillSecure.id),
                     "a stale plain wrapper cannot keep intent for an ID actually in the vault")
        XCTAssertNil(retainedMetadata.envelope(stillSecure.id))

        XCTAssertEqual(retainedJournal.entry(demotedID)?.desired, demotedEnvelope,
                       "forget must preserve the genuine plain destination of a completed demotion")
        XCTAssertEqual(retainedMetadata.envelope(demotedID), demotedEnvelope)
        XCTAssertEqual(fixture.store.snippet(id: demotedID), demotedSnippet)
        XCTAssertNil(retainedBase.envelope(demotedID),
                     "its old secure ancestor is removed while ordinary intent remains")
        XCTAssertEqual(
            retainedBase.recordVersion(demotedID),
            SyncRecordVersion(Data("secure-B-generation".utf8)),
            "the pending demotion keeps its CAS authority")
    }

    func testReviewedAccountResetMaterializesMissingSecurePrerequisiteBeforeNewScopePush()
        async throws
    {
        try await assertReviewedResetMaterializesPrerequisite(.account)
    }

    func testReviewedCheckpointResetMaterializesMissingSecurePrerequisiteBeforeNewScopePush()
        async throws
    {
        try await assertReviewedResetMaterializesPrerequisite(.checkpoint)
    }

    func testAuthenticatedLaterC1CannotSubstituteForPreparedC0DuringRecovery()
        async throws
    {
        let harness = try await makeStagedResetHarness(.account)
        let variant = harness.scenario.variant
        let exactC0 = try XCTUnwrap(
            harness.fixture.bridge.prepareConflictCopyEvidence(
                from: [harness.scenario.survivor]).only)
        var laterC1 = exactC0
        laterC1.hlc = HLC(wallMs: 900, counter: 0, device: Self.deviceB)
        laterC1.origin = Self.deviceB
        var laterFields = try XCTUnwrap(laterC1.fields)
        laterFields.name = "Authenticated C1 cannot stand in for prepared C0"
        laterFields.tags = ["conflict", "later-c1"]
        laterFields.updatedAt = Date(timeIntervalSince1970: 0.9)
        laterC1 = replacingFields(of: laterC1, with: laterFields)
        try SyncSecureConflictMaterializer.validateIncomingSecureCopy(
            laterC1,
            keyring: harness.scenario.keyring,
            vaultKID: harness.scenario.vaultKID)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            laterC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))

        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let receiptsBeforeRejection = try loadedVault().localConflictInstallReceipts
        let journalBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.syncJournalFileURL)
        XCTAssertThrowsError(try harness.fixture.bridge.materializeConflictPrerequisites(
            from: [harness.scenario.survivor],
            preparedConflictCopyEvidence: [laterC1],
            heldConflictCopyIntents: [:],
            expectedPrimary: [variant.copyID: .absent])) { error in
                guard let failure = error as? SyncEngineFailure else {
                    return XCTFail("expected typed quarantine, got \(error)")
                }
                XCTAssertEqual(failure.reason, .localLibraryQuarantined)
            }
        XCTAssertNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore,
            "semantic C0 validation must precede every primary mutation")
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts,
                       receiptsBeforeRejection,
                       "rejected later C1 evidence cannot mint a C0 receipt")
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL),
            journalBytesBefore)
        XCTAssertEqual(harness.backend.accountReviewResetAttempts, 0)
        XCTAssertEqual(harness.backend.checkpointReviewResetAttempts, 0)
    }

    func testReviewedAccountResetPreservesCopyTombstoneAndUploadsC0ThenSourceThenT()
        async throws
    {
        let harness = try await makeStagedResetHarness(.account)
        let variant = harness.scenario.variant
        let preparedC0 = try XCTUnwrap(
            harness.fixture.bridge.prepareConflictCopyEvidence(
                from: [harness.scenario.survivor]).only)
        var journal = try loadedJournal()
        try journal.recordConflictCopyEvidence([preparedC0])
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // Establish real user deletion history in primary storage. The durable C0
        // snapshot predates this action; T is ordinary later intent and must survive
        // the reviewed account boundary without leaving C0 resurrected in the vault.
        let beforeMaterialization = try harness.fixture.bridge.currentSnapshot(
            agreedBase: journal.projectionKnowledge(over: harness.engine.agreedBase))
        let materialized = try harness.fixture.bridge.materializeConflictPrerequisites(
            from: [harness.scenario.survivor],
            preparedConflictCopyEvidence: [preparedC0],
            heldConflictCopyIntents: [:],
            expectedPrimary: [
                variant.copyID: beforeMaterialization.primaryState(for: variant.copyID),
            ])
        XCTAssertEqual(materialized.changedIDs, [variant.copyID])
        XCTAssertTrue(materialized.retryIDs.isEmpty)
        XCTAssertNotNil(try loadedVault().record(variant.copyID))
        let installedC0 = try harness.fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: harness.engine.agreedBase))
        try journal.reconcileDependencies(
            current: installedC0,
            confirmed: harness.engine.agreedBase)
        journal.reconcile(
            current: installedC0,
            confirmed: harness.engine.agreedBase,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 0.5))
        XCTAssertEqual(journal.entry(variant.copyID)?.desired, preparedC0,
            "the normal post-install fence observes C0 before a later user deletion")
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try harness.fixture.secureStore.delete(id: variant.copyID)
        XCTAssertNil(try loadedVault().record(variant.copyID))
        let base = harness.engine.agreedBase
        let currentAfterDelete = try harness.fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        journal.reconcile(
            current: currentAfterDelete,
            confirmed: base,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        let finalT = try XCTUnwrap(journal.entry(variant.copyID)?.desired)
        XCTAssertTrue(finalT.deleted)
        XCTAssertEqual(journal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot, preparedC0)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)

        let restarted = makeEngine(
            backend: harness.backend,
            bridge: SnippetLibraryBridge(
                store: harness.fixture.store,
                secureStore: harness.fixture.secureStore),
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        guard case .halted(.accountChanged, _) = await restarted.sync() else {
            return XCTFail("old account scope must stop for explicit review")
        }
        restarted.clearHaltAfterUserReview()
        let firstOffset = harness.backend.submittedBatches.count
        var state = await restarted.sync()
        if case .waitingForVault = state {
            _ = try await harness.fixture.session.unlock(
                reason: "Resume tombstone-preserving account reset")
            state = await restarted.sync()
        }
        guard !state.isHalted else {
            return XCTFail("reviewed reset must preserve T while recovering C0; got \(state)")
        }
        XCTAssertEqual(harness.backend.accountReviewResetAttempts, 1)
        XCTAssertNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore,
            "account reset must not leave its prerequisite in deleted primary storage")

        for _ in 0..<4 {
            let opened = try harness.backend.submittedBatches.dropFirst(firstOffset)
                .flatMap { batch in
                    try batch.map { try WireCodec.open($0, using: harness.sealer) }
                }
            if opened.count >= 3 { break }
            state = await restarted.sync()
            if case .waitingForVault = state {
                _ = try await harness.fixture.session.unlock(
                    reason: "Continue C0 to source to T account ordering")
            }
        }
        let submitted = try harness.backend.submittedBatches.dropFirst(firstOffset)
            .flatMap { batch in
                try batch.map { try WireCodec.open($0, using: harness.sealer) }
            }
        XCTAssertEqual(submitted.map(\.id), [
            variant.copyID,
            Self.sourceID,
            variant.copyID,
        ])
        XCTAssertEqual(submitted.first, preparedC0)
        XCTAssertNil(submitted.dropFirst().first?.x[variant.extensionKey])
        XCTAssertEqual(submitted.last, finalT)
        XCTAssertNil(try loadedVault().record(variant.copyID))
    }

    func testReviewedResetReconcilesDemotedSiblingBeforeMaterializingMissingCarrier()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare multi-carrier reset recovery")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("multi-carrier ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losingC1 = try secureEnvelope(
            plaintext: Data("first secure body to preserve".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losingC2 = try secureEnvelope(
            plaintext: Data("second secure body to preserve".utf8),
            revision: 250,
            device: "ccccccc3",
            vaultKID: document.kid,
            keyring: keyring)
        let remotePlain = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Multi-carrier plain survivor",
                keyword: "multi-carrier-survivor",
                content: "remote plain winner",
                tags: ["reset"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let firstMerge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losingC1,
            remote: remotePlain)
        let secondMerge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losingC2,
            remote: remotePlain)
        let firstSource = try XCTUnwrap(firstMerge.survivor)
        let secondSource = try XCTUnwrap(secondMerge.survivor)
        let firstVariant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: firstSource).only)
        let secondVariant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: secondSource).only)
        XCTAssertNotEqual(firstVariant.copyID, secondVariant.copyID)
        var sourceWithBothCarriers = firstSource
        sourceWithBothCarriers.x[secondVariant.extensionKey] = try XCTUnwrap(
            secondSource.x[secondVariant.extensionKey])
        XCTAssertEqual(
            Set(try SyncMerge.secureContentConflictVariants(
                in: sourceWithBothCarriers).map(\.copyID)),
            [firstVariant.copyID, secondVariant.copyID])

        var vault = document
        vault.records = [try XCTUnwrap(
            SyncLibraryProjection.vaultRecord(from: losingC1))]
        try VaultFile.write(vault)
        fixture.secureStore.reload(notifyChange: false)
        _ = try await fixture.session.unlock(
            reason: "Unlock multi-carrier reset fixture")

        var base = SyncBase(
            cursor: SyncCursor("old-multi-carrier-scope"),
            cursorKind: .legacy,
            journalEstablished: true,
            accountIdentity: SecureDependencyResetKind.accountA)
        base.recordConfirmed(
            ancestor,
            recordVersion: SyncRecordVersion(Data("multi-carrier-ancestor".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: sourceWithBothCarriers,
            conflictCopies: [])
        XCTAssertTrue(journal.dependency(Self.sourceID)?.requirements.values
            .allSatisfy { $0.snapshot == nil } == true,
                      "the crash-shaped journal must not know either primary copy yet")

        // Model C1 reaching primary storage before the crash and then changing only
        // representation through secure→plain demotion. The journal write above remains
        // stale (snapshot=nil), but C1's deterministic provenance and exact losing body
        // are durable in primary/sidecar projection. A later body edit is intentionally
        // outside this fixture: without a frozen journal snapshot, it cannot also occupy
        // the same deterministic id as the original prerequisite.
        let firstMaterialization = try fixture.bridge.materializeConflictPrerequisites(
            from: [firstSource])
        XCTAssertEqual(firstMaterialization.changedIDs, [firstVariant.copyID])
        XCTAssertNotNil(try loadedVault().record(firstVariant.copyID))
        _ = try fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        _ = try await fixture.session.unlock(
            reason: "Demote the already-materialized sibling")
        try SecureSnippetTransitionCoordinator.demote(
            recordID: firstVariant.copyID,
            store: fixture.store,
            secureStore: fixture.secureStore)
        _ = try await fixture.session.unlock(
            reason: "Unlock multi-carrier reset after demotion reload")
        let demotedC1 = try XCTUnwrap(
            fixture.store.snippet(id: firstVariant.copyID))
        try fixture.store.flushPendingWritesForSync()
        let beforeReset = try fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        let projectedC1 = try XCTUnwrap(beforeReset[firstVariant.copyID])
        XCTAssertFalse(projectedC1.secure)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            projectedC1,
            sourceID: Self.sourceID,
            fingerprint: firstVariant.fingerprint))
        XCTAssertNil(beforeReset[secondVariant.copyID])
        XCTAssertNil(try loadedVault().record(firstVariant.copyID))

        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let staleJournal = try loadedJournal()
        XCTAssertNil(staleJournal.dependency(Self.sourceID)?
            .requirements[firstVariant.fingerprint]?.snapshot)
        XCTAssertNil(staleJournal.dependency(Self.sourceID)?
            .requirements[secondVariant.fingerprint]?.snapshot)

        let backend = SecureDependencyTransport()
        backend.configureScope(identity: SecureDependencyResetKind.accountB)
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "multi-carrier-demotion-reset")
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        guard case .halted(.accountChanged, _) = await engine.sync() else {
            return XCTFail("the old scope must require reviewed recovery")
        }
        engine.clearHaltAfterUserReview()

        var state = await engine.sync()
        let firstBoundarySubmitted = try backend.submittedBatches.flatMap { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertEqual(Set(firstBoundarySubmitted.map(\.id)), [
            firstVariant.copyID,
            secondVariant.copyID,
        ])
        XCTAssertFalse(firstBoundarySubmitted.contains { $0.id == Self.sourceID },
                       "both copies remain ordered before the carrier source")
        if case .waitingForVault = state {
            // A bridge implementation may relock while publishing the still-missing
            // secure sibling. Resume explicitly when it does; C1 reconciliation and C2
            // materialisation are already durable across this optional boundary.
            _ = try await fixture.session.unlock(
                reason: "Resume multi-carrier reset after materialization reload")
            state = await engine.sync()
        }

        guard case .idle = state else {
            return XCTFail(
                "reviewed recovery must reconcile primary C1 before materializing C2; "
                    + "got \(state)")
        }
        XCTAssertEqual(backend.accountReviewResetAttempts, 1)
        XCTAssertNil(try loadedVault().record(firstVariant.copyID),
                     "recovering C2 may not re-promote or overwrite demoted C1")
        XCTAssertNotNil(try loadedVault().record(secondVariant.copyID),
                        "only the still-missing carrier must be materialized")
        let retainedC1 = try XCTUnwrap(
            fixture.store.snippet(id: firstVariant.copyID))
        XCTAssertEqual(retainedC1, demotedC1,
                       "recovering C2 may not rewrite the already-demoted C1 body")
        let recovered = try fixture.bridge.currentEnvelopes(
            agreedBase: engine.agreedBase)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            try XCTUnwrap(recovered[firstVariant.copyID]),
            sourceID: Self.sourceID,
            fingerprint: firstVariant.fingerprint))
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            try XCTUnwrap(recovered[secondVariant.copyID]),
            sourceID: Self.sourceID,
            fingerprint: secondVariant.fingerprint))
        for _ in 0..<4 where !backend.submittedBatches.contains(where: { batch in
            batch.contains { record in
                (try? WireCodec.open(record, using: sealer).id) == Self.sourceID
            }
        }) {
            state = await engine.sync()
            if case .waitingForVault = state {
                _ = try await fixture.session.unlock(
                    reason: "Continue multi-carrier copy-before-source release")
            }
        }
        let submittedBatches = try backend.submittedBatches.map { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        let submitted = submittedBatches.flatMap { $0 }
        XCTAssertEqual(Set(submitted.map(\.id)), [
            firstVariant.copyID,
            secondVariant.copyID,
            Self.sourceID,
        ])
        let sourceBatch = try XCTUnwrap(
            submittedBatches.firstIndex { batch in
                batch.contains { $0.id == Self.sourceID }
            })
        let lastCopyBatch = try XCTUnwrap(
            submittedBatches.lastIndex { batch in
                batch.contains {
                    $0.id == firstVariant.copyID || $0.id == secondVariant.copyID
                }
            })
        XCTAssertGreaterThan(sourceBatch, lastCopyBatch,
            "the materialization relock may split rounds but never reverse C1,C2 → source")
    }

    func testLockedVaultBlocksReviewedResetWithoutLosingCarrierDependency()
        async throws
    {
        let harness = try await makeStagedResetHarness(.account)
        guard case .halted(.accountChanged, _) = await harness.engine.sync() else {
            return XCTFail("the old account binding must require review")
        }
        harness.fixture.session.lock()
        harness.engine.clearHaltAfterUserReview()
        let baseBefore = try Data(
            contentsOf: SnippetStorageLocations.syncBaseFileURL)

        let state = await harness.engine.sync()

        if case .idle = state {
            XCTFail("a locked vault cannot authorize resetting away the carrier-only edge")
        }
        XCTAssertEqual(harness.backend.accountReviewResetAttempts, 0)
        XCTAssertEqual(harness.backend.checkpointReviewResetAttempts, 0)
        XCTAssertTrue(harness.backend.submittedBatches.isEmpty)
        XCTAssertNil(try loadedVault().record(harness.scenario.variant.copyID))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            baseBefore)
        let retained = try loadedJournal()
        let requirement = try XCTUnwrap(
            retained.dependency(Self.sourceID)?.requirements.values.first)
        XCTAssertNil(requirement.snapshot)
        XCTAssertNil(requirement.offered)
        XCTAssertEqual(requirement.carrierKey, harness.scenario.variant.extensionKey)
        XCTAssertEqual(requirement.carrierValue, harness.scenario.carrierValue)
        XCTAssertNotNil(retained.entry(Self.sourceID),
            "the journal-first reset preflight may persist current local source intent")
    }

    func testLocalFullResyncCrashStateMaterializesCarrierBeforeSchedulerReset()
        async throws
    {
        let harness = try await makeStagedLocalFullResyncHarness()
        XCTAssertNil(try loadedVault().record(harness.scenario.variant.copyID))
        let stagedBase = harness.engine.agreedBase
        XCTAssertTrue(stagedBase.requiresTransportFullResync)
        let beforeCopy = harness.backend.submittedBatches.count

        let state = await harness.engine.sync()

        guard case .idle = state else {
            return XCTFail("unlocked crash recovery should complete, got \(state)")
        }
        XCTAssertEqual(harness.backend.localFullResyncAttempts, 1)
        XCTAssertTrue(harness.backend.beforeLocalFullResyncBase?
            .requiresTransportFullResync == true,
                      "the reset hook must observe the durable crash marker")
        let journalAtReset = try XCTUnwrap(
            harness.backend.beforeLocalFullResyncJournal)
        let requirementAtReset = try XCTUnwrap(
            journalAtReset.dependency(Self.sourceID)?.requirements.values.first)
        XCTAssertNotNil(requirementAtReset.snapshot,
                        "the prerequisite snapshot must be durable before scheduler reset")
        XCTAssertTrue(harness.backend.vaultRecordIDsAtLocalFullResync.contains(
            harness.scenario.variant.copyID),
                      "the deterministic copy must reach primary vault storage before reset")
        XCTAssertNotNil(try loadedVault().record(harness.scenario.variant.copyID))
        XCTAssertFalse(harness.engine.agreedBase.requiresTransportFullResync,
                       "the crash marker may clear only after reset returns")

        let submitted = try openedBatches(after: beforeCopy, in: harness)
        let copy = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(copy.id, harness.scenario.variant.copyID)
        XCTAssertFalse(copy.deleted)
        XCTAssertFalse(submitted.flatMap { $0 }.contains { $0.id == Self.sourceID },
                       "the recovered copy still precedes its source after scheduler reset")
    }

    func testLocalFullResyncFreezesCarrierC0WithoutReplacingPrimaryC1()
        async throws
    {
        let harness = try await makeStagedLocalFullResyncHarness()
        let variant = harness.scenario.variant
        let c0Shape = try materializedSecureConflictCopy(
            source: harness.scenario.survivor,
            variant: variant,
            keyring: harness.scenario.keyring,
            vaultKID: harness.scenario.vaultKID)
        var c1Fields = try XCTUnwrap(c0Shape.fields)
        c1Fields.name = "User-edited deterministic copy C1 before rekey"
        c1Fields.tags = ["conflict", "edited", "rekey"]
        c1Fields.updatedAt = Date(timeIntervalSince1970: 0.9)
        let primaryC1 = SyncEnvelope(
            id: c0Shape.id,
            hlc: HLC(wallMs: 900, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: true,
            deleted: false,
            fields: c1Fields,
            x: c0Shape.x)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            primaryC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        _ = try harness.fixture.bridge.applyRemote([primaryC1])
        _ = try await harness.fixture.session.unlock(
            reason: "Stage C1 intent before local full resync")

        let base = harness.engine.agreedBase
        var journal = try loadedJournal()
        XCTAssertNil(journal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        let current = try harness.fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        XCTAssertEqual(current[variant.copyID], primaryC1)
        // Deliberately model the crash before the key-aware dependency reconciliation.
        // Generic intent discovery has seen C1, but the immutable prerequisite slot is
        // still empty and must be filled from the carrier, never from this later value.
        journal.reconcile(
            current: current,
            confirmed: base,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(journal.entry(variant.copyID)?.desired, primaryC1)
        XCTAssertNil(journal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let c1Record = try XCTUnwrap(loadedVault().record(variant.copyID))
        var vaultBeforeRecovery = try loadedVault()
        vaultBeforeRecovery.removeLocalConflictInstallReceipts()

        let restarted = makeEngine(
            backend: harness.backend,
            bridge: SnippetLibraryBridge(
                store: harness.fixture.store,
                secureStore: harness.fixture.secureStore),
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        let firstOffset = harness.backend.submittedBatches.count
        var state = await restarted.sync()
        if case .waitingForVault = state {
            _ = try await harness.fixture.session.unlock(
                reason: "Resume C1-preserving local full resync")
            state = await restarted.sync()
        }
        guard !state.isHalted else {
            return XCTFail(
                "C1 must be held while carrier evidence is frozen before reset; got \(state)")
        }
        XCTAssertEqual(harness.backend.localFullResyncAttempts, 1)
        let journalAtReset = try XCTUnwrap(
            harness.backend.beforeLocalFullResyncJournal)
        let durableC0 = try XCTUnwrap(journalAtReset.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        XCTAssertNotEqual(durableC0, primaryC1)
        XCTAssertEqual(
            try decryptedSecureContent(
                durableC0,
                vaultKID: harness.scenario.vaultKID,
                keyring: harness.scenario.keyring),
            try decryptedSecureContent(
                c0Shape,
                vaultKID: harness.scenario.vaultKID,
                keyring: harness.scenario.keyring))
        XCTAssertEqual(try loadedVault().record(variant.copyID), c1Record,
                       "reset recovery may not leave transient C0 in primary storage")
        let recoveredVault = try loadedVault()
        XCTAssertEqual(recoveredVault.localConflictInstallReceipts, [:],
            "an already-present C1 is never replaced by C0, so no install receipt is minted")
        var recoveredVaultWithoutReceipts = recoveredVault
        recoveredVaultWithoutReceipts.removeLocalConflictInstallReceipts()
        XCTAssertEqual(
            recoveredVaultWithoutReceipts,
            vaultBeforeRecovery,
            "C1 primary state remains unchanged apart from the local-only C0 receipt")

        for _ in 0..<4 {
            let opened = try harness.backend.submittedBatches.dropFirst(firstOffset)
                .flatMap { batch in
                    try batch.map { try WireCodec.open($0, using: harness.sealer) }
                }
            if opened.count >= 3 { break }
            state = await restarted.sync()
            if case .waitingForVault = state {
                _ = try await harness.fixture.session.unlock(
                    reason: "Continue C0 to source to C1 rekey ordering")
            }
        }
        let submitted = try harness.backend.submittedBatches.dropFirst(firstOffset)
            .flatMap { batch in
                try batch.map { try WireCodec.open($0, using: harness.sealer) }
            }
        XCTAssertEqual(submitted.map(\.id), [
            variant.copyID,
            Self.sourceID,
            variant.copyID,
        ])
        XCTAssertEqual(submitted.first, durableC0)
        XCTAssertNil(submitted.dropFirst().first?.x[variant.extensionKey])
        XCTAssertEqual(submitted.last, primaryC1)
        XCTAssertEqual(try loadedVault().record(variant.copyID), c1Record)
    }

    func testReviewedAccountRecoveryCASMissKeepsRacingC1AndDoesNotResetScheduler()
        async throws
    {
        let harness = try await makeStagedResetHarness(.account)
        let variant = harness.scenario.variant
        let preparedC0 = try XCTUnwrap(
            harness.fixture.bridge.prepareConflictCopyEvidence(
                from: [harness.scenario.survivor]).only)
        var racingC1 = preparedC0
        racingC1.hlc = HLC(wallMs: 900, counter: 0, device: Self.deviceB)
        racingC1.origin = Self.deviceB
        var racingFields = try XCTUnwrap(racingC1.fields)
        racingFields.name = "C1 committed after recovery snapshot"
        racingFields.tags = ["conflict", "cas-race"]
        racingFields.updatedAt = Date(timeIntervalSince1970: 0.9)
        racingC1 = replacingFields(of: racingC1, with: racingFields)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            racingC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        let racingRecord = try XCTUnwrap(
            SyncLibraryProjection.vaultRecord(from: racingC1))
        let receiptsBeforeCASMiss = try loadedVault().localConflictInstallReceipts

        let racing = MaterializationRaceLibrary(inner: harness.fixture.bridge) {
            _ = try LibraryTransaction.perform(lockTimeout: 1) { contents in
                guard var vault = contents.vault else {
                    throw SecureDependencyFixtureFailure.expectedReadableMetadata
                }
                vault.records.removeAll { $0.id == racingRecord.id }
                vault.records.append(racingRecord)
                contents.vault = vault
            }
        }
        let engine = makeEngine(
            backend: harness.backend,
            bridge: racing,
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        guard case .halted(.accountChanged, _) = await engine.sync() else {
            return XCTFail("the old account scope must require review before recovery")
        }
        engine.clearHaltAfterUserReview()

        let state = await engine.sync()

        guard case .halted(.localLibraryQuarantined, _) = state else {
            return XCTFail("a recovery CAS miss must retain the old scope for review")
        }
        XCTAssertEqual(racing.materializationCalls, 1)
        XCTAssertEqual(racing.outcomes.only?.retryIDs, [Self.sourceID])
        XCTAssertEqual(harness.backend.accountReviewResetAttempts, 0,
                       "a recovery CAS miss may not reset the scheduler")
        XCTAssertEqual(try loadedVault().record(variant.copyID), racingRecord,
                       "the CAS miss must leave the racing primary record untouched")
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts,
                       receiptsBeforeCASMiss,
                       "a recovery CAS miss cannot mint a C0 install receipt")
        let retainedC0 = try XCTUnwrap(loadedJournal().dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            retainedC0,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        XCTAssertEqual(
            try decryptedSecureContent(
                retainedC0,
                vaultKID: harness.scenario.vaultKID,
                keyring: harness.scenario.keyring),
            try decryptedSecureContent(
                preparedC0,
                vaultKID: harness.scenario.vaultKID,
                keyring: harness.scenario.keyring),
            "the CAS miss must retain authenticated C0 content, not racing C1")
    }

    func testHeldTombstoneRecoveryFromAbsentPrimaryIsNotReportedAsCASMiss()
        async throws
    {
        let harness = try await makeStagedLocalFullResyncHarness()
        let variant = harness.scenario.variant
        let preparedC0 = try XCTUnwrap(
            harness.fixture.bridge.prepareConflictCopyEvidence(
                from: [harness.scenario.survivor]).only)
        let heldTombstone = preparedC0.tombstoned(
            hlc: HLC(wallMs: 900, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let before = try harness.fixture.bridge.currentSnapshot(
            agreedBase: harness.engine.agreedBase)
        XCTAssertEqual(before.primaryState(for: variant.copyID), .absent)

        let outcome = try harness.fixture.bridge.materializeConflictPrerequisites(
            from: [harness.scenario.survivor],
            preparedConflictCopyEvidence: [preparedC0],
            heldConflictCopyIntents: [variant.copyID: heldTombstone],
            expectedPrimary: [variant.copyID: .absent])

        XCTAssertTrue(outcome.retryIDs.isEmpty,
                      "C0 then held T is a completed transaction, not the empty CAS sentinel")
        XCTAssertEqual(outcome.conflictCopyEvidence, [preparedC0])
        XCTAssertNil(try loadedVault().record(variant.copyID))
        XCTAssertNil(harness.fixture.store.snippet(id: variant.copyID))
        XCTAssertEqual(
            try loadedVault().localConflictInstallReceipts,
            [variant.copyID: try preparedC0.envelopeHash()],
            "C0 then held T must preserve the exact install fact in the same transaction")
    }

    func testHeldPlainC1RecoveryFromAbsentPrimaryRecordsExactC0Receipt()
        async throws
    {
        let harness = try await makeStagedLocalFullResyncHarness()
        let variant = harness.scenario.variant
        let preparedC0 = try XCTUnwrap(
            harness.fixture.bridge.prepareConflictCopyEvidence(
                from: [harness.scenario.survivor]).only)
        var heldPlainC1 = SyncEnvelope.plain(
            Snippet(
                id: variant.copyID,
                name: "Held plain C1 after recovery C0",
                keyword: "held-plain-c1",
                content: "final demoted generation",
                tags: ["conflict", "demoted", "recovery"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.9)),
            hlc: HLC(wallMs: 900, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        heldPlainC1.x[SyncMerge.plainConflictCopyExtensionKey] = try XCTUnwrap(
            preparedC0.x[SyncMerge.plainConflictCopyExtensionKey])
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            heldPlainC1,
            sourceID: Self.sourceID,
            fingerprint: variant.fingerprint))
        let before = try harness.fixture.bridge.currentSnapshot(
            agreedBase: harness.engine.agreedBase)
        XCTAssertEqual(before.primaryState(for: variant.copyID), .absent)

        let outcome = try harness.fixture.bridge.materializeConflictPrerequisites(
            from: [harness.scenario.survivor],
            preparedConflictCopyEvidence: [preparedC0],
            heldConflictCopyIntents: [variant.copyID: heldPlainC1],
            expectedPrimary: [variant.copyID: .absent])

        XCTAssertTrue(outcome.retryIDs.isEmpty)
        XCTAssertEqual(outcome.conflictCopyEvidence, [preparedC0])
        XCTAssertNil(try loadedVault().record(variant.copyID),
                     "the transient secure C0 must not replace final plaintext C1")
        XCTAssertEqual(
            harness.fixture.store.snippet(id: variant.copyID)?.content,
            "final demoted generation")
        XCTAssertEqual(
            try loadedVault().localConflictInstallReceipts,
            [variant.copyID: try preparedC0.envelopeHash()],
            "recovery must durably remember exact C0 even when final primary is plain C1")
    }

    func testRestartAfterPreparedC1DeletionCASMissDoesNotReapplyStaleHeldC1()
        async throws
    {
        let harness = try await makeStagedLocalFullResyncHarness()
        let variant = harness.scenario.variant
        let preparedC0 = try XCTUnwrap(
            harness.fixture.bridge.prepareConflictCopyEvidence(
                from: [harness.scenario.survivor]).only)
        var journal = try loadedJournal()
        try journal.recordConflictCopyEvidence([preparedC0])
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let beforeMaterialization = try harness.fixture.bridge.currentSnapshot(
            agreedBase: journal.projectionKnowledge(over: harness.engine.agreedBase))
        let installed = try harness.fixture.bridge.materializeConflictPrerequisites(
            from: [harness.scenario.survivor],
            preparedConflictCopyEvidence: [preparedC0],
            heldConflictCopyIntents: [:],
            expectedPrimary: [
                variant.copyID: beforeMaterialization.primaryState(for: variant.copyID),
            ])
        XCTAssertEqual(installed.changedIDs, [variant.copyID])
        XCTAssertTrue(installed.retryIDs.isEmpty)
        XCTAssertEqual(
            try loadedVault().localConflictInstallReceipts,
            [variant.copyID: try preparedC0.envelopeHash()])
        _ = try await harness.fixture.session.unlock(
            reason: "Create held C1 before post-evidence delete crash")
        try harness.fixture.secureStore.setContent(
            "held C1 deleted after evidence fsync",
            for: variant.copyID)
        let c1Snapshot = try harness.fixture.bridge.currentSnapshot(
            agreedBase: harness.engine.agreedBase)
        let heldC1 = try XCTUnwrap(c1Snapshot.envelopes[variant.copyID])
        XCTAssertNotEqual(heldC1, preparedC0)

        journal.reconcile(
            current: c1Snapshot.envelopes,
            confirmed: harness.engine.agreedBase,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(journal.entry(variant.copyID)?.desired, heldC1)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // Recovery captured C1 as the compare-and-swap input and then the user deleted
        // it. Simulate process death immediately after the bridge reports that miss,
        // before the engine can reconcile/persist the new absence as T. The exact C0
        // receipt remains durable so restart can classify that absence unambiguously.
        try harness.fixture.secureStore.delete(id: variant.copyID)
        XCTAssertNil(try loadedVault().record(variant.copyID))
        let missed = try harness.fixture.bridge.materializeConflictPrerequisites(
            from: [harness.scenario.survivor],
            preparedConflictCopyEvidence: [preparedC0],
            heldConflictCopyIntents: [variant.copyID: heldC1],
            expectedPrimary: [
                variant.copyID: c1Snapshot.primaryState(for: variant.copyID),
            ])
        XCTAssertEqual(missed.retryIDs, [Self.sourceID])
        XCTAssertNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(
            try loadedVault().localConflictInstallReceipts,
            [variant.copyID: try preparedC0.envelopeHash()])

        let restarted = makeEngine(
            backend: harness.backend,
            bridge: SnippetLibraryBridge(
                store: harness.fixture.store,
                secureStore: harness.fixture.secureStore),
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        var state = await restarted.sync()
        if case .waitingForVault = state {
            _ = try await harness.fixture.session.unlock(
                reason: "Resume after post-evidence C1 deletion")
            state = await restarted.sync()
        }

        XCTAssertFalse(state.isHalted)
        XCTAssertNil(try loadedVault().record(variant.copyID),
                     "restart may not replay the stale held C1 over the intervening deletion")
        XCTAssertNil(harness.fixture.store.snippet(id: variant.copyID))
        XCTAssertTrue(try loadedJournal().entry(variant.copyID)?.desired.deleted == true,
                      "the restart must turn the real post-C1 absence into durable T")
    }

    func testOrdinaryRestartAfterPrimaryC1DeletionDoesNotReapplyStaleHeldC1()
        async throws
    {
        let harness = try await makeConflictHarness()
        let variant = harness.scenario.variant
        let initialJournal = try loadedJournal()
        let frozenC0 = try XCTUnwrap(initialJournal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot)
        XCTAssertNil(initialJournal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.offered)
        XCTAssertNil(initialJournal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.acceptedRecordVersion)
        XCTAssertFalse(harness.engine.agreedBase.requiresTransportFullResync,
                       "this regression must exercise ordinary recovery-before-reconcile")
        XCTAssertNotNil(try loadedVault().record(variant.copyID))

        _ = try await harness.fixture.session.unlock(
            reason: "Create ordinary-restart held C1")
        try harness.fixture.secureStore.setContent(
            "ordinary restart must not resurrect this stale C1",
            for: variant.copyID)
        try harness.fixture.secureStore.updateMetadata(
            id: variant.copyID,
            name: "Ordinary-restart stale held C1",
            tags: ["conflict", "ordinary-restart", "deleted"])
        let c1Snapshot = try harness.fixture.bridge.currentSnapshot(
            agreedBase: initialJournal.projectionKnowledge(
                over: harness.engine.agreedBase))
        let heldC1 = try XCTUnwrap(c1Snapshot.envelopes[variant.copyID])
        XCTAssertNotEqual(heldC1, frozenC0)

        var journal = initialJournal
        journal.reconcile(
            current: c1Snapshot.envelopes,
            confirmed: harness.engine.agreedBase,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(journal.entry(variant.copyID)?.desired, heldC1)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // No reset helper runs in this scenario. Restart's frozen-C0 recovery is the
        // first reader of the stale C1 entry, so it must consult the primary-atomic
        // install fact before deciding whether held C1 is still legitimate intent.
        try harness.fixture.secureStore.delete(id: variant.copyID)
        XCTAssertNil(try loadedVault().record(variant.copyID))
        XCTAssertEqual(try loadedJournal().entry(variant.copyID)?.desired, heldC1,
                       "simulate death before ordinary reconcile can record the deletion")

        let restartedFixture = recreateFixture(using: harness.fixture)
        _ = try await restartedFixture.session.unlock(
            reason: "Resume ordinary recovery after C1 deletion")
        let restarted = makeEngine(
            backend: harness.backend,
            bridge: restartedFixture.bridge,
            sealer: harness.sealer,
            deviceID: restartedFixture.store.deviceID)
        var state = await restarted.sync()
        if case .waitingForVault = state {
            _ = try await restartedFixture.session.unlock(
                reason: "Continue ordinary recovery after C1 deletion")
            state = await restarted.sync()
        }

        XCTAssertFalse(state.isHalted)
        XCTAssertEqual(harness.backend.localFullResyncAttempts, 0)
        XCTAssertEqual(harness.backend.accountReviewResetAttempts, 0)
        XCTAssertEqual(harness.backend.checkpointReviewResetAttempts, 0)
        XCTAssertNil(try loadedVault().record(variant.copyID),
                     "ordinary restart may not reapply stale held C1 over deletion")
        XCTAssertNil(restartedFixture.store.snippet(id: variant.copyID))
        let recoveredJournal = try loadedJournal()
        XCTAssertTrue(recoveredJournal.entry(variant.copyID)?.desired.deleted == true,
                      "ordinary recovery must replace stale held C1 with durable T")
        XCTAssertEqual(recoveredJournal.dependency(Self.sourceID)?
            .requirements[variant.fingerprint]?.snapshot, frozenC0,
            "the exact C0 prerequisite remains ordered ahead of the deletion")
    }

    func testLockedVaultDefersLocalFullResyncWithoutResettingOrLosingProtocolIntent()
        async throws
    {
        let harness = try await makeStagedLocalFullResyncHarness()
        harness.fixture.session.lock()
        let baseBefore = try Data(
            contentsOf: SnippetStorageLocations.syncBaseFileURL)

        let state = await harness.engine.sync()

        guard case .waitingForVault = state else {
            return XCTFail("a locked vault should defer local full resync, got \(state)")
        }
        XCTAssertEqual(harness.backend.localFullResyncAttempts, 0)
        XCTAssertTrue(harness.backend.submittedBatches.isEmpty)
        XCTAssertNil(try loadedVault().record(harness.scenario.variant.copyID))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            baseBefore)
        XCTAssertTrue(harness.engine.agreedBase.requiresTransportFullResync)
        let retained = try loadedJournal()
        let requirement = try XCTUnwrap(
            retained.dependency(Self.sourceID)?.requirements.values.first)
        XCTAssertNil(requirement.snapshot)
        XCTAssertNil(requirement.offered)
        XCTAssertEqual(requirement.carrierKey, harness.scenario.variant.extensionKey)
        XCTAssertEqual(requirement.carrierValue, harness.scenario.carrierValue)
        XCTAssertNotNil(retained.entry(Self.sourceID),
            "the journal-first reset preflight may persist current local source intent")
    }

    func testTransportRekeyRejectsConfirmedUnrelatedCopyOccupantBeforeProtocolWrites()
        throws
    {
        let ancestor = plainEnvelope(
            revision: 100,
            device: Self.deviceA,
            body: "ancestor")
        let losing = plainEnvelope(
            revision: 200,
            device: Self.deviceA,
            body: "losing edit")
        let winning = plainEnvelope(
            revision: 300,
            device: Self.deviceB,
            body: "winning edit")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try XCTUnwrap(merge.survivor)
        let authenticCopy = try XCTUnwrap(merge.conflictCopies.only)
        var occupantFields = try XCTUnwrap(authenticCopy.fields)
        occupantFields.name = "unrelated deterministic-ID occupant"
        occupantFields.content = Data("must never acquire conflict-copy authority".utf8)
        var malformedProvenance = authenticCopy.x
        malformedProvenance[SyncMerge.plainConflictCopyExtensionKey] = .object([
            "version": .int(1),
        ])
        let occupant = SyncEnvelope(
            id: authenticCopy.id,
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: false,
            deleted: false,
            fields: occupantFields,
            x: malformedProvenance)
        XCTAssertFalse(SyncMerge.matchesConflictCopyProvenance(
            occupant,
            sourceID: source.id,
            fingerprint: try XCTUnwrap(
                SyncMerge.conflictCopyProvenance(in: authenticCopy)?.fingerprint)))
        XCTAssertNil(SyncMerge.conflictCopyProvenance(in: occupant))

        var base = SyncBase(journalEstablished: true)
        base.recordConfirmed(
            source,
            recordVersion: SyncRecordVersion(Data("source-before-rekey".utf8)))
        base.recordConfirmed(
            occupant,
            recordVersion: SyncRecordVersion(Data("occupant-before-rekey".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: source,
            conflictCopies: [authenticCopy])
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let baseBefore = try Data(
            contentsOf: SnippetStorageLocations.syncBaseFileURL)
        let journalBefore = try Data(
            contentsOf: SnippetStorageLocations.syncJournalFileURL)

        let fingerprintKey = "SnippetsSyncWireKeyFingerprint"
        let previousFingerprint = UserDefaults.standard.object(forKey: fingerprintKey)
        defer {
            if let previousFingerprint {
                UserDefaults.standard.set(previousFingerprint, forKey: fingerprintKey)
            } else {
                UserDefaults.standard.removeObject(forKey: fingerprintKey)
            }
        }
        UserDefaults.standard.set("stale-conflict-dependency-key", forKey: fingerprintKey)
        SyncCoordinator.runtimeEnabledOverride = true
        let library = RekeyCollisionLibrary(envelopes: [
            source.id: source,
        ])
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.rekey-collision-tests."
                + UUID().uuidString.lowercased(),
            inMemory: true)
        let transport = SecureDependencyTransport()
        let coordinator = SyncCoordinator(
            library: library,
            keys: SyncKeyStore(keychain: keychain),
            device: Self.deviceB,
            transportFactory: { transport })
        defer { coordinator.stop() }

        coordinator.start()

        XCTAssertEqual(library.currentEnvelopeCallCount, 1,
                       "rekey must reach active-v2 dependency validation exactly once")
        XCTAssertNil(coordinator.engine,
                     "copy-ID provenance collision must abort before engine construction")
        guard case .cannotStart = coordinator.readiness else {
            return XCTFail("the rekey collision must be a retryable start failure")
        }
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            baseBefore,
            "failed rekey must leave the confirmed checkpoint byte-for-byte intact")
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL),
            journalBefore,
            "failed rekey must leave the active v2 dependency byte-for-byte intact")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: fingerprintKey),
            "stale-conflict-dependency-key",
            "failed validation must not commit the new wire-key fingerprint")
        XCTAssertEqual(transport.localFullResyncAttempts, 0)
        XCTAssertTrue(transport.submittedBatches.isEmpty)
    }

    func testSecondConflictDuringFirstSourceCASCompletesNewCopyAndReleaseWithoutWedge()
        async throws
    {
        let harness = try await makeConflictHarness()
        _ = await harness.engine.sync()
        XCTAssertNotNil(harness.engine.agreedBase.envelope(harness.scenario.variant.copyID))

        // Turn the carrier-free source release into a genuinely new secure edit. The
        // backend concurrently accepts a newer plain edit immediately before checking
        // this offer's old CAS generation, forcing a second secure-loser conflict.
        _ = try await harness.fixture.session.unlock(
            reason: "Promote source before the second conflict")
        try SecureSnippetTransitionCoordinator.promote(
            snippetID: Self.sourceID,
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)
        _ = try await harness.fixture.session.unlock(
            reason: "Materialize the second secure conflict")
        let remoteSecond = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Second remote winner",
                keyword: "second-remote",
                content: "second remote body",
                tags: ["second"],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970 + 60)),
            hlc: HLC(
                wallMs: UInt64(Date().timeIntervalSince1970 * 1_000) + 60_000,
                counter: 0,
                device: Self.deviceB),
            origin: Self.deviceB)
        harness.backend.injectBeforeNextSubmit(
            try WireCodec.seal(remoteSecond, using: harness.sealer))
        let beforeConflict = harness.backend.submittedBatches.count

        var state = await harness.engine.sync()

        if case .waitingForVault = state {
            // Cleaning the first carrier reloads the vault before the fetched CAS
            // conflict is materialized. That durability boundary deliberately locks
            // the session; resume the same round after user presence without weakening
            // the eventual copy-before-source ordering contract below.
            _ = try await harness.fixture.session.unlock(
                reason: "Resume second conflict after carrier cleanup reload")
            state = await harness.engine.sync()
        }
        guard case .idle = state else {
            return XCTFail("the second conflict must remain retryable, got \(state)")
        }

        let rejectedRelease = try openedBatches(after: beforeConflict, in: harness)
        XCTAssertEqual(rejectedRelease.only?.only?.id, Self.sourceID)
        XCTAssertTrue(rejectedRelease.only?.only?.secure == true)
        let afterConflict = try harness.fixture.bridge.currentEnvelopes(
            agreedBase: harness.engine.agreedBase)
        let sourceWithSecond = try XCTUnwrap(afterConflict[Self.sourceID])
        let variants = try SyncMerge.secureContentConflictVariants(in: sourceWithSecond)
        let second = try XCTUnwrap(variants.only)
        XCTAssertNotEqual(second.copyID, harness.scenario.variant.copyID)
        XCTAssertNil(sourceWithSecond.x[harness.scenario.variant.extensionKey],
                     "the first carrier was already cleaned and must not return")
        XCTAssertNotNil(sourceWithSecond.x[second.extensionKey])
        XCTAssertNotNil(try loadedVault().record(second.copyID),
                        "the second losing secure edit must be materialized locally")

        var offset = harness.backend.submittedBatches.count
        _ = await harness.engine.sync()
        var submitted = try openedBatches(after: offset, in: harness)
        let secondCopy = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(secondCopy.id, second.copyID)
        XCTAssertFalse(secondCopy.deleted)
        XCTAssertFalse(submitted.flatMap { $0 }.contains { $0.id == Self.sourceID })

        offset = harness.backend.submittedBatches.count
        _ = await harness.engine.sync()
        submitted = try openedBatches(after: offset, in: harness)
        let finalSource = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(finalSource.id, Self.sourceID)
        XCTAssertNil(finalSource.x[second.extensionKey])
        XCTAssertNil(finalSource.x[harness.scenario.variant.extensionKey])
        XCTAssertFalse(SyncMerge.hasUnresolvedContentConflict(finalSource))
        XCTAssertEqual(finalSource.fields?.content, remoteSecond.fields?.content)

        let backend = try openedBackend(in: harness)
        XCTAssertFalse(try XCTUnwrap(backend[Self.sourceID]).deleted)
        XCTAssertFalse(SyncMerge.hasUnresolvedContentConflict(backend[Self.sourceID]))
        XCTAssertNotNil(backend[harness.scenario.variant.copyID])
        XCTAssertNotNil(backend[second.copyID])
        let retainedJournal = try loadedJournal()
        XCTAssertNil(retainedJournal.dependency(Self.sourceID),
                     "the second source ACK must retire the combined dependency graph")
    }

    func testLaterCorruptStandaloneSecureCopyCannotOverwriteMaterializedDependencyCopy()
        async throws
    {
        let harness = try await makeConflictHarness()

        // Confirm the already-authenticated copy while retaining the source carrier.
        // The next source release is a separate round, so the dependency is still live.
        _ = await harness.engine.sync()
        let copyID = harness.scenario.variant.copyID
        let confirmedCopy = try XCTUnwrap(harness.engine.agreedBase.envelope(copyID))
        let carryingSource = try XCTUnwrap(
            harness.fixture.bridge.currentEnvelopes(
                agreedBase: harness.engine.agreedBase)[Self.sourceID])
        XCTAssertEqual(
            carryingSource.x[harness.scenario.variant.extensionKey],
            harness.scenario.carrierValue)
        XCTAssertNotNil(try loadedJournal().dependency(Self.sourceID))

        let goodRecord = try XCTUnwrap(loadedVault().record(copyID))
        let vaultBefore = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let receiptsBeforeCollision = try loadedVault().localConflictInstallReceipts
        let baseBefore = try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL)
        let journalBefore = try Data(
            contentsOf: SnippetStorageLocations.syncJournalFileURL)

        var corruptCopy = try laterStandaloneCopy(in: harness)
        var corruptFields = try XCTUnwrap(corruptCopy.fields)
        corruptFields.content = Data("not-a-valid-sealed-conflict-copy".utf8)
        corruptCopy = replacingFields(of: corruptCopy, with: corruptFields)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            corruptCopy,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        XCTAssertEqual(
            corruptCopy.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text,
            harness.scenario.vaultKID)
        XCTAssertNoThrow(try SyncMerge.validateContentConflictExtensions(in: corruptCopy),
                         "the outer envelope is structurally valid; only its sealed body is corrupt")
        _ = try await harness.fixture.session.unlock(
            reason: "Authenticate a later standalone conflict copy")

        do {
            _ = try harness.fixture.bridge.applyRemote([corruptCopy])
            XCTFail("an unauthenticated standalone conflict copy must be quarantined")
        } catch let failure as SyncEngineFailure {
            XCTAssertEqual(failure.reason, .localLibraryQuarantined)
        } catch {
            XCTFail("expected a sync quarantine, got \(error)")
        }
        let retainedRecord = try XCTUnwrap(loadedVault().record(copyID))
        XCTAssertEqual(retainedRecord.sealed, goodRecord.sealed)
        XCTAssertEqual(retainedRecord.contentHash, goodRecord.contentHash)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBefore,
            "the later corrupt copy must be rejected before the vault transaction commits")
        XCTAssertEqual(try loadedVault().localConflictInstallReceipts,
                       receiptsBeforeCollision,
                       "a quarantined copy collision cannot mint or replace a receipt")
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            baseBefore,
            "a rejected standalone copy must not become a confirmed generation")
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL),
            journalBefore,
            "quarantine must preserve the active copy-before-source dependency")
        XCTAssertEqual(harness.engine.agreedBase.envelope(copyID), confirmedCopy)
        XCTAssertNotNil(try loadedJournal().dependency(Self.sourceID))
    }

    func testLaterValidStandaloneSecureConflictCopyIsAccepted() async throws {
        let harness = try await makeConflictHarness()
        _ = await harness.engine.sync()
        let copyID = harness.scenario.variant.copyID
        let goodRecord = try XCTUnwrap(loadedVault().record(copyID))
        let standaloneCopy = try laterStandaloneCopy(in: harness)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            standaloneCopy,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        _ = try await harness.fixture.session.unlock(
            reason: "Accept a valid later standalone conflict copy")

        let outcome = try harness.fixture.bridge.applyRemote([standaloneCopy])

        XCTAssertEqual(outcome.changedIDs, [copyID])
        XCTAssertTrue(outcome.deferredIDs.isEmpty)
        let accepted = try XCTUnwrap(loadedVault().record(copyID))
        XCTAssertEqual(accepted.sealed, goodRecord.sealed)
        XCTAssertEqual(accepted.contentHash, goodRecord.contentHash)
        XCTAssertEqual(accepted.hlc, standaloneCopy.hlc)
        XCTAssertEqual(accepted.updatedAt, standaloneCopy.fields?.updatedAt)
        XCTAssertEqual(
            accepted.x[SyncMerge.plainConflictCopyExtensionKey],
            goodRecord.x[SyncMerge.plainConflictCopyExtensionKey])
    }

    func testLockedVaultDefersStandaloneSecureConflictCopyWithoutMutation()
        async throws
    {
        let harness = try await makeConflictHarness()
        let copyID = harness.scenario.variant.copyID
        let standaloneCopy = try laterStandaloneCopy(in: harness)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            standaloneCopy,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        let goodRecord = try XCTUnwrap(loadedVault().record(copyID))
        let vaultBefore = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let baseBefore = try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL)
        let journalBefore = try Data(
            contentsOf: SnippetStorageLocations.syncJournalFileURL)
        harness.fixture.session.lock()

        let outcome = try harness.fixture.bridge.applyRemote([standaloneCopy])

        XCTAssertTrue(outcome.changedIDs.isEmpty)
        XCTAssertEqual(outcome.deferredIDs, [copyID])
        let retainedRecord = try XCTUnwrap(loadedVault().record(copyID))
        XCTAssertEqual(retainedRecord.sealed, goodRecord.sealed)
        XCTAssertEqual(retainedRecord.contentHash, goodRecord.contentHash)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBefore,
            "a locked vault must defer the standalone copy before primary mutation")
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            baseBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL),
            journalBefore)
        XCTAssertNotNil(try loadedJournal().dependency(Self.sourceID))
    }

    func testLockedVaultAcceptsExactKnownSecureConflictCopyEchoWithoutMutation()
        async throws
    {
        let harness = try await makeConflictHarness()
        let copyID = harness.scenario.variant.copyID
        let exactEcho = try XCTUnwrap(
            harness.fixture.bridge.currentEnvelopes(
                agreedBase: harness.engine.agreedBase)[copyID])
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            exactEcho,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        let goodRecord = try XCTUnwrap(loadedVault().record(copyID))
        let vaultBefore = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let baseBefore = try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL)
        let journalBefore = try Data(
            contentsOf: SnippetStorageLocations.syncJournalFileURL)
        harness.fixture.session.lock()

        let outcome = try harness.fixture.bridge.applyRemote([exactEcho])

        XCTAssertTrue(outcome.deferredIDs.isEmpty,
                      "an exact primary echo needs no key and must be confirmable while locked")
        XCTAssertTrue(outcome.incompatibleVaultIDs.isEmpty)
        let retained = try XCTUnwrap(loadedVault().record(copyID))
        XCTAssertEqual(retained.sealed, goodRecord.sealed)
        XCTAssertEqual(retained.contentHash, goodRecord.contentHash)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            baseBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL),
            journalBefore)
        XCTAssertNotNil(try loadedJournal().dependency(Self.sourceID))
    }

    func testSecureTombstoneWithoutVaultKIDCannotDeletePlainOccupant() throws {
        let fixture = makeFixture()
        let plain = plainEnvelope(
            revision: 100,
            device: Self.deviceA,
            body: "plain occupant protected from unscoped secure deletion")
        _ = try fixture.bridge.applyRemote([plain])
        let snippetBefore = try XCTUnwrap(fixture.store.snippet(id: plain.id))
        let libraryBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        let tombstone = SyncEnvelope.tombstone(
            id: plain.id,
            secure: true,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [:])
        let classification = fixture.bridge.classifyRemote([tombstone])
        XCTAssertTrue(classification.applicable.isEmpty)
        XCTAssertTrue(classification.deferredIDs.isEmpty,
                      "an occupied unscoped secure tombstone is incompatible, not retryable")
        XCTAssertEqual(classification.incompatibleVaultIDs, [plain.id])

        do {
            let outcome = try fixture.bridge.applyRemote([tombstone])
            XCTAssertFalse(outcome.changedIDs.contains(plain.id))
        } catch let failure as SyncEngineFailure {
            XCTAssertTrue(
                failure.reason == .localLibraryQuarantined
                    || failure.reason == .vaultUnreadable)
        }

        XCTAssertEqual(fixture.store.snippet(id: plain.id), snippetBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore,
            "an unscoped secure tombstone may not erase a plaintext UUID occupant")
    }

    func testStampedSecureTombstoneCannotDeletePlainOccupantWhenLocalVaultIsAbsent()
        throws
    {
        let fixture = makeFixture()
        let plain = plainEnvelope(
            revision: 100,
            device: Self.deviceA,
            body: "plain occupant with no local vault")
        _ = try fixture.bridge.applyRemote([plain])
        let snippetBefore = try XCTUnwrap(fixture.store.snippet(id: plain.id))
        let libraryBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        XCTAssertNil(fixture.secureStore.document)
        let tombstone = SyncEnvelope.tombstone(
            id: plain.id,
            secure: true,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [
                SyncEnvelope.vaultKeyIDExtensionKey: .string("remote-vault-scope"),
            ])

        let classification = fixture.bridge.classifyRemote([tombstone])
        XCTAssertTrue(classification.applicable.isEmpty,
                      "without a local vault, remote scope cannot authorize deleting plain data")
        XCTAssertTrue(
            classification.deferredIDs == [plain.id]
                || classification.incompatibleVaultIDs == [plain.id])
        do {
            let outcome = try fixture.bridge.applyRemote([tombstone])
            XCTAssertFalse(outcome.changedIDs.contains(plain.id))
            XCTAssertTrue(
                outcome.deferredIDs == [plain.id]
                    || outcome.incompatibleVaultIDs == [plain.id])
        } catch let failure as SyncEngineFailure {
            XCTAssertTrue(
                failure.reason == .vaultUnreadable
                    || failure.reason == .localLibraryQuarantined)
        }
        XCTAssertEqual(fixture.store.snippet(id: plain.id), snippetBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore)

        let absentID = UUID(
            uuidString: "40000000-0000-4000-8000-0000000000ac")!
        let absentTombstone = SyncEnvelope.tombstone(
            id: absentID,
            secure: true,
            hlc: HLC(wallMs: 201, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [
                SyncEnvelope.vaultKeyIDExtensionKey: .string("remote-vault-scope"),
            ])
        let absentClassification = fixture.bridge.classifyRemote([absentTombstone])
        XCTAssertEqual(absentClassification.applicable, [absentTombstone])
        XCTAssertTrue(absentClassification.deferredIDs.isEmpty)
        XCTAssertTrue(absentClassification.incompatibleVaultIDs.isEmpty)
        let absentOutcome = try fixture.bridge.applyRemote([absentTombstone])
        XCTAssertTrue(absentOutcome.changedIDs.isEmpty)
    }

    func testSecureTombstoneWithoutVaultKIDCannotDeleteSecureOccupant()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare scoped secure occupant")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secure = try secureEnvelope(
            plaintext: Data("secure occupant protected from unscoped deletion".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([secure])
        let recordBefore = try XCTUnwrap(loadedVault().record(secure.id))
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let tombstone = SyncEnvelope.tombstone(
            id: secure.id,
            secure: true,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [:])
        let classification = fixture.bridge.classifyRemote([tombstone])
        XCTAssertTrue(classification.applicable.isEmpty)
        XCTAssertTrue(classification.deferredIDs.isEmpty,
                      "an occupied unscoped secure tombstone is incompatible, not retryable")
        XCTAssertEqual(classification.incompatibleVaultIDs, [secure.id])

        do {
            let outcome = try fixture.bridge.applyRemote([tombstone])
            XCTAssertFalse(outcome.changedIDs.contains(secure.id))
        } catch let failure as SyncEngineFailure {
            XCTAssertTrue(
                failure.reason == .localLibraryQuarantined
                    || failure.reason == .vaultUnreadable)
        }

        XCTAssertEqual(try loadedVault().record(secure.id), recordBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore,
            "a secure deletion without authenticated vault scope must not touch ciphertext")
    }

    func testOccupiedSecureTombstoneWithoutVaultKIDHaltsStickyInsteadOfDeferring()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare unscoped tombstone halt")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secure = try secureEnvelope(
            plaintext: Data("occupied secure record must survive".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([secure])
        _ = try await fixture.session.unlock(reason: "Project occupied secure baseline")
        let projected = try XCTUnwrap(
            fixture.bridge.currentEnvelopes(agreedBase: SyncBase())[secure.id])
        let recordBefore = try XCTUnwrap(loadedVault().record(secure.id))
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)

        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "unscoped-secure-tombstone-halt")
        backend.seed([try WireCodec.seal(projected, using: sealer)])
        let stored = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            projected,
            recordVersion: try XCTUnwrap(stored.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let unscopedTombstone = SyncEnvelope.tombstone(
            id: secure.id,
            secure: true,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [:])
        backend.seed([try WireCodec.seal(unscopedTombstone, using: sealer)])
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)

        guard case .halted(.vaultUnreadable, _) = await engine.sync() else {
            return XCTFail("occupied unscoped secure deletion must halt as incompatible")
        }
        XCTAssertEqual(try loadedVault().record(secure.id), recordBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore)
        let submissionsAtHalt = backend.submittedBatches.count
        guard case .halted(.vaultUnreadable, _) = await engine.sync() else {
            return XCTFail("the incompatible-vault halt must be sticky")
        }
        XCTAssertEqual(backend.submittedBatches.count, submissionsAtHalt)
        XCTAssertEqual(try loadedVault().record(secure.id), recordBefore)
    }

    func testSecureTombstoneWithoutVaultKIDIsNoOpForAbsentID() throws {
        let fixture = makeFixture()
        let absentID = UUID(
            uuidString: "40000000-0000-4000-8000-0000000000ab")!
        let tombstone = SyncEnvelope.tombstone(
            id: absentID,
            secure: true,
            hlc: HLC(wallMs: 100, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [:])
        let classification = fixture.bridge.classifyRemote([tombstone])
        XCTAssertEqual(classification.applicable, [tombstone])
        XCTAssertTrue(classification.deferredIDs.isEmpty)
        XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty)

        let outcome = try fixture.bridge.applyRemote([tombstone])

        XCTAssertTrue(outcome.changedIDs.isEmpty)
        XCTAssertFalse(fixture.store.snippets.contains { $0.id == absentID })
        XCTAssertNil(fixture.secureStore.record(absentID))
    }

    func testLegacyUnstampedExactSecureEchoIsSafeLockedButChangedGenerationRequiresAuthentication()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare exact legacy unstamped secure echo")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let initial = try secureEnvelope(
            plaintext: Data("legacy exact secure body".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([initial])
        let exactStamped = try XCTUnwrap(
            fixture.bridge.currentEnvelopes(agreedBase: SyncBase())[Self.sourceID])
        var exactLegacy = exactStamped
        exactLegacy.x[SyncEnvelope.vaultKeyIDExtensionKey] = nil
        XCTAssertEqual(exactLegacy.fields, exactStamped.fields)
        XCTAssertEqual(exactLegacy.hlc, exactStamped.hlc)
        XCTAssertEqual(exactLegacy.origin, exactStamped.origin)
        XCTAssertEqual(
            exactLegacy.x[SyncEnvelope.vaultContentHashExtensionKey],
            exactStamped.x[SyncEnvelope.vaultContentHashExtensionKey])
        let recordBefore = try XCTUnwrap(loadedVault().record(Self.sourceID))
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        fixture.session.lock()

        let exactOutcome = try fixture.bridge.applyRemote([exactLegacy])

        XCTAssertTrue(exactOutcome.deferredIDs.isEmpty,
                      "an exact legacy echo proves it needs no decryption while locked")
        XCTAssertTrue(exactOutcome.incompatibleVaultIDs.isEmpty)
        XCTAssertTrue(exactOutcome.changedIDs.isEmpty,
                      "an exact legacy echo is an accepted primary no-op")
        XCTAssertEqual(try loadedVault().record(Self.sourceID), recordBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore)

        var changedLegacy = try secureEnvelope(
            plaintext: Data("authenticated changed legacy body".utf8),
            revision: 200,
            device: Self.deviceB,
            vaultKID: document.kid,
            keyring: keyring)
        changedLegacy.x[SyncEnvelope.vaultKeyIDExtensionKey] = nil

        let deferred = try fixture.bridge.applyRemote([changedLegacy])

        XCTAssertTrue(deferred.changedIDs.isEmpty)
        XCTAssertEqual(deferred.deferredIDs, [Self.sourceID],
                       "any non-exact unstamped generation still needs AEAD/HMAC validation")
        XCTAssertEqual(try loadedVault().record(Self.sourceID), recordBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore)

        _ = try await fixture.session.unlock(
            reason: "Authenticate changed legacy unstamped generation")
        let authenticated = try fixture.bridge.applyRemote([changedLegacy])

        XCTAssertEqual(authenticated.changedIDs, [Self.sourceID])
        XCTAssertTrue(authenticated.deferredIDs.isEmpty)
        let changedRecord = try XCTUnwrap(loadedVault().record(Self.sourceID))
        XCTAssertEqual(changedRecord.hlc, changedLegacy.hlc)
        XCTAssertEqual(
            try SnippetCrypto.open(
                changedRecord.sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: document.kid,
                    recordID: Self.sourceID),
                keyring: keyring),
            Data("authenticated changed legacy body".utf8))
    }

    func testLiveSecureEnvelopeWithoutVaultKIDCannotReplaceUnauthenticatedOccupant()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare authenticated secure occupant")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secure = try secureEnvelope(
            plaintext: Data("known-good authenticated body".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([secure])
        let recordBefore = try XCTUnwrap(loadedVault().record(secure.id))
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        var forgedFields = try XCTUnwrap(secure.fields)
        forgedFields.content = Data("not-a-valid-vault-ciphertext".utf8)
        forgedFields.updatedAt = Date(timeIntervalSince1970: 0.2)
        var forgedX = secure.x
        forgedX[SyncEnvelope.vaultKeyIDExtensionKey] = nil
        let forged = SyncEnvelope(
            id: secure.id,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: true,
            deleted: false,
            fields: forgedFields,
            x: forgedX)

        do {
            let outcome = try fixture.bridge.applyRemote([forged])
            XCTAssertFalse(outcome.changedIDs.contains(secure.id))
        } catch let failure as SyncEngineFailure {
            XCTAssertTrue(
                failure.reason == .localLibraryQuarantined
                    || failure.reason == .vaultUnreadable)
        }

        XCTAssertEqual(try loadedVault().record(secure.id), recordBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore,
            "missing scope plus failed AEAD authentication cannot replace a vault record")
    }

    func testLiveSecureEnvelopeWithoutVaultKIDCannotRemovePlainOccupantWithoutAEAD()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        _ = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Protect plain occupant from forged secure row")
        let plain = plainEnvelope(
            revision: 100,
            device: Self.deviceA,
            body: "plain body must remain authoritative")
        _ = try fixture.bridge.applyRemote([plain])
        let snippetBefore = try XCTUnwrap(fixture.store.snippet(id: plain.id))
        let libraryBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let fields = SyncEnvelope.Fields(
            name: "Forged unstamped secure replacement",
            keyword: "forged",
            content: Data("not-a-valid-vault-ciphertext".utf8),
            tags: [],
            isEnabled: true,
            isPinned: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 0.2))
        let forged = SyncEnvelope(
            id: plain.id,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: true,
            deleted: false,
            fields: fields,
            x: [
                SyncEnvelope.vaultContentHashExtensionKey:
                    .string(String(repeating: "a", count: 32)),
            ])

        do {
            let outcome = try fixture.bridge.applyRemote([forged])
            XCTAssertFalse(outcome.changedIDs.contains(plain.id))
        } catch let failure as SyncEngineFailure {
            XCTAssertTrue(
                failure.reason == .localLibraryQuarantined
                    || failure.reason == .vaultUnreadable)
        }

        XCTAssertEqual(fixture.store.snippet(id: plain.id), snippetBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore)
        XCTAssertNil(try loadedVault().record(plain.id),
                     "failed authentication may not move an ordinary row into the vault")
    }

    func testAbsentLiveSecureEnvelopeWithoutVaultKIDRequiresUnlockAndAEADBeforeAdoption()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare valid legacy unstamped record")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let absentID = UUID(
            uuidString: "40000000-0000-4000-8000-0000000000ac")!
        var unstamped = try secureEnvelope(
            plaintext: Data("valid legacy unstamped secure body".utf8),
            id: absentID,
            revision: 100,
            device: Self.deviceB,
            vaultKID: document.kid,
            keyring: keyring)
        unstamped.x[SyncEnvelope.vaultKeyIDExtensionKey] = nil
        fixture.session.lock()

        let deferred = try fixture.bridge.applyRemote([unstamped])

        XCTAssertTrue(deferred.changedIDs.isEmpty)
        XCTAssertEqual(deferred.deferredIDs, [absentID])
        XCTAssertNil(try loadedVault().record(absentID))

        _ = try await fixture.session.unlock(reason: "Authenticate valid legacy unstamped record")
        let applied = try fixture.bridge.applyRemote([unstamped])

        XCTAssertEqual(applied.changedIDs, [absentID])
        XCTAssertTrue(applied.deferredIDs.isEmpty)
        let adopted = try XCTUnwrap(loadedVault().record(absentID))
        XCTAssertEqual(adopted.sealed, String(data: try XCTUnwrap(unstamped.fields).content,
                                              encoding: .utf8))
        XCTAssertEqual(adopted.contentHash,
                       unstamped.x[SyncEnvelope.vaultContentHashExtensionKey]?.text)
    }

    func testRuntimeRejectsConflictCopyWhoseIDDoesNotMatchItsValidProvenance()
        throws
    {
        let fixture = makeFixture()
        let fingerprint = String(repeating: "a", count: 64)
        let invalidID = UUID(
            uuidString: "49999999-0000-4000-8000-000000000001")!
        let invalidCopy = SyncEnvelope(
            id: invalidID,
            hlc: HLC(wallMs: 100, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Invalid deterministic copy",
                keyword: "",
                content: Data("must not be applied".utf8),
                tags: ["conflict"],
                isEnabled: false,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)),
            x: [
                SyncMerge.plainConflictCopyExtensionKey:
                    SyncMerge.conflictCopyProvenance(
                        sourceID: Self.sourceID,
                        fingerprint: fingerprint),
            ])
        XCTAssertNotNil(SyncMerge.conflictCopyProvenance(in: invalidCopy),
                        "the tuple is structurally valid; only its deterministic id is false")
        XCTAssertFalse(SyncMerge.hasValidConflictCopyIdentity(invalidCopy))

        do {
            _ = try fixture.bridge.applyRemote([invalidCopy])
            XCTFail("runtime mutation boundary accepted a non-deterministic conflict-copy id")
        } catch let failure as SyncEngineFailure {
            XCTAssertEqual(failure.reason, .localLibraryQuarantined)
        } catch {
            XCTFail("expected a sync quarantine, got \(error)")
        }
        XCTAssertNil(fixture.store.snippet(id: invalidID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncLibraryMetadataFileURL.path))
    }

    func testTwoCarrierVariantsClaimingSameDeterministicCopyIDFailClosedWithoutTrap()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Validate duplicate carrier copy IDs")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("duplicate-copy-id ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losingA = try secureEnvelope(
            plaintext: Data("first carrier body".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losingB = try secureEnvelope(
            plaintext: Data("second carrier body".utf8),
            revision: 250,
            device: "ccccccc3",
            vaultKID: document.kid,
            keyring: keyring)
        let winner = plainEnvelope(
            revision: 300,
            device: Self.deviceB,
            body: "plain winner for duplicate carrier test")
        let sourceA = try XCTUnwrap(SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losingA,
            remote: winner).survivor)
        let sourceB = try XCTUnwrap(SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losingB,
            remote: winner).survivor)
        let variantA = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: sourceA).only)
        let variantB = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: sourceB).only)
        XCTAssertNotEqual(variantA.copyID, variantB.copyID)

        var forgedB = try XCTUnwrap(sourceB.x[variantB.extensionKey]?.object)
        forgedB["copyID"] = .string(variantA.copyID.uuidString.lowercased())
        var malicious = sourceA
        malicious.x[variantB.extensionKey] = .object(forgedB)
        XCTAssertEqual(
            malicious.x[variantA.extensionKey]?.object?["copyID"]?.text,
            malicious.x[variantB.extensionKey]?.object?["copyID"]?.text,
            "both raw carrier members must claim the same reserved copy id")
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBytesBefore = try? Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)

        do {
            _ = try fixture.bridge.applyRemote([malicious])
            XCTFail("duplicate carrier copy-ID authority must not reach mutation")
        } catch let failure as SyncEngineFailure {
            XCTAssertEqual(failure.reason, .localLibraryQuarantined)
        } catch {
            XCTFail("duplicate copy IDs must produce a typed quarantine, got \(error)")
        }

        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore)
        XCTAssertEqual(
            try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore)
    }

    func testPlainConflictCopyProvenanceHealsAfterMetadataWriteFailureAndRestart()
        async throws
    {
        let fixture = makeFixture()
        let scenario = try plainConflictScenario()
        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "plain-copy-metadata-recovery")
        backend.seed([try WireCodec.seal(scenario.ancestor, using: sealer)])
        let storedAncestor = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            scenario.ancestor,
            recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [scenario.copy])
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // Keep the destination readable/missing, then make only its atomic staging
        // directory invalid. This reaches the intended post-primary best-effort write
        // failure without making the bridge reject an unreadable sidecar at preflight.
        let blockedMetadataURL = rootURL.appendingPathComponent(
            "faulted-library-metadata.json")
        let blockedTemporaryDirectory = rootURL.appendingPathComponent(
            "metadata-temporary-directory-is-a-file")
        try Data("not a directory".utf8).write(to: blockedTemporaryDirectory)
        let faultingBridge = SnippetLibraryBridge(
            store: fixture.store,
            secureStore: fixture.secureStore,
            metadataURL: blockedMetadataURL,
            temporaryDirectory: blockedTemporaryDirectory)

        let applied = try faultingBridge.applyRemote([
            scenario.survivor,
            scenario.copy,
        ])

        XCTAssertEqual(Set(applied.changedIDs), [scenario.survivor.id, scenario.copy.id])
        XCTAssertNotNil(fixture.store.snippet(id: scenario.copy.id),
                        "primary C must commit even though its derived sidecar did not")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncLibraryMetadataFileURL.path))

        // The fresh bridge has only primary rows plus durable dependency knowledge. It
        // must reconstruct exact provenance, heal the normal sidecar, and retry C first.
        let restartedBridge = SnippetLibraryBridge(
            store: fixture.store,
            secureStore: fixture.secureStore)
        let restarted = makeEngine(
            backend: backend,
            bridge: restartedBridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        let state = await restarted.sync()

        XCTAssertFalse(state.isHalted)
        let submitted = try backend.submittedBatches.flatMap { batch in
            try batch.map { try WireCodec.open($0, using: sealer) }
        }
        XCTAssertEqual(submitted.only?.id, scenario.copy.id)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            try XCTUnwrap(submitted.only),
            sourceID: scenario.survivor.id,
            fingerprint: scenario.fingerprint))
        let healed = try loadedMetadata()
        let healedCopy = try XCTUnwrap(healed.envelope(scenario.copy.id))
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            healedCopy,
            sourceID: scenario.survivor.id,
            fingerprint: scenario.fingerprint))
        XCTAssertNotNil(try loadedJournal().dependency(scenario.survivor.id))
    }

    func testRestartUnionsStaleSidecarAndJournalUnknownExtensionsAfterWriteFailure()
        throws
    {
        let fixture = makeFixture()
        let scenario = try plainConflictScenario()
        let sidecarKey = "future.sidecar.v9"
        let journalKey = "future.journal.v10"
        let sidecarValue = CanonicalJSON.Value.object([
            "opaque": .utf8(Data("retained only by stale sidecar".utf8)),
            "version": .int(9),
        ])
        let journalValue = CanonicalJSON.Value.array([
            .string("retained only by durable dependency"),
            .int(10),
        ])
        var oldCopy = scenario.copy
        oldCopy.x[sidecarKey] = sidecarValue
        _ = try fixture.bridge.applyRemote([scenario.survivor, oldCopy])
        let oldSidecar = try loadedMetadata()
        XCTAssertEqual(oldSidecar.envelope(oldCopy.id)?.x[sidecarKey], sidecarValue)
        XCTAssertNil(oldSidecar.envelope(oldCopy.id)?.x[journalKey])

        var newCopy = oldCopy
        newCopy.x[journalKey] = journalValue
        var base = SyncBase(journalEstablished: true)
        base.recordConfirmed(
            scenario.ancestor,
            recordVersion: SyncRecordVersion(Data("ancestor-before-copy".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [newCopy])
        let copyOffer = try XCTUnwrap(journal.pending(confirmed: base).only)
        XCTAssertEqual(copyOffer, newCopy)
        journal.markOffered([copyOffer], confirmed: base)
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // Keep the old sidecar readable but make its attempted atomic replacement fail.
        // The primary row cannot store either x bag, so restart must combine the stale
        // derived member with the newer durable dependency offer rather than choosing one.
        let blockedTemporaryDirectory = rootURL.appendingPathComponent(
            "metadata-temporary-directory-is-a-file")
        try Data("not a directory".utf8).write(to: blockedTemporaryDirectory)
        let faultingBridge = SnippetLibraryBridge(
            store: fixture.store,
            secureStore: fixture.secureStore,
            metadataURL: SnippetStorageLocations.syncLibraryMetadataFileURL,
            temporaryDirectory: blockedTemporaryDirectory)
        _ = try faultingBridge.applyRemote([newCopy])
        let stillStale = try loadedMetadata()
        XCTAssertEqual(stillStale.envelope(newCopy.id)?.x[sidecarKey], sidecarValue)
        XCTAssertNil(stillStale.envelope(newCopy.id)?.x[journalKey],
                     "the fixture must prove the newer sidecar write really failed")

        let restarted = SnippetLibraryBridge(
            store: fixture.store,
            secureStore: fixture.secureStore)
        let knowledge = journal.projectionKnowledge(over: base)
        let recovered = try XCTUnwrap(
            restarted.currentEnvelopes(agreedBase: knowledge)[newCopy.id])

        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            recovered,
            sourceID: scenario.survivor.id,
            fingerprint: scenario.fingerprint))
        XCTAssertEqual(recovered.x[sidecarKey], sidecarValue)
        XCTAssertEqual(recovered.x[journalKey], journalValue,
                       "exact stale sidecar matching must not shadow newer journal x")
        let healed = try loadedMetadata()
        XCTAssertEqual(healed.envelope(newCopy.id)?.x, recovered.x)

        let secondRestart = SnippetLibraryBridge(
            store: fixture.store,
            secureStore: fixture.secureStore)
        let stable = try XCTUnwrap(
            secondRestart.currentEnvelopes(agreedBase: knowledge)[newCopy.id])
        XCTAssertEqual(stable.x, recovered.x,
                       "the healed union must remain stable across another restart")
    }

    func testRestartScrubsLegacyPlainSidecarForSecurePrimaryAndPreservesUnknownExtensions()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare legacy plaintext sidecar migration")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secret = Data("legacy plaintext must be scrubbed from metadata".utf8)
        let secure = try secureEnvelope(
            plaintext: secret,
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([secure])
        let primaryRecord = try XCTUnwrap(loadedVault().record(Self.sourceID))
        let vaultBytes = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)

        let agreedKey = "future.agreed.v11"
        let sidecarKey = "future.sidecar.v12"
        let agreedValue = CanonicalJSON.Value.object([
            "owner": .string("durable protocol knowledge"),
            "version": .int(11),
        ])
        let sidecarValue = CanonicalJSON.Value.array([
            .string("legacy sidecar-only metadata"),
            .int(12),
        ])
        let staleFingerprint = String(repeating: "e", count: 64)
        let staleCarrierKey = SyncMerge.contentConflictV1ExtensionPrefix
            + staleFingerprint
        let staleOpaqueStorageKey = SyncMerge.contentConflictOpaqueCarrierPrefix
            + staleFingerprint
        let staleCarrierValue = CanonicalJSON.Value.object([
            "version": .int(1),
            "stale": .bool(true),
        ])
        let staleProvenanceValue = CanonicalJSON.Value.object([
            "version": .int(1),
            "sourceID": .string(UUID().uuidString.lowercased()),
            "fingerprint": .string(staleFingerprint),
        ])
        let staleVaultKID = "stale-sidecar-vault-scope"
        let staleContentHash = String(repeating: "f", count: 32)
        var agreedSecure = secure
        agreedSecure.x[agreedKey] = agreedValue
        var agreed = SyncBase()
        agreed.record(agreedSecure)

        var stalePlain = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Legacy plaintext shadow",
                keyword: "legacy-plaintext-shadow",
                content: String(decoding: secret, as: UTF8.self),
                tags: ["must", "be", "scrubbed"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.2)),
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        stalePlain.x[sidecarKey] = sidecarValue
        stalePlain.x[staleCarrierKey] = staleCarrierValue
        stalePlain.x[staleOpaqueStorageKey] = .string(
            try CanonicalJSON.data(staleCarrierValue).base64EncodedString())
        stalePlain.x[SyncMerge.plainConflictCopyExtensionKey] = staleProvenanceValue
        stalePlain.x[SyncEnvelope.vaultKeyIDExtensionKey] = .string(staleVaultKID)
        stalePlain.x[SyncEnvelope.vaultContentHashExtensionKey] = .string(
            staleContentHash)
        var legacySidecar = SyncBase()
        legacySidecar.record(stalePlain)
        try SyncBaseFile.write(
            legacySidecar,
            to: SnippetStorageLocations.syncLibraryMetadataFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let unsafeMetadata = try loadedMetadata()
        XCTAssertEqual(
            unsafeMetadata.envelope(Self.sourceID)?.fields?.content,
            secret,
            "the parsed legacy sidecar must prove it owns plaintext before migration")

        SyncCoordinator.runtimeEnabledOverride = false
        let restarted = recreateFixture(using: fixture)
        let startupHealed = try assertMetadataDoesNotContainPlaintext(
            secret,
            id: Self.sourceID,
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)
        XCTAssertTrue(startupHealed.secure,
                      "sync-disabled secure-store startup must scrub the legacy leak")
        XCTAssertEqual(startupHealed.fields?.content, Data(primaryRecord.sealed.utf8))
        XCTAssertEqual(startupHealed.x[sidecarKey], sidecarValue,
                       "startup scrub retains safe legacy sidecar extensions")
        XCTAssertNil(startupHealed.x[staleCarrierKey],
                     "plaintext sidecar carrier state may not become secure protocol evidence")
        XCTAssertNil(startupHealed.x[staleOpaqueStorageKey],
                     "plaintext sidecar vault-storage carrier keys are untrusted too")
        XCTAssertNil(startupHealed.x[SyncMerge.plainConflictCopyExtensionKey],
                     "plaintext sidecar provenance may not become secure protocol evidence")
        XCTAssertEqual(
            startupHealed.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text,
            document.kid,
            "vault scope must be projected from secure primary, not stale sidecar x")
        XCTAssertEqual(
            startupHealed.x[SyncEnvelope.vaultContentHashExtensionKey]?.text,
            primaryRecord.contentHash,
            "content authentication must be projected from secure primary")
        XCTAssertNotEqual(
            startupHealed.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text,
            staleVaultKID)
        XCTAssertNotEqual(
            startupHealed.x[SyncEnvelope.vaultContentHashExtensionKey]?.text,
            staleContentHash)
        XCTAssertEqual(try loadedVault().record(Self.sourceID), primaryRecord)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytes)

        let projected = try XCTUnwrap(
            restarted.bridge.currentEnvelopes(agreedBase: agreed)[Self.sourceID])

        XCTAssertTrue(projected.secure)
        XCTAssertEqual(projected.fields?.content, Data(primaryRecord.sealed.utf8))
        XCTAssertEqual(projected.x[agreedKey], agreedValue)
        XCTAssertEqual(projected.x[sidecarKey], sidecarValue,
                       "safe disjoint sidecar knowledge survives the plaintext scrub")
        XCTAssertNil(projected.x[staleCarrierKey])
        XCTAssertNil(projected.x[staleOpaqueStorageKey])
        XCTAssertNil(projected.x[SyncMerge.plainConflictCopyExtensionKey])
        XCTAssertEqual(projected.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text,
                       document.kid)
        XCTAssertEqual(
            projected.x[SyncEnvelope.vaultContentHashExtensionKey]?.text,
            primaryRecord.contentHash)
        let stableHealed = try assertMetadataDoesNotContainPlaintext(
            secret,
            id: Self.sourceID,
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)
        XCTAssertEqual(stableHealed, projected)
        XCTAssertNil(stableHealed.x[staleOpaqueStorageKey])
        XCTAssertEqual(try loadedVault().record(Self.sourceID), primaryRecord)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytes,
            "sidecar migration is derived-state repair and may not rewrite the vault")
    }

    func testRestartWithTooNewPlaintextSidecarFailsClosedWithoutChangingBytes()
        async throws
    {
        try await assertUnsafeProjectionSidecarFailsClosed(
            Data("{\"schemaVersion\":4,\"legacyPlaintext\":\"must remain untouched\"}".utf8),
            expectedReason: .schemaTooNew)
    }

    func testStartupPlaintextSidecarHealWriteFailureRemovesDerivedLeakAndLeavesVaultExact()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare startup metadata-heal write failure")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secret = Data("startup heal failure must not retain plaintext".utf8)
        let secure = try secureEnvelope(
            plaintext: secret,
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([secure])
        let primaryRecord = try XCTUnwrap(loadedVault().record(Self.sourceID))
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)

        let safeKey = "future.sidecar.write-failure.v13"
        let safeValue = CanonicalJSON.Value.object([
            "owner": .string("derived legacy sidecar"),
            "version": .int(13),
        ])
        var stalePlain = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Known-schema plaintext leak",
                keyword: "startup-heal-failure",
                content: String(decoding: secret, as: UTF8.self),
                tags: ["privacy", "fixture"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.2)),
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        stalePlain.x[safeKey] = safeValue
        var legacySidecar = SyncBase()
        legacySidecar.record(stalePlain)
        try SyncBaseFile.write(
            legacySidecar,
            to: SnippetStorageLocations.syncLibraryMetadataFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let leakingBytes = try Data(
            contentsOf: SnippetStorageLocations.syncLibraryMetadataFileURL)
        XCTAssertEqual(
            try loadedMetadata().envelope(Self.sourceID)?.fields?.content,
            secret)
        let temporaryEntriesBefore = Set(try FileManager.default.contentsOfDirectory(
            atPath: SnippetStorageLocations.tmpFolderURL.path))

        SyncCoordinator.runtimeEnabledOverride = false
        var writeAttempts = 0
        var attemptedSanitizedMetadata: SyncBase?
        let restartedSession = VaultSession(
            keychain: fixture.keychain,
            authenticationEvaluator: { _ in true })
        let restartedStore = SnippetStore(configuration: .iOS)
        let restartedSecureStore = SecureSnippetStore(
            session: restartedSession,
            keychain: fixture.keychain,
            deviceID: restartedStore.deviceID,
            syncMetadataWriter: { metadata, _, _ in
                writeAttempts += 1
                attemptedSanitizedMetadata = metadata
                throw SecureDependencyFixtureFailure.injectedMetadataWrite
            })
        restartedStore.secureProvider = restartedSecureStore

        XCTAssertEqual(writeAttempts, 1)
        let attempted = try XCTUnwrap(
            attemptedSanitizedMetadata?.envelope(Self.sourceID))
        XCTAssertTrue(attempted.secure)
        XCTAssertNotEqual(attempted.fields?.content, secret)
        XCTAssertEqual(attempted.fields?.content, Data(primaryRecord.sealed.utf8))
        XCTAssertEqual(attempted.x[safeKey], safeValue)
        XCTAssertEqual(try loadedVault().record(Self.sourceID), primaryRecord)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore,
            "derived-state cleanup may not rewrite secure primary bytes")

        let sidecarStillExists = FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncLibraryMetadataFileURL.path)
        XCTAssertFalse(sidecarStillExists,
                       "failed startup healing must durably remove the derived plaintext leak")
        if sidecarStillExists {
            XCTAssertEqual(
                try Data(contentsOf: SnippetStorageLocations.syncLibraryMetadataFileURL),
                leakingBytes,
                "a failed writer may not leave a partial sanitized replacement")
        }
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                atPath: SnippetStorageLocations.tmpFolderURL.path)),
            temporaryEntriesBefore,
            "startup leak cleanup may not strand a partial sidecar in Tmp")
    }

    func testRestartWithUnreadablePlaintextSidecarFailsClosedWithoutChangingBytes()
        async throws
    {
        try await assertUnsafeProjectionSidecarFailsClosed(
            Data("{not valid JSON; legacyPlaintext=must remain untouched".utf8),
            expectedReason: .localLibraryQuarantined)
    }

    func testScopedUndoRestoringExactConflictCopySupersedesJournalTombstone()
        throws
    {
        try assertExactPlainConflictCopyUndoSupersedesTombstone { store, copyID in
            let token = try XCTUnwrap(store.deleteForUndo(snippetID: copyID))
            return {
                XCTAssertTrue(store.restoreDeletedSnippet(using: token))
            }
        }
    }

    func testGlobalUndoRestoringExactConflictCopySupersedesJournalTombstone()
        throws
    {
        try assertExactPlainConflictCopyUndoSupersedesTombstone { store, copyID in
            store.delete(snippetID: copyID)
            return {
                XCTAssertTrue(store.undo())
            }
        }
    }

    func testPromotingGeneratedPlainCopyBeforeFirstACKPreservesDependencyProvenance()
        async throws
    {
        let fixture = makeFixture()
        let scenario = try plainConflictScenario()
        let futureCarrierKey = "contentConflict.v9." + String(repeating: "c", count: 64)
        let futureCarrierValue = CanonicalJSON.Value.object([
            "opaque": .utf8(Data("future promotion carrier".utf8)),
            "version": .int(9),
        ])
        var promotedCopy = scenario.copy
        promotedCopy.x[futureCarrierKey] = futureCarrierValue
        var base = SyncBase(journalEstablished: true)
        base.recordConfirmed(
            scenario.ancestor,
            recordVersion: SyncRecordVersion(Data("plain-ancestor".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [promotedCopy])
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        _ = try fixture.bridge.applyRemote([scenario.survivor, scenario.copy])
        XCTAssertNotNil(fixture.store.snippet(id: promotedCopy.id))
        let pendingVault = try XCTUnwrap(
            fixture.secureStore.prepareVaultCreationIfNeeded())
        _ = try fixture.secureStore.commitVaultCreation(pendingVault)
        _ = try await fixture.session.unlock(
            reason: "Promote a generated conflict copy before its first ACK")

        // Only the primary row plus durable journal evidence remain. Promotion must
        // not depend on a healthy derived sidecar to carry provenance or future x.
        try? FileManager.default.removeItem(
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)

        try SecureSnippetTransitionCoordinator.promote(
            snippetID: promotedCopy.id,
            store: fixture.store,
            secureStore: fixture.secureStore)

        XCTAssertNil(fixture.store.snippet(id: promotedCopy.id))
        let secureCopy = try XCTUnwrap(loadedVault().record(promotedCopy.id))
        XCTAssertEqual(
            secureCopy.x[SyncMerge.plainConflictCopyExtensionKey],
            .object([
                "version": .integer(1),
                "sourceID": .string(scenario.survivor.id.uuidString.lowercased()),
                "fingerprint": .string(scenario.fingerprint),
            ]),
            "representation changes may not strip deterministic-copy authority")
        let futureCarrierSuffix = String(futureCarrierKey.dropFirst(
            SyncMerge.contentConflictExtensionPrefix.count))
        let futureOpaqueStorageKey =
            SyncMerge.contentConflictOpaqueCarrierPrefix + futureCarrierSuffix
        XCTAssertEqual(
            secureCopy.x[futureOpaqueStorageKey],
            .string(try CanonicalJSON.data(futureCarrierValue).base64EncodedString()))
        let projected = try fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        let projectedCopy = try XCTUnwrap(projected[promotedCopy.id])
        XCTAssertTrue(projectedCopy.secure)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            projectedCopy,
            sourceID: scenario.survivor.id,
            fingerprint: scenario.fingerprint))
        XCTAssertEqual(projectedCopy.x[futureCarrierKey], futureCarrierValue)
        XCTAssertNoThrow(try journal.reconcileDependencies(
            current: projected,
            confirmed: base))
        XCTAssertNotNil(journal.dependency(scenario.survivor.id))
        XCTAssertEqual(
            journal.pending(confirmed: base).only?.id,
            promotedCopy.id,
            "the promoted C remains dependency-owned and uploadable before source release")
    }

    func testDemotingGeneratedSecureCopyBeforeFirstACKPreservesProvenanceWithoutSidecar()
        async throws
    {
        let harness = try await makeConflictHarness()
        let copyID = harness.scenario.variant.copyID
        let journal = try loadedJournal()
        let base = harness.engine.agreedBase
        let secureCopy = try XCTUnwrap(loadedVault().record(copyID))
        XCTAssertNotNil(secureCopy.x[SyncMerge.plainConflictCopyExtensionKey])
        XCTAssertNotNil(journal.dependency(Self.sourceID))
        XCTAssertNil(base.envelope(copyID),
                     "the transition must happen before the copy's first backend ACK")

        // Derived metadata is intentionally absent. The durable journal plus vault
        // provenance must be sufficient to carry identity across secure→plain ownership.
        try? FileManager.default.removeItem(
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)
        _ = try await harness.fixture.session.unlock(
            reason: "Demote a generated secure conflict copy")
        try SecureSnippetTransitionCoordinator.demote(
            recordID: copyID,
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)

        XCTAssertNil(try loadedVault().record(copyID))
        let safeHandoff = try assertMetadataDoesNotContainPlaintext(
            Data("secure edit that must survive".utf8),
            id: copyID,
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)
        XCTAssertTrue(safeHandoff.secure,
                      "demotion prewrites the encrypted source, never its decrypted target")
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            safeHandoff,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        var editedPlain = try XCTUnwrap(harness.fixture.store.snippet(id: copyID))
        editedPlain.name = "Plain edit after generated-copy demotion"
        editedPlain.content = "later plain intent that must wait behind frozen C"
        editedPlain.tags = ["conflict", "reviewed"]
        harness.fixture.store.update(editedPlain)
        try harness.fixture.store.flushPendingWritesForSync()
        let restarted = SnippetLibraryBridge(
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)
        let projected = try restarted.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        let plainCopy = try XCTUnwrap(projected[copyID])
        XCTAssertFalse(plainCopy.secure)
        XCTAssertNil(plainCopy.x[SyncEnvelope.vaultContentHashExtensionKey],
                     "plain projection may not retain a secure-body hash")
        XCTAssertNil(plainCopy.x[SyncEnvelope.vaultKeyIDExtensionKey],
                     "plain projection may not claim secure vault scope")
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            plainCopy,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint),
            "demotion cannot turn dependency-owned C into an unrelated ordinary row")

        var reconciled = journal
        XCTAssertNoThrow(try reconciled.reconcileDependencies(
            current: projected,
            confirmed: base))
        reconciled.reconcile(
            current: projected,
            confirmed: base,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 2))
        XCTAssertNotNil(reconciled.dependency(Self.sourceID))
        let frozenCopyOffer = try XCTUnwrap(reconciled.pending(confirmed: base).only)
        XCTAssertEqual(frozenCopyOffer.id, copyID)
        XCTAssertTrue(frozenCopyOffer.secure,
                      "the immutable authenticated prerequisite predates demotion")
        XCTAssertNotEqual(frozenCopyOffer.fields?.content,
                          Data(editedPlain.content.utf8))
        XCTAssertEqual(
            try loadedMetadata().envelope(copyID)?.x[
                SyncMerge.plainConflictCopyExtensionKey],
            plainCopy.x[SyncMerge.plainConflictCopyExtensionKey])

        reconciled.markOffered([frozenCopyOffer], confirmed: base)
        var copyConfirmed = base
        copyConfirmed.recordConfirmed(
            frozenCopyOffer,
            recordVersion: SyncRecordVersion(Data("demoted-C-first-ACK".utf8)))
        reconciled.acknowledge([copyID], confirmed: copyConfirmed)
        let resolution = try XCTUnwrap(reconciled.carrierResolutions(
            current: projected,
            confirmed: copyConfirmed).only)
        try reconciled.beginCarrierResolutions([resolution])
        _ = try restarted.resolveConflictCarriers([resolution])
        let afterCleanup = try restarted.currentEnvelopes(
            agreedBase: reconciled.projectionKnowledge(over: copyConfirmed))
        try reconciled.reconcileDependencies(
            current: afterCleanup,
            confirmed: copyConfirmed)
        reconciled.reconcile(
            current: afterCleanup,
            confirmed: copyConfirmed,
            deviceID: harness.fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 3))
        let sourceRelease = try XCTUnwrap(
            reconciled.pending(confirmed: copyConfirmed).only)
        XCTAssertEqual(sourceRelease.id, Self.sourceID)
        reconciled.markOffered([sourceRelease], confirmed: copyConfirmed)
        var sourceConfirmed = copyConfirmed
        sourceConfirmed.recordConfirmed(
            sourceRelease,
            recordVersion: SyncRecordVersion(Data("demoted-C-source-ACK".utf8)))
        reconciled.acknowledge([Self.sourceID], confirmed: sourceConfirmed)
        try reconciled.reconcileDependencies(
            current: afterCleanup,
            confirmed: sourceConfirmed,
            acceptedSourceIDs: [Self.sourceID])
        XCTAssertNil(reconciled.dependency(Self.sourceID))
        let laterPlainOffer = try XCTUnwrap(
            reconciled.pending(confirmed: sourceConfirmed).only)
        XCTAssertEqual(laterPlainOffer.id, copyID)
        XCTAssertFalse(laterPlainOffer.secure)
        XCTAssertEqual(laterPlainOffer.fields?.content, Data(editedPlain.content.utf8),
                       "the user edit survives until the ordered fence releases it")
    }

    func testNormalRoundAcceptsFrozenSecureCopyAfterPrimaryDemotion()
        async throws
    {
        let harness = try await makeConflictHarness()
        let copyID = harness.scenario.variant.copyID
        XCTAssertNil(harness.engine.agreedBase.envelope(copyID))
        XCTAssertNotNil(try loadedJournal().dependency(Self.sourceID))
        _ = try await harness.fixture.session.unlock(
            reason: "Demote generated copy before its normal retry")
        try SecureSnippetTransitionCoordinator.demote(
            recordID: copyID,
            store: harness.fixture.store,
            secureStore: harness.fixture.secureStore)
        var editedPlain = try XCTUnwrap(
            harness.fixture.store.snippet(id: copyID))
        editedPlain.name = "Reviewed demoted copy"
        editedPlain.content = "later plaintext intent stays behind the frozen offer"
        editedPlain.tags = ["demoted", "normal-round"]
        harness.fixture.store.update(editedPlain)
        try harness.fixture.store.flushPendingWritesForSync()
        let beforeRetry = harness.backend.submittedBatches.count

        let state = await harness.engine.sync()

        XCTAssertFalse(state.isHalted)
        let submitted = try openedBatches(after: beforeRetry, in: harness)
        let frozen = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(frozen.id, copyID)
        XCTAssertTrue(frozen.secure,
                      "the dependency owns the authenticated pre-demotion snapshot")
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            frozen,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        XCTAssertFalse(submitted.flatMap { $0 }.contains { $0.id == Self.sourceID })
        XCTAssertEqual(harness.engine.agreedBase.envelope(copyID), frozen)
        XCTAssertNotNil(try loadedJournal().dependency(Self.sourceID),
                        "the source release remains a later ordered round")

        XCTAssertNil(try loadedVault().record(copyID),
                     "normal replay may not re-materialize or re-promote demoted C")
        let retained = try XCTUnwrap(
            harness.fixture.store.snippet(id: copyID))
        XCTAssertEqual(retained.name, editedPlain.name)
        XCTAssertEqual(retained.content, editedPlain.content)
        XCTAssertEqual(retained.tags, editedPlain.tags)
        let projected = try harness.fixture.bridge.currentEnvelopes(
            agreedBase: harness.engine.agreedBase)
        let projectedCopy = try XCTUnwrap(projected[copyID])
        XCTAssertFalse(projectedCopy.secure)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            projectedCopy,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
    }

    func testPromotionSuccessLeavesOnlyCiphertextInSyncMetadataWhenSyncIsOff()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Promote without plaintext sidecar")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secret = Data("promotion-success-secret-body-7f42".utf8)
        let snippet = fixture.store.addSnippet(
            name: "Promotion privacy fixture",
            content: String(decoding: secret, as: UTF8.self))
        try fixture.store.flushPendingWritesForSync()
        SyncCoordinator.runtimeEnabledOverride = false

        try SecureSnippetTransitionCoordinator.promote(
            snippetID: snippet.id,
            store: fixture.store,
            secureStore: fixture.secureStore)

        XCTAssertNil(fixture.store.snippet(id: snippet.id))
        XCTAssertNotNil(try loadedVault().record(snippet.id))
        let handoff = try assertMetadataDoesNotContainPlaintext(
            secret,
            id: snippet.id,
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)
        XCTAssertTrue(handoff.secure)
        XCTAssertEqual(
            handoff.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text,
            document.kid)
        let sealed = try XCTUnwrap(
            handoff.fields.flatMap { String(data: $0.content, encoding: .utf8) })
        XCTAssertEqual(
            try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: document.kid,
                    recordID: snippet.id),
                keyring: keyring),
            secret,
            "the handoff is the secure target, not a redacted or plaintext surrogate")
    }

    func testFailedPromotionPrimaryWriteNeverLeavesPlaintextInSyncMetadata()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare failed promotion")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secret = Data("failed-promotion-secret-body-a913".utf8)
        let snippet = fixture.store.addSnippet(
            name: "Failed promotion privacy fixture",
            content: String(decoding: secret, as: UTF8.self))
        try fixture.store.flushPendingWritesForSync()
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        let blockedPrimaryTemp = rootURL.appendingPathComponent(
            "failed-promotion-primary-temp-is-file")
        try Data("not a directory".utf8).write(to: blockedPrimaryTemp)
        let metadataTemp = rootURL.appendingPathComponent(
            "failed-promotion-metadata-temp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: metadataTemp,
            withIntermediateDirectories: true)
        let metadataURL = rootURL.appendingPathComponent(
            "failed-promotion-library-metadata.json")
        var metadataWrites = 0
        let faulting = SecureSnippetStore(
            session: fixture.session,
            keychain: fixture.keychain,
            deviceID: fixture.store.deviceID,
            temporaryDirectory: blockedPrimaryTemp,
            syncMetadataURL: metadataURL,
            syncMetadataWriter: { metadata, url, _ in
                metadataWrites += 1
                try SyncBaseFile.write(
                    metadata,
                    to: url,
                    temporaryDirectory: metadataTemp)
            })
        _ = try await fixture.session.unlock(reason: "Fail promotion after safe handoff")

        XCTAssertThrowsError(try faulting.promote(snippetID: snippet.id))

        XCTAssertEqual(metadataWrites, 1)
        XCTAssertEqual(fixture.store.snippet(id: snippet.id), snippet)
        XCTAssertNil(try loadedVault().record(snippet.id))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore)
        let handoff = try assertMetadataDoesNotContainPlaintext(
            secret,
            id: snippet.id,
            at: metadataURL)
        XCTAssertTrue(handoff.secure,
                      "failed promotion may leave only the ciphertext target handoff")
        let sealed = try XCTUnwrap(
            handoff.fields.flatMap { String(data: $0.content, encoding: .utf8) })
        XCTAssertEqual(
            try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: document.kid,
                    recordID: snippet.id),
                keyring: keyring),
            secret)
    }

    func testFailedDemotionPrimaryWriteNeverLeavesDecryptedBodyInSyncMetadata()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare failed demotion")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secret = Data("failed-demotion-secret-body-c284".utf8)
        let secure = try secureEnvelope(
            plaintext: secret,
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([secure])
        let recordBefore = try XCTUnwrap(loadedVault().record(secure.id))
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBytesBefore = try? Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        let blockedPrimaryTemp = rootURL.appendingPathComponent(
            "failed-demotion-primary-temp-is-file")
        try Data("not a directory".utf8).write(to: blockedPrimaryTemp)
        let metadataTemp = rootURL.appendingPathComponent(
            "failed-demotion-metadata-temp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: metadataTemp,
            withIntermediateDirectories: true)
        let metadataURL = rootURL.appendingPathComponent(
            "failed-demotion-library-metadata.json")
        var metadataWrites = 0
        let faulting = SecureSnippetStore(
            session: fixture.session,
            keychain: fixture.keychain,
            deviceID: fixture.store.deviceID,
            temporaryDirectory: blockedPrimaryTemp,
            syncMetadataURL: metadataURL,
            syncMetadataWriter: { metadata, url, _ in
                metadataWrites += 1
                try SyncBaseFile.write(
                    metadata,
                    to: url,
                    temporaryDirectory: metadataTemp)
            })
        _ = try await fixture.session.unlock(reason: "Fail demotion after safe handoff")

        XCTAssertThrowsError(try faulting.demote(recordID: secure.id))

        XCTAssertEqual(metadataWrites, 1)
        XCTAssertNil(fixture.store.snippet(id: secure.id))
        XCTAssertEqual(try loadedVault().record(secure.id), recordBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore)
        XCTAssertEqual(
            try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore)
        let handoff = try assertMetadataDoesNotContainPlaintext(
            secret,
            id: secure.id,
            at: metadataURL)
        XCTAssertTrue(handoff.secure,
                      "failed demotion must leave the encrypted source as handoff")
        XCTAssertEqual(handoff.fields?.content, secure.fields?.content)
        let sealed = try XCTUnwrap(
            handoff.fields.flatMap { String(data: $0.content, encoding: .utf8) })
        XCTAssertEqual(
            try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: document.kid,
                    recordID: secure.id),
                keyring: keyring),
            secret)
    }

    func testDemotionMetadataFailureLeavesGeneratedCopySecureAndRetryable()
        async throws
    {
        var metadataWriteAttempts = 0
        let fixture = makeFixture(syncMetadataWriter: { metadata, url, temporary in
            metadataWriteAttempts += 1
            if metadataWriteAttempts == 1 {
                throw SecureDependencyFixtureFailure.injectedMetadataWrite
            }
            try SyncBaseFile.write(
                metadata, to: url, temporaryDirectory: temporary)
        })
        let harness = try await makeConflictHarness(fixture: fixture)
        let copyID = harness.scenario.variant.copyID
        let secureBefore = try XCTUnwrap(loadedVault().record(copyID))
        let vaultBytesBefore = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        try? FileManager.default.removeItem(
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)
        _ = try await fixture.session.unlock(
            reason: "Attempt generated-copy demotion with failed metadata durability")

        XCTAssertThrowsError(try SecureSnippetTransitionCoordinator.demote(
            recordID: copyID,
            store: fixture.store,
            secureStore: fixture.secureStore))

        XCTAssertEqual(metadataWriteAttempts, 1,
                       "the fault must occur at the metadata-before-primary fence")
        XCTAssertNil(fixture.store.snippet(id: copyID),
                     "failed demotion may not commit plaintext ownership")
        XCTAssertEqual(try loadedVault().record(copyID), secureBefore,
                       "the vault remains the authoritative retry source")
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncLibraryMetadataFileURL.path),
            "a failed prewrite cannot leave a partial sidecar that speaks for plaintext")
    }

    func testDemotionRejectsUnknownVaultRecordExtensionWithoutChangingPrimaryFiles()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare unknown vault-extension demotion")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ordinary = try secureEnvelope(
            plaintext: Data("ordinary secure body with future vault metadata".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([ordinary])

        let unknownKey = "futureVaultFeature.v2"
        let unknownValue = JSONValue.object([
            "mode": .string("must not be silently discarded"),
            "version": .integer(2),
        ])
        var vault = try loadedVault()
        let recordIndex = try XCTUnwrap(
            vault.records.firstIndex { $0.id == Self.sourceID })
        XCTAssertTrue(vault.records[recordIndex].x.keys.allSatisfy {
            $0 == SyncMerge.plainConflictCopyExtensionKey
                || $0.hasPrefix(SyncMerge.contentConflictOpaqueCarrierPrefix)
        })
        vault.records[recordIndex].x[unknownKey] = unknownValue
        try VaultFile.write(vault)
        fixture.secureStore.reload(notifyChange: false)
        _ = try await fixture.session.unlock(
            reason: "Attempt demotion with unknown vault metadata")
        let beforeRecord = try XCTUnwrap(
            fixture.secureStore.record(Self.sourceID))
        XCTAssertEqual(beforeRecord.x[unknownKey], unknownValue)
        XCTAssertNil(fixture.store.snippet(id: Self.sourceID))
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBytesBefore = try? Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        let libraryExistedBefore = FileManager.default.fileExists(
            atPath: SnippetStorageLocations.snippetsFileURL.path)

        XCTAssertThrowsError(try SecureSnippetTransitionCoordinator.demote(
            recordID: Self.sourceID,
            store: fixture.store,
            secureStore: fixture.secureStore))

        XCTAssertNil(fixture.store.snippet(id: Self.sourceID),
                     "an unsupported record extension must not cross into plaintext")
        XCTAssertEqual(
            fixture.secureStore.record(Self.sourceID),
            beforeRecord,
            "the vault record remains the authoritative retry source")
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore,
            "failed demotion must not rewrite vault primary storage")
        XCTAssertEqual(
            try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore,
            "failed demotion must not rewrite plaintext primary storage")
        XCTAssertEqual(
            FileManager.default.fileExists(
                atPath: SnippetStorageLocations.snippetsFileURL.path),
            libraryExistedBefore,
            "failed demotion must not create or remove plaintext primary storage")
    }

    func testSecureProjectionRejectsMalformedVaultConflictCopyMarker()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare malformed conflict-copy projection")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ordinary = try secureEnvelope(
            plaintext: Data("secure body with malformed provenance".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([ordinary])

        let malformed = JSONValue.object([
            "version": .integer(1),
            "sourceID": .string(Self.sourceID.uuidString.lowercased()),
            "fingerprint": .string("not-a-lowercase-sha256"),
        ])
        var vault = try loadedVault()
        let index = try XCTUnwrap(
            vault.records.firstIndex { $0.id == Self.sourceID })
        vault.records[index].x[SyncMerge.plainConflictCopyExtensionKey] = malformed
        try VaultFile.write(vault)
        fixture.secureStore.reload(notifyChange: false)
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)

        do {
            _ = try fixture.bridge.currentEnvelopes(agreedBase: SyncBase())
            XCTFail(
                "projection must fail closed instead of silently deleting a reserved marker")
            return
        } catch {}

        XCTAssertEqual(
            fixture.secureStore.record(Self.sourceID)?.x[
                SyncMerge.plainConflictCopyExtensionKey],
            malformed)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore,
            "read-only projection failure may not rewrite the malformed primary record")
    }

    func testDemotionRejectsMalformedConflictCopyMarkerWithoutChangingPrimaryFiles()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare malformed conflict-copy demotion")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ordinary = try secureEnvelope(
            plaintext: Data("secure body that must remain authoritative".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([ordinary])

        let malformed = JSONValue.object([
            "version": .integer(1),
            "sourceID": .string(Self.sourceID.uuidString.lowercased()),
            "fingerprint": .string("not-a-lowercase-sha256"),
        ])
        var vault = try loadedVault()
        let index = try XCTUnwrap(
            vault.records.firstIndex { $0.id == Self.sourceID })
        vault.records[index].x[SyncMerge.plainConflictCopyExtensionKey] = malformed
        try VaultFile.write(vault)
        fixture.secureStore.reload(notifyChange: false)
        _ = try await fixture.session.unlock(
            reason: "Attempt demotion with malformed conflict-copy provenance")
        let recordBefore = try XCTUnwrap(fixture.secureStore.record(Self.sourceID))
        let vaultBytesBefore = try Data(
            contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBytesBefore = try? Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        let libraryExistedBefore = FileManager.default.fileExists(
            atPath: SnippetStorageLocations.snippetsFileURL.path)

        do {
            try SecureSnippetTransitionCoordinator.demote(
                recordID: Self.sourceID,
                store: fixture.store,
                secureStore: fixture.secureStore)
            XCTFail("an allowed reserved key with an invalid value must fail closed")
            return
        } catch {}

        XCTAssertNil(fixture.store.snippet(id: Self.sourceID))
        XCTAssertEqual(fixture.secureStore.record(Self.sourceID), recordBefore)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytesBefore,
            "failed demotion must leave vault primary bytes unchanged")
        XCTAssertEqual(
            try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            libraryBytesBefore,
            "failed demotion must leave plaintext primary bytes unchanged")
        XCTAssertEqual(
            FileManager.default.fileExists(
                atPath: SnippetStorageLocations.snippetsFileURL.path),
            libraryExistedBefore,
            "failed demotion must not create or remove plaintext primary storage")
    }

    func testDemotingSecureCarrierSourcePreservesOpaqueVariantWithoutSidecar()
        async throws
    {
        let fixture = makeFixture()
        let futureCarrierKey = "contentConflict.v9." + String(repeating: "d", count: 64)
        let futureCarrierValue = CanonicalJSON.Value.array([
            .string("opaque future carrier"),
            .int(9),
        ])
        let genericKey = "future.genericWire.v4"
        let genericValue = CanonicalJSON.Value.object([
            "mode": .string("preserve across secure ownership change"),
            "version": .int(4),
        ])
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare secure carrier demotion")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("secure carrier ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let losing = try secureEnvelope(
            plaintext: Data("secure losing body in opaque carrier".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let winning = try secureEnvelope(
            plaintext: Data("secure winning source body".utf8),
            revision: 300,
            device: Self.deviceB,
            vaultKID: document.kid,
            keyring: keyring)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let survivorWithoutFutureCarrier = try XCTUnwrap(merge.survivor)
        var survivor = survivorWithoutFutureCarrier
        survivor.x[futureCarrierKey] = futureCarrierValue
        survivor.x[genericKey] = genericValue
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: survivor).only)
        let carrierValue = try XCTUnwrap(survivor.x[variant.extensionKey])
        var base = SyncBase(journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: SyncRecordVersion(Data("secure-carrier-ancestor".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: survivor,
            conflictCopies: [])
        let preparedCopy = try XCTUnwrap(
            fixture.bridge.prepareConflictCopyEvidence(from: [survivor]).only)
        try journal.recordConflictCopyEvidence([preparedCopy])
        // Model a crash/restart where the primary vault has the exact secure fields,
        // the derived sidecar is stale, and only the durable journal retains disjoint
        // generic wire metadata from the same version.
        journal.reconcile(
            current: [Self.sourceID: survivor],
            confirmed: base,
            deviceID: fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 0.5))
        XCTAssertEqual(journal.entry(Self.sourceID)?.desired.x[genericKey], genericValue)
        _ = try fixture.bridge.applyRemote([survivorWithoutFutureCarrier])
        let futureCarrierSuffix = String(futureCarrierKey.dropFirst(
            SyncMerge.contentConflictExtensionPrefix.count))
        let futureOpaqueStorageKey =
            SyncMerge.contentConflictOpaqueCarrierPrefix + futureCarrierSuffix
        var vaultWithFutureCarrier = try loadedVault()
        let sourceIndex = try XCTUnwrap(
            vaultWithFutureCarrier.records.firstIndex { $0.id == Self.sourceID })
        vaultWithFutureCarrier.records[sourceIndex].x[futureOpaqueStorageKey] =
            .string(try CanonicalJSON.data(futureCarrierValue).base64EncodedString())
        try VaultFile.write(vaultWithFutureCarrier)
        fixture.secureStore.reload(notifyChange: false)
        _ = try await fixture.session.unlock(
            reason: "Reload secure carrier fixture with future metadata")
        let projectedBefore = try fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        try journal.reconcileDependencies(
            current: projectedBefore,
            confirmed: base)
        journal.reconcile(
            current: projectedBefore,
            confirmed: base,
            deviceID: fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        let suffix = String(variant.extensionKey.dropFirst(
            SyncMerge.contentConflictExtensionPrefix.count))
        let opaqueStorageKey = SyncMerge.contentConflictOpaqueCarrierPrefix + suffix
        let sourceRecord = try XCTUnwrap(loadedVault().record(Self.sourceID))
        XCTAssertNotNil(sourceRecord.x[opaqueStorageKey],
                        "vault.json must own the carrier before the transition")
        XCTAssertEqual(
            sourceRecord.x[futureOpaqueStorageKey],
            .string(try CanonicalJSON.data(futureCarrierValue).base64EncodedString()))
        XCTAssertNotNil(try loadedVault().record(variant.copyID))

        try? FileManager.default.removeItem(
            at: SnippetStorageLocations.syncLibraryMetadataFileURL)
        _ = try await fixture.session.unlock(reason: "Demote secure carrier source")
        try SecureSnippetTransitionCoordinator.demote(
            recordID: Self.sourceID,
            store: fixture.store,
            secureStore: fixture.secureStore)
        XCTAssertNotNil(fixture.store.snippet(id: Self.sourceID))
        XCTAssertNil(try loadedVault().record(Self.sourceID))

        // This same bridge was primed before demotion. Its in-memory metadata cache must
        // not shadow the transition's strict metadata-before-primary prewrite.
        let projected = try fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        let plainSource = try XCTUnwrap(projected[Self.sourceID])
        XCTAssertFalse(plainSource.secure)
        XCTAssertEqual(plainSource.x[variant.extensionKey], carrierValue)
        XCTAssertEqual(plainSource.x[futureCarrierKey], futureCarrierValue)
        XCTAssertEqual(plainSource.x[genericKey], genericValue)
        XCTAssertNil(plainSource.x[SyncEnvelope.vaultContentHashExtensionKey],
                     "plain projection may not retain a secure-body hash")
        XCTAssertNil(plainSource.x[SyncEnvelope.vaultKeyIDExtensionKey],
                     "plain projection may not claim secure vault scope")
        XCTAssertTrue(SyncMerge.hasUnresolvedContentConflict(plainSource),
                      "secure→plain ownership must not resolve an unacknowledged carrier")

        var reconciled = journal
        XCTAssertNoThrow(try reconciled.reconcileDependencies(
            current: projected,
            confirmed: base))
        XCTAssertNotNil(reconciled.dependency(Self.sourceID))
        XCTAssertEqual(reconciled.pending(confirmed: base).only?.id, variant.copyID,
                       "the materialized copy remains the first write after demotion")
        XCTAssertEqual(
            try loadedMetadata().envelope(Self.sourceID)?.x[variant.extensionKey],
            carrierValue)
        XCTAssertEqual(
            try loadedMetadata().envelope(Self.sourceID)?.x[futureCarrierKey],
            futureCarrierValue)
        XCTAssertEqual(
            try loadedMetadata().envelope(Self.sourceID)?.x[genericKey],
            genericValue)
        XCTAssertNil(try loadedMetadata().envelope(Self.sourceID)?.x[
            SyncEnvelope.vaultContentHashExtensionKey])
        XCTAssertNil(try loadedMetadata().envelope(Self.sourceID)?.x[
            SyncEnvelope.vaultKeyIDExtensionKey])
    }

    func testPlainInboundMergeDoesNotOverwritePrimaryEditCommittedAfterPrepare()
        async throws
    {
        let fixture = makeFixture()
        let localL0 = plainEnvelope(
            revision: 100,
            device: Self.deviceA,
            body: "plain local L0")
        _ = try fixture.bridge.applyRemote([localL0])
        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "plain-inbound-apply-race")
        backend.seed([try WireCodec.seal(localL0, using: sealer)])
        let storedL0 = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            localL0,
            recordVersion: try XCTUnwrap(storedL0.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        var remoteM = plainEnvelope(
            revision: 200,
            device: Self.deviceB,
            body: "plain remote M")
        var remoteFields = try XCTUnwrap(remoteM.fields)
        remoteFields.name = "Remote M name"
        remoteFields.keyword = "remote-m"
        remoteFields.tags = ["remote", "stale"]
        remoteFields.isPinned = true
        remoteM = replacingFields(of: remoteM, with: remoteFields)
        backend.seed([try WireCodec.seal(remoteM, using: sealer)])

        let racing = ApplyRaceLibrary(inner: fixture.bridge) {
            var localL1 = try XCTUnwrap(fixture.store.snippet(id: Self.sourceID))
            localL1.name = "Local L1 name"
            localL1.keyword = "local-l1"
            localL1.content = "plain local L1 committed after prepare"
            localL1.tags = ["local", "latest"]
            localL1.isEnabled = false
            localL1.isPinned = false
            fixture.store.update(localL1)
            try fixture.store.flushPendingWritesForSync()
        }
        let engine = makeEngine(
            backend: backend,
            bridge: racing,
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        let cursorBefore = engine.agreedBase.cursor

        let state = await engine.sync()

        XCTAssertFalse(state.isHalted)
        XCTAssertEqual(racing.prepareRemoteCalls, 2)
        XCTAssertEqual(racing.applyRemoteCalls, 2,
                       "one sync request must immediately replay a primary CAS miss")
        XCTAssertEqual(racing.applyOutcomes.first?.retryIDs, [Self.sourceID],
                       "the stale prepared M must be retried against primary L1")
        XCTAssertTrue(racing.applyOutcomes.first?.deferredIDs.isEmpty == true)
        XCTAssertTrue(racing.applyOutcomes.last?.retryIDs.isEmpty == true)
        XCTAssertTrue(racing.applyOutcomes.last?.deferredIDs.isEmpty == true)
        let afterRejectedStaleApply = try XCTUnwrap(
            racing.snapshotsAfterApply.first?.envelopes[Self.sourceID])
        XCTAssertEqual(afterRejectedStaleApply.fields?.name, "Local L1 name")
        XCTAssertEqual(afterRejectedStaleApply.fields?.keyword, "local-l1")
        XCTAssertEqual(afterRejectedStaleApply.fields?.content,
                       Data("plain local L1 committed after prepare".utf8))
        XCTAssertEqual(afterRejectedStaleApply.fields?.tags, ["local", "latest"])
        XCTAssertEqual(afterRejectedStaleApply.fields?.isEnabled, false)
        XCTAssertEqual(afterRejectedStaleApply.fields?.isPinned, false)

        // The bounded replay inside the same sync request must merge L1 against M,
        // rather than treating either as an unconditional replacement.
        let mergedSource = try XCTUnwrap(fixture.store.snippet(id: Self.sourceID))
        XCTAssertEqual(mergedSource.content, "plain local L1 committed after prepare")
        let mergedCopy = try XCTUnwrap(
            fixture.store.snippets.first(where: { $0.id != Self.sourceID }))
        XCTAssertEqual(mergedCopy.content, "plain remote M")
        XCTAssertEqual(engine.agreedBase.envelope(Self.sourceID), remoteM)
        XCTAssertNotEqual(engine.agreedBase.cursor, cursorBefore)
    }

    func testSecureInboundMergeDoesNotOverwriteVaultEditCommittedAfterPrepare()
        async throws
    {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare secure inbound apply race")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let localL0 = try secureEnvelope(
            plaintext: Data("secure local L0".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([localL0])
        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "secure-inbound-apply-race")
        backend.seed([try WireCodec.seal(localL0, using: sealer)])
        let storedL0 = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            localL0,
            recordVersion: try XCTUnwrap(storedL0.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        var remoteM = try secureEnvelope(
            plaintext: Data("secure remote M".utf8),
            revision: 200,
            device: Self.deviceB,
            vaultKID: document.kid,
            keyring: keyring)
        var remoteFields = try XCTUnwrap(remoteM.fields)
        remoteFields.name = "Secure remote M name"
        remoteFields.keyword = "secure-remote-m"
        remoteFields.tags = ["secure", "remote"]
        remoteFields.isPinned = true
        remoteM = replacingFields(of: remoteM, with: remoteFields)
        backend.seed([try WireCodec.seal(remoteM, using: sealer)])

        let racing = ApplyRaceLibrary(inner: fixture.bridge) {
            try fixture.secureStore.setContent(
                "secure local L1 committed after prepare",
                for: Self.sourceID)
            try fixture.secureStore.updateMetadata(
                id: Self.sourceID,
                name: "Secure local L1 name",
                keyword: "secure-local-l1",
                tags: ["secure", "local", "latest"],
                isEnabled: false,
                isPinned: false)
        }
        let engine = makeEngine(
            backend: backend,
            bridge: racing,
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        let cursorBefore = engine.agreedBase.cursor
        _ = try await fixture.session.unlock(
            reason: "Commit secure L1 at the apply race boundary")

        let state = await engine.sync()

        XCTAssertFalse(state.isHalted)
        XCTAssertEqual(racing.prepareRemoteCalls, 2)
        XCTAssertEqual(racing.applyRemoteCalls, 2,
                       "one sync request must immediately replay a vault CAS miss")
        XCTAssertEqual(racing.applyOutcomes.first?.retryIDs, [Self.sourceID],
                       "the stale secure M must be retried against vault L1")
        XCTAssertTrue(racing.applyOutcomes.first?.deferredIDs.isEmpty == true)
        XCTAssertTrue(racing.applyOutcomes.last?.retryIDs.isEmpty == true)
        XCTAssertTrue(racing.applyOutcomes.last?.deferredIDs.isEmpty == true,
                      "the bounded replay must not strand the secure remerge behind a reload lock")
        let afterRejectedStaleApply = try XCTUnwrap(
            racing.snapshotsAfterApply.first?.primaryStates[Self.sourceID])
        guard case .secure(let firstRetained, _, _) = afterRejectedStaleApply else {
            return XCTFail("the stale apply changed secure primary ownership")
        }
        XCTAssertEqual(firstRetained.name, "Secure local L1 name")
        XCTAssertEqual(firstRetained.keyword, "secure-local-l1")
        XCTAssertEqual(firstRetained.tags, ["secure", "local", "latest"])
        XCTAssertFalse(firstRetained.isEnabled)
        XCTAssertFalse(firstRetained.isPinned)
        _ = try await fixture.session.unlock(reason: "Inspect retained secure L1")
        XCTAssertEqual(
            try fixture.secureStore.content(for: Self.sourceID),
            "secure local L1 committed after prepare")

        _ = try await fixture.session.unlock(reason: "Inspect immediate secure retry merge")
        XCTAssertEqual(
            try fixture.secureStore.content(for: Self.sourceID),
            "secure local L1 committed after prepare")
        let mergedVault = try loadedVault()
        let mergedCopy = try XCTUnwrap(
            mergedVault.records.first(where: { $0.id != Self.sourceID }))
        XCTAssertNotNil(mergedCopy.x[SyncMerge.plainConflictCopyExtensionKey])
        XCTAssertEqual(
            try fixture.secureStore.content(for: mergedCopy.id),
            "secure remote M")
        XCTAssertEqual(engine.agreedBase.envelope(Self.sourceID), remoteM)
        XCTAssertNotEqual(engine.agreedBase.cursor, cursorBefore)
    }

    func testDeletingFrozenDerivedCopyAfterSnapshotRetriesCarrierApplyAndPreservesDeleteIntent()
        async throws
    {
        let harness = try await makeConflictHarness()
        let copyID = harness.scenario.variant.copyID
        let frozen = try XCTUnwrap(
            loadedJournal().dependency(Self.sourceID)?
                .requirements[harness.scenario.variant.fingerprint]?.snapshot)
        XCTAssertEqual(frozen.id, copyID)
        XCTAssertFalse(frozen.deleted)
        XCTAssertNotNil(try loadedVault().record(copyID))

        // Make the carrier source an authoritative incoming record, but keep C off the
        // backend for the first fetch. The rate-limited pre-push leaves the already
        // frozen prerequisite in the journal while the source reaches apply by itself.
        harness.backend.seed([
            try WireCodec.seal(harness.scenario.survivor, using: harness.sealer),
        ])
        harness.backend.rejectNextSubmit(.rateLimited(retryAfter: 1))
        harness.backend.rejectNextSubmit(.rateLimited(retryAfter: 1))
        _ = try await harness.fixture.session.unlock(
            reason: "Delete a frozen derived copy at the apply race boundary")
        let racing = ApplyRaceLibrary(inner: harness.fixture.bridge) {
            try harness.fixture.secureStore.delete(id: copyID)
        }
        let restarted = makeEngine(
            backend: harness.backend,
            bridge: racing,
            sealer: harness.sealer,
            deviceID: harness.fixture.store.deviceID)
        let beforeRace = harness.backend.submittedBatches.count

        let state = await restarted.sync()

        XCTAssertFalse(state.isHalted)
        XCTAssertGreaterThanOrEqual(racing.applyRemoteCalls, 2,
            "one sync request must replay the carrier against the post-delete primary")
        XCTAssertEqual(racing.applyOutcomes.first?.retryIDs, [Self.sourceID],
            "the carrier transaction reads derived C and must fail CAS when C disappears")
        XCTAssertEqual(
            racing.snapshotsAfterApply.first?.primaryState(for: copyID),
            .absent,
            "the stale carrier apply may not recreate C over the concurrent deletion")
        XCTAssertNil(try loadedVault().record(copyID),
            "the bounded replay must atomically reapply the protected local tombstone")

        let afterRace = try loadedJournal()
        let retainedRequirement = try XCTUnwrap(
            afterRace.dependency(Self.sourceID)?
                .requirements[harness.scenario.variant.fingerprint])
        XCTAssertEqual(retainedRequirement.snapshot, frozen,
            "the original live C remains the immutable prerequisite")
        guard afterRace.entry(copyID)?.desired.deleted == true else {
            XCTFail("the concurrent deletion survives as later ordinary intent")
            return
        }
        let copyAttempts = try openedBatches(after: beforeRace, in: harness)
            .flatMap { $0 }
        XCTAssertGreaterThanOrEqual(copyAttempts.count, 2)
        XCTAssertTrue(copyAttempts.allSatisfy {
            $0.id == copyID && !$0.deleted && $0 == frozen
        }, "both the rejected attempt and bounded retry must offer frozen C, never its delete")

        let beforeCopy = harness.backend.submittedBatches.count
        _ = try await harness.fixture.session.unlock(
            reason: "Accept frozen copy after its delete intent is durable")
        _ = await restarted.sync()
        let acceptedCopy = try XCTUnwrap(
            openedBatches(after: beforeCopy, in: harness).only?.only)
        XCTAssertEqual(acceptedCopy, frozen)

        let beforeSource = harness.backend.submittedBatches.count
        _ = try await harness.fixture.session.unlock(
            reason: "Release source after frozen copy acceptance")
        _ = await restarted.sync()
        let sourceRelease = try XCTUnwrap(
            openedBatches(after: beforeSource, in: harness).only?.only)
        XCTAssertEqual(sourceRelease.id, Self.sourceID)
        XCTAssertFalse(sourceRelease.deleted)
        XCTAssertNil(sourceRelease.x[harness.scenario.variant.extensionKey])
        XCTAssertNil(try loadedVault().record(copyID))

        let beforeDelete = harness.backend.submittedBatches.count
        _ = try await harness.fixture.session.unlock(
            reason: "Publish retained copy deletion after source fence")
        _ = await restarted.sync()
        let copyDelete = try XCTUnwrap(
            openedBatches(after: beforeDelete, in: harness).only?.only)
        XCTAssertEqual(copyDelete.id, copyID)
        XCTAssertTrue(copyDelete.deleted,
            "C deletion becomes eligible only after frozen C and the source release ACK")
    }

    // MARK: - Fixtures

    private func assertExactPlainConflictCopyUndoSupersedesTombstone(
        delete: (
            _ store: SnippetStore,
            _ copyID: UUID
        ) throws -> () -> Void
    ) throws {
        let fixture = makeFixture()
        let scenario = try plainConflictScenario()
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            scenario.ancestor,
            recordVersion: SyncRecordVersion(Data("undo-ancestor".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [scenario.copy])
        _ = try fixture.bridge.applyRemote([
            scenario.survivor,
            scenario.copy,
        ])
        // Model the normal post-apply engine fence. A merely frozen C0 is deliberately
        // not existence proof because the process may have died before primary apply;
        // observing the installed copy in ordinary reconciliation establishes the local
        // generation whose later absence is a real user deletion.
        let installed = try fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: confirmed))
        try journal.reconcileDependencies(
            current: installed,
            confirmed: confirmed)
        journal.reconcile(
            current: installed,
            confirmed: confirmed,
            deviceID: fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 0.5))
        XCTAssertEqual(journal.entry(scenario.copy.id)?.desired, scenario.copy)
        let originalSnippet = try XCTUnwrap(
            fixture.store.snippet(id: scenario.copy.id))
        let restore = try delete(fixture.store, scenario.copy.id)
        XCTAssertNil(fixture.store.snippet(id: scenario.copy.id))

        let afterDelete = try fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: confirmed))
        try journal.reconcileDependencies(
            current: afterDelete,
            confirmed: confirmed)
        journal.reconcile(
            current: afterDelete,
            confirmed: confirmed,
            deviceID: fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 1))
        let tombstone = try XCTUnwrap(
            journal.entry(scenario.copy.id)?.desired)
        XCTAssertTrue(tombstone.deleted)
        XCTAssertNil(
            tombstone.x[SyncMerge.plainConflictCopyExtensionKey],
            "ordinary deletion intent does not carry deterministic-copy provenance")

        restore()
        XCTAssertEqual(
            fixture.store.snippet(id: scenario.copy.id),
            originalSnippet,
            "the fixture must restore the exact frozen Snippet bytes")
        let restored = try fixture.bridge.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: confirmed))
        let restoredCopy = try XCTUnwrap(restored[scenario.copy.id])
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            restoredCopy,
            sourceID: scenario.survivor.id,
            fingerprint: scenario.fingerprint))

        try journal.reconcileDependencies(
            current: restored,
            confirmed: confirmed)
        journal.reconcile(
            current: restored,
            confirmed: confirmed,
            deviceID: fixture.store.deviceID,
            now: Date(timeIntervalSince1970: 2))

        let desired = try XCTUnwrap(journal.entry(scenario.copy.id)?.desired)
        XCTAssertFalse(
            desired.deleted,
            "an explicit user Undo must not be mistaken for protocol C0 materialization")
        XCTAssertEqual(desired.fields, restoredCopy.fields)
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            desired,
            sourceID: scenario.survivor.id,
            fingerprint: scenario.fingerprint))
        XCTAssertEqual(
            journal.dependency(scenario.survivor.id)?
                .requirements[scenario.fingerprint]?.snapshot,
            scenario.copy,
            "Undo changes ordinary intent without rewriting the frozen prerequisite")
    }

    private func plainConflictScenario() throws -> (
        ancestor: SyncEnvelope,
        survivor: SyncEnvelope,
        copy: SyncEnvelope,
        fingerprint: String
    ) {
        let ancestor = plainEnvelope(
            revision: 100,
            device: Self.deviceA,
            body: "plain ancestor")
        let losing = plainEnvelope(
            revision: 200,
            device: Self.deviceA,
            body: "plain losing edit")
        let winning = plainEnvelope(
            revision: 300,
            device: Self.deviceB,
            body: "plain winning edit")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let survivor = try XCTUnwrap(merge.survivor)
        let copy = try XCTUnwrap(merge.conflictCopies.only)
        let provenance = try XCTUnwrap(SyncMerge.conflictCopyProvenance(in: copy))
        return (ancestor, survivor, copy, provenance.fingerprint)
    }

    private func laterStandaloneCopy(
        in harness: SecureDependencyHarness
    ) throws -> SyncEnvelope {
        var copy = try XCTUnwrap(
            harness.fixture.bridge.currentEnvelopes(
                agreedBase: harness.engine.agreedBase)[harness.scenario.variant.copyID])
        copy.hlc = HLC(wallMs: 900, counter: 0, device: Self.deviceB)
        copy.origin = Self.deviceB
        var fields = try XCTUnwrap(copy.fields)
        fields.updatedAt = Date(timeIntervalSince1970: 0.9)
        return replacingFields(of: copy, with: fields)
    }

    private func replacingFields(
        of envelope: SyncEnvelope,
        with fields: SyncEnvelope.Fields
    ) -> SyncEnvelope {
        SyncEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            hlc: envelope.hlc,
            origin: envelope.origin,
            secure: envelope.secure,
            deleted: false,
            fields: fields,
            x: envelope.x)
    }

    private func makeConflictHarness(
        fixture suppliedFixture: SecureDependencyFixture? = nil
    ) async throws -> SecureDependencyHarness {
        let fixture = suppliedFixture ?? makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare dependency fixture")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()

        let ancestor = try secureEnvelope(
            plaintext: Data("ancestor secret".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let localSecureEdit = try secureEnvelope(
            plaintext: Data("secure edit that must survive".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let remotePlainEdit = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Remote plain winner",
                keyword: "remote-winner",
                content: "plain body from the other device",
                tags: ["remote"],
                isEnabled: true,
                isPinned: true,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        var seededVault = document
        seededVault.records = [try XCTUnwrap(
            SyncLibraryProjection.vaultRecord(from: localSecureEdit))]
        try VaultFile.write(seededVault)
        fixture.secureStore.reload(notifyChange: false)
        _ = try await fixture.session.unlock(reason: "Unlock dependency fixture")

        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "secure-conflict-dependency-test")
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let storedAncestor = try XCTUnwrap(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        // VaultRecord intentionally freezes less envelope metadata than the wire type.
        // Derive the expected conflict from the bridge's real projection, exactly as
        // the engine will see it, rather than from the construction input above.
        let projectedSecureEdit = try XCTUnwrap(
            fixture.bridge.currentEnvelopes(agreedBase: base)[Self.sourceID])
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: projectedSecureEdit,
            remote: remotePlainEdit)
        let survivor = try XCTUnwrap(merge.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: survivor).first)
        let carrierValue = try XCTUnwrap(survivor.x[variant.extensionKey])
        backend.seed([try WireCodec.seal(remotePlainEdit, using: sealer)])

        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        let submissionsBeforeConflict = backend.submittedBatches.count
        let setupState = await engine.sync()
        XCTAssertFalse(setupState.isHalted)
        if case .waitingForVault = setupState {
            XCTFail("a carrier-only fetch has no phantom dependent record to defer")
        }
        XCTAssertEqual(engine.agreedBase.cursor, backend.currentCursor,
                       "successful carrier-only apply must advance the fetch cursor")
        XCTAssertEqual(
            backend.submittedBatches.count,
            submissionsBeforeConflict + 1,
            "the setup round must be the stale secure-source attempt only")

        return SecureDependencyHarness(
            fixture: fixture,
            backend: backend,
            sealer: sealer,
            engine: engine,
            scenario: SecureDependencyScenario(
                ancestor: ancestor,
                localSecureEdit: projectedSecureEdit,
                remotePlainEdit: remotePlainEdit,
                survivor: survivor,
                variant: variant,
                carrierValue: carrierValue,
                keyring: keyring,
                vaultKID: document.kid))
    }

    private func assertSameFetchPlainC1IsHeldWithUnavailableCarrier(
        createRivalVault: Bool
    ) async throws {
        let fixture = makeFixture()
        if createRivalVault {
            let pending = try XCTUnwrap(
                fixture.secureStore.prepareVaultCreationIfNeeded())
            _ = try fixture.secureStore.commitVaultCreation(pending)
        }
        let remoteKeyring = SnippetCrypto.Keyring.generate()
        let remoteVaultKID = "remote-carrier-vault"
        let ancestor = try secureEnvelope(
            plaintext: Data("unavailable carrier ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: remoteVaultKID,
            keyring: remoteKeyring)
        let losing = try secureEnvelope(
            plaintext: Data("unavailable carrier C0".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: remoteVaultKID,
            keyring: remoteKeyring)
        let winner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Unavailable-carrier winner",
                keyword: "unavailable-carrier",
                content: "source whose secure loser cannot be opened locally",
                tags: ["deferred"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winner)
        let source = try XCTUnwrap(merge.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: source).only)
        let c0Shape = try materializedSecureConflictCopy(
            source: source,
            variant: variant,
            keyring: remoteKeyring,
            vaultKID: remoteVaultKID)
        var plainC1 = SyncEnvelope.plain(
            Snippet(
                id: variant.copyID,
                name: "Plain C1 beside unavailable carrier",
                keyword: "held-plain-c1",
                content: "must not orphan from its deferred source",
                tags: ["conflict", "plain-c1"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.4)),
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        plainC1.x[SyncMerge.plainConflictCopyExtensionKey] = try XCTUnwrap(
            c0Shape.x[SyncMerge.plainConflictCopyExtensionKey])

        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: createRivalVault
                ? "rival-vault-carrier-with-plain-c1"
                : "missing-vault-carrier-with-plain-c1")
        let base = SyncBase(journalEstablished: true)
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        backend.seed([
            try WireCodec.seal(source, using: sealer),
            try WireCodec.seal(plainC1, using: sealer),
        ])
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)

        let state = await engine.sync()

        if createRivalVault {
            guard case .halted(.vaultUnreadable, _) = state else {
                return XCTFail("a rival-vault carrier must halt without orphaning plain C1")
            }
        } else {
            guard case .waitingForVault = state else {
                return XCTFail("a missing key must defer the carrier and its plain C1 together")
            }
        }
        XCTAssertNil(fixture.store.snippet(id: variant.copyID))
        XCTAssertNil(fixture.secureStore.record(variant.copyID))
        XCTAssertNil(engine.agreedBase.envelope(variant.copyID),
                     "dependent plain C1 may not be confirmed independently")
        XCTAssertTrue(backend.submittedBatches.isEmpty)
    }

    private func assertSameFetchCopyTombstoneIsHeldWithUnavailableCarrier(
        createRivalVault: Bool
    ) async throws {
        let fixture = makeFixture()
        if createRivalVault {
            let pending = try XCTUnwrap(
                fixture.secureStore.prepareVaultCreationIfNeeded())
            _ = try fixture.secureStore.commitVaultCreation(pending)
        }
        let remoteKeyring = SnippetCrypto.Keyring.generate()
        let remoteVaultKID = "remote-tombstone-carrier-vault"
        let ancestor = try secureEnvelope(
            plaintext: Data("unavailable tombstone carrier ancestor".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: remoteVaultKID,
            keyring: remoteKeyring)
        let losing = try secureEnvelope(
            plaintext: Data("unavailable tombstone carrier C0".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: remoteVaultKID,
            keyring: remoteKeyring)
        let winner = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Unavailable tombstone-carrier winner",
                keyword: "unavailable-tombstone-carrier",
                content: "source whose copy deletion must remain coupled",
                tags: ["deferred", "tombstone"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winner)
        let source = try XCTUnwrap(merge.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: source).only)
        let copyTombstone = SyncEnvelope.tombstone(
            id: variant.copyID,
            secure: true,
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [
                SyncEnvelope.vaultKeyIDExtensionKey: .string(remoteVaultKID),
            ])

        let backend = SecureDependencyTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: createRivalVault
                ? "rival-carrier-with-copy-tombstone"
                : "missing-carrier-with-copy-tombstone")
        let base = SyncBase(journalEstablished: true)
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try SyncJournalFile.write(
            SyncJournal(),
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        backend.seed([
            try WireCodec.seal(source, using: sealer),
            try WireCodec.seal(copyTombstone, using: sealer),
        ])
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)

        let state = await engine.sync()

        if createRivalVault {
            guard case .halted(.vaultUnreadable, _) = state else {
                return XCTFail("rival carrier must halt without confirming dependent T")
            }
        } else {
            guard case .waitingForVault = state else {
                return XCTFail("missing key must defer carrier and dependent T together")
            }
        }
        XCTAssertNil(fixture.store.snippet(id: variant.copyID))
        XCTAssertNil(fixture.secureStore.record(variant.copyID))
        XCTAssertNil(engine.agreedBase.envelope(variant.copyID),
                     "dependent T may not be confirmed independently of unavailable C0")
        XCTAssertTrue(backend.submittedBatches.isEmpty)
    }

    private func assertReviewedResetMaterializesPrerequisite(
        _ kind: SecureDependencyResetKind
    ) async throws {
        let harness = try await makeStagedResetHarness(kind)
        let stopped = await harness.engine.sync()
        switch (kind, stopped) {
        case (.account, .halted(.accountChanged, _)),
             (.checkpoint, .halted(.checkpointUnreadable, _)):
            break
        default:
            return XCTFail("fixture must stop for reviewed \(kind) reset, got \(stopped)")
        }
        XCTAssertNil(try loadedVault().record(harness.scenario.variant.copyID))
        harness.engine.clearHaltAfterUserReview()
        let beforeCopy = harness.backend.submittedBatches.count

        var recovered = await harness.engine.sync()
        if case .waitingForVault = recovered {
            _ = try await harness.fixture.session.unlock(
                reason: "Resume reviewed reset after prerequisite materialization")
            recovered = await harness.engine.sync()
        }
        guard case .idle = recovered else {
            return XCTFail("reviewed \(kind) reset should complete, got \(recovered)")
        }

        switch kind {
        case .account:
            XCTAssertEqual(harness.backend.accountReviewResetAttempts, 1)
            XCTAssertEqual(harness.backend.checkpointReviewResetAttempts, 0)
        case .checkpoint:
            XCTAssertEqual(harness.backend.accountReviewResetAttempts, 0)
            XCTAssertEqual(harness.backend.checkpointReviewResetAttempts, 1)
        }
        XCTAssertNotNil(try loadedVault().record(harness.scenario.variant.copyID),
                        "reset preflight must materialize the carrier while the old scope exists")
        var submitted = try openedBatches(after: beforeCopy, in: harness)
        let copy = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(copy.id, harness.scenario.variant.copyID)
        XCTAssertFalse(copy.deleted)
        XCTAssertFalse(submitted.flatMap { $0 }.contains { $0.id == Self.sourceID })
        XCTAssertTrue(SyncMerge.matchesConflictCopyProvenance(
            copy,
            sourceID: Self.sourceID,
            fingerprint: harness.scenario.variant.fingerprint))
        let resetBase = harness.engine.agreedBase
        XCTAssertEqual(resetBase.accountIdentity, SecureDependencyResetKind.accountB)
        XCTAssertNotNil(resetBase.envelope(harness.scenario.variant.copyID))

        let beforeSource = harness.backend.submittedBatches.count
        _ = await harness.engine.sync()
        submitted = try openedBatches(after: beforeSource, in: harness)
        let source = try XCTUnwrap(submitted.only?.only)
        XCTAssertEqual(source.id, Self.sourceID)
        XCTAssertNil(source.x[harness.scenario.variant.extensionKey])
        XCTAssertFalse(SyncMerge.hasUnresolvedContentConflict(source))
    }

    private func makeStagedResetHarness(
        _ kind: SecureDependencyResetKind,
        requiresLocalFullResync: Bool = false
    ) async throws -> SecureDependencyHarness {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare reviewed reset fixture")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let ancestor = try secureEnvelope(
            plaintext: Data("ancestor before reset".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        let localSecureEdit = try secureEnvelope(
            plaintext: Data("secure edit stranded at reset".utf8),
            revision: 200,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        var vault = document
        vault.records = [try XCTUnwrap(
            SyncLibraryProjection.vaultRecord(from: localSecureEdit))]
        try VaultFile.write(vault)
        fixture.secureStore.reload(notifyChange: false)
        _ = try await fixture.session.unlock(reason: "Unlock reviewed reset fixture")

        var base = SyncBase(
            cursor: SyncCursor("old-scope-cursor"),
            cursorKind: .legacy,
            journalEstablished: true,
            accountIdentity: kind == .account
                ? SecureDependencyResetKind.accountA
                : SecureDependencyResetKind.accountB,
            requiresTransportFullResync: requiresLocalFullResync)
        base.recordConfirmed(
            ancestor,
            recordVersion: SyncRecordVersion(Data("old-scope-generation".utf8)))
        try SyncBaseFile.write(
            base,
            to: SnippetStorageLocations.syncBaseFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let projectedSecureEdit = try XCTUnwrap(
            fixture.bridge.currentEnvelopes(agreedBase: base)[Self.sourceID])
        let remotePlainEdit = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Plain survivor before reset",
                keyword: "plain-reset-survivor",
                content: "plain body before reset",
                tags: ["reset"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 0.3)),
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: projectedSecureEdit,
            remote: remotePlainEdit)
        let survivor = try XCTUnwrap(merge.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: survivor).only)
        let carrierValue = try XCTUnwrap(survivor.x[variant.extensionKey])
        var journal = SyncJournal()
        try journal.stageConflictDependency(source: survivor, conflictCopies: [])
        try SyncJournalFile.write(
            journal,
            to: SnippetStorageLocations.syncJournalFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let stagedRequirement = try XCTUnwrap(
            journal.dependency(Self.sourceID)?.requirements.values.first)
        XCTAssertNil(stagedRequirement.snapshot,
                     "the reset fixture must begin in the post-stage/pre-apply crash window")

        let backend = SecureDependencyTransport()
        backend.configureScope(
            identity: SecureDependencyResetKind.accountB,
            checkpointIssue: kind == .checkpoint && !requiresLocalFullResync
                ? .unreadable : nil)
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "secure-conflict-reset-test")
        if requiresLocalFullResync {
            // A same-account local scheduler reset retains record CAS generations.
            // Seed the ancestor into this backend and bind the fixture to its actual
            // cursor/generation; a made-up old-scope generation describes an account
            // replacement fixture and makes every later source offer spuriously race.
            backend.seed([try WireCodec.seal(ancestor, using: sealer)])
            let storedAncestor = try XCTUnwrap(backend.snapshot.only)
            base.cursor = backend.currentCursor
            base.recordConfirmed(
                ancestor,
                recordVersion: try XCTUnwrap(storedAncestor.recordVersion))
            try SyncBaseFile.write(
                base,
                to: SnippetStorageLocations.syncBaseFileURL,
                temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        }
        let engine = makeEngine(
            backend: backend,
            bridge: fixture.bridge,
            sealer: sealer,
            deviceID: fixture.store.deviceID)
        return SecureDependencyHarness(
            fixture: fixture,
            backend: backend,
            sealer: sealer,
            engine: engine,
            scenario: SecureDependencyScenario(
                ancestor: ancestor,
                localSecureEdit: projectedSecureEdit,
                remotePlainEdit: remotePlainEdit,
                survivor: survivor,
                variant: variant,
                carrierValue: carrierValue,
                keyring: keyring,
                vaultKID: document.kid))
    }

    private func makeStagedLocalFullResyncHarness() async throws
        -> SecureDependencyHarness
    {
        try await makeStagedResetHarness(
            .checkpoint,
            requiresLocalFullResync: true)
    }

    private func assertUnsafeProjectionSidecarFailsClosed(
        _ bytes: Data,
        expectedReason: SyncState.HaltReason
    ) async throws {
        let fixture = makeFixture()
        let pending = try XCTUnwrap(fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(
            reason: "Prepare fail-closed projection sidecar fixture")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let secure = try secureEnvelope(
            plaintext: Data("authoritative secure primary".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: document.kid,
            keyring: keyring)
        _ = try fixture.bridge.applyRemote([secure])
        let primaryRecord = try XCTUnwrap(loadedVault().record(Self.sourceID))
        let vaultBytes = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        try bytes.write(
            to: SnippetStorageLocations.syncLibraryMetadataFileURL,
            options: .atomic)
        let sidecarBytes = try Data(
            contentsOf: SnippetStorageLocations.syncLibraryMetadataFileURL)

        SyncCoordinator.runtimeEnabledOverride = false
        let restarted = recreateFixture(using: fixture)
        do {
            _ = try restarted.bridge.currentEnvelopes(agreedBase: SyncBase())
            XCTFail("unknown or unreadable sidecar bytes must fail closed")
        } catch let failure as SyncEngineFailure {
            XCTAssertEqual(failure.reason, expectedReason)
        } catch {
            XCTFail("expected a typed sync halt, got \(error)")
        }

        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncLibraryMetadataFileURL),
            sidecarBytes,
            "fail-closed projection may not replace bytes it cannot understand")
        XCTAssertEqual(try loadedVault().record(Self.sourceID), primaryRecord)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            vaultBytes)
    }

    private func recreateFixture(
        using fixture: SecureDependencyFixture
    ) -> SecureDependencyFixture {
        let session = VaultSession(
            keychain: fixture.keychain,
            authenticationEvaluator: { _ in true })
        let store = SnippetStore(configuration: .iOS)
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: fixture.keychain,
            deviceID: store.deviceID)
        store.secureProvider = secureStore
        return SecureDependencyFixture(
            store: store,
            secureStore: secureStore,
            session: session,
            keychain: fixture.keychain,
            bridge: SnippetLibraryBridge(store: store, secureStore: secureStore))
    }

    private func makeFixture(
        keychain suppliedKeychain: KeychainSecretStore? = nil,
        syncMetadataWriter: @escaping (SyncBase, URL, URL) throws -> Void = {
            try SyncBaseFile.write($0, to: $1, temporaryDirectory: $2)
        }
    ) -> SecureDependencyFixture {
        let keychain = suppliedKeychain ?? KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
        let session = VaultSession(
            keychain: keychain,
            authenticationEvaluator: { _ in true })
        let store = SnippetStore(configuration: .iOS)
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: keychain,
            deviceID: store.deviceID,
            syncMetadataWriter: syncMetadataWriter)
        store.secureProvider = secureStore
        return SecureDependencyFixture(
            store: store,
            secureStore: secureStore,
            session: session,
            keychain: keychain,
            bridge: SnippetLibraryBridge(store: store, secureStore: secureStore))
    }

    private func makeEngine(
        backend: SecureDependencyTransport,
        bridge: any SyncLibraryAccess,
        sealer: SnippetCryptoSealer,
        deviceID: String
    ) -> SyncEngine {
        SyncEngine(
            transport: backend,
            library: bridge,
            sealer: sealer,
            device: deviceID,
            baseURL: SnippetStorageLocations.syncBaseFileURL,
            journalURL: SnippetStorageLocations.syncJournalFileURL,
            stateURL: SnippetStorageLocations.syncStateFileURL,
            lockURL: SnippetStorageLocations.libraryLockFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
    }

    private func secureEnvelope(
        plaintext: Data,
        id requestedID: UUID? = nil,
        revision: UInt64,
        device: String,
        vaultKID: String,
        keyring: SnippetCrypto.Keyring
    ) throws -> SyncEnvelope {
        let id = requestedID ?? Self.sourceID
        let sealed = try SnippetCrypto.seal(
            plaintext,
            for: SnippetCrypto.RecordContext(
                scopeID: vaultKID,
                recordID: id),
            keyring: keyring)
        return SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: true,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Secure source",
                keyword: "secure-source",
                content: Data(sealed.utf8),
                tags: ["secure"],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)),
            x: [
                SyncEnvelope.vaultContentHashExtensionKey: .string(
                    SnippetCrypto.contentHash(of: plaintext, keyring: keyring)),
                SyncEnvelope.vaultKeyIDExtensionKey: .string(vaultKID),
            ])
    }

    private func materializedSecureConflictCopy(
        source: SyncEnvelope,
        variant: SyncMerge.SecureContentConflictVariant,
        keyring: SnippetCrypto.Keyring,
        vaultKID: String
    ) throws -> SyncEnvelope {
        let result = try SyncSecureConflictMaterializer.materialize(
            envelope: source,
            keyring: keyring,
            vaultKID: vaultKID,
            existingSnippets: [],
            existingRecords: [])
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: result.records,
            deviceID: source.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: vaultKID)
        return try XCTUnwrap(projected[variant.copyID])
    }

    private func decryptedSecureContent(
        _ envelope: SyncEnvelope,
        vaultKID: String,
        keyring: SnippetCrypto.Keyring
    ) throws -> Data {
        let fields = try XCTUnwrap(envelope.fields)
        let sealed = try XCTUnwrap(String(data: fields.content, encoding: .utf8))
        return try SnippetCrypto.open(
            sealed,
            for: SnippetCrypto.RecordContext(
                scopeID: vaultKID,
                recordID: envelope.id),
            keyring: keyring)
    }

    @discardableResult
    private func assertMetadataDoesNotContainPlaintext(
        _ plaintext: Data,
        id: UUID,
        at metadataURL: URL
    ) throws -> SyncEnvelope {
        guard case .loaded(let metadata) = SyncBaseFile.load(from: metadataURL) else {
            throw SecureDependencyFixtureFailure.expectedReadableMetadata
        }
        let envelope = try XCTUnwrap(metadata.envelope(id))
        XCTAssertNotEqual(envelope.fields?.content, plaintext,
                          "sync metadata may not hold the decrypted snippet body")

        let plaintextBase64 = Data(plaintext.base64EncodedString().utf8)
        let canonical = try envelope.canonicalData()
        XCTAssertNil(canonical.range(of: plaintext))
        XCTAssertNil(canonical.range(of: plaintextBase64),
                     "the canonical envelope may not encode the plaintext body")
        let outer = try Data(contentsOf: metadataURL)
        XCTAssertNil(outer.range(of: plaintext))
        XCTAssertNil(outer.range(of: plaintextBase64))
        return envelope
    }

    private func plainEnvelope(
        revision: UInt64,
        device: String,
        body: String
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: Self.sourceID,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Plain source",
                keyword: "plain-source",
                content: Data(body.utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)))
    }

    private func openedBatches(
        after offset: Int,
        in harness: SecureDependencyHarness
    ) throws -> [[SyncEnvelope]] {
        try harness.backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: harness.sealer) }
        }
    }

    private func openedBackend(
        in harness: SecureDependencyHarness
    ) throws -> [UUID: SyncEnvelope] {
        try harness.backend.snapshot.reduce(into: [:]) { result, record in
            let envelope = try WireCodec.open(record, using: harness.sealer)
            result[envelope.id] = envelope
        }
    }

    private func loadedMetadata() throws -> SyncBase {
        guard case .loaded(let metadata) = SyncBaseFile.load(
            from: SnippetStorageLocations.syncLibraryMetadataFileURL)
        else { throw SecureDependencyFixtureFailure.expectedReadableMetadata }
        return metadata
    }

    private func loadedJournal() throws -> SyncJournal {
        guard case .loaded(let journal) = SyncJournalFile.load(
            from: SnippetStorageLocations.syncJournalFileURL)
        else { throw SecureDependencyFixtureFailure.expectedReadableJournal }
        return journal
    }

    private func loadedVault() throws -> VaultDocument {
        try XCTUnwrap(VaultFile.load().value)
    }
}

private enum SecureDependencyFixtureFailure: Error {
    case expectedReadableMetadata
    case expectedReadableJournal
    case injectedMetadataWrite
    case injectedReceiptPrune
}

private enum SecureDependencyResetKind: CustomStringConvertible {
    case account
    case checkpoint

    static let accountA = SyncAccountIdentity(Data(repeating: 0xa1, count: 32))
    static let accountB = SyncAccountIdentity(Data(repeating: 0xb2, count: 32))

    var description: String {
        switch self {
        case .account: return "account"
        case .checkpoint: return "checkpoint"
        }
    }
}

@MainActor
private final class ReceiptPruneFailureLibrary: SyncLibraryAccess {
    private let inner: SnippetLibraryBridge
    private var shouldFailEmptyRetention = true
    private(set) var injectedFailureCount = 0

    init(inner: SnippetLibraryBridge) {
        self.inner = inner
    }

    var supportsSecureConflictMaterialization: Bool {
        inner.supportsSecureConflictMaterialization
    }

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        try inner.currentEnvelopes(agreedBase: agreedBase)
    }

    func currentSnapshot(agreedBase: SyncBase) throws -> SyncLibrarySnapshot {
        try inner.currentSnapshot(agreedBase: agreedBase)
    }

    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
        inner.classifyRemote(envelopes)
    }

    func prepareRemote(_ envelopes: [SyncEnvelope]) throws -> RemoteClassification {
        try inner.prepareRemote(envelopes)
    }

    func prepareConflictCopyEvidence(
        from envelopes: [SyncEnvelope]
    ) throws -> [SyncEnvelope] {
        try inner.prepareConflictCopyEvidence(from: envelopes)
    }

    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome {
        try inner.applyRemote(envelopes)
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        try inner.applyRemote(envelopes, expectedPrimary: expectedPrimary)
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope]
    ) throws -> ApplyOutcome {
        try inner.applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: heldConflictCopyIntents,
            preparedConflictCopyEvidence: preparedConflictCopyEvidence)
    }

    func resolveConflictCarriers(
        _ resolutions: [SyncJournal.ConflictCarrierResolution]
    ) throws -> ApplyOutcome {
        try inner.resolveConflictCarriers(resolutions)
    }

    func materializeConflictPrerequisites(
        from sources: [SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        try inner.materializeConflictPrerequisites(
            from: sources,
            preparedConflictCopyEvidence: preparedConflictCopyEvidence,
            heldConflictCopyIntents: heldConflictCopyIntents,
            expectedPrimary: expectedPrimary)
    }

    func retainConflictPrerequisiteInstallReceipts(for ids: Set<UUID>) throws {
        if shouldFailEmptyRetention, ids.isEmpty {
            shouldFailEmptyRetention = false
            injectedFailureCount += 1
            throw SecureDependencyFixtureFailure.injectedReceiptPrune
        }
        try inner.retainConflictPrerequisiteInstallReceipts(for: ids)
    }

    func liveIDs() -> Set<UUID> { inner.liveIDs() }
}

@MainActor
private final class ApplyRaceLibrary: SyncLibraryAccess {
    private let inner: SnippetLibraryBridge
    private var beforeFirstApply: (() throws -> Void)?
    private(set) var prepareRemoteCalls = 0
    private(set) var applyRemoteCalls = 0
    private(set) var lastApplyOutcome: ApplyOutcome?
    private(set) var applyOutcomes: [ApplyOutcome] = []
    private(set) var snapshotsAfterApply: [SyncLibrarySnapshot] = []

    init(
        inner: SnippetLibraryBridge,
        beforeFirstApply: @escaping () throws -> Void
    ) {
        self.inner = inner
        self.beforeFirstApply = beforeFirstApply
    }

    var supportsSecureConflictMaterialization: Bool {
        inner.supportsSecureConflictMaterialization
    }

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        try inner.currentEnvelopes(agreedBase: agreedBase)
    }

    func currentSnapshot(agreedBase: SyncBase) throws -> SyncLibrarySnapshot {
        try inner.currentSnapshot(agreedBase: agreedBase)
    }

    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
        inner.classifyRemote(envelopes)
    }

    func prepareRemote(_ envelopes: [SyncEnvelope]) throws -> RemoteClassification {
        prepareRemoteCalls += 1
        return try inner.prepareRemote(envelopes)
    }

    func prepareConflictCopyEvidence(
        from envelopes: [SyncEnvelope]
    ) throws -> [SyncEnvelope] {
        try inner.prepareConflictCopyEvidence(from: envelopes)
    }

    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome {
        try inner.applyRemote(envelopes)
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        try applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: [:],
            preparedConflictCopyEvidence: [])
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope]
    ) throws -> ApplyOutcome {
        try applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: heldConflictCopyIntents,
            preparedConflictCopyEvidence: [])
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope]
    ) throws -> ApplyOutcome {
        applyRemoteCalls += 1
        if let race = beforeFirstApply {
            beforeFirstApply = nil
            try race()
        }
        let outcome = try inner.applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: heldConflictCopyIntents,
            preparedConflictCopyEvidence: preparedConflictCopyEvidence)
        lastApplyOutcome = outcome
        applyOutcomes.append(outcome)
        snapshotsAfterApply.append(try inner.currentSnapshot(agreedBase: SyncBase()))
        return outcome
    }

    func resolveConflictCarriers(
        _ resolutions: [SyncJournal.ConflictCarrierResolution]
    ) throws -> ApplyOutcome {
        try inner.resolveConflictCarriers(resolutions)
    }

    func materializeConflictPrerequisites(
        from sources: [SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        try inner.materializeConflictPrerequisites(
            from: sources,
            preparedConflictCopyEvidence: preparedConflictCopyEvidence,
            heldConflictCopyIntents: heldConflictCopyIntents,
            expectedPrimary: expectedPrimary)
    }

    func liveIDs() -> Set<UUID> { inner.liveIDs() }
}

@MainActor
private final class MaterializationRaceLibrary: SyncLibraryAccess {
    private let inner: SnippetLibraryBridge
    private var beforeFirstMaterialization: (() throws -> Void)?
    private(set) var materializationCalls = 0
    private(set) var outcomes: [ApplyOutcome] = []

    init(
        inner: SnippetLibraryBridge,
        beforeFirstMaterialization: @escaping () throws -> Void
    ) {
        self.inner = inner
        self.beforeFirstMaterialization = beforeFirstMaterialization
    }

    var supportsSecureConflictMaterialization: Bool {
        inner.supportsSecureConflictMaterialization
    }

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        try inner.currentEnvelopes(agreedBase: agreedBase)
    }

    func currentSnapshot(agreedBase: SyncBase) throws -> SyncLibrarySnapshot {
        try inner.currentSnapshot(agreedBase: agreedBase)
    }

    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
        inner.classifyRemote(envelopes)
    }

    func prepareRemote(_ envelopes: [SyncEnvelope]) throws -> RemoteClassification {
        try inner.prepareRemote(envelopes)
    }

    func prepareConflictCopyEvidence(
        from envelopes: [SyncEnvelope]
    ) throws -> [SyncEnvelope] {
        try inner.prepareConflictCopyEvidence(from: envelopes)
    }

    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome {
        try inner.applyRemote(envelopes)
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        try inner.applyRemote(envelopes, expectedPrimary: expectedPrimary)
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope]
    ) throws -> ApplyOutcome {
        try inner.applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: heldConflictCopyIntents,
            preparedConflictCopyEvidence: preparedConflictCopyEvidence)
    }

    func resolveConflictCarriers(
        _ resolutions: [SyncJournal.ConflictCarrierResolution]
    ) throws -> ApplyOutcome {
        try inner.resolveConflictCarriers(resolutions)
    }

    func materializeConflictPrerequisites(
        from sources: [SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        materializationCalls += 1
        if let race = beforeFirstMaterialization {
            beforeFirstMaterialization = nil
            try race()
        }
        let outcome = try inner.materializeConflictPrerequisites(
            from: sources,
            preparedConflictCopyEvidence: preparedConflictCopyEvidence,
            heldConflictCopyIntents: heldConflictCopyIntents,
            expectedPrimary: expectedPrimary)
        outcomes.append(outcome)
        return outcome
    }

    func liveIDs() -> Set<UUID> { inner.liveIDs() }
}

@MainActor
private struct SecureDependencyFixture {
    let store: SnippetStore
    let secureStore: SecureSnippetStore
    let session: VaultSession
    let keychain: KeychainSecretStore
    let bridge: SnippetLibraryBridge
}

@MainActor
private struct SecureDependencyHarness {
    let fixture: SecureDependencyFixture
    let backend: SecureDependencyTransport
    let sealer: SnippetCryptoSealer
    let engine: SyncEngine
    let scenario: SecureDependencyScenario
}

private struct SecureDependencyScenario {
    let ancestor: SyncEnvelope
    let localSecureEdit: SyncEnvelope
    let remotePlainEdit: SyncEnvelope
    let survivor: SyncEnvelope
    let variant: SyncMerge.SecureContentConflictVariant
    let carrierValue: CanonicalJSON.Value
    let keyring: SnippetCrypto.Keyring
    let vaultKID: String
}

@MainActor
private final class RekeyCollisionLibrary: SyncLibraryAccess {
    private let envelopes: [UUID: SyncEnvelope]
    private(set) var currentEnvelopeCallCount = 0

    init(envelopes: [UUID: SyncEnvelope]) {
        self.envelopes = envelopes
    }

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        currentEnvelopeCallCount += 1
        return envelopes
    }

    func classifyRemote(_ incoming: [SyncEnvelope]) -> RemoteClassification {
        RemoteClassification(
            applicable: incoming,
            deferredIDs: [],
            incompatibleVaultIDs: [])
    }

    func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
        ApplyOutcome(changedIDs: incoming.map(\.id))
    }

    func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

/// Test-target counterpart of CorePackage's `InMemoryTransport`.
///
/// The iOS app target intentionally does not link that development backend, so this
/// fixture keeps only the honest CAS/cursor behavior needed to drive the production
/// `SyncEngine` through its real app bridge.
private final class SecureDependencyTransport: SyncTransport, @unchecked Sendable {
    private struct Stored {
        var record: WireRecord
        var sequence: Int
    }

    let identifier = "secure-dependency-memory"
    let supportsPush = true
    let pollInterval: TimeInterval = 30
    let events: AsyncStream<SyncTransportEvent> = AsyncStream { _ in }

    private let lock = NSLock()
    private var storage: [UUID: Stored] = [:]
    private var nextSequence = 1
    private var batches: [[WireRecord]] = []
    private var scopeIdentity: SyncAccountIdentity?
    private var checkpointIssue: SyncScopePreflight.CheckpointIssue?
    private var accountResetCount = 0
    private var checkpointResetCount = 0
    private var localFullResyncResetCount = 0
    private var baseBeforeLocalFullResync: SyncBase?
    private var journalBeforeLocalFullResync: SyncJournal?
    private var vaultRecordIDsBeforeLocalFullResync = Set<UUID>()
    private var recordInjectedBeforeNextSubmit: WireRecord?
    private var rejectionsForNextSubmits: [SyncRejection] = []

    var snapshot: [WireRecord] {
        lock.withLock {
            storage.values.sorted { $0.sequence < $1.sequence }.map(\.record)
        }
    }

    var submittedBatches: [[WireRecord]] {
        lock.withLock { batches }
    }

    var currentCursor: SyncCursor? {
        lock.withLock { cursorLocked() }
    }

    var accountReviewResetAttempts: Int {
        lock.withLock { accountResetCount }
    }

    var checkpointReviewResetAttempts: Int {
        lock.withLock { checkpointResetCount }
    }

    var localFullResyncAttempts: Int {
        lock.withLock { localFullResyncResetCount }
    }

    var beforeLocalFullResyncBase: SyncBase? {
        lock.withLock { baseBeforeLocalFullResync }
    }

    var beforeLocalFullResyncJournal: SyncJournal? {
        lock.withLock { journalBeforeLocalFullResync }
    }

    var vaultRecordIDsAtLocalFullResync: Set<UUID> {
        lock.withLock { vaultRecordIDsBeforeLocalFullResync }
    }

    func configureScope(
        identity: SyncAccountIdentity?,
        checkpointIssue: SyncScopePreflight.CheckpointIssue? = nil
    ) {
        lock.withLock {
            scopeIdentity = identity
            self.checkpointIssue = checkpointIssue
        }
    }

    func injectBeforeNextSubmit(_ record: WireRecord) {
        lock.withLock { recordInjectedBeforeNextSubmit = record }
    }

    func rejectNextSubmit(_ rejection: SyncRejection) {
        lock.withLock { rejectionsForNextSubmits.append(rejection) }
    }

    func seed(_ records: [WireRecord]) {
        lock.withLock {
            for record in records { _ = storeLocked(record) }
        }
    }

    func preflightScope() async throws -> SyncScopePreflight {
        lock.withLock {
            SyncScopePreflight(
                identity: scopeIdentity,
                checkpointIssue: checkpointIssue)
        }
    }

    func resetAfterAccountReview() async throws {
        lock.withLock {
            accountResetCount += 1
            checkpointIssue = nil
        }
    }

    func resetAfterCheckpointReview() async throws {
        lock.withLock {
            checkpointResetCount += 1
            checkpointIssue = nil
        }
    }

    func resetForLocalFullResync() async throws {
        lock.withLock {
            localFullResyncResetCount += 1
            if case .loaded(let base) = SyncBaseFile.load(
                from: SnippetStorageLocations.syncBaseFileURL) {
                baseBeforeLocalFullResync = base
            }
            if case .loaded(let journal) = SyncJournalFile.load(
                from: SnippetStorageLocations.syncJournalFileURL) {
                journalBeforeLocalFullResync = journal
            }
            vaultRecordIDsBeforeLocalFullResync = Set(
                VaultFile.load().value?.records.map(\.id) ?? [])
        }
    }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        lock.withLock {
            let after = cursor.flatMap { Int($0.rawValue) } ?? 0
            let pending = storage.values
                .filter { $0.sequence > after }
                .sorted { $0.sequence < $1.sequence }
            return SyncFetch(
                records: pending.map(\.record),
                cursor: pending.last.map { SyncCursor(String($0.sequence)) } ?? cursor,
                hasMore: false,
                isFullResync: false,
                accountIdentity: scopeIdentity)
        }
    }

    func submit(
        _ records: [WireRecord],
        at cursor: SyncCursor?
    ) async throws -> SyncSubmission {
        lock.withLock {
            batches.append(records)
            if !rejectionsForNextSubmits.isEmpty {
                let rejection = rejectionsForNextSubmits.removeFirst()
                return SyncSubmission(
                    results: records.map {
                        SyncSubmitResult(id: $0.id, outcome: .rejected(rejection))
                    },
                    cursor: cursorLocked(),
                    accountIdentity: scopeIdentity)
            }
            if let injected = recordInjectedBeforeNextSubmit {
                _ = storeLocked(injected)
                recordInjectedBeforeNextSubmit = nil
            }
            var results: [SyncSubmitResult] = []
            for record in records {
                if let existing = storage[record.id],
                   existing.record.recordVersion != record.recordVersion {
                    results.append(SyncSubmitResult(
                        id: record.id,
                        outcome: .rejected(.conflict(remote: existing.record))))
                    continue
                }
                if storage[record.id] == nil, record.recordVersion != nil {
                    results.append(SyncSubmitResult(
                        id: record.id,
                        outcome: .rejected(.conflict(remote: nil))))
                    continue
                }
                let stored = storeLocked(record)
                results.append(SyncSubmitResult(
                    id: record.id,
                    outcome: .accepted(
                        rev: stored.record.rev,
                        recordVersion: try! XCTUnwrap(stored.record.recordVersion))))
            }
            return SyncSubmission(
                results: results,
                cursor: cursorLocked(),
                accountIdentity: scopeIdentity)
        }
    }

    @discardableResult
    private func storeLocked(_ record: WireRecord) -> Stored {
        var versioned = record
        versioned.recordVersion = SyncRecordVersion(
            Data("secure-memory-\(nextSequence)".utf8))
        let stored = Stored(record: versioned, sequence: nextSequence)
        storage[record.id] = stored
        nextSequence += 1
        return stored
    }

    private func cursorLocked() -> SyncCursor? {
        storage.values.map(\.sequence).max().map { SyncCursor(String($0)) }
    }
}
