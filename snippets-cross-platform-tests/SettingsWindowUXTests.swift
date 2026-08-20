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
            XCTAssertTrue(
                paneView.translatesAutoresizingMaskIntoConstraints,
                "\(title) must let NSTabViewController manage its root frame"
            )
            let paneContainer = try XCTUnwrap(paneView.superview)
            XCTAssertEqual(paneView.frame.minX, paneContainer.bounds.minX, accuracy: 1)
            XCTAssertEqual(paneView.frame.minY, paneContainer.bounds.minY, accuracy: 1)
            XCTAssertEqual(paneView.frame.width, paneContainer.bounds.width, accuracy: 1)
            XCTAssertEqual(paneView.frame.height, paneContainer.bounds.height, accuracy: 1)

            let stack = try XCTUnwrap(
                paneView.subviews.first(where: { $0 is NSStackView }) as? NSStackView,
                "\(title) should use the standard settings stack"
            )
            XCTAssertGreaterThan(stack.frame.height, 0)
            XCTAssertEqual(
                window.contentLayoutRect.height,
                max(220, ceil(stack.fittingSize.height + 48)),
                accuracy: 1,
                "\(title) should use its compact fitting height"
            )
            XCTAssertEqual(
                paneView.bounds.maxY - stack.frame.maxY,
                24,
                accuracy: 1,
                "\(title) should not inherit an extra toolbar safe-area inset"
            )
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

    func testRapidPaneNavigationKeepsSelectedPaneFillingItsContainer() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        defer { window.close() }

        controller.showSettings()
        settle()

        // Exercise a short/tall mix while the preceding window resize is still in flight.
        for index in [1, 4, 6, 0, 5, 4, 3] {
            tabs.selectedTabViewItemIndex = index
            settle(0.03)
        }
        settle()

        let paneView = try XCTUnwrap(
            tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view
        )
        let paneContainer = try XCTUnwrap(paneView.superview)
        XCTAssertTrue(paneView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(paneView.frame.minX, paneContainer.bounds.minX, accuracy: 1)
        XCTAssertEqual(paneView.frame.minY, paneContainer.bounds.minY, accuracy: 1)
        XCTAssertEqual(paneView.frame.width, paneContainer.bounds.width, accuracy: 1)
        XCTAssertEqual(paneView.frame.height, paneContainer.bounds.height, accuracy: 1)

        let stack = try XCTUnwrap(
            paneView.subviews.first(where: { $0 is NSStackView }) as? NSStackView
        )
        XCTAssertEqual(paneView.bounds.maxY - stack.frame.maxY, 24, accuracy: 1)
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
        let tableAction = try XCTUnwrap(table.action)
        XCTAssertTrue(NSApp.sendAction(tableAction, to: table.target, from: table))
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

    func testSearchKeepsFieldEditorFocusWhileUpdatingResults() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.showSettings()
        settle()

        let searchItem = try currentSearchItem(in: window)
        searchItem.beginSearchInteraction()
        settle(0.1)
        let field = searchItem.searchField
        XCTAssertTrue(window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === fieldEditor)

        updateSearch(field, text: "b")
        settle(0.1)
        XCTAssertTrue(window.firstResponder === fieldEditor)
        XCTAssertTrue(field.currentEditor() === fieldEditor)

        updateSearch(field, text: "ba")
        settle(0.1)
        XCTAssertTrue(window.firstResponder === fieldEditor)
        XCTAssertTrue(field.currentEditor() === fieldEditor)

        let resultsController = try XCTUnwrap(searchResultsController())
        let table = try XCTUnwrap(searchResultsTable(in: resultsController.view))
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertFalse(resultsController.view.window?.isKeyWindow ?? true)
    }

    func testSearchSupportsKeyboardSelectionAndEscape() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.showSettings()
        settle()

        let searchItem = try currentSearchItem(in: window)
        searchItem.beginSearchInteraction()
        settle(0.1)
        let field = searchItem.searchField
        XCTAssertTrue(window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        updateSearch(field, text: "backup")
        settle(0.1)
        let resultsController = try XCTUnwrap(searchResultsController())
        let table = try XCTUnwrap(searchResultsTable(in: resultsController.view))
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 0)

        let moved = field.delegate?.control?(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.moveDown(_:))
        )
        XCTAssertEqual(moved, true)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertTrue(window.firstResponder === fieldEditor)

        let cancelled = field.delegate?.control?(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertEqual(cancelled, true)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertFalse(resultsController.view.window?.isVisible ?? false)

        updateSearch(field, text: "export logs")
        settle(0.1)
        let reopenedResultsController = try XCTUnwrap(searchResultsController())
        let reopenedTable = try XCTUnwrap(searchResultsTable(in: reopenedResultsController.view))
        XCTAssertEqual(reopenedTable.numberOfRows, 1)

        let activated = field.delegate?.control?(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertEqual(activated, true)
        settle()
        XCTAssertEqual(window.title, "Diagnostics")
        XCTAssertEqual(field.stringValue, "")
        XCTAssertFalse(reopenedResultsController.view.window?.isVisible ?? false)
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
