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

    func testAppWideKeyboardCommandsUseMacShortcutsAndWinTextInputPriority() {
        let commands: [(UIKeyCommand, String, UIKeyModifierFlags)] = [
            (MainSplitViewController.searchKeyCommand(), "f", .command),
            (MainSplitViewController.toggleSidebarKeyCommand(), "b", .command),
            (MainSplitViewController.editSnippetKeyCommand(), "e", .command),
            (MainSplitViewController.nextFieldKeyCommand(), "\t", []),
            (MainSplitViewController.previousFieldKeyCommand(), "\t", .shift),
            (MainSplitViewController.shortcutsKeyCommand(), "k", .command),
            (MainSplitViewController.nextSnippetKeyCommand(), "n", .control),
            (MainSplitViewController.previousSnippetKeyCommand(), "p", .control),
        ]

        for (command, input, modifiers) in commands {
            XCTAssertEqual(command.input, input)
            XCTAssertEqual(command.modifierFlags, modifiers)
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        }
    }

    func testSearchShortcutRevealsHiddenSidebarAndFocusesSearch() {
        UIView.setAnimationsEnabled(false)
        addTeardownBlock { UIView.setAnimationsEnabled(true) }
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Search me")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)

        hosted.controller.hide(.primary)
        hosted.controller.view.layoutIfNeeded()
        XCTAssertFalse(hosted.controller.isSidebarVisible)

        hosted.controller.searchCommand()
        hosted.controller.view.layoutIfNeeded()

        XCTAssertTrue(hosted.controller.isSidebarVisible)
        XCTAssertTrue(waitUntil { hosted.list.isSearchFocused })
    }

    func testEditAndTabShortcutsFollowMacEditorFocusOrder() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Edit me")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView
        let keyword = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-keyword"
        ) as? UITextField
        let name = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-name"
        ) as? UITextField
        let tags = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "tags-input"
        ) as? UITextField

        hosted.controller.editSnippetCommand()
        XCTAssertTrue(body?.isFirstResponder == true)
        for command in [
            MainSplitViewController.searchKeyCommand(),
            MainSplitViewController.toggleSidebarKeyCommand(),
            MainSplitViewController.editSnippetKeyCommand(),
            MainSplitViewController.nextFieldKeyCommand(),
            MainSplitViewController.nextSnippetKeyCommand(),
            MainSplitViewController.shortcutsKeyCommand(),
        ] {
            guard let action = command.action else {
                return XCTFail("\(command.title) should have an action")
            }
            let target = body?.target(forAction: action, withSender: command)
            XCTAssertTrue(
                target as AnyObject? === hosted.controller,
                "\(command.title) should route from the editor to the split controller"
            )
        }

        hosted.controller.nextFieldCommand()
        XCTAssertTrue(keyword?.isFirstResponder == true)
        hosted.controller.nextFieldCommand()
        XCTAssertTrue(name?.isFirstResponder == true)
        hosted.controller.nextFieldCommand()
        XCTAssertTrue(tags?.isFirstResponder == true)
        hosted.controller.nextFieldCommand()
        XCTAssertTrue(body?.isFirstResponder == true)

        hosted.controller.previousFieldCommand()
        XCTAssertTrue(hosted.controller.isSidebarVisible)
        XCTAssertTrue(hosted.list.ownsFirstResponder)
    }

    func testCommandBTogglesSidebarAndMovesSidebarFocusIntoEditor() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Edit me")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)
        hosted.list.focusSearch()

        hosted.controller.toggleSidebarCommand()
        hosted.controller.view.layoutIfNeeded()
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView
        XCTAssertFalse(hosted.controller.isSidebarVisible)
        XCTAssertTrue(body?.isFirstResponder == true)

        hosted.controller.toggleSidebarCommand()
        hosted.controller.view.layoutIfNeeded()
        XCTAssertTrue(hosted.controller.isSidebarVisible)
    }

    func testCommandKTogglesMacStyleShortcutPanelAndOptionHint() {
        let environment = AppEnvironment()
        let hosted = hostMainSplit(environment: environment)
        UIView.setAnimationsEnabled(false)
        addTeardownBlock { UIView.setAnimationsEnabled(true) }

        hosted.controller.shortcutsCommand()
        let panel = hosted.controller.view.descendant(
            withAccessibilityIdentifier: "shortcut-panel"
        ) as? ShortcutPanelView
        let tip = panel?.descendant(
            withAccessibilityIdentifier: "shortcut-panel-tip"
        ) as? UILabel
        XCTAssertTrue(panel?.isPresented == true)
        XCTAssertEqual(tip?.text, "Hold ⌥ for all shortcuts.")

        panel?.setShowsAllShortcuts(true, animated: false)
        XCTAssertTrue(panel?.showsAllShortcuts == true)
        XCTAssertEqual(tip?.text, "Release ⌥ for essentials.")

        hosted.controller.shortcutsCommand()
        XCTAssertFalse(panel?.isPresented == true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertTrue(panel?.isHidden == true)
    }

    func testControlNAndControlPNavigateSnippetListWithoutMovingEditorFocus() {
        let environment = AppEnvironment()
        _ = environment.store.addSnippet(name: "First", content: "One")
        _ = environment.store.addSnippet(name: "Second", content: "Two")
        let hosted = hostMainSplit(environment: environment)
        let firstID = hosted.list.firstVisibleSnippetID!
        hosted.controller.snippetList(hosted.list, selected: firstID)
        hosted.controller.editSnippetCommand()
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView

        hosted.controller.nextSnippetCommand()
        let nextID = hosted.list.selectedSnippetID
        XCTAssertNotEqual(nextID, firstID)
        XCTAssertTrue(body?.isFirstResponder == true)

        hosted.controller.previousSnippetCommand()
        XCTAssertEqual(hosted.list.selectedSnippetID, firstID)
        XCTAssertTrue(body?.isFirstResponder == true)
    }

    func testSidebarKeepsProgrammaticSelectionVisibleAcrossReload() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Visible selection")
        let controller = SnippetListViewController(environment: environment)
        let previousKeyWindow = currentKeyWindow()
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        controller.loadViewIfNeeded()
        controller.select(id: snippet.id)
        controller.reload(keepingSelection: true)
        controller.view.layoutIfNeeded()

        let tableView = controller.view.descendant(
            withAccessibilityIdentifier: "snippet-list"
        ) as? UITableView
        XCTAssertEqual(tableView?.indexPathForSelectedRow, IndexPath(row: 0, section: 0))
        XCTAssertTrue(tableView?.cellForRow(at: IndexPath(row: 0, section: 0))?.isSelected == true)
        XCTAssertTrue(
            tableView?.cellForRow(at: IndexPath(row: 0, section: 0))?
                .accessibilityTraits.contains(.selected) == true
        )
        XCTAssertNil(
            controller.view.descendant(withAccessibilityIdentifier: "delete-snippet"),
            "Deletion is available from the row context menu and swipe action"
        )
    }

    func testSidebarTagFiltersWrapAndExpandWithoutHorizontalScrolling() {
        let filter = SidebarTagFilterView()
        let tags = [
            "Engineering", "Personal", "Meetings", "Support", "Email",
            "Planning", "Design", "Finance", "Documentation", "Research",
        ]
        let items = tags.enumerated().map {
            SidebarTagFilterView.Item(tag: $0.element, count: $0.offset + 1)
        }
        filter.update(
            items: items,
            activeKeys: []
        )

        let width: CGFloat = 300
        let collapsedHeight = filter.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        filter.frame = CGRect(x: 0, y: 0, width: width, height: collapsedHeight)
        filter.layoutIfNeeded()

        XCTAssertGreaterThan(collapsedHeight, 38, "Several tags should wrap instead of scrolling sideways")
        XCTAssertFalse(filter.containsDescendant(ofType: UIScrollView.self))

        var toggledTag: String?
        filter.onToggleTag = { toggledTag = $0 }
        let engineering = filter.descendant(
            withAccessibilityIdentifier: "tag-filter-engineering"
        ) as? UIButton
        engineering?.sendActions(for: .touchUpInside)
        XCTAssertEqual(toggledTag, "Engineering")

        filter.update(items: items, activeKeys: ["engineering"])
        filter.frame.size.height = filter.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        filter.layoutIfNeeded()
        XCTAssertEqual(
            filter.descendant(withAccessibilityIdentifier: "tag-filter-engineering")?
                .accessibilityValue,
            "Selected"
        )

        var didClear = false
        filter.onClearFilters = { didClear = true }
        let clear = filter.descendant(
            withAccessibilityIdentifier: "clear-tag-filters"
        ) as? UIButton
        clear?.sendActions(for: .touchUpInside)
        XCTAssertTrue(didClear)

        let disclosure = filter.descendant(
            withAccessibilityIdentifier: "tag-filters-disclosure"
        ) as? UIButton
        XCTAssertNotNil(disclosure)
        XCTAssertFalse(disclosure?.isHidden == true)
        disclosure?.sendActions(for: .touchUpInside)

        let expandedHeight = filter.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        XCTAssertGreaterThan(expandedHeight, collapsedHeight)
    }

    func testScrollFadeTracksOnlyEdgesWithHiddenContent() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let container = ScrollFadeContainerView(containing: scrollView)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()
        scrollView.contentSize = CGSize(width: 300, height: 600)

        scrollView.contentOffset = .zero
        container.updateFade()
        XCTAssertEqual(container.topFadeIntensity, 0, accuracy: 0.001)
        XCTAssertEqual(container.bottomFadeIntensity, 1, accuracy: 0.001)

        scrollView.contentOffset.y = 200
        container.updateFade()
        XCTAssertEqual(container.topFadeIntensity, 1, accuracy: 0.001)
        XCTAssertEqual(container.bottomFadeIntensity, 1, accuracy: 0.001)

        scrollView.contentOffset.y = 400
        container.updateFade()
        XCTAssertEqual(container.topFadeIntensity, 1, accuracy: 0.001)
        XCTAssertEqual(container.bottomFadeIntensity, 0, accuracy: 0.001)
    }

    private func hostMainSplit(
        environment: AppEnvironment,
        selecting snippetID: UUID? = nil
    ) -> (
        controller: MainSplitViewController,
        list: SnippetListViewController,
        editor: SnippetEditorViewController
    ) {
        let controller = MainSplitViewController(environment: environment)
        let previousKeyWindow = currentKeyWindow()
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        let listNavigation = controller.viewController(for: .primary) as! UINavigationController
        let editorNavigation = controller.viewController(for: .secondary) as! UINavigationController
        let list = listNavigation.topViewController as! SnippetListViewController
        let editor = editorNavigation.topViewController as! SnippetEditorViewController
        list.loadViewIfNeeded()
        editor.loadViewIfNeeded()
        if let snippetID {
            controller.snippetList(list, selected: snippetID)
        }
        controller.view.layoutIfNeeded()
        // Let the normal appearance callback establish the root responder before
        // a test invokes a shortcut that intentionally moves focus elsewhere.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        return (controller, list, editor)
    }

    private func currentKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private func testWindow(frame: CGRect) -> UIWindow {
        let scene = currentKeyWindow()?.windowScene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }
}

@MainActor
private final class SecureProviderStub: SecureSnippetProviding {
    let shell: Snippet

    init(shell: Snippet) { self.shell = shell }
    func secureShellsForDisplay() -> [Snippet] { [shell] }
    func isSecure(_ id: UUID) -> Bool { id == shell.id }
}

@MainActor
private extension UIView {
    func descendant(withAccessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.descendant(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }

    func containsDescendant<T: UIView>(ofType type: T.Type) -> Bool {
        if self is T { return true }
        return subviews.contains { $0.containsDescendant(ofType: type) }
    }
}
