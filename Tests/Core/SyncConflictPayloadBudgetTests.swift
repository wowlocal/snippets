import CryptoKit
import Foundation
import Testing

@testable import SnippetsCore

/// Conflict preservation creates payload that neither input carried on its own. These
/// tests keep the shipping AES-GCM/base64 boundary beside that reducer: CloudKit checks
/// the final sealed blob, so checking only the arriving records is insufficient.
@MainActor
@Suite("Sync conflict payload budget", .timeLimit(.minutes(1)))
struct SyncConflictPayloadBudgetTests {

    private static let cloudKitBlobLimit = 900_000
    private static let maximumCanonicalBytesAtShippingBoundary = 674_815
    private static let sourceID = UUID(
        uuidString: "30000000-0000-4000-8000-000000000006")!
    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"
    private static let vaultKID = "payload-budget-vault"

    private func sealer(scope: String = "payload-budget-wire") -> SnippetCryptoSealer {
        SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring(
                libraryKey: SymmetricKey(data: Data(repeating: 0x33, count: 32)),
                salt: Data(repeating: 0x55, count: SnippetCrypto.saltByteCount)),
            scopeID: scope,
            nonces: SnippetCrypto.NonceSource {
                Data(repeating: 0x77, count: SnippetCrypto.nonceByteCount)
            })
    }

    private func envelope(
        id: UUID? = nil,
        revision: UInt64,
        device: String,
        secure: Bool,
        content: Data,
        name: String = "x",
        x: [String: CanonicalJSON.Value] = [:]
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id ?? Self.sourceID,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: secure,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: name,
                keyword: "k",
                content: content,
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSinceReferenceDate: 1),
                updatedAt: Date(timeIntervalSinceReferenceDate: Double(revision))),
            x: x)
    }

    private func plainEnvelope(
        revision: UInt64,
        device: String,
        bodyBytes: Int,
        name: String = "x"
    ) -> SyncEnvelope {
        envelope(
            revision: revision,
            device: device,
            secure: false,
            content: Data(repeating: 0x61, count: bodyBytes),
            name: name)
    }

    private func opaqueSecureEnvelope(
        revision: UInt64,
        device: String,
        content: Data,
        hash: String
    ) -> SyncEnvelope {
        envelope(
            revision: revision,
            device: device,
            secure: true,
            content: content,
            x: [
                SyncEnvelope.vaultContentHashExtensionKey: .string(hash),
                SyncEnvelope.vaultKeyIDExtensionKey: .string(Self.vaultKID),
            ])
    }

    private func wireBytes(
        _ envelope: SyncEnvelope,
        using sealer: SnippetCryptoSealer
    ) throws -> Int {
        try WireCodec.seal(envelope, using: sealer).blob.count
    }

    @Test func shippingEncodingPinsTheLastCloudKitSafePaddingBlock() throws {
        let sealer = sealer(scope: "shipping-boundary")
        let identity = WireIdentity(
            id: Self.sourceID,
            rev: "boundary",
            deleted: false)
        let lastSafe = try sealer.seal(
            Data(repeating: 0x61, count: Self.maximumCanonicalBytesAtShippingBoundary),
            for: identity)
        let firstByteInNextPaddingBlock = try sealer.seal(
            Data(
                repeating: 0x61,
                count: Self.maximumCanonicalBytesAtShippingBoundary + 1),
            for: identity)

        #expect(lastSafe.count == 899_796)
        #expect(lastSafe.count <= Self.cloudKitBlobLimit)
        #expect(firstByteInNextPaddingBlock.count == 900_138)
        #expect(firstByteInNextPaddingBlock.count > Self.cloudKitBlobLimit)
    }

    @Test func fullCanonicalBudgetMatchesShippingBoundary() {
        #expect(
            SyncMerge.maximumWireCanonicalBytes
                == Self.maximumCanonicalBytesAtShippingBoundary,
            "Core must budget the complete candidate at the exact shipping-sealer boundary")
        #expect(
            SyncMerge.maximumContentConflictVariantBytes <= 512 * 1_024,
            "the independent abuse cap may remain 512 KiB now that full output is measured")
    }

    @Test func individuallyShippableInputsCannotMergeIntoOversizedSecureVariantSurvivor()
        async throws
    {
        let sealer = sealer(scope: "aggregate-conflict")
        let ancestor = opaqueSecureEnvelope(
            revision: 100,
            device: Self.deviceA,
            content: Data("ancestor seal".utf8),
            hash: "ancestor-hash")
        let local = opaqueSecureEnvelope(
            revision: 200,
            device: Self.deviceA,
            content: Data(repeating: 0x73, count: 350_000),
            hash: "local-large-secure-hash")
        let remote = plainEnvelope(
            revision: 300,
            device: Self.deviceB,
            bodyBytes: 350_000)

        #expect(try wireBytes(local, using: sealer) <= Self.cloudKitBlobLimit)
        #expect(try wireBytes(remote, using: sealer) <= Self.cloudKitBlobLimit)
        do {
            let direct = try SyncMerge.mergeEnvelopeOutcome(
                base: ancestor, local: local, remote: remote)
            let survivor = try #require(direct.survivor)
            #expect(try wireBytes(survivor, using: sealer) > Self.cloudKitBlobLimit,
                    "the fixture must exercise aggregate survivor+variant growth")
        } catch {
            // A reducer that already rejects this unshippable output is the desired
            // behavior; the engine assertions below pin its durability consequences.
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-conflict-payload-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseURL = directory.appendingPathComponent("base.json")
        let journalURL = directory.appendingPathComponent("journal.json")
        let oldCursor = SyncCursor("before-oversized-conflict")
        var base = SyncBase(cursor: oldCursor, journalEstablished: true)
        base.recordConfirmed(
            ancestor,
            recordVersion: SyncRecordVersion(Data("ancestor-generation".utf8)))
        try SyncBaseFile.write(base, to: baseURL, temporaryDirectory: directory)
        try SyncJournalFile.write(
            SyncJournal(), to: journalURL, temporaryDirectory: directory)

        var remoteRecord = try WireCodec.seal(remote, using: sealer)
        remoteRecord.recordVersion = SyncRecordVersion(Data("remote-generation".utf8))
        let transport = ConflictTransport(
            remote: remoteRecord,
            deliveredCursor: SyncCursor("after-oversized-conflict"))
        let library = Library(local)
        let engine = SyncEngine(
            transport: transport,
            library: library,
            sealer: sealer,
            device: Self.deviceA,
            baseURL: baseURL,
            journalURL: journalURL,
            stateURL: directory.appendingPathComponent("state.json"),
            lockURL: directory.appendingPathComponent("library.lock"),
            temporaryDirectory: directory)

        let state = await engine.sync()

        if case .halted(let reason, _) = state {
            #expect(reason == .localLibraryQuarantined)
        } else {
            Issue.record("an unshippable merged payload must halt, got \(state)")
        }
        #expect(library.appliedBatches.isEmpty,
                "the oversized survivor must fail before the primary library write")
        #expect(library.envelopes == [Self.sourceID: local])
        #expect(transport.acknowledgedCursors.isEmpty,
                "the fetched cursor remains retryable until the payload is representable")
        guard case .loaded(let retainedBase) = SyncBaseFile.load(from: baseURL) else {
            Issue.record("the original durable base must remain readable")
            return
        }
        #expect(retainedBase.cursor == oldCursor)
        #expect(retainedBase.envelope(Self.sourceID) == ancestor)
    }

    @Test func generatedPlainConflictCopyMustFitEvenWhenItsSourceInputFits() throws {
        let sealer = sealer(scope: "plain-copy-boundary")
        let source = try largestFittingPlainEnvelope(using: sealer)
        #expect(try wireBytes(source, using: sealer) <= Self.cloudKitBlobLimit)
        #expect(
            try wireBytes(
                plainEnvelope(
                    revision: source.hlc.wallMs,
                    device: source.origin,
                    bodyBytes: try #require(source.fields).content.count + 1),
                using: sealer) > Self.cloudKitBlobLimit,
            "the fixture source is the largest body that fits the shipping record")

        let ancestor = plainEnvelope(
            revision: 100, device: Self.deviceA, bodyBytes: 8, name: "ancestor")
        let secureWinner = opaqueSecureEnvelope(
            revision: 300,
            device: Self.deviceB,
            content: Data("small secure winner".utf8),
            hash: "secure-winner-hash")

        let outcome: SyncMerge.EnvelopeOutcome
        do {
            outcome = try SyncMerge.mergeEnvelopeOutcome(
                base: ancestor, local: source, remote: secureWinner)
        } catch {
            return
        }
        let copy = try #require(outcome.conflictCopies.first)
        #expect(outcome.conflictCopies.count == 1)
        #expect(try wireBytes(copy, using: sealer) <= Self.cloudKitBlobLimit,
                "generated copy metadata must be included in the pre-commit wire budget")
    }

    @Test func materializedSecureCopyRemainsInsideShippingBudget() throws {
        let wireSealer = sealer(scope: "materialized-copy-boundary")
        let vaultKeyring = SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data(repeating: 0x91, count: 32)),
            salt: Data(repeating: 0xA2, count: SnippetCrypto.saltByteCount))
        let losingPlaintext = Data(repeating: 0x6C, count: 380_000)
        let losingSeal = try SnippetCrypto.seal(
            losingPlaintext,
            for: SnippetCrypto.RecordContext(
                scopeID: Self.vaultKID, recordID: Self.sourceID),
            keyring: vaultKeyring,
            nonces: SnippetCrypto.NonceSource {
                Data(repeating: 0xB3, count: SnippetCrypto.nonceByteCount)
            })
        let ancestor = opaqueSecureEnvelope(
            revision: 100,
            device: Self.deviceA,
            content: Data("ancestor seal".utf8),
            hash: "ancestor-hash")
        let secureLoser = opaqueSecureEnvelope(
            revision: 200,
            device: Self.deviceA,
            content: Data(losingSeal.utf8),
            hash: SnippetCrypto.contentHash(of: losingPlaintext, keyring: vaultKeyring))
        let plainWinner = plainEnvelope(
            revision: 300, device: Self.deviceB, bodyBytes: 16)
        #expect(try wireBytes(secureLoser, using: wireSealer) <= Self.cloudKitBlobLimit)

        let outcome = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor, local: secureLoser, remote: plainWinner)
        let survivor = try #require(outcome.survivor)
        let variant = try #require(
            SyncMerge.secureContentConflictVariants(in: survivor).first)
        let projectedSourceRecord = try SyncLibraryProjection.vaultRecord(
            from: secureLoser)
        let sourceRecord = try #require(projectedSourceRecord)
        let materialized = try SyncSecureConflictMaterializer.materialize(
            envelope: survivor,
            keyring: vaultKeyring,
            vaultKID: Self.vaultKID,
            existingSnippets: [],
            existingRecords: [sourceRecord])
        let copyRecord = try #require(
            materialized.records.first { $0.id == variant.copyID })
        let copyEnvelope = try #require(
            SyncLibraryProjection.currentEnvelopes(
                snippets: [],
                records: [copyRecord],
                deviceID: Self.deviceB,
                metadata: SyncBase(),
                agreedBase: SyncBase(),
                vaultKID: Self.vaultKID)[variant.copyID])

        #expect(SyncMerge.maximumContentConflictVariantBytes <= 512 * 1_024,
                "the secure variant cap is also the materialized-copy safety budget")
        #expect(try wireBytes(copyEnvelope, using: wireSealer) <= Self.cloudKitBlobLimit,
                "the resealed body and provenance must be budgeted as a shipping record")
    }

    private func largestFittingPlainEnvelope(
        using sealer: SnippetCryptoSealer
    ) throws -> SyncEnvelope {
        var fitting = 0
        var oversized = 700_000
        while fitting + 1 < oversized {
            let candidate = fitting + (oversized - fitting) / 2
            let envelope = plainEnvelope(
                revision: 200,
                device: Self.deviceA,
                bodyBytes: candidate)
            if try wireBytes(envelope, using: sealer) <= Self.cloudKitBlobLimit {
                fitting = candidate
            } else {
                oversized = candidate
            }
        }
        return plainEnvelope(
            revision: 200,
            device: Self.deviceA,
            bodyBytes: fitting)
    }

    private final class Library: SyncLibraryAccess {
        private(set) var envelopes: [UUID: SyncEnvelope]
        private(set) var appliedBatches: [[SyncEnvelope]] = []

        init(_ envelope: SyncEnvelope) {
            envelopes = [envelope.id: envelope]
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
            for envelope in incoming { envelopes[envelope.id] = envelope }
            return ApplyOutcome(changedIDs: incoming.map(\.id))
        }

        func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
    }

    private final class ConflictTransport: SyncTransport, @unchecked Sendable {
        let identifier = "conflict-payload-budget-test"
        let supportsPush = true
        let pollInterval: TimeInterval = 30
        let events: AsyncStream<SyncTransportEvent> = AsyncStream { $0.finish() }

        private let remote: WireRecord
        private let deliveredCursor: SyncCursor
        private let lock = NSLock()
        private var acknowledgements: [SyncCursor?] = []

        init(remote: WireRecord, deliveredCursor: SyncCursor) {
            self.remote = remote
            self.deliveredCursor = deliveredCursor
        }

        var acknowledgedCursors: [SyncCursor?] {
            lock.withLock { acknowledgements }
        }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            SyncFetch(records: [], cursor: deliveredCursor)
        }

        func submit(
            _ records: [WireRecord], at cursor: SyncCursor?
        ) async throws -> SyncSubmission {
            SyncSubmission(
                results: records.map {
                    SyncSubmitResult(
                        id: $0.id,
                        outcome: .rejected(.conflict(remote: remote)))
                },
                cursor: cursor)
        }

        func acknowledgeFetched(through cursor: SyncCursor?) async throws {
            lock.withLock { acknowledgements.append(cursor) }
        }
    }
}
