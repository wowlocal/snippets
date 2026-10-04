import Foundation
import Testing

@testable import SnippetsCore

/// A conflict copy keeps its deterministic identity when it is deleted and restored.
///
/// The frozen `Snippet` model cannot hold `conflictCopy.v1`, and an ordinary tombstone
/// deliberately carries no `x`. Once a deletion was confirmed, nothing remembered the
/// provenance, so ⌘Z re-encoded the copy on its UUIDv5 id without it. Every peer that
/// still held the valid copy then saw an unrelated occupant of a reserved id and stopped
/// with a sticky `localLibraryQuarantined` halt — the 2026-10-04 Mac → iPhone incident.
@MainActor
@Suite("Restored conflict copy identity")
struct SyncRestoredConflictCopyTests {
    private static let sourceID = UUID(
        uuidString: "40000000-0000-4000-8000-000000000001")!
    private static let mac = "aaaaaaa1"
    private static let phone = "bbbbbbb2"

    /// The plain half of `SnippetLibraryBridge`: primary `Snippet` values plus the
    /// derived projection sidecar it rewrites after every projection and remote apply.
    private final class PlainLibrary: SyncLibraryAccess {
        let device: String
        var snippets: [Snippet] = []
        private(set) var sidecar = SyncBase()
        /// `false` is the bridge before the fix: the sidecar was exactly the projection.
        let retainsCopyIdentities: Bool

        init(device: String, retainsCopyIdentities: Bool = true) {
            self.device = device
            self.retainsCopyIdentities = retainsCopyIdentities
        }

        private func persist(_ projected: [UUID: SyncEnvelope]) {
            guard retainsCopyIdentities else {
                var next = SyncBase()
                for envelope in projected.values { next.record(envelope) }
                sidecar = next
                return
            }
            sidecar = SyncLibraryProjection.projectionSidecar(
                for: projected,
                replacing: sidecar)
        }

        func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
            let projected = SyncLibraryProjection.currentEnvelopes(
                snippets: snippets,
                records: [],
                deviceID: device,
                metadata: sidecar,
                agreedBase: agreedBase)
            persist(projected)
            return projected
        }

        func classifyRemote(_ incoming: [SyncEnvelope]) -> RemoteClassification {
            RemoteClassification(
                applicable: incoming,
                deferredIDs: [],
                incompatibleVaultIDs: [])
        }

        func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
            var projected: [UUID: SyncEnvelope] = [:]
            for envelope in sidecar.envelopes.values where !envelope.deleted {
                projected[envelope.id] = envelope
            }
            var changed: [UUID] = []
            for envelope in incoming {
                let index = snippets.firstIndex { $0.id == envelope.id }
                if envelope.deleted {
                    if let index {
                        snippets.remove(at: index)
                        changed.append(envelope.id)
                    }
                    projected[envelope.id] = nil
                } else if let snippet = envelope.plainSnippet {
                    if let index {
                        if snippets[index] != snippet {
                            snippets[index] = snippet
                            changed.append(envelope.id)
                        }
                    } else {
                        snippets.append(snippet)
                        changed.append(envelope.id)
                    }
                    projected[envelope.id] = envelope
                }
            }
            persist(projected)
            return ApplyOutcome(changedIDs: changed)
        }

        func liveIDs() -> Set<UUID> { Set(snippets.map(\.id)) }
    }

    private func envelope(device: String, revision: UInt64, body: String) -> SyncEnvelope {
        SyncEnvelope(
            id: Self.sourceID,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Shared snippet",
                keyword: "shared",
                content: Data(body.utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)))
    }

    /// The canonical copy every client mints for the phone's losing edit.
    private func mintedConflict() throws -> (source: SyncEnvelope, copy: SyncEnvelope) {
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: envelope(device: Self.phone, revision: 100, body: "ancestor"),
            local: envelope(device: Self.phone, revision: 200, body: "phone edit"),
            remote: envelope(device: Self.mac, revision: 300, body: "mac edit"))
        let source = try #require(merge.survivor)
        let copy = try #require(merge.conflictCopies.only)
        #expect(SyncMerge.hasValidConflictCopyIdentity(copy))
        return (source, copy)
    }

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-restored-conflict-copy-\(label)-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func engine(
        _ library: PlainLibrary,
        backend: InMemoryTransport,
        sealer: SnippetCryptoSealer,
        directory: URL
    ) -> SyncEngine {
        SyncEngine(
            transport: backend,
            library: library,
            sealer: sealer,
            device: library.device,
            baseURL: directory.appendingPathComponent("base.json"),
            journalURL: directory.appendingPathComponent("journal.json"),
            stateURL: directory.appendingPathComponent("state.json"),
            quarantineFolderURL: directory.appendingPathComponent(
                "Quarantine", isDirectory: true),
            lockURL: directory.appendingPathComponent("library.lock"),
            temporaryDirectory: directory)
    }

    private func isSynced(_ state: SyncEngine.State) -> Bool {
        if case .idle(let lastSync) = state { return lastSync != nil }
        return false
    }

    /// A Mac and a phone that both hold the canonical copy, confirmed by the backend.
    private struct World {
        let backend: InMemoryTransport
        let sealer: SnippetCryptoSealer
        let source: SyncEnvelope
        let copy: SyncEnvelope
        let macLibrary: PlainLibrary
        let phoneLibrary: PlainLibrary
        let mac: SyncEngine
        let phone: SyncEngine
        let directories: [URL]

        func published(_ id: UUID) throws -> SyncEnvelope {
            let record = try #require(backend.snapshot.first { $0.id == id })
            return try WireCodec.open(record, using: sealer)
        }
    }

    private func joinedWorld(macRetainsCopyIdentities: Bool = true) async throws -> World {
        let macDirectory = try directory("mac")
        let phoneDirectory = try directory("phone")
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(),
            scopeID: "restored-conflict-copy")
        let (source, copy) = try mintedConflict()
        backend.seed([
            try WireCodec.seal(source, using: sealer),
            try WireCodec.seal(copy, using: sealer),
        ])
        let macLibrary = PlainLibrary(
            device: Self.mac, retainsCopyIdentities: macRetainsCopyIdentities)
        let phoneLibrary = PlainLibrary(device: Self.phone)
        let world = World(
            backend: backend,
            sealer: sealer,
            source: source,
            copy: copy,
            macLibrary: macLibrary,
            phoneLibrary: phoneLibrary,
            mac: engine(macLibrary, backend: backend, sealer: sealer, directory: macDirectory),
            phone: engine(
                phoneLibrary, backend: backend, sealer: sealer, directory: phoneDirectory),
            directories: [macDirectory, phoneDirectory])
        let macJoined = await world.mac.sync()
        let phoneJoined = await world.phone.sync()
        #expect(isSynced(macJoined), "the Mac did not join: \(macJoined)")
        #expect(isSynced(phoneJoined), "the phone did not join: \(phoneJoined)")
        #expect(world.phone.agreedBase.envelope(copy.id) == copy)
        return world
    }

    private func remove(_ world: World) {
        for directory in world.directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The user deletes the copy on the Mac, and the provenance-free tombstone is accepted.
    private func deleteCopyOnMac(in world: World) async throws -> SyncEnvelope {
        world.macLibrary.snippets.removeAll { $0.id == world.copy.id }
        world.mac.noteUserInitiatedDeletions([world.copy.id])
        let deleted = await world.mac.sync()
        #expect(isSynced(deleted), "the deletion did not sync: \(deleted)")
        let tombstone = try world.published(world.copy.id)
        #expect(tombstone.deleted)
        #expect(tombstone.x[SyncMerge.plainConflictCopyExtensionKey] == nil,
                "the wire tombstone stays provenance-free")
        return tombstone
    }

    /// ⌘Z puts the identical Snippet back into the Mac's primary storage.
    private func restoreCopyOnMac(in world: World) async throws -> SyncEnvelope {
        world.mac.cancelUserInitiatedDeletions([world.copy.id])
        world.macLibrary.snippets.append(try #require(world.copy.plainSnippet))
        let recreated = await world.mac.sync()
        #expect(isSynced(recreated), "the restoration did not sync: \(recreated)")
        return try world.published(world.copy.id)
    }

    // MARK: - The incident, end to end

    @Test(arguments: [false, true])
    func aCopyRestoredAfterItsConfirmedDeletionKeepsItsIdentityOnEveryPeer(
        peerAppliedTheDeletionFirst: Bool
    ) async throws {
        let world = try await joinedWorld()
        defer { remove(world) }
        let copy = world.copy

        let tombstone = try await deleteCopyOnMac(in: world)
        if peerAppliedTheDeletionFirst {
            let applied = await world.phone.sync()
            #expect(isSynced(applied), "the phone did not apply the deletion: \(applied)")
            #expect(!world.phoneLibrary.snippets.contains { $0.id == copy.id })
        }

        let restored = try await restoreCopyOnMac(in: world)
        #expect(!restored.deleted)
        #expect(restored.fields == copy.fields)
        #expect(restored.x == copy.x,
                "a restored copy must be re-published with its own provenance")
        #expect(SyncMerge.hasValidConflictCopyIdentity(restored))
        #expect(restored.hlc > tombstone.hlc,
                "the restoration must supersede the tombstone on every peer")

        let received = await world.phone.sync()
        #expect(isSynced(received),
                "a peer that held the valid copy stopped on its restoration: \(received)")
        #expect(world.phoneLibrary.snippets.contains(try #require(copy.plainSnippet)))
        #expect(world.phone.agreedBase.envelope(copy.id) == restored)

        // A restored pair is an unconfirmed copy of a live source, so the journal runs
        // its copy-before-source sequencing: the unchanged source is released once
        // after the copy was accepted. Then both devices are at a fixed point.
        let beforeRelease = world.backend.submittedBatches.count
        _ = await world.mac.sync()
        _ = await world.phone.sync()
        let released = try world.backend.submittedBatches.dropFirst(beforeRelease)
            .flatMap { try $0.map { try WireCodec.open($0, using: world.sealer) } }
        #expect(released.allSatisfy { $0 == world.source },
                "only the unchanged source may follow its restored copy")
        let settled = world.backend.submittedBatches.count
        _ = await world.mac.sync()
        _ = await world.phone.sync()
        #expect(world.backend.submittedBatches.count == settled)
    }

    /// Recovery for a library already damaged by an unfixed build: deleting the
    /// unmarked restoration again on its producer releases the halted peer on Check Again.
    @Test func deletingAnUnmarkedRestorationAgainReleasesAHaltedPeer() async throws {
        let world = try await joinedWorld(macRetainsCopyIdentities: false)
        defer { remove(world) }
        let copy = world.copy

        _ = try await deleteCopyOnMac(in: world)
        let unmarked = try await restoreCopyOnMac(in: world)
        #expect(unmarked.x.isEmpty, "the unfixed producer publishes no provenance")
        let halted = await world.phone.sync()
        guard case .halted(.localLibraryQuarantined, _) = halted else {
            Issue.record("the unmarked restoration did not stop the phone: \(halted)")
            return
        }
        #expect(world.phone.recoveryAction == .checkAgain)

        _ = try await deleteCopyOnMac(in: world)
        world.phone.performRecovery(.checkAgain)
        let recovered = await world.phone.sync()

        #expect(isSynced(recovered), "Check Again did not release the phone: \(recovered)")
        #expect(!world.phoneLibrary.snippets.contains { $0.id == copy.id })
        #expect(world.phone.agreedBase.envelope(copy.id)?.deleted == true)
        #expect(world.phoneLibrary.snippets.contains { $0.id == world.source.id })
    }

    // MARK: - The sidecar memory

    private func ordinary(_ revision: UInt64) -> SyncEnvelope {
        SyncEnvelope(
            id: UUID(),
            hlc: HLC(wallMs: revision, counter: 0, device: Self.mac),
            origin: Self.mac,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Ordinary", keyword: "", content: Data("body".utf8),
                tags: [], isEnabled: true, isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)))
    }

    private func sidecar(_ envelopes: SyncEnvelope...) -> SyncBase {
        var base = SyncBase()
        for envelope in envelopes { base.record(envelope) }
        return base
    }

    @Test func aCopyLeavingPrimaryLeavesOnlyItsIdentityBehind() throws {
        let (source, copy) = try mintedConflict()
        let other = ordinary(400)

        let next = SyncLibraryProjection.projectionSidecar(
            for: [source.id: source],
            replacing: sidecar(source, copy, other))

        #expect(next.envelope(source.id) == source)
        #expect(next.envelope(other.id) == nil,
                "an ordinary deleted record leaves nothing behind")
        let identity = try #require(next.envelope(copy.id))
        #expect(identity.deleted)
        #expect(!identity.secure)
        #expect(identity.fields == nil, "no body or field survives the deletion")
        #expect(identity.x == [
            SyncMerge.plainConflictCopyExtensionKey:
                try #require(copy.x[SyncMerge.plainConflictCopyExtensionKey]),
        ])
        #expect(identity.hlc == copy.hlc)
        #expect(identity.origin == copy.origin)
        #expect(SyncMerge.hasValidConflictCopyIdentity(identity))
    }

    @Test func aRetainedIdentityLastsUntilTheCopyReturns() throws {
        let (source, copy) = try mintedConflict()
        let retired = SyncLibraryProjection.projectionSidecar(
            for: [source.id: source],
            replacing: sidecar(source, copy))
        let identity = try #require(retired.envelope(copy.id))

        let later = SyncLibraryProjection.projectionSidecar(
            for: [source.id: source],
            replacing: retired)
        #expect(later.envelope(copy.id) == identity)

        let returned = SyncLibraryProjection.projectionSidecar(
            for: [source.id: source, copy.id: copy],
            replacing: later)
        #expect(returned.envelope(copy.id) == copy)
        #expect(returned.envelopes.count == 2)
    }

    @Test func onlyAVerifiedPlainIdentityIsRetained() throws {
        let (_, copy) = try mintedConflict()

        // Provenance copied onto a record whose id it does not derive.
        var forged = ordinary(500)
        forged.x[SyncMerge.plainConflictCopyExtensionKey] =
            copy.x[SyncMerge.plainConflictCopyExtensionKey]
        #expect(!SyncMerge.hasValidConflictCopyIdentity(forged))

        // A secure copy keeps its provenance in vault.json, its own primary storage.
        var secure = copy
        secure.secure = true

        // Only the exact identity-only shape is carried forward.
        var widened = try #require(SyncLibraryProjection.projectionSidecar(
            for: [:],
            replacing: sidecar(copy)).envelope(copy.id))
        widened.x["future"] = true

        for previous in [forged, secure, widened] {
            let next = SyncLibraryProjection.projectionSidecar(
                for: [:],
                replacing: sidecar(previous))
            #expect(next.envelopes.isEmpty, "\(previous.id) must not be retained")
        }
    }

    @Test func retainedIdentitiesAreBoundedNewestFirst() throws {
        let limit = SyncLibraryProjection.maximumRetainedCopyIdentities
        var previous = SyncBase()
        var copies: [SyncEnvelope] = []
        for index in 0..<(limit + 3) {
            let merge = try SyncMerge.mergeEnvelopeOutcome(
                base: envelope(device: Self.phone, revision: 100, body: "ancestor"),
                local: envelope(
                    device: Self.phone,
                    revision: 200 + UInt64(index),
                    body: "phone edit \(index)"),
                remote: envelope(device: Self.mac, revision: 10_000, body: "mac edit"))
            let copy = try #require(merge.conflictCopies.only)
            copies.append(copy)
            previous.record(copy)
        }

        let next = SyncLibraryProjection.projectionSidecar(for: [:], replacing: previous)

        #expect(next.envelopes.count == limit)
        let kept = Set(next.envelopes.values.map(\.id))
        let newest = copies.sorted { $0.hlc > $1.hlc }.prefix(limit).map(\.id)
        #expect(kept == Set(newest))
    }

    // MARK: - Re-projection over the tombstone

    @Test func aCopyRestoredOverItsTombstoneIsProjectedWithItsProvenance() throws {
        let (source, copy) = try mintedConflict()
        let retained = SyncLibraryProjection.projectionSidecar(
            for: [source.id: source],
            replacing: sidecar(source, copy))
        var tombstone = copy.tombstoned(
            hlc: HLC(wallMs: 9_000, counter: 0, device: Self.mac),
            origin: Self.mac)
        tombstone.x[SyncEnvelope.userInitiatedDeletionExtensionKey] =
            .array([.string(try copy.envelopeHash())])
        let agreed = sidecar(source, tombstone)
        let snippets = [try #require(source.plainSnippet), try #require(copy.plainSnippet)]

        let restored = try #require(SyncLibraryProjection.currentEnvelopes(
            snippets: snippets,
            records: [],
            deviceID: Self.mac,
            metadata: retained,
            agreedBase: agreed)[copy.id])

        #expect(!restored.deleted)
        #expect(restored.fields == copy.fields)
        #expect(restored.x == copy.x,
                "provenance returns; the tombstone's deletion proof does not")
        #expect(restored.hlc > tombstone.hlc)
        #expect(restored.origin == Self.mac)
        #expect(SyncMerge.hasValidConflictCopyIdentity(restored))
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
