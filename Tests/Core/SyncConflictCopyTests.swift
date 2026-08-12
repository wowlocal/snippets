import CryptoKit
import Foundation
import Testing

@testable import SnippetsCore

/// Cross-device regression coverage for content conflict copies.
///
/// `SyncMergeTests` already pins conflict copies for the local file-vs-file merge. This
/// suite exercises the separate envelope/engine path, including the CAS rejection that
/// turns two edits made from one ancestor into a real three-way merge. It intentionally
/// remains red until that path preserves a plain loser as a syncable copy and a secure
/// loser as an opaque, later-materializable encrypted variant.
@MainActor
@Suite("Sync conflict copies", .timeLimit(.minutes(1)))
struct SyncConflictCopyTests {

    // MARK: - Fixtures

    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"
    private static let snippetID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000012")!
    private static let vaultKID = "11111111-2222-4333-8444-555555555555"
    /// One dynamic extension key per immutable source snapshot. Separate keys are
    /// load-bearing: an older client shallow-merges `x`, so a single nested map would
    /// make two independently learned variants overwrite one another wholesale.
    private static let conflictVariantPrefix = "contentConflict.v1."

    private enum FirstWriter {
        case a
        case b
    }

    /// A value-level stand-in for the ordinary library plus vault. It deliberately keeps
    /// opaque secure bodies as `Data`: these tests must never turn a vault ciphertext into
    /// plaintext merely to prove that the sync layer retained it.
    private final class Library: SyncLibraryAccess {
        var envelopes: [UUID: SyncEnvelope] = [:]
        private(set) var appliedBatches: [[SyncEnvelope]] = []

        func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
            envelopes
        }

        func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
            RemoteClassification(
                applicable: envelopes, deferredIDs: [], incompatibleVaultIDs: [])
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

    private struct Snapshot {
        var onA: [UUID: SyncEnvelope]
        var onB: [UUID: SyncEnvelope]
        var backend: [UUID: SyncEnvelope]
        var submittedBatchCount: Int
    }

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-conflict-copy-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func engine(
        backend: InMemoryTransport,
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
            stateURL: directory.appendingPathComponent("state.json"),
            lockURL: directory.appendingPathComponent("library.lock"),
            temporaryDirectory: directory)
    }

    private func harness(_ label: String) throws -> Harness {
        let directoryA = try directory("\(label)-a")
        let directoryB = try directory("\(label)-b")
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "conflict-copy-test")
        let libraryA = Library()
        let libraryB = Library()
        return Harness(
            backend: backend,
            sealer: sealer,
            libraryA: libraryA,
            libraryB: libraryB,
            engineA: engine(
                backend: backend, library: libraryA, sealer: sealer,
                device: Self.deviceA, directory: directoryA),
            engineB: engine(
                backend: backend, library: libraryB, sealer: sealer,
                device: Self.deviceB, directory: directoryB),
            directoryA: directoryA,
            directoryB: directoryB)
    }

    private func cleanUp(_ harness: Harness) {
        try? FileManager.default.removeItem(at: harness.directoryA)
        try? FileManager.default.removeItem(at: harness.directoryB)
    }

    private func envelope(
        device: String,
        revision: UInt64,
        content: Data,
        name: String = "Shared snippet",
        keyword: String = "shared",
        tags: [String] = ["original"],
        isEnabled: Bool = true,
        isPinned: Bool = false,
        secure: Bool = false,
        clockDevice: String? = nil,
        x: [String: CanonicalJSON.Value] = [:]
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: Self.snippetID,
            hlc: HLC(wallMs: revision, counter: 0, device: clockDevice ?? device),
            origin: device,
            secure: secure,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: name,
                keyword: keyword,
                content: content,
                tags: tags,
                isEnabled: isEnabled,
                isPinned: isPinned,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)),
            x: x)
    }

    private func plainEnvelope(
        device: String,
        revision: UInt64,
        content: String,
        name: String = "Shared snippet",
        keyword: String = "shared",
        tags: [String] = ["original"],
        isPinned: Bool = false,
        clockDevice: String? = nil
    ) -> SyncEnvelope {
        envelope(
            device: device,
            revision: revision,
            content: Data(content.utf8),
            name: name,
            keyword: keyword,
            tags: tags,
            isPinned: isPinned,
            clockDevice: clockDevice)
    }

    private func secureEnvelope(
        device: String,
        revision: UInt64,
        sealed: String,
        contentHash: String
    ) -> SyncEnvelope {
        envelope(
            device: device,
            revision: revision,
            content: Data(sealed.utf8),
            name: "Secure shared snippet",
            keyword: "secure-shared",
            tags: ["vault"],
            secure: true,
            x: [
                SyncEnvelope.vaultContentHashExtensionKey: .string(contentHash),
                SyncEnvelope.vaultKeyIDExtensionKey: .string(Self.vaultKID),
            ])
    }

    private func establishSharedAncestor(_ ancestor: SyncEnvelope, in harness: Harness) async {
        harness.libraryA.envelopes[ancestor.id] = ancestor
        _ = await harness.engineA.sync()
        _ = await harness.engineB.sync()

        #expect(harness.libraryA.envelopes[ancestor.id] == ancestor)
        #expect(harness.libraryB.envelopes[ancestor.id] == ancestor)
        #expect(harness.engineA.agreedBase.cursor == harness.engineB.agreedBase.cursor,
                "both edits must start from the same backend position")
    }

    /// Both edits are installed before either engine runs. Serializing the two submits is
    /// deterministic test orchestration, not a weaker history: the second submit still
    /// carries the common ancestor's CAS generation and is rejected as stale.
    private func race(
        _ editA: SyncEnvelope?,
        against editB: SyncEnvelope?,
        firstWriter: FirstWriter,
        in harness: Harness
    ) async {
        harness.libraryA.envelopes[Self.snippetID] = editA
        harness.libraryB.envelopes[Self.snippetID] = editB

        switch firstWriter {
        case .a:
            _ = await harness.engineA.sync()
            _ = await harness.engineB.sync()
        case .b:
            _ = await harness.engineB.sync()
            _ = await harness.engineA.sync()
        }
    }

    private func settle(_ harness: Harness, rounds: Int = 5) async {
        for round in 0..<rounds {
            if round.isMultiple(of: 2) {
                _ = await harness.engineA.sync()
                _ = await harness.engineB.sync()
            } else {
                _ = await harness.engineB.sync()
                _ = await harness.engineA.sync()
            }
        }
    }

    private func openedBackend(_ harness: Harness) throws -> [UUID: SyncEnvelope] {
        var opened: [UUID: SyncEnvelope] = [:]
        for record in harness.backend.snapshot {
            opened[record.id] = try WireCodec.open(record, using: harness.sealer)
        }
        return opened
    }

    private func snapshot(_ harness: Harness) throws -> Snapshot {
        Snapshot(
            onA: harness.libraryA.envelopes,
            onB: harness.libraryB.envelopes,
            backend: try openedBackend(harness),
            submittedBatchCount: harness.backend.submittedBatches.count)
    }

    private func content(_ envelope: SyncEnvelope?) -> Data? {
        envelope?.fields?.content
    }

    private func contentHash(_ plaintext: Data, keyring: SnippetCrypto.Keyring) -> String {
        SnippetCrypto.contentHash(of: plaintext, key: keyring.contentHashKey)
    }

    private func text(_ envelope: SyncEnvelope?) -> String? {
        content(envelope).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func copies(in envelopes: [UUID: SyncEnvelope]) -> [SyncEnvelope] {
        envelopes.values.filter { !$0.deleted && $0.id != Self.snippetID }
    }

    private struct SecureVariant {
        var variantKey: String
        var fingerprint: String
        var version: Int64
        var copyID: UUID
        var sourceID: UUID
        var secure: Bool
        var content: Data
        var contentHash: String
        var vaultKID: String
        var sourceHLC: String
        var sourceOrigin: String
        var name: String
        var keyword: String
        var tags: [String]
        var isEnabled: Bool
        var isPinned: Bool
        var createdAt: Double
        var updatedAt: Double
        var sourceExtensions: [String: CanonicalJSON.Value]
    }

    private func digest(_ value: CanonicalJSON.Value) throws -> String {
        SHA256.hash(data: try CanonicalJSON.data(value))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func isReservedConflictExtension(_ key: String) -> Bool {
        key.hasPrefix("contentConflict.")
    }

    /// Constructs the exact immutable snapshot contract expected from production. The
    /// fingerprint hashes every source fact needed for later materialization except the
    /// derived `copyID`; `version` and the name passed to UUIDv5 domain-separate future
    /// shapes. Reserved conflict keys are excluded so a second conflict cannot recursively
    /// embed the first payload and grow exponentially.
    private func secureVariantValue(
        for source: SyncEnvelope
    ) throws -> (key: String, value: CanonicalJSON.Value, copyID: UUID) {
        let fields = try #require(source.fields)
        let sourceX = source.x.filter { !isReservedConflictExtension($0.key) }
        var snapshot: [String: CanonicalJSON.Value] = [
            "version": .int(1),
            "sourceID": .string(source.id.uuidString.lowercased()),
            "sourceHLC": .string(source.hlc.string),
            "sourceOrigin": .string(source.origin),
            "secure": .bool(source.secure),
            "fields": fields.canonicalValue,
            "x": .object(sourceX),
        ]
        let fingerprint = try digest(.object(snapshot))
        let copyID = SyncMerge.deterministicUUID(
            namespace: source.id,
            name: "sync-content-conflict-v1|\(fingerprint)")
        snapshot["copyID"] = .string(copyID.uuidString.lowercased())
        return (
            key: Self.conflictVariantPrefix + fingerprint,
            value: .object(snapshot),
            copyID: copyID)
    }

    /// Strict test-side decoder for the internal opaque wire contract. This does not add
    /// a production API or grow the frozen top-level wire key set: every independently
    /// mergeable variant is one member of the existing encrypted `x` bag.
    private func secureVariants(in envelope: SyncEnvelope) -> [SecureVariant] {
        envelope.x.compactMap { variantKey, raw in
            guard variantKey.hasPrefix(Self.conflictVariantPrefix) else { return nil }
            let fingerprint = String(variantKey.dropFirst(Self.conflictVariantPrefix.count))
            guard fingerprint.count == 64,
                  fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  let object = raw.object,
                  Set(object.keys) == [
                    "version", "copyID", "sourceID", "sourceHLC", "sourceOrigin",
                    "secure", "fields", "x",
                  ],
                  let version = object["version"]?.int,
                  version == 1,
                  let copyText = object["copyID"]?.text,
                  let copyID = UUID(uuidString: copyText),
                  copyText == copyID.uuidString.lowercased(),
                  let sourceText = object["sourceID"]?.text,
                  let sourceID = UUID(uuidString: sourceText),
                  sourceText == sourceID.uuidString.lowercased(),
                  let secure = object["secure"]?.bool,
                  secure,
                  let sourceHLC = object["sourceHLC"]?.text,
                  HLC(parsing: sourceHLC) != nil,
                  let sourceOrigin = object["sourceOrigin"]?.text,
                  HLC.isCanonicalDeviceID(sourceOrigin),
                  let fields = object["fields"]?.object,
                  Set(fields.keys) == SyncEnvelope.Fields.keys,
                  let name = fields["name"]?.text,
                  let keyword = fields["keyword"]?.text,
                  let content = fields["content"]?.data,
                  let tagValues = fields["tags"]?.array,
                  tagValues.allSatisfy({ $0.text != nil }),
                  let isEnabled = fields["isEnabled"]?.bool,
                  let isPinned = fields["isPinned"]?.bool,
                  let createdAt = fields["createdAt"]?.double,
                  let updatedAt = fields["updatedAt"]?.double,
                  let sourceExtensions = object["x"]?.object,
                  sourceExtensions.keys.allSatisfy({ !isReservedConflictExtension($0) }),
                  let contentHash = sourceExtensions[
                    SyncEnvelope.vaultContentHashExtensionKey]?.text,
                  let vaultKID = sourceExtensions[
                    SyncEnvelope.vaultKeyIDExtensionKey]?.text
            else { return nil }
            let tags = tagValues.compactMap(\.text)

            var snapshot = object
            snapshot["copyID"] = nil
            guard (try? digest(.object(snapshot))) == fingerprint,
                  copyID == SyncMerge.deterministicUUID(
                    namespace: sourceID,
                    name: "sync-content-conflict-v1|\(fingerprint)")
            else { return nil }

            return SecureVariant(
                variantKey: variantKey,
                fingerprint: fingerprint,
                version: version,
                copyID: copyID,
                sourceID: sourceID,
                secure: secure,
                content: content,
                contentHash: contentHash,
                vaultKID: vaultKID,
                sourceHLC: sourceHLC,
                sourceOrigin: sourceOrigin,
                name: name,
                keyword: keyword,
                tags: tags,
                isEnabled: isEnabled,
                isPinned: isPinned,
                createdAt: createdAt,
                updatedAt: updatedAt,
                sourceExtensions: sourceExtensions)
        }.sorted { $0.variantKey < $1.variantKey }
    }

    private func runPlainConflict(firstWriter: FirstWriter, label: String) async throws -> Snapshot {
        let harness = try harness(label)
        defer { cleanUp(harness) }

        let ancestor = plainEnvelope(
            device: Self.deviceA, revision: 100, content: "ancestor body")
        await establishSharedAncestor(ancestor, in: harness)
        await race(
            plainEnvelope(device: Self.deviceA, revision: 200, content: "body written on A"),
            against: plainEnvelope(
                device: Self.deviceB, revision: 300, content: "body written on B"),
            firstWriter: firstWriter,
            in: harness)
        await settle(harness)
        return try snapshot(harness)
    }

    private func runEqualHLCPlainConflict(
        firstWriter: FirstWriter, label: String
    ) async throws -> Snapshot {
        let harness = try harness(label)
        defer { cleanUp(harness) }

        let ancestor = plainEnvelope(
            device: Self.deviceA, revision: 100, content: "ancestor body")
        await establishSharedAncestor(ancestor, in: harness)
        // Origins remain distinct, but both edits deliberately carry the exact same HLC.
        // This forces the payload-level deterministic tiebreak rather than the clock.
        await race(
            plainEnvelope(
                device: Self.deviceA, revision: 200, content: "body written on A",
                clockDevice: "cccccccc"),
            against: plainEnvelope(
                device: Self.deviceB, revision: 200, content: "body written on B",
                clockDevice: "cccccccc"),
            firstWriter: firstWriter,
            in: harness)
        await settle(harness)
        return try snapshot(harness)
    }

    // MARK: - Plain content conflicts

    @Test func concurrentPlainTextEditsImmediatelyPreserveBothBodies() async throws {
        let harness = try harness("plain-immediate")
        defer { cleanUp(harness) }

        let ancestor = plainEnvelope(
            device: Self.deviceA, revision: 100, content: "ancestor body")
        await establishSharedAncestor(ancestor, in: harness)
        await race(
            plainEnvelope(device: Self.deviceA, revision: 200, content: "body written on A"),
            against: plainEnvelope(
                device: Self.deviceB, revision: 300, content: "body written on B"),
            firstWriter: .a,
            in: harness)

        let bodies = Set(harness.libraryB.envelopes.values.compactMap(text))
        #expect(bodies == ["body written on A", "body written on B"],
                "the stale writer must preserve the losing body before finishing its merge round")
        #expect(text(harness.libraryB.envelopes[Self.snippetID]) == "body written on B",
                "the higher HLC remains at the original record id")

        let copy = try #require(copies(in: harness.libraryB.envelopes).only)
        #expect(!copy.secure)
        #expect(copy.fields?.isEnabled == false, "a conflict copy must never expand")
        #expect(copy.fields?.keyword == "", "the copy must not contend for the live keyword")
        #expect(copy.fields?.isPinned == false)
        #expect(copy.fields?.tags.contains(where: {
            SnippetTagging.filterKey(for: $0) == "conflict"
        }) == true, "the preserved version must be discoverable")
    }

    @Test func oppositeMergeOrdersDeriveTheSameConflictCopyID() async throws {
        let aFirst = try await runPlainConflict(firstWriter: .a, label: "order-a-first")
        let bFirst = try await runPlainConflict(firstWriter: .b, label: "order-b-first")

        let copyA = try #require(copies(in: aFirst.onA).only)
        let copyB = try #require(copies(in: bFirst.onA).only)
        #expect(aFirst.onA == bFirst.onA,
                "the whole converged library must be independent of submit order")
        #expect(copyA.id == copyB.id,
                "copy identity must depend on the source conflict, never arrival order")
        #expect(copyA.id != Self.snippetID)
        #expect(content(copyA) == Data("body written on A".utf8))
        #expect(content(copyB) == Data("body written on A".utf8))
    }

    @Test func equalHLCConflictConvergesIdenticallyInOppositeSubmitOrders() async throws {
        let aFirst = try await runEqualHLCPlainConflict(
            firstWriter: .a, label: "equal-hlc-a-first")
        let bFirst = try await runEqualHLCPlainConflict(
            firstWriter: .b, label: "equal-hlc-b-first")

        #expect(aFirst.onA == aFirst.onB)
        #expect(bFirst.onA == bFirst.onB)
        #expect(aFirst.onA == aFirst.backend)
        #expect(bFirst.onA == bFirst.backend)
        #expect(aFirst.onA == bFirst.onA,
                "exact clock ties must use a symmetric payload tiebreak, not arrival order")
        #expect(copies(in: aFirst.onA).count == 1)
        #expect(Set(aFirst.onA.values.compactMap(text)) == [
            "body written on A", "body written on B",
        ])
    }

    @Test func twoEnginesAndBackendConvergeOnExactlyOneConflictCopy() async throws {
        let result = try await runPlainConflict(firstWriter: .a, label: "convergence")

        #expect(result.onA == result.onB,
                "both devices must converge on the survivor and its conflict copy")
        #expect(result.onA == result.backend,
                "the conflict copy must be syncable, not merely a local side effect")
        #expect(result.onA.count == 2)
        #expect(copies(in: result.onA).count == 1)
        #expect(Set(result.onA.values.compactMap(text)) == [
            "body written on A", "body written on B",
        ])
    }

    @Test func repeatedAndRedeliveredMergesAreAFixedPoint() async throws {
        let harness = try harness("idempotence")
        defer { cleanUp(harness) }

        let ancestor = plainEnvelope(
            device: Self.deviceA, revision: 100, content: "ancestor body")
        await establishSharedAncestor(ancestor, in: harness)
        await race(
            plainEnvelope(device: Self.deviceA, revision: 200, content: "body written on A"),
            against: plainEnvelope(
                device: Self.deviceB, revision: 300, content: "body written on B"),
            firstWriter: .a,
            in: harness)
        await settle(harness)

        let before = try snapshot(harness)
        #expect(before.onA == before.onB)
        #expect(copies(in: before.onA).count == 1)

        // Re-fetch the entire backend twice and redeliver every page three times. This
        // exercises the merge again; merely running an empty-cursor round would only test
        // the scheduler, not conflict-copy idempotence.
        harness.backend.configure {
            $0.invalidateCursorOnNextFetch = true
            $0.deliverPagesTimes = 3
        }
        _ = await harness.engineA.sync()
        harness.backend.configure { $0.invalidateCursorOnNextFetch = true }
        _ = await harness.engineB.sync()
        harness.backend.configure { $0.deliverPagesTimes = 1 }
        await settle(harness, rounds: 3)

        let after = try snapshot(harness)
        #expect(after.onA == before.onA)
        #expect(after.onB == before.onB)
        #expect(after.backend == before.backend)
        #expect(after.submittedBatchCount == before.submittedBatchCount,
                "replaying an already merged conflict must not cause another upload")
        #expect(copies(in: after.onA).count == 1,
                "redelivery must not breed duplicate conflict copies")
    }

    // MARK: - Non-conflicting and deletion histories

    @Test func independentFieldOnlyChangesStillMergeWithoutACopy() async throws {
        let harness = try harness("field-only")
        defer { cleanUp(harness) }

        let ancestor = plainEnvelope(
            device: Self.deviceA,
            revision: 100,
            content: "unchanged body",
            name: "Original name",
            tags: ["original"])
        await establishSharedAncestor(ancestor, in: harness)

        let renamedOnA = plainEnvelope(
            device: Self.deviceA,
            revision: 200,
            content: "unchanged body",
            name: "Renamed on A",
            tags: ["original"])
        let classifiedOnB = plainEnvelope(
            device: Self.deviceB,
            revision: 300,
            content: "unchanged body",
            name: "Original name",
            tags: ["original", "mobile"],
            isPinned: true)
        await race(renamedOnA, against: classifiedOnB, firstWriter: .a, in: harness)
        await settle(harness)

        let result = try snapshot(harness)
        #expect(result.onA == result.onB)
        #expect(result.onA == result.backend)
        #expect(Set(result.onA.keys) == [Self.snippetID],
                "independent fields are an ordinary merge, not a content conflict")
        let merged = try #require(result.onA[Self.snippetID]?.fields)
        #expect(merged.name == "Renamed on A")
        #expect(merged.tags == ["original", "mobile"])
        #expect(merged.isPinned)
        #expect(merged.content == Data("unchanged body".utf8))
    }

    @Test func concurrentDeleteAndUpdateKeepTheUpdateInEitherSubmitOrder() async throws {
        func run(deleteFirst: Bool, label: String) async throws -> Snapshot {
            let harness = try harness(label)
            defer { cleanUp(harness) }

            let ancestor = plainEnvelope(
                device: Self.deviceA, revision: 100, content: "ancestor body")
            await establishSharedAncestor(ancestor, in: harness)
            let update = plainEnvelope(
                device: Self.deviceB, revision: 300, content: "body rescued from deletion")
            await race(
                nil,
                against: update,
                firstWriter: deleteFirst ? .a : .b,
                in: harness)
            await settle(harness)
            return try snapshot(harness)
        }

        let deleteFirst = try await run(deleteFirst: true, label: "delete-first")
        let updateFirst = try await run(deleteFirst: false, label: "update-first")

        for result in [deleteFirst, updateFirst] {
            #expect(result.onA == result.onB)
            #expect(result.onA == result.backend)
            #expect(Set(result.onA.keys) == [Self.snippetID])
            #expect(text(result.onA[Self.snippetID]) == "body rescued from deletion",
                    "an edit is irrecoverable while a delete can be repeated, so the edit wins")
            #expect(copies(in: result.onA).isEmpty,
                    "delete-vs-update has only one user body and does not need a copy")
        }
    }

    @Test func anUncontestedDeleteStillDeletesInsteadOfCreatingACopy() async throws {
        let harness = try harness("uncontested-delete")
        defer { cleanUp(harness) }

        let ancestor = plainEnvelope(
            device: Self.deviceA, revision: 100, content: "ancestor body")
        await establishSharedAncestor(ancestor, in: harness)
        harness.libraryA.envelopes[Self.snippetID] = nil
        _ = await harness.engineA.sync()
        _ = await harness.engineB.sync()
        await settle(harness, rounds: 2)

        #expect(harness.libraryA.envelopes.isEmpty)
        #expect(harness.libraryB.envelopes.isEmpty)
        let backend = try openedBackend(harness)
        #expect(backend.count == 1)
        #expect(backend[Self.snippetID]?.deleted == true)
    }

    // MARK: - Secure content conflicts

    @Test func unawareShallowMergeAndWireRoundTripUnionIndependentSecureVariants() throws {
        let vaultKeyring = SnippetCrypto.Keyring.generate()
        let sourceContext = SnippetCrypto.RecordContext(
            scopeID: Self.vaultKID, recordID: Self.snippetID)
        let plaintextA = Data("opaque variant A".utf8)
        let plaintextB = Data("opaque variant B".utf8)
        let sourceA = secureEnvelope(
            device: Self.deviceA,
            revision: 200,
            sealed: try SnippetCrypto.seal(
                plaintextA, for: sourceContext, keyring: vaultKeyring),
            contentHash: contentHash(plaintextA, keyring: vaultKeyring))
        let sourceB = secureEnvelope(
            device: Self.deviceB,
            revision: 300,
            sealed: try SnippetCrypto.seal(
                plaintextB, for: sourceContext, keyring: vaultKeyring),
            contentHash: contentHash(plaintextB, keyring: vaultKeyring))
        let variantA = try secureVariantValue(for: sourceA)
        let variantB = try secureVariantValue(for: sourceB)
        #expect(variantA.key != variantB.key)
        #expect(variantA.copyID != variantB.copyID)

        let survivorPlaintext = Data("current secure winner".utf8)
        let survivor = secureEnvelope(
            device: Self.deviceA,
            revision: 400,
            sealed: try SnippetCrypto.seal(
                survivorPlaintext, for: sourceContext, keyring: vaultKeyring),
            contentHash: contentHash(survivorPlaintext, keyring: vaultKeyring))

        func carrying(
            _ variant: (key: String, value: CanonicalJSON.Value, copyID: UUID)
        ) -> SyncEnvelope {
            var extensions = survivor.x
            extensions[variant.key] = variant.value
            return SyncEnvelope(
                schemaVersion: survivor.schemaVersion,
                id: survivor.id,
                hlc: survivor.hlc,
                origin: survivor.origin,
                secure: survivor.secure,
                deleted: false,
                fields: survivor.fields,
                x: extensions)
        }

        // This is deliberately the pre-feature behavior: `mergeEnvelope` knows only
        // that `x` is an opaque dictionary and performs a shallow union. Separate dynamic
        // keys make that unaware behavior safe; a nested variants map would lose one side.
        let viewA = carrying(variantA)
        let viewB = carrying(variantB)
        let mergedAB = try #require(SyncMerge.mergeEnvelope(
            base: survivor, local: viewA, remote: viewB))
        let mergedBA = try #require(SyncMerge.mergeEnvelope(
            base: survivor, local: viewB, remote: viewA))

        #expect(mergedAB == mergedBA,
                "mirrored old clients must compute the same shallow union")
        #expect(mergedAB.x[variantA.key] == variantA.value)
        #expect(mergedAB.x[variantB.key] == variantB.value)
        #expect(secureVariants(in: mergedAB).map(\.variantKey)
                == [variantA.key, variantB.key].sorted())

        // An unaware reader parses and re-emits the entire x bag without understanding
        // either dynamic key. Exact round-trip preservation includes `.utf8` ciphertext.
        let roundTripped = try SyncEnvelope.parse(mergedAB.canonicalData())
        #expect(roundTripped == mergedAB)
        #expect(roundTripped.x[variantA.key] == variantA.value)
        #expect(roundTripped.x[variantB.key] == variantB.value)
        #expect(secureVariants(in: roundTripped).count == 2)
    }

    @Test func laterSecureConflictUnionsANewVariantWithoutRecursiveEmbedding() throws {
        let vaultKeyring = SnippetCrypto.Keyring.generate()
        let sourceContext = SnippetCrypto.RecordContext(
            scopeID: Self.vaultKID, recordID: Self.snippetID)

        func version(_ text: String, device: String, revision: UInt64) throws -> SyncEnvelope {
            let plaintext = Data(text.utf8)
            return secureEnvelope(
                device: device,
                revision: revision,
                sealed: try SnippetCrypto.seal(
                    plaintext, for: sourceContext, keyring: vaultKeyring),
                contentHash: contentHash(plaintext, keyring: vaultKeyring))
        }

        let historicalSource = try version(
            "historical losing secret", device: Self.deviceA, revision: 150)
        let historical = try secureVariantValue(for: historicalSource)

        var ancestor = try version(
            "second ancestor", device: Self.deviceA, revision: 300)
        ancestor.x[historical.key] = historical.value
        var onA = try version("second edit A", device: Self.deviceA, revision: 400)
        onA.x[historical.key] = historical.value
        var onB = try version("second edit B", device: Self.deviceB, revision: 500)
        onB.x[historical.key] = historical.value

        // This expected snapshot deliberately filters `historical.key`. If production
        // recursively embeds existing variants, its fingerprint/value cannot equal this.
        let expectedNew = try secureVariantValue(for: onA)
        let merged = try #require(SyncMerge.mergeEnvelope(
            base: ancestor, local: onA, remote: onB))

        #expect(content(merged) == content(onB))
        #expect(merged.x[historical.key] == historical.value,
                "a later conflict must not overwrite an unresolved earlier one")
        #expect(merged.x[expectedNew.key] == expectedNew.value)
        let variants = secureVariants(in: merged)
        #expect(variants.map(\.variantKey)
                == [historical.key, expectedNew.key].sorted())
        #expect(variants.allSatisfy {
            $0.sourceExtensions.keys.allSatisfy { !isReservedConflictExtension($0) }
        }, "a snapshot must not recursively contain prior conflict payloads")
    }

    @Test func secureContentConflictPreservesBothOpaqueCiphertextsAndTheirProvenance() async throws {
        let harness = try harness("secure")
        defer { cleanUp(harness) }

        let vaultKeyring = SnippetCrypto.Keyring.generate()
        let context = SnippetCrypto.RecordContext(
            scopeID: Self.vaultKID, recordID: Self.snippetID)
        let ancestorPlaintext = Data("ancestor secret".utf8)
        let plaintextA = Data("secret written on A".utf8)
        let plaintextB = Data("secret written on B".utf8)
        let sealedAncestor = try SnippetCrypto.seal(
            ancestorPlaintext, for: context, keyring: vaultKeyring)
        let sealedA = try SnippetCrypto.seal(plaintextA, for: context, keyring: vaultKeyring)
        let sealedB = try SnippetCrypto.seal(plaintextB, for: context, keyring: vaultKeyring)
        let hashKey = vaultKeyring.contentHashKey

        let ancestor = secureEnvelope(
            device: Self.deviceA,
            revision: 100,
            sealed: sealedAncestor,
            contentHash: SnippetCrypto.contentHash(of: ancestorPlaintext, key: hashKey))
        let editA = secureEnvelope(
            device: Self.deviceA,
            revision: 200,
            sealed: sealedA,
            contentHash: SnippetCrypto.contentHash(of: plaintextA, key: hashKey))
        let editB = secureEnvelope(
            device: Self.deviceB,
            revision: 300,
            sealed: sealedB,
            contentHash: SnippetCrypto.contentHash(of: plaintextB, key: hashKey))
        let expectedVariant = try secureVariantValue(for: editA)

        await establishSharedAncestor(ancestor, in: harness)
        await race(editA, against: editB, firstWriter: .a, in: harness)

        let immediate = try #require(harness.libraryB.envelopes[Self.snippetID])
        #expect(content(immediate) == Data(sealedB.utf8),
                "the clock winner remains the ordinary secure envelope")
        #expect(copies(in: harness.libraryB.envelopes).isEmpty,
                "raw vault bytes must not be filed as a VaultRecord under a new UUID")
        #expect(immediate.x[expectedVariant.key] == expectedVariant.value,
                "the complete losing snapshot is retained inside the encrypted extension bag")

        let variant = try #require(secureVariants(in: immediate).only)
        #expect(variant.version == 1)
        #expect(variant.copyID == expectedVariant.copyID)
        #expect(variant.copyID != Self.snippetID)
        #expect(variant.sourceID == Self.snippetID)
        #expect(variant.sourceHLC == editA.hlc.string)
        #expect(variant.sourceOrigin == editA.origin)
        #expect(variant.secure)
        #expect(variant.content == Data(sealedA.utf8),
                "the losing ciphertext is preserved byte-for-byte while the vault is locked")
        #expect(variant.contentHash == contentHash(plaintextA, keyring: vaultKeyring))
        #expect(variant.vaultKID == Self.vaultKID)
        #expect(variant.name == editA.fields?.name)
        #expect(variant.keyword == editA.fields?.keyword)
        #expect(variant.tags == editA.fields?.tags)
        #expect(variant.isEnabled == editA.fields?.isEnabled)
        #expect(variant.isPinned == editA.fields?.isPinned)
        #expect(variant.createdAt == editA.fields?.createdAt.timeIntervalSinceReferenceDate)
        #expect(variant.updatedAt == editA.fields?.updatedAt.timeIntervalSinceReferenceDate)
        #expect(variant.sourceExtensions[SyncEnvelope.vaultContentHashExtensionKey]?.text
                == contentHash(plaintextA, keyring: vaultKeyring))
        #expect(variant.sourceExtensions[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                == Self.vaultKID)

        // The seal's key and AAD are bound to `sourceID`. Merely assigning `copyID`
        // cannot make it a valid new VaultRecord; only a key-aware layer may later open
        // with sourceID and reseal under copyID. This assertion must fail authentication,
        // not materialize either secret as plaintext.
        #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
            try SnippetCrypto.open(
                sealedA,
                for: SnippetCrypto.RecordContext(
                    scopeID: Self.vaultKID, recordID: variant.copyID),
                keyring: vaultKeyring)
        }

        await settle(harness)
        let result = try snapshot(harness)
        #expect(result.onA == result.onB)
        #expect(result.onA == result.backend)
        #expect(Set(result.onA.keys) == [Self.snippetID])
        #expect(copies(in: result.onA).isEmpty)
        let settled = try #require(result.onA[Self.snippetID])
        #expect(content(settled) == Data(sealedB.utf8))
        #expect(secureVariants(in: settled).count == 1,
                "retries must retain exactly one opaque snapshot, not breed variants")
        #expect(settled.x[expectedVariant.key] == expectedVariant.value)
    }

}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
