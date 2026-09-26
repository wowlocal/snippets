import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class SecureEditorSyncRaceTests: XCTestCase {
    private var root: URL!
    private var previousRoot: String?

    override func setUpWithError() throws {
        let key = SnippetStorageLocations.rootOverrideEnvironmentKey
        previousRoot = ProcessInfo.processInfo.environment[key]
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SecureEditorSyncRaceTests-\(UUID().uuidString)")
        setenv(key, root.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        let key = SnippetStorageLocations.rootOverrideEnvironmentKey
        if let previousRoot { setenv(key, previousRoot, 1) } else { unsetenv(key) }
        try? FileManager.default.removeItem(at: root)
    }

    func testSnapshotFlushesPendingSecureNameAndKeyword() async throws {
        let f = try await fixture()
        defer { f.controller.cancelEditorListReload() }
        var draft = f.snippet
        draft.name = "New complete name"
        draft.keyword = "new-keyword"
        f.controller.commitSecureEdit(draft)
        XCTAssertNotEqual(f.secure.record(draft.id)?.name, draft.name)

        let snapshot = try f.bridge.currentSnapshot(agreedBase: SyncBase())

        XCTAssertEqual(snapshot.envelopes[draft.id]?.fields?.name, draft.name)
        XCTAssertEqual(snapshot.envelopes[draft.id]?.fields?.keyword, draft.keyword)
        XCTAssertNil(f.controller.pendingSecureEdit)
    }

    func testEditBetweenSnapshotAndApplyRejectsStaleRemoteCAS() async throws {
        let f = try await fixture()
        defer { f.controller.cancelEditorListReload() }
        let before = try f.bridge.currentSnapshot(agreedBase: SyncBase())
        let stale = try XCTUnwrap(before.envelopes[f.snippet.id])
        var draft = f.snippet
        draft.name = "Newer local typing"
        f.controller.commitSecureEdit(draft)

        let outcome = try f.bridge.applyRemote(
            [stale], expectedPrimary: [draft.id: before.primaryState(for: draft.id)])

        XCTAssertEqual(outcome.retryIDs, [draft.id])
        XCTAssertTrue(outcome.changedIDs.isEmpty)
        XCTAssertEqual(f.secure.record(draft.id)?.name, draft.name)
        XCTAssertNil(f.controller.pendingSecureEdit)
    }

    func testOwnVaultSavePreservesUnfinishedKeywordAndCaret() async throws {
        let f = try await fixture(bindUI: true)
        defer { f.controller.cancelEditorListReload() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = f.controller.view
        defer { window.contentView = nil; window.close() }
        f.controller.keywordField.stringValue = "my "
        window.makeFirstResponder(f.controller.keywordField)
        let editor = try XCTUnwrap(f.controller.keywordField.currentEditor())
        editor.string = "my "
        editor.selectedRange = NSRange(location: 2, length: 0)
        var draft = f.snippet
        draft.keyword = "my"
        f.controller.commitSecureEdit(draft)

        try f.controller.flushPendingSecureEditForSync()

        XCTAssertEqual(editor.string, "my ", "The user's unfinished space must survive a save")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(f.secure.record(draft.id)?.keyword, "my")
    }

    func testFailedDraftSaveStopsSnapshotAndKeepsDraft() async throws {
        let f = try await fixture()
        defer { f.controller.cancelEditorListReload() }
        var draft = f.snippet
        draft.id = UUID() // A record that no longer exists cannot be durably edited.
        draft.name = "Unsaved typing"
        f.controller.commitSecureEdit(draft)

        XCTAssertThrowsError(try f.bridge.currentSnapshot(agreedBase: SyncBase()))
        XCTAssertEqual(f.controller.pendingSecureEdit?.name, draft.name)
        XCTAssertFalse(f.controller.isFlushingSecureEdit)
        f.controller.pendingSecureEdit = nil
    }

    func testExactServerEchoDoesNotInvalidateSecureEditor() async throws {
        let f = try await fixture()
        let snapshot = try f.bridge.currentSnapshot(agreedBase: SyncBase())
        let echo = try XCTUnwrap(snapshot.envelopes[f.snippet.id])
        var invalidated = false
        f.controller.store.onChange = { invalidated = $0.affects(echo.id) }
        let outcome = try f.bridge.applyRemote(
            [echo], expectedPrimary: [echo.id: snapshot.primaryState(for: echo.id)])
        XCTAssertFalse(invalidated)
        XCTAssertTrue(outcome.retryIDs.isEmpty)
        XCTAssertEqual(f.secure.record(echo.id)?.name, f.snippet.name)
    }

    func testMetadataNotificationCannotReplaceBodyDuringSameSave() async throws {
        let f = try await fixture(bindUI: true)
        defer { f.controller.cancelEditorListReload() }
        var draft = f.snippet
        draft.name = "Edited metadata"
        draft.content = "Edited body"
        f.controller.secureContentEditableForID = draft.id
        f.controller.snippetTextView.string = draft.content
        f.controller.commitSecureEdit(draft)

        try f.controller.flushPendingSecureEditForSync()

        XCTAssertEqual(try f.secure.content(for: draft.id), draft.content)
        XCTAssertEqual(f.controller.snippetTextView.string, draft.content)
        XCTAssertEqual(f.secure.record(draft.id)?.name, draft.name)
    }

    func testRealRemoteRenameStillInvalidatesSecureEditor() async throws {
        let f = try await fixture()
        let snapshot = try f.bridge.currentSnapshot(agreedBase: SyncBase())
        let original = try XCTUnwrap(snapshot.envelopes[f.snippet.id])
        var fields = try XCTUnwrap(original.fields)
        fields.name = "Renamed on another device"
        let incoming = SyncEnvelope(id: original.id, hlc: original.hlc,
            origin: original.origin, secure: true, deleted: false,
            fields: fields, x: original.x)
        var invalidated = false
        f.controller.store.onChange = { invalidated = $0.affects(incoming.id) }

        _ = try f.bridge.applyRemote(
            [incoming], expectedPrimary: [incoming.id: snapshot.primaryState(for: incoming.id)])

        XCTAssertTrue(invalidated)
        XCTAssertEqual(f.secure.record(incoming.id)?.name, incoming.fields?.name)
    }

    private func fixture(bindUI: Bool = false) async throws -> (
        controller: ViewController, secure: SecureSnippetStore,
        bridge: SnippetLibraryBridge, snippet: Snippet
    ) {
        let keychain = KeychainSecretStore(tier: .deviceOnly,
            service: "secure-editor-race-tests", inMemory: true)
        let session = VaultSession(keychain: keychain, authenticationEvaluator: { _ in true })
        let store = SnippetStore(configuration: .iOS)
        let secure = SecureSnippetStore(session: session, keychain: keychain,
            selectedSyncProvider: { nil }, syncIsEnabled: { false }, deviceID: store.deviceID)
        store.secureProvider = secure
        let pending = try XCTUnwrap(secure.prepareVaultCreationIfNeeded())
        _ = try secure.commitVaultCreation(pending)
        _ = try await session.unlock(reason: "Test fixture")
        let snippet = try store.addSnippet(name: "Initial name", content: "Fixture body")
        try store.flushPendingWritesForSync()
        try secure.promote(snippetID: snippet.id)
        store.reloadAfterExternalWrite(notifyChange: false)

        let controller = ViewController()
        controller.store = store
        controller.usageStore = SnippetUsageStore()
        controller.engine = SnippetExpansionEngine(store: store, usage: controller.usageStore)
        controller.selectedSnippetID = snippet.id
        controller.editingSnippetID = snippet.id
        if bindUI {
            controller.buildUI()
            controller.bindState()
            controller.reloadVisibleSnippets(keepSelection: true)
            secure.onChange = { [weak store] in store?.onChange?(.init(source: .external)) }
        }
        let bridge = SnippetLibraryBridge(store: store, secureStore: secure,
            flushPendingEditorEdits: { [weak controller] in
                try controller?.flushPendingSecureEditForSync()
            })
        return (controller, secure, bridge, snippet)
    }
}
#endif
