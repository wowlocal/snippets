import Foundation
import Testing

@testable import SnippetsCore

@MainActor
@Suite("Sync conflict dependencies")
struct SyncConflictDependencyTests {
    private static let sourceID = UUID(
        uuidString: "30000000-0000-4000-8000-000000000001")!
    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"

    private final class Library: SyncLibraryAccess {
        var envelopes: [UUID: SyncEnvelope] = [:]
        var failCurrentEnvelopeCall: Int?
        private(set) var currentEnvelopeCalls = 0

        func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
            currentEnvelopeCalls += 1
            if currentEnvelopeCalls == failCurrentEnvelopeCall {
                throw ConflictDependencyFixtureFailure.injectedPostApplyCrash
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
            var changed: [UUID] = []
            for envelope in incoming {
                if envelope.deleted {
                    if envelopes.removeValue(forKey: envelope.id) != nil {
                        changed.append(envelope.id)
                    }
                } else if envelopes[envelope.id] != envelope {
                    envelopes[envelope.id] = envelope
                    changed.append(envelope.id)
                }
            }
            return ApplyOutcome(changedIDs: changed)
        }

        func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
    }

    private final class CaptureCancellingTransport: SyncTransport, @unchecked Sendable {
        private let inner: InMemoryTransport
        private let lock = NSLock()
        private var capturedStorage: [[WireRecord]] = []

        init(_ inner: InMemoryTransport) { self.inner = inner }

        var identifier: String { inner.identifier }
        var supportsPush: Bool { inner.supportsPush }
        var pollInterval: TimeInterval { inner.pollInterval }
        var events: AsyncStream<SyncTransportEvent> { inner.events }
        var capturedBatches: [[WireRecord]] {
            lock.withLock { capturedStorage }
        }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            try await inner.fetchChanges(since: cursor)
        }

        func submit(
            _ records: [WireRecord],
            at cursor: SyncCursor?
        ) async throws -> SyncSubmission {
            lock.withLock { capturedStorage.append(records) }
            throw CancellationError()
        }
    }

    private struct Harness {
        let backend: InMemoryTransport
        let sealer: SnippetCryptoSealer
        let libraryA: Library
        let libraryB: Library
        let engineA: SyncEngine
        let engineB: SyncEngine
        let directoryA: URL
        let directoryB: URL
    }

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-conflict-dependency-\(label)-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func engine(
        backend: any SyncTransport,
        library: Library,
        sealer: SnippetCryptoSealer,
        device: String,
        directory: URL
    ) -> SyncEngine {
        SyncEngine(
            transport: backend,
            library: library,
            sealer: sealer,
            device: device,
            baseURL: directory.appendingPathComponent("base.json"),
            journalURL: directory.appendingPathComponent("journal.json"),
            stateURL: directory.appendingPathComponent("state.json"),
            lockURL: directory.appendingPathComponent("library.lock"),
            temporaryDirectory: directory)
    }

    private func harness(_ label: String) throws -> Harness {
        let directoryA = try directory("\(label)-a")
        let directoryB = try directory("\(label)-b")
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "conflict-dependency-test")
        let libraryA = Library()
        let libraryB = Library()
        return Harness(
            backend: backend,
            sealer: sealer,
            libraryA: libraryA,
            libraryB: libraryB,
            engineA: engine(
                backend: backend,
                library: libraryA,
                sealer: sealer,
                device: Self.deviceA,
                directory: directoryA),
            engineB: engine(
                backend: backend,
                library: libraryB,
                sealer: sealer,
                device: Self.deviceB,
                directory: directoryB),
            directoryA: directoryA,
            directoryB: directoryB)
    }

    private func cleanUp(_ harness: Harness) {
        try? FileManager.default.removeItem(at: harness.directoryA)
        try? FileManager.default.removeItem(at: harness.directoryB)
    }

    private func envelope(device: String, revision: UInt64, body: String) -> SyncEnvelope {
        envelope(
            id: Self.sourceID,
            device: device,
            revision: revision,
            body: body)
    }

    private func envelope(
        id: UUID,
        device: String,
        revision: UInt64,
        body: String
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Shared snippet",
                keyword: "shared",
                content: Data(body.utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)))
    }

    private func openedBatches(
        after offset: Int,
        in harness: Harness
    ) throws -> [[SyncEnvelope]] {
        try harness.backend.submittedBatches.dropFirst(offset).map { batch in
            try batch.map { try WireCodec.open($0, using: harness.sealer) }
        }
    }

    private func establishConflict(in harness: Harness) async throws -> UUID {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        harness.libraryA.envelopes[Self.sourceID] = ancestor
        _ = await harness.engineA.sync()
        _ = await harness.engineB.sync()

        harness.libraryA.envelopes[Self.sourceID] = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "edit on A")
        harness.libraryB.envelopes[Self.sourceID] = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "edit on B")
        _ = await harness.engineA.sync()
        _ = await harness.engineB.sync()

        return try #require(
            harness.libraryB.envelopes.keys.first { $0 != Self.sourceID })
    }

    @Test func generatedCopyIsAcceptedBeforeItsSourceCanBeSubmitted() async throws {
        let harness = try harness("copy-first")
        defer { cleanUp(harness) }
        let copyID = try await establishConflict(in: harness)
        let batchesBeforeRetry = harness.backend.submittedBatches.count

        _ = await harness.engineB.sync()

        let retryBatches = Array(harness.backend.submittedBatches.dropFirst(batchesBeforeRetry))
        let submittedIDs = retryBatches.flatMap { $0.map(\.id) }
        #expect(submittedIDs == [copyID],
                "the generated copy must be durably accepted before its source is eligible")
        #expect(!submittedIDs.contains(Self.sourceID),
                "the source must remain gated while the copy acknowledgement is unresolved")
    }

    @Test func editingGeneratedCopyBeforeFirstAckDoesNotReplaceFrozenLosingSnapshot()
        async throws
    {
        let harness = try harness("edited-copy-before-ack")
        defer { cleanUp(harness) }
        let copyID = try await establishConflict(in: harness)
        let generated = try #require(harness.libraryB.envelopes[copyID])
        var editedFields = try #require(generated.fields)
        editedFields.name = "User edited generated copy"
        editedFields.content = Data("new body written before first ACK".utf8)
        let edited = SyncEnvelope(
            id: generated.id,
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: false,
            deleted: false,
            fields: editedFields,
            x: generated.x)
        harness.libraryB.envelopes[copyID] = edited
        let beforeCopy = harness.backend.submittedBatches.count

        _ = await harness.engineB.sync()

        let submitted = try #require(
            openedBatches(after: beforeCopy, in: harness).only?.only)
        #expect(submitted.id == copyID)
        #expect(submitted.fields?.content == Data("edit on A".utf8),
                "the first prerequisite offer is the immutable losing snapshot")
        #expect(submitted.fields?.content != edited.fields?.content,
                "a pre-ACK user edit must remain later intent, not redefine preservation")
    }

    @Test func mismatchedLiveOccupantAtDeterministicCopyIDHaltsWithoutCASOverwrite()
        async throws
    {
        let harness = try harness("copy-id-occupant")
        defer { cleanUp(harness) }
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        harness.libraryA.envelopes[Self.sourceID] = ancestor
        _ = await harness.engineA.sync()
        _ = await harness.engineB.sync()

        let editA = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "edit on A")
        let editB = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "edit on B")
        let expected = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: editB,
            remote: editA)
        let generated = try #require(expected.conflictCopies.only)
        let occupant = envelope(
            id: generated.id,
            device: Self.deviceB,
            revision: 250,
            body: "unrelated live occupant")
        #expect(!SyncMerge.isMatchingPlainConflictCopy(occupant, candidate: generated))
        harness.libraryA.envelopes[Self.sourceID] = editA
        _ = await harness.engineA.sync()
        harness.libraryB.envelopes[Self.sourceID] = editB
        harness.libraryB.envelopes[generated.id] = occupant

        let state = await harness.engineB.sync()

        guard case .halted(.localLibraryQuarantined, _) = state else {
            Issue.record("mismatched copy-id provenance must enter the sticky quarantine")
            return
        }
        #expect(harness.libraryB.envelopes[generated.id] == occupant)
        let backend = try Dictionary(
            uniqueKeysWithValues: harness.backend.snapshot.map {
                let envelope = try WireCodec.open($0, using: harness.sealer)
                return (envelope.id, envelope)
            })
        #expect(backend[generated.id] == occupant,
                "the generated copy must never receive the occupant's CAS authority")
        #expect(backend[generated.id]?.fields?.content == Data("unrelated live occupant".utf8))
        #expect(!SyncMerge.isMatchingPlainConflictCopy(
            try #require(backend[generated.id]), candidate: generated))
    }

    @Test func unseenBackendOccupantAtPendingCopyIDQuarantinesBeforeLocalApply()
        async throws
    {
        let directory = try directory("unseen-backend-copy-id-occupant")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "unseen-copy-id-occupant")
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "losing edit preserved as C0")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning source E")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let survivor = try #require(merge.survivor)
        let copyC0 = try #require(merge.conflictCopies.only)
        let occupant = envelope(
            id: copyC0.id,
            device: "ccccccc3",
            revision: 900,
            body: "unrelated backend occupant O")
        #expect(!SyncMerge.isMatchingPlainConflictCopy(occupant, candidate: copyC0))

        // The local base predates O and has no generation for C's deterministic id.
        // C0 is therefore offered as a create and discovers the collision only from the
        // conditional-save result / subsequent change feed.
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let ancestorWire = try #require(backend.snapshot.only)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: ancestorWire.recordVersion)
        try SyncBaseFile.write(
            base,
            to: directory.appendingPathComponent("base.json"),
            temporaryDirectory: directory)
        backend.seed([try WireCodec.seal(occupant, using: sealer)])

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: survivor,
            conflictCopies: [copyC0])
        try SyncJournalFile.write(
            journal,
            to: directory.appendingPathComponent("journal.json"),
            temporaryDirectory: directory)
        let library = Library()
        library.envelopes = [survivor.id: survivor, copyC0.id: copyC0]
        let primaryBefore = library.envelopes
        let syncEngine = engine(
            backend: backend,
            library: library,
            sealer: sealer,
            device: Self.deviceB,
            directory: directory)

        let state = await syncEngine.sync()

        guard case .halted(.localLibraryQuarantined, _) = state else {
            Issue.record("an unrelated backend occupant must enter sticky quarantine")
            return
        }
        #expect(library.envelopes == primaryBefore,
                "O must be rejected before apply can replace or re-merge local C0")
        #expect(syncEngine.agreedBase.envelope(copyC0.id) == nil,
                "an unapplied collision cannot become projection authority")
        let backendByID = try Dictionary(
            uniqueKeysWithValues: backend.snapshot.map { record in
                let opened = try WireCodec.open(record, using: sealer)
                return (opened.id, opened)
            })
        #expect(backendByID[copyC0.id] == occupant,
                "the failed C0 create must leave backend occupant O byte-for-byte intact")
        #expect(backendByID[survivor.id] == ancestor)
        let attemptedCreate = try #require(
            backend.submittedBatches.only?.only)
        #expect(try WireCodec.open(attemptedCreate, using: sealer) == copyC0)
        #expect(attemptedCreate.recordVersion == nil)
        let retained = try loadedJournal(
            from: directory.appendingPathComponent("journal.json"))
        #expect(retained.dependency(survivor.id) != nil)
        #expect(retained.dependency(survivor.id)?
            .requirements.values.first?.snapshot == copyC0)

        let attemptsBeforeStickyRetry = backend.submittedBatches.count
        #expect(await syncEngine.sync() == state)
        #expect(backend.submittedBatches.count == attemptsBeforeStickyRetry,
                "sticky quarantine must not retry C0 against O without review")
    }

    @Test(arguments: [false, true])
    func backendOccupantCannotReplaceCompletedPlainCopyAfterDependencyPrune(
        carriesWrongProvenance: Bool
    ) async throws {
        let directory = try directory(
            carriesWrongProvenance
                ? "completed-copy-wrong-marker-occupant"
                : "completed-copy-unmarked-occupant")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "completed-copy-backend-occupant")
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "completed losing body")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "completed source E")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)

        backend.seed([
            try WireCodec.seal(source, using: sealer),
            try WireCodec.seal(copy, using: sealer),
        ])
        let acceptedByID = Dictionary(
            uniqueKeysWithValues: backend.snapshot.map { ($0.id, $0) })
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            source,
            recordVersion: try #require(acceptedByID[source.id]?.recordVersion))
        base.recordConfirmed(
            copy,
            recordVersion: try #require(acceptedByID[copy.id]?.recordVersion))
        try SyncBaseFile.write(
            base,
            to: directory.appendingPathComponent("base.json"),
            temporaryDirectory: directory)
        try SyncJournalFile.write(
            SyncJournal(),
            to: directory.appendingPathComponent("journal.json"),
            temporaryDirectory: directory)

        var occupant = envelope(
            id: copy.id,
            device: "ccccccc3",
            revision: 900,
            body: "independent backend occupant O")
        if carriesWrongProvenance {
            occupant.x[SyncMerge.plainConflictCopyExtensionKey] =
                SyncMerge.conflictCopyProvenance(
                    sourceID: UUID(
                        uuidString: "39999999-0000-4000-8000-000000000001")!,
                    fingerprint: String(repeating: "f", count: 64))
        }
        #expect(!SyncMerge.isMatchingPlainConflictCopy(occupant, candidate: copy))
        backend.seed([try WireCodec.seal(occupant, using: sealer)])

        let library = Library()
        library.envelopes = [source.id: source, copy.id: copy]
        let primaryBefore = library.envelopes
        let syncEngine = engine(
            backend: backend,
            library: library,
            sealer: sealer,
            device: Self.deviceB,
            directory: directory)
        let cursorBefore = syncEngine.agreedBase.cursor

        let state = await syncEngine.sync()

        guard case .halted(.localLibraryQuarantined, _) = state else {
            Issue.record("incoming occupant at completed copy id returned \(state)")
            return
        }
        #expect(library.envelopes == primaryBefore,
                "O must be rejected before it can replace the completed local copy C")
        #expect(syncEngine.agreedBase.envelope(copy.id) == copy,
                "O cannot become the confirmed copy merely by inheriting local x")
        #expect(syncEngine.agreedBase.cursor == cursorBefore,
                "the occupant change must remain unread until reviewed")
        #expect(backend.submittedBatches.isEmpty,
                "a quiescent completed pair has no outbound write that could mask O")
    }

    @Test(arguments: [false, true])
    func deletedCompletedCopyStillReservesItsIDUntilTombstoneACK(
        carriesWrongProvenance: Bool
    ) async throws {
        let directory = try directory(
            carriesWrongProvenance
                ? "deleted-completed-copy-wrong-marker"
                : "deleted-completed-copy-unmarked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "deleted-completed-copy-backend-occupant")
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "completed losing body deleted locally")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "completed source E")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)

        backend.seed([
            try WireCodec.seal(source, using: sealer),
            try WireCodec.seal(copy, using: sealer),
        ])
        let acceptedByID = Dictionary(
            uniqueKeysWithValues: backend.snapshot.map { ($0.id, $0) })
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(
            source,
            recordVersion: try #require(acceptedByID[source.id]?.recordVersion))
        base.recordConfirmed(
            copy,
            recordVersion: try #require(acceptedByID[copy.id]?.recordVersion))
        try SyncBaseFile.write(
            base,
            to: directory.appendingPathComponent("base.json"),
            temporaryDirectory: directory)

        // The dependency is already completed and pruned. Deleting primary C creates
        // an ordinary tombstone, which intentionally carries no provenance metadata.
        // Until that tombstone is ACKed, the valid confirmed C in base remains the
        // durable reservation for its deterministic id.
        var journal = SyncJournal()
        journal.reconcile(
            current: [source.id: source],
            confirmed: base,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 1))
        let tombstone = try #require(journal.entry(copy.id)?.desired)
        #expect(tombstone.deleted)
        #expect(tombstone.x[SyncMerge.plainConflictCopyExtensionKey] == nil,
                "ordinary tombstones must not retain copy provenance")
        #expect(!SyncMerge.hasValidConflictCopyIdentity(tombstone))
        try SyncJournalFile.write(
            journal,
            to: directory.appendingPathComponent("journal.json"),
            temporaryDirectory: directory)

        var occupant = envelope(
            id: copy.id,
            device: "ccccccc3",
            revision: 900,
            body: "independent live occupant racing C tombstone")
        if carriesWrongProvenance {
            occupant.x[SyncMerge.plainConflictCopyExtensionKey] =
                SyncMerge.conflictCopyProvenance(
                    sourceID: UUID(
                        uuidString: "39999999-0000-4000-8000-000000000001")!,
                    fingerprint: String(repeating: "f", count: 64))
        }
        #expect(!SyncMerge.isMatchingPlainConflictCopy(occupant, candidate: copy))
        backend.seed([try WireCodec.seal(occupant, using: sealer)])

        let library = Library()
        library.envelopes = [source.id: source]
        let primaryBefore = library.envelopes
        let syncEngine = engine(
            backend: backend,
            library: library,
            sealer: sealer,
            device: Self.deviceB,
            directory: directory)
        let cursorBefore = syncEngine.agreedBase.cursor

        let state = await syncEngine.sync()

        guard case .halted(.localLibraryQuarantined, _) = state else {
            Issue.record("incoming occupant racing a copy tombstone returned \(state)")
            return
        }
        #expect(library.envelopes == primaryBefore)
        #expect(library.envelopes[copy.id] == nil,
                "O must be rejected before it can recreate locally deleted C")
        #expect(syncEngine.agreedBase.envelope(copy.id) == copy,
                "the malformed occupant cannot replace the valid reservation in base")
        #expect(syncEngine.agreedBase.cursor == cursorBefore,
                "the occupant generation must remain unread until reviewed")

        let attempted = try #require(backend.submittedBatches.only?.only)
        #expect(try WireCodec.open(attempted, using: sealer) == tombstone,
                "push-first may attempt only the provenance-free local tombstone")
        let backendByID = try Dictionary(
            uniqueKeysWithValues: backend.snapshot.map { record in
                let opened = try WireCodec.open(record, using: sealer)
                return (opened.id, opened)
            })
        #expect(backendByID[copy.id] == occupant,
                "the stale-C tombstone CAS must not delete the newer occupant")
        let retained = try loadedJournal(
            from: directory.appendingPathComponent("journal.json"))
        #expect(retained.entry(copy.id)?.desired == tombstone)

        let attemptsBeforeStickyRetry = backend.submittedBatches.count
        #expect(await syncEngine.sync() == state)
        #expect(backend.submittedBatches.count == attemptsBeforeStickyRetry,
                "sticky quarantine must not retry the tombstone without review")
    }

    @Test func sourceIsSubmittedOnlyAfterCopyAcceptanceWithoutAProtocolCarrier()
        async throws
    {
        let harness = try harness("carrier-free-source")
        defer { cleanUp(harness) }
        let copyID = try await establishConflict(in: harness)
        let beforeCopy = harness.backend.submittedBatches.count

        _ = await harness.engineB.sync()
        let copyRound = try openedBatches(after: beforeCopy, in: harness)
        #expect(copyRound.count == 1)
        #expect(copyRound.first?.map(\.id) == [copyID])

        let beforeSource = harness.backend.submittedBatches.count
        _ = await harness.engineB.sync()
        let sourceRound = try openedBatches(after: beforeSource, in: harness)
        let source = try #require(sourceRound.only?.only)
        #expect(source.id == Self.sourceID)
        #expect(source.x.isEmpty,
                "dependency state belongs to the encrypted journal, not the wire envelope")
        #expect(source.fields?.content == Data("edit on B".utf8))
    }

    @Test func restartAfterPartialAcceptanceStillOffersCopyBeforeSource() async throws {
        let harness = try harness("partial-restart")
        defer { cleanUp(harness) }
        let copyID = try await establishConflict(in: harness)
        let unrelatedID = UUID(
            uuidString: "10000000-0000-4000-8000-000000000001")!
        harness.libraryB.envelopes[unrelatedID] = envelope(
            id: unrelatedID,
            device: Self.deviceB,
            revision: 400,
            body: "independent pending edit")
        harness.backend.configure { $0.acceptAtMostPerBatch = 1 }
        let beforePartial = harness.backend.submittedBatches.count

        _ = await harness.engineB.sync()

        let partial = try #require(
            openedBatches(after: beforePartial, in: harness).only)
        #expect(partial.map(\.id) == [unrelatedID, copyID],
                "partial acceptance may include independent work, but never the gated source")
        #expect(!partial.map(\.id).contains(Self.sourceID))

        harness.backend.configure { $0.acceptAtMostPerBatch = nil }
        let restarted = engine(
            backend: harness.backend,
            library: harness.libraryB,
            sealer: harness.sealer,
            device: Self.deviceB,
            directory: harness.directoryB)
        let beforeRestart = harness.backend.submittedBatches.count

        _ = await restarted.sync()

        let retried = try #require(
            openedBatches(after: beforeRestart, in: harness).only)
        #expect(retried.map(\.id) == [copyID],
                "a restart must recover the durable copy-before-source dependency")

        let beforeSource = harness.backend.submittedBatches.count
        _ = await restarted.sync()
        let source = try #require(
            openedBatches(after: beforeSource, in: harness).only?.only)
        #expect(source.id == Self.sourceID)
        #expect(source.x.isEmpty)
    }

    @Test func deletingSourceAndCopyBeforeCopyAckPreservesCopyThenUploadsTombstones()
        async throws
    {
        let harness = try harness("delete-before-copy-ack")
        defer { cleanUp(harness) }
        let copyID = try await establishConflict(in: harness)
        harness.libraryB.envelopes[Self.sourceID] = nil
        harness.libraryB.envelopes[copyID] = nil
        let beforePreservation = harness.backend.submittedBatches.count

        _ = await harness.engineB.sync()

        let preserved = try #require(
            openedBatches(after: beforePreservation, in: harness).only?.only)
        #expect(preserved.id == copyID,
                "deleting both local rows cannot erase the only unconfirmed losing body")
        #expect(!preserved.deleted)
        #expect(preserved.fields?.content == Data("edit on A".utf8))

        let beforeDeletion = harness.backend.submittedBatches.count
        _ = await harness.engineB.sync()
        let sourceTombstone = try #require(
            openedBatches(after: beforeDeletion, in: harness).only?.only)
        #expect(sourceTombstone.id == Self.sourceID)
        #expect(sourceTombstone.deleted,
                "the source may be deleted only after the losing copy is confirmed")

        let beforeCopyDeletion = harness.backend.submittedBatches.count
        _ = await harness.engineB.sync()
        let copyTombstone = try #require(
            openedBatches(after: beforeCopyDeletion, in: harness).only?.only)
        #expect(copyTombstone.id == copyID)
        #expect(copyTombstone.deleted,
                "the copy tombstone must wait until the source no longer carries the conflict")

        for _ in 0..<3 {
            _ = await harness.engineA.sync()
            _ = await harness.engineB.sync()
        }
        let backend = try Dictionary(
            uniqueKeysWithValues: harness.backend.snapshot.map {
                let envelope = try WireCodec.open($0, using: harness.sealer)
                return (envelope.id, envelope)
            })
        #expect(Set(backend.keys) == [Self.sourceID, copyID])
        #expect(backend.values.allSatisfy { $0.deleted })
        #expect(harness.libraryA.envelopes.isEmpty)
        #expect(harness.libraryB.envelopes.isEmpty,
                "redelivery after both tombstones must not resurrect source or copy")
    }

    @Test func directReconcileTreatsExactAndNewerCopyRecreationAsUserIntent()
        throws
    {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "frozen losing copy C0")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning source")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(merge.survivor)
        let frozenC0 = try #require(merge.conflictCopies.only)
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            ancestor,
            recordVersion: SyncRecordVersion(Data("ancestor-generation".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: source,
            conflictCopies: [frozenC0])
        journal.reconcile(
            current: [source.id: source, frozenC0.id: frozenC0],
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 1))

        // The user deletes C while the dependency still owns immutable C0. The
        // ordinary desired tombstone is later intent and carries no provenance.
        journal.reconcile(
            current: [source.id: source],
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 2))
        let deleteIntent = try #require(journal.entry(frozenC0.id)?.desired)
        #expect(deleteIntent.deleted)
        #expect(deleteIntent.x[SyncMerge.plainConflictCopyExtensionKey] == nil)

        // Pure journal reconciliation has no mutation provenance: exact C0 could be a
        // token/global Undo just as easily as a protocol materializer. It must therefore
        // treat the live primary as intentional recreation. The engine/bridge's atomic
        // protected-tombstone path is responsible for keeping a protocol-owned replay
        // from being exposed to this ambiguous generic boundary.
        journal.reconcile(
            current: [source.id: source, frozenC0.id: frozenC0],
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 3))
        let restoredC0 = try #require(journal.entry(frozenC0.id)?.desired)
        #expect(!restoredC0.deleted)
        #expect(restoredC0.fields == frozenC0.fields)
        #expect(restoredC0.x == frozenC0.x)
        #expect(restoredC0.hlc > deleteIntent.hlc)
        #expect(journal.dependency(source.id)?
            .requirements.values.first?.snapshot == frozenC0)

        // A non-exact live C1 with the same deterministic provenance is a genuine
        // edit/recreation. It supersedes the earlier delete instead of being mistaken
        // for another protocol echo of immutable C0.
        var recreatedFields = try #require(frozenC0.fields)
        recreatedFields.name = "User recreated C1"
        recreatedFields.content = Data("newer recreated copy body".utf8)
        let recreatedC1 = SyncEnvelope(
            id: frozenC0.id,
            hlc: HLC(wallMs: 4_000, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: false,
            deleted: false,
            fields: recreatedFields,
            x: frozenC0.x)
        journal.reconcile(
            current: [source.id: source, recreatedC1.id: recreatedC1],
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 4))

        let latest = try #require(journal.entry(recreatedC1.id)?.desired)
        #expect(latest == recreatedC1)
        #expect(!latest.deleted)
        #expect(latest.fields?.content == Data("newer recreated copy body".utf8))
        #expect(SyncMerge.isMatchingPlainConflictCopy(
            latest, candidate: frozenC0))
        #expect(journal.dependency(source.id)?
            .requirements.values.first?.snapshot == frozenC0,
                "ordinary C1 intent cannot rewrite the immutable prerequisite")
    }

    @Test func transportRekeyDuringDependencyDoesNotReplayGenericOffersAfterPrune()
        throws
    {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "losing edit")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning edit")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let survivor = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            ancestor,
            recordVersion: SyncRecordVersion(Data("source-before-rekey".utf8)))
        confirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("copy-before-rekey".utf8)))

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: survivor,
            conflictCopies: [copy])
        let current = [survivor.id: survivor, copy.id: copy]
        try journal.reconcileDependencies(current: current, confirmed: confirmed)
        journal.reconcile(
            current: current,
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 1))

        // Rekey staging must not create a second, ordinary owner for IDs already
        // fenced by the durable copy-before-source dependency. Otherwise the generic
        // pre-conflict source offer can become visible again after the edge is pruned.
        journal.stageConfirmedForTransportRekey(
            confirmed,
            now: Date(timeIntervalSince1970: 2))
        var resetBase = SyncBase(recordVersions: confirmed.recordVersions)

        let copyOffer = try #require(journal.pending(confirmed: resetBase).only)
        #expect(copyOffer == copy)
        journal.markOffered([copyOffer], confirmed: resetBase)
        resetBase.recordConfirmed(
            copyOffer,
            recordVersion: SyncRecordVersion(Data("copy-after-rekey".utf8)))
        journal.acknowledge([copy.id], confirmed: resetBase)

        let sourceOffer = try #require(journal.pending(confirmed: resetBase).only)
        #expect(sourceOffer == survivor)
        journal.markOffered([sourceOffer], confirmed: resetBase)
        resetBase.recordConfirmed(
            sourceOffer,
            recordVersion: SyncRecordVersion(Data("source-after-rekey".utf8)))
        journal.acknowledge([survivor.id], confirmed: resetBase)
        #expect(journal.dependency(survivor.id) != nil,
                "an ACK alone cannot prune before primary storage is reread")
        try journal.reconcileDependencies(
            current: current,
            confirmed: resetBase,
            acceptedSourceIDs: [survivor.id])

        #expect(journal.dependency(survivor.id) == nil)
        #expect(journal.entry(copy.id) == nil,
                "the dependency ACK must consume any redundant generic copy offer")
        #expect(journal.entry(survivor.id) == nil,
                "the dependency ACK must consume the redundant generic source intent")
        #expect(journal.pending(confirmed: resetBase).isEmpty,
                "pruning the dependency must not replay stale pre-rekey source/copy bytes")
        journal.reconcile(
            current: current,
            confirmed: resetBase,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 3))
        #expect(journal.entry(survivor.id) == nil,
                "the next ordinary reconcile should remove the redundant desired entry")
    }

    @Test func transportRekeyRetiresPreexistingGenericOffersOwnedByDependency()
        throws
    {
        let directory = try directory("rekey-preexisting-generic-offers")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "losing edit")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning edit")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let sourceS0 = try #require(merge.survivor)
        let copyC0 = try #require(merge.conflictCopies.only)
        var latestSourceFields = try #require(sourceS0.fields)
        latestSourceFields.name = "latest source E"
        latestSourceFields.content = Data("latest source body E".utf8)
        let latestSourceE = SyncEnvelope(
            id: sourceS0.id,
            hlc: HLC(wallMs: 500, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: false,
            deleted: false,
            fields: latestSourceFields,
            x: sourceS0.x)
        var latestCopyFields = try #require(copyC0.fields)
        latestCopyFields.name = "latest copy C1"
        latestCopyFields.content = Data("latest copy body C1".utf8)
        let latestCopyC1 = SyncEnvelope(
            id: copyC0.id,
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceA),
            origin: Self.deviceA,
            secure: false,
            deleted: false,
            fields: latestCopyFields,
            x: copyC0.x)
        #expect(latestSourceE != sourceS0)
        #expect(latestCopyC1 != copyC0)

        // These generic offers predate dependency ownership. S0 is stale, while C0 is
        // the immutable preservation generation. C1 remains later held intent: a new
        // wire-key epoch must re-earn C0 → E ordering before it can publish C1.
        var journal = SyncJournal(entries: [
            SyncBase.key(sourceS0.id): SyncJournal.Entry(
                desired: latestSourceE,
                offered: SyncJournal.Offered(
                    envelope: sourceS0,
                    generation: 1,
                    recordVersion: SyncRecordVersion(Data("source-S0-CAS".utf8))),
                generation: 2,
                modifiedAt: Date(timeIntervalSince1970: 1)),
            SyncBase.key(copyC0.id): SyncJournal.Entry(
                desired: latestCopyC1,
                offered: SyncJournal.Offered(
                    envelope: copyC0,
                    generation: 1,
                    recordVersion: SyncRecordVersion(Data("copy-C0-CAS".utf8))),
                generation: 2,
                modifiedAt: Date(timeIntervalSince1970: 1)),
        ])
        try journal.stageConflictDependency(
            source: latestSourceE,
            conflictCopies: [copyC0])
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            sourceS0,
            recordVersion: SyncRecordVersion(Data("source-S0-CAS".utf8)))
        confirmed.recordConfirmed(
            latestCopyC1,
            recordVersion: SyncRecordVersion(Data("copy-C1-CAS".utf8)))
        #expect(journal.entry(sourceS0.id)?.offered?.envelope == sourceS0)
        #expect(journal.entry(copyC0.id)?.offered?.envelope == copyC0)

        journal.stageConfirmedForTransportRekey(
            confirmed,
            now: Date(timeIntervalSince1970: 2))
        try SyncJournalFile.write(
            journal,
            to: journalURL,
            temporaryDirectory: directory)
        journal = try loadedJournal(from: journalURL)

        #expect(journal.entry(sourceS0.id)?.offered == nil,
                "dependency ownership must retire the stale generic S0 offer at rekey")
        #expect(journal.entry(copyC0.id)?.offered == nil,
                "dependency ownership must retire the stale generic C0 offer at rekey")
        let preserved = try #require(
            journal.dependency(sourceS0.id)?
                .requirements.values.first?.snapshot)
        #expect(preserved == copyC0,
                "rekey may not replace immutable C0 with the confirmed later C1")
        #expect(journal.entry(copyC0.id)?.desired == latestCopyC1,
                "the later copy generation remains held ordinary intent")

        var resetBase = SyncBase(recordVersions: confirmed.recordVersions)
        let copyOffer = try #require(journal.pending(confirmed: resetBase).only)
        #expect(copyOffer == copyC0)
        #expect(copyOffer != latestCopyC1)
        journal.markOffered([copyOffer], confirmed: resetBase)
        resetBase.recordConfirmed(
            copyOffer,
            recordVersion: SyncRecordVersion(Data("copy-C0-after-rekey".utf8)))
        journal.acknowledge([copyOffer.id], confirmed: resetBase)

        let sourceOffer = try #require(journal.pending(confirmed: resetBase).only)
        #expect(sourceOffer == latestSourceE)
        #expect(sourceOffer != sourceS0)
        journal.markOffered([sourceOffer], confirmed: resetBase)
        resetBase.recordConfirmed(
            sourceOffer,
            recordVersion: SyncRecordVersion(Data("source-E-after-rekey".utf8)))
        journal.acknowledge([sourceOffer.id], confirmed: resetBase)
        #expect(journal.dependency(sourceS0.id) != nil,
                "the source receipt remains fenced until current primary is reread")
        try journal.reconcileDependencies(
            current: [latestSourceE.id: latestSourceE, latestCopyC1.id: latestCopyC1],
            confirmed: resetBase,
            acceptedSourceIDs: [sourceOffer.id])

        #expect(journal.dependency(sourceS0.id) == nil)
        #expect(journal.pending(confirmed: resetBase) == [latestCopyC1],
                "C1 is released only after replacement-epoch C0 and E receipts")
        journal.markOffered([latestCopyC1], confirmed: resetBase)
        resetBase.recordConfirmed(
            latestCopyC1,
            recordVersion: SyncRecordVersion(Data("copy-C1-after-source".utf8)))
        journal.acknowledge([latestCopyC1.id], confirmed: resetBase)
        #expect(journal.pending(confirmed: resetBase).isEmpty)
        #expect(journal.entry(sourceS0.id)?.offered == nil)
        #expect(journal.entry(copyC0.id) == nil)
    }

    @Test func legacyV1JournalMigratesToV3WithAnEmptyDependencyMap() throws {
        let directory = try directory("journal-v1")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        try Data("{\"schemaVersion\":1,\"entries\":{}}".utf8).write(to: journalURL)

        let migrated: SyncJournal
        guard case .loaded(let loaded) = SyncJournalFile.load(from: journalURL) else {
            Issue.record("a valid version-1 journal must remain readable during migration")
            return
        }
        var reconciled = loaded
        try reconciled.reconcileDependencies(current: [:], confirmed: SyncBase())
        migrated = reconciled
        try SyncJournalFile.write(migrated, to: journalURL, temporaryDirectory: directory)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any])
        #expect(object["schemaVersion"] as? Int == SyncJournal.currentSchemaVersion)
        #expect((object["conflictDependencies"] as? [String: Any])?.isEmpty == true,
                "legacy intent migrates without inventing dependencies")
    }

    @Test func legacyMigrationDoesNotDiscoverSecureCarrierWithoutMaterializationCapability()
        throws
    {
        let directory = try directory("legacy-no-secure-materialization")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        try legacyV1JournalData(entries: []).write(to: journalURL)
        var journal = try loadedJournal(from: journalURL)
        let scenario = try SecureConflictVariantFixture.makeScenario()

        try journal.reconcileDependencies(
            current: [scenario.survivor.id: scenario.survivor],
            confirmed: SyncBase(),
            discoverSecureCarriers: false)

        #expect(journal.dependency(scenario.survivor.id) == nil,
                "value-only migration must not invent a secure prerequisite")
        #expect(journal.conflictDependencies.isEmpty)
        try SyncJournalFile.write(
            journal,
            to: journalURL,
            temporaryDirectory: directory)
        #expect(try loadedJournal(from: journalURL).conflictDependencies.isEmpty)
    }

    @Test func meaningfulLegacyV1CannotBeRewrittenDirectlyOrByMaintenanceBeforeReconcile() throws {
        let directory = try directory("journal-v1-meaningful")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "losing edit")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning edit")
        let outcome = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(outcome.survivor)
        let copy = try #require(outcome.conflictCopies.only)
        let legacy = try legacyV1JournalData(entries: [source, copy])
        let current = [source.id: source, copy.id: copy]

        let directURL = directory.appendingPathComponent("direct.json")
        try legacy.write(to: directURL)
        let direct = try loadedJournal(from: directURL)
        do {
            try SyncJournalFile.write(
                direct, to: directURL, temporaryDirectory: directory)
            Issue.record("a meaningful v1 journal was rewritten before dependency reconcile")
        } catch {}
        #expect(try Data(contentsOf: directURL) == legacy,
                "the direct writer must leave meaningful v1 evidence byte-for-byte intact")

        let maintenanceURL = directory.appendingPathComponent("maintenance.json")
        try legacy.write(to: maintenanceURL)
        var maintenance = try loadedJournal(from: maintenanceURL)
        try maintenance.prepareForAccountChange(
            current: current,
            confirmed: SyncBase(),
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 10))
        #expect(maintenance.dependency(source.id) != nil,
                "maintenance must reconcile the real source-to-copy edge before upgrade")
        try SyncJournalFile.write(
            maintenance, to: maintenanceURL, temporaryDirectory: directory)
        let maintained = try loadedJournal(from: maintenanceURL)
        #expect(maintained.schemaVersion == SyncJournal.currentSchemaVersion)
        #expect(maintained.dependency(source.id) != nil,
                "maintenance may publish v2 only with the reconstructed edge intact")

        let reconciledURL = directory.appendingPathComponent("reconciled.json")
        try legacy.write(to: reconciledURL)
        var reconciled = try loadedJournal(from: reconciledURL)
        try reconciled.reconcileDependencies(
            current: current,
            confirmed: SyncBase())
        try SyncJournalFile.write(
            reconciled, to: reconciledURL, temporaryDirectory: directory)
        let upgraded = try loadedJournal(from: reconciledURL)
        #expect(upgraded.schemaVersion == SyncJournal.currentSchemaVersion)
        #expect(upgraded.dependency(source.id) != nil,
                "reconcile must recover the real source-to-copy edge before v2 publication")
    }

    @Test func migratedV1ConfirmedSourceTombstoneIsReofferedAfterCopyACKBeforePrune()
        throws
    {
        let directory = try directory("journal-v1-confirmed-source-tombstone")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "losing edit")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning edit")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let survivor = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        let sourceTombstone = survivor.tombstoned(
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let sourceGeneration = SyncRecordVersion(Data("source-before-copy".utf8))
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            sourceTombstone,
            recordVersion: sourceGeneration)

        // Schema 1 could acknowledge and clear the source tombstone before its
        // independent conflict copy. Migration must reconstruct the missing ordering
        // proof from the copy provenance and the confirmed source tombstone.
        let journalURL = directory.appendingPathComponent("journal.json")
        try legacyV1JournalData(entries: [copy]).write(to: journalURL)
        var journal = try loadedJournal(from: journalURL)
        try journal.reconcileDependencies(
            current: [copy.id: copy],
            confirmed: confirmed)
        journal.reconcile(
            current: [copy.id: copy],
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 10))
        #expect(journal.dependency(Self.sourceID) != nil)

        let copyOffer = try #require(journal.pending(confirmed: confirmed).only)
        #expect(copyOffer.id == copy.id)
        journal.markOffered([copyOffer], confirmed: confirmed)
        confirmed.recordConfirmed(
            copyOffer,
            recordVersion: SyncRecordVersion(Data("copy-accepted".utf8)))
        journal.acknowledge([copy.id], confirmed: confirmed)

        let postCopySource = try #require(
            journal.pending(confirmed: confirmed).only,
            "the already-confirmed tombstone must be CAS-written again after the copy ACK")
        #expect(postCopySource.id == Self.sourceID)
        #expect(postCopySource.deleted)
        #expect(postCopySource == sourceTombstone)
        journal.markOffered([postCopySource], confirmed: confirmed)
        let release = try #require(
            journal.dependency(Self.sourceID)?.sourceOffered)
        #expect(release.recordVersion == sourceGeneration,
                "the duplicate tombstone must use the pre-copy source generation as CAS")

        confirmed.recordConfirmed(
            postCopySource,
            recordVersion: SyncRecordVersion(Data("source-after-copy".utf8)))
        journal.acknowledge([Self.sourceID], confirmed: confirmed)
        #expect(journal.dependency(Self.sourceID) != nil,
                "the migrated source receipt must await a primary reread")
        try journal.reconcileDependencies(
            current: [copy.id: copy],
            confirmed: confirmed,
            acceptedSourceIDs: [Self.sourceID])
        #expect(journal.dependency(Self.sourceID) == nil,
                "only the post-copy source ACK may retire the migrated dependency")
    }

    @Test func migratedV1OlderOfferAndCurrentTwoCarrierSourcePersistStrictUnionSnapshot()
        throws
    {
        let directory = try directory("journal-v1-carrier-union")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let scenario = try SecureConflictVariantFixture.makeScenario()

        let secondPlaintext = Data("second losing secure revision".utf8)
        let secondSeal = try SnippetCrypto.seal(
            secondPlaintext,
            for: SnippetCrypto.RecordContext(
                scopeID: SecureConflictVariantFixture.vaultKID,
                recordID: scenario.losingSource.id),
            keyring: scenario.keyring)
        var secondFields = try #require(scenario.losingSource.fields)
        secondFields.content = Data(secondSeal.utf8)
        secondFields.updatedAt = Date(timeIntervalSince1970: 0.25)
        var secondExtensions = scenario.losingSource.x
        secondExtensions[SyncEnvelope.vaultContentHashExtensionKey] = .string(
            SnippetCrypto.contentHash(of: secondPlaintext, keyring: scenario.keyring))
        let secondLosingSource = SyncEnvelope(
            id: scenario.losingSource.id,
            hlc: HLC(wallMs: 250, counter: 0, device: "ccccccc3"),
            origin: "ccccccc3",
            secure: true,
            deleted: false,
            fields: secondFields,
            x: secondExtensions)
        let secondMerge = try SyncMerge.mergeEnvelopeOutcome(
            base: scenario.ancestor,
            local: secondLosingSource,
            remote: scenario.winningSource)
        let secondCarrierSource = try #require(secondMerge.survivor)
        let secondVariant = try #require(
            SyncMerge.secureContentConflictVariants(in: secondCarrierSource).only)
        #expect(secondVariant.fingerprint != scenario.variant.fingerprint)

        var unionSource = scenario.survivor
        unionSource.x[secondVariant.extensionKey] =
            secondCarrierSource.x[secondVariant.extensionKey]
        let unionVariants = try SyncMerge.secureContentConflictVariants(in: unionSource)
        #expect(Set(unionVariants.map(\.fingerprint)) == [
            scenario.variant.fingerprint,
            secondVariant.fingerprint,
        ])

        // The old ambiguous offer knew only R1 while primary storage and desired intent
        // now contain R1+R2. A v1 migration must union evidence without letting the last
        // (older) candidate replace the dependency's source snapshot.
        try legacyV1JournalData(
            desired: unionSource,
            offered: scenario.survivor)
            .write(to: journalURL)
        var journal = try loadedJournal(from: journalURL)
        var confirmed = SyncBase()
        confirmed.record(scenario.ancestor)
        try journal.reconcileDependencies(
            current: [unionSource.id: unionSource],
            confirmed: confirmed)
        try SyncJournalFile.write(
            journal, to: journalURL, temporaryDirectory: directory)

        guard case .loaded(let persisted) = SyncJournalFile.load(from: journalURL) else {
            Issue.record(
                "the migrated R1+R2 dependency must pass the strict v2 decoder after restart")
            return
        }
        let dependency = try #require(persisted.dependency(unionSource.id))
        #expect(Set(dependency.requirements.keys) == [
            scenario.variant.fingerprint,
            secondVariant.fingerprint,
        ])
        #expect(dependency.sourceSnapshot.x[scenario.variant.extensionKey]
                == scenario.survivor.x[scenario.variant.extensionKey])
        #expect(dependency.sourceSnapshot.x[secondVariant.extensionKey]
                == secondCarrierSource.x[secondVariant.extensionKey])
    }

    @Test func malformedV2DependencyGraphFailsClosed() throws {
        let directory = try directory("journal-v2-malformed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let malformed = Data(
            "{\"schemaVersion\":2,\"entries\":{},\"conflictDependencies\":[]}".utf8)
        try malformed.write(to: journalURL)

        guard case .unreadable = SyncJournalFile.load(from: journalURL) else {
            Issue.record("a malformed version-2 dependency graph must halt, not load empty")
            return
        }
        #expect(try Data(contentsOf: journalURL) == malformed,
                "fail-closed loading must preserve the only durable evidence")
    }

    @Test func preparedSecureC0EvidenceRejectsAuthenticatedLaterOrMutatedCopies()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        var exactC0 = try materializedConflictCopy(for: scenario)
        // The generic projection helper chooses its caller device as origin; prepared
        // evidence instead preserves the losing variant's exact source origin.
        exactC0.hlc = scenario.variant.sourceHLC
        exactC0.origin = scenario.variant.sourceOrigin
        let exactFields = try #require(exactC0.fields)

        var laterHLC = exactC0
        laterHLC.hlc = HLC(
            wallMs: exactC0.hlc.wallMs + 1,
            counter: 0,
            device: Self.deviceB)

        var laterOrigin = exactC0
        laterOrigin.origin = Self.deviceB

        var editedMetadataFields = exactFields
        editedMetadataFields.name = "legitimate later copy edit"
        editedMetadataFields.tags = ["later-tag"]
        let editedMetadata = SyncEnvelope(
            id: exactC0.id,
            hlc: exactC0.hlc,
            origin: exactC0.origin,
            secure: exactC0.secure,
            deleted: false,
            fields: editedMetadataFields,
            x: exactC0.x)

        let laterPlaintext = Data("legitimate later secure C1".utf8)
        let laterSeal = try SnippetCrypto.seal(
            laterPlaintext,
            for: SnippetCrypto.RecordContext(
                scopeID: SecureConflictVariantFixture.vaultKID,
                recordID: scenario.variant.copyID),
            keyring: scenario.keyring)
        var editedBodyFields = exactFields
        editedBodyFields.content = Data(laterSeal.utf8)
        var editedBodyExtensions = exactC0.x
        editedBodyExtensions[SyncEnvelope.vaultContentHashExtensionKey] = .string(
            SnippetCrypto.contentHash(
                of: laterPlaintext,
                keyring: scenario.keyring))
        let editedBody = SyncEnvelope(
            id: exactC0.id,
            hlc: exactC0.hlc,
            origin: exactC0.origin,
            secure: exactC0.secure,
            deleted: false,
            fields: editedBodyFields,
            x: editedBodyExtensions)

        for (label, candidate) in [
            ("later HLC", laterHLC),
            ("later origin", laterOrigin),
            ("edited derived metadata", editedMetadata),
            ("edited authenticated body and hash", editedBody),
        ] {
            _ = try SyncSecureConflictMaterializer.validateIncomingSecureCopy(
                candidate,
                keyring: scenario.keyring,
                vaultKID: SecureConflictVariantFixture.vaultKID)
            #expect(throws: SyncSecureConflictMaterializer.Failure.self,
                    "\(label) is a valid secure C1, not prepared C0 evidence") {
                try SyncSecureConflictMaterializer.validatePreparedEvidence(
                    candidate,
                    for: scenario.variant,
                    keyring: scenario.keyring,
                    vaultKID: SecureConflictVariantFixture.vaultKID)
            }
        }

        try SyncSecureConflictMaterializer.validatePreparedEvidence(
            exactC0,
            for: scenario.variant,
            keyring: scenario.keyring,
            vaultKID: SecureConflictVariantFixture.vaultKID)
    }

    @Test func localC0InstallReceiptRoundTripsAndSurvivesPrimaryRecordDeletion()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let c0 = try materializedConflictCopy(for: scenario)
        let expectedHash = try c0.envelopeHash()
        var vault = receiptVault(
            x: ["safeFuture": .string("preserve")],
            records: [try #require(try SyncLibraryProjection.vaultRecord(from: c0))])

        try vault.recordLocalConflictInstallReceipts(for: [c0])
        let installedBytes = try VaultFile.encode(vault)
        let installed = try VaultFile.decode(installedBytes)
        #expect(installed.localConflictInstallReceipts == [c0.id: expectedHash])
        #expect(installed.x["safeFuture"] == .string("preserve"))

        var deleted = installed
        deleted.records.removeAll { $0.id == c0.id }
        let deletedReload = try VaultFile.decode(VaultFile.encode(deleted))
        #expect(deletedReload.record(c0.id) == nil)
        #expect(deletedReload.localConflictInstallReceipts == [c0.id: expectedHash],
                "secure deletion must preserve the device-local install fact")
        #expect(deletedReload.x["safeFuture"] == .string("preserve"))
    }

    @Test func localC0InstallReceiptIsBoundToExactFrozenEnvelopeNotOnlyLineage()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let firstC0 = try materializedConflictCopy(for: scenario)
        let nextEpochC0 = try materializedConflictCopy(for: scenario)
        #expect(firstC0.id == nextEpochC0.id)
        let firstProvenance = try #require(
            SyncMerge.conflictCopyProvenance(in: firstC0))
        let nextProvenance = try #require(
            SyncMerge.conflictCopyProvenance(in: nextEpochC0))
        #expect(firstProvenance.sourceID == nextProvenance.sourceID)
        #expect(firstProvenance.fingerprint == nextProvenance.fingerprint)
        #expect(try firstC0.envelopeHash() != nextEpochC0.envelopeHash(),
                "fresh AEAD nonces make the exact C0 snapshots distinct")

        var vault = receiptVault()
        try vault.recordLocalConflictInstallReceipts(for: [firstC0])
        let receipts = try #require(vault.localConflictInstallReceipts)
        let firstHash = try firstC0.envelopeHash()
        let nextHash = try nextEpochC0.envelopeHash()
        #expect(receipts[firstC0.id] == firstHash)
        #expect(receipts[nextEpochC0.id] != nextHash,
                "a stale same-source/fingerprint receipt cannot suppress new C0 recovery")

        try vault.recordLocalConflictInstallReceipts(for: [nextEpochC0])
        #expect(vault.localConflictInstallReceipts == [nextEpochC0.id: nextHash],
                "a newer exact C0 for the same deterministic id replaces the old epoch hash")
    }

    @Test func localC0InstallReceiptsAccumulateBeyondOneEnvelopesVariantLimit()
        throws
    {
        var evidence: [SyncEnvelope] = []
        evidence.reserveCapacity(SyncMerge.maximumContentConflictVariantCount + 1)
        for _ in 0...SyncMerge.maximumContentConflictVariantCount {
            evidence.append(try materializedConflictCopy(
                for: SecureConflictVariantFixture.makeScenario()))
        }
        let receipts = try Dictionary(
            uniqueKeysWithValues: evidence.map { ($0.id, try $0.envelopeHash()) })
        #expect(receipts.count == evidence.count,
                "each independently valid C0 must have a distinct deterministic id")

        var vault = receiptVault()
        try vault.recordLocalConflictInstallReceipts(for: evidence)

        #expect(vault.localConflictInstallReceipts == receipts,
                "the per-envelope carrier fanout limit is not a lifetime receipt cap")
        let reloaded = try VaultFile.decode(VaultFile.encode(vault))
        #expect(reloaded.localConflictInstallReceipts == receipts)
    }

    @Test func installedReceiptAbsenceTombstoneAdvancesPastFarFutureConfirmedC1()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let c0 = try materializedConflictCopy(for: scenario)
        var confirmedC1 = c0
        confirmedC1.hlc = HLC(
            wallMs: 9_000_000_000_000,
            counter: 17,
            device: Self.deviceB)
        confirmedC1.origin = Self.deviceB
        var c1Fields = try #require(confirmedC1.fields)
        c1Fields.name = "far-future confirmed C1"
        c1Fields.updatedAt = Date(timeIntervalSince1970: 9_000_000_000)
        confirmedC1 = SyncEnvelope(
            id: confirmedC1.id,
            hlc: confirmedC1.hlc,
            origin: confirmedC1.origin,
            secure: confirmedC1.secure,
            deleted: false,
            fields: c1Fields,
            x: confirmedC1.x)
        #expect(SyncMerge.matchesConflictCopyProvenance(
            confirmedC1,
            sourceID: scenario.survivor.id,
            fingerprint: scenario.variant.fingerprint))

        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            confirmedC1,
            recordVersion: SyncRecordVersion(Data("far-future-c1".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([c0])
        #expect(journal.entry(c0.id) == nil)

        try journal.reconcileInstalledConflictPrerequisiteAbsence(
            current: [:],
            installedHashes: [c0.id: try c0.envelopeHash()],
            confirmed: confirmed,
            deviceID: Self.deviceA,
            now: Date(timeIntervalSince1970: 1))

        let tombstone = try #require(journal.entry(c0.id)?.desired)
        #expect(tombstone.deleted)
        #expect(tombstone.hlc > confirmedC1.hlc,
                "receipt-derived deletion must be causally newer than remote knowledge")
        #expect(tombstone.origin == Self.deviceA)
        #expect(tombstone.secure)
        #expect(tombstone.id == c0.id)
        #expect(tombstone.fields == nil)
        #expect(tombstone.x[SyncEnvelope.vaultKeyIDExtensionKey]
                == c0.x[SyncEnvelope.vaultKeyIDExtensionKey])
        #expect(tombstone.x[SyncMerge.plainConflictCopyExtensionKey] == nil,
                "privacy-preserving tombstones do not retain conflict provenance")
        #expect(tombstone.x.count == 1,
                "the stabilized tombstone retains only vault scope")
    }

    @Test func installedReceiptAbsenceTombstoneAdvancesPastFarFutureConfirmedTombstone()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let c0 = try materializedConflictCopy(for: scenario)
        let confirmedT = c0.tombstoned(
            hlc: HLC(
                wallMs: 9_000_000_000_001,
                counter: 23,
                device: Self.deviceB),
            origin: Self.deviceB)

        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            confirmedT,
            recordVersion: SyncRecordVersion(Data("far-future-t".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([c0])

        try journal.reconcileInstalledConflictPrerequisiteAbsence(
            current: [:],
            installedHashes: [c0.id: try c0.envelopeHash()],
            confirmed: confirmed,
            deviceID: Self.deviceA,
            now: Date(timeIntervalSince1970: 1))

        let stabilized = try #require(journal.entry(c0.id)?.desired)
        #expect(stabilized.deleted)
        #expect(stabilized.hlc > confirmedT.hlc,
                "a stale receipt cannot mint a tombstone behind remote deletion knowledge")
        #expect(stabilized.id == c0.id)
        #expect(stabilized.origin == Self.deviceA)
        #expect(stabilized.secure)
        #expect(stabilized.fields == nil)
        #expect(stabilized.x[SyncEnvelope.vaultKeyIDExtensionKey]
                == c0.x[SyncEnvelope.vaultKeyIDExtensionKey])
        #expect(stabilized.x[SyncMerge.plainConflictCopyExtensionKey] == nil)
        #expect(stabilized.x.count == 1)
    }

    @Test func malformedLocalC0InstallReceiptFailsClosedAndCannotBeExtended()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let c0 = try materializedConflictCopy(for: scenario)
        let validID = c0.id.uuidString.lowercased()
        let malformedValues: [JSONValue] = [
            .array([.bool(true)]),
            .object([String(repeating: "A", count: 64): .string(validID)]),
            .object([String(repeating: "a", count: 64): .bool(false)]),
            .object(["too-short": .string(validID)]),
            .object([
                String(repeating: "a", count: 64):
                    .string(c0.id.uuidString.uppercased()),
            ]),
        ]

        for malformed in malformedValues {
            var vault = receiptVault(x: [
                VaultDocument.localConflictInstallReceiptsKey: malformed,
            ])
            #expect(vault.localConflictInstallReceipts == nil)
            #expect(throws: SyncMerge.EnvelopeFailure.self) {
                try vault.recordLocalConflictInstallReceipts(for: [c0])
            }
            #expect(vault.x[VaultDocument.localConflictInstallReceiptsKey] == malformed,
                    "fail-closed validation must not rewrite unknown or malformed bytes")
        }

        var futureVersion = receiptVault()
        try futureVersion.recordLocalConflictInstallReceipts(for: [c0])
        let validV1 = futureVersion.x[VaultDocument.localConflictInstallReceiptsKey]
        let futureKey = VaultDocument.localConflictInstallReceiptsPrefix + "v2"
        futureVersion.x[futureKey] = .object(["opaque": .string("future-shape")])
        #expect(futureVersion.localConflictInstallReceipts == nil,
                "an unknown reserved receipt version makes the whole local history unreadable")
        #expect(throws: SyncMerge.EnvelopeFailure.self) {
            try futureVersion.recordLocalConflictInstallReceipts(for: [c0])
        }
        #expect(futureVersion.x[VaultDocument.localConflictInstallReceiptsKey] == validV1)
        #expect(futureVersion.x[futureKey]
                == .object(["opaque": .string("future-shape")]),
                "fail-closed validation cannot rewrite a future receipt version")
    }

    @Test func sharedVaultIdentityMergeNeverTransportsLocalC0InstallReceipts()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let existingC0 = try materializedConflictCopy(for: scenario)
        let candidateC0 = try materializedConflictCopy(for: scenario)
        let futureReceiptKey = VaultDocument.localConflictInstallReceiptsPrefix + "v2"
        var existing = receiptVault(x: ["existingFuture": .string("left")])
        try existing.recordLocalConflictInstallReceipts(for: [existingC0])
        existing.x[futureReceiptKey] = .object(["opaque": .string("existing-device")])
        #expect(existing.localConflictInstallReceipts == nil)
        var candidate = receiptVault(x: ["candidateFuture": .string("right")])
        try candidate.recordLocalConflictInstallReceipts(for: [candidateC0])
        candidate.x[futureReceiptKey] = .object(["opaque": .string("candidate-device")])
        #expect(candidate.localConflictInstallReceipts == nil)

        let merged = try #require(VaultDocument.mergingSharedIdentity(
            existing: existing,
            candidate: candidate))

        #expect(merged.records.isEmpty)
        #expect(merged.localConflictInstallReceipts == [:])
        #expect(merged.x[VaultDocument.localConflictInstallReceiptsKey] == nil)
        #expect(merged.x[futureReceiptKey] == nil,
                "future receipt versions are device-local even when this build cannot read them")
        #expect(merged.x["existingFuture"] == .string("left"))
        #expect(merged.x["candidateFuture"] == .string("right"))
    }

    @Test func retiredExactCarrierReappearingFromCurrentReopensCleanupWithoutRestaging()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let copy = try materializedConflictCopy(for: scenario)
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("copy-confirmed".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([copy])
        try journal.reconcileDependencies(
            current: [scenario.survivor.id: scenario.survivor, copy.id: copy],
            confirmed: confirmed)

        let carrierValue = try #require(
            scenario.survivor.x[scenario.variant.extensionKey])
        let resolved = try #require(SyncMerge.resolvingContentConflicts(
            in: scenario.survivor,
            expected: [scenario.variant.extensionKey: carrierValue]))
        try journal.reconcileDependencies(
            current: [resolved.id: resolved, copy.id: copy],
            confirmed: confirmed)
        let retired = try #require(
            journal.dependency(scenario.survivor.id)?
                .requirements[scenario.variant.fingerprint])
        #expect(retired.carrierKey == nil)
        #expect(retired.carrierValue == nil)

        // Simulate a stale primary projection restoring the exact authenticated v1
        // member. There is no new inbox merge and therefore no second stage call.
        try journal.reconcileDependencies(
            current: [scenario.survivor.id: scenario.survivor, copy.id: copy],
            confirmed: confirmed)

        let reopened = try #require(
            journal.dependency(scenario.survivor.id)?
                .requirements[scenario.variant.fingerprint])
        #expect(reopened.carrierKey == scenario.variant.extensionKey)
        #expect(reopened.carrierValue == carrierValue)
        let cleanup = try #require(journal.carrierResolutions(
            current: [scenario.survivor.id: scenario.survivor, copy.id: copy],
            confirmed: confirmed).only)
        #expect(cleanup.expected == [scenario.variant.extensionKey: carrierValue])
        #expect(cleanup.resolvedEnvelope.x[scenario.variant.extensionKey] == nil)
    }

    @Test func beginCarrierResolutionRejectsStaleOfferedCarrierValue() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let copy = try materializedConflictCopy(for: scenario)
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("copy-confirmed".utf8)))
        var staged = SyncJournal()
        try staged.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try staged.recordConflictCopyEvidence([copy])
        try staged.reconcileDependencies(
            current: [scenario.survivor.id: scenario.survivor, copy.id: copy],
            confirmed: confirmed)

        let carrierKey = scenario.variant.extensionKey
        let carrierValue = try #require(scenario.survivor.x[carrierKey])
        let resolution = try #require(staged.carrierResolutions(
            current: [scenario.survivor.id: scenario.survivor, copy.id: copy],
            confirmed: confirmed).only)
        #expect(resolution.expected == [carrierKey: carrierValue])

        // Model an ambiguous pre-cleanup offer from a stale epoch. Its carrier key is
        // the same but its authenticated value is not. Clearing that offer and retiring
        // the current requirement would join evidence from two different conflicts.
        var staleOfferedSource = scenario.survivor
        staleOfferedSource.x[carrierKey] = .object([
            "version": .int(1),
            "stale": .bool(true),
        ])
        let sourceKey = SyncBase.key(scenario.survivor.id)
        let dependency = try #require(staged.dependency(scenario.survivor.id))
        var journal = SyncJournal(
            entries: [
                sourceKey: SyncJournal.Entry(
                    desired: scenario.survivor,
                    offered: SyncJournal.Offered(
                        envelope: staleOfferedSource,
                        generation: 1,
                        recordVersion: SyncRecordVersion(
                            Data("stale-source-generation".utf8))),
                    generation: 1,
                    modifiedAt: Date(timeIntervalSince1970: 1)),
            ],
            conflictDependencies: [sourceKey: dependency])
        let before = journal

        #expect(throws: SyncMerge.EnvelopeFailure.malformedContentConflict) {
            try journal.beginCarrierResolutions([resolution])
        }
        #expect(journal == before,
                "a stale offered value must fail before retiring any carrier evidence")
    }

    @Test func identicalConfirmedSourceAtOldCASDoesNotProvePostCopyReleaseAcrossCrash()
        throws
    {
        let directory = try directory("identical-source-old-cas")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let copy = try materializedConflictCopy(for: scenario)
        let carrierValue = try #require(
            scenario.survivor.x[scenario.variant.extensionKey])
        let releaseE = try #require(SyncMerge.resolvingContentConflicts(
            in: scenario.survivor,
            expected: [scenario.variant.extensionKey: carrierValue]))
        let sourceV1 = SyncRecordVersion(Data("source-E-V1".utf8))
        let sourceV2 = SyncRecordVersion(Data("source-E-V2".utf8))
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("copy-confirmed".utf8)))
        confirmed.recordConfirmed(releaseE, recordVersion: sourceV1)

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([copy])
        let current = [releaseE.id: releaseE, copy.id: copy]
        try journal.reconcileDependencies(current: current, confirmed: confirmed)
        let retired = try #require(
            journal.dependency(releaseE.id)?
                .requirements[scenario.variant.fingerprint])
        #expect(retired.carrierKey == nil)
        #expect(retired.carrierValue == nil)
        #expect(confirmed.envelope(releaseE.id) == releaseE,
                "the old base deliberately has bytes identical to the pending release")

        let pendingRelease = try #require(journal.pending(confirmed: confirmed).only)
        #expect(pendingRelease == releaseE,
                "identical bytes still need a post-copy conditional source write")
        journal.markOffered([pendingRelease], confirmed: confirmed)
        let preCrashOffer = try #require(
            journal.dependency(releaseE.id)?.sourceOffered)
        #expect(preCrashOffer.envelope == releaseE)
        #expect(preCrashOffer.recordVersion == sourceV1)

        // Crash after journal publication but before the submit. On restart, E/V1 is
        // only the pre-copy base fact; it cannot acknowledge this duplicate E offer.
        try SyncJournalFile.write(
            journal,
            to: journalURL,
            temporaryDirectory: directory)
        var restarted = try loadedJournal(from: journalURL)
        try restarted.reconcileDependencies(current: current, confirmed: confirmed)

        let retained = try #require(restarted.dependency(releaseE.id),
            "same envelope bytes at the offer's input CAS are not an accepted write")
        #expect(retained.sourceOffered?.envelope == releaseE)
        #expect(retained.sourceOffered?.recordVersion == sourceV1,
                "the crash retry must retain the exact V1 CAS authority")
        #expect(restarted.pending(confirmed: confirmed).only == releaseE,
                "restart must retry E rather than prune the ordering dependency")

        // Only transport acceptance advances the source generation to V2. Persisting
        // that base before acknowledgement is the durable post-copy ordering proof.
        confirmed.recordConfirmed(releaseE, recordVersion: sourceV2)
        restarted.acknowledge([releaseE.id], confirmed: confirmed)
        try restarted.reconcileDependencies(
            current: current,
            confirmed: confirmed,
            acceptedSourceIDs: [releaseE.id])

        #expect(restarted.dependency(releaseE.id) == nil)
        #expect(restarted.pending(confirmed: confirmed).isEmpty)
    }

    @Test func sourceACKBeforeCarrierRereadKeepsCopyLiveAndReopensCleanup()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let copy = try materializedConflictCopy(for: scenario)
        let carrierValue = try #require(
            scenario.survivor.x[scenario.variant.extensionKey])
        let release = try #require(SyncMerge.resolvingContentConflicts(
            in: scenario.survivor,
            expected: [scenario.variant.extensionKey: carrierValue]))
        var copyTombstone = copy.tombstoned(
            hlc: HLC(wallMs: 500, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        copyTombstone.x = copy.x
        let sourceV1 = SyncRecordVersion(Data("source-release-V1".utf8))
        let sourceV2 = SyncRecordVersion(Data("source-release-V2".utf8))
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("copy-confirmed".utf8)))
        confirmed.recordConfirmed(release, recordVersion: sourceV1)

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([copy])
        try journal.reconcileDependencies(
            current: [release.id: release, copy.id: copyTombstone],
            confirmed: confirmed)
        journal.reconcile(
            current: [release.id: release, copy.id: copyTombstone],
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 1))
        let sourceOffer = try #require(journal.pending(confirmed: confirmed).only)
        #expect(sourceOffer == release)
        journal.markOffered([sourceOffer], confirmed: confirmed)
        confirmed.recordConfirmed(release, recordVersion: sourceV2)

        // The submit resumed before the next primary reread. ACK must retain the graph
        // and therefore keep the already-deleted copy's live preservation snapshot.
        journal.acknowledge([release.id], confirmed: confirmed)
        #expect(journal.dependency(release.id) != nil)
        #expect(journal.pending(confirmed: confirmed).only == release,
                "the fence may retry E, but must never release the copy tombstone before reread")

        // Primary storage concurrently restored the exact carrier. This reread must
        // reopen a new source-cleanup epoch instead of pruning on the stale V2 ACK.
        try journal.reconcileDependencies(
            current: [scenario.survivor.id: scenario.survivor,
                      copyTombstone.id: copyTombstone],
            confirmed: confirmed,
            acceptedSourceIDs: [release.id])
        let reopened = try #require(journal.dependency(release.id))
        #expect(reopened.sourceOffered == nil)
        #expect(reopened.requirements[scenario.variant.fingerprint]?.carrierKey
                == scenario.variant.extensionKey)
        #expect(journal.pending(confirmed: confirmed).only == release,
                "copy deletion remains fenced while the restored carrier needs cleanup")
        let cleanup = try #require(journal.carrierResolutions(
            current: [scenario.survivor.id: scenario.survivor,
                      copyTombstone.id: copyTombstone],
            confirmed: confirmed).only)
        #expect(cleanup.resolvedEnvelope == release)

        // After conditional primary cleanup, E must receive a fresh CAS before the copy
        // tombstone becomes eligible as ordinary pending intent.
        try journal.reconcileDependencies(
            current: [release.id: release, copyTombstone.id: copyTombstone],
            confirmed: confirmed)
        let retriedRelease = try #require(journal.pending(confirmed: confirmed).only)
        #expect(retriedRelease == release)
        #expect(retriedRelease.id != copyTombstone.id)
    }

    @Test func newConflictAfterAcceptedReleaseInvalidatesOldSourceEpoch()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let copyC1 = try materializedConflictCopy(for: scenario)
        let firstCarrierValue = try #require(
            scenario.survivor.x[scenario.variant.extensionKey])
        let firstRelease = try #require(SyncMerge.resolvingContentConflicts(
            in: scenario.survivor,
            expected: [scenario.variant.extensionKey: firstCarrierValue]))
        let sourceV1 = SyncRecordVersion(Data("source-before-C1-release".utf8))
        let acceptedSourceV2 = SyncRecordVersion(Data("accepted-C1-release".utf8))
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            copyC1,
            recordVersion: SyncRecordVersion(Data("C1-confirmed".utf8)))
        confirmed.recordConfirmed(firstRelease, recordVersion: sourceV1)

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([copyC1])
        try journal.reconcileDependencies(
            current: [firstRelease.id: firstRelease, copyC1.id: copyC1],
            confirmed: confirmed)
        let firstSourceOffer = try #require(journal.pending(confirmed: confirmed).only)
        #expect(firstSourceOffer == firstRelease)
        journal.markOffered([firstSourceOffer], confirmed: confirmed)
        confirmed.recordConfirmed(firstRelease, recordVersion: acceptedSourceV2)
        journal.acknowledge([firstRelease.id], confirmed: confirmed)
        #expect(journal.dependency(firstRelease.id)?.sourceOffered != nil,
                "the accepted release awaits its mandatory primary reread")

        // Before that reread completes, another independently losing secure edit adds
        // C2. The accepted C1-only source release predates this new prerequisite and is
        // no longer authority to retire the enlarged dependency graph.
        let second = try secondSecureCarrier(for: scenario)
        let copyC2 = try materializedConflictCopy(
            source: second.source,
            variant: second.variant,
            keyring: scenario.keyring)
        #expect(copyC2.id != copyC1.id)
        try journal.stageConflictDependency(
            source: second.source,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([copyC2])

        let enlarged = try #require(journal.dependency(firstRelease.id))
        #expect(Set(enlarged.requirements.keys) == [
            scenario.variant.fingerprint,
            second.variant.fingerprint,
        ])
        #expect(enlarged.sourceOffered == nil,
                "adding C2 must invalidate the C1-only source offer and its receipt")

        let currentWithC2 = [
            second.source.id: second.source,
            copyC1.id: copyC1,
            copyC2.id: copyC2,
        ]
        try journal.reconcileDependencies(
            current: currentWithC2,
            confirmed: confirmed,
            acceptedSourceIDs: [firstRelease.id])
        let copyC2Offer = try #require(journal.pending(confirmed: confirmed).only)
        #expect(copyC2Offer == copyC2,
                "the newly introduced prerequisite must be published before any source")
        journal.markOffered([copyC2Offer], confirmed: confirmed)
        confirmed.recordConfirmed(
            copyC2,
            recordVersion: SyncRecordVersion(Data("C2-confirmed".utf8)))
        journal.acknowledge([copyC2.id], confirmed: confirmed)

        let secondCarrierValue = try #require(
            second.source.x[second.variant.extensionKey])
        let secondRelease = try #require(SyncMerge.resolvingContentConflicts(
            in: second.source,
            expected: [second.variant.extensionKey: secondCarrierValue]))
        let currentAfterCleanup = [
            secondRelease.id: secondRelease,
            copyC1.id: copyC1,
            copyC2.id: copyC2,
        ]
        try journal.reconcileDependencies(
            current: currentAfterCleanup,
            confirmed: confirmed)

        let freshRelease = try #require(journal.pending(confirmed: confirmed).only)
        #expect(freshRelease == secondRelease)
        #expect(freshRelease.id == firstRelease.id)
        #expect(journal.dependency(firstRelease.id)?.sourceOffered == nil,
                "C2 confirmation unlocks a fresh source CAS, never the stale C1 epoch")
    }

    @Test func acceptedSourceRereadDiscoversCurrentOnlyC2AndInvalidatesReceipt()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let copyC1 = try materializedConflictCopy(for: scenario)
        let firstCarrierValue = try #require(
            scenario.survivor.x[scenario.variant.extensionKey])
        let firstRelease = try #require(SyncMerge.resolvingContentConflicts(
            in: scenario.survivor,
            expected: [scenario.variant.extensionKey: firstCarrierValue]))
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            copyC1,
            recordVersion: SyncRecordVersion(Data("C1-confirmed".utf8)))
        confirmed.recordConfirmed(
            firstRelease,
            recordVersion: SyncRecordVersion(Data("source-before-C1-release".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([copyC1])
        try journal.reconcileDependencies(
            current: [firstRelease.id: firstRelease, copyC1.id: copyC1],
            confirmed: confirmed)
        let firstSourceOffer = try #require(journal.pending(confirmed: confirmed).only)
        journal.markOffered([firstSourceOffer], confirmed: confirmed)
        confirmed.recordConfirmed(
            firstRelease,
            recordVersion: SyncRecordVersion(Data("accepted-C1-source-release".utf8)))
        journal.acknowledge([firstRelease.id], confirmed: confirmed)
        #expect(journal.dependency(firstRelease.id)?.sourceOffered != nil)

        // A primary/external writer commits a fresh, structurally valid C2 carrier and
        // its materialized copy while the source submit was awaited. There was no inbox
        // merge and therefore no explicit stage call. This accepted receipt orders C1
        // only; the mandatory current reread must discover C2 and start a new epoch.
        let second = try secondSecureCarrier(for: scenario)
        let copyC2 = try materializedConflictCopy(
            source: second.source,
            variant: second.variant,
            keyring: scenario.keyring)
        #expect(second.variant.fingerprint != scenario.variant.fingerprint)
        #expect(second.source.x[scenario.variant.extensionKey] == nil)
        #expect(second.source.x[second.variant.extensionKey] != nil)
        let current = [
            second.source.id: second.source,
            copyC1.id: copyC1,
            copyC2.id: copyC2,
        ]

        // The primary reread discovers the new carrier edge, but a same-provenance
        // occupant alone cannot become immutable C0 evidence. Freeze only the exact
        // copy returned by the authenticated secure materializer, then complete the
        // accepted-source reconciliation against that larger epoch.
        try journal.reconcileDependencies(
            current: current,
            confirmed: confirmed)
        #expect(journal.dependency(firstRelease.id)?
            .requirements[second.variant.fingerprint]?.snapshot == nil)
        try journal.recordConflictCopyEvidence([copyC2])
        try journal.reconcileDependencies(
            current: current,
            confirmed: confirmed,
            acceptedSourceIDs: [firstRelease.id])

        let enlarged = try #require(journal.dependency(firstRelease.id),
            "current-only C2 must be staged before the C1 receipt can prune")
        #expect(Set(enlarged.requirements.keys) == [
            scenario.variant.fingerprint,
            second.variant.fingerprint,
        ])
        #expect(enlarged.sourceOffered == nil,
                "the C1-only accepted receipt predates C2 and must be invalidated")
        let c2 = try #require(enlarged.requirements[second.variant.fingerprint])
        #expect(c2.snapshot == copyC2)
        #expect(c2.carrierKey == second.variant.extensionKey)
        let next = try #require(journal.pending(confirmed: confirmed).only)
        #expect(next == copyC2,
                "newly discovered C2 is the only eligible write before a fresh source CAS")
    }

    @Test func resetMaterializationSourceContainsOnlyMissingCarrierRequirement()
        throws
    {
        let first = try SecureConflictVariantFixture.makeScenario()
        let copyC1 = try materializedConflictCopy(for: first)
        let second = try secondSecureCarrier(for: first)
        var unionSource = first.survivor
        unionSource.x[second.variant.extensionKey] =
            second.source.x[second.variant.extensionKey]
        #expect(Set(try SyncMerge.secureContentConflictVariants(in: unionSource)
            .map(\.fingerprint)) == [
                first.variant.fingerprint,
                second.variant.fingerprint,
            ])

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: unionSource,
            conflictCopies: [copyC1])
        let c1Offer = try #require(journal.pending(confirmed: SyncBase()).only)
        #expect(c1Offer == copyC1)
        journal.markOffered([c1Offer], confirmed: SyncBase())

        // The user changes C1's primary representation after its authenticated offer.
        // Recovery of still-missing C2 must not feed C1 back through a secure
        // materializer, whose validation could reject or rewrite this legitimate edit.
        var changedC1Fields = try #require(copyC1.fields)
        changedC1Fields.name = "Demoted and edited C1"
        changedC1Fields.content = Data("plain user-edited C1".utf8)
        let changedPlainC1 = SyncEnvelope(
            id: copyC1.id,
            hlc: HLC(wallMs: 900, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: false,
            deleted: false,
            fields: changedC1Fields,
            x: copyC1.x)
        try journal.reconcileDependencies(
            current: [unionSource.id: unionSource, changedPlainC1.id: changedPlainC1],
            confirmed: SyncBase())

        let recoverySource = try #require(
            journal.carrierSourcesAwaitingMaterialization.only)
        let recoveryVariants = try SyncMerge.secureContentConflictVariants(
            in: recoverySource)
        #expect(recoveryVariants.map(\.fingerprint) == [second.variant.fingerprint],
                "reset recovery must validate/materialize C2 without revisiting satisfied C1")
        #expect(recoverySource.x[first.variant.extensionKey] == nil)
        #expect(recoverySource.x[second.variant.extensionKey]
                == unionSource.x[second.variant.extensionKey])
        #expect(journal.dependency(unionSource.id)?
            .requirements[first.variant.fingerprint]?.offered?.envelope == copyC1,
                "filtering the recovery source cannot rewrite C1's frozen proof")
    }

    @Test func schema2EmptyJournalDiscoversExternalConflictPairAndGatesSource()
        throws
    {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "external losing edit")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "external winning edit")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            ancestor,
            recordVersion: SyncRecordVersion(Data("external-ancestor".utf8)))
        var journal = SyncJournal()
        #expect(journal.schemaVersion == SyncJournal.currentSchemaVersion)
        #expect(!journal.requiresDependencyMigration)
        #expect(journal.dependency(source.id) == nil)
        let current = [source.id: source, copy.id: copy]

        try journal.reconcileDependencies(current: current, confirmed: confirmed)
        journal.reconcile(
            current: current,
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 1))

        let dependency = try #require(journal.dependency(source.id),
            "a current schema journal must still discover externally committed provenance")
        let provenance = try #require(SyncMerge.conflictCopyProvenance(in: copy))
        #expect(dependency.requirements[provenance.fingerprint]?.snapshot == copy)
        let pending = journal.pending(confirmed: confirmed)
        #expect(pending == [copy])
        #expect(!pending.contains(where: { $0.id == source.id }),
                "external source intent remains gated until its copy is confirmed")
    }

    @Test func completedPlainDependencyStaysQuiescentWithLiveProvenanceCopy()
        throws
    {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "losing plain body")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning plain body")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let release = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            ancestor,
            recordVersion: SyncRecordVersion(Data("source-before-copy".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: release,
            conflictCopies: [copy])
        let current = [release.id: release, copy.id: copy]
        try journal.reconcileDependencies(current: current, confirmed: confirmed)

        let copyOffer = try #require(journal.pending(confirmed: confirmed).only)
        #expect(copyOffer == copy)
        journal.markOffered([copyOffer], confirmed: confirmed)
        confirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("copy-accepted".utf8)))
        journal.acknowledge([copy.id], confirmed: confirmed)
        let sourceOffer = try #require(journal.pending(confirmed: confirmed).only)
        #expect(sourceOffer == release)
        journal.markOffered([sourceOffer], confirmed: confirmed)
        confirmed.recordConfirmed(
            release,
            recordVersion: SyncRecordVersion(Data("source-after-copy".utf8)))
        journal.acknowledge([release.id], confirmed: confirmed)
        try journal.reconcileDependencies(
            current: current,
            confirmed: confirmed,
            acceptedSourceIDs: [release.id])
        #expect(journal.dependency(release.id) == nil)
        #expect(journal.pending(confirmed: confirmed).isEmpty)

        // The ordinary copy remains live and necessarily retains conflictCopy.v1.
        // That identity is not evidence of a new conflict epoch after the source and C
        // are already confirmed together. Repeated maintenance must be a fixed point.
        for round in 1...3 {
            try journal.reconcileDependencies(
                current: current,
                confirmed: confirmed)
            journal.reconcile(
                current: current,
                confirmed: confirmed,
                deviceID: Self.deviceB,
                now: Date(timeIntervalSince1970: TimeInterval(round)))
            #expect(journal.dependency(release.id) == nil,
                    "round \(round) recreated an already-completed dependency")
            #expect(journal.pending(confirmed: confirmed).isEmpty,
                    "round \(round) resubmitted an already-confirmed source/copy")
        }
    }

    @Test func accountResetRecoversCompletedPlainPairAndOffersCopyBeforeSource()
        throws
    {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "completed losing body")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "completed source body")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        let current = [source.id: source, copy.id: copy]
        var oldBase = SyncBase(journalEstablished: true)
        oldBase.recordConfirmed(
            source,
            recordVersion: SyncRecordVersion(Data("old-account-source".utf8)))
        oldBase.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("old-account-copy".utf8)))
        var journal = SyncJournal()
        #expect(journal.dependency(source.id) == nil,
                "the old account starts from a fully completed/pruned pair")

        try journal.prepareForAccountChange(
            current: current,
            confirmed: oldBase,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 1))

        let replacementBase = SyncBase(journalEstablished: true)
        let recovered = try #require(journal.dependency(source.id),
            "reviewed account reset must rebuild copy ordering before clearing scope")
        let provenance = try #require(SyncMerge.conflictCopyProvenance(in: copy))
        #expect(recovered.requirements[provenance.fingerprint]?.snapshot == copy)
        #expect(journal.pending(confirmed: replacementBase) == [copy])

        journal.markOffered([copy], confirmed: replacementBase)
        var copyConfirmed = replacementBase
        copyConfirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("new-account-copy".utf8)))
        journal.acknowledge([copy.id], confirmed: copyConfirmed)
        #expect(journal.pending(confirmed: copyConfirmed) == [source],
                "E becomes eligible only after C is durable in the replacement account")
    }

    @Test func transportRekeyRecoversCompletedPlainPairAndOffersCopyBeforeSource()
        throws
    {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "completed losing body")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "completed source body")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        var oldBase = SyncBase(journalEstablished: true)
        oldBase.recordConfirmed(
            source,
            recordVersion: SyncRecordVersion(Data("old-key-source".utf8)))
        oldBase.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("old-key-copy".utf8)))
        var journal = SyncJournal()
        #expect(journal.dependency(source.id) == nil)

        try journal.prepareForTransportRekey(
            current: [source.id: source, copy.id: copy],
            confirmed: oldBase,
            now: Date(timeIntervalSince1970: 1))

        let replacementBase = SyncBase(recordVersions: oldBase.recordVersions)
        let recovered = try #require(journal.dependency(source.id),
            "rekey must rebuild the completed C→E edge before envelope base reset")
        let provenance = try #require(SyncMerge.conflictCopyProvenance(in: copy))
        #expect(recovered.requirements[provenance.fingerprint]?.snapshot == copy)
        #expect(journal.pending(confirmed: replacementBase) == [copy])

        journal.markOffered([copy], confirmed: replacementBase)
        var copyConfirmed = replacementBase
        copyConfirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("new-key-copy".utf8)))
        journal.acknowledge([copy.id], confirmed: copyConfirmed)
        #expect(journal.pending(confirmed: copyConfirmed) == [source],
                "rekeyed E must remain gated behind rekeyed C")
    }

    @Test func transportRekeyRecoversCompletedPlainCopyBeforeConfirmedSourceTombstone()
        throws
    {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "completed losing body")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "completed source body")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let survivor = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        let tombstone = survivor.tombstoned(
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        var oldBase = SyncBase(journalEstablished: true)
        oldBase.recordConfirmed(
            tombstone,
            recordVersion: SyncRecordVersion(Data("old-key-source-tombstone".utf8)))
        oldBase.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("old-key-copy".utf8)))
        var journal = SyncJournal()

        // Primary storage legitimately contains no row for the confirmed tombstone.
        // The reviewed key reset must nevertheless recover its completed plain C→E
        // ordering proof before either record is resealed into the new transport epoch.
        try journal.prepareForTransportRekey(
            current: [copy.id: copy],
            confirmed: oldBase,
            now: Date(timeIntervalSince1970: 1))

        let replacementBase = SyncBase(recordVersions: oldBase.recordVersions)
        let recovered = try #require(journal.dependency(tombstone.id),
            "rekey must use the confirmed tombstone as the missing source snapshot")
        let provenance = try #require(SyncMerge.conflictCopyProvenance(in: copy))
        #expect(recovered.requirements[provenance.fingerprint]?.snapshot == copy)
        #expect(recovered.sourceSnapshot == tombstone)
        #expect(journal.pending(confirmed: replacementBase) == [copy],
                "the live conflict copy must be resealed before the source tombstone")

        journal.markOffered([copy], confirmed: replacementBase)
        var copyConfirmed = replacementBase
        copyConfirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("new-key-copy".utf8)))
        journal.acknowledge([copy.id], confirmed: copyConfirmed)
        #expect(journal.pending(confirmed: copyConfirmed) == [tombstone],
                "only C's new-key ACK may release the confirmed source tombstone")
    }

    @Test func independentIdenticalV2AfterConflictRebasesOfferButCannotPruneWithoutReceipt()
        throws
    {
        let directory = try directory("identical-independent-v2-receipt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let copy = try materializedConflictCopy(for: scenario)
        let carrierValue = try #require(
            scenario.survivor.x[scenario.variant.extensionKey])
        let release = try #require(SyncMerge.resolvingContentConflicts(
            in: scenario.survivor,
            expected: [scenario.variant.extensionKey: carrierValue]))
        let sourceV1 = SyncRecordVersion(Data("source-E-V1".utf8))
        let independentV2 = SyncRecordVersion(Data("independent-E-V2".utf8))
        let acceptedV3 = SyncRecordVersion(Data("accepted-E-V3".utf8))
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            copy,
            recordVersion: SyncRecordVersion(Data("copy-confirmed".utf8)))
        confirmed.recordConfirmed(release, recordVersion: sourceV1)
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([copy])
        let current = [release.id: release, copy.id: copy]
        try journal.reconcileDependencies(current: current, confirmed: confirmed)
        let firstOffer = try #require(journal.pending(confirmed: confirmed).only)
        journal.markOffered([firstOffer], confirmed: confirmed)
        #expect(journal.dependency(release.id)?.sourceOffered?.recordVersion == sourceV1)

        // The V1 submit conflicted. An authoritative independent writer happened to
        // publish byte-identical E/V2; persist base, then crash before journal rejection.
        confirmed.recordConfirmed(release, recordVersion: independentV2)
        try SyncJournalFile.write(
            journal,
            to: journalURL,
            temporaryDirectory: directory)
        var restarted = try loadedJournal(from: journalURL)
        try restarted.reconcileDependencies(current: current, confirmed: confirmed)

        let retained = try #require(restarted.dependency(release.id),
            "generation advance without an accepted receipt cannot prove our write")
        #expect(retained.sourceOffered?.recordVersion == sourceV1)
        let retry = try #require(restarted.pending(confirmed: confirmed).only)
        #expect(retry == release)

        // Pre-push rebase resolves the known conflict and freezes the same E against
        // V2. This still is not a receipt and must remain fenced across persistence.
        restarted.reject([release.id])
        restarted.markOffered([retry], confirmed: confirmed)
        #expect(restarted.dependency(release.id)?.sourceOffered?.recordVersion
                == independentV2)
        try SyncJournalFile.write(
            restarted,
            to: journalURL,
            temporaryDirectory: directory)
        restarted = try loadedJournal(from: journalURL)
        try restarted.reconcileDependencies(current: current, confirmed: confirmed)
        #expect(restarted.dependency(release.id) != nil)
        #expect(restarted.pending(confirmed: confirmed).only == release)

        // Model the explicit accepted receipt by acknowledging only after the submit
        // returned E/V3. Current primary must then be reread before pruning.
        confirmed.recordConfirmed(release, recordVersion: acceptedV3)
        restarted.acknowledge([release.id], confirmed: confirmed)
        #expect(restarted.dependency(release.id) != nil)
        try restarted.reconcileDependencies(
            current: current,
            confirmed: confirmed,
            acceptedSourceIDs: [release.id])
        #expect(restarted.dependency(release.id) == nil)
        #expect(restarted.pending(confirmed: confirmed).isEmpty)
    }

    @Test func sameProvenanceC1InBaseDoesNotSatisfyExactC0WithoutAcceptanceReceipt()
        throws
    {
        let scenario = try plainCopyReceiptScenario()
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.source,
            conflictCopies: [scenario.c0])
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            scenario.c1,
            recordVersion: SyncRecordVersion(Data("independent-C1".utf8)))

        let pending = journal.pending(confirmed: confirmed)

        #expect(pending == [scenario.c0],
                "same provenance identifies the copy lineage but cannot prove exact C0 was accepted")
        #expect(!pending.contains { $0.id == scenario.source.id },
                "source release remains fenced until exact C0 has an acceptance receipt")
    }

    @Test func restartHealsBaseFirstExactC0ReceiptAndReleasesSourceWithCurrentCAS()
        async throws
    {
        let directory = try directory("base-first-exact-C0-receipt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseURL = directory.appendingPathComponent("base.json")
        let journalURL = directory.appendingPathComponent("journal.json")
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "base-first-exact-C0-receipt")
        let scenario = try plainCopyReceiptScenario()
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "receipt ancestor")

        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let ancestorWire = try #require(backend.snapshot.only)
        let ancestorVersion = try #require(ancestorWire.recordVersion)
        var preOfferBase = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        preOfferBase.recordConfirmed(ancestor, recordVersion: ancestorVersion)

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.source,
            conflictCopies: [scenario.c0])
        #expect(journal.pending(confirmed: preOfferBase) == [scenario.c0])
        journal.markOffered([scenario.c0], confirmed: preOfferBase)
        let fingerprint = try #require(
            SyncMerge.conflictCopyProvenance(in: scenario.c0)?.fingerprint)
        let ambiguous = try #require(
            journal.dependency(scenario.source.id)?.requirements[fingerprint])
        #expect(ambiguous.snapshot == scenario.c0)
        #expect(ambiguous.offered?.envelope == scenario.c0)
        #expect(ambiguous.acceptedRecordVersion == nil)

        // Model the exact crash window: C0 was accepted and base.json reached disk,
        // but the dependency journal still contains the ambiguous pre-submit offer.
        backend.seed([try WireCodec.seal(scenario.c0, using: sealer)])
        let copyWire = try #require(
            backend.snapshot.first(where: { $0.id == scenario.c0.id }))
        let copyVersion = try #require(copyWire.recordVersion)
        var durableBase = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        durableBase.recordConfirmed(ancestor, recordVersion: ancestorVersion)
        durableBase.recordConfirmed(scenario.c0, recordVersion: copyVersion)
        try SyncBaseFile.write(
            durableBase,
            to: baseURL,
            temporaryDirectory: directory)
        try SyncJournalFile.write(
            journal,
            to: journalURL,
            temporaryDirectory: directory)

        let library = Library()
        library.envelopes = [
            scenario.source.id: scenario.source,
            scenario.c0.id: scenario.c0,
        ]
        let cancelling = CaptureCancellingTransport(backend)
        let preflight = engine(
            backend: cancelling,
            library: library,
            sealer: sealer,
            device: Self.deviceB,
            directory: directory)

        #expect(await preflight.sync() == .disabled)
        let releasedWire = try #require(cancelling.capturedBatches.only?.only)
        #expect(releasedWire.id == scenario.source.id)
        #expect(releasedWire.recordVersion == ancestorVersion,
                "the healed edge must release E against the current source CAS")
        #expect(try WireCodec.open(releasedWire, using: sealer) == scenario.source,
                "preflight must not restamp or rewrite the exact source bytes")

        let healed = try loadedJournal(from: journalURL)
        let healedRequirement = try #require(
            healed.dependency(scenario.source.id)?.requirements[fingerprint])
        #expect(healedRequirement.snapshot == scenario.c0)
        #expect(healedRequirement.offered == nil)
        #expect(healedRequirement.acceptedRecordVersion == copyVersion)
        #expect(healed.dependency(scenario.source.id)?.sourceSnapshot == scenario.source)
        #expect(healed.dependency(scenario.source.id)?.sourceOffered?.envelope
                == scenario.source)
        #expect(healed.dependency(scenario.source.id)?.sourceOffered?.recordVersion
                == ancestorVersion)

        // A second restart uses that durable receipt and live CAS, rather than wedging
        // forever on C0's create generation or releasing a synthesized source value.
        let accepting = engine(
            backend: backend,
            library: library,
            sealer: sealer,
            device: Self.deviceB,
            directory: directory)
        let finalState = await accepting.sync()
        #expect(!finalState.isHalted)
        let submittedSource = try #require(
            backend.submittedBatches.last?.first(where: {
                $0.id == scenario.source.id
            }))
        #expect(submittedSource.recordVersion == ancestorVersion)
        #expect(try WireCodec.open(submittedSource, using: sealer) == scenario.source)
        let backendCopy = try #require(
            backend.snapshot.first(where: { $0.id == scenario.c0.id }))
        let openedCopy = try WireCodec.open(backendCopy, using: sealer)
        #expect(openedCopy == scenario.c0)
        let openedProvenance = try #require(
            SyncMerge.conflictCopyProvenance(in: openedCopy))
        let expectedProvenance = try #require(
            SyncMerge.conflictCopyProvenance(in: scenario.c0))
        #expect(openedProvenance.sourceID == expectedProvenance.sourceID)
        #expect(openedProvenance.fingerprint == expectedProvenance.fingerprint)
        #expect(try loadedJournal(from: journalURL)
            .dependency(scenario.source.id) == nil)
    }

    @Test func restartRecoveryDoesNotMintReceiptFromC1OrCopyTombstone()
        throws
    {
        let scenario = try plainCopyReceiptScenario()
        let tombstone = scenario.c1.tombstoned(
            hlc: HLC(wallMs: 500, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let fingerprint = try #require(
            SyncMerge.conflictCopyProvenance(in: scenario.c0)?.fingerprint)

        for (label, occupant) in [
            ("same-provenance-C1", scenario.c1),
            ("copy-tombstone", tombstone),
        ] {
            let directory = try directory("receipt-no-heal-\(label)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let journalURL = directory.appendingPathComponent("journal.json")
            var journal = SyncJournal()
            try journal.stageConflictDependency(
                source: scenario.source,
                conflictCopies: [scenario.c0])
            journal.markOffered([scenario.c0], confirmed: SyncBase())
            try SyncJournalFile.write(
                journal,
                to: journalURL,
                temporaryDirectory: directory)

            var confirmed = SyncBase(journalEstablished: true)
            confirmed.recordConfirmed(
                occupant,
                recordVersion: SyncRecordVersion(Data("\(label)-version".utf8)))
            var restarted = try loadedJournal(from: journalURL)
            restarted.recoverAcceptedPrerequisiteOffers(confirmed: confirmed)
            try SyncJournalFile.write(
                restarted,
                to: journalURL,
                temporaryDirectory: directory)
            let durable = try loadedJournal(from: journalURL)
            let requirement = try #require(
                durable.dependency(scenario.source.id)?.requirements[fingerprint])

            #expect(requirement.snapshot == scenario.c0)
            #expect(requirement.offered?.envelope == scenario.c0)
            #expect(requirement.acceptedRecordVersion == nil,
                    "\(label) must not manufacture an exact-C0 acceptance receipt")
            #expect(durable.pending(confirmed: confirmed) == [scenario.c0])
            #expect(durable.dependency(scenario.source.id)?.sourceSnapshot
                    == scenario.source)
            let durableSnapshot = try #require(requirement.snapshot)
            let durableProvenance = try #require(
                SyncMerge.conflictCopyProvenance(in: durableSnapshot))
            let expectedProvenance = try #require(
                SyncMerge.conflictCopyProvenance(in: scenario.c0))
            #expect(durableProvenance.sourceID == expectedProvenance.sourceID)
            #expect(durableProvenance.fingerprint == expectedProvenance.fingerprint)
        }
    }

    @Test func exactC0AcceptanceReceiptSurvivesRoundTripAndLaterBaseC1()
        throws
    {
        let directory = try directory("exact-C0-acceptance-receipt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let scenario = try plainCopyReceiptScenario()
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.source,
            conflictCopies: [scenario.c0])
        var confirmed = SyncBase(journalEstablished: true)
        let exactOffer = try #require(journal.pending(confirmed: confirmed).only)
        #expect(exactOffer == scenario.c0)
        journal.markOffered([exactOffer], confirmed: confirmed)
        confirmed.recordConfirmed(
            scenario.c0,
            recordVersion: SyncRecordVersion(Data("accepted-exact-C0".utf8)))
        journal.acknowledge([scenario.c0.id], confirmed: confirmed)
        try SyncJournalFile.write(
            journal,
            to: journalURL,
            temporaryDirectory: directory)

        var restarted = try loadedJournal(from: journalURL)
        #expect(restarted.pending(confirmed: confirmed) == [scenario.source])

        // C1 is a later ordinary generation at the same deterministic id. It may
        // replace the base envelope without erasing the durable fact that this device's
        // exact C0 offer was accepted first.
        confirmed.recordConfirmed(
            scenario.c1,
            recordVersion: SyncRecordVersion(Data("later-C1".utf8)))
        try SyncJournalFile.write(
            restarted,
            to: journalURL,
            temporaryDirectory: directory)
        restarted = try loadedJournal(from: journalURL)

        #expect(restarted.pending(confirmed: confirmed) == [scenario.source],
                "the exact-C0 receipt, not equality with today's base C1, releases source")
    }

    @Test func copyTombstoneNeverSatisfiesExactC0Requirement()
        throws
    {
        let scenario = try plainCopyReceiptScenario()
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.source,
            conflictCopies: [scenario.c0])
        let tombstone = scenario.c1.tombstoned(
            hlc: HLC(wallMs: 500, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        var confirmed = SyncBase(journalEstablished: true)
        confirmed.recordConfirmed(
            tombstone,
            recordVersion: SyncRecordVersion(Data("copy-tombstone".utf8)))

        #expect(journal.pending(confirmed: confirmed) == [scenario.c0])
        #expect(journal.dependency(scenario.source.id) != nil)
    }

    @Test func accountResetClearsExactC0AcceptanceReceiptAndReordersCopyFirst()
        throws
    {
        let scenario = try plainCopyReceiptScenario()
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.source,
            conflictCopies: [scenario.c0])
        var confirmed = SyncBase(journalEstablished: true)
        journal.markOffered([scenario.c0], confirmed: confirmed)
        confirmed.recordConfirmed(
            scenario.c0,
            recordVersion: SyncRecordVersion(Data("old-account-C0".utf8)))
        journal.acknowledge([scenario.c0.id], confirmed: confirmed)
        confirmed.recordConfirmed(
            scenario.c1,
            recordVersion: SyncRecordVersion(Data("old-account-C1".utf8)))
        #expect(journal.pending(confirmed: confirmed) == [scenario.source],
                "the old scope first proves the receipt is active")

        try journal.prepareForAccountChange(
            current: [
                scenario.source.id: scenario.source,
                scenario.c1.id: scenario.c1,
            ],
            confirmed: confirmed,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 1))
        let replacement = SyncBase(journalEstablished: true)
        let pending = journal.pending(confirmed: replacement)

        #expect(pending.only?.id == scenario.c0.id)
        #expect(!pending.contains { $0.id == scenario.source.id },
                "an acceptance receipt cannot cross private-database account scope")
    }

    @Test func accountResetDependencySourceDeletedBeforeOfferBecomesOrderedTombstone()
        throws
    {
        let scenario = try plainCopyReceiptScenario()
        var oldBase = SyncBase(journalEstablished: true)
        oldBase.recordConfirmed(
            scenario.source,
            recordVersion: SyncRecordVersion(Data("old-source-generation".utf8)))
        oldBase.recordConfirmed(
            scenario.c1,
            recordVersion: SyncRecordVersion(Data("old-copy-generation".utf8)))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.source,
            conflictCopies: [scenario.c0])

        try journal.prepareForAccountChange(
            current: [
                scenario.source.id: scenario.source,
                scenario.c1.id: scenario.c1,
            ],
            confirmed: oldBase,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 1))
        let replacement = SyncBase(journalEstablished: true)
        #expect(journal.pending(confirmed: replacement) == [scenario.c0])

        // The user deletes E after the reviewed reset but before C0 has been offered.
        // E is dependency-owned durable intent, so absence is an ordered T rather than
        // an unoffered create that may collapse away.
        journal.reconcile(
            current: [scenario.c1.id: scenario.c1],
            confirmed: replacement,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 2))
        let sourceTombstone = try #require(journal.entry(scenario.source.id)?.desired)
        #expect(sourceTombstone.deleted)
        #expect(sourceTombstone.id == scenario.source.id)
        #expect(journal.pending(confirmed: replacement) == [scenario.c0],
                "the new source T remains fenced until exact C0 is accepted")

        journal.markOffered([scenario.c0], confirmed: replacement)
        var copyConfirmed = replacement
        copyConfirmed.recordConfirmed(
            scenario.c0,
            recordVersion: SyncRecordVersion(Data("new-account-C0".utf8)))
        journal.acknowledge([scenario.c0.id], confirmed: copyConfirmed)
        #expect(journal.pending(confirmed: copyConfirmed) == [sourceTombstone])

        // Preserve the ordinary journal compaction rule: a brand-new nondependency
        // create that disappears before it was offered still collapses to no intent.
        let ordinaryCreate = envelope(
            device: Self.deviceA,
            revision: 700,
            body: "ordinary unoffered create")
        var ordinaryJournal = SyncJournal()
        ordinaryJournal.reconcile(
            current: [ordinaryCreate.id: ordinaryCreate],
            confirmed: replacement,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 3))
        #expect(ordinaryJournal.pending(confirmed: replacement) == [ordinaryCreate])
        ordinaryJournal.reconcile(
            current: [:],
            confirmed: replacement,
            deviceID: Self.deviceB,
            now: Date(timeIntervalSince1970: 4))
        #expect(ordinaryJournal.entry(ordinaryCreate.id) == nil)
        #expect(ordinaryJournal.pending(confirmed: replacement).isEmpty)
    }

    @Test func transportRekeyClearsExactC0AcceptanceReceiptAndReordersCopyFirst()
        throws
    {
        let scenario = try plainCopyReceiptScenario()
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.source,
            conflictCopies: [scenario.c0])
        var confirmed = SyncBase(journalEstablished: true)
        journal.markOffered([scenario.c0], confirmed: confirmed)
        confirmed.recordConfirmed(
            scenario.c0,
            recordVersion: SyncRecordVersion(Data("old-key-C0".utf8)))
        journal.acknowledge([scenario.c0.id], confirmed: confirmed)
        confirmed.recordConfirmed(
            scenario.c1,
            recordVersion: SyncRecordVersion(Data("old-key-C1".utf8)))
        #expect(journal.pending(confirmed: confirmed) == [scenario.source])

        try journal.prepareForTransportRekey(
            current: [
                scenario.source.id: scenario.source,
                scenario.c1.id: scenario.c1,
            ],
            confirmed: confirmed,
            now: Date(timeIntervalSince1970: 1))
        let replacement = SyncBase(
            recordVersions: confirmed.recordVersions,
            journalEstablished: true)
        let pending = journal.pending(confirmed: replacement)

        #expect(pending.only?.id == scenario.c0.id)
        #expect(!pending.contains { $0.id == scenario.source.id },
                "a transport-key epoch must earn a fresh copy acceptance receipt")
    }

    @Test func engineCrashAfterIdenticalConflictV2RebasesAndRequiresAcceptedV3Receipt()
        async throws
    {
        let directory = try directory("engine-identical-conflict-receipt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseURL = directory.appendingPathComponent("base.json")
        let journalURL = directory.appendingPathComponent("journal.json")
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "engine-conflict-receipt")
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "losing")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let releaseE = try #require(merge.survivor)
        let copyC = try #require(merge.conflictCopies.only)

        backend.seed([
            try WireCodec.seal(copyC, using: sealer),
            try WireCodec.seal(releaseE, using: sealer),
        ])
        let copyV1 = try #require(
            backend.snapshot.first(where: { $0.id == copyC.id })?.recordVersion)
        let sourceV1 = try #require(
            backend.snapshot.first(where: { $0.id == releaseE.id })?.recordVersion)
        var base = SyncBase(
            cursor: backend.currentCursor,
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(copyC, recordVersion: copyV1)
        base.recordConfirmed(releaseE, recordVersion: sourceV1)
        try SyncBaseFile.write(
            base,
            to: baseURL,
            temporaryDirectory: directory)
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: releaseE,
            conflictCopies: [copyC])
        let current = [releaseE.id: releaseE, copyC.id: copyC]
        try journal.reconcileDependencies(current: current, confirmed: base)
        let firstOffer = try #require(journal.pending(confirmed: base).only)
        #expect(firstOffer == releaseE)
        journal.markOffered([firstOffer], confirmed: base)
        try SyncJournalFile.write(
            journal,
            to: journalURL,
            temporaryDirectory: directory)

        // A different client independently writes byte-identical E after our V1 base.
        // Our frozen V1 offer must conflict against this authoritative V2 generation.
        backend.seed([try WireCodec.seal(releaseE, using: sealer)])
        let independentV2 = try #require(
            backend.snapshot.first(where: { $0.id == releaseE.id })?.recordVersion)
        #expect(independentV2 != sourceV1)
        let crashingLibrary = Library()
        crashingLibrary.envelopes = current
        crashingLibrary.failCurrentEnvelopeCall = 3
        let crashing = engine(
            backend: backend,
            library: crashingLibrary,
            sealer: sealer,
            device: Self.deviceB,
            directory: directory)

        let crashed = await crashing.sync()

        guard case .offline = crashed else {
            Issue.record("the injected post-base crash should stop this round, got \(crashed)")
            return
        }
        guard case .loaded(let durableV2) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("the authoritative identical V2 base must be durable before crash")
            return
        }
        #expect(durableV2.envelope(releaseE.id) == releaseE)
        let durableVersionLabel = String(
            data: durableV2.recordVersion(releaseE.id)?.data ?? Data(),
            encoding: .utf8) ?? "?"
        let expectedVersionLabel = String(
            data: independentV2.data,
            encoding: .utf8) ?? "?"
        #expect(
            durableV2.recordVersion(releaseE.id) == independentV2,
            "durable=\(durableVersionLabel) expected=\(expectedVersionLabel)")
        let crashedJournal = try loadedJournal(from: journalURL)
        #expect(crashedJournal.dependency(releaseE.id)?.sourceOffered?.recordVersion
                == sourceV1,
                "crash before journal rejection must retain the exact stale V1 offer")

        // Restart pre-push must treat V2 as an independent generation: retain the edge,
        // rebase E's CAS to V2, and durably retry E. Cancel before any backend result so
        // this assertion cannot accidentally borrow an acceptance receipt.
        let cancelling = CaptureCancellingTransport(backend)
        let restartedLibrary = Library()
        restartedLibrary.envelopes = current
        let rebasing = engine(
            backend: cancelling,
            library: restartedLibrary,
            sealer: sealer,
            device: Self.deviceB,
            directory: directory)
        if case .halted = rebasing.state,
           let action = rebasing.recoveryAction {
            rebasing.performRecovery(action)
        }
        #expect(await rebasing.sync() == .disabled)
        let rebasedWire = try #require(cancelling.capturedBatches.only?.only)
        #expect(rebasedWire.id == releaseE.id)
        #expect(rebasedWire.recordVersion == independentV2,
                "the retry must be conditionally rebased to independent E/V2")
        #expect(try WireCodec.open(rebasedWire, using: sealer) == releaseE)
        let rebasedJournal = try loadedJournal(from: journalURL)
        #expect(rebasedJournal.dependency(releaseE.id) != nil)
        #expect(rebasedJournal.dependency(releaseE.id)?.sourceOffered?.recordVersion
                == independentV2)

        // Only a returned acceptance of that V2-conditioned retry mints V3. The engine
        // then rereads current primary state and may finally prune the ordered edge.
        let accepting = engine(
            backend: backend,
            library: restartedLibrary,
            sealer: sealer,
            device: Self.deviceB,
            directory: directory)
        _ = await accepting.sync()
        let acceptedV3 = try #require(
            backend.snapshot.first(where: { $0.id == releaseE.id })?.recordVersion)
        #expect(acceptedV3 != independentV2)
        #expect(accepting.agreedBase.recordVersion(releaseE.id) == acceptedV3)
        let completed = try loadedJournal(from: journalURL)
        #expect(completed.dependency(releaseE.id) == nil)
        #expect(completed.pending(confirmed: accepting.agreedBase).isEmpty)
    }

    @Test func recoveryUnionPreservesOpaqueFutureCarrierAcrossNewerStageAndRestart()
        throws
    {
        let directory = try directory("journal-future-carrier-union")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let futureKey = "contentConflict.v2." + String(repeating: "d", count: 64)
        let futureValue = CanonicalJSON.Value.object([
            "version": .int(2),
            "opaque": .array([.string("future payload"), .int(17)]),
        ])
        var olderWithFuture = scenario.survivor
        olderWithFuture.x[futureKey] = futureValue
        var newerWithoutFuture = scenario.survivor
        newerWithoutFuture.hlc = HLC(
            wallMs: scenario.survivor.hlc.wallMs + 1,
            counter: 0,
            device: Self.deviceB)

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: olderWithFuture,
            conflictCopies: [])
        try journal.stageConflictDependency(
            source: newerWithoutFuture,
            conflictCopies: [])

        #expect(journal.dependency(scenario.survivor.id)?
            .sourceSnapshot.x[futureKey] == futureValue,
                "a newer known-version source cannot erase opaque future causal evidence")
        try SyncJournalFile.write(
            journal, to: journalURL, temporaryDirectory: directory)
        let persisted = try loadedJournal(from: journalURL)
        #expect(persisted.dependency(scenario.survivor.id)?
            .sourceSnapshot.x[futureKey] == futureValue,
                "the strict v2 journal must preserve the opaque member across restart")
    }

    @Test func equalHLCDependencyRestageAndReconcilePreserveOlderOpaqueFutureMember()
        throws
    {
        let directory = try directory("equal-hlc-future-carrier-union")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let futureKey = "contentConflict.v2." + String(repeating: "e", count: 64)
        let futureValue = CanonicalJSON.Value.object([
            "version": .int(2),
            "opaque": .utf8(Data("must survive equal-HLC replacement".utf8)),
        ])
        var olderWithFuture = scenario.survivor
        olderWithFuture.x[futureKey] = futureValue
        let sameHLCWithoutFuture = scenario.survivor
        #expect(olderWithFuture.hlc == sameHLCWithoutFuture.hlc)
        #expect(sameHLCWithoutFuture.x[futureKey] == nil)

        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: olderWithFuture,
            conflictCopies: [])
        try journal.stageConflictDependency(
            source: sameHLCWithoutFuture,
            conflictCopies: [])

        #expect(journal.dependency(scenario.survivor.id)?
            .sourceSnapshot.x[futureKey] == futureValue,
                "equal HLC is not authority to erase opaque causal evidence")
        try journal.reconcileDependencies(
            current: [sameHLCWithoutFuture.id: sameHLCWithoutFuture],
            confirmed: SyncBase())
        #expect(journal.dependency(scenario.survivor.id)?
            .sourceSnapshot.x[futureKey] == futureValue,
                "ordinary primary reread may refresh known fields but not erase v2")
        try SyncJournalFile.write(
            journal,
            to: journalURL,
            temporaryDirectory: directory)
        let restarted = try loadedJournal(from: journalURL)
        #expect(restarted.dependency(scenario.survivor.id)?
            .sourceSnapshot.x[futureKey] == futureValue)
    }

    @Test func v3DecoderRejectsUnknownNestedDependencyAndRequirementFields() throws {
        for target in ["dependency", "requirement"] {
            var fixture = try validSecureCarrierJournalObject()
            if target == "dependency" {
                try mutateDependency(in: &fixture.object, scenario: fixture.scenario) {
                    $0["futureField"] = true
                }
            } else {
                try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
                    $0["futureField"] = true
                }
            }
            try expectUnreadableJournal(fixture.object, label: "unknown-\(target)-field")
        }
    }

    @Test func v3DecoderRejectsUnknownNestedStoredOfferedField() throws {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "losing edit")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "winning edit")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        let provenance = try #require(SyncMerge.conflictCopyProvenance(in: copy))
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: source,
            conflictCopies: [copy])
        journal.markOffered(
            journal.pending(confirmed: SyncBase()),
            confirmed: SyncBase())
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(journal))
                as? [String: Any])
        var dependencies = try #require(
            object["conflictDependencies"] as? [String: Any])
        let sourceKey = SyncBase.key(source.id)
        var dependency = try #require(dependencies[sourceKey] as? [String: Any])
        var requirements = try #require(
            dependency["requirements"] as? [String: Any])
        var requirement = try #require(
            requirements[provenance.fingerprint] as? [String: Any])
        var offered = try #require(requirement["offered"] as? [String: Any])
        offered["futureNestedField"] = ["must": "fail closed"]
        requirement["offered"] = offered
        requirements[provenance.fingerprint] = requirement
        dependency["requirements"] = requirements
        dependencies[sourceKey] = dependency
        object["conflictDependencies"] = dependencies

        try expectUnreadableJournal(object, label: "unknown-stored-offered-field")
    }

    @Test func v3DecoderRejectsUnknownFieldBesideAcceptedPrerequisiteReceipt() throws {
        var fixture = try acceptedSecureCarrierReceiptJournalObject()
        try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
            #expect($0["acceptedRecordVersion"] != nil)
            $0["futureReceiptField"] = ["must": "fail closed"]
        }

        try expectUnreadableJournal(
            fixture.object,
            label: "unknown-accepted-receipt-sibling-field")
    }

    @Test func v3DecoderRejectsAcceptedPrerequisiteReceiptWithoutImmutableSnapshot()
        throws
    {
        var fixture = try acceptedSecureCarrierReceiptJournalObject()
        try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
            #expect($0["acceptedRecordVersion"] != nil)
            #expect($0["snapshot"] != nil)
            $0.removeValue(forKey: "snapshot")
        }

        try expectUnreadableJournal(
            fixture.object,
            label: "accepted-receipt-without-snapshot")
    }

    @Test func v3DecoderRejectsMalformedAcceptedPrerequisiteRecordVersion() throws {
        var fixture = try acceptedSecureCarrierReceiptJournalObject()
        try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
            #expect($0["acceptedRecordVersion"] != nil)
            $0["acceptedRecordVersion"] = [
                "version": NSNull(),
                "envelope": $0["snapshot"] as Any,
            ]
        }

        try expectUnreadableJournal(
            fixture.object,
            label: "malformed-accepted-record-version")
    }

    @Test func v2DecoderRejectsAcceptedPrerequisiteReceiptFromSchema3() throws {
        var fixture = try acceptedSecureCarrierReceiptJournalObject()
        fixture.object["schemaVersion"] = 2

        try expectUnreadableJournal(
            fixture.object,
            label: "schema-2-with-accepted-receipt")
    }

    @Test func v3DecoderRejectsUntrackedUnderstoodCarrierInSourceSnapshot() throws {
        var fixture = try validSecureCarrierJournalObject()
        let second = try secondSecureCarrier(for: fixture.scenario)
        var untrackedUnion = fixture.scenario.survivor
        untrackedUnion.x[second.variant.extensionKey] =
            second.source.x[second.variant.extensionKey]
        try mutateDependency(in: &fixture.object, scenario: fixture.scenario) {
            $0["sourceSnapshot"] = try untrackedUnion.canonicalData()
                .base64EncodedString()
        }

        try expectUnreadableJournal(
            fixture.object,
            label: "untracked-understood-source-carrier")
    }

    @Test func v3DecoderRejectsOfferedPrerequisiteWithoutFrozenSnapshot() throws {
        var fixture = try validSecureCarrierJournalObject()
        let copy = try materializedConflictCopy(for: fixture.scenario)
        try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
            #expect($0["snapshot"] == nil)
            $0["offered"] = [
                "envelope": try copy.canonicalData().base64EncodedString(),
                "generation": 1,
            ]
        }

        try expectUnreadableJournal(
            fixture.object,
            label: "offered-prerequisite-without-snapshot")
    }

    @Test func v3DecoderRejectsNonDeterministicConflictCopyID() throws {
        var fixture = try validSecureCarrierJournalObject()
        try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
            $0["copyID"] = UUID().uuidString.lowercased()
        }
        try expectUnreadableJournal(fixture.object, label: "non-deterministic-copy-id")
    }

    @Test func v3DecoderRejectsCarrierKeyThatDoesNotMatchRequirementFingerprint() throws {
        var fixture = try validSecureCarrierJournalObject()
        try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
            $0["carrierKey"] = SyncMerge.contentConflictV1ExtensionPrefix
                + String(repeating: "c", count: 64)
        }
        try expectUnreadableJournal(fixture.object, label: "carrier-key-mismatch")
    }

    @Test func v3DecoderRejectsCarrierValueAbsentFromSourceSnapshot() throws {
        var fixture = try validSecureCarrierJournalObject()
        try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
            $0["carrierValue"] = (try? CanonicalJSON.data(.null).base64EncodedString())
        }
        try expectUnreadableJournal(fixture.object, label: "carrier-value-mismatch")
    }

    @Test func v3DecoderRejectsCarrierCopyWithMismatchedProvenanceTuple() throws {
        var fixture = try validSecureCarrierJournalObject()
        let variant = fixture.scenario.variant
        let wrongSource = UUID()
        let occupant = SyncEnvelope.plain(
            Snippet(
                id: variant.copyID,
                name: "wrong provenance occupant",
                keyword: "wrong-provenance",
                content: "must not authenticate the dependency",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)),
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [
                SyncMerge.plainConflictCopyExtensionKey:
                    SyncMerge.conflictCopyProvenance(
                        sourceID: wrongSource,
                        fingerprint: variant.fingerprint),
            ])
        try mutateRequirement(in: &fixture.object, scenario: fixture.scenario) {
            $0["snapshot"] = try? occupant.canonicalData().base64EncodedString()
        }
        try expectUnreadableJournal(fixture.object, label: "carrier-copy-tuple-mismatch")
    }

    @Test func v3DecoderRejectsSourceOfferThatStillCarriesUnderstoodConflict() throws {
        var fixture = try validSecureCarrierJournalObject()
        let carrying = fixture.scenario.survivor
        try mutateDependency(in: &fixture.object, scenario: fixture.scenario) {
            $0["sourceOffered"] = [
                "envelope": try? carrying.canonicalData().base64EncodedString() as Any,
                "generation": 1,
            ]
        }
        try expectUnreadableJournal(fixture.object, label: "carrier-bearing-source-offer")
    }

    @Test func futureJournalWithDependencyGraphIsNotDecodedOrRewritten() throws {
        let directory = try directory("journal-future")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let future = Data(
            "{\"schemaVersion\":6,\"entries\":{},\"conflictDependencies\":{}}".utf8)
        try future.write(to: journalURL)

        guard case .tooNew(let version) = SyncJournalFile.load(from: journalURL) else {
            Issue.record("a future dependency schema must fail closed")
            return
        }
        #expect(version == 6)
        #expect(try Data(contentsOf: journalURL) == future)
    }

    private func plainCopyReceiptScenario() throws -> (
        source: SyncEnvelope,
        c0: SyncEnvelope,
        c1: SyncEnvelope
    ) {
        let ancestor = envelope(
            device: Self.deviceA,
            revision: 100,
            body: "receipt ancestor")
        let losing = envelope(
            device: Self.deviceA,
            revision: 200,
            body: "immutable C0")
        let winning = envelope(
            device: Self.deviceB,
            revision: 300,
            body: "carrier-free source E")
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losing,
            remote: winning)
        let source = try #require(merge.survivor)
        let c0 = try #require(merge.conflictCopies.only)
        var c1Fields = try #require(c0.fields)
        c1Fields.name = "User-edited deterministic copy C1"
        c1Fields.content = Data("later same-provenance C1".utf8)
        c1Fields.updatedAt = Date(timeIntervalSince1970: 0.4)
        let c1 = SyncEnvelope(
            id: c0.id,
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            secure: false,
            deleted: false,
            fields: c1Fields,
            x: c0.x)
        #expect(SyncMerge.matchesConflictCopyProvenance(
            c1,
            sourceID: source.id,
            fingerprint: try #require(
                SyncMerge.conflictCopyProvenance(in: c0)?.fingerprint)))
        #expect(c1 != c0)
        return (source, c0, c1)
    }

    private func receiptVault(
        x: [String: JSONValue] = [:],
        records: [VaultRecord] = []
    ) -> VaultDocument {
        VaultDocument(
            kid: SecureConflictVariantFixture.vaultKID,
            vaultSalt: "3Qk5Yy1xQfC0Zr8mHn2pQw",
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: "Yh8pQm4kL1sTz0Wc7Vb9Ng"),
            x: x,
            records: records)
    }

    private func legacyV1JournalData(entries: [SyncEnvelope]) throws -> Data {
        var stored: [String: Any] = [:]
        for envelope in entries {
            stored[SyncBase.key(envelope.id)] = [
                "desired": try envelope.canonicalData().base64EncodedString(),
                "generation": 1,
                "modifiedAt": 0.0,
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "entries": stored,
            ],
            options: [.sortedKeys])
    }

    private func legacyV1JournalData(
        desired: SyncEnvelope,
        offered: SyncEnvelope
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "entries": [
                    SyncBase.key(desired.id): [
                        "desired": try desired.canonicalData().base64EncodedString(),
                        "offered": [
                            "envelope": try offered.canonicalData().base64EncodedString(),
                            "generation": 1,
                        ],
                        "generation": 2,
                        "modifiedAt": 0.0,
                    ],
                ],
            ],
            options: [.sortedKeys])
    }

    private func loadedJournal(from url: URL) throws -> SyncJournal {
        guard case .loaded(let journal) = SyncJournalFile.load(from: url) else {
            throw ConflictDependencyFixtureFailure.expectedReadableJournal
        }
        return journal
    }

    private func validSecureCarrierJournalObject() throws -> (
        scenario: SecureConflictVariantFixture.Scenario,
        object: [String: Any]
    ) {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        let encoded = try JSONEncoder().encode(journal)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        return (scenario, object)
    }

    private func acceptedSecureCarrierReceiptJournalObject() throws -> (
        scenario: SecureConflictVariantFixture.Scenario,
        object: [String: Any]
    ) {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let copy = try materializedConflictCopy(for: scenario)
        var journal = SyncJournal()
        try journal.stageConflictDependency(
            source: scenario.survivor,
            conflictCopies: [])
        try journal.recordConflictCopyEvidence([copy])
        var confirmed = SyncBase(journalEstablished: true)
        #expect(journal.pending(confirmed: confirmed) == [copy])
        journal.markOffered([copy], confirmed: confirmed)
        let acceptedVersion = SyncRecordVersion(Data("accepted-secure-C0".utf8))
        confirmed.recordConfirmed(copy, recordVersion: acceptedVersion)
        journal.acknowledge([copy.id], confirmed: confirmed)
        let requirement = try #require(
            journal.dependency(scenario.survivor.id)?
                .requirements[scenario.variant.fingerprint])
        #expect(requirement.snapshot == copy)
        #expect(requirement.offered == nil)
        #expect(requirement.acceptedRecordVersion == acceptedVersion)
        let encoded = try JSONEncoder().encode(journal)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        return (scenario, object)
    }

    private func materializedConflictCopy(
        for scenario: SecureConflictVariantFixture.Scenario
    ) throws -> SyncEnvelope {
        try materializedConflictCopy(
            source: scenario.survivor,
            variant: scenario.variant,
            keyring: scenario.keyring)
    }

    private func materializedConflictCopy(
        source: SyncEnvelope,
        variant: SyncMerge.SecureContentConflictVariant,
        keyring: SnippetCrypto.Keyring
    ) throws -> SyncEnvelope {
        let sourceRecord = try #require(
            try SyncLibraryProjection.vaultRecord(from: source))
        let result = try SyncSecureConflictMaterializer.materialize(
            envelope: source,
            keyring: keyring,
            vaultKID: SecureConflictVariantFixture.vaultKID,
            existingSnippets: [],
            existingRecords: [sourceRecord])
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: result.records,
            deviceID: source.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        return try #require(projected[variant.copyID])
    }

    private func secondSecureCarrier(
        for scenario: SecureConflictVariantFixture.Scenario
    ) throws -> (
        source: SyncEnvelope,
        variant: SyncMerge.SecureContentConflictVariant
    ) {
        let plaintext = Data("second losing secure revision".utf8)
        let seal = try SnippetCrypto.seal(
            plaintext,
            for: SnippetCrypto.RecordContext(
                scopeID: SecureConflictVariantFixture.vaultKID,
                recordID: scenario.losingSource.id),
            keyring: scenario.keyring)
        var fields = try #require(scenario.losingSource.fields)
        fields.content = Data(seal.utf8)
        fields.updatedAt = Date(timeIntervalSince1970: 0.25)
        var extensions = scenario.losingSource.x
        extensions[SyncEnvelope.vaultContentHashExtensionKey] = .string(
            SnippetCrypto.contentHash(of: plaintext, keyring: scenario.keyring))
        let losing = SyncEnvelope(
            id: scenario.losingSource.id,
            hlc: HLC(wallMs: 250, counter: 0, device: "ccccccc3"),
            origin: "ccccccc3",
            secure: true,
            deleted: false,
            fields: fields,
            x: extensions)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: scenario.ancestor,
            local: losing,
            remote: scenario.winningSource)
        let source = try #require(merge.survivor)
        return (
            source: source,
            variant: try #require(
                SyncMerge.secureContentConflictVariants(in: source).only))
    }

    private func mutateDependency(
        in object: inout [String: Any],
        scenario: SecureConflictVariantFixture.Scenario,
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws {
        var dependencies = try #require(
            object["conflictDependencies"] as? [String: Any])
        let sourceKey = SyncBase.key(scenario.survivor.id)
        var dependency = try #require(dependencies[sourceKey] as? [String: Any])
        try mutate(&dependency)
        dependencies[sourceKey] = dependency
        object["conflictDependencies"] = dependencies
    }

    private func mutateRequirement(
        in object: inout [String: Any],
        scenario: SecureConflictVariantFixture.Scenario,
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws {
        try mutateDependency(in: &object, scenario: scenario) { dependency in
            var requirements = try #require(
                dependency["requirements"] as? [String: Any])
            var requirement = try #require(
                requirements[scenario.variant.fingerprint] as? [String: Any])
            try mutate(&requirement)
            requirements[scenario.variant.fingerprint] = requirement
            dependency["requirements"] = requirements
        }
    }

    private func expectUnreadableJournal(
        _ object: [String: Any],
        label: String
    ) throws {
        let directory = try directory("decoder-\(label)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url)
        guard case .unreadable = SyncJournalFile.load(from: url) else {
            Issue.record("sync-journal decoder accepted \(label)")
            return
        }
    }
}

private enum ConflictDependencyFixtureFailure: Error {
    case expectedReadableJournal
    case injectedPostApplyCrash
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
