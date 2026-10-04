import XCTest
#if os(macOS)
@testable import Snippets_Debug
#else
@testable import Snippets
#endif

/// The app-level half of `SyncRestoredConflictCopyTests`: the real `SnippetStore`,
/// `SnippetLibraryBridge` and its on-disk projection sidecar. A deleted plain conflict
/// copy that comes back — ⌘Z, or a restored file after a relaunch — must be published
/// with its `conflictCopy.v1`, or every peer still holding the copy halts.
@MainActor
final class RestoredConflictCopySyncTests: XCTestCase {
    private var root: URL!
    private var previousRoot: String?

    override func setUpWithError() throws {
        previousRoot = ProcessInfo.processInfo.environment[
            SnippetStorageLocations.rootOverrideEnvironmentKey]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoredConflictCopy-\(UUID())")
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        if let previousRoot {
            setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previousRoot, 1)
        } else {
            unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        }
        try? FileManager.default.removeItem(at: root)
    }

    #if os(macOS) // InMemoryTransport is intentionally not shipped in the iOS app.
    private struct Fixture {
        let backend: InMemoryTransport
        let sealer: SnippetCryptoSealer
        let copy: SyncEnvelope
    }

    private func envelope(device: String, revision: UInt64, body: String) -> SyncEnvelope {
        SyncEnvelope(
            id: UUID(uuidString: "41000000-0000-4000-8000-000000000001")!,
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

    /// A backend holding a source and the canonical copy of a phone's losing edit.
    private func fixture() throws -> Fixture {
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: envelope(device: "bbbbbbb2", revision: 100, body: "ancestor"),
            local: envelope(device: "bbbbbbb2", revision: 200, body: "phone edit"),
            remote: envelope(device: "aaaaaaa1", revision: 300, body: "mac edit"))
        let source = try XCTUnwrap(merge.survivor)
        XCTAssertEqual(merge.conflictCopies.count, 1)
        let copy = try XCTUnwrap(merge.conflictCopies.first)
        XCTAssertTrue(SyncMerge.hasValidConflictCopyIdentity(copy))
        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(
            keyring: .generate(), scopeID: "restored-conflict-copy-app")
        backend.seed([
            try WireCodec.seal(source, using: sealer),
            try WireCodec.seal(copy, using: sealer),
        ])
        return Fixture(backend: backend, sealer: sealer, copy: copy)
    }

    private func engine(_ store: SnippetStore, _ fixture: Fixture) -> SyncEngine {
        let keychain = KeychainSecretStore(
            tier: .deviceOnly, service: "restored-conflict-copy-test", inMemory: true)
        let secure = SecureSnippetStore(
            session: VaultSession(keychain: keychain, authenticationEvaluator: { _ in true }),
            keychain: keychain,
            selectedSyncProvider: { nil },
            syncIsEnabled: { false },
            deviceID: store.deviceID)
        return SyncEngine(
            transport: fixture.backend,
            library: SnippetLibraryBridge(store: store, secureStore: secure),
            sealer: fixture.sealer,
            device: store.deviceID)
    }

    private func published(_ fixture: Fixture) throws -> SyncEnvelope {
        let record = try XCTUnwrap(fixture.backend.snapshot.first { $0.id == fixture.copy.id })
        return try WireCodec.open(record, using: fixture.sealer)
    }

    private func assertSynced(
        _ state: SyncEngine.State,
        _ step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .idle(let lastSync) = state, lastSync != nil else {
            return XCTFail("\(step) did not sync: \(state)", file: file, line: line)
        }
    }

    private func assertRepublishedWithProvenance(
        _ fixture: Fixture,
        over tombstone: SyncEnvelope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let restored = try published(fixture)
        XCTAssertFalse(restored.deleted, file: file, line: line)
        XCTAssertEqual(restored.fields, fixture.copy.fields, file: file, line: line)
        XCTAssertEqual(restored.x, fixture.copy.x,
                       "the restored copy lost its provenance", file: file, line: line)
        XCTAssertTrue(SyncMerge.hasValidConflictCopyIdentity(restored), file: file, line: line)
        XCTAssertGreaterThan(restored.hlc, tombstone.hlc, file: file, line: line)
    }

    func testUndoAfterAConfirmedDeletionRepublishesTheCopyWithItsProvenance() async throws {
        let fixture = try fixture()
        let store = SnippetStore(configuration: .iOS)
        let engine = engine(store, fixture)
        assertSynced(await engine.sync(), "joining")
        XCTAssertTrue(store.snippets.contains { $0.id == fixture.copy.id })

        XCTAssertTrue(store.delete(snippetID: fixture.copy.id))
        assertSynced(await engine.sync(), "deleting")
        let tombstone = try published(fixture)
        XCTAssertTrue(tombstone.deleted)
        XCTAssertNil(tombstone.x[SyncMerge.plainConflictCopyExtensionKey])

        // Between the two, only the body-free identity remains on disk.
        guard case .loaded(let sidecar) = SyncBaseFile.load(
            from: SnippetStorageLocations.syncLibraryMetadataFileURL)
        else { return XCTFail("the projection sidecar was not written") }
        let identity = try XCTUnwrap(sidecar.envelope(fixture.copy.id))
        XCTAssertTrue(identity.deleted)
        XCTAssertNil(identity.fields)
        XCTAssertEqual(identity.x, fixture.copy.x)

        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.snippets.contains { $0.id == fixture.copy.id })
        assertSynced(await engine.sync(), "restoring")
        try assertRepublishedWithProvenance(fixture, over: tombstone)
    }

    func testARestoredFileAfterRelaunchRepublishesTheCopyWithItsProvenance() async throws {
        let fixture = try fixture()
        do {
            let store = SnippetStore(configuration: .iOS)
            let engine = engine(store, fixture)
            assertSynced(await engine.sync(), "joining")
            XCTAssertTrue(store.delete(snippetID: fixture.copy.id))
            assertSynced(await engine.sync(), "deleting")
        }
        let tombstone = try published(fixture)
        XCTAssertTrue(tombstone.deleted)

        // After a relaunch the user restores the copy from a backup of snippets.json.
        let restored = try XCTUnwrap(fixture.copy.plainSnippet)
        _ = try LibraryWriter.update(lockTimeout: 5, expectedDigest: nil) { snapshot in
            snapshot.snippets + [restored]
        }
        let store = SnippetStore(configuration: .iOS)
        let engine = engine(store, fixture)
        assertSynced(await engine.sync(), "restoring")
        try assertRepublishedWithProvenance(fixture, over: tombstone)
    }
    #endif
}
