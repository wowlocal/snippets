import Foundation
import Testing

@testable import SnippetsCore

/// Regression coverage for ordering at the boundary between the durable inbound log
/// and content-conflict generation.
///
/// These cases deliberately use one fetch containing records that a transport learned in
/// order. They are not competing snapshots merely because Core receives them together:
/// a later occurrence of the same record id supersedes the earlier occurrence, and an
/// already-existing conflict-copy id must be considered before a generated candidate is
/// admitted into the library.
@MainActor
@Suite("Sync conflict ordering", .timeLimit(.minutes(1)))
struct SyncConflictOrderingTests {

    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"
    private static let originalID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000021")!

    private final class Library: SyncLibraryAccess {
        var envelopes: [UUID: SyncEnvelope]
        private(set) var appliedBatches: [[SyncEnvelope]] = []

        init(_ envelopes: [UUID: SyncEnvelope]) {
            self.envelopes = envelopes
        }

        func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
            envelopes
        }

        func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
            RemoteClassification(
                applicable: envelopes,
                deferredIDs: [],
                incompatibleVaultIDs: [])
        }

        func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
            appliedBatches.append(incoming)
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

    /// A single-page ordered inbox. Local pushes are rejected retryably so the fetch is
    /// authoritative without adding a synthetic conflict record ahead of the requested
    /// order. This mirrors a CKSyncEngine checkpoint that accumulated multiple durable
    /// generations before Core consumed them.
    private final class OrderedInboxTransport: SyncTransport, @unchecked Sendable {
        let identifier = "ordered-inbox-test"
        let supportsPush = true
        let pollInterval: TimeInterval = 30
        let events: AsyncStream<SyncTransportEvent>

        private let records: [WireRecord]
        private let lock = NSLock()
        private var submissionsStorage: [[WireRecord]] = []

        init(records: [WireRecord]) {
            self.records = records
            events = AsyncStream { _ in }
        }

        var submissions: [[WireRecord]] {
            lock.withLock { submissionsStorage }
        }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            SyncFetch(
                records: records,
                cursor: SyncCursor("ordered-inbox-1"),
                hasMore: false,
                isFullResync: false)
        }

        func submit(
            _ records: [WireRecord], at cursor: SyncCursor?
        ) async throws -> SyncSubmission {
            lock.withLock { submissionsStorage.append(records) }
            return SyncSubmission(
                results: records.map {
                    SyncSubmitResult(
                        id: $0.id,
                        outcome: .rejected(.rateLimited(retryAfter: 1)))
                },
                cursor: cursor)
        }
    }

    private struct RunResult {
        var state: SyncEngine.State
        var library: [UUID: SyncEnvelope]
        var appliedBatches: [[SyncEnvelope]]
        var base: SyncBase
    }

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-conflict-ordering-\(label)-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func envelope(
        id: UUID,
        revision: UInt64,
        device: String,
        body: String,
        name: String = "Shared snippet",
        keyword: String = "shared",
        tags: [String] = ["original"],
        x: [String: CanonicalJSON.Value] = [:]
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
                content: Data(body.utf8),
                tags: tags,
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)),
            x: x)
    }

    private func version(_ label: String) -> SyncRecordVersion {
        SyncRecordVersion(Data(label.utf8))
    }

    private func wire(
        _ envelope: SyncEnvelope,
        version: SyncRecordVersion,
        sealer: SnippetCryptoSealer
    ) throws -> WireRecord {
        var record = try WireCodec.seal(envelope, using: sealer)
        record.recordVersion = version
        return record
    }

    private func writeCheckpoint(
        ancestor: SyncEnvelope,
        directory: URL
    ) throws {
        let baseURL = directory.appendingPathComponent("base.json")
        let journalURL = directory.appendingPathComponent("journal.json")
        var base = SyncBase(
            cursor: SyncCursor("ordered-inbox-base"),
            cursorKind: .legacy,
            journalEstablished: true)
        base.recordConfirmed(ancestor, recordVersion: version("ancestor"))
        try SyncBaseFile.write(base, to: baseURL, temporaryDirectory: directory)
        try SyncJournalFile.write(
            SyncJournal(), to: journalURL, temporaryDirectory: directory)
    }

    private func run(
        label: String,
        ancestor: SyncEnvelope,
        local: [UUID: SyncEnvelope],
        incoming: [SyncEnvelope],
        sealer: SnippetCryptoSealer
    ) async throws -> RunResult {
        let directory = try directory(label)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCheckpoint(ancestor: ancestor, directory: directory)

        let records = try incoming.enumerated().map { offset, envelope in
            try wire(
                envelope,
                version: version("incoming-\(offset)"),
                sealer: sealer)
        }
        let transport = OrderedInboxTransport(records: records)
        let library = Library(local)
        let engine = SyncEngine(
            transport: transport,
            library: library,
            sealer: sealer,
            device: Self.deviceA,
            baseURL: directory.appendingPathComponent("base.json"),
            journalURL: directory.appendingPathComponent("journal.json"),
            stateURL: directory.appendingPathComponent("state.json"),
            lockURL: directory.appendingPathComponent("library.lock"),
            temporaryDirectory: directory)

        let state = await engine.sync()
        return RunResult(
            state: state,
            library: library.envelopes,
            appliedBatches: library.appliedBatches,
            base: engine.agreedBase)
    }

    @Test func laterGenerationOfOneIDSupersedesEarlierGenerationWithoutAConflictCopy() async throws {
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "ordered-generations-test")
        let ancestor = envelope(
            id: Self.originalID,
            revision: 100, device: Self.deviceA, body: "ancestor")
        let intermediate = envelope(
            id: Self.originalID,
            revision: 200, device: Self.deviceB, body: "remote intermediate")
        let latest = envelope(
            id: Self.originalID,
            revision: 300, device: Self.deviceB, body: "remote latest")

        let result = try await run(
            label: "same-id-generations",
            ancestor: ancestor,
            local: [ancestor.id: ancestor],
            incoming: [intermediate, latest],
            sealer: sealer)

        #expect(result.state.isIdle)
        #expect(result.library == [latest.id: latest],
                "a causally superseded server version is not a concurrent user edit")
        #expect(result.appliedBatches.count == 1)
        #expect(result.appliedBatches.first == [latest],
                "Core should reduce an ordered same-id prefix to its latest authority")
        #expect(result.base.envelope(latest.id) == latest)
        #expect(result.base.recordVersion(latest.id) == version("incoming-1"),
                "the CAS ancestor must come from the retained latest generation")
    }

    @Test func editedRemoteConflictCopyIsNotTreatedAsConcurrentWithItsGeneratedAncestor() async throws {
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "edited-copy-order-test")
        let ancestor = envelope(
            id: Self.originalID,
            revision: 100, device: Self.deviceA, body: "ancestor")
        let localEdit = envelope(
            id: Self.originalID,
            revision: 200, device: Self.deviceA, body: "body from A")
        let remoteWinner = envelope(
            id: Self.originalID,
            revision: 300, device: Self.deviceB, body: "body from B")
        let outcome = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: localEdit,
            remote: remoteWinner)
        let generated = try #require(outcome.conflictCopies.first)
        #expect(outcome.conflictCopies.count == 1)

        let editedCopy = envelope(
            id: generated.id,
            revision: 400,
            device: Self.deviceB,
            body: "the user edited the conflict copy",
            name: "Reviewed conflict copy",
            keyword: "",
            tags: generated.fields?.tags ?? ["conflict"],
            x: generated.x)

        let originalFirst = try await run(
            label: "edited-copy-original-first",
            ancestor: ancestor,
            local: [localEdit.id: localEdit],
            incoming: [remoteWinner, editedCopy],
            sealer: sealer)
        let copyFirst = try await run(
            label: "edited-copy-copy-first",
            ancestor: ancestor,
            local: [localEdit.id: localEdit],
            incoming: [editedCopy, remoteWinner],
            sealer: sealer)

        let expected = [remoteWinner.id: remoteWinner, editedCopy.id: editedCopy]
        #expect(originalFirst.state.isIdle)
        #expect(copyFirst.state.isIdle)
        #expect(originalFirst.library == expected,
                "the pristine generated snapshot is the edited copy's ancestor, not a rival")
        #expect(copyFirst.library == expected)
        #expect(originalFirst.library == copyFirst.library,
                "record arrival order must not decide whether a copy-of-copy is created")
        #expect(Set(originalFirst.library.keys) == [Self.originalID, generated.id])
    }

    @Test func unrelatedRecordAtGeneratedCopyIDHaltsBeforeApplyInEitherArrivalOrder() async throws {
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "copy-id-collision-test")
        let ancestor = envelope(
            id: Self.originalID,
            revision: 100, device: Self.deviceA, body: "ancestor")
        let localEdit = envelope(
            id: Self.originalID,
            revision: 200, device: Self.deviceA, body: "body from A")
        let remoteWinner = envelope(
            id: Self.originalID,
            revision: 300, device: Self.deviceB, body: "body from B")
        let outcome = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: localEdit,
            remote: remoteWinner)
        let generated = try #require(outcome.conflictCopies.first)
        #expect(outcome.conflictCopies.count == 1)

        let unrelated = envelope(
            id: generated.id,
            revision: 500,
            device: Self.deviceB,
            body: "unrelated pre-existing record",
            name: "Unrelated snippet",
            keyword: "unrelated",
            tags: ["unrelated"])

        let originalFirst = try await run(
            label: "collision-original-first",
            ancestor: ancestor,
            local: [localEdit.id: localEdit],
            incoming: [remoteWinner, unrelated],
            sealer: sealer)
        let collisionFirst = try await run(
            label: "collision-record-first",
            ancestor: ancestor,
            local: [localEdit.id: localEdit],
            incoming: [unrelated, remoteWinner],
            sealer: sealer)

        for result in [originalFirst, collisionFirst] {
            guard case .halted(let reason, _) = result.state else {
                Issue.record("a generated-id collision must halt before applying the batch")
                continue
            }
            #expect(reason == .localLibraryQuarantined)
            #expect(result.library == [localEdit.id: localEdit],
                    "neither colliding record may overwrite the other")
            #expect(result.appliedBatches.isEmpty)
        }
    }
}

private extension SyncEngine.State {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}
