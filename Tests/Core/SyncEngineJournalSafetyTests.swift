import Foundation
import Testing

@testable import SnippetsCore

/// Integration boundary between durable journal loading and the sync loop.
///
/// A journal is pending user intent. Treating an existing unreadable/future file as an
/// empty one would permit both a fetch that overwrites local intent and a submit built
/// from incomplete knowledge. These tests therefore assert on transport call counts,
/// not only on the status label shown by the engine.
@MainActor
@Suite("Sync engine journal safety", .timeLimit(.minutes(1)))
struct SyncEngineJournalSafetyTests {

    // MARK: - Fixtures

    private static let device = "aaaaaaa1"

    private struct ScratchDirectory {
        let url: URL

        init(_ label: String) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "sync-engine-journal-safety-\(label)-\(UUID().uuidString)",
                isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func file(_ name: String) -> URL {
            url.appendingPathComponent(name, isDirectory: false)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

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

    /// No randomness is needed for a test that must stop before transport. The one
    /// post-repair fetch is empty, so this seam remains unused there too.
    private struct PassthroughSealer: SyncBlobSealing {
        func seal(_ plaintext: Data, for identity: WireIdentity) throws -> Data { plaintext }
        func open(_ ciphertext: Data, for identity: WireIdentity) throws -> Data { ciphertext }
    }

    private struct Harness {
        let scratch: ScratchDirectory
        let journalURL: URL
        let transport: InMemoryTransport
        let engine: SyncEngine
    }

    private func harness(label: String, journalData: Data) throws -> Harness {
        let scratch = try ScratchDirectory(label)
        let journalURL = scratch.file("journal.json")
        try journalData.write(to: journalURL)
        let transport = InMemoryTransport()
        let library = Library()
        let engine = SyncEngine(
            transport: transport,
            library: library,
            sealer: PassthroughSealer(),
            device: Self.device,
            baseURL: scratch.file("base.json"),
            journalURL: journalURL,
            stateURL: scratch.file("state.json"),
            lockURL: scratch.file("library.lock"),
            temporaryDirectory: scratch.file("Tmp"))
        return Harness(
            scratch: scratch, journalURL: journalURL, transport: transport, engine: engine)
    }

    private enum BaseDamage: Sendable {
        case missing
        case corrupt
    }

    private enum MissingJournalRecovery: Sendable {
        case restoreJournal
        case deleteBoth
    }

    /// The exact top-level shape understood by the build shipped before the additive
    /// journal marker. Synthesized decoding deliberately ignores unknown keys.
    private struct LegacyBaseDecoder: Decodable {
        var schemaVersion: Int
        var envelopes: [String: String]
        var cursor: SyncCursor?
    }

    /// The schema gate in the build immediately before CKSyncEngine. Synthesized
    /// decoding would ignore `cursorKind`, so the version check is the actual fence.
    private struct SchemaTwoBaseReader: Decodable {
        private enum CodingKeys: String, CodingKey {
            case schemaVersion
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .schemaVersion)
            guard (1...2).contains(version) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: container,
                    debugDescription: "unsupported sync-base schema version")
            }
        }
    }

    private func envelope(_ id: UUID) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 1_000, counter: 0, device: Self.device),
            origin: Self.device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "fixed",
                keyword: "fixed",
                content: Data("fixed body".utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSinceReferenceDate: 10),
                updatedAt: Date(timeIntervalSinceReferenceDate: 20)))
    }

    private func secureEnvelope(
        _ id: UUID,
        revision: UInt64,
        content: String
    ) -> SyncEnvelope {
        SyncEnvelope.secureRecord(
            id: id,
            name: "secure",
            keyword: "secure",
            plaintext: Data(content.utf8),
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: Double(revision)),
            hlc: HLC(wallMs: revision, counter: 0, device: Self.device),
            origin: Self.device,
            x: [SyncEnvelope.vaultKeyIDExtensionKey: .string("rollback-vault")])
    }

    private func expectNoTransportCalls(
        _ transport: InMemoryTransport,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(transport.submittedBatches.isEmpty, sourceLocation: sourceLocation)
        #expect(transport.fetchAttempts == 0, sourceLocation: sourceLocation)
    }

    // MARK: - Fail closed before transport

    @Test func baseLoadRejectsSyntacticallyValidTruncationsAndInvalidEnvelopes() throws {
        let scratch = try ScratchDirectory("strict-base-decode")
        defer { scratch.remove() }
        let envelopeID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let wrongID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let canonicalEnvelope = try envelope(envelopeID).canonicalData().base64EncodedString()
        let malformedEnvelope = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": SyncBase.currentSchemaVersion,
            "journalEstablished": false,
            "envelopes": [SyncBase.key(envelopeID): "not-base64"],
        ])
        let invalidEnvelopeKey = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": SyncBase.currentSchemaVersion,
            "journalEstablished": false,
            "envelopes": [SyncBase.key(wrongID): canonicalEnvelope],
        ])
        let documents: [(label: String, data: Data)] = [
            ("empty object", Data("{}".utf8)),
            ("missing envelopes", Data("{\"schemaVersion\":1}".utf8)),
            ("null envelopes", Data("{\"schemaVersion\":1,\"envelopes\":null}".utf8)),
            ("wrong envelopes shape", Data("{\"schemaVersion\":1,\"envelopes\":[]}".utf8)),
            ("null journal marker", Data(
                "{\"schemaVersion\":1,\"envelopes\":{},\"journalEstablished\":null}".utf8)),
            ("malformed envelope", malformedEnvelope),
            ("envelope stored under a different key", invalidEnvelopeKey),
        ]

        for (index, document) in documents.enumerated() {
            let url = scratch.file("base-\(index).json")
            try document.data.write(to: url)
            guard case .unreadable = SyncBaseFile.load(from: url) else {
                Issue.record("\(document.label) must fail closed instead of loading an empty base")
                continue
            }
        }
    }

    @Test func currentBaseRejectsUnknownFutureTopLevelField() throws {
        let scratch = try ScratchDirectory("strict-base-future-field")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let futureField = "cursorGenerationKindV4"
        let document = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": SyncBase.currentSchemaVersion,
                "envelopes": [:],
                "recordVersions": [:],
                "journalEstablished": true,
                "requiresNonDestructiveLibraryMerge": false,
                futureField: "unknown-protocol-sentinel",
            ],
            options: [.sortedKeys])
        try document.write(to: baseURL)

        guard case .unreadable = SyncBaseFile.load(from: baseURL) else {
            Issue.record(
                "an unknown future field must not be ignored and erased on the next write")
            return
        }
        #expect(try Data(contentsOf: baseURL) == document)
    }

    @Test func currentBaseCannotLoseItsRequiredLibraryRecoveryFenceField() throws {
        let scratch = try ScratchDirectory("strict-base-recovery-fence")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        try SyncBaseFile.write(
            SyncBase(journalEstablished: true),
            to: baseURL,
            temporaryDirectory: scratch.file("Tmp"))
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: baseURL)) as? [String: Any])
        object.removeValue(forKey: "requiresNonDestructiveLibraryMerge")
        try JSONSerialization.data(withJSONObject: object).write(to: baseURL)

        guard case .unreadable = SyncBaseFile.load(from: baseURL) else {
            Issue.record("stripping the crash fence must fail closed, not decode as false")
            return
        }
    }

    @Test func schemaFiveRecoveryFenceRequiresItsExactReviewedSnapshotMode() throws {
        let scratch = try ScratchDirectory("strict-base-recovery-mode")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let reviewed = SyncBase(
            journalEstablished: true,
            requiresNonDestructiveLibraryMerge: true,
            nonDestructiveMergeMode: .reviewedLocalSnapshot)
        try SyncBaseFile.write(
            reviewed,
            to: baseURL,
            temporaryDirectory: scratch.file("Tmp"))
        guard case .loaded(let roundTrip) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("the schema-5 reviewed recovery fence must round trip")
            return
        }
        #expect(roundTrip.nonDestructiveMergeMode == .reviewedLocalSnapshot)

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: baseURL)) as? [String: Any])
        object.removeValue(forKey: "nonDestructiveMergeMode")
        try JSONSerialization.data(withJSONObject: object).write(to: baseURL)
        guard case .unreadable = SyncBaseFile.load(from: baseURL) else {
            Issue.record("a schema-5 recovery fence without its mode must fail closed")
            return
        }
    }

    @Test func legacySchemaOneWithoutJournalMarkerLoadsAndMigratesOnFirstRound() async throws {
        let scratch = try ScratchDirectory("legacy-base-migration")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let journalURL = scratch.file("journal.json")
        try Data("{\"schemaVersion\":1,\"envelopes\":{}}".utf8).write(to: baseURL)

        guard case .loaded(let legacy) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("schema-1 base without the later marker must remain readable")
            return
        }
        #expect(legacy.schemaVersion == 1)
        #expect(!legacy.journalEstablished)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))

        let transport = InMemoryTransport()
        let engine = SyncEngine(
            transport: transport,
            library: Library(),
            sealer: PassthroughSealer(),
            device: Self.device,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: scratch.file("state.json"),
            lockURL: scratch.file("library.lock"),
            temporaryDirectory: scratch.file("Tmp"))
        #expect(!engine.state.isHalted,
                "a pre-marker installation is the one legitimate base-without-journal shape")
        _ = await engine.sync()

        guard case .loaded(let migrated) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("first round should rewrite the legacy base in the current schema")
            return
        }
        #expect(migrated.schemaVersion == SyncBase.currentSchemaVersion)
        #expect(migrated.journalEstablished)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test func accountBindingAndCursorKindForceADowngradeSafeBaseSchemaBump() throws {
        let scratch = try ScratchDirectory("marker-downgrade")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let snippetID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        var current = SyncBase(cursor: SyncCursor("91"), journalEstablished: true)
        current.record(envelope(snippetID))
        try SyncBaseFile.write(
            current, to: baseURL, temporaryDirectory: scratch.file("Tmp"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseBytes = try Data(contentsOf: baseURL)
        let legacy = try decoder.decode(LegacyBaseDecoder.self, from: baseBytes)

        #expect(legacy.schemaVersion == SyncBase.currentSchemaVersion)
        #expect(legacy.schemaVersion == 7,
                "schema 7 must stop older builds before they ignore review-epoch identity; two-phase recovery ancestry, dataset, cursor-kind and account fences remain intact")
        #expect(throws: (any Error).self) {
            try decoder.decode(SchemaTwoBaseReader.self, from: baseBytes)
        }
        #expect(legacy.cursor == current.cursor)
        #expect(Set(legacy.envelopes.keys) == [SyncBase.key(snippetID)])
    }

    @Test func firstFreshEngineRoundDurablyEstablishesJournalMarker() async throws {
        let scratch = try ScratchDirectory("fresh-marker")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let journalURL = scratch.file("journal.json")
        let transport = InMemoryTransport()
        let engine = SyncEngine(
            transport: transport,
            library: Library(),
            sealer: PassthroughSealer(),
            device: Self.device,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: scratch.file("state.json"),
            lockURL: scratch.file("library.lock"),
            temporaryDirectory: scratch.file("Tmp"))

        _ = await engine.sync()

        guard case .loaded(let established) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("first round must leave a readable confirmed base")
            return
        }
        #expect(established.journalEstablished)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(transport.fetchAttempts == 1)
    }

    @Test(arguments: [
        MissingJournalRecovery.restoreJournal,
        MissingJournalRecovery.deleteBoth,
    ])
    private func markedBaseWithMissingJournalHaltsUntilExplicitRecovery(
        recovery: MissingJournalRecovery
    ) async throws {
        let scratch = try ScratchDirectory("missing-marked-journal-\(recovery)")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let journalURL = scratch.file("journal.json")
        try SyncBaseFile.write(
            SyncBase(journalEstablished: true),
            to: baseURL,
            temporaryDirectory: scratch.file("Tmp"))
        let transport = InMemoryTransport()
        let engine = SyncEngine(
            transport: transport,
            library: Library(),
            sealer: PassthroughSealer(),
            device: Self.device,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: scratch.file("state.json"),
            lockURL: scratch.file("library.lock"),
            temporaryDirectory: scratch.file("Tmp"))

        guard case .halted(let reason, let detail) = engine.state else {
            Issue.record("marked base with a missing journal must halt at initialization")
            return
        }
        #expect(reason == .localLibraryQuarantined)
        #expect(detail.contains("journal"))
        _ = await engine.sync()
        expectNoTransportCalls(transport)
        engine.performRecovery(.checkAgain)
        #expect(engine.state.isHalted, "Resume alone must not synthesize the missing journal")
        expectNoTransportCalls(transport)

        switch recovery {
        case .restoreJournal:
            try SyncJournalFile.write(
                SyncJournal(), to: journalURL, temporaryDirectory: scratch.file("Tmp"))
        case .deleteBoth:
            try FileManager.default.removeItem(at: baseURL)
        }
        engine.performRecovery(.checkAgain)
        #expect(!engine.state.isHalted)
        _ = await engine.sync()
        #expect(transport.fetchAttempts == 1)
    }

    @Test func repairedBaseCannotMakeResumeForgetThatJournalIsMissing() async throws {
        let scratch = try ScratchDirectory("repair-base-without-journal")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let journalURL = scratch.file("journal.json")
        try Data("{\"schemaVersion\":1,\"envelopes\":null}".utf8).write(to: baseURL)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))

        let transport = InMemoryTransport()
        let engine = SyncEngine(
            transport: transport,
            library: Library(),
            sealer: PassthroughSealer(),
            device: Self.device,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: scratch.file("state.json"),
            lockURL: scratch.file("library.lock"),
            temporaryDirectory: scratch.file("Tmp"))

        guard case .halted(let initialReason, _) = engine.state else {
            Issue.record("an unreadable base must halt before its replacement is reviewed")
            return
        }
        #expect(initialReason == .localLibraryQuarantined)
        expectNoTransportCalls(transport)

        // Repair only the file that caused the initial halt. Its marker changes the
        // meaning of the still-missing journal: Resume must re-read the pair and retain
        // the stop rather than carrying the init-time empty journal across the review.
        try SyncBaseFile.write(
            SyncBase(cursor: SyncCursor("19"), journalEstablished: true),
            to: baseURL,
            temporaryDirectory: scratch.file("Tmp"))
        engine.performRecovery(.checkAgain)

        guard case .halted(let resumedReason, let detail) = engine.state else {
            Issue.record("repairing base alone must not bypass the missing-journal fence")
            return
        }
        #expect(resumedReason == .localLibraryQuarantined)
        #expect(detail.contains("journal"))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path),
                "Resume must not manufacture the missing evidence")
        _ = await engine.sync()
        expectNoTransportCalls(transport)
    }

    @Test func rollbackCrashAfterJournalRestoreKeepsIntentAndLooksStructurallyValid() throws {
        let scratch = try ScratchDirectory("rollback-between-legs")
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let journalURL = scratch.file("journal.json")
        let snippetID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let confirmed = secureEnvelope(snippetID, revision: 100, content: "confirmed")
        let offered = secureEnvelope(snippetID, revision: 200, content: "offered")
        let desired = secureEnvelope(snippetID, revision: 300, content: "newer desired")

        // Forget's forward leg has already pruned the secure confirmation. Rollback
        // restores the original journal first, then crashes before restoring base.
        // This conservative intermediate state must retain intent and remain restartable.
        let prunedBase = SyncBase(
            cursor: nil,
            journalEstablished: true)
        let originalJournal = SyncJournal(entries: [
            SyncBase.key(snippetID): SyncJournal.Entry(
                desired: desired,
                offered: SyncJournal.Offered(envelope: offered, generation: 1),
                generation: 2,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 50)),
        ])
        try SyncBaseFile.write(
            prunedBase, to: baseURL, temporaryDirectory: scratch.file("Tmp"))
        try SyncJournalFile.write(
            originalJournal, to: journalURL, temporaryDirectory: scratch.file("Tmp"))

        guard case .loaded(let restoredJournal) = SyncJournalFile.load(from: journalURL) else {
            Issue.record("the first rollback leg must leave a readable original journal")
            return
        }
        #expect(restoredJournal == originalJournal)
        #expect(restoredJournal.entry(snippetID)?.offered?.envelope == offered)
        #expect(restoredJournal.entry(snippetID)?.desired == desired)
        #expect(restoredJournal.pending(confirmed: prunedBase) == [offered])

        let library = Library()
        library.envelopes[snippetID] = desired
        let engine = SyncEngine(
            transport: InMemoryTransport(),
            library: library,
            sealer: PassthroughSealer(),
            device: Self.device,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: scratch.file("state.json"),
            lockURL: scratch.file("library.lock"),
            temporaryDirectory: scratch.file("Tmp"))
        #expect(!engine.state.isHalted,
                "marked pruned base plus restored journal is conservative, not lost state")
        #expect(engine.agreedBase.envelope(snippetID) == nil)

        // Keep the original confirmed fixture explicit: the absent envelope is the
        // unfinished second rollback leg, not an accidentally empty test setup.
        #expect(confirmed.secure)
    }

    @Test func existingCorruptJournalHaltsAtInitializationBeforeSubmitOrFetch() async throws {
        let h = try harness(
            label: "corrupt-init", journalData: Data("{not-json".utf8))
        defer { h.scratch.remove() }

        guard case .halted(let reason, let detail) = h.engine.state else {
            Issue.record("an existing corrupt journal must halt during initialization")
            return
        }
        #expect(reason == .localLibraryQuarantined)
        #expect(detail.contains("journal"))
        expectNoTransportCalls(h.transport)

        let state = await h.engine.sync()
        #expect(state.isHalted)
        expectNoTransportCalls(h.transport)
    }

    @Test func resumeCannotBypassCorruptionButExplicitRemovalAllowsSync() async throws {
        let h = try harness(
            label: "corrupt-resume", journalData: Data("{still-not-json".utf8))
        defer { h.scratch.remove() }

        h.engine.performRecovery(.checkAgain)
        guard case .halted(let reason, _) = h.engine.state else {
            Issue.record("Resume must not replace a corrupt journal with an empty one")
            return
        }
        #expect(reason == .localLibraryQuarantined)
        _ = await h.engine.sync()
        expectNoTransportCalls(h.transport)

        // Deliberate deletion is the recovery action under test. The file lives in this
        // test's private temporary directory and contains no user data.
        try FileManager.default.removeItem(at: h.journalURL)
        h.engine.performRecovery(.checkAgain)
        #expect(!h.engine.state.isHalted)

        _ = await h.engine.sync()
        #expect(h.transport.submittedBatches.isEmpty)
        #expect(h.transport.fetchAttempts == 1,
                "after explicit repair the ordinary empty-library fetch may start")
    }

    @Test func resumeCannotBypassOrOverwriteFutureJournal() async throws {
        let futureVersion = SyncJournal.currentSchemaVersion + 1
        let futureBytes = Data(
            "{\"schemaVersion\":\(futureVersion),\"entries\":{\"future\":true}}".utf8)
        let h = try harness(label: "future", journalData: futureBytes)
        defer { h.scratch.remove() }

        guard case .halted(let initialReason, _) = h.engine.state else {
            Issue.record("a future journal must halt during initialization")
            return
        }
        #expect(initialReason == .schemaTooNew)
        #expect(try Data(contentsOf: h.journalURL) == futureBytes)
        expectNoTransportCalls(h.transport)

        h.engine.performRecovery(.checkAgain)
        guard case .halted(let resumedReason, _) = h.engine.state else {
            Issue.record("Resume must not let an older build cross a future journal")
            return
        }
        #expect(resumedReason == .schemaTooNew)
        _ = await h.engine.sync()

        expectNoTransportCalls(h.transport)
        #expect(try Data(contentsOf: h.journalURL) == futureBytes,
                "initialization, Resume, and sync must all leave future bytes untouched")
    }

    @Test(arguments: [BaseDamage.missing, BaseDamage.corrupt])
    private func existingJournalWithUnavailableBaseHaltsBeforeTransport(
        damage: BaseDamage
    ) async throws {
        let label: String
        switch damage {
        case .missing: label = "missing-base"
        case .corrupt: label = "corrupt-base"
        }
        let scratch = try ScratchDirectory(label)
        defer { scratch.remove() }
        let baseURL = scratch.file("base.json")
        let journalURL = scratch.file("journal.json")
        let stateURL = scratch.file("state.json")
        let lockURL = scratch.file("library.lock")
        let temporaryDirectory = scratch.file("Tmp")
        let library = Library()
        let snippetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        library.envelopes[snippetID] = envelope(snippetID)
        let firstTransport = InMemoryTransport()
        let firstEngine = SyncEngine(
            transport: firstTransport,
            library: library,
            sealer: PassthroughSealer(),
            device: Self.device,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: lockURL,
            temporaryDirectory: temporaryDirectory)

        let firstState = await firstEngine.sync()
        #expect(!firstState.isHalted)
        #expect(FileManager.default.fileExists(atPath: baseURL.path))
        #expect(FileManager.default.fileExists(atPath: journalURL.path),
                "a completed ACK must leave its durable journal fence present")
        let journalBytes = try Data(contentsOf: journalURL)

        switch damage {
        case .missing:
            try FileManager.default.removeItem(at: baseURL)
        case .corrupt:
            // Valid JSON is not a valid empty base: required envelope state may not be
            // defaulted away at the durability fence.
            try Data("{\"schemaVersion\":1,\"envelopes\":null}".utf8).write(to: baseURL)
        }

        let restartTransport = InMemoryTransport()
        let restarted = SyncEngine(
            transport: restartTransport,
            library: library,
            sealer: PassthroughSealer(),
            device: Self.device,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: stateURL,
            lockURL: lockURL,
            temporaryDirectory: temporaryDirectory)

        #expect(restarted.state.isHalted,
                "an existing journal proves missing/corrupt base is not a fresh install")
        _ = await restarted.sync()
        expectNoTransportCalls(restartTransport)
        #expect(try Data(contentsOf: journalURL) == journalBytes,
                "fail-closed restart must preserve the remaining journal evidence")
    }

    // MARK: - Exact persistence

    @Test func subsecondModifiedAtRoundTripsBitExactly() throws {
        let scratch = try ScratchDirectory("subsecond")
        defer { scratch.remove() }
        let journalURL = scratch.file("journal.json")
        let snippetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let modifiedAt = Date(timeIntervalSinceReferenceDate: 123_456.789_123_456)
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: envelope(snippetID)],
            confirmed: SyncBase(),
            deviceID: Self.device,
            now: modifiedAt)
        let before = try #require(journal.entry(snippetID)?.modifiedAt)
        #expect(before == modifiedAt)

        try SyncJournalFile.write(
            journal, to: journalURL, temporaryDirectory: scratch.file("Tmp"))
        guard case .loaded(let reloaded) = SyncJournalFile.load(from: journalURL) else {
            Issue.record("expected the written journal to load")
            return
        }
        let after = try #require(reloaded.entry(snippetID)?.modifiedAt)

        #expect(after == before)
        #expect(
            after.timeIntervalSinceReferenceDate.bitPattern
                == before.timeIntervalSinceReferenceDate.bitPattern,
            "journal persistence must not truncate subsecond user-intent ordering")
        #expect(reloaded == journal)
    }
}
