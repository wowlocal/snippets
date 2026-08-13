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

    func testAccessibilityXXXLOnboardingReflowsIntoScrollableConnectAction() throws {
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
        let connect = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-connect-icloud") as? UIButton
        )
        let table = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-snippet-list") as? UITableView
        )
        let scrollView = try XCTUnwrap(connect.firstAncestor(ofType: UIScrollView.self))
        scrollView.layoutIfNeeded()

        let titleFrame = title.convert(title.bounds, to: scrollView)
        let connectFrame = connect.convert(connect.bounds, to: scrollView)
        XCTAssertGreaterThan(connectFrame.minY, titleFrame.maxY)
        XCTAssertGreaterThan(title.bounds.width, 180, "The title must not collapse to one letter per line")
        XCTAssertGreaterThan(connect.bounds.width, 140, "The connect action must remain readable")
        XCTAssertLessThan(connect.bounds.width, 300, "The connect action should remain compact")
        XCTAssertEqual(connect.titleLabel?.numberOfLines, 0)
        XCTAssertGreaterThanOrEqual(scrollView.contentSize.height, scrollView.bounds.height)
        XCTAssertFalse(table.isScrollEnabled, "An empty library must not collapse its large title")
    }

    func testOnboardingUsesCompactCenteredConnectActionWithoutDuplicateCreationAction() throws {
        let environment = AppEnvironment()
        let library = PhoneLibraryViewController(environment: environment)
        let navigation = UINavigationController(rootViewController: library)
        _ = host(navigation, size: CGSize(width: 390, height: 844))
        library.reload()
        library.view.layoutIfNeeded()

        let title = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-empty-title") as? UILabel
        )
        let connect = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-connect-icloud") as? UIButton
        )
        let scrollView = try XCTUnwrap(connect.firstAncestor(ofType: UIScrollView.self))
        scrollView.layoutIfNeeded()

        let titleFrame = title.convert(title.bounds, to: scrollView)
        let connectFrame = connect.convert(connect.bounds, to: scrollView)
        let groupCenterY = (titleFrame.minY + connectFrame.maxY) / 2
        XCTAssertEqual(groupCenterY, scrollView.bounds.midY - 20, accuracy: 50)
        XCTAssertLessThan(connectFrame.maxY - titleFrame.minY, 220)
        XCTAssertLessThan(connectFrame.width, 300)
        XCTAssertNil(
            library.view.descendant(withAccessibilityIdentifier: "phone-empty-create")
        )
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
        let navigation = UINavigationController(rootViewController: library)
        _ = host(navigation)
        library.reload()
        library.view.layoutIfNeeded()

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

    func testLibraryUsesInsetMailStyleRowsAndCustomSwipeActions() throws {
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        let environment = AppEnvironment()
        _ = environment.store.addSnippet(
            name: "Mail-style row",
            content: "The preview remains readable beneath floating controls.",
            tags: ["Work"]
        )
        for index in 0..<12 {
            _ = environment.store.addSnippet(
                name: "Additional row \(index)",
                content: "Enough content to exercise scrolling behavior.",
                tags: ["Work"]
            )
        }
        let root = PhoneRootViewController(environment: environment)
        _ = host(root)
        let library = try XCTUnwrap(root.viewControllers.first as? PhoneLibraryViewController)
        library.reload()
        library.view.layoutIfNeeded()

        let table = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-snippet-list") as? UITableView
        )
        let banner = try XCTUnwrap(
            library.view.descendant(withAccessibilityIdentifier: "phone-sync-status")
        )
        let syncHeader = try XCTUnwrap(table.tableHeaderView)
        let moreButton = try XCTUnwrap(
            root.view.descendant(withAccessibilityIdentifier: "phone-library-more") as? UIButton
        )
        let moreFrameAtScrollEdge = moreButton.convert(moreButton.bounds, to: root.navigationBar)

        XCTAssertEqual(library.title, "Snippets")
        XCTAssertTrue(moreButton.superview === root.navigationBar)
        XCTAssertNil(library.navigationItem.rightBarButtonItem)
        XCTAssertGreaterThan(root.navigationBar.bounds.height, 80)
        XCTAssertEqual(
            root.navigationBar.bounds.maxY - moreFrameAtScrollEdge.maxY,
            4,
            accuracy: 1,
            "The expanded More control must follow the large-title row at the bar's lower edge"
        )
        XCTAssertEqual(table.style, .grouped)
        XCTAssertTrue(table.isScrollEnabled)
        XCTAssertEqual(table.frame.minY, library.view.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(table.frame.maxY, library.view.bounds.maxY, accuracy: 0.5)
        XCTAssertTrue(banner.isDescendant(of: syncHeader))
        XCTAssertGreaterThan(syncHeader.bounds.height, banner.bounds.height)
        XCTAssertEqual(banner.bounds.height, 34, accuracy: 0.5)
        XCTAssertEqual(syncHeader.bounds.height, 46, accuracy: 0.5)
        XCTAssertEqual(banner.frame.minX, 20, accuracy: 0.5)
        XCTAssertEqual(table.contentInset.top, 0, accuracy: 0.5)
        XCTAssertTrue(banner is UIVisualEffectView)
        XCTAssertGreaterThan(banner.layer.cornerRadius, 0)
        XCTAssertTrue(library.navigationItem.hidesSearchBarWhenScrolling)
        XCTAssertTrue(root.toolbar.isTranslucent)

        XCTAssertNil(library.tableView(table, viewForHeaderInSection: 0))
        XCTAssertEqual(
            library.tableView(table, heightForHeaderInSection: 0),
            .leastNormalMagnitude
        )

        let bannerY = banner.convert(banner.bounds, to: library.view).minY
        table.setContentOffset(
            CGPoint(x: 0, y: table.contentOffset.y + 96),
            animated: false
        )
        library.view.layoutIfNeeded()
        XCTAssertLessThan(banner.convert(banner.bounds, to: library.view).minY, bannerY)

        let cell = library.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        cell.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: 110)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let rowContent = try XCTUnwrap(
            cell.descendant(withAccessibilityIdentifier: "phone-snippet-row-content")
        )
        let rowHighlight = try XCTUnwrap(
            cell.descendant(withAccessibilityIdentifier: "phone-snippet-highlight")
        )
        let pill = try XCTUnwrap(
            cell.descendant(withAccessibilityIdentifier: "phone-tag-pill")
        )
        XCTAssertLessThan(pill.bounds.width, cell.bounds.width / 2)
        XCTAssertEqual(rowContent.frame.minX, 18, accuracy: 0.5)
        XCTAssertEqual(cell.bounds.width - rowContent.frame.maxX, 18, accuracy: 0.5)
        XCTAssertEqual(
            rowHighlight.frame.minX,
            PhoneSnippetCell.highlightHorizontalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            cell.bounds.width - rowHighlight.frame.maxX,
            PhoneSnippetCell.highlightHorizontalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            rowContent.frame.minX - rowHighlight.frame.minX,
            12,
            accuracy: 0.5,
            "The full-row highlight should leave comfortable padding before the text"
        )
        XCTAssertEqual(
            rowHighlight.frame.minY,
            PhoneSnippetCell.highlightVerticalInset,
            accuracy: 0.5
        )
        XCTAssertGreaterThanOrEqual(rowContent.frame.minY - rowHighlight.frame.minY, 8)
        XCTAssertEqual(rowHighlight.alpha, 0, accuracy: 0.01)
        cell.setHighlighted(true, animated: false)
        XCTAssertEqual(rowHighlight.alpha, 1, accuracy: 0.01)
        cell.setHighlighted(false, animated: false)
        XCTAssertEqual(rowHighlight.alpha, 0, accuracy: 0.01)
        XCTAssertEqual(cell.backgroundColor?.cgColor.alpha ?? 1, 0, accuracy: 0.01)

        // UITableView owns these margins and can mutate them while grouped cells are
        // reused. The row's visual geometry must remain independent from that state.
        cell.directionalLayoutMargins = .zero
        cell.contentView.directionalLayoutMargins = .zero
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        XCTAssertEqual(rowContent.frame.minX, 18, accuracy: 0.5)
        XCTAssertEqual(cell.bounds.width - rowContent.frame.maxX, 18, accuracy: 0.5)

        let assertVisibleRowsUseFixedGrid = {
            var checkedRows = 0
            for visibleCell in table.visibleCells {
                guard let visibleContent = visibleCell.descendant(
                    withAccessibilityIdentifier: "phone-snippet-row-content"
                ) else { continue }
                visibleCell.layoutIfNeeded()
                let contentFrame = visibleContent.convert(visibleContent.bounds, to: visibleCell.contentView)
                XCTAssertEqual(contentFrame.minX, 18, accuracy: 0.5)
                XCTAssertEqual(
                    visibleCell.contentView.bounds.width - contentFrame.maxX,
                    18,
                    accuracy: 0.5
                )
                checkedRows += 1
            }
            XCTAssertGreaterThan(checkedRows, 0)
        }

        // Exercise actual dequeue/reuse in both directions, not just a newly created
        // cell. This reproduces the path that previously mixed 20 pt and 68 pt rows.
        let bottomOffset = max(
            -table.adjustedContentInset.top,
            table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom
        )
        table.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
        table.layoutIfNeeded()
        drainMainRunLoop()
        assertVisibleRowsUseFixedGrid()

        table.setContentOffset(
            CGPoint(x: 0, y: -table.adjustedContentInset.top),
            animated: false
        )
        table.layoutIfNeeded()
        drainMainRunLoop()
        assertVisibleRowsUseFixedGrid()

        let swipeCell = try XCTUnwrap(cell as? PhoneSnippetCell)
        let swipeSurface = try XCTUnwrap(
            cell.descendant(withAccessibilityIdentifier: "phone-snippet-swipe-surface")
        )
        let editAction = try XCTUnwrap(
            cell.descendant(withAccessibilityIdentifier: "phone-swipe-edit") as? UIButton
        )
        let pinAction = try XCTUnwrap(
            cell.descendant(withAccessibilityIdentifier: "phone-swipe-pin") as? UIButton
        )
        let deleteAction = try XCTUnwrap(
            cell.descendant(withAccessibilityIdentifier: "phone-swipe-delete") as? UIButton
        )
        XCTAssertTrue(swipeSurface.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer } == true)
        XCTAssertNotNil(editAction.configuration)
        XCTAssertNotNil(pinAction.configuration)
        XCTAssertNotNil(deleteAction.configuration)
        XCTAssertEqual(editAction.bounds.width, PhoneSnippetCell.actionWidth, accuracy: 0.5)
        XCTAssertEqual(pinAction.bounds.width, PhoneSnippetCell.actionWidth, accuracy: 0.5)
        XCTAssertEqual(deleteAction.bounds.width, PhoneSnippetCell.actionWidth, accuracy: 0.5)

        swipeCell.openSwipeActions(on: .leading, animated: false)
        XCTAssertEqual(swipeCell.swipeSide, .leading)
        XCTAssertEqual(swipeCell.swipeOffset, PhoneSnippetCell.leadingActionWidth, accuracy: 0.5)
        XCTAssertEqual(swipeSurface.transform.tx, PhoneSnippetCell.leadingActionWidth, accuracy: 0.5)

        swipeCell.openSwipeActions(on: .trailing, animated: false)
        XCTAssertEqual(swipeCell.swipeSide, .trailing)
        XCTAssertEqual(swipeCell.swipeOffset, -PhoneSnippetCell.trailingActionWidth, accuracy: 0.5)
        XCTAssertEqual(swipeSurface.transform.tx, -PhoneSnippetCell.trailingActionWidth, accuracy: 0.5)

        let actionDelegate = PhoneSnippetCellSwipeDelegateSpy()
        swipeCell.swipeDelegate = actionDelegate
        pinAction.sendActions(for: .touchUpInside)
        XCTAssertEqual(actionDelegate.actions, [.pin])
        XCTAssertNil(swipeCell.swipeSide)
        XCTAssertEqual(swipeCell.swipeOffset, 0, accuracy: 0.5)

        swipeCell.openSwipeActions(on: .leading, animated: false)
        editAction.sendActions(for: .touchUpInside)
        swipeCell.openSwipeActions(on: .trailing, animated: false)
        deleteAction.sendActions(for: .touchUpInside)
        XCTAssertEqual(actionDelegate.actions, [.pin, .edit, .delete])
    }

    func testCustomSwipePhysicsUsesResistanceVelocityAndSemanticDirection() throws {
        let leadingWidth = PhoneSnippetCell.leadingActionWidth
        let trailingWidth = PhoneSnippetCell.trailingActionWidth
        let containerWidth: CGFloat = 390
        let fullSwipeThreshold = PhoneSwipePhysics.leadingFullSwipeThreshold(
            leadingWidth: leadingWidth,
            containerWidth: containerWidth
        )
        XCTAssertEqual(
            PhoneSwipePhysics.displayedOffset(
                for: 40,
                leadingLimit: leadingWidth,
                trailingLimit: trailingWidth,
                containerWidth: containerWidth,
                leadingExpansionLimit: fullSwipeThreshold
            ),
            40,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PhoneSwipePhysics.displayedOffset(
                for: 150,
                leadingLimit: leadingWidth,
                trailingLimit: trailingWidth,
                containerWidth: containerWidth,
                leadingExpansionLimit: fullSwipeThreshold
            ),
            150,
            accuracy: 0.001,
            "A full-swipe action should track the finger directly until it arms"
        )
        let resisted = PhoneSwipePhysics.displayedOffset(
            for: 300,
            leadingLimit: leadingWidth,
            trailingLimit: trailingWidth,
            containerWidth: containerWidth,
            leadingExpansionLimit: fullSwipeThreshold
        )
        XCTAssertGreaterThan(resisted, fullSwipeThreshold)
        XCTAssertLessThan(resisted, 300)
        XCTAssertEqual(
            PhoneSwipePhysics.resolution(
                rawOffset: leadingWidth * 0.54,
                velocity: 0,
                leadingWidth: leadingWidth,
                trailingWidth: trailingWidth,
                containerWidth: containerWidth
            ),
            .open(.leading)
        )
        XCTAssertEqual(
            PhoneSwipePhysics.resolution(
                rawOffset: -trailingWidth * 0.54,
                velocity: 0,
                leadingWidth: leadingWidth,
                trailingWidth: trailingWidth,
                containerWidth: containerWidth
            ),
            .open(.trailing)
        )
        XCTAssertEqual(
            PhoneSwipePhysics.resolution(
                rawOffset: fullSwipeThreshold + 1,
                velocity: 0,
                leadingWidth: leadingWidth,
                trailingWidth: trailingWidth,
                containerWidth: containerWidth
            ),
            .triggerLeadingAction
        )

        let rtlCell = PhoneSnippetCell(style: .default, reuseIdentifier: "rtl")
        rtlCell.semanticContentAttribute = .forceRightToLeft
        rtlCell.frame = CGRect(x: 0, y: 0, width: 390, height: 110)
        rtlCell.layoutIfNeeded()
        let rtlSurface = try XCTUnwrap(
            rtlCell.descendant(withAccessibilityIdentifier: "phone-snippet-swipe-surface")
        )
        rtlCell.openSwipeActions(on: .leading, animated: false)
        XCTAssertEqual(rtlCell.swipeOffset, PhoneSnippetCell.leadingActionWidth, accuracy: 0.5)
        XCTAssertEqual(rtlSurface.transform.tx, -PhoneSnippetCell.leadingActionWidth, accuracy: 0.5)

        rtlCell.prepareForReuse()
        XCTAssertNil(rtlCell.swipeSide)
        XCTAssertEqual(rtlSurface.transform, .identity)
    }

    func testLeadingFullSwipeRequestsEditWithoutWaitingForCommitAnimation() {
        let cell = PhoneSnippetCell(style: .default, reuseIdentifier: "full-swipe")
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 110)
        cell.layoutIfNeeded()
        let delegate = PhoneSnippetCellSwipeDelegateSpy()
        cell.swipeDelegate = delegate

        UIView.setAnimationsEnabled(true)
        defer {
            cell.closeSwipe(animated: false)
            UIView.setAnimationsEnabled(false)
        }

        cell.commitLeadingFullSwipe(with: 900)

        XCTAssertEqual(
            delegate.actions,
            [.edit],
            "Edit should be requested synchronously when the finger lifts"
        )
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

    func testRecoverableSafetyHaltBannerOffersResumeButRemoteResetDoesNot() {
        let banner = PhoneSyncStatusBanner()
        var resumeRequests = 0
        banner.onRequestResume = { resumeRequests += 1 }

        banner.configure(
            state: .halted(.accountChanged, detail: "Account review is required."),
            status: "Stopped because the iCloud account changed.",
            isFirstFetch: false
        )

        XCTAssertTrue(banner.isUserInteractionEnabled)
        XCTAssertTrue(banner.accessibilityTraits.contains(.button))
        XCTAssertTrue(banner.accessibilityActivate())
        XCTAssertEqual(resumeRequests, 1)

        banner.configure(
            state: .halted(.remoteDataReset, detail: "The remote library was reset."),
            status: "Stopped because the remote library was reset.",
            isFirstFetch: false
        )

        XCTAssertFalse(banner.isUserInteractionEnabled)
        XCTAssertFalse(banner.accessibilityTraits.contains(.button))
        XCTAssertFalse(banner.accessibilityActivate())
        XCTAssertEqual(resumeRequests, 1)
    }

    func testResumeConfirmationExplainsTheSafetyStopBeforeOfferingResume() {
        let alert = SyncResumeConfirmation.makeAlert(
            statusDescription: "Stopped because the iCloud account changed."
        ) {}

        XCTAssertEqual(alert.title, "Resume iCloud Sync?")
        XCTAssertTrue(alert.message?.contains("iCloud account changed") == true)
        XCTAssertTrue(alert.message?.contains("clear the safety stop") == true)
        XCTAssertEqual(alert.actions.map(\.title), ["Cancel", "Resume"])
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .default])
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

@MainActor
private final class PhoneSnippetCellSwipeDelegateSpy: PhoneSnippetCellSwipeDelegate {
    private(set) var willBeginCount = 0
    private(set) var didCloseCount = 0
    private(set) var actions: [PhoneSnippetSwipeAction] = []

    func phoneSnippetCellWillBeginSwipe(_ cell: PhoneSnippetCell) {
        willBeginCount += 1
    }

    func phoneSnippetCellDidCloseSwipe(_ cell: PhoneSnippetCell) {
        didCloseCount += 1
    }

    func phoneSnippetCell(
        _ cell: PhoneSnippetCell,
        requested action: PhoneSnippetSwipeAction
    ) {
        actions.append(action)
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
