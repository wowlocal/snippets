import Foundation
import Testing

@testable import SnippetsCore

/// Regression for docs/issues/cloud-account-key/02-post-crash-conflict-copies.md.
///
/// The audit's iPhone and iPad crash stages began with a wire-key reseal: the
/// coordinator stages every confirmed envelope as an exact offer *ahead of* the newer
/// local edit, then the round's accepted reply was withheld and the process killed.
/// Recovery resolved that reseal (an exact echo of already-confirmed bytes), reported
/// Synced and left the user's edit unsent. Later devices therefore edited the old
/// value, and the delayed edit became a genuine concurrent conflict — the extra copy of
/// an edit the audit believed had been accepted. These tests run the real engine,
/// journal, base and in-memory CAS backend.
@MainActor
@Suite("Sync recovery uploads intent left behind by resolved offers", .timeLimit(.minutes(1)))
struct SyncRecoveryFollowUpTests {

    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"

    private final class Library: SyncLibraryAccess {
        var envelopes: [UUID: SyncEnvelope] = [:]

        func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
            envelopes
        }

        func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
            RemoteClassification(
                applicable: envelopes, deferredIDs: [], incompatibleVaultIDs: [])
        }

        func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
            for envelope in incoming {
                envelopes[envelope.id] = envelope.deleted ? nil : envelope
            }
            return ApplyOutcome(changedIDs: incoming.map(\.id))
        }

        func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
    }

    /// The server commits the batch; the reply never reaches the process.
    private final class WithheldReplyTransport: SyncTransport, @unchecked Sendable {
        private let inner: InMemoryTransport
        private let lock = NSLock()
        private var withholdNext = false

        init(_ inner: InMemoryTransport) { self.inner = inner }

        var identifier: String { inner.identifier }
        var supportsPush: Bool { inner.supportsPush }
        var pollInterval: TimeInterval { inner.pollInterval }
        var events: AsyncStream<SyncTransportEvent> { inner.events }

        func withholdNextReply() { lock.withLock { withholdNext = true } }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            try await inner.fetchChanges(since: cursor)
        }

        func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
            let submission = try await inner.submit(records, at: cursor)
            let withhold = lock.withLock {
                defer { withholdNext = false }
                return withholdNext
            }
            if withhold { throw CancellationError() }
            return submission
        }
    }

    @MainActor private struct Device {
        let directory: URL
        let library = Library()
        let device: String

        var baseURL: URL { directory.appendingPathComponent("base.json") }
        var journalURL: URL { directory.appendingPathComponent("journal.json") }

        /// Configured exactly like `SyncCoordinator`'s production engine.
        func engine(_ transport: any SyncTransport, sealer: SnippetCryptoSealer) -> SyncEngine {
            let engine = SyncEngine(
                transport: transport,
                library: library,
                sealer: sealer,
                device: device,
                baseURL: baseURL,
                stateURL: directory.appendingPathComponent("state.json"),
                lockURL: directory.appendingPathComponent("library.lock"),
                temporaryDirectory: directory)
            engine.followUpRoundsAfterSettledOffers = SyncEngine.productionFollowUpRounds
            return engine
        }

        /// `SyncCoordinator.discardAgreedBaseIfWireKeyChanged`: capture current intent,
        /// stage every confirmed envelope for resealing, then replace the base with a
        /// full-resync base that keeps only the per-record CAS generations.
        func stageWireKeyReseal(now: Date) throws {
            guard case .loaded(let confirmed) = SyncBaseFile.load(from: baseURL),
                  case .loaded(var journal) = SyncJournalFile.load(from: journalURL)
            else {
                Issue.record("the device has not synchronized yet")
                return
            }
            let current = try library.currentEnvelopes(
                agreedBase: journal.projectionKnowledge(over: confirmed))
            try journal.reconcileDependencies(current: current, confirmed: confirmed)
            journal.reconcile(current: current, confirmed: confirmed, deviceID: device, now: now)
            try journal.prepareForTransportRekey(current: current, confirmed: confirmed, now: now)
            try SyncJournalFile.write(journal, to: journalURL, temporaryDirectory: directory)
            try SyncBaseFile.write(SyncBase(
                envelopes: [:],
                recordVersions: confirmed.recordVersions,
                journalEstablished: true,
                accountIdentity: confirmed.accountIdentity,
                datasetIdentity: confirmed.datasetIdentity,
                requiresTransportFullResync: true),
                to: baseURL, temporaryDirectory: directory)
        }
    }

    private func device(_ label: String, _ id: String) throws -> Device {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-recovery-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Device(directory: url, device: id)
    }

    private let recordID = UUID(uuidString: "a11ce002-0000-4000-8000-000000000002")!

    private func fields(_ content: String, device: String, wall: UInt64) -> SyncEnvelope {
        SyncEnvelope(
            id: recordID,
            hlc: HLC(wallMs: wall, counter: 0, device: device),
            origin: device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "fields", keyword: "fields", content: Data(content.utf8),
                tags: ["audit"], isEnabled: true, isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1_786_579_200),
                updatedAt: Date(timeIntervalSince1970: Double(wall) / 1_000)))
    }

    private func body(_ envelope: SyncEnvelope?) -> String? {
        envelope?.fields.flatMap { String(data: $0.content, encoding: .utf8) }
    }

    private func server(_ backend: InMemoryTransport, _ sealer: SnippetCryptoSealer) throws
        -> [SyncEnvelope] {
        try backend.snapshot.map { try WireCodec.open($0, using: sealer) }
    }

    /// accepted-but-unacknowledged A → recovery A → B receives A and edits → A receives B.
    /// The audit's recovery launch reported `key_changed` again (the killed process never
    /// persisted its fingerprint), so it is also exercised with a second reseal staging.
    @Test(arguments: [false, true])
    func resealRecoveryUploadsTheEditBeforeAnotherDeviceBuildsOnIt(
        restagedAtRecovery: Bool
    ) async throws {
        let backend = InMemoryTransport()
        let transport = WithheldReplyTransport(backend)
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "recovery-follow-up")
        let a = try device("a", Self.deviceA)
        let b = try device("b", Self.deviceB)
        defer {
            try? FileManager.default.removeItem(at: a.directory)
            try? FileManager.default.removeItem(at: b.directory)
        }

        a.library.envelopes[recordID] = fields(
            "audit-crash-macos", device: Self.deviceA, wall: 1_791_000_000_000)
        _ = await a.engine(transport, sealer: sealer).sync()
        _ = await b.engine(transport, sealer: sealer).sync()
        #expect(body(b.library.envelopes[recordID]) == "audit-crash-macos")

        // A edits, then starts with a wire-key reseal. The server accepts the first
        // batch (the reseal of the confirmed bytes) and the process is killed.
        a.library.envelopes[recordID] = fields(
            "audit-crash-iphone", device: Self.deviceA, wall: 1_791_000_010_000)
        try a.stageWireKeyReseal(now: Date(timeIntervalSince1970: 1_791_000_011))
        transport.withholdNextReply()
        _ = await a.engine(transport, sealer: sealer).sync()
        #expect(body(try server(backend, sealer).first) == "audit-crash-macos",
                "the withheld batch was the byte-identical reseal, not the edit")

        // Recovery is one ordinary sync of the same installation.
        if restagedAtRecovery {
            try a.stageWireKeyReseal(now: Date(timeIntervalSince1970: 1_791_000_012))
        }
        let recovered = a.engine(transport, sealer: sealer)
        let recoveredState = await recovered.sync()
        guard case .idle = recoveredState else {
            Issue.record("recovery did not finish: \(recoveredState)")
            return
        }
        #expect(body(try server(backend, sealer).first) == "audit-crash-iphone",
                "a Synced recovery must not leave the user's newer edit unsent")

        // B receives A's edit and builds on it; A then receives B.
        let bEngine = b.engine(transport, sealer: sealer)
        _ = await bEngine.sync()
        #expect(body(b.library.envelopes[recordID]) == "audit-crash-iphone")
        b.library.envelopes[recordID] = fields(
            "audit-crash-ipad", device: Self.deviceB, wall: 1_791_000_020_000)
        _ = await bEngine.sync()
        _ = await recovered.sync()

        #expect(a.library.envelopes.count == 1, "a sequential edit became a conflict copy")
        #expect(body(a.library.envelopes[recordID]) == "audit-crash-ipad")
        #expect(try server(backend, sealer).count == 1)
        #expect(try server(backend, sealer).allSatisfy {
            SyncMerge.conflictCopyProvenance(in: $0) == nil
        })
    }

    /// Ordinary lost acknowledgement: recovery and the newer edit finish in one sync.
    @Test func lostAcknowledgementRecoveryAndNewerEditFinishInOneSync() async throws {
        let backend = InMemoryTransport()
        let transport = WithheldReplyTransport(backend)
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "recovery-follow-up")
        let a = try device("lost-ack", Self.deviceA)
        defer { try? FileManager.default.removeItem(at: a.directory) }

        a.library.envelopes[recordID] = fields("ancestor", device: Self.deviceA, wall: 100)
        _ = await a.engine(transport, sealer: sealer).sync()
        a.library.envelopes[recordID] = fields("committed", device: Self.deviceA, wall: 200)
        transport.withholdNextReply()
        _ = await a.engine(transport, sealer: sealer).sync()
        a.library.envelopes[recordID] = fields("newer", device: Self.deviceA, wall: 300)

        let restarted = a.engine(transport, sealer: sealer)
        _ = await restarted.sync()
        #expect(body(try server(backend, sealer).first) == "newer")
        let submissions = backend.submittedBatches.count
        _ = await restarted.sync()
        #expect(backend.submittedBatches.count == submissions,
                "an idle follow-up must not write")
    }
}
