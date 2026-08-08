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

        func currentEnvelopes() throws -> [UUID: SyncEnvelope] {
            if let throwOnRead { throw throwOnRead }
            return envelopes
        }

        func applyRemote(_ incoming: [SyncEnvelope]) throws -> [UUID] {
            applied.append(incoming)
            for envelope in incoming {
                if envelope.deleted { envelopes[envelope.id] = nil } else { envelopes[envelope.id] = envelope }
            }
            return incoming.map(\.id)
        }

        func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
    }

    private func envelope(
        _ id: UUID, name: String, content: String = "body", ms: UInt64 = 1_000, deleted: Bool = false
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: ms, counter: 0, device: "aaaaaaa1"),
            origin: "aaaaaaa1",
            secure: false,
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
            baseURL: dir.appendingPathComponent("base.json"), temporaryDirectory: dir)
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

    @Test func aPermanentRejectionHaltsRatherThanRetryingForever() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let id = UUID()
        h.library.envelopes[id] = envelope(id, name: "a")
        await h.transport.configure { $0.rejectRecords[id] = .permanent(detail: "schema rejected") }

        let state = await h.engine.sync()
        #expect(state.isHalted)

        guard case .halted(let reason, let detail) = state else {
            Issue.record("expected .halted, got \(state)")
            return
        }

        // The reason has to name what happened. This branch used to report
        // `manifestIntegrityFailed` — documented as "the backend was rolled back,
        // truncated, or tampered with" — for every non-retryable rejection there is. A
        // CloudKit container whose schema had simply never been deployed to Production
        // therefore told the user their backend had been tampered with, and sent them
        // looking for corruption that was not there.
        #expect(reason == .backendRefused)

        // The backend's own words, unwrapped. `Rejection.description` prefixes "the
        // backend permanently refused this snippet", and the halt title already says
        // iCloud refused a snippet, so keeping both made the sentence say it twice
        // before reaching anything a reader could act on.
        #expect(detail == "schema rejected")
    }

    @Test func anAuthenticationFailureAsksForCredentialsInsteadOfBackingOff() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.library.envelopes[UUID()] = envelope(UUID(), name: "a")
        await h.transport.configure { $0.rejectEverything = .authenticationRequired(detail: "token expired") }

        let state = await h.engine.sync()
        if case .needsAuthentication = state {} else {
            Issue.record("expected .needsAuthentication, got \(state)")
        }
    }

    // MARK: - Backoff

    @Test func anUnreachableBackendBacksOffAndRefusesToRunBeforeItsDeadline() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        var clock = Date(timeIntervalSince1970: 1_000)
        h.engine.now = { clock }
        h.library.envelopes[UUID()] = envelope(UUID(), name: "a")
        await h.transport.configure { $0.unreachable = true }

        let first = await h.engine.sync()
        guard case .offline(let firstDeadline) = first else {
            Issue.record("expected .offline, got \(first)"); return
        }

        // Still inside the window: the round must not even be attempted.
        let batchesBefore = await h.transport.submittedBatches.count
        _ = await h.engine.sync()
        #expect(await h.transport.submittedBatches.count == batchesBefore)

        // Past the window, it tries again and backs off further.
        clock = firstDeadline.addingTimeInterval(1)
        let second = await h.engine.sync()
        guard case .offline(let secondDeadline) = second else {
            Issue.record("expected .offline, got \(second)"); return
        }
        #expect(secondDeadline.timeIntervalSince(clock) > firstDeadline.timeIntervalSince(Date(timeIntervalSince1970: 1_000)),
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

    /// A halt is sticky, and only an explicit review clears it.
    @Test func aHaltSurvivesFurtherSyncAttemptsUntilReviewed() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.engine.halt(.massDeletion, detail: "test")
        #expect(await h.engine.sync().isHalted)
        #expect(await h.engine.sync().isHalted)

        h.engine.clearHaltAfterUserReview()
        #expect(!h.engine.state.isHalted)
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
            baseURL: dir.appendingPathComponent("base.json"), temporaryDirectory: dir)

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
            baseURL: h.dir.appendingPathComponent("base.json"), temporaryDirectory: h.dir)
        #expect(restarted.agreedBase.envelope(id) != nil)

        let batchesBefore = await h.transport.submittedBatches.count
        _ = await restarted.sync()
        #expect(await h.transport.submittedBatches.count == batchesBefore,
                "a restart must not re-push an already-agreed library")
    }
}
