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

    func testSidebarKeepsProgrammaticSelectionVisibleAcrossReload() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Visible selection")
        let controller = SnippetListViewController(environment: environment)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }

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
