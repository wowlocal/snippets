import Foundation
import Testing

@testable import SnippetsCore

/// The transport inbox is an ordered generation log, not an unordered set of rivals.
/// An opaque generation blocks only while it is the latest occurrence for that id; a
/// later valid generation supersedes it and must be applied and acknowledged normally.
@MainActor
@Suite("Opaque sync generation ordering", .timeLimit(.minutes(1)))
struct SyncOpaqueGenerationOrderingTests {

    private static let recordID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000031")!
    private static let device = "aaaaaaa1"

    private final class Library: SyncLibraryAccess {
        private(set) var envelopes: [UUID: SyncEnvelope] = [:]
        private(set) var appliedBatches: [[SyncEnvelope]] = []

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
            for envelope in incoming { envelopes[envelope.id] = envelope }
            return ApplyOutcome(changedIDs: incoming.map(\.id))
        }

        func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
    }

    private final class OrderedTransport: SyncTransport, @unchecked Sendable {
        let identifier = "opaque-generation-ordering-test"
        let supportsPush = true
        let pollInterval: TimeInterval = 30
        let events: AsyncStream<SyncTransportEvent> = AsyncStream { _ in }

        private let records: [WireRecord]
        private let deliveredCursor: SyncCursor
        private let baseURL: URL
        private let lock = NSLock()
        private var acknowledgementsStorage: [String?] = []
        private var baseCursorsObservedAtAcknowledgementStorage: [String?] = []

        init(records: [WireRecord], deliveredCursor: SyncCursor, baseURL: URL) {
            self.records = records
            self.deliveredCursor = deliveredCursor
            self.baseURL = baseURL
        }

        var acknowledgements: [String?] {
            lock.withLock { acknowledgementsStorage }
        }

        var baseCursorsObservedAtAcknowledgement: [String?] {
            lock.withLock { baseCursorsObservedAtAcknowledgementStorage }
        }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            SyncFetch(
                records: records,
                cursor: deliveredCursor,
                cursorKind: .legacy,
                hasMore: false,
                isFullResync: false)
        }

        func submit(
            _ records: [WireRecord], at cursor: SyncCursor?
        ) async throws -> SyncSubmission {
            SyncSubmission(
                results: records.map {
                    SyncSubmitResult(
                        id: $0.id,
                        outcome: .rejected(.rateLimited(retryAfter: 1)))
                },
                cursor: cursor)
        }

        func acknowledgeFetched(through cursor: SyncCursor?) async throws {
            let persistedCursor: String?
            if case .loaded(let base) = SyncBaseFile.load(from: baseURL) {
                persistedCursor = base.cursor?.rawValue
            } else {
                persistedCursor = nil
            }
            lock.withLock {
                acknowledgementsStorage.append(cursor?.rawValue)
                baseCursorsObservedAtAcknowledgementStorage.append(persistedCursor)
            }
        }
    }

    @Test func opaqueThenValidForSameIDAppliesLatestAndAdvancesDurableCursorBeforeACK() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-opaque-then-valid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseURL = directory.appendingPathComponent("base.json")
        let journalURL = directory.appendingPathComponent("journal.json")
        let deliveredCursor = SyncCursor("opaque-then-valid-cursor")
        let latestVersion = SyncRecordVersion(Data("latest-valid-generation".utf8))
        let latest = SyncEnvelope(
            id: Self.recordID,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.device),
            origin: Self.device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Latest valid generation",
                keyword: "latest-valid",
                content: Data("latest valid body".utf8),
                tags: ["ordered"],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)),
            x: [:])
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "opaque-generation-ordering-test")
        var validRecord = try WireCodec.seal(latest, using: sealer)
        validRecord.recordVersion = latestVersion
        let opaqueRecord = WireRecord(
            id: Self.recordID,
            rev: "earlier-opaque-generation",
            deleted: false,
            blob: Data("not an authenticated wire envelope".utf8),
            recordVersion: SyncRecordVersion(Data("earlier-opaque-generation".utf8)))

        let transport = OrderedTransport(
            records: [opaqueRecord, validRecord],
            deliveredCursor: deliveredCursor,
            baseURL: baseURL)
        let library = Library()
        let engine = SyncEngine(
            transport: transport,
            library: library,
            sealer: sealer,
            device: Self.device,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: directory.appendingPathComponent("state.json"),
            lockURL: directory.appendingPathComponent("library.lock"),
            temporaryDirectory: directory)

        let state = await engine.sync()

        guard case .idle = state else {
            Issue.record("the later valid generation should complete the round, got \(state)")
            return
        }
        #expect(library.envelopes == [Self.recordID: latest])
        #expect(library.appliedBatches == [[latest]],
                "the earlier opaque generation must neither apply nor suppress latest valid")
        #expect(engine.agreedBase.envelope(Self.recordID) == latest)
        #expect(engine.agreedBase.recordVersion(Self.recordID) == latestVersion)
        #expect(engine.agreedBase.cursor == deliveredCursor,
                "a superseded opaque generation must not pin the fetch cursor")
        #expect(transport.acknowledgements == [deliveredCursor.rawValue],
                "the transport inbox prefix should be acknowledged exactly once")
        #expect(transport.baseCursorsObservedAtAcknowledgement == [deliveredCursor.rawValue],
                "Core must fsync its advanced cursor before acknowledging the inbox prefix")
    }
}
