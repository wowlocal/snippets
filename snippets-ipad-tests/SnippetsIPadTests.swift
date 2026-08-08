import Darwin
import UIKit
import XCTest
@testable import Snippets

@MainActor
final class SnippetsIPadTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetsIPadTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testFreshIPadLibraryStartsEmptyAndPersistsCRUD() throws {
        var store: SnippetStore? = SnippetStore(configuration: .iPad)
        XCTAssertTrue(store?.snippets.isEmpty == true)

        let created = store!.addSnippet(name: "Greeting", content: "Hello", tags: ["Work"])
        var updated = created
        updated.keyword = "hello"
        updated.content = "Hello from iPad"
        store!.update(updated)
        store!.flushPendingWrites()
        store = nil

        let reloaded = SnippetStore(configuration: .iPad)
        XCTAssertEqual(reloaded.snippets.count, 1)
        XCTAssertEqual(reloaded.snippets.first?.name, "Greeting")
        XCTAssertEqual(reloaded.snippets.first?.content, "Hello from iPad")
        XCTAssertEqual(reloaded.snippets.first?.normalizedKeyword, "hello")
    }

    func testExportStructurallyExcludesSecureShells() throws {
        let store = SnippetStore(configuration: .iPad)
        _ = store.addSnippet(name: "Ordinary", content: "visible")
        let secureID = UUID()
        let secureProvider = SecureProviderStub(
            shell: Snippet(id: secureID, name: "Encrypted", keyword: "secret", content: "")
        )
        store.secureProvider = secureProvider

        let exportURL = rootURL.appendingPathComponent("export.json")
        XCTAssertEqual(try store.exportSnippets(to: exportURL), 1)
        let export = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(export.contains("Ordinary"))
        XCTAssertFalse(export.contains("Encrypted"))
        XCTAssertFalse(export.contains(secureID.uuidString))
    }

    func testIPadConfigurationDoesNotSeedStarterContentAfterCorruptFileRecovery() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: rootURL.appendingPathComponent("snippets.json"))
        let store = SnippetStore(configuration: .iPad)
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
                .contains { $0.hasPrefix("snippets.json.corrupt-") }
        )
    }

    func testCopySnippetShortcutUsesCommandReturnWithTextInputPriority() {
        let command = MainSplitViewController.copySnippetKeyCommand()

        XCTAssertEqual(command.input, "\r")
        XCTAssertEqual(command.modifierFlags, .command)
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
    }

    func testCopySnippetShortcutRoutesPastFocusedTextInputAndCopiesSelection() {
        let previousPasteboardString = UIPasteboard.general.string
        addTeardownBlock { UIPasteboard.general.string = previousPasteboardString }

        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Greeting", content: "Hello from iPad")
        let rootController = MainSplitViewController(environment: environment)
        rootController.loadViewIfNeeded()
        let editorNavigationController = rootController.viewController(for: .secondary) as? UINavigationController
        let editorController = editorNavigationController?.topViewController as? SnippetEditorViewController
        editorController?.loadViewIfNeeded()
        editorController?.bind(to: snippet.id)

        let textField = UITextField()
        rootController.view.addSubview(textField)
        let command = MainSplitViewController.copySnippetKeyCommand()
        guard let action = command.action else {
            return XCTFail("Copy snippet command should have an action")
        }
        let target = textField.target(forAction: action, withSender: command)

        XCTAssertTrue(target as AnyObject? === rootController)
        XCTAssertTrue(
            UIApplication.shared.sendAction(action, to: target, from: command, for: nil)
        )
        XCTAssertEqual(UIPasteboard.general.string, "Hello from iPad")
    }
}

@MainActor
private final class SecureProviderStub: SecureSnippetProviding {
    let shell: Snippet

    init(shell: Snippet) { self.shell = shell }
    func secureShellsForDisplay() -> [Snippet] { [shell] }
    func isSecure(_ id: UUID) -> Bool { id == shell.id }
}
