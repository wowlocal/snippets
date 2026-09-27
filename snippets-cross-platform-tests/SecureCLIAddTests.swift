import XCTest
import CryptoKit
#if os(macOS)
@testable import Snippets_Debug
#else
@testable import Snippets
#endif

@MainActor
final class SecureCLIAddTests: XCTestCase {
    private var root: URL!
    private var previousRoot: String?

    override func setUpWithError() throws {
        previousRoot = ProcessInfo.processInfo.environment[SnippetStorageLocations.rootOverrideEnvironmentKey]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SecureCLIAdd-\(UUID())")
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        if let previousRoot { setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previousRoot, 1) }
        else { unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey) }
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture() async throws -> (SecureSnippetStore, VaultSession, KeychainSecretStore) {
        let keychain = KeychainSecretStore(tier: .deviceOnly, service: "secure-cli-add-test", inMemory: true)
        let session = VaultSession(keychain: keychain, authenticationEvaluator: { _ in true })
        let store = SecureSnippetStore(session: session, keychain: keychain,
            selectedSyncProvider: { nil }, syncIsEnabled: { false }, deviceID: "aabbccdd")
        let pending = try XCTUnwrap(store.prepareVaultCreationIfNeeded())
        _ = try store.commitVaultCreation(pending)
        _ = try await session.unlock(reason: "Synthetic test")
        return (store, session, keychain)
    }

    func testCreationNeverPersistsPlaintextAndIsVisibleToSync() async throws {
        let (store, session, _) = try await fixture()
        _ = session // retain session throughout the test
        let body = Data("synthetic-secret-НЕ-настоящий\nsecond line\n".utf8)
        let id = try store.addSecure(name: "", keyword: "test-secret", body: body,
            tags: ["work", "work"], isEnabled: false, isPinned: true)
        XCTAssertEqual(try store.contentData(for: id), body)
        let record = try XCTUnwrap(store.record(id))
        XCTAssertEqual(record.name, "", "never derive public metadata from secret body")
        XCTAssertEqual(record.tags, ["work"])
        XCTAssertFalse(record.isEnabled)
        XCTAssertTrue(record.isPinned)
        XCTAssertEqual(record.shell.content, "")
        XCTAssertFalse(try LibraryWriter.read(from: SnippetStorageLocations.snippetsFileURL).snippets.contains { $0.id == id })
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for url in files.allObjects.compactMap({ $0 as? URL }) {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                XCTAssertNil(try Data(contentsOf: url).range(of: body), "plaintext reached a file")
            }
        }
        let ordinary = SnippetStore(configuration: .iOS)
        let bridge = SnippetLibraryBridge(store: ordinary, secureStore: store)
        let snapshot = try bridge.currentSnapshot(agreedBase: SyncBase())
        let envelope = try XCTUnwrap(snapshot.envelopes[id])
        XCTAssertTrue(envelope.secure)
        XCTAssertNotEqual(envelope.fields?.content, body)
    }

    func testDuplicateKeywordAcrossBothStoresLeavesVaultUnchanged() async throws {
        let (store, session, _) = try await fixture()
        _ = session
        let body = Data("synthetic".utf8)
        _ = try store.addSecure(name: "", keyword: "café", body: body,
            tags: [], isEnabled: true, isPinned: false)
        let original = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        XCTAssertThrowsError(try store.addSecure(name: "", keyword: "CAFE", body: body,
            tags: [], isEnabled: true, isPinned: false))
        let ordinary = Snippet(name: "", keyword: "ordinary", content: "public")
        _ = try LibraryWriter.update(libraryURL: SnippetStorageLocations.snippetsFileURL,
            lockTimeout: 5, expectedDigest: nil) { _ in [ordinary] }
        XCTAssertThrowsError(try store.addSecure(name: "", keyword: "ORDINARY", body: body,
            tags: [], isEnabled: true, isPinned: false))
        XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL), original)
    }

    func testNotificationSeesDurableRecordAndMergedDesktopList() async throws {
        let (secure, session, _) = try await fixture()
        _ = session
        let ordinary = SnippetStore(configuration: .iOS)
        ordinary.secureProvider = secure
        XCTAssertTrue(ordinary.snippetsSortedForDisplay().isEmpty)
        var notifications = 0
        secure.onChange = {
            notifications += 1
            guard case .loaded(let vault) = VaultFile.load() else { return XCTFail("not durable") }
            XCTAssertEqual(vault.records.count, 1)
            XCTAssertEqual(ordinary.snippetsSortedForDisplay().first(where: { $0.id == vault.records[0].id })?.content, "")
        }
        _ = try secure.addSecure(name: "Demo", keyword: "notified", body: Data("synthetic".utf8),
            tags: [], isEnabled: true, isPinned: false)
        XCTAssertEqual(notifications, 1)
    }

    #if os(macOS) // InMemoryTransport is intentionally not shipped in the iOS app.
    func testCreationSurvivesRestartAndSyncsWhileVaultLockedAfterOfflineFailure() async throws {
        let (secure, session, keychain) = try await fixture()
        let id = try secure.addSecure(name: "Demo", keyword: "restart", body: Data("synthetic-secret".utf8),
            tags: [], isEnabled: true, isPinned: false)
        session.lock()
        let sealer = SnippetCryptoSealer(keyring: .generate(), scopeID: "secure-add-test")
        let remote = InMemoryTransport()
        remote.configure { $0.unreachable = true }
        let ordinary = SnippetStore(configuration: .iOS)
        let first = SyncEngine(transport: remote,
            library: SnippetLibraryBridge(store: ordinary, secureStore: secure),
            sealer: sealer, device: ordinary.deviceID)
        _ = await first.sync()
        XCTAssertTrue(remote.snapshot.isEmpty)

        // New projections read the durable primary files, even if the process died
        // before the in-memory onChange callback or a successful network round.
        let restartedSession = VaultSession(keychain: keychain, authenticationEvaluator: { _ in false })
        let restarted = SecureSnippetStore(session: restartedSession, keychain: keychain,
            selectedSyncProvider: { nil }, syncIsEnabled: { false }, deviceID: ordinary.deviceID)
        XCTAssertNotNil(restarted.record(id))
        XCTAssertFalse(restartedSession.state.isUnlocked)
        remote.configure { $0.unreachable = false }
        let engine = SyncEngine(transport: remote,
            library: SnippetLibraryBridge(store: ordinary, secureStore: restarted),
            sealer: sealer, device: ordinary.deviceID)
        _ = await engine.sync(bypassingBackoff: true)
        let wire = try XCTUnwrap(remote.snapshot.first { $0.id == id })
        let envelope = try WireCodec.open(wire, using: sealer)
        XCTAssertTrue(envelope.secure)
        XCTAssertEqual(envelope.fields?.content, Data(try XCTUnwrap(restarted.record(id)).sealed.utf8))
        XCTAssertFalse(restartedSession.state.isUnlocked)
        _ = await engine.sync(bypassingBackoff: true)
        XCTAssertEqual(remote.snapshot.filter { $0.id == id }.count, 1)
    }

    #endif

    func testWriteFailureDoesNotPublishChangeOrAlterVault() async throws {
        let (secure, session, keychain) = try await fixture()
        _ = secure
        let oldBytes = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let invalidStaging = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: invalidStaging)
        let failing = SecureSnippetStore(session: session, keychain: keychain,
            selectedSyncProvider: { nil }, syncIsEnabled: { false }, deviceID: "aabbccdd",
            temporaryDirectory: invalidStaging)
        _ = try await session.unlock(reason: "Synthetic write failure")
        var notifications = 0
        failing.onChange = { notifications += 1 }
        XCTAssertThrowsError(try failing.addSecure(name: "", keyword: "failed", body: Data("synthetic".utf8),
            tags: [], isEnabled: true, isPinned: false))
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL), oldBytes)
        XCTAssertEqual(failing.count, 0)
    }

    #if os(macOS)
    func testCLICommitFlushesPendingEditorKeywordBeforeCollisionCheck() async throws {
        let (secure, session, _) = try await fixture()
        let ordinary = SnippetStore(configuration: .iOS, persistDelay: 60)
        var draft = try ordinary.addSnippet(name: "Draft", content: "public")
        try ordinary.flushPendingWritesForSync()
        draft.keyword = "reserved-in-editor"
        XCTAssertTrue(ordinary.update(draft))
        XCTAssertEqual(try LibraryWriter.read(from: SnippetStorageLocations.snippetsFileURL).snippets.first?.keyword, "")
        let server = ControlServer(session: session, secureStore: secure,
            prepareSecureCreation: { try ordinary.flushPendingWritesForSync() })
        let input = SnippetsIPC.SecureAdd(name: "", keyword: draft.keyword, body: Data("synthetic".utf8),
            tags: [], isEnabled: true, isPinned: false)
        XCTAssertThrowsError(try server.commitSecureCreation(input))
        XCTAssertEqual(secure.count, 0)
        XCTAssertEqual(try LibraryWriter.read(from: SnippetStorageLocations.snippetsFileURL).snippets.first?.keyword, draft.keyword)
    }
    #endif

    func testLockedVaultAndInvalidUTF8DoNotCreateRecords() async throws {
        let (store, session, _) = try await fixture()
        XCTAssertThrowsError(try store.addSecure(name: "", keyword: "invalid", body: Data([0xff]),
            tags: [], isEnabled: true, isPinned: false))
        session.lock()
        XCTAssertThrowsError(try store.addSecure(name: "", keyword: "locked", body: Data("test".utf8),
            tags: [], isEnabled: true, isPinned: false))
        XCTAssertEqual(store.count, 0)
    }
}
