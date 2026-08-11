import Darwin
import UIKit
import XCTest

@testable import Snippets

@MainActor
final class EditorInvalidationTests: XCTestCase {
    private var rootURL: URL!
    private var previousSyncPreference: Any?
    private var windows: [UIWindow] = []
    private var environments: [AppEnvironment] = []

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorInvalidationTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey
        )
        UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
        UIView.setAnimationsEnabled(false)
    }

    override func tearDownWithError() throws {
        environments.forEach { $0.store.flushPendingWrites() }
        windows.forEach {
            $0.endEditing(true)
            $0.isHidden = true
        }
        drainMainRunLoop(for: 0.02)
        windows.forEach { $0.rootViewController = nil }
        windows.removeAll()
        environments.removeAll()
        UIView.setAnimationsEnabled(true)
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let previousSyncPreference {
            UserDefaults.standard.set(previousSyncPreference, forKey: SyncCoordinator.enabledDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncCoordinator.enabledDefaultsKey)
        }
        previousSyncPreference = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testPhoneEditorMutationDefersHiddenLibraryUntilReturning() throws {
        let environment = makeEnvironment()
        let snippet = environment.store.addSnippet(name: "Before", content: "Body")
        let root = PhoneRootViewController(environment: environment)
        _ = host(root, size: CGSize(width: 390, height: 844))
        let library = try XCTUnwrap(
            root.viewControllers.first as? PhoneLibraryViewController
        )
        library.loadViewIfNeeded()
        let table = try XCTUnwrap(
            library.view.invalidationDescendant(identifier: "phone-snippet-list") as? UITableView
        )
        XCTAssertEqual(phoneRowName(in: library, table: table), "Before")

        root.phoneLibrary(library, requestedEdit: snippet.id)
        let editor = try XCTUnwrap(root.topViewController as? PhoneSnippetEditorViewController)
        editor.loadViewIfNeeded()
        drainMainRunLoop(for: 0.05)
        let nameField = try XCTUnwrap(
            editor.view.invalidationDescendant(identifier: "snippet-name") as? UITextField
        )

        nameField.text = "After"
        nameField.sendActions(for: .editingChanged)

        XCTAssertEqual(environment.store.snippet(id: snippet.id)?.name, "After")
        XCTAssertEqual(editor.title, "After", "Editor-derived UI must update in the publishing pass")
        XCTAssertEqual(
            phoneRowName(in: library, table: table),
            "Before",
            "A covered phone list must not rebuild synchronously for an editor keystroke"
        )

        root.setViewControllers([library], animated: false)
        drainMainRunLoop(for: 0.05)

        XCTAssertTrue(root.topViewController === library)
        XCTAssertEqual(
            phoneRowName(in: library, table: table),
            "After",
            "viewWillAppear must make the library current before it is shown again"
        )
    }

    func testIPadRapidEditorMutationsUseTrailingListReload() throws {
        let environment = makeEnvironment()
        let snippet = environment.store.addSnippet(name: "Before", content: "Body")
        let hosted = try hostSplit(environment: environment, selecting: snippet.id)
        let table = try XCTUnwrap(
            hosted.list.view.invalidationDescendant(identifier: "snippet-list") as? UITableView
        )
        let nameField = try XCTUnwrap(
            hosted.editor.view.invalidationDescendant(identifier: "snippet-name") as? UITextField
        )
        XCTAssertEqual(iPadRowName(in: hosted.list, table: table), "Before")

        nameField.text = "First"
        nameField.sendActions(for: .editingChanged)
        nameField.text = "Final"
        nameField.sendActions(for: .editingChanged)

        XCTAssertEqual(environment.store.snippet(id: snippet.id)?.name, "Final")
        XCTAssertEqual(hosted.editor.title, "Final")
        XCTAssertEqual(
            iPadRowName(in: hosted.list, table: table),
            "Before",
            "The visible list must not reload in either synchronous editor callback"
        )

        XCTAssertTrue(waitUntil {
            self.iPadRowName(in: hosted.list, table: table) == "Final"
        })
        XCTAssertEqual(hosted.list.selectedSnippetID, snippet.id)
    }

    func testNonEditorLocalChangeStillRefreshesIPadListSynchronously() throws {
        let environment = makeEnvironment()
        let snippet = environment.store.addSnippet(name: "Before", content: "Body")
        let hosted = try hostSplit(environment: environment, selecting: snippet.id)
        let table = try XCTUnwrap(
            hosted.list.view.invalidationDescendant(identifier: "snippet-list") as? UITableView
        )

        _ = environment.store.addSnippet(name: "List Action", content: "Body")

        XCTAssertEqual(
            hosted.list.tableView(table, numberOfRowsInSection: 0),
            2,
            "List-originated and other ordinary local changes must remain immediate"
        )
    }

    func testSecureEditorNotificationIsClassifiedAndContextUnwindsAfterThrow() {
        enum ProbeError: Error { case expected }

        let environment = makeEnvironment()
        var observed: [(source: SnippetStore.ChangeSource, editorContext: Bool)] = []
        environment.store.onChange = { source in
            observed.append((source, environment.isPerformingLocalEditorChange))
        }

        environment.performLocalEditorChange {
            environment.performLocalSecureChange {
                environment.secureStore.onChange?()
            }
        }
        environment.performLocalSecureChange {
            environment.secureStore.onChange?()
        }
        environment.secureStore.onChange?()

        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed.map(\.editorContext), [true, false, false])
        XCTAssertTrue(observed[0].source == .local)
        XCTAssertTrue(observed[1].source == .local)
        XCTAssertTrue(observed[2].source == .external)

        XCTAssertThrowsError(
            try environment.performLocalEditorChange {
                XCTAssertTrue(environment.isPerformingLocalEditorChange)
                throw ProbeError.expected
            }
        )
        XCTAssertFalse(
            environment.isPerformingLocalEditorChange,
            "A failed editor save must not classify subsequent secure or list changes as editor typing"
        )
    }

    func testSecureChangeOutsideEditorContextRefreshesPendingIPadListImmediately() throws {
        let environment = makeEnvironment()
        let snippet = environment.store.addSnippet(name: "Before", content: "Body")
        let hosted = try hostSplit(environment: environment, selecting: snippet.id)
        let table = try XCTUnwrap(
            hosted.list.view.invalidationDescendant(identifier: "snippet-list") as? UITableView
        )
        let nameField = try XCTUnwrap(
            hosted.editor.view.invalidationDescendant(identifier: "snippet-name") as? UITextField
        )

        nameField.text = "After"
        nameField.sendActions(for: .editingChanged)
        XCTAssertEqual(iPadRowName(in: hosted.list, table: table), "Before")

        environment.performLocalSecureChange {
            environment.secureStore.onChange?()
        }

        XCTAssertEqual(
            iPadRowName(in: hosted.list, table: table),
            "After",
            "A secure action outside the editor scope must cancel the delay and refresh immediately"
        )
    }

    func testExternalChangeRefreshesPhoneLibraryAndEditorImmediately() throws {
        let environment = makeEnvironment()
        let snippet = environment.store.addSnippet(name: "Local", content: "Body")
        environment.store.flushPendingWrites()
        let root = PhoneRootViewController(environment: environment)
        _ = host(root, size: CGSize(width: 390, height: 844))
        let library = try XCTUnwrap(
            root.viewControllers.first as? PhoneLibraryViewController
        )
        library.loadViewIfNeeded()
        let table = try XCTUnwrap(
            library.view.invalidationDescendant(identifier: "phone-snippet-list") as? UITableView
        )
        root.phoneLibrary(library, requestedEdit: snippet.id)
        let editor = try XCTUnwrap(root.topViewController as? PhoneSnippetEditorViewController)
        editor.loadViewIfNeeded()
        drainMainRunLoop(for: 0.05)

        var remote = snippet
        remote.name = "Remote"
        remote.keyword = "remote"
        remote.content = "Remote body"
        remote.updatedAt = snippet.updatedAt.addingTimeInterval(1)
        try SnippetLibraryCodec.encode([remote])
            .write(to: SnippetStorageLocations.snippetsFileURL)

        XCTAssertTrue(environment.store.reloadAfterExternalWrite())
        XCTAssertEqual(
            library.tableView(table, numberOfRowsInSection: 0),
            1,
            "External changes must bypass editor coalescing"
        )
        XCTAssertEqual(phoneRowName(in: library, table: table), "Remote")
        XCTAssertEqual(editor.title, "Remote")
    }

    private func phoneRowName(
        in library: PhoneLibraryViewController,
        table: UITableView
    ) -> String? {
        library.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0)).accessibilityLabel
    }

    private func makeEnvironment() -> AppEnvironment {
        let environment = AppEnvironment()
        environments.append(environment)
        return environment
    }

    private func iPadRowName(
        in list: SnippetListViewController,
        table: UITableView
    ) -> String? {
        list.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0)).accessibilityLabel
    }

    private func hostSplit(
        environment: AppEnvironment,
        selecting snippetID: UUID
    ) throws -> (
        root: MainSplitViewController,
        list: SnippetListViewController,
        editor: SnippetEditorViewController
    ) {
        let root = MainSplitViewController(environment: environment)
        _ = host(root, size: CGSize(width: 1180, height: 820))
        root.loadViewIfNeeded()
        root.view.layoutIfNeeded()
        let listNavigation = try XCTUnwrap(
            root.viewController(for: .primary) as? UINavigationController
        )
        let editorNavigation = try XCTUnwrap(
            root.viewController(for: .secondary) as? UINavigationController
        )
        let list = try XCTUnwrap(
            listNavigation.topViewController as? SnippetListViewController
        )
        let editor = try XCTUnwrap(
            editorNavigation.topViewController as? SnippetEditorViewController
        )
        list.loadViewIfNeeded()
        editor.loadViewIfNeeded()
        root.snippetList(list, selected: snippetID)
        root.view.layoutIfNeeded()
        return (root, list, editor)
    }

    @discardableResult
    private func host(_ controller: UIViewController, size: CGSize) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        windows.append(window)
        return window
    }

    private func drainMainRunLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private extension UIView {
    func invalidationDescendant(identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.invalidationDescendant(identifier: identifier) {
                return match
            }
        }
        return nil
    }
}
