import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class SettingsWindowUXTests: XCTestCase {
    private let expectedPanes = [
        "General",
        "Expansion",
        "Sync",
        "Secure",
        "Backup",
        "Integrations",
        "Diagnostics",
    ]

    func testEveryPaneFitsAndWindowRemainsCompact() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        defer { window.close() }

        controller.showSettings()
        settle()

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize.width, 620, accuracy: 1)
        XCTAssertEqual(tabs.tabViewItems.count, expectedPanes.count)
        XCTAssertFalse(window.contentViewController is NSSplitViewController)

        let paneIdentifiers = tabs.tabViewItems.compactMap { $0.identifier as? String }
        XCTAssertEqual(
            paneIdentifiers,
            ["general", "expansion", "sync", "secure", "backup", "integrations", "diagnostics"]
        )

        for (index, title) in expectedPanes.enumerated() {
            tabs.selectedTabViewItemIndex = index
            settle()

            XCTAssertEqual(window.title, title)
            XCTAssertLessThan(window.frame.height, 760, "\(title) should not create a sprawling window")
            XCTAssertGreaterThan(window.contentLayoutRect.height, 200)

            let paneView = try XCTUnwrap(tabs.tabViewItems[index].viewController?.view)
            paneView.layoutSubtreeIfNeeded()
            XCTAssertFalse(paneView is NSScrollView, "The pane root must not trigger a toolbar scroll pocket")

            let stack = try XCTUnwrap(
                paneView.subviews.first(where: { $0 is NSStackView }) as? NSStackView,
                "\(title) should use the standard settings stack"
            )
            XCTAssertGreaterThan(stack.frame.height, 0)
            XCTAssertGreaterThanOrEqual(stack.frame.minY, paneView.bounds.minY - 1)
            XCTAssertLessThanOrEqual(stack.frame.maxY, paneView.bounds.maxY + 1)

            for arrangedView in stack.arrangedSubviews where !arrangedView.isHidden {
                XCTAssertGreaterThanOrEqual(
                    arrangedView.frame.minY,
                    stack.bounds.minY - 1,
                    "\(title) contains a control clipped below its stack"
                )
                XCTAssertLessThanOrEqual(
                    arrangedView.frame.maxY,
                    stack.bounds.maxY + 1,
                    "\(title) contains a control clipped above its stack"
                )
            }
        }
    }

    func testManualWidthSurvivesPaneNavigation() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        defer { window.close() }

        controller.showSettings()
        settle()
        window.setContentSize(NSSize(width: 780, height: 560))

        tabs.selectedTabViewItemIndex = 1
        settle()
        XCTAssertEqual(window.frame.width, 780, accuracy: 1)

        tabs.selectedTabViewItemIndex = 4
        settle()
        XCTAssertEqual(window.frame.width, 780, accuracy: 1)
        XCTAssertEqual(window.title, "Backup")
    }

    func testSearchFindsResultsWithoutSidebarAndNavigates() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.showSettings()
        settle()

        let initialSearchItem = try currentSearchItem(in: window)
        initialSearchItem.beginSearchInteraction()
        settle(0.1)
        let field = initialSearchItem.searchField

        updateSearch(field, text: "backup")
        settle(0.1)

        let resultsController = try XCTUnwrap(searchResultsController())
        let table = try XCTUnwrap(searchResultsTable(in: resultsController.view))
        XCTAssertEqual(table.numberOfRows, 2)

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        settle()
        XCTAssertEqual(window.title, "Backup")
        XCTAssertEqual(field.stringValue, "")
        XCTAssertFalse(resultsController.view.window?.isVisible ?? false)

        let repeatedSearchItem = try currentSearchItem(in: window)
        repeatedSearchItem.beginSearchInteraction()
        settle(0.1)
        let repeatedField = repeatedSearchItem.searchField
        updateSearch(repeatedField, text: "definitely-not-a-setting")
        settle(0.1)

        let repeatedResultsController = try XCTUnwrap(searchResultsController())
        let repeatedTable = try XCTUnwrap(searchResultsTable(in: repeatedResultsController.view))
        XCTAssertEqual(repeatedTable.numberOfRows, 0)

        updateSearch(repeatedField, text: "")
        settle(0.1)
        XCTAssertFalse(repeatedResultsController.view.window?.isVisible ?? false)
    }

    func testSearchShowsEmptyStateAndClosesForEmptyQuery() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.showSettings()
        settle()

        let searchItem = try currentSearchItem(in: window)
        searchItem.beginSearchInteraction()
        settle(0.1)
        let field = searchItem.searchField
        updateSearch(field, text: "definitely-not-a-setting")
        settle(0.1)
        let emptyResultsController = try XCTUnwrap(searchResultsController())
        let emptyTable = try XCTUnwrap(searchResultsTable(in: emptyResultsController.view))
        XCTAssertEqual(emptyTable.numberOfRows, 0)
        let emptyLabel = emptyResultsController.view.subviews
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.stringValue == "No Results" })
        XCTAssertEqual(emptyLabel?.isHidden, false)

        updateSearch(field, text: "")
        settle(0.1)
        XCTAssertFalse(emptyResultsController.view.window?.isVisible ?? false)
    }

    func testBackupUsesPlainSectionsInsteadOfOutlinedCards() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        defer { window.close() }

        controller.showSettings()
        tabs.selectedTabViewItemIndex = 4
        settle()

        let backupView = try XCTUnwrap(tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view)
        let boxes = descendants(of: backupView).compactMap { $0 as? NSBox }
        XCTAssertFalse(boxes.isEmpty)
        XCTAssertTrue(boxes.allSatisfy { $0.boxType == NSBox.BoxType.separator })
    }

    private func updateSearch(_ field: NSSearchField, text: String) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
    }

    private func currentSearchItem(in window: NSWindow) throws -> NSSearchToolbarItem {
        let toolbar = try XCTUnwrap(window.toolbar)
        return try XCTUnwrap(toolbar.items.first {
            $0.itemIdentifier.rawValue == "SnippetsSettingsSearch"
        } as? NSSearchToolbarItem)
    }

    private func searchResultsController() -> NSViewController? {
        NSApp.windows
            .compactMap(\.contentViewController)
            .first {
                String(describing: type(of: $0)).contains("SettingsSearchResultsViewController")
                    && ($0.view.window?.isVisible ?? false)
            }
    }

    private func searchResultsTable(in root: NSView) -> NSTableView? {
        descendants(of: root).compactMap { $0 as? NSTableView }.first
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { descendants(of: $0) }
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
