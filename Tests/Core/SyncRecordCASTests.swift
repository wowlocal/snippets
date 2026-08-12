import Darwin
import Foundation
import Testing

@testable import SnippetsCore

@Suite("Sync record versions")
struct SyncRecordVersionPersistenceTests {

    private let id = UUID(uuidString: "abcdef12-1212-4212-8212-abcdef121212")!

    private func envelope(name: String = "confirmed") -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: name == "confirmed" ? 100 : 200, counter: 0, device: "aaaaaaa1"),
            origin: "aaaaaaa1",
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: name,
                keyword: "versioned",
                content: Data(name.utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: name == "confirmed" ? 1 : 2)))
    }

    private func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-record-version-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func opaqueVersionUsesClosedStrictVersionedCodable() throws {
        let expected = SyncRecordVersion(Data([0, 1, 2, 0xfe, 0xff]))
        let encoded = try JSONEncoder().encode(expected)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(Set(object.keys) == ["schemaVersion", "data"])
        #expect(object["schemaVersion"] as? Int == SyncRecordVersion.currentSchemaVersion)
        #expect(try JSONDecoder().decode(SyncRecordVersion.self, from: encoded) == expected)

        let invalidDocuments = [
            "{}",
            "{\"schemaVersion\":1}",
            "{\"data\":\"AA==\"}",
            "{\"schemaVersion\":null,\"data\":\"AA==\"}",
            "{\"schemaVersion\":1,\"data\":null}",
            "{\"schemaVersion\":\"1\",\"data\":\"AA==\"}",
            "{\"schemaVersion\":1,\"data\":7}",
            "{\"schemaVersion\":0,\"data\":\"AA==\"}",
            "{\"schemaVersion\":2,\"data\":\"AA==\"}",
            "{\"schemaVersion\":1,\"data\":\"%%%\"}",
            "{\"schemaVersion\":1,\"data\":\"AA==\",\"extra\":true}",
        ]
        for document in invalidDocuments {
            #expect(throws: (any Error).self, "must reject \(document)") {
                try JSONDecoder().decode(
                    SyncRecordVersion.self, from: Data(document.utf8))
            }
        }

        let oversized = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "data": Data(repeating: 0xa5, count: 2 * 1_024 * 1_024).base64EncodedString(),
        ])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SyncRecordVersion.self, from: oversized)
        }
    }

    @Test func legacyBaseWithoutRecordVersionsLoadsAsEmptyAndRoundTripsAdditively() throws {
        let dir = try scratch("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("base.json")
        let confirmed = envelope()
        let legacy = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": SyncBase.currentSchemaVersion,
            "journalEstablished": true,
            "envelopes": [
                SyncBase.key(id): try confirmed.canonicalData().base64EncodedString(),
            ],
        ])
        try legacy.write(to: url)

        guard case .loaded(let loaded) = SyncBaseFile.load(from: url) else {
            Issue.record("a pre-CAS base must remain readable")
            return
        }
        #expect(loaded.envelope(id) == confirmed)
        #expect(loaded.recordVersions.isEmpty)
        #expect(loaded.recordVersion(id) == nil)

        try SyncBaseFile.write(loaded, to: url, temporaryDirectory: dir)
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((rewritten["recordVersions"] as? [String: Any])?.isEmpty == true)
    }

    @Test func explicitNullMalformedAndFutureRecordVersionsMakeTheWholeBaseUnreadable() throws {
        let dir = try scratch("strict-base")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SyncBase.key(id)
        let validEnvelope = try envelope().canonicalData().base64EncodedString()
        let documents: [(String, Any)] = [
            ("null", NSNull()),
            ("array", []),
            ("null entry", [key: NSNull()]),
            ("missing version schema", [key: ["data": "AA=="]]),
            ("future nested schema", [key: ["schemaVersion": 2, "data": "AA=="]]),
            ("malformed archive", [key: ["schemaVersion": 1, "data": "%%%"]]),
            ("unknown version field", [key: [
                "schemaVersion": 1, "data": "AA==", "extra": true,
            ]]),
            ("noncanonical key", [id.uuidString.uppercased(): [
                "schemaVersion": 1, "data": "AA==",
            ]]),
        ]

        for (index, item) in documents.enumerated() {
            let url = dir.appendingPathComponent("base-\(index).json")
            let data = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": SyncBase.currentSchemaVersion,
                "journalEstablished": true,
                "envelopes": [key: validEnvelope],
                "recordVersions": item.1,
            ])
            try data.write(to: url)
            guard case .unreadable = SyncBaseFile.load(from: url) else {
                Issue.record("\(item.0) must fail closed")
                continue
            }
        }
    }

    @Test func confirmedMutationAtomicallyReplacesOrRemovesItsVersion() {
        let firstVersion = SyncRecordVersion(Data("system-fields-v1".utf8))
        let secondVersion = SyncRecordVersion(Data("system-fields-v2".utf8))
        let confirmed = envelope()
        let edited = envelope(name: "edited")
        var base = SyncBase()

        base.recordConfirmed(confirmed, recordVersion: firstVersion)
        #expect(base.envelope(id) == confirmed)
        #expect(base.recordVersion(id) == firstVersion)

        base.record(edited)
        #expect(base.envelope(id) == edited)
        #expect(base.recordVersion(id) == firstVersion,
                "ordinary envelope replacement must not silently discard CAS ancestry")

        base.recordConfirmed(confirmed, recordVersion: secondVersion)
        #expect(base.recordVersion(id) == secondVersion)

        base.recordConfirmed(edited, recordVersion: nil)
        #expect(base.envelope(id) == edited)
        #expect(base.recordVersion(id) == nil)

        base.recordConfirmed(confirmed, recordVersion: firstVersion)
        base.removeRecordVersion(id)
        #expect(base.envelope(id) == confirmed)
        #expect(base.recordVersion(id) == nil)
    }

    @Test func wireVersionIsOpaqueTransportMetadataNotPartOfEncryptedIdentity() throws {
        let sealer = PassthroughRecordVersionSealer()
        let confirmed = envelope()
        var wire = try WireCodec.seal(confirmed, using: sealer)
        let originalIdentity = WireIdentity(id: wire.id, rev: wire.rev, deleted: wire.deleted)

        wire.recordVersion = SyncRecordVersion(Data("backend-private-state".utf8))

        #expect(try WireCodec.open(wire, using: sealer) == confirmed)
        #expect(WireIdentity(id: wire.id, rev: wire.rev, deleted: wire.deleted) == originalIdentity)
    }
}

@MainActor
@Suite("Sync engine per-record CAS", .timeLimit(.minutes(1)))
struct SyncEngineRecordCASTests {

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

    private final class AcceptThenHookTransport: SyncTransport, @unchecked Sendable {
        let identifier = "accept-then-hook"
        let supportsPush = true
        let pollInterval: TimeInterval = 3_600
        let events = AsyncStream<SyncTransportEvent> { _ in }

        private let lock = NSLock()
        private let returnedVersion: SyncRecordVersion
        private var hook: (() throws -> Void)?
        private var batches: [[WireRecord]] = []

        init(returnedVersion: SyncRecordVersion, hook: @escaping () throws -> Void) {
            self.returnedVersion = returnedVersion
            self.hook = hook
        }

        var submittedBatches: [[WireRecord]] { lock.withLock { batches } }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            SyncFetch(records: [], cursor: cursor)
        }

        func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
            let oneShotHook: (() throws -> Void)? = lock.withLock {
                batches.append(records)
                defer { hook = nil }
                return hook
            }
            try oneShotHook?()
            return SyncSubmission(
                results: records.map {
                    SyncSubmitResult(
                        id: $0.id,
                        outcome: .accepted(
                            rev: $0.rev,
                            recordVersion: returnedVersion))
                },
                cursor: cursor)
        }
    }

    /// A deterministic backend with the same per-record rule CloudKit's
    /// `.ifServerRecordUnchanged` enforces. A nil version creates only when the record is
    /// absent; an update succeeds only with the exact system-fields version currently
    /// stored. Conflicts can carry the authoritative record without relying on a later
    /// change-feed page.
    private final class CASBackend: SyncTransport, @unchecked Sendable {
        let identifier = "record-cas"
        let supportsPush = true
        let pollInterval: TimeInterval = 3_600
        let events = AsyncStream<SyncTransportEvent> { _ in }

        private let lock = NSLock()
        private var stored: WireRecord?
        private var batches: [[WireRecord]] = []
        private var versionSequence = 10
        private var includeRemoteInConflictsStorage: Bool
        private var returnStoredOnFetchStorage: Bool

        init(
            stored: WireRecord?,
            includeRemoteInConflicts: Bool = true,
            returnStoredOnFetch: Bool = false
        ) {
            self.stored = stored
            includeRemoteInConflictsStorage = includeRemoteInConflicts
            returnStoredOnFetchStorage = returnStoredOnFetch
        }

        var snapshot: WireRecord? { lock.withLock { stored } }
        var submittedBatches: [[WireRecord]] { lock.withLock { batches } }

        func configure(
            includeRemoteInConflicts: Bool? = nil,
            returnStoredOnFetch: Bool? = nil
        ) {
            lock.withLock {
                if let includeRemoteInConflicts {
                    includeRemoteInConflictsStorage = includeRemoteInConflicts
                }
                if let returnStoredOnFetch {
                    returnStoredOnFetchStorage = returnStoredOnFetch
                }
            }
        }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            lock.withLock {
                let records = returnStoredOnFetchStorage ? stored.map { [$0] } ?? [] : []
                return SyncFetch(
                    records: records,
                    cursor: SyncCursor("feed-\(versionSequence)"))
            }
        }

        func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
            lock.withLock {
                batches.append(records)
                var results: [SyncSubmitResult] = []
                for offered in records {
                    if let current = stored {
                        guard offered.recordVersion != nil,
                              offered.recordVersion == current.recordVersion else {
                            results.append(SyncSubmitResult(
                                id: offered.id,
                                outcome: .rejected(.conflict(
                                    remote: includeRemoteInConflictsStorage ? current : nil))))
                            continue
                        }
                    } else if offered.recordVersion != nil {
                        results.append(SyncSubmitResult(
                            id: offered.id,
                            outcome: .rejected(.conflict(remote: nil))))
                        continue
                    }

                    versionSequence += 1
                    let acceptedVersion = SyncRecordVersion(
                        Data("server-version-\(versionSequence)".utf8))
                    var accepted = offered
                    accepted.recordVersion = acceptedVersion
                    stored = accepted
                    results.append(SyncSubmitResult(
                        id: offered.id,
                        outcome: .accepted(
                            rev: offered.rev,
                            recordVersion: acceptedVersion)))
                }
                return SyncSubmission(results: results, cursor: cursor)
            }
        }
    }

    private final class FetchHookTransport: SyncTransport, @unchecked Sendable {
        private let inner: CASBackend
        private let lock = NSLock()
        private var hook: (() throws -> Void)?

        init(inner: CASBackend, hook: @escaping () throws -> Void) {
            self.inner = inner
            self.hook = hook
        }

        var identifier: String { inner.identifier }
        var supportsPush: Bool { inner.supportsPush }
        var pollInterval: TimeInterval { inner.pollInterval }
        var events: AsyncStream<SyncTransportEvent> { inner.events }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            let fetched = try await inner.fetchChanges(since: cursor)
            let oneShotHook: (() throws -> Void)? = lock.withLock {
                defer { hook = nil }
                return hook
            }
            try oneShotHook?()
            return fetched
        }

        func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
            try await inner.submit(records, at: cursor)
        }
    }

    private struct Paths {
        let root: URL
        let baseDirectory: URL
        let journalDirectory: URL
        let temporaryDirectory: URL

        var base: URL { baseDirectory.appendingPathComponent("base.json") }
        var journal: URL { journalDirectory.appendingPathComponent("journal.json") }
        var state: URL { baseDirectory.appendingPathComponent("state.json") }
        var lock: URL { baseDirectory.appendingPathComponent("library.lock") }

        init(_ label: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "sync-record-cas-\(label)-\(UUID().uuidString)", isDirectory: true)
            baseDirectory = root.appendingPathComponent("Base", isDirectory: true)
            journalDirectory = root.appendingPathComponent("Journal", isDirectory: true)
            temporaryDirectory = root.appendingPathComponent("Tmp", isDirectory: true)
            for directory in [baseDirectory, journalDirectory, temporaryDirectory] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
        }
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", value))!
    }

    private func envelope(
        _ id: UUID,
        device: String,
        revision: UInt64,
        name: String,
        content: String
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: name,
                keyword: "record-cas",
                content: Data(content.utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)))
    }

    private func content(_ envelope: SyncEnvelope?) -> String? {
        envelope?.fields.flatMap { String(data: $0.content, encoding: .utf8) }
    }

    private func engine(
        transport: any SyncTransport,
        library: Library,
        paths: Paths
    ) -> SyncEngine {
        SyncEngine(
            transport: transport,
            library: library,
            sealer: PassthroughRecordVersionSealer(),
            device: Self.deviceA,
            baseURL: paths.base,
            journalURL: paths.journal,
            stateURL: paths.state,
            lockURL: paths.lock,
            temporaryDirectory: paths.temporaryDirectory)
    }

    @Test func outgoingOfferCarriesAncestorVersionAndAcceptedVersionFencesJournalAck() async throws {
        let paths = try Paths("accepted-fence")
        defer {
            _ = chmod(paths.journalDirectory.path, 0o700)
            try? FileManager.default.removeItem(at: paths.root)
        }
        let snippetID = id(1)
        let ancestor = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            name: "ancestor", content: "ancestor body")
        let edited = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            name: "ancestor", content: "edited body")
        let ancestorVersion = SyncRecordVersion(Data("ancestor-system-fields".utf8))
        let acceptedVersion = SyncRecordVersion(Data("accepted-system-fields".utf8))
        var base = SyncBase(cursor: SyncCursor("old-cursor"), journalEstablished: true)
        base.recordConfirmed(ancestor, recordVersion: ancestorVersion)
        try SyncBaseFile.write(
            base, to: paths.base, temporaryDirectory: paths.temporaryDirectory)
        try SyncJournalFile.write(
            SyncJournal(), to: paths.journal, temporaryDirectory: paths.temporaryDirectory)

        let transport = AcceptThenHookTransport(returnedVersion: acceptedVersion) {
            guard chmod(paths.journalDirectory.path, 0o500) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let library = Library()
        library.envelopes[snippetID] = edited
        let firstEngine = engine(transport: transport, library: library, paths: paths)

        let state = await firstEngine.sync()
        guard case .halted(let reason, _) = state else {
            Issue.record("journal ACK failure must halt")
            return
        }
        #expect(reason == .localLibraryQuarantined)
        let submitted = try #require(transport.submittedBatches.first?.first)
        #expect(submitted.recordVersion == ancestorVersion,
                "the exact offer must carry the version of its confirmed ancestor")

        guard case .loaded(let durableBase) = SyncBaseFile.load(from: paths.base) else {
            Issue.record("accepted confirmation must already be durable")
            return
        }
        #expect(durableBase.envelope(snippetID) == edited)
        #expect(durableBase.recordVersion(snippetID) == acceptedVersion)

        guard case .loaded(let durableJournal) = SyncJournalFile.load(from: paths.journal) else {
            Issue.record("pre-ACK journal must remain readable")
            return
        }
        #expect(durableJournal.entry(snippetID)?.offered?.envelope == edited,
                "base persistence must precede forgetting the ambiguous offer")
        #expect(durableJournal.entry(snippetID)?.offered?.recordVersion == ancestorVersion,
                "the journal must freeze the exact CAS ancestor alongside the offered bytes")

        #expect(chmod(paths.journalDirectory.path, 0o700) == 0)
        var acceptedOnServer = submitted
        acceptedOnServer.recordVersion = acceptedVersion
        let restartedTransport = CASBackend(stored: acceptedOnServer)
        let restarted = engine(
            transport: restartedTransport, library: library, paths: paths)
        #expect(restarted.state.isHalted)
        restarted.clearHaltAfterUserReview()
        _ = await restarted.sync()
        #expect(restartedTransport.submittedBatches.isEmpty,
                "restart must finish the ACK from durable base instead of resubmitting")
    }

    @Test func fetchedVersionIsDurableBeforeCursorAndStaleOfferReplayCannotOverwriteRemote() async throws {
        let paths = try Paths("fetch-fence")
        defer {
            _ = chmod(paths.journalDirectory.path, 0o700)
            try? FileManager.default.removeItem(at: paths.root)
        }
        let snippetID = id(2)
        let ancestor = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            name: "ancestor name", content: "ancestor body")
        let local = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            name: "ancestor name", content: "local body")
        let independentRemote = envelope(
            snippetID, device: Self.deviceB, revision: 300,
            name: "remote name", content: "ancestor body")
        let ancestorVersion = SyncRecordVersion(Data("version-A".utf8))
        let remoteVersion = SyncRecordVersion(Data("version-B".utf8))
        var remoteWire = try WireCodec.seal(
            independentRemote, using: PassthroughRecordVersionSealer())
        remoteWire.recordVersion = remoteVersion
        let backend = CASBackend(
            stored: remoteWire,
            includeRemoteInConflicts: false,
            returnStoredOnFetch: true)

        var base = SyncBase(cursor: SyncCursor("cursor-before-B"), journalEstablished: true)
        base.recordConfirmed(ancestor, recordVersion: ancestorVersion)
        try SyncBaseFile.write(
            base, to: paths.base, temporaryDirectory: paths.temporaryDirectory)
        var journal = SyncJournal()
        journal.reconcile(
            current: [snippetID: local], confirmed: base,
            deviceID: Self.deviceA, now: Date(timeIntervalSince1970: 1))
        journal.markOffered(journal.pending(confirmed: base), confirmed: base)
        try SyncJournalFile.write(
            journal, to: paths.journal, temporaryDirectory: paths.temporaryDirectory)
        let journalBytes = try Data(contentsOf: paths.journal)

        let faulting = FetchHookTransport(inner: backend) {
            guard chmod(paths.journalDirectory.path, 0o500) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let library = Library()
        library.envelopes[snippetID] = local
        let first = engine(transport: faulting, library: library, paths: paths)
        let failed = await first.sync()
        guard case .halted(let reason, _) = failed else {
            Issue.record("journal resolution failure must halt")
            return
        }
        #expect(reason == .localLibraryQuarantined)
        #expect(chmod(paths.journalDirectory.path, 0o700) == 0)

        guard case .loaded(let baseAfterFetch) = SyncBaseFile.load(from: paths.base) else {
            Issue.record("fetched server record must already be durable")
            return
        }
        #expect(baseAfterFetch.envelope(snippetID) == independentRemote)
        #expect(baseAfterFetch.recordVersion(snippetID) == remoteVersion)
        #expect(baseAfterFetch.cursor == SyncCursor("cursor-before-B"),
                "cursor must remain behind the fetched version until journal resolution")
        #expect(try Data(contentsOf: paths.journal) == journalBytes)
        #expect(library.envelopes[snippetID]?.fields?.name == "remote name")
        #expect(content(library.envelopes[snippetID]) == "local body")

        // Re-run from that exact crash image. If the engine attaches B's newly fetched
        // version to the still-frozen offer A, CAS accepts A and destroys B. The replay
        // must use A's exact durably captured ancestor version, never borrow B's
        // version.
        backend.configure(
            includeRemoteInConflicts: true,
            returnStoredOnFetch: false)
        let restarted = engine(transport: backend, library: library, paths: paths)
        #expect(restarted.state.isHalted)
        restarted.clearHaltAfterUserReview()
        _ = await restarted.sync()

        let replayedOffer = try #require(backend.submittedBatches.last?.first)
        #expect(replayedOffer.recordVersion == ancestorVersion,
                "a stale journal offer must retain its own exact ancestor version")
        #expect(try WireCodec.open(
            try #require(backend.snapshot),
            using: PassthroughRecordVersionSealer()) == independentRemote,
                "first replay must not overwrite the independent remote edit")
        #expect(library.envelopes[snippetID]?.fields?.name == "remote name")
        #expect(content(library.envelopes[snippetID]) == "local body")

        _ = await restarted.sync()
        let mergedWire = try #require(backend.snapshot)
        let merged = try WireCodec.open(
            mergedWire, using: PassthroughRecordVersionSealer())
        #expect(merged.fields?.name == "remote name")
        #expect(content(merged) == "local body")
        let retriedMerge = try #require(backend.submittedBatches.last?.first)
        #expect(retriedMerge.recordVersion == remoteVersion,
                "the rebased merge must retry against the fetched authoritative version")
    }

    @Test func conflictWithoutRemoteIsResolvedByNormalFetchAndMergedRetryUsesFetchedVersion() async throws {
        let paths = try Paths("nil-conflict-fetch")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let snippetID = id(4)
        let ancestor = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            name: "ancestor name", content: "ancestor body")
        let local = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            name: "ancestor name", content: "local body")
        let independentRemote = envelope(
            snippetID, device: Self.deviceB, revision: 300,
            name: "remote name", content: "ancestor body")
        let ancestorVersion = SyncRecordVersion(Data("nil-conflict-A".utf8))
        let remoteVersion = SyncRecordVersion(Data("nil-conflict-B".utf8))
        var remoteWire = try WireCodec.seal(
            independentRemote, using: PassthroughRecordVersionSealer())
        remoteWire.recordVersion = remoteVersion
        let backend = CASBackend(
            stored: remoteWire,
            includeRemoteInConflicts: false,
            returnStoredOnFetch: true)

        let oldCursor = SyncCursor("before-authoritative-B")
        var base = SyncBase(cursor: oldCursor, journalEstablished: true)
        base.recordConfirmed(ancestor, recordVersion: ancestorVersion)
        try SyncBaseFile.write(
            base, to: paths.base, temporaryDirectory: paths.temporaryDirectory)
        try SyncJournalFile.write(
            SyncJournal(), to: paths.journal, temporaryDirectory: paths.temporaryDirectory)
        let library = Library()
        library.envelopes[snippetID] = local
        let syncEngine = engine(transport: backend, library: library, paths: paths)

        let firstState = await syncEngine.sync()
        guard case .idle = firstState else {
            Issue.record("a normal fetch of B/V2 must resolve conflict(nil), got \(firstState)")
            return
        }
        let staleAttempt = try #require(backend.submittedBatches.first?.first)
        #expect(staleAttempt.recordVersion == ancestorVersion)
        #expect(try WireCodec.open(
            try #require(backend.snapshot),
            using: PassthroughRecordVersionSealer()) == independentRemote,
                "the stale offer must not overwrite B before it is rebased")

        guard case .loaded(let fetchedBase) = SyncBaseFile.load(from: paths.base) else {
            Issue.record("the normally fetched B/V2 must be durable")
            return
        }
        #expect(fetchedBase.envelope(snippetID) == independentRemote)
        #expect(fetchedBase.recordVersion(snippetID) == remoteVersion)
        #expect(fetchedBase.cursor != oldCursor)
        guard case .loaded(let rebasedJournal) = SyncJournalFile.load(from: paths.journal) else {
            Issue.record("the stale offer must resolve into durable merged intent")
            return
        }
        #expect(rebasedJournal.entry(snippetID)?.offered == nil,
                "a fetched authoritative value must not leave conflict(nil) pinned")
        let mergedDesired = try #require(rebasedJournal.entry(snippetID)?.desired)
        #expect(mergedDesired.fields?.name == "remote name")
        #expect(content(mergedDesired) == "local body")

        backend.configure(returnStoredOnFetch: false)
        let secondState = await syncEngine.sync()
        guard case .idle = secondState else {
            Issue.record("the rebased desired value must be immediately retryable")
            return
        }
        let retried = try #require(backend.submittedBatches.last?.first)
        #expect(backend.submittedBatches.count == 2)
        #expect(retried.recordVersion == remoteVersion,
                "the merge must retry with B's fetched server generation")
        let acceptedMerge = try WireCodec.open(
            try #require(backend.snapshot),
            using: PassthroughRecordVersionSealer())
        #expect(acceptedMerge.fields?.name == "remote name")
        #expect(content(acceptedMerge) == "local body")
    }

    @Test func conflictWithoutRemoteAndEmptyFetchRetainsOfferCursorAndRetryableState() async throws {
        let paths = try Paths("nil-conflict-empty-fetch")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let snippetID = id(5)
        let ancestor = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            name: "ancestor", content: "ancestor body")
        let local = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            name: "ancestor", content: "local body")
        let independentRemote = envelope(
            snippetID, device: Self.deviceB, revision: 300,
            name: "remote", content: "remote body")
        let ancestorVersion = SyncRecordVersion(Data("empty-fetch-A".utf8))
        let remoteVersion = SyncRecordVersion(Data("empty-fetch-B".utf8))
        var remoteWire = try WireCodec.seal(
            independentRemote, using: PassthroughRecordVersionSealer())
        remoteWire.recordVersion = remoteVersion
        let backend = CASBackend(
            stored: remoteWire,
            includeRemoteInConflicts: false,
            returnStoredOnFetch: false)

        let oldCursor = SyncCursor("cursor-before-empty-fetch")
        var base = SyncBase(cursor: oldCursor, journalEstablished: true)
        base.recordConfirmed(ancestor, recordVersion: ancestorVersion)
        try SyncBaseFile.write(
            base, to: paths.base, temporaryDirectory: paths.temporaryDirectory)
        try SyncJournalFile.write(
            SyncJournal(), to: paths.journal, temporaryDirectory: paths.temporaryDirectory)
        let library = Library()
        library.envelopes[snippetID] = local
        let syncEngine = engine(transport: backend, library: library, paths: paths)

        let state = await syncEngine.sync()
        guard case .offline = state else {
            Issue.record("unresolved conflict(nil) must remain retryable, got \(state)")
            return
        }
        guard case .loaded(let retainedBase) = SyncBaseFile.load(from: paths.base) else {
            Issue.record("the pre-conflict base must remain readable")
            return
        }
        #expect(retainedBase.envelope(snippetID) == ancestor)
        #expect(retainedBase.recordVersion(snippetID) == ancestorVersion)
        #expect(retainedBase.cursor == oldCursor,
                "an empty fetch cannot advance past an unresolved conflict")
        guard case .loaded(let retainedJournal) = SyncJournalFile.load(from: paths.journal) else {
            Issue.record("the unresolved offered snapshot must remain durable")
            return
        }
        #expect(retainedJournal.entry(snippetID)?.offered?.envelope == local)
        #expect(retainedJournal.entry(snippetID)?.offered?.recordVersion == ancestorVersion)
        #expect(retainedJournal.pending(confirmed: retainedBase) == [local])
        #expect(backend.submittedBatches.count == 1)
        #expect(try WireCodec.open(
            try #require(backend.snapshot),
            using: PassthroughRecordVersionSealer()) == independentRemote)
    }

    @Test func authoritativeConflictRecordRebasesLegacyBaseAndRetriesWithItsVersion() async throws {
        let paths = try Paths("authoritative-conflict")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let snippetID = id(3)
        let ancestor = envelope(
            snippetID, device: Self.deviceA, revision: 100,
            name: "ancestor name", content: "ancestor body")
        let local = envelope(
            snippetID, device: Self.deviceA, revision: 200,
            name: "ancestor name", content: "local body")
        let independentRemote = envelope(
            snippetID, device: Self.deviceB, revision: 300,
            name: "remote name", content: "ancestor body")
        let remoteVersion = SyncRecordVersion(Data("authoritative-B".utf8))
        var remoteWire = try WireCodec.seal(
            independentRemote, using: PassthroughRecordVersionSealer())
        remoteWire.recordVersion = remoteVersion
        let backend = CASBackend(stored: remoteWire)

        // This is the migration shape: the envelope/cursor predate saved system fields.
        // Its first update must be a nil-version conditional create, not an unconditional
        // overwrite of the record already in CloudKit.
        var legacyBase = SyncBase(
            cursor: SyncCursor("legacy-cursor"), journalEstablished: true)
        legacyBase.record(ancestor)
        try SyncBaseFile.write(
            legacyBase, to: paths.base, temporaryDirectory: paths.temporaryDirectory)
        try SyncJournalFile.write(
            SyncJournal(), to: paths.journal, temporaryDirectory: paths.temporaryDirectory)
        let library = Library()
        library.envelopes[snippetID] = local
        let syncEngine = engine(transport: backend, library: library, paths: paths)

        _ = await syncEngine.sync()

        let firstOffer = try #require(backend.submittedBatches.first?.first)
        #expect(firstOffer.recordVersion == nil)
        #expect(try WireCodec.open(
            try #require(backend.snapshot),
            using: PassthroughRecordVersionSealer()) == independentRemote,
                "the legacy attempt must conflict instead of overwriting the server")
        #expect(syncEngine.agreedBase.envelope(snippetID) == independentRemote)
        #expect(syncEngine.agreedBase.recordVersion(snippetID) == remoteVersion)
        #expect(library.envelopes[snippetID]?.fields?.name == "remote name")
        #expect(content(library.envelopes[snippetID]) == "local body")

        _ = await syncEngine.sync()

        let secondOffer = try #require(backend.submittedBatches.last?.first)
        #expect(secondOffer.recordVersion == remoteVersion)
        let merged = try WireCodec.open(
            try #require(backend.snapshot),
            using: PassthroughRecordVersionSealer())
        #expect(merged.fields?.name == "remote name")
        #expect(content(merged) == "local body")
    }
}

private struct PassthroughRecordVersionSealer: SyncBlobSealing {
    func seal(_ plaintext: Data, for identity: WireIdentity) throws -> Data { plaintext }
    func open(_ ciphertext: Data, for identity: WireIdentity) throws -> Data { ciphertext }
}
