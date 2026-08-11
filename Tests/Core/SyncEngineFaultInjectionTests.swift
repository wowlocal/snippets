import CryptoKit
import Darwin
import Foundation
import Testing

@testable import SnippetsCore

/// Crash- and conflict-shaped histories that are awkward to reproduce against a real
/// backend but deterministic against `InMemoryTransport`.
///
/// These tests deliberately drive two devices in a fixed order rather than scheduling
/// real concurrent tasks. Both devices first capture the same cursor, then one submits
/// before the other. That is the exact stale-write history concurrency creates, without
/// a race in the test itself.
@MainActor
@Suite("Sync engine fault injection", .timeLimit(.minutes(1)))
struct SyncEngineFaultInjectionTests {

    // MARK: - Fixtures

    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"

    private final class Library: SyncLibraryAccess {
        var envelopes: [UUID: SyncEnvelope] = [:]
        private(set) var applied: [[SyncEnvelope]] = []

        func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
            envelopes
        }

        func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
            RemoteClassification(
                applicable: envelopes, deferredIDs: [], incompatibleVaultIDs: [])
        }

        func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
            applied.append(incoming)
            for envelope in incoming {
                if envelope.deleted {
                    envelopes[envelope.id] = nil
                } else {
                    envelopes[envelope.id] = envelope
                }
            }
            return ApplyOutcome(changedIDs: incoming.map(\.id))
        }

        func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
    }

    /// Commits to the real in-memory backend, then drops exactly the next acknowledgement.
    /// Throwing `CancellationError` after the inner submit returns models the process being
    /// stopped after the server commit but before `SyncEngine` can confirm it in `base.json`.
    /// It has no suspension gates or wall-clock waits, so a failed assertion cannot hang.
    private final class LostAcknowledgementTransport: SyncTransport, @unchecked Sendable {
        private let inner: InMemoryTransport
        private let lock = NSLock()
        private var shouldLoseNextAcknowledgement = false

        init(_ inner: InMemoryTransport) { self.inner = inner }

        var identifier: String { inner.identifier }
        var supportsPush: Bool { inner.supportsPush }
        var pollInterval: TimeInterval { inner.pollInterval }
        var events: AsyncStream<SyncTransportEvent> { inner.events }

        func loseNextAcknowledgement() {
            lock.lock()
            shouldLoseNextAcknowledgement = true
            lock.unlock()
        }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            try await inner.fetchChanges(since: cursor)
        }

        func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
            let submission = try await inner.submit(records, at: cursor)
            if consumeLostAcknowledgement() { throw CancellationError() }
            return submission
        }

        private func consumeLostAcknowledgement() -> Bool {
            lock.lock()
            let loseAcknowledgement = shouldLoseNextAcknowledgement
            shouldLoseNextAcknowledgement = false
            lock.unlock()
            return loseAcknowledgement
        }
    }

    /// Records the outcomes returned by the shared backend so the two-device test can
    /// prove that the second submit really was rejected as stale, rather than inferring
    /// that merely from the eventual merged value.
    private final class SubmissionObservingTransport: SyncTransport, @unchecked Sendable {
        private let inner: InMemoryTransport
        private let lock = NSLock()
        private var submissionsStorage: [SyncSubmission] = []

        init(_ inner: InMemoryTransport) { self.inner = inner }

        var identifier: String { inner.identifier }
        var supportsPush: Bool { inner.supportsPush }
        var pollInterval: TimeInterval { inner.pollInterval }
        var events: AsyncStream<SyncTransportEvent> { inner.events }

        var submissions: [SyncSubmission] {
            lock.lock()
            defer { lock.unlock() }
            return submissionsStorage
        }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            try await inner.fetchChanges(since: cursor)
        }

        func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
            let submission = try await inner.submit(records, at: cursor)
            record(submission)
            return submission
        }

        private func record(_ submission: SyncSubmission) {
            lock.lock()
            submissionsStorage.append(submission)
            lock.unlock()
        }
    }

    /// Runs a one-shot hook after an authoritative fetch has completed but before the
    /// engine can persist what it learned. Tests use this to close only the journal
    /// directory during the base-before-journal resolution window.
    private final class FetchHookTransport: SyncTransport, @unchecked Sendable {
        private let inner: InMemoryTransport
        private let lock = NSLock()
        private var hook: (() throws -> Void)?

        init(_ inner: InMemoryTransport, hook: @escaping () throws -> Void) {
            self.inner = inner
            self.hook = hook
        }

        var identifier: String { inner.identifier }
        var supportsPush: Bool { inner.supportsPush }
        var pollInterval: TimeInterval { inner.pollInterval }
        var events: AsyncStream<SyncTransportEvent> { inner.events }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            let fetch = try await inner.fetchChanges(since: cursor)
            let nextHook: (() throws -> Void)? = lock.withLock {
                defer { hook = nil }
                return hook
            }
            try nextHook?()
            return fetch
        }

        func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
            try await inner.submit(records, at: cursor)
        }
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", value))!
    }

    private func envelope(
        _ id: UUID,
        device: String,
        revision: UInt64,
        name: String = "name",
        keyword: String = "keyword",
        content: String = "body",
        tags: [String] = []
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: name,
                keyword: keyword,
                content: Data(content.utf8),
                tags: tags,
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)))
    }

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-fault-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func engine(
        transport: any SyncTransport,
        library: Library,
        sealer: SnippetCryptoSealer,
        device: String,
        directory: URL
    ) -> SyncEngine {
        SyncEngine(
            transport: transport,
            library: library,
            sealer: sealer,
            device: device,
            baseURL: directory.appendingPathComponent("base.json"),
            stateURL: directory.appendingPathComponent("state.json"),
            lockURL: directory.appendingPathComponent("library.lock"),
            temporaryDirectory: directory)
    }

    private func serverEnvelope(
        _ id: UUID,
        transport: InMemoryTransport,
        sealer: SnippetCryptoSealer
    ) throws -> SyncEnvelope? {
        guard let record = transport.snapshot.first(where: { $0.id == id }) else { return nil }
        return try WireCodec.open(record, using: sealer)
    }

    private func content(_ envelope: SyncEnvelope?) -> String? {
        envelope?.fields.flatMap { String(data: $0.content, encoding: .utf8) }
    }

    // MARK: - A server commit whose acknowledgement was lost

    @Test func newerEditAfterLostCreateAcknowledgementSurvivesRestart() async throws {
        let dir = try directory("lost-create-edit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryTransport()
        let transport = LostAcknowledgementTransport(backend)
        let library = Library()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "fault-test")
        let snippetID = id(1)

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 100, content: "created body")
        transport.loseNextAcknowledgement()
        let firstEngine = engine(
            transport: transport, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)

        #expect(await firstEngine.sync() == .disabled)
        #expect(content(try serverEnvelope(snippetID, transport: backend, sealer: sealer)) == "created body",
                "the server commit must happen before the acknowledgement is lost")
        #expect(firstEngine.agreedBase.envelope(snippetID) == nil,
                "a lost acknowledgement must not be treated as local confirmation")

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 200, content: "newer local body")
        let restarted = engine(
            transport: transport, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)

        // The first round is rejected as stale and fetches the committed create; the
        // second pushes the locally newer version against that newly confirmed base.
        _ = await restarted.sync()
        _ = await restarted.sync()

        #expect(content(library.envelopes[snippetID]) == "newer local body")
        #expect(content(try serverEnvelope(snippetID, transport: backend, sealer: sealer)) == "newer local body",
                "recovering the lost ACK must not overwrite the edit made afterwards")
    }

    @Test func newerEditAfterLostUpdateAcknowledgementSurvivesRestart() async throws {
        let dir = try directory("lost-update-edit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryTransport()
        let transport = LostAcknowledgementTransport(backend)
        let library = Library()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "fault-test")
        let snippetID = id(2)
        let firstEngine = engine(
            transport: transport, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 100, content: "ancestor")
        _ = await firstEngine.sync()

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 200, content: "committed update")
        transport.loseNextAcknowledgement()
        #expect(await firstEngine.sync() == .disabled)
        #expect(content(try serverEnvelope(snippetID, transport: backend, sealer: sealer)) == "committed update")
        #expect(content(firstEngine.agreedBase.envelope(snippetID)) == "ancestor")

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 300, content: "newest local update")
        let restarted = engine(
            transport: transport, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)
        _ = await restarted.sync()
        _ = await restarted.sync()

        #expect(content(library.envelopes[snippetID]) == "newest local update")
        #expect(content(try serverEnvelope(snippetID, transport: backend, sealer: sealer)) == "newest local update")
    }

    @Test func deleteAfterLostUpdateAcknowledgementSurvivesRestart() async throws {
        let dir = try directory("lost-update-delete")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryTransport()
        let transport = LostAcknowledgementTransport(backend)
        let library = Library()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "fault-test")
        let snippetID = id(3)
        let firstEngine = engine(
            transport: transport, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 100, content: "ancestor")
        _ = await firstEngine.sync()

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 200, content: "server committed this")
        transport.loseNextAcknowledgement()
        _ = await firstEngine.sync()
        #expect(content(firstEngine.agreedBase.envelope(snippetID)) == "ancestor")

        // This deletion happened after the unacknowledged update and is therefore the
        // latest user intent. A restart must not reinterpret our own server echo as a
        // competing remote edit that outranks it.
        library.envelopes[snippetID] = nil
        let restarted = engine(
            transport: transport, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)
        _ = await restarted.sync()
        _ = await restarted.sync()

        #expect(library.envelopes[snippetID] == nil,
                "the committed-but-unconfirmed update must not resurrect a later local delete")
        #expect(try serverEnvelope(snippetID, transport: backend, sealer: sealer)?.deleted == true,
                "the later delete must eventually replace the unacknowledged update on the server")
    }

    @Test func deleteAfterLostCreateAcknowledgementSurvivesRestart() async throws {
        let dir = try directory("lost-create-delete")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryTransport()
        let transport = LostAcknowledgementTransport(backend)
        let library = Library()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "fault-test")
        let snippetID = id(4)
        let firstEngine = engine(
            transport: transport, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 100, content: "short lived")
        transport.loseNextAcknowledgement()
        _ = await firstEngine.sync()
        #expect(firstEngine.agreedBase.envelope(snippetID) == nil)
        #expect(try serverEnvelope(snippetID, transport: backend, sealer: sealer) != nil)

        library.envelopes[snippetID] = nil
        let restarted = engine(
            transport: transport, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)
        _ = await restarted.sync()
        _ = await restarted.sync()

        #expect(library.envelopes[snippetID] == nil,
                "an absent local record needs durable create/delete intent across the lost ACK")
        #expect(try serverEnvelope(snippetID, transport: backend, sealer: sealer)?.deleted == true)
    }

    @Test func rekeyRetryRetainsCursorForCASAndConflictsWithIndependentRemoteWrite() async throws {
        let snippetID = id(5)
        let ancestorA = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            name: "ancestor name", content: "ancestor body")
        let offeredC = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            name: "ancestor name", content: "body from C")
        let independentD = envelope(
            snippetID, device: Self.deviceB, revision: 300,
            name: "name from D", content: "ancestor body")
        let oldSealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "before-rekey")
        let newSealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "after-rekey")
        let wireA = try WireCodec.seal(ancestorA, using: oldSealer)
        let wireCOldKey = try WireCodec.seal(offeredC, using: oldSealer)
        let wireCNewKey = try WireCodec.seal(offeredC, using: newSealer)
        let wireD = try WireCodec.seal(independentD, using: newSealer)

        let acceptingBackend = InMemoryTransport()
        acceptingBackend.seed([wireA])
        let cursorAtA = try #require(acceptingBackend.currentCursor)
        var confirmed = SyncBase(cursor: cursorAtA)
        confirmed.record(ancestorA)
        var journal = SyncJournal()
        journal.reconcile(
            current: [snippetID: offeredC], confirmed: confirmed,
            deviceID: Self.deviceA, now: Date(timeIntervalSince1970: 1))
        journal.markOffered(journal.pending(confirmed: confirmed))
        #expect(journal.entry(snippetID)?.offered?.envelope == offeredC)

        // The first submission fails before commit, so A remains remotely and C stays
        // an ambiguous plaintext offer ready to be resealed by the winning sync key.
        acceptingBackend.configure { $0.failSubmits = 1 }
        await #expect(throws: (any Error).self) {
            _ = try await acceptingBackend.submit([wireCOldKey], at: confirmed.cursor)
        }
        #expect(acceptingBackend.snapshot == [wireA])

        journal.stageConfirmedForTransportRekey(confirmed, now: Date(timeIntervalSince1970: 2))
        let resetBase = SyncBase(cursor: confirmed.cursor)
        #expect(resetBase.envelopes.isEmpty)
        #expect(resetBase.cursor == cursorAtA,
                "rekey must retain the compare-and-swap ancestor cursor")
        #expect(journal.pending(confirmed: resetBase) == [offeredC],
                "staging A must not replace the existing lost-ACK offer C")

        let accepted = try await acceptingBackend.submit([wireCNewKey], at: resetBase.cursor)
        #expect(accepted.acceptedIDs == [snippetID],
                "C can replace A because the retained cursor covers A's write")
        let acceptedRecord = try #require(acceptingBackend.snapshot.first)
        #expect(try WireCodec.open(acceptedRecord, using: newSealer) == offeredC)

        // In the independent branch, D lands after the same old cursor. Retaining that
        // cursor must cause C to conflict rather than blindly overwrite D; the fetched
        // D can then be merged with C over their shared ancestor A.
        let conflictingBackend = InMemoryTransport()
        conflictingBackend.seed([wireA])
        let sharedCursor = try #require(conflictingBackend.currentCursor)
        conflictingBackend.seed([wireD])
        let rejected = try await conflictingBackend.submit([wireCNewKey], at: sharedCursor)
        let conflict = try #require(rejected.rejections.first)
        #expect(conflict.id == snippetID)
        if case .conflict(let remoteRev) = conflict.rejection {
            #expect(remoteRev == wireD.rev)
        } else {
            Issue.record("expected the post-cursor independent write D to conflict")
        }

        let fetched = try await conflictingBackend.fetchChanges(since: sharedCursor)
        let fetchedRecord = try #require(fetched.records.first(where: { $0.id == snippetID }))
        let fetchedD = try WireCodec.open(fetchedRecord, using: newSealer)
        #expect(fetchedD == independentD)
        let merged = try #require(SyncMerge.mergeEnvelope(
            base: ancestorA, local: offeredC, remote: fetchedD))
        #expect(merged.fields?.name == "name from D")
        #expect(content(merged) == "body from C")
    }

    @Test func permanentRejectionDoesNotPinOldOfferAfterPayloadIsFixed() async throws {
        let dir = try directory("permanent-rejection-repair")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryTransport()
        let library = Library()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "permanent-repair")
        let snippetID = id(6)
        let rejectedPayload = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            content: "payload permanently rejected")
        let fixedPayload = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            content: "fixed payload")
        library.envelopes[snippetID] = rejectedPayload
        backend.configure {
            $0.rejectRecords[snippetID] = .permanent(detail: "payload must be fixed")
        }
        let syncEngine = engine(
            transport: backend, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)

        let rejectedState = await syncEngine.sync()
        guard case .halted(let reason, _) = rejectedState else {
            Issue.record("a permanent per-record rejection must halt for user repair")
            return
        }
        #expect(reason == .backendRefused)
        #expect(backend.fetchAttempts == 1,
                "the engine must complete an authoritative fetch before pinning a terminal halt")
        #expect(backend.submittedBatches.count == 1)

        library.envelopes[snippetID] = fixedPayload
        backend.configure { $0.rejectRecords[snippetID] = nil }
        syncEngine.clearHaltAfterUserReview()
        #expect(!syncEngine.state.isHalted)
        let resumedState = await syncEngine.sync()
        #expect(!resumedState.isHalted)

        let submittedEnvelopes = try backend.submittedBatches
            .flatMap { $0 }
            .map { try WireCodec.open($0, using: sealer) }
        #expect(submittedEnvelopes == [rejectedPayload, fixedPayload],
                "Resume must submit the repaired desired value, never the rejected offer again")
        #expect(content(try serverEnvelope(
            snippetID, transport: backend, sealer: sealer)) == "fixed payload")

        let batchesAfterRepair = backend.submittedBatches.count
        _ = await syncEngine.sync()
        #expect(backend.submittedBatches.count == batchesAfterRepair,
                "the repaired acceptance must be a fixed point")
    }

    @Test func journalResolutionFailureRetainsOldCursorSoRestartCannotOverwriteRemote() async throws {
        let root = try directory("cursor-before-journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseDirectory = root.appendingPathComponent("Base", isDirectory: true)
        let journalDirectory = root.appendingPathComponent("Journal", isDirectory: true)
        let temporaryDirectory = root.appendingPathComponent("Tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: journalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
        defer { _ = chmod(journalDirectory.path, 0o700) }

        let baseURL = baseDirectory.appendingPathComponent("base.json")
        let journalURL = journalDirectory.appendingPathComponent("journal.json")
        let stateURL = baseDirectory.appendingPathComponent("state.json")
        let lockURL = baseDirectory.appendingPathComponent("library.lock")
        let snippetID = id(7)
        let ancestor = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            name: "ancestor name", content: "ancestor body")
        let offeredA = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            name: "ancestor name", content: "local body A")
        let independentB = envelope(
            snippetID, device: Self.deviceB, revision: 300,
            name: "remote name B", content: "ancestor body")
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "cursor-window")
        let backend = InMemoryTransport()
        backend.seed([try WireCodec.seal(ancestor, using: sealer)])
        let oldCursor = try #require(backend.currentCursor)

        var confirmed = SyncBase(cursor: oldCursor, journalEstablished: true)
        confirmed.record(ancestor)
        try SyncBaseFile.write(
            confirmed, to: baseURL, temporaryDirectory: temporaryDirectory)
        var journal = SyncJournal()
        journal.reconcile(
            current: [snippetID: offeredA], confirmed: confirmed,
            deviceID: Self.deviceA, now: Date(timeIntervalSince1970: 1))
        journal.markOffered(journal.pending(confirmed: confirmed))
        try SyncJournalFile.write(
            journal, to: journalURL, temporaryDirectory: temporaryDirectory)
        let journalBeforeFailure = try Data(contentsOf: journalURL)

        // B is an independent write after the cursor that A was derived from. A's
        // submit therefore conflicts, and the following fetch returns B.
        backend.seed([try WireCodec.seal(independentB, using: sealer)])
        let library = Library()
        library.envelopes[snippetID] = offeredA
        let faultingTransport = FetchHookTransport(backend) {
            guard chmod(journalDirectory.path, 0o500) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: journalDirectory.path])
            }
        }
        let firstEngine = SyncEngine(
            transport: faultingTransport,
            library: library,
            sealer: sealer,
            device: Self.deviceA,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: lockURL,
            temporaryDirectory: temporaryDirectory)

        let failedState = await firstEngine.sync()
        guard case .halted(let reason, _) = failedState else {
            Issue.record("resolution journal failure must halt before advancing the cursor")
            return
        }
        #expect(reason == .localLibraryQuarantined)
        #expect(chmod(journalDirectory.path, 0o700) == 0)

        guard case .loaded(let baseAfterFailure) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("the fetched remote base should be durable before journal resolution")
            return
        }
        #expect(baseAfterFailure.envelope(snippetID) == independentB)
        #expect(baseAfterFailure.cursor == oldCursor,
                "cursor must not advance past B until stale offer A is durably resolved")
        #expect(try Data(contentsOf: journalURL) == journalBeforeFailure)
        guard case .loaded(let journalAfterFailure) = SyncJournalFile.load(from: journalURL) else {
            Issue.record("the pre-resolution journal must remain readable")
            return
        }
        #expect(journalAfterFailure.entry(snippetID)?.offered?.envelope == offeredA)

        let durableMerged = try #require(library.envelopes[snippetID])
        #expect(durableMerged.fields?.name == "remote name B")
        #expect(content(durableMerged) == "local body A",
                "remote apply must durably rebase local A and independent B before failing")

        // Resume from the exact crash image. Because base retained the old cursor, A
        // conflicts with B and B is fetched again; it cannot be accepted over B merely
        // because B's envelope was already made durable in base.json.
        let observingRestart = SubmissionObservingTransport(backend)
        let restartedLibrary = Library()
        restartedLibrary.envelopes[snippetID] = durableMerged
        let restarted = SyncEngine(
            transport: observingRestart,
            library: restartedLibrary,
            sealer: sealer,
            device: Self.deviceA,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: lockURL,
            temporaryDirectory: temporaryDirectory)
        #expect(restarted.state.isHalted)
        restarted.clearHaltAfterUserReview()
        #expect(!restarted.state.isHalted)
        _ = await restarted.sync()

        let replay = try #require(observingRestart.submissions.first)
        let replayConflict = try #require(replay.rejections.first)
        #expect(replay.acceptedIDs.isEmpty)
        #expect(replayConflict.id == snippetID)
        if case .conflict = replayConflict.rejection {} else {
            Issue.record("restart must conflict stale A against post-cursor B")
        }
        #expect(try serverEnvelope(snippetID, transport: backend, sealer: sealer) == independentB)
        #expect(restartedLibrary.envelopes[snippetID]?.fields?.name == "remote name B")
        #expect(content(restartedLibrary.envelopes[snippetID]) == "local body A")

        // With A's stale offer now durably rejected and the cursor advanced by the
        // repeated fetch, the field-level merge may be submitted safely.
        _ = await restarted.sync()
        let mergedServerEnvelope = try serverEnvelope(
            snippetID, transport: backend, sealer: sealer)
        let mergedOnServer = try #require(mergedServerEnvelope)
        #expect(mergedOnServer.fields?.name == "remote name B")
        #expect(content(mergedOnServer) == "local body A")
    }

    // MARK: - Two devices with a shared ancestor

    @Test func staleDisjointUpdateConflictsThenMergesWithoutLosingEitherField() async throws {
        let dirA = try directory("disjoint-a")
        let dirB = try directory("disjoint-b")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let backend = InMemoryTransport()
        let observingB = SubmissionObservingTransport(backend)
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "fault-test")
        let libraryA = Library()
        let libraryB = Library()
        let engineA = engine(
            transport: backend, library: libraryA, sealer: sealer,
            device: Self.deviceA, directory: dirA)
        let engineB = engine(
            transport: observingB, library: libraryB, sealer: sealer,
            device: Self.deviceB, directory: dirB)
        let snippetID = id(10)
        let ancestor = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            name: "original name", content: "original body")

        libraryA.envelopes[snippetID] = ancestor
        _ = await engineA.sync()
        _ = await engineB.sync()
        #expect(engineA.agreedBase.cursor == engineB.agreedBase.cursor,
                "both devices must begin their edits from the same backend position")

        libraryA.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            name: "renamed on A", content: "original body")
        libraryB.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceB, revision: 300,
            name: "original name", content: "rewritten on B")

        _ = await engineA.sync()
        _ = await engineB.sync()

        let staleResult = try #require(observingB.submissions.last?.rejections.first)
        #expect(staleResult.id == snippetID)
        if case .conflict = staleResult.rejection {
            // Expected: B wrote from the common ancestor after A had already advanced it.
        } else {
            Issue.record("expected B's stale submit to conflict, got \(staleResult.rejection)")
        }
        #expect(libraryB.envelopes[snippetID]?.fields?.name == "renamed on A")
        #expect(content(libraryB.envelopes[snippetID]) == "rewritten on B")

        // B now submits the field-level merge at its fresh cursor, and A fetches it.
        _ = await engineB.sync()
        _ = await engineA.sync()

        for library in [libraryA, libraryB] {
            #expect(library.envelopes[snippetID]?.fields?.name == "renamed on A")
            #expect(content(library.envelopes[snippetID]) == "rewritten on B")
        }
        let fetchedServerEnvelope = try serverEnvelope(
            snippetID, transport: backend, sealer: sealer)
        let onServer = try #require(fetchedServerEnvelope)
        #expect(onServer.fields?.name == "renamed on A")
        #expect(content(onServer) == "rewritten on B")
    }

    @Test func concurrentSameScalarEditConvergesToOneDeterministicWinner() throws {
        let snippetID = id(11)
        let ancestor = envelope(
            snippetID, device: Self.deviceA, revision: 100, name: "ancestor")
        let onA = envelope(
            snippetID, device: Self.deviceA, revision: 200, name: "name from A")
        let onB = envelope(
            snippetID, device: Self.deviceB, revision: 200, name: "name from B")

        let mergedOnA = try #require(SyncMerge.mergeEnvelope(
            base: ancestor, local: onA, remote: onB))
        let mergedOnB = try #require(SyncMerge.mergeEnvelope(
            base: ancestor, local: onB, remote: onA))

        #expect(mergedOnA == mergedOnB,
                "mirrored devices must not each choose their own same-field edit")
        #expect(mergedOnA.fields?.name == "name from B",
                "the HLC device tiebreak chooses the same scalar winner everywhere")
        #expect(SyncMerge.mergeEnvelope(
            base: mergedOnA, local: mergedOnA, remote: mergedOnB) == mergedOnA,
                "the chosen result must be a fixed point rather than ping-pong")
    }

    // MARK: - Tombstone and partial-batch durability

    @Test func createThenDeleteBeforeRestartStillUploadsATombstoneExactlyOnce() async throws {
        let dir = try directory("create-delete-restart")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryTransport()
        let library = Library()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "fault-test")
        let snippetID = id(20)
        let firstEngine = engine(
            transport: backend, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)

        library.envelopes[snippetID] = envelope(
            snippetID, device: Self.deviceA, revision: 100, content: "doomed")
        _ = await firstEngine.sync()
        library.envelopes[snippetID] = nil

        let restarted = engine(
            transport: backend, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)
        _ = await restarted.sync()
        let batchesAfterDelete = backend.submittedBatches.count

        #expect(library.envelopes[snippetID] == nil)
        #expect(try serverEnvelope(snippetID, transport: backend, sealer: sealer)?.deleted == true)

        let restartedAgain = engine(
            transport: backend, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)
        _ = await restartedAgain.sync()
        #expect(backend.submittedBatches.count == batchesAfterDelete,
                "a confirmed tombstone must not be submitted again after another restart")
        #expect(library.envelopes[snippetID] == nil, "the server echo must not resurrect the create")
    }

    @Test func partialBatchRetryOnlyResubmitsRejectedTailAndIsIdempotent() async throws {
        let dir = try directory("partial-batch")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryTransport()
        backend.configure {
            $0.acceptAtMostPerBatch = 1
            $0.partialBatchRejection = .rateLimited(retryAfter: 1)
        }
        let library = Library()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "fault-test")
        let ids = [id(30), id(31), id(32)]
        for (offset, snippetID) in ids.enumerated() {
            library.envelopes[snippetID] = envelope(
                snippetID, device: Self.deviceA, revision: UInt64(100 + offset),
                name: "snippet \(offset)", content: "body \(offset)")
        }
        let firstEngine = engine(
            transport: backend, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)

        _ = await firstEngine.sync()
        #expect(backend.snapshot.map(\.id) == [ids[0]])
        #expect(firstEngine.agreedBase.envelope(ids[0]) != nil)
        #expect(firstEngine.agreedBase.envelope(ids[1]) == nil)
        #expect(firstEngine.agreedBase.envelope(ids[2]) == nil)

        backend.configure { $0.acceptAtMostPerBatch = nil }
        let restarted = engine(
            transport: backend, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)
        _ = await restarted.sync()

        #expect(backend.submittedBatches.map { $0.map(\.id) } == [ids, Array(ids.dropFirst())],
                "the accepted prefix must not be repeated with the rejected tail")
        #expect(Set(backend.snapshot.map(\.id)) == Set(ids))
        #expect(backend.snapshot.count == ids.count, "retry must not duplicate accepted records")

        let batchesAfterRecovery = backend.submittedBatches.count
        let restartedAgain = engine(
            transport: backend, library: library, sealer: sealer,
            device: Self.deviceA, directory: dir)
        _ = await restartedAgain.sync()

        #expect(backend.submittedBatches.count == batchesAfterRecovery,
                "a completed retry must be a fixed point across restart")
        #expect(backend.snapshot.count == ids.count)
    }
}
