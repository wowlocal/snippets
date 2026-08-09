import Darwin
import XCTest
@testable import Snippets

@MainActor
final class DeletionUndoTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletionUndoTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testScopedRestorePreservesInterveningMutationAndOriginalOrder() throws {
        let store = SnippetStore(configuration: .iOS)
        let deleted = store.addSnippet(name: "Delete me", content: "Original")
        let survivor = store.addSnippet(name: "Keep me", content: "Before")

        let token = try XCTUnwrap(store.deleteForUndo(snippetID: deleted.id))

        var editedSurvivor = try XCTUnwrap(store.snippet(id: survivor.id))
        editedSurvivor.content = "After"
        store.update(editedSurvivor)
        store.togglePinned(snippetID: survivor.id)

        XCTAssertTrue(store.restoreDeletedSnippet(using: token))
        XCTAssertEqual(store.snippets.map(\.id), [survivor.id, deleted.id])
        XCTAssertEqual(store.snippet(id: survivor.id)?.content, "After")
        XCTAssertEqual(store.snippet(id: survivor.id)?.isPinned, true)
        XCTAssertEqual(store.snippet(id: deleted.id)?.content, "Original")

        store.flushPendingWrites()
        let reloaded = SnippetStore(configuration: .iOS)
        XCTAssertEqual(reloaded.snippets.map(\.id), [survivor.id, deleted.id])
        XCTAssertEqual(reloaded.snippet(id: survivor.id)?.content, "After")
        XCTAssertEqual(reloaded.snippet(id: survivor.id)?.isPinned, true)
    }

    func testScopedRestoreIsOneShotAndCannotUndoAnotherAction() throws {
        let store = SnippetStore(configuration: .iOS)
        let deleted = store.addSnippet(name: "Delete me")
        let survivor = store.addSnippet(name: "Keep me")
        let token = try XCTUnwrap(store.deleteForUndo(snippetID: deleted.id))

        XCTAssertTrue(store.restoreDeletedSnippet(using: token))
        store.togglePinned(snippetID: survivor.id)

        XCTAssertFalse(store.restoreDeletedSnippet(using: token))
        XCTAssertEqual(store.snippet(id: survivor.id)?.isPinned, true)
        XCTAssertNotNil(store.snippet(id: deleted.id))
    }

    func testScopedRestoreDoesNotReplaceARecordRestoredByGlobalUndo() throws {
        let store = SnippetStore(configuration: .iOS)
        let snippet = store.addSnippet(name: "Current")
        let token = try XCTUnwrap(store.deleteForUndo(snippetID: snippet.id))

        XCTAssertTrue(store.undo())
        var globallyRestored = try XCTUnwrap(store.snippet(id: snippet.id))
        globallyRestored.name = "Newer"
        store.update(globallyRestored)

        XCTAssertFalse(store.restoreDeletedSnippet(using: token))
        XCTAssertEqual(store.snippet(id: snippet.id)?.name, "Newer")
    }
}
