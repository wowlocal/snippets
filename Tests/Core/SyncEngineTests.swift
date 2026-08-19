import CryptoKit
import Foundation
import Testing
@testable import SnippetsCore

/// The sync loop, driven entirely by `InMemoryTransport`.
///
/// The wire format cannot change once a second device has spoken it, so every behaviour
/// that decides whether user data survives has to be settled while it is still free to
/// change. All of these provoke conditions that are painful to arrange against a real
/// backend and trivial here: a rejected batch, an invalidated cursor, an undecryptable
/// record, a backend that suddenly reports an empty library.
@MainActor
@Suite("Sync engine")
struct SyncEngineTests {

    // MARK: - Fixtures

    /// A library the engine can drive, standing in for `SnippetStore` + the vault.
    private final class FakeLibrary: SyncLibraryAccess {
        var envelopes: [UUID: SyncEnvelope] = [:]
        var applied: [[SyncEnvelope]] = []
        var throwOnRead: (any Error)?
        var onApply: (([SyncEnvelope]) -> Void)?

        private(set) var lastAgreedBase = SyncBase()

        func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
            if let throwOnRead { throw throwOnRead }
            lastAgreedBase = agreedBase
            return envelopes
        }

        /// Ids this fake temporarily refuses to file, standing in for a secure record whose
        /// vault has not arrived yet. A different vault uses `incompatibleIDs` below and
        /// produces a sticky halt after compatible records apply.
        var deferIDs: Set<UUID> = []
        var incompatibleIDs: Set<UUID> = []

        func classifyRemote(_ incoming: [SyncEnvelope]) -> RemoteClassification {
            var applicable: [SyncEnvelope] = []
            var deferred: [UUID] = []
            var incompatible: [UUID] = []
            for envelope in incoming {
                if deferIDs.contains(envelope.id) {
                    deferred.append(envelope.id)
                } else if incompatibleIDs.contains(envelope.id) {
                    incompatible.append(envelope.id)
                } else {
                    applicable.append(envelope)
                }
            }
            return RemoteClassification(
                applicable: applicable, deferredIDs: deferred,
                incompatibleVaultIDs: incompatible)
        }

        func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
            applied.append(incoming)
            var changed: [UUID] = []
            var deferred: [UUID] = []
            for envelope in incoming {
                guard !deferIDs.contains(envelope.id) else {
                    deferred.append(envelope.id)
                    continue
                }
                if envelope.deleted { envelopes[envelope.id] = nil } else { envelopes[envelope.id] = envelope }
                changed.append(envelope.id)
            }
            onApply?(incoming)
            return ApplyOutcome(changedIDs: changed, deferredIDs: deferred)
        }

        func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
    }

    private func envelope(
        _ id: UUID, name: String, content: String = "body", ms: UInt64 = 1_000,
        secure: Bool = false, deleted: Bool = false
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: ms, counter: 0, device: "aaaaaaa1"),
            origin: "aaaaaaa1",
            secure: secure,
            deleted: deleted,
            fields: deleted ? nil : SyncEnvelope.Fields(
                name: name, keyword: name, content: Data(content.utf8), tags: [],
                isEnabled: true, isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)))
    }

    private struct Harness {
        let transport: InMemoryTransport
        let library: FakeLibrary
        let engine: SyncEngine
        let sealer: SnippetCryptoSealer
        let dir: URL
    }

    private func harness() throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let transport = InMemoryTransport()
        let library = FakeLibrary()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test")
        let engine = SyncEngine(
            transport: transport, library: library, sealer: sealer, device: "aaaaaaa1",
            baseURL: dir.appendingPathComponent("base.json"),
            stateURL: dir.appendingPathComponent("state.json"),
            lockURL: dir.appendingPathComponent("library.lock"),
            temporaryDirectory: dir)
        return Harness(transport: transport, library: library, engine: engine, sealer: sealer, dir: dir)
    }

    // MARK: - The happy path, and what it must not do twice

    @Test func localChangesArePushedAndThenNotPushedAgain() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        h.library.envelopes[id] = envelope(id, name: "a")
        _ = await h.engine.sync()

        #expect(await h.transport.submittedBatches.count == 1)
        #expect(h.engine.agreedBase.envelope(id) != nil)

        // The second round must be silent. A device that re-pushes unchanged records
        // makes two devices trade writes forever and burns backend quota doing nothing.
        _ = await h.engine.sync()
        #expect(await h.transport.submittedBatches.count == 1, "an unchanged library must not be pushed again")
        #expect(h.library.lastAgreedBase.envelope(id) != nil,
                "projection must receive the engine's live ancestor, not re-read a stale file")
    }

    @Test func cancellationAfterBackendAcceptanceDoesNotBlessTheWriteLocally() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        let transport = InMemoryTransport(sleeper: { _ in
            entered.continuation.yield()
            var iterator = released.stream.makeAsyncIterator()
            _ = await iterator.next()
            // Intentionally ignore cancellation. CloudKit may finish an operation that
            // was already in flight; the engine's post-await barrier must still hold.
        })
        transport.configure { $0.latency = .seconds(1) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = FakeLibrary()
        let id = UUID()
        library.envelopes[id] = envelope(id, name: "accepted while stopping")
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test")
        let engine = SyncEngine(
            transport: transport, library: library, sealer: sealer, device: "aaaaaaa1",
            baseURL: dir.appendingPathComponent("base.json"),
            stateURL: dir.appendingPathComponent("state.json"),
            lockURL: dir.appendingPathComponent("library.lock"),
            temporaryDirectory: dir)

        var enteredIterator = entered.stream.makeAsyncIterator()
        let round = Task { await engine.sync() }
        _ = await enteredIterator.next()
        round.cancel()
        released.continuation.yield()
        _ = await round.value

        #expect(transport.snapshot.count == 1,
                "the simulated backend deliberately completed the cancelled submit")
        #expect(engine.agreedBase.envelope(id) == nil,
                "a cancelled round must not record a backend write as locally agreed")
        #expect(engine.state == .disabled)
    }

    @Test func remoteChangesAreApplied() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        let remote = envelope(id, name: "fromElsewhere")
        await h.transport.seed([try WireCodec.seal(remote, using: h.sealer)])

        _ = await h.engine.sync()
        #expect(h.library.envelopes[id]?.fields?.name == "fromElsewhere")
    }

    /// A local delete has to travel as an explicit tombstone. Sending nothing would be
    /// indistinguishable from "this device has not seen it", and the merge treats those
    /// as opposites for good reason.
    @Test func aLocalDeleteIsPushedAsATombstoneNotAsAnOmission() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        h.library.envelopes[id] = envelope(id, name: "doomed")
        _ = await h.engine.sync()

        h.library.envelopes[id] = nil
        _ = await h.engine.sync()

        let batches = await h.transport.submittedBatches
        #expect(batches.count == 2)
        let tombstone = try WireCodec.open(try #require(batches.last?.first), using: h.sealer)
        #expect(tombstone.deleted)
        #expect(tombstone.fields == nil, "a tombstone must carry no content")
    }

    /// The local library can change while CloudKit is accepting the snapshot captured
    /// at the start of a round. When that snapshot contains a newly created record and
    /// the user deletes it during the submit, the fetch immediately echoes the accepted
    /// live record back. The agreed base now proves the local absence is a deletion; it
    /// must not be mistaken for a fresh install that simply has not seen the record yet.
    @Test func deletingWhileCreateUploadIsInFlightDoesNotResurrectTheSnippet() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        let transport = InMemoryTransport(sleeper: { _ in
            entered.continuation.yield()
            var iterator = released.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        transport.configure { $0.latency = .seconds(1) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-delete-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = FakeLibrary()
        let id = UUID()
        library.envelopes[id] = envelope(id, name: "delete while uploading")
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test")
        let engine = SyncEngine(
            transport: transport, library: library, sealer: sealer, device: "aaaaaaa1",
            baseURL: dir.appendingPathComponent("base.json"),
            stateURL: dir.appendingPathComponent("state.json"),
            lockURL: dir.appendingPathComponent("library.lock"),
            temporaryDirectory: dir)

        var enteredIterator = entered.stream.makeAsyncIterator()
        let round = Task { await engine.sync() }
        _ = await enteredIterator.next()       // submit captured the live record
        library.envelopes[id] = nil            // the user deletes it during the await
        released.continuation.yield()
        _ = await enteredIterator.next()       // fetch is about to echo the accepted live record
        released.continuation.yield()
        _ = await round.value

        #expect(library.envelopes[id] == nil,
                "the submit echo must not resurrect a record deleted during the round")
        #expect(library.applied.last?.first?.deleted == true,
                "the agreed ancestor must turn the local absence into an explicit tombstone")

        // The backend still holds the live version accepted by the first submit. The
        // next round must therefore carry the deletion outward, not merely hide it in
        // this process.
        transport.configure { $0.latency = .zero }
        _ = await engine.sync()
        let batches = transport.submittedBatches
        let tombstone = try WireCodec.open(try #require(batches.last?.first), using: sealer)
        #expect(tombstone.deleted)
        #expect(library.envelopes[id] == nil)
    }

    // MARK: - Ordering

    /// Push must happen before apply. Fetching first and applying would rewrite local
    /// records before this device's own changes had left it, and a crash in between
    /// loses them with nothing to recover from.
    @Test func aRoundPushesBeforeItApplies() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let mine = UUID(), theirs = UUID()
        h.library.envelopes[mine] = envelope(mine, name: "mine")
        await h.transport.seed([try WireCodec.seal(envelope(theirs, name: "theirs"), using: h.sealer)])

        _ = await h.engine.sync()

        // If apply had run first, `mine` would have been in the library at apply time
        // but not yet submitted. It was submitted, so the push came first.
        #expect(await h.transport.submittedBatches.count == 1)
        #expect(h.library.envelopes[theirs] != nil)
    }

    // MARK: - Rejections

    @Test func aRetryableRejectionLeavesTheRecordPendingForTheNextRound() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        h.library.envelopes[id] = envelope(id, name: "a")
        await h.transport.configure { $0.rejectRecords[id] = .rateLimited(retryAfter: 1) }

        _ = await h.engine.sync()
        #expect(h.engine.agreedBase.envelope(id) == nil, "a rejected record must not be recorded as agreed")

        // Cleared, it goes through — which is the whole point of not recording it.
        await h.transport.configure { $0.rejectRecords = [:] }
        _ = await h.engine.sync()
        #expect(h.engine.agreedBase.envelope(id) != nil)
    }

    @Test func aPermanentRejectionNeedsAttentionWithoutCreatingASafetyHalt() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        h.library.envelopes[id] = envelope(id, name: "a")
        await h.transport.configure { $0.rejectRecords[id] = .permanent(detail: "schema rejected") }

        let state = await h.engine.sync()
        #expect(!state.isHalted)

        guard case .needsAttention(let detail) = state else {
            Issue.record("expected .needsAttention, got \(state)")
            return
        }

        // The reason has to name what happened. This branch used to report
        // `manifestIntegrityFailed` — documented as "the backend was rolled back,
        // truncated, or tampered with" — for every non-retryable rejection there is. A
        // CloudKit container whose schema had simply never been deployed to Production
        // therefore told the user their backend had been tampered with, and sent them
        // looking for corruption that was not there.
        // The backend's own words remain actionable without a scary, durable safety
        // stop. A later manual round can retry after schema/quota/payload repair.
        #expect(detail == "schema rejected")
    }

    @Test func anAuthenticationFailureAsksForCredentialsInsteadOfBackingOff() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        h.library.envelopes[id] = envelope(id, name: "a")
        await h.transport.configure { $0.rejectEverything = .authenticationRequired(detail: "token expired") }

        let state = await h.engine.sync()
        if case .needsAuthentication = state {} else {
            Issue.record("expected .needsAuthentication, got \(state)")
        }
    }

    /// Submit and fetch must classify the same permanent refusal as non-sticky attention,
    /// rather than making an undeployed CloudKit schema look like a sign-in problem or a
    /// destructive safety anomaly depending on which half encountered it.
    @Test func aPermanentFetchRejectionNeedsAttentionWithoutCreatingAStickyHalt() async throws {
        final class RejectingFetchTransport: SyncTransport, @unchecked Sendable {
            let inner = InMemoryTransport()

            var identifier: String { inner.identifier }
            var supportsPush: Bool { inner.supportsPush }
            var pollInterval: TimeInterval { inner.pollInterval }
            var events: AsyncStream<SyncTransportEvent> { inner.events }

            func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
                throw SyncTransportFailure.rejected(.permanent(detail: "schema missing"))
            }

            func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
                try await inner.submit(records, at: cursor)
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transport = RejectingFetchTransport()
        let library = FakeLibrary()
        let engine = SyncEngine(
            transport: transport, library: library,
            sealer: SnippetCryptoSealer(
                keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test"),
            device: "aaaaaaa1", baseURL: dir.appendingPathComponent("base.json"),
            stateURL: dir.appendingPathComponent("state.json"),
            lockURL: dir.appendingPathComponent("library.lock"),
            temporaryDirectory: dir)

        let state = await engine.sync()
        guard case .needsAttention(let detail) = state else {
            Issue.record("expected .needsAttention, got \(state)")
            return
        }
        #expect(detail == "schema missing")
    }

    // MARK: - Backoff

    @Test func anUnreachableBackendBacksOffAndRefusesToRunBeforeItsDeadline() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        var clock = Date(timeIntervalSince1970: 1_000)
        h.engine.now = { clock }
        let id = UUID()
        h.library.envelopes[id] = envelope(id, name: "a")
        await h.transport.configure { $0.unreachable = true }

        let first = await h.engine.sync()
        guard case .offline(let firstDeadline) = first else {
            Issue.record("expected .offline, got \(first)"); return
        }

        // Still inside the window: the round must not even be attempted.
        let batchesBefore = await h.transport.submittedBatches.count
        _ = await h.engine.sync()
        #expect(await h.transport.submittedBatches.count == batchesBefore)

        // A visible Sync Now must not be a no-op. Automatic calls retain the deadline,
        // while an explicit user request is allowed one immediate attempt.
        let forced = await h.engine.sync(bypassingBackoff: true)
        #expect(await h.transport.submittedBatches.count == batchesBefore + 1)
        guard case .offline(let forcedDeadline) = forced else {
            Issue.record("the forced attempt should establish its own backoff, got \(forced)")
            return
        }
        #expect(forcedDeadline.timeIntervalSince(clock)
                > firstDeadline.timeIntervalSince(clock),
                "a failed manual attempt still advances exponential backoff")

        // Past the window, it tries again and backs off further.
        clock = forcedDeadline.addingTimeInterval(1)
        let second = await h.engine.sync()
        guard case .offline(let secondDeadline) = second else {
            Issue.record("expected .offline, got \(second)"); return
        }
        #expect(secondDeadline.timeIntervalSince(clock)
                > forcedDeadline.timeIntervalSince(Date(timeIntervalSince1970: 1_000)),
                "backoff must grow")
    }

    // MARK: - The circuit breaker

    /// The scenario this exists for: a backend that has been rolled back, truncated, or
    /// restored from an empty state, telling us to delete everything.
    @Test func aRemoteMassDeletionHaltsAndAppliesNothing() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        var ids: [UUID] = []
        for index in 0..<40 {
            let id = UUID()
            ids.append(id)
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()

        // The backend now claims almost everything is gone.
        let tombstones = try ids.prefix(30).map {
            try WireCodec.seal(envelope($0, name: "x", ms: 9_000, deleted: true), using: h.sealer)
        }
        await h.transport.seed(tombstones)

        let state = await h.engine.sync()
        #expect(state.isHalted)
        #expect(h.library.applied.isEmpty, "nothing may be applied once the guard refuses")
        #expect(h.library.envelopes.count == 40, "the library must be untouched")
    }

    @Test func userInitiatedRemoteMassDeletionDoesNotAskEveryDeviceAgain() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()

        let records = try ids.prefix(30).map { id -> WireRecord in
            var tombstone = envelope(id, name: "deleted", ms: 9_000, deleted: true)
            let ancestor = try #require(h.library.envelopes[id])
            tombstone.x[SyncEnvelope.userInitiatedDeletionExtensionKey] = .array([
                .string(try ancestor.envelopeHash())
            ])
            return try WireCodec.seal(tombstone, using: h.sealer)
        }
        await h.transport.seed(records)

        let state = await h.engine.sync()
        #expect(!state.isHalted)
        #expect(h.library.envelopes.count == 10)
        #expect(h.library.applied.flatMap { $0 }.count == 30)
    }

    @Test func localDeleteIntentIsDurableBeforeItsTombstonesLeaveTheDevice() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<12).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()

        let deletedIDs = Set(ids.prefix(8))
        for id in deletedIDs { h.library.envelopes[id] = nil }
        var consumed: Set<UUID> = []
        h.engine.onUserDeletionIntentsConsumed = { consumed.formUnion($0) }
        h.engine.noteUserInitiatedDeletions(deletedIDs)

        let state = await h.engine.sync()
        #expect(!state.isHalted)
        #expect(consumed == deletedIDs)
        guard case .loaded(let confirmed) = SyncBaseFile.load(
            from: h.dir.appendingPathComponent("base.json")) else {
            Issue.record("the accepted tombstones must be durable in the confirmed base")
            return
        }
        for id in deletedIDs {
            #expect(confirmed.envelope(id)?.carriesUserInitiatedDeletion == true)
        }
    }

    @Test func unexplainedDeletionsStillTripTheGuardBesideApprovedOnes() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()

        let records = try ids.prefix(36).enumerated().map { index, id -> WireRecord in
            var tombstone = envelope(id, name: "deleted", ms: 9_000, deleted: true)
            if index < 30 {
                let ancestor = try #require(h.library.envelopes[id])
                tombstone.x[SyncEnvelope.userInitiatedDeletionExtensionKey] = .array([
                    .string(try ancestor.envelopeHash())
                ])
            }
            return try WireCodec.seal(tombstone, using: h.sealer)
        }
        await h.transport.seed(records)

        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("six unexplained deletions among ten remaining records must stop")
            return
        }
        #expect(h.library.applied.isEmpty)
        #expect(h.library.envelopes.count == 40)

        h.engine.performRecovery(.applyRemoteDeletions)
        let recovered = await h.engine.sync()
        #expect(!recovered.isHalted,
                "the unchanged mixed batch must need exactly one confirmation")
        #expect(h.library.envelopes.count == 4)
    }

    @Test func replayedMarkedTombstonesCannotDeleteLaterRecreationsWithoutReview() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        var originalByID: [UUID: SyncEnvelope] = [:]
        for (index, id) in ids.enumerated() {
            let original = envelope(id, name: "old-\(index)", ms: 1_000)
            originalByID[id] = original
            h.library.envelopes[id] = original
        }
        _ = await h.engine.sync()

        // Recreate/update every record and let that newer generation become the
        // confirmed ancestor before the backend rolls back to the old deletions.
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "new-\(index)", ms: 5_000)
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()

        let replay = try ids.prefix(30).map { id -> WireRecord in
            let oldAncestor = try #require(originalByID[id])
            var tombstone = envelope(id, name: "deleted", ms: 2_000, deleted: true)
            tombstone.x[SyncEnvelope.userInitiatedDeletionExtensionKey] = .array([
                .string(try oldAncestor.envelopeHash())
            ])
            return try WireCodec.seal(tombstone, using: h.sealer)
        }
        await h.transport.seed(replay)

        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("an old marked tombstone must not authorize deleting a recreation")
            return
        }
        #expect(h.library.applied.isEmpty)
        #expect(h.library.envelopes.count == 40)
    }

    @Test func reviewedRemoteMassDeletionAppliesTheConfirmedBatch() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()
        h.transport.seed(try ids.prefix(30).map {
            try WireCodec.seal(
                envelope($0, name: "deleted", ms: 9_000, deleted: true),
                using: h.sealer)
        })

        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("the fixture must stop before confirmation")
            return
        }
        guard case .loaded(let stopped) = SyncStateFile.load(
            from: h.dir.appendingPathComponent("state.json")) else {
            Issue.record("the deletion review context must be durable")
            return
        }
        guard let context = stopped.halt?.recoveryContext,
              case .massDeletion(
                let liveCount,
                let requestedDeletions,
                let batchFingerprint) = context else {
            Issue.record("the deletion halt must retain typed review facts")
            return
        }
        #expect(liveCount == 40)
        #expect(requestedDeletions == 30)
        #expect(batchFingerprint.count == 64)

        h.engine.performRecovery(.applyRemoteDeletions)
        let recovered = await h.engine.sync()

        #expect(!recovered.isHalted)
        #expect(h.library.envelopes.count == 10)
        #expect(h.library.applied.flatMap { $0 }.count == 30)
    }

    @Test func changedMassDeletionSetWithTheSameCountRequiresFreshConfirmation() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()
        h.transport.seed(try ids.prefix(30).map {
            try WireCodec.seal(
                envelope($0, name: "deleted", ms: 9_000, deleted: true),
                using: h.sealer)
        })
        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("the fixture must stop before confirmation")
            return
        }
        guard case .loaded(let firstStopped) = SyncStateFile.load(
            from: h.dir.appendingPathComponent("state.json")),
              let firstContext = firstStopped.halt?.recoveryContext,
              case .massDeletion(_, _, let reviewedFingerprint) = firstContext else {
            Issue.record("the first deletion set must have a durable fingerprint")
            return
        }
        h.engine.performRecovery(.applyRemoteDeletions)

        h.transport.seed([
            try WireCodec.seal(
                envelope(ids[0], name: "restored remotely", ms: 9_001),
                using: h.sealer),
            try WireCodec.seal(
                envelope(ids[30], name: "new deletion", ms: 9_001, deleted: true),
                using: h.sealer),
        ])
        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("a changed destructive batch must ask again")
            return
        }
        #expect(h.library.envelopes.count == 40)
        #expect(h.library.applied.isEmpty)
        guard case .loaded(let stopped) = SyncStateFile.load(
            from: h.dir.appendingPathComponent("state.json")) else {
            Issue.record("the replacement review context must be durable")
            return
        }
        guard let replacementContext = stopped.halt?.recoveryContext,
              case .massDeletion(
                let liveCount,
                let requestedDeletions,
                let replacementFingerprint) = replacementContext else {
            Issue.record("the replacement deletion set must have typed review facts")
            return
        }
        #expect(liveCount == 40)
        #expect(requestedDeletions == 30)
        #expect(replacementFingerprint != reviewedFingerprint)
    }

    @Test func reviewedDeletionThatShrinksBelowThresholdRequiresFreshConfirmation() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()
        h.transport.seed(try ids.prefix(30).map {
            try WireCodec.seal(
                envelope($0, name: "deleted", ms: 9_000, deleted: true),
                using: h.sealer)
        })
        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("the fixture must first stop on the large deletion")
            return
        }
        h.engine.performRecovery(.applyRemoteDeletions)

        h.transport.seed(try ids.prefix(29).enumerated().map { index, id in
            try WireCodec.seal(
                envelope(id, name: "n\(index)", ms: 9_001), using: h.sealer)
        })
        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("a shrunken replacement batch must not inherit old authority")
            return
        }
        #expect(h.library.applied.isEmpty)
        #expect(h.library.envelopes.count == 40)
        guard case .loaded(let stopped) = SyncStateFile.load(
            from: h.dir.appendingPathComponent("state.json")),
              case .massDeletion(
                let liveCount,
                let requestedDeletions,
                _)? = stopped.halt?.recoveryContext else {
            Issue.record("the exact shrunken replacement must become the new review")
            return
        }
        #expect(liveCount == 40)
        #expect(requestedDeletions == 1)

        h.engine.performRecovery(.applyRemoteDeletions)
        #expect(!(await h.engine.sync()).isHalted)
        #expect(h.library.envelopes.count == 39)
    }

    @Test func approvedDeletionKeepsDurableFenceAcrossRestartBeforeApply() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()
        h.transport.seed(try ids.prefix(30).map {
            try WireCodec.seal(
                envelope($0, name: "deleted", ms: 9_000, deleted: true),
                using: h.sealer)
        })
        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("the fixture must first stop on the large deletion")
            return
        }

        h.engine.performRecovery(.applyRemoteDeletions)
        guard case .loaded(var stillStopped) = SyncStateFile.load(
            from: h.dir.appendingPathComponent("state.json")),
              case .massDeletion? = stillStopped.halt?.recoveryContext,
              var abandonedClaim = stillStopped.halt?.recoveryClaim else {
            Issue.record("Apply must retain the exact durable stop until commit")
            return
        }
        // The fixture still retains the first engine in this XCTest process. Replace
        // its process-local owner token to model the durable file a genuinely crashed
        // process leaves behind; the restarted engine must require takeover.
        abandonedClaim.ownerID = UUID()
        stillStopped.halt?.recoveryClaim = abandonedClaim
        try SyncStateFile.write(
            stillStopped,
            to: h.dir.appendingPathComponent("state.json"),
            temporaryDirectory: h.dir)

        let restarted = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("base.json"),
            stateURL: h.dir.appendingPathComponent("state.json"),
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        #expect(restarted.state.isHalted)

        // The original 30-record approval cannot authorize the one record still
        // deleted after the process died, even though one is below the normal guard.
        h.transport.seed(try ids.prefix(29).enumerated().map { index, id in
            try WireCodec.seal(
                envelope(id, name: "n\(index)", ms: 9_001), using: h.sealer)
        })
        #expect(restarted.recoveryAction == .reclaimRecovery)
        restarted.performRecovery(.reclaimRecovery)
        #expect(restarted.recoveryAction == .applyRemoteDeletions)
        restarted.performRecovery(.applyRemoteDeletions)
        guard case .halted(.massDeletion, _) = await restarted.sync() else {
            Issue.record("the changed post-restart batch must ask again")
            return
        }
        #expect(h.library.envelopes.count == 40)
        #expect(h.library.applied.isEmpty)
        guard case .loaded(let replacement) = SyncStateFile.load(
            from: h.dir.appendingPathComponent("state.json")),
              case .massDeletion(
                let liveCount,
                let requestedDeletions,
                _)? = replacement.halt?.recoveryContext else {
            Issue.record("the replacement one-record review must be durable")
            return
        }
        #expect(liveCount == 40)
        #expect(requestedDeletions == 1)
    }

    @Test func legacyDeletionHaltRefreshesExactFactsBeforeItCanApplyAnything() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()
        h.transport.seed(try ids.prefix(30).map {
            try WireCodec.seal(
                envelope($0, name: "deleted", ms: 9_000, deleted: true),
                using: h.sealer)
        })
        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("the fixture must stop before confirmation")
            return
        }

        // Simulate a schema-3 build rewriting the known Halt fields while omitting the
        // optional typed context it did not understand.
        let stateURL = h.dir.appendingPathComponent("state.json")
        guard case .loaded(var legacy) = SyncStateFile.load(from: stateURL) else {
            Issue.record("the halt must be durable")
            return
        }
        legacy.halt?.recoveryContext = nil
        try SyncStateFile.write(legacy, to: stateURL, temporaryDirectory: h.dir)

        let restarted = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("base.json"),
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        #expect(restarted.recoveryAction == .refreshDeletionReview)

        // A stale destructive button cannot clear or authorize the legacy stop.
        restarted.performRecovery(.applyRemoteDeletions)
        #expect(restarted.state.isHalted)
        #expect(h.library.applied.isEmpty)

        restarted.performRecovery(.refreshDeletionReview)
        guard case .halted(.massDeletion, _) = await restarted.sync() else {
            Issue.record("refresh must persist an exact batch and ask again")
            return
        }
        #expect(h.library.applied.isEmpty)
        #expect(h.library.envelopes.count == 40)
        #expect(restarted.recoveryAction == .applyRemoteDeletions)
        guard case .loaded(let refreshed) = SyncStateFile.load(from: stateURL),
              case .massDeletion? = refreshed.halt?.recoveryContext else {
            Issue.record("refresh must replace legacy text with typed review facts")
            return
        }

        restarted.performRecovery(.applyRemoteDeletions)
        #expect(!(await restarted.sync()).isHalted)
        #expect(h.library.envelopes.count == 10)
    }

    @Test func legacyDeletionRefreshNeverAppliesAShrunkenBelowThresholdBatch() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "n\(index)")
        }
        _ = await h.engine.sync()
        h.library.applied.removeAll()
        h.transport.seed(try ids.prefix(30).map {
            try WireCodec.seal(
                envelope($0, name: "deleted", ms: 9_000, deleted: true),
                using: h.sealer)
        })
        guard case .halted(.massDeletion, _) = await h.engine.sync() else {
            Issue.record("the fixture must first stop on the large deletion")
            return
        }

        let stateURL = h.dir.appendingPathComponent("state.json")
        guard case .loaded(var legacy) = SyncStateFile.load(from: stateURL) else {
            Issue.record("the halt must be durable")
            return
        }
        legacy.halt?.recoveryContext = nil
        try SyncStateFile.write(legacy, to: stateURL, temporaryDirectory: h.dir)

        // Twenty-nine remote restores leave one effective deletion — well below the
        // ordinary allowance of eight. Refresh still has read-only semantics: it must
        // bind that exact one-record set and ask separately before applying anything.
        h.transport.seed(try ids.prefix(29).map { id in
            let index = try #require(ids.firstIndex(of: id))
            return try WireCodec.seal(
                envelope(id, name: "n\(index)", ms: 9_001), using: h.sealer)
        })
        let restarted = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("base.json"),
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        restarted.performRecovery(.refreshDeletionReview)

        guard case .halted(.massDeletion, _) = await restarted.sync() else {
            Issue.record("even one remaining deletion needs exact confirmation after Refresh")
            return
        }
        #expect(h.library.applied.isEmpty)
        #expect(h.library.envelopes.count == 40)
        guard case .loaded(let refreshed) = SyncStateFile.load(from: stateURL),
              case .massDeletion(
                let liveCount,
                let requestedDeletions,
                _)? = refreshed.halt?.recoveryContext else {
            Issue.record("Refresh must persist the shrunken batch's exact facts")
            return
        }
        #expect(liveCount == 40)
        #expect(requestedDeletions == 1)

        restarted.performRecovery(.applyRemoteDeletions)
        #expect(!(await restarted.sync()).isHalted)
        #expect(h.library.envelopes.count == 39)
    }

    /// A halt is sticky, and only an explicit review clears it.
    @Test func aHaltSurvivesFurtherSyncAttemptsUntilReviewed() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.engine.halt(.massDeletion, detail: "test")
        #expect(await h.engine.sync().isHalted)
        #expect(await h.engine.sync().isHalted)

        #expect(h.engine.recoveryAction == .refreshDeletionReview)
        h.engine.performRecovery(.applyRemoteDeletions)
        #expect(h.engine.state.isHalted, "a legacy stop cannot grant destructive authority")
        h.engine.performRecovery(.refreshDeletionReview)
        #expect(!h.engine.state.isHalted)
    }

    @Test func checkAgainCannotClearPrimaryQuarantineUntilLibraryProjects() throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        var persisted = SyncState.fresh(
            deviceID: "aaaaaaa1",
            now: Date(timeIntervalSince1970: 1_000))
        persisted.halt = SyncState.Halt(
            reason: .localLibraryQuarantined,
            detail: "primary preserved",
            at: Date(timeIntervalSince1970: 1_000),
            recoveryContext: .localLibraryQuarantine)
        let stateURL = h.dir.appendingPathComponent("state.json")
        try SyncStateFile.write(persisted, to: stateURL, temporaryDirectory: h.dir)
        let restarted = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("base.json"),
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)

        h.library.throwOnRead = SyncEngineFailure(
            reason: .localLibraryQuarantined,
            detail: "still unreadable")
        restarted.performRecovery(.checkAgain)
        #expect(restarted.state.isHalted)
        guard case .loaded(let stillStopped) = SyncStateFile.load(from: stateURL) else {
            Issue.record("failed validation must retain the durable marker")
            return
        }
        #expect(stillStopped.halt?.recoveryContext == .localLibraryQuarantine)

        h.library.throwOnRead = nil
        restarted.performRecovery(.checkAgain)
        #expect(!restarted.state.isHalted)
        guard case .loaded(let recovered) = SyncStateFile.load(from: stateURL) else {
            Issue.record("successful validation must update the durable state")
            return
        }
        #expect(recovered.halt == nil)
        guard case .missing = SyncBaseFile.load(
            from: h.dir.appendingPathComponent("base.json")) else {
            Issue.record("a never-synced library must not create base.json during local review")
            return
        }
        guard case .missing = SyncJournalFile.load(
            from: h.dir.appendingPathComponent("journal.json")) else {
            Issue.record("a never-synced library must keep journal.json absent")
            return
        }
    }

    @Test func independentMarkerStillRequiresValidationAfterHaltPersistenceRecovers() throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let stateURL = h.dir.appendingPathComponent("state.json")
        let markerURL = LibraryQuarantineMarker.url(beside: stateURL)
        try LibraryQuarantineMarker.write(to: markerURL, temporaryDirectory: h.dir)
        // A directory at the destination makes the initial typed-halt write fail. Then
        // remove it to model a transient I/O problem resolving before the user reviews.
        try FileManager.default.createDirectory(
            at: stateURL, withIntermediateDirectories: false)
        let engine = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("base.json"),
            stateURL: stateURL,
            libraryQuarantineMarkerURL: markerURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        engine.reassertPrimaryLibraryQuarantine()
        #expect(engine.state.isHalted)
        try FileManager.default.removeItem(at: stateURL)

        h.library.throwOnRead = SyncEngineFailure(
            reason: .localLibraryQuarantined,
            detail: "restored candidate still unreadable")
        engine.performRecovery(.checkAgain)

        #expect(engine.state.isHalted,
                "the independent marker must still force primary validation")
        #expect(LibraryQuarantineMarker.exists(at: markerURL))

        h.library.throwOnRead = nil
        engine.performRecovery(.checkAgain)
        #expect(!engine.state.isHalted)
        #expect(!LibraryQuarantineMarker.exists(at: markerURL))
    }

    @Test func primaryRecoveryKeepsMarkerUntilItsDurableHaltClears() throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let baseURL = h.dir.appendingPathComponent("base.json")
        let journalURL = h.dir.appendingPathComponent("journal.json")
        let stateURL = h.dir.appendingPathComponent("state.json")
        let markerURL = LibraryQuarantineMarker.url(beside: stateURL)
        let lockURL = h.dir.appendingPathComponent("library.lock")
        var base = SyncBase(journalEstablished: true)
        base.upgradeToCurrentSchema()
        try SyncBaseFile.write(base, to: baseURL, temporaryDirectory: h.dir)
        try SyncJournalFile.write(SyncJournal(), to: journalURL, temporaryDirectory: h.dir)
        let originalReviewID = try LibraryQuarantineMarker.write(
            to: markerURL, temporaryDirectory: h.dir)
        var stopped = SyncState.fresh(
            deviceID: "aaaaaaa1", now: Date(timeIntervalSince1970: 10))
        stopped.halt = SyncState.Halt(
            reason: .localLibraryQuarantined,
            detail: "primary preserved",
            at: Date(timeIntervalSince1970: 10),
            recoveryContext: .localLibraryQuarantine)
        try SyncStateFile.write(stopped, to: stateURL, temporaryDirectory: h.dir)

        let recovering = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            libraryQuarantineMarkerURL: markerURL,
            lockURL: lockURL,
            temporaryDirectory: h.dir,
            stateLockTimeout: 0.01)

        // Model a peer/process holding the state transaction through the whole
        // recovery attempt. base.json may commit, but the halt cannot be cleared.
        let held = try FileGuard.acquire(at: lockURL, timeout: 1)
        recovering.performRecovery(.checkAgain)
        held.release()

        #expect(recovering.state.isHalted)
        #expect(LibraryQuarantineMarker.exists(at: markerURL),
                "the primary must remain write-blocked while its halt is durable")
        guard case .loaded(let interruptedBase) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("the reviewed recovery fence should already be durable")
            return
        }
        #expect(interruptedBase.nonDestructiveReviewID == originalReviewID)
        #expect(LibraryQuarantineMarker.reviewID(at: markerURL) == originalReviewID)

        // Retrying after the lock clears finishes the same epoch instead of minting a
        // second review identity from an identical recovery candidate.
        recovering.performRecovery(.checkAgain)
        #expect(!recovering.state.isHalted)
        #expect(!LibraryQuarantineMarker.exists(at: markerURL))
        guard case .loaded(let completedBase) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("the completed recovery fence should remain durable")
            return
        }
        #expect(completedBase.nonDestructiveReviewID == originalReviewID)
    }

    @Test func localRecoveryPreservesAConcurrentTransportHalt() throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let stateURL = h.dir.appendingPathComponent("state.json")
        let markerURL = LibraryQuarantineMarker.url(beside: stateURL)
        try LibraryQuarantineMarker.write(to: markerURL, temporaryDirectory: h.dir)
        var persisted = SyncState.fresh(
            deviceID: "aaaaaaa1", now: Date(timeIntervalSince1970: 10))
        let accountHalt = SyncState.Halt(
            reason: .accountChanged,
            detail: "review the current account",
            at: Date(timeIntervalSince1970: 10))
        persisted.halt = accountHalt
        try SyncStateFile.write(persisted, to: stateURL, temporaryDirectory: h.dir)
        let engine = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("base.json"),
            stateURL: stateURL,
            libraryQuarantineMarkerURL: markerURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)

        engine.reassertPrimaryLibraryQuarantine()
        #expect(engine.recoveryAction == .checkAgain)
        engine.performRecovery(.checkAgain)

        #expect(!LibraryQuarantineMarker.exists(at: markerURL))
        guard case .halted(.accountChanged, _) = engine.state else {
            Issue.record("local review must reveal the preserved transport halt")
            return
        }
        guard case .loaded(let after) = SyncStateFile.load(from: stateURL) else {
            Issue.record("the concurrent transport halt must remain durable")
            return
        }
        #expect(after.halt == accountHalt)
        guard case .missing = SyncBaseFile.load(
            from: h.dir.appendingPathComponent("base.json")) else {
            Issue.record("a never-synced recovery must not initialize protocol state")
            return
        }
    }

    @Test func partialLibraryRecoveryNeverInfersOldAbsencesAsDeletesAcrossResetFailure() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let aID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let bID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let cID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let tombstoneID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let deletedDuringMaterializeID = UUID(
            uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let a = envelope(aID, name: "restored A", ms: 1_000)
        let b = envelope(bID, name: "remote-only B", ms: 1_100)
        let c = envelope(cID, name: "journal-only C", ms: 1_200)
        let tombstone = envelope(
            tombstoneID, name: "deleted before quarantine", ms: 1_300, deleted: true)
        let deletedDuringMaterialize = envelope(
            deletedDuringMaterializeID,
            name: "deleted during materialization",
            ms: 1_400)

        h.transport.seed([
            try WireCodec.seal(a, using: h.sealer),
            try WireCodec.seal(b, using: h.sealer),
        ])
        var oldBase = SyncBase(
            cursor: h.transport.currentCursor,
            journalEstablished: true)
        for record in h.transport.snapshot {
            oldBase.recordConfirmed(
                try WireCodec.open(record, using: h.sealer),
                recordVersion: record.recordVersion)
        }
        // Model a journaled write whose acknowledgement was lost: it exists remotely,
        // but the old confirmed base does not yet know that.
        h.transport.seed([try WireCodec.seal(deletedDuringMaterialize, using: h.sealer)])
        let oldJournal = SyncJournal(entries: [
            SyncBase.key(cID): SyncJournal.Entry(
                desired: c, offered: nil, generation: 1,
                modifiedAt: Date(timeIntervalSince1970: 10)),
            SyncBase.key(tombstoneID): SyncJournal.Entry(
                desired: tombstone, offered: nil, generation: 1,
                modifiedAt: Date(timeIntervalSince1970: 11)),
            SyncBase.key(deletedDuringMaterializeID): SyncJournal.Entry(
                desired: deletedDuringMaterialize, offered: nil, generation: 1,
                modifiedAt: Date(timeIntervalSince1970: 12)),
        ])
        let baseURL = h.dir.appendingPathComponent("base.json")
        let journalURL = h.dir.appendingPathComponent("journal.json")
        let stateURL = h.dir.appendingPathComponent("state.json")
        let markerURL = LibraryQuarantineMarker.url(beside: stateURL)
        try SyncBaseFile.write(oldBase, to: baseURL, temporaryDirectory: h.dir)
        try SyncJournalFile.write(oldJournal, to: journalURL, temporaryDirectory: h.dir)
        try LibraryQuarantineMarker.write(to: markerURL, temporaryDirectory: h.dir)
        var stopped = SyncState.fresh(
            deviceID: "aaaaaaa1", now: Date(timeIntervalSince1970: 12))
        stopped.halt = SyncState.Halt(
            reason: .localLibraryQuarantined,
            detail: "primary preserved",
            at: Date(timeIntervalSince1970: 12),
            recoveryContext: .localLibraryQuarantine)
        try SyncStateFile.write(stopped, to: stateURL, temporaryDirectory: h.dir)
        h.library.envelopes = [aID: a]
        h.library.onApply = { incoming in
            guard incoming.contains(where: { $0.id == deletedDuringMaterializeID }) else {
                return
            }
            h.library.envelopes[deletedDuringMaterializeID] = nil
            h.library.onApply = nil
        }

        let recovering = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        recovering.performRecovery(.checkAgain)
        #expect(!recovering.state.isHalted)
        #expect(!LibraryQuarantineMarker.exists(at: markerURL))
        guard case .loaded(let fencedBase) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("review must make the non-destructive reset crash-safe")
            return
        }
        #expect(fencedBase.requiresNonDestructiveLibraryMerge)

        // Fail after C was materialized into primary and the rewritten journal reached
        // disk, but before the transport checkpoint/base reset. A relaunch must repeat
        // the preparation without losing C or manufacturing a deletion for B.
        h.transport.configure { $0.failLocalFullResets = 1 }
        let interrupted = await recovering.sync()
        #expect(!interrupted.isHalted)
        #expect(h.library.envelopes[cID] == c)
        #expect(h.library.envelopes[deletedDuringMaterializeID] == nil)
        #expect(h.library.envelopes[bID] == nil)
        #expect(h.transport.localFullResetAttempts == 1)
        guard case .loaded(let stillFenced) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("failed checkpoint reset must retain the recovery fence")
            return
        }
        #expect(stillFenced.requiresNonDestructiveLibraryMerge)

        let restarted = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        #expect(!(await restarted.sync()).isHalted)
        #expect(h.transport.localFullResetAttempts == 2)
        #expect(h.library.envelopes[aID] != nil)
        #expect(h.library.envelopes[bID] == b,
                "an old-base record absent from the partial restore must be fetched, not deleted")
        #expect(h.library.envelopes[cID] == c,
                "journal-only live intent must survive materialize-before-reset restart")

        let submitted = try h.transport.submittedBatches.flatMap { batch in
            try batch.map { try WireCodec.open($0, using: h.sealer) }
        }
        #expect(!submitted.contains { $0.id == bID && $0.deleted },
                "partial recovery absence must never become an outbound tombstone")
        #expect(submitted.contains { $0.id == tombstoneID && $0.deleted },
                "an explicit journal tombstone must survive recovery")
        #expect(submitted.contains {
            $0.id == deletedDuringMaterializeID && $0.deleted
        }, "a deletion immediately after materialization must survive reset and restart")
        #expect(h.library.envelopes[deletedDuringMaterializeID] == nil)
        let remoteTombstone = try #require(
            h.transport.snapshot.first(where: { $0.id == tombstoneID }))
        #expect((try WireCodec.open(remoteTombstone, using: h.sealer)).deleted)
        guard case .loaded(let completedBase) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("completed recovery must leave a readable base")
            return
        }
        #expect(!completedBase.requiresNonDestructiveLibraryMerge)
    }

    @Test func partialJournalMaterializationPublishesAncestorsBeforeReturning() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let appliedID = UUID(uuidString: "f1000000-0000-4000-8000-000000000001")!
        let deferredID = UUID(uuidString: "f1000000-0000-4000-8000-000000000002")!
        let applied = envelope(appliedID, name: "applied then deleted", ms: 1_000)
        let deferred = envelope(deferredID, name: "still deferred", ms: 1_100)
        let baseURL = h.dir.appendingPathComponent("base.json")
        let journalURL = h.dir.appendingPathComponent("journal.json")
        let stateURL = h.dir.appendingPathComponent("state.json")
        try SyncBaseFile.write(SyncBase(
            journalEstablished: true,
            requiresNonDestructiveLibraryMerge: true,
            nonDestructiveMergeMode: .reviewedLocalSnapshot),
            to: baseURL, temporaryDirectory: h.dir)
        try SyncJournalFile.write(SyncJournal(entries: [
            SyncBase.key(appliedID): SyncJournal.Entry(
                desired: applied, offered: nil, generation: 1,
                modifiedAt: Date(timeIntervalSince1970: 10)),
            SyncBase.key(deferredID): SyncJournal.Entry(
                desired: deferred, offered: nil, generation: 1,
                modifiedAt: Date(timeIntervalSince1970: 11)),
        ]), to: journalURL, temporaryDirectory: h.dir)
        h.library.deferIDs = [deferredID]
        h.library.onApply = { incoming in
            guard incoming.contains(where: { $0.id == appliedID }) else { return }
            h.library.envelopes[appliedID] = nil
            h.library.onApply = nil
        }

        let recovering = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        _ = await recovering.sync()

        guard case .loaded(let afterPartialApply) = SyncJournalFile.load(from: journalURL) else {
            Issue.record("partial materialization must persist its successful rows")
            return
        }
        #expect(afterPartialApply.entry(appliedID)?.reviewedLocalAncestor == applied)
        #expect(afterPartialApply.entry(deferredID)?.reviewedLocalAncestor == nil)

        _ = await recovering.sync()
        guard case .loaded(let afterDeletion) = SyncJournalFile.load(from: journalURL) else {
            Issue.record("the post-materialization deletion must become durable")
            return
        }
        #expect(afterDeletion.entry(appliedID)?.desired.deleted == true)
        #expect(afterDeletion.entry(deferredID)?.desired.deleted == false)
    }

    @Test func reviewedLibraryDeletionBeforeDelayedSyncIsNotResurrected() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID(uuidString: "abababab-abab-4bab-8bab-abababababab")!
        let reviewed = envelope(id, name: "reviewed then deleted", ms: 1_000)
        h.transport.seed([try WireCodec.seal(reviewed, using: h.sealer)])
        var oldBase = SyncBase(
            cursor: h.transport.currentCursor,
            journalEstablished: true)
        let remote = try #require(h.transport.snapshot.first)
        oldBase.recordConfirmed(
            try WireCodec.open(remote, using: h.sealer),
            recordVersion: remote.recordVersion)

        let baseURL = h.dir.appendingPathComponent("base.json")
        let journalURL = h.dir.appendingPathComponent("journal.json")
        let stateURL = h.dir.appendingPathComponent("state.json")
        let markerURL = LibraryQuarantineMarker.url(beside: stateURL)
        try SyncBaseFile.write(oldBase, to: baseURL, temporaryDirectory: h.dir)
        try SyncJournalFile.write(SyncJournal(), to: journalURL, temporaryDirectory: h.dir)
        try LibraryQuarantineMarker.write(to: markerURL, temporaryDirectory: h.dir)
        var stopped = SyncState.fresh(
            deviceID: "aaaaaaa1", now: Date(timeIntervalSince1970: 12))
        stopped.halt = SyncState.Halt(
            reason: .localLibraryQuarantined,
            detail: "review restored primary",
            at: Date(timeIntervalSince1970: 12),
            recoveryContext: .localLibraryQuarantine)
        try SyncStateFile.write(stopped, to: stateURL, temporaryDirectory: h.dir)
        h.library.envelopes = [id: reviewed]

        let recovering = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        recovering.performRecovery(.checkAgain)
        guard case .loaded(let fenced) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("Check Again must commit an exact reviewed snapshot")
            return
        }
        #expect(fenced.nonDestructiveMergeMode == .reviewedLocalSnapshot)

        // This models sync remaining off for an arbitrary interval after Check Again.
        h.library.envelopes[id] = nil
        _ = await recovering.sync()
        _ = await recovering.sync()

        let submitted = try h.transport.submittedBatches.flatMap { batch in
            try batch.map { try WireCodec.open($0, using: h.sealer) }
        }
        #expect(submitted.contains { $0.id == id && $0.deleted })
        #expect(h.library.envelopes[id] == nil,
                "the reviewed value must not be materialized over a later local deletion")
    }

    @Test func checkpointRepairLocalEditThenDeleteUsesOldConfirmedAncestor() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID(uuidString: "acacacac-acac-4cac-8cac-acacacacacac")!
        let confirmed = envelope(id, name: "confirmed", content: "server", ms: 1_000)
        let reviewed = envelope(
            id, name: "local edit before Repair", content: "local", ms: 2_000)
        h.transport.seed([try WireCodec.seal(confirmed, using: h.sealer)])

        let recoveryBase = SyncBase(
            envelopes: [SyncBase.key(id): reviewed],
            journalEstablished: true,
            requiresNonDestructiveLibraryMerge: true,
            nonDestructiveMergeMode: .reviewedLocalSnapshot,
            preRecoveryConfirmedEnvelopes: [SyncBase.key(id): confirmed])
        var recoveryJournal = SyncJournal()
        try recoveryJournal.reconcileAfterReviewedLocalSnapshot(
            current: [id: reviewed],
            reviewedSnapshot: recoveryBase,
            deviceID: "aaaaaaa1",
            now: Date(timeIntervalSince1970: 10))

        let baseURL = h.dir.appendingPathComponent("base.json")
        let journalURL = h.dir.appendingPathComponent("journal.json")
        let stateURL = h.dir.appendingPathComponent("state.json")
        try SyncBaseFile.write(recoveryBase, to: baseURL, temporaryDirectory: h.dir)
        try SyncJournalFile.write(
            recoveryJournal, to: journalURL, temporaryDirectory: h.dir)

        // The explicit review saw the unconfirmed local edit. The user then deleted
        // it before the first full fetch. A nil-CAS push conflicts with the unchanged
        // backend value, exercising the recovery merge selector directly.
        h.library.envelopes = [:]
        let recovering = SyncEngine(
            transport: h.transport,
            library: h.library,
            sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)

        _ = await recovering.sync()
        _ = await recovering.sync()

        #expect(h.library.envelopes[id] == nil,
                "an unchanged confirmed remote must not resurrect the deleted local edit")
        let submitted = try h.transport.submittedBatches.flatMap { batch in
            try batch.map { try WireCodec.open($0, using: h.sealer) }
        }
        #expect(submitted.contains { $0.id == id && $0.deleted })
        let remote = try #require(h.transport.snapshot.first(where: { $0.id == id }))
        #expect((try WireCodec.open(remote, using: h.sealer)).deleted)
    }

    // MARK: - Undecryptable records

    /// A record we cannot open is quarantined, never applied, and never silently
    /// dropped — it means either a key we do not have or a bug, and both have to be
    /// visible rather than inferred from data that quietly went missing.
    @Test func anUndecryptableRecordIsQuarantinedAndTheRoundStillCompletes() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let readable = UUID()
        let foreign = WireRecord(
            id: UUID(), rev: "1", deleted: false, blob: Data("not a sealed envelope".utf8))
        await h.transport.seed([
            try WireCodec.seal(envelope(readable, name: "readable"), using: h.sealer),
            foreign,
        ])

        let state = await h.engine.sync()
        #expect(!state.isHalted, "one bad record must not stop the others")
        #expect(h.library.envelopes[readable] != nil)
        #expect(h.library.envelopes[foreign.id] == nil, "an unreadable record must never be applied")
    }

    // MARK: - Cursors

    /// One secure record that cannot be filed must not roll back unrelated plaintext.
    /// Holding the cursor makes the backend offer the deferred record again, while
    /// recording the applied record in the base prevents it from looking locally new.
    @Test func aDeferredSecureRecordDoesNotBlockPlaintextAndIsRetried() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let plainID = UUID()
        let secureID = UUID()
        h.library.deferIDs = [secureID]
        await h.transport.seed([
            try WireCodec.seal(envelope(plainID, name: "plain"), using: h.sealer),
            try WireCodec.seal(
                envelope(secureID, name: "secure", secure: true), using: h.sealer),
        ])

        let waiting = await h.engine.sync()
        guard case .waitingForVault = waiting else {
            Issue.record("expected .waitingForVault, got \(waiting)")
            return
        }
        #expect(h.library.envelopes[plainID] != nil,
                "an unfileable secret must not roll back plaintext in the same batch")
        #expect(h.library.envelopes[secureID] == nil)
        #expect(h.engine.agreedBase.envelope(plainID) != nil)
        #expect(h.engine.agreedBase.envelope(secureID) == nil)
        #expect(h.engine.agreedBase.cursor == nil,
                "the cursor must stay before a record that still needs to be offered")

        h.library.deferIDs = []
        let recovered = await h.engine.sync()
        guard case .idle = recovered else {
            Issue.record("expected .idle after the vault became usable, got \(recovered)")
            return
        }
        #expect(h.library.envelopes[secureID] != nil)
        #expect(h.engine.agreedBase.envelope(secureID) != nil)
        #expect(h.engine.agreedBase.cursor != nil)
    }

    @Test func rivalVaultTombstonesDoNotTripDeletionGuardOrPollForever() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        // Establish six live agreed records: enough that deleting all of them would trip
        // the floor-based mass-deletion guard.
        let localIDs = (0..<6).map { _ in UUID() }
        for (index, id) in localIDs.enumerated() {
            h.library.envelopes[id] = envelope(id, name: "local-\(index)")
        }
        _ = await h.engine.sync()

        h.library.incompatibleIDs = Set(localIDs)
        let plainID = UUID()
        var remote: [WireRecord] = try localIDs.map { id in
            try WireCodec.seal(
                envelope(id, name: "rival", ms: 9_000, secure: true, deleted: true),
                using: h.sealer)
        }
        remote.append(try WireCodec.seal(
            envelope(plainID, name: "still applicable", ms: 9_001), using: h.sealer))
        h.transport.seed(remote)

        let state = await h.engine.sync()
        guard case .halted(let reason, let detail) = state else {
            Issue.record("expected rival vault halt, got \(state)")
            return
        }
        #expect(reason == .vaultUnreadable)
        #expect(detail.contains("different vault identity"))
        #expect(localIDs.allSatisfy { h.library.envelopes[$0] != nil },
                "rival tombstones must not delete or trip the mass-deletion guard")
        #expect(h.library.envelopes[plainID] != nil,
                "applicable plaintext in the same batch must land before the halt")

        let fetchesAtHalt = h.transport.fetchAttempts
        _ = await h.engine.sync()
        #expect(h.transport.fetchAttempts == fetchesAtHalt,
                "a permanent vault mismatch must halt, not re-fetch one cursor forever")

        // The stop has to outlive this engine. Before halt persistence, relaunching made
        // a fresh `.disabled` engine fetch the held cursor once, halt again, and repeat
        // that cycle on every launch despite the UI calling the stop sticky.
        let restarted = SyncEngine(
            transport: h.transport, library: h.library, sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("base.json"),
            stateURL: h.dir.appendingPathComponent("state.json"),
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        guard case .halted(let restoredReason, let restoredDetail) = restarted.state else {
            Issue.record("expected the rival-vault halt to survive restart")
            return
        }
        #expect(restoredReason == .vaultUnreadable)
        #expect(restoredDetail.contains("different vault identity"))
        _ = await restarted.sync()
        #expect(h.transport.fetchAttempts == fetchesAtHalt,
                "a restored halt must not fetch before explicit user review")

        // Review is compare-and-swap, not "set halt = nil". If a peer discovers a new
        // safety problem while this pane still displays the old one, reviewing the old
        // stop must adopt the new one rather than erase it.
        let stateURL = h.dir.appendingPathComponent("state.json")
        guard case .loaded(var peerState) = SyncStateFile.load(from: stateURL) else {
            Issue.record("expected persisted sync state before peer halt replacement")
            return
        }
        let peerHalt = SyncState.Halt(
            reason: .backendRefused, detail: "newer stop from a peer",
            at: Date(timeIntervalSince1970: 123))
        peerState.halt = peerHalt
        try SyncStateFile.write(peerState, to: stateURL, temporaryDirectory: h.dir)

        restarted.performRecovery(.checkAgain)
        #expect(restarted.state == .halted(.backendRefused, detail: peerHalt.detail),
                "reviewing an older halt must surface, not clear, the peer's newer halt")
        guard case .loaded(let stillStopped) = SyncStateFile.load(from: stateURL) else {
            Issue.record("expected the peer halt to remain persisted")
            return
        }
        #expect(stillStopped.halt == peerHalt)

        // A second review now covers the halt actually displayed and may clear it.
        restarted.performRecovery(.retrySync)
        guard case .loaded(let reviewed) = SyncStateFile.load(from: stateURL) else {
            Issue.record("expected persisted sync state after clearing the halt")
            return
        }
        #expect(reviewed.halt == nil, "the matching recovery action must clear the durable halt")
    }

    @Test func aFutureSyncStateFailsClosedBeforeTheFirstFetch() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        var future = SyncState.fresh(deviceID: "aaaaaaa1", now: Date(timeIntervalSince1970: 0))
        future.schemaVersion = SyncState.currentSchemaVersion + 1
        let stateURL = h.dir.appendingPathComponent("future-state.json")
        // The production writer always stamps the schema implemented by this build.
        // Encode directly to model bytes written by a genuinely newer build.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(
            encoder.encode(future), to: stateURL, temporaryDirectory: h.dir)

        let engine = SyncEngine(
            transport: h.transport, library: h.library, sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("future-base.json"),
            stateURL: stateURL,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        guard case .halted(let reason, _) = engine.state else {
            Issue.record("a future state file must stop this older engine")
            return
        }
        #expect(reason == .schemaTooNew)
        let fetches = h.transport.fetchAttempts
        _ = await engine.sync()
        #expect(h.transport.fetchAttempts == fetches)

        engine.performRecovery(.checkAgain)
        #expect(engine.state.isHalted, "a mismatched recovery cannot overwrite a future state schema")
    }

    @Test func anUnwritableHaltUsesTheIndependentFailClosedChannel() throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let stateDirectory = h.dir.appendingPathComponent("state-is-a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let engine = SyncEngine(
            transport: h.transport, library: h.library, sealer: h.sealer,
            device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("fallback-base.json"),
            stateURL: stateDirectory,
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        var disabledPersistentOptIn = false
        engine.onSafetyHaltPersistenceFailure = { disabledPersistentOptIn = true }

        engine.halt(.massDeletion, detail: "test persistence failure")
        #expect(engine.state.isHalted)
        #expect(disabledPersistentOptIn,
                "a memory-only stop must disable sync through an independent durable channel")
    }

    @Test func anInvalidatedCursorTriggersAFullResyncRatherThanSilentDivergence() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        await h.transport.seed([try WireCodec.seal(envelope(id, name: "a"), using: h.sealer)])
        _ = await h.engine.sync()

        await h.transport.configure { $0.invalidateCursorOnNextFetch = true }
        let state = await h.engine.sync()
        #expect(!state.isHalted)
        #expect(h.library.envelopes[id] != nil, "a resync must not lose what was already applied")
    }

    @Test func feedRestartBetweenPagesDiscardsTheObsoletePage() async throws {
        final class RestartingPagedTransport: SyncTransport, @unchecked Sendable {
            let identifier = "restarting-pages"
            let supportsPush = false
            let pollInterval: TimeInterval = 60
            let events = AsyncStream<SyncTransportEvent> { $0.finish() }
            var pages: [SyncFetch]
            var fetchIndex = 0

            init(pages: [SyncFetch]) { self.pages = pages }

            func resolveAccountIdentity() async throws -> SyncAccountIdentity? { nil }

            func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
                defer { fetchIndex += 1 }
                return pages[fetchIndex]
            }

            func submit(
                _ records: [WireRecord], at cursor: SyncCursor?
            ) async throws -> SyncSubmission {
                throw SyncTransportFailure.pushUnsupported
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test")
        func record(_ value: SyncEnvelope, version: String) throws -> WireRecord {
            var wire = try WireCodec.seal(value, using: sealer)
            wire.recordVersion = SyncRecordVersion(Data(version.utf8))
            return wire
        }
        let obsoleteID = UUID(uuidString: "10101010-1010-4010-8010-101010101010")!
        let freshAID = UUID(uuidString: "20202020-2020-4020-8020-202020202020")!
        let freshBID = UUID(uuidString: "30303030-3030-4030-8030-303030303030")!
        let obsolete = try record(envelope(obsoleteID, name: "obsolete"), version: "old-v1")
        let freshA = try record(envelope(freshAID, name: "fresh-a"), version: "new-v1")
        let freshB = try record(envelope(freshBID, name: "fresh-b"), version: "new-v2")
        let transport = RestartingPagedTransport(pages: [
            SyncFetch(
                records: [obsolete], cursor: SyncCursor("old-page-1"),
                hasMore: true, isFullResync: false),
            SyncFetch(
                records: [freshA], cursor: SyncCursor("new-page-1"),
                hasMore: true, isFullResync: true, replacesPriorPages: true),
            SyncFetch(
                records: [freshB], cursor: SyncCursor("new-final"),
                hasMore: false, isFullResync: true),
        ])
        let baseURL = dir.appendingPathComponent("base.json")
        try SyncBaseFile.write(
            SyncBase(cursor: SyncCursor("old-root")),
            to: baseURL,
            temporaryDirectory: dir)
        let library = FakeLibrary()
        let engine = SyncEngine(
            transport: transport,
            library: library,
            sealer: sealer,
            device: "aaaaaaa1",
            baseURL: baseURL,
            stateURL: dir.appendingPathComponent("state.json"),
            lockURL: dir.appendingPathComponent("library.lock"),
            temporaryDirectory: dir)

        let state = await engine.sync()

        #expect(!state.isHalted)
        #expect(transport.fetchIndex == 3)
        #expect(library.envelopes[obsoleteID] == nil,
                "a page from the rotated feed must never reach merge/apply")
        #expect(library.envelopes[freshAID]?.fields?.name == "fresh-a")
        #expect(library.envelopes[freshBID]?.fields?.name == "fresh-b")
        #expect(engine.agreedBase.cursor == SyncCursor("new-final"))
    }

    @Test func pagedFetchRejectsSnapshotModeFlipWithoutAdvancingCursor() async throws {
        final class ModeFlippingTransport: SyncTransport, @unchecked Sendable {
            let identifier = "mode-flipping-pages"
            let supportsPush = false
            let pollInterval: TimeInterval = 60
            let events = AsyncStream<SyncTransportEvent> { $0.finish() }
            var fetchIndex = 0

            func resolveAccountIdentity() async throws -> SyncAccountIdentity? { nil }

            func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
                defer { fetchIndex += 1 }
                return if fetchIndex == 0 {
                    SyncFetch(
                        records: [], cursor: SyncCursor("snapshot-page-2"),
                        hasMore: true, isFullResync: true)
                } else {
                    SyncFetch(
                        records: [], cursor: SyncCursor("spliced-final"),
                        hasMore: false, isFullResync: false)
                }
            }

            func submit(
                _ records: [WireRecord], at cursor: SyncCursor?
            ) async throws -> SyncSubmission {
                throw SyncTransportFailure.pushUnsupported
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-flip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = dir.appendingPathComponent("base.json")
        try SyncBaseFile.write(
            SyncBase(cursor: nil),
            to: baseURL,
            temporaryDirectory: dir)
        let transport = ModeFlippingTransport()
        let engine = SyncEngine(
            transport: transport,
            library: FakeLibrary(),
            sealer: SnippetCryptoSealer(
                keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test"),
            device: "aaaaaaa1",
            baseURL: baseURL,
            stateURL: dir.appendingPathComponent("state.json"),
            lockURL: dir.appendingPathComponent("library.lock"),
            temporaryDirectory: dir)

        let state = await engine.sync()

        guard case .halted(.checkpointUnreadable, _) = state else {
            Issue.record("a paged mode flip must halt before adopting its cursor")
            return
        }
        #expect(transport.fetchIndex == 2)
        #expect(engine.agreedBase.cursor == nil)
    }

    // MARK: - Submit results are paired by id, not by position

    /// Hands back submit results in a different order than they were submitted.
    ///
    /// Not a contrived fault: CloudKit answers `modifyRecords` with
    /// `saveResults: [CKRecord.ID: Result<...>]`, a **dictionary**, so a transport that
    /// forwards its backend's natural iteration order produces exactly this. Reversal is
    /// used because it is the permutation guaranteed to differ for any batch of two or
    /// more, which keeps the test deterministic.
    private final class ResultReorderingTransport: SyncTransport, @unchecked Sendable {
        private let inner: InMemoryTransport

        init(_ inner: InMemoryTransport) { self.inner = inner }

        var identifier: String { inner.identifier }
        var supportsPush: Bool { inner.supportsPush }
        var pollInterval: TimeInterval { inner.pollInterval }
        var events: AsyncStream<SyncTransportEvent> { inner.events }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            try await inner.fetchChanges(since: cursor)
        }

        func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
            var submission = try await inner.submit(records, at: cursor)
            submission.results.reverse()
            return submission
        }
    }

    /// The engine must pair each outcome with the record it belongs to.
    ///
    /// Pairing by position instead fails in the worst available direction. The record that
    /// was really accepted is left out of the base and re-pushed forever, which is merely
    /// wasteful — but the record that was *rejected* gets recorded as agreed, so the next
    /// diff skips it and it is never pushed again. The user's edit exists on this Mac and
    /// on no other, and nothing anywhere reports a problem.
    @Test func aSubmitOutcomeIsPairedWithItsOwnRecordNotWithItsPosition() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inner = InMemoryTransport()
        let transport = ResultReorderingTransport(inner)
        let library = FakeLibrary()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test")
        let engine = SyncEngine(
            transport: transport, library: library, sealer: sealer, device: "aaaaaaa1",
            baseURL: dir.appendingPathComponent("base.json"),
            stateURL: dir.appendingPathComponent("state.json"),
            lockURL: dir.appendingPathComponent("library.lock"),
            temporaryDirectory: dir)

        // `pendingChanges` sorts by uuid string, so sorting here identifies which record
        // lands in which position of the submitted batch.
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let refused = ids[0]
        let accepted = ids[1]
        library.envelopes[refused] = envelope(refused, name: "refused")
        library.envelopes[accepted] = envelope(accepted, name: "accepted")

        // One retryable rejection and one acceptance, then the results come back reversed.
        inner.configure { $0.rejectRecords[refused] = .rateLimited(retryAfter: 1) }

        _ = await engine.sync()

        #expect(engine.agreedBase.envelope(accepted) != nil,
                "the record the backend accepted must be recorded as agreed")
        #expect(engine.agreedBase.envelope(refused) == nil,
                "a rejected record recorded as agreed is never pushed again — it is lost")
    }

    // MARK: - Persistence

    @Test func theAgreedBaseSurvivesARestart() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        h.library.envelopes[id] = envelope(id, name: "a")
        _ = await h.engine.sync()

        // A fresh engine over the same files must know the record is already agreed, or
        // every launch would re-push the entire library.
        let restarted = SyncEngine(
            transport: h.transport, library: h.library, sealer: h.sealer, device: "aaaaaaa1",
            baseURL: h.dir.appendingPathComponent("base.json"),
            stateURL: h.dir.appendingPathComponent("state.json"),
            lockURL: h.dir.appendingPathComponent("library.lock"),
            temporaryDirectory: h.dir)
        #expect(restarted.agreedBase.envelope(id) != nil)

        let batchesBefore = await h.transport.submittedBatches.count
        _ = await restarted.sync()
        #expect(await h.transport.submittedBatches.count == batchesBefore,
                "a restart must not re-push an already-agreed library")
    }
}
