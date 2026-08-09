import UIKit
import XCTest
@testable import Snippets

@MainActor
final class PhoneLibraryUXTests: XCTestCase {
    private var rootURL: URL!
    private var previousSyncPreference: Any?
    private var windows: [UIWindow] = []

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneLibraryUXTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey
        )
        UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
        UIView.setAnimationsEnabled(false)
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        UIView.setAnimationsEnabled(true)
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let previousSyncPreference {
            UserDefaults.standard.set(
                previousSyncPreference,
                forKey: SyncCoordinator.enabledDefaultsKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: SyncCoordinator.enabledDefaultsKey)
        }
        previousSyncPreference = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testAccessibilityXXXLOnboardingReflowsIntoScrollableReadableActions() throws {
        let environment = AppEnvironment()
        let library = PhoneLibraryViewController(environment: environment)
        let navigation = UINavigationController(rootViewController: library)
        _ = host(
            navigation,
            size: CGSize(width: 320, height: 480),
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        library.reload()
        library.view.layoutIfNeeded()

        let title = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-empty-title") as? UILabel
        )
        let create = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-empty-create") as? UIButton
        )
        let scrollView = try XCTUnwrap(create.firstAncestor(ofType: UIScrollView.self))
        scrollView.layoutIfNeeded()

        let titleFrame = title.convert(title.bounds, to: scrollView)
        let createFrame = create.convert(create.bounds, to: scrollView)
        XCTAssertGreaterThan(createFrame.minY, titleFrame.maxY)
        XCTAssertGreaterThan(title.bounds.width, 180, "The title must not collapse to one letter per line")
        XCTAssertGreaterThan(create.bounds.width, 180, "Actions should use the available phone width")
        XCTAssertEqual(create.titleLabel?.numberOfLines, 0)
        XCTAssertGreaterThanOrEqual(scrollView.contentSize.height, scrollView.bounds.height)
    }

    func testRowAccessibilityDescribesStatePinAndTagsAndOffersActions() throws {
        let environment = AppEnvironment()
        var snippet = environment.store.addSnippet(
            name: "Deploy Token",
            content: "ordinary body",
            tags: ["Work", "Release"]
        )
        snippet.keyword = "deploy"
        snippet.isPinned = true
        snippet.isEnabled = false
        environment.store.update(snippet)

        let library = PhoneLibraryViewController(environment: environment)
        library.loadViewIfNeeded()
        library.reload()
        let table = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-snippet-list") as? UITableView
        )
        let cell = library.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))

        XCTAssertEqual(cell.accessibilityLabel, "Deploy Token")
        let value = try XCTUnwrap(cell.accessibilityValue)
        XCTAssertTrue(value.contains("Standard"))
        XCTAssertTrue(value.contains("Pinned"))
        XCTAssertTrue(value.contains("Disabled"))
        XCTAssertTrue(value.contains("Tags: Work, Release"))
        XCTAssertEqual(
            cell.accessibilityCustomActions?.map(\.name),
            ["Copy", "Edit", "Unpin", "Delete"]
        )
        XCTAssertEqual(cell.contentView.alpha, 1, "Disabled state must not rely on opacity")
    }

    func testActiveFilterCountIsVisibleAndEmptyFilterResultCanBeCleared() throws {
        let environment = AppEnvironment()
        _ = environment.store.addSnippet(name: "One", content: "1", tags: ["Personal"])
        _ = environment.store.addSnippet(name: "Two", content: "2", tags: ["Work"])
        let library = PhoneLibraryViewController(environment: environment)
        let navigation = UINavigationController(rootViewController: library)
        _ = host(navigation)
        library.reload()

        let filter = try XCTUnwrap(
            navigation.view.descendant(withAccessibilityIdentifier: "phone-tag-filter") as? UIButton
        )
        filter.sendActions(for: .touchUpInside)
        drainMainRunLoop()

        let sheet = try XCTUnwrap(library.presentedViewController as? UINavigationController)
        let filters = try XCTUnwrap(sheet.topViewController as? UITableViewController)
        XCTAssertEqual(filters.tableView(filters.tableView, numberOfRowsInSection: 0), 2)
        filters.tableView(filters.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        filters.tableView(filters.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        drainMainRunLoop()

        XCTAssertEqual(filter.configuration?.title, "2")
        XCTAssertEqual(filter.accessibilityValue, "2 active filters")
        let clear = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-clear-filters") as? UIButton
        )
        XCTAssertFalse(clear.isHidden)
        clear.sendActions(for: .touchUpInside)

        XCTAssertNil(filter.configuration?.title)
        XCTAssertEqual(filter.accessibilityValue, "No active filters")
    }

    func testFirstFetchHasPersistentStatusAndIsNotPresentedAsEmptyLibrary() throws {
        let environment = AppEnvironment()
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        let library = PhoneLibraryViewController(environment: environment)
        library.loadViewIfNeeded()
        library.reload()

        let banner = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-sync-status")
        )
        XCTAssertFalse(banner.isHidden)
        XCTAssertEqual(banner.accessibilityLabel, "iCloud Sync")
        let title = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-empty-title") as? UILabel
        )
        XCTAssertEqual(title.text, "Library Hasn’t Been Fetched")
        XCTAssertNotEqual(title.text, "Your Library Is Empty")
    }

    func testStatusActionCanOnlyRunOnce() throws {
        let environment = AppEnvironment()
        let library = PhoneLibraryViewController(environment: environment)
        library.loadViewIfNeeded()
        var invocationCount = 0
        library.showStatus("Deleted snippet.", actionTitle: "Undo") {
            invocationCount += 1
        }

        let action = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-toast-action") as? UIButton
        )
        XCTAssertFalse(action.isHidden)
        action.sendActions(for: .touchUpInside)
        action.sendActions(for: .touchUpInside)

        XCTAssertEqual(invocationCount, 1)
        XCTAssertFalse(action.isEnabled)
    }

    func testPullToRefreshDoesNotEnableSyncWithoutConfirmation() throws {
        let environment = AppEnvironment()
        let root = PhoneRootViewController(environment: environment)
        _ = host(root)
        let library = try XCTUnwrap(root.viewControllers.first as? PhoneLibraryViewController)
        library.loadViewIfNeeded()
        let table = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-snippet-list") as? UITableView
        )

        table.refreshControl?.beginRefreshing()
        table.refreshControl?.sendActions(for: .valueChanged)
        drainMainRunLoop()

        XCTAssertFalse(SyncCoordinator.isEnabled)
        let alert = try XCTUnwrap(library.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "Turn On iCloud Sync?")
        XCTAssertFalse(table.refreshControl?.isRefreshing == true)
    }

    @discardableResult
    private func host(
        _ controller: UIViewController,
        size: CGSize = CGSize(width: 390, height: 844),
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> UIWindow {
        let host = UIViewController()
        host.view.backgroundColor = .systemBackground
        host.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: host.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        controller.didMove(toParent: host)
        controller.traitOverrides.horizontalSizeClass = .compact
        controller.traitOverrides.verticalSizeClass = size.width > size.height ? .compact : .regular
        controller.traitOverrides.preferredContentSizeCategory = contentSizeCategory

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        windows.append(window)
        return window
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

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

    func firstAncestor<T: UIView>(ofType type: T.Type) -> T? {
        var candidate = superview
        while let view = candidate {
            if let match = view as? T { return match }
            candidate = view.superview
        }
        return nil
    }
}
