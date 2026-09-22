import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class ClipboardHistoryPanelTests: XCTestCase {
    func testCommandKDefersExplicitPasteUntilMenuClosesWithCopyPreference() async throws {
        let entry = ClipboardHistoryEntry(text: "Menu paste")
        let fixture = await makeFixture(entries: [entry])
        fixture.service.primaryAction = .copy
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        var events: [String] = []
        let controller = ClipboardHistoryPanelController(service: fixture.service, presentActionsMenu: { menu, _ in
            events.append("menu opened")
            XCTAssertTrue(menu.item(withTitle: "Paste")?.isEnabled == true)
            XCTAssertEqual(menu.item(withTitle: "Paste")?.keyEquivalent, "")
            XCTAssertEqual(menu.items.first?.title, "Copy")
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Paste"))
            XCTAssertEqual(events, ["menu opened"], "Menu tracking must release focus before paste starts")
            events.append("menu closed")
        })
        defer { controller.dismiss() }
        controller.show(canPaste: true, onPaste: {
            XCTAssertFalse(controller.isVisible)
            XCTAssertEqual($0, entry)
            events.append("paste")
        }, onCopy: { _ in XCTFail("The explicit Paste menu action overrides the Copy preference") },
        onCreateSnippet: { _ in XCTFail("Unexpected create") }, onDismiss: { _ in events.append("dismiss") })
        try sendKey(code: 40, characters: "k", modifiers: .command, to: pickerWindow(excluding: initialWindows))
        XCTAssertEqual(events, ["menu opened", "menu closed", "dismiss", "paste"])
    }

    func testMenuCancellationPreservesSearchAndMenuCommandReturnCopiesOnceAfterTracking() async throws {
        let entry = ClipboardHistoryEntry(text: "Searchable entry")
        let fixture = await makeFixture(entries: [entry])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        var invocation = 0
        var copyCount = 0
        weak var observedController: ClipboardHistoryPanelController?
        let controller = ClipboardHistoryPanelController(service: fixture.service, presentActionsMenu: { menu, anchor in
            invocation += 1
            if let window = anchor.window {
                observedController?.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
            }
            XCTAssertFalse(observedController?.control(NSSearchField(), textView: NSTextView(),
                doCommandBy: #selector(NSResponder.cancelOperation(_:))) ?? true,
                "The menu owns Escape while tracking")
            if invocation == 2 {
                guard let window = anchor.window,
                      let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
                else { return XCTFail("Expected a menu keyboard event") }
                XCTAssertTrue(menu.performKeyEquivalent(with: key))
            }
            XCTAssertEqual(copyCount, 0, "Callbacks must wait until the menu returns")
        })
        observedController = controller
        defer { controller.dismiss() }
        controller.show(canPaste: true, onPaste: { _ in XCTFail("Unexpected paste") }, onCopy: {
            XCTAssertEqual($0, entry)
            XCTAssertFalse(controller.isVisible)
            copyCount += 1
        }, onCreateSnippet: { _ in XCTFail("Unexpected create") }, onDismiss: { _ in })
        let window = try pickerWindow(excluding: initialWindows)
        let search = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "Searchable"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try sendKey(code: 40, characters: "k", modifiers: .command, to: window)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(search.stringValue, "Searchable")
        XCTAssertEqual(copyCount, 0)
        try sendKey(code: 40, characters: "k", modifiers: .command, to: window)
        XCTAssertEqual(copyCount, 1)
    }

    func testDisablingHistoryDuringMenuTrackingInvalidatesPendingAction() async throws {
        let fixture = await makeFixture(entries: [ClipboardHistoryEntry(text: "Entry")])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        var chosen = false
        var dismissCount = 0
        let controller = ClipboardHistoryPanelController(service: fixture.service, presentActionsMenu: { menu, _ in
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Copy"))
            fixture.service.setEnabled(false)
        })
        defer { controller.dismiss() }
        controller.show(canPaste: true, onPaste: { _ in chosen = true }, onCopy: { _ in chosen = true },
            onCreateSnippet: { _ in chosen = true }, onDismiss: { _ in dismissCount += 1 })
        try sendKey(code: 40, characters: "k", modifiers: .command, to: pickerWindow(excluding: initialWindows))
        XCTAssertFalse(chosen)
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(dismissCount, 1)
    }

    func testPrimaryPreferenceControlsReturnAndNumbersWhileCommandReturnAlwaysCopies() async throws {
        let entry = ClipboardHistoryEntry(text: "  exact\n{clipboard}\n")
        let fixture = await makeFixture(entries: [entry])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var copied: [ClipboardHistoryEntry] = []
        func show() {
            controller.show(canPaste: true, onPaste: { _ in XCTFail("These commands should copy") },
                onCopy: {
                    XCTAssertFalse(controller.isVisible)
                    copied.append($0)
                }, onCreateSnippet: { _ in XCTFail("Unexpected create") }, onDismiss: { _ in })
        }
        show()
        let window = try pickerWindow(excluding: initialWindows)
        fixture.service.primaryAction = .copy
        let buttons = descendants(of: try XCTUnwrap(window.contentView)).compactMap { $0 as? NSButton }
        XCTAssertTrue(buttons.contains { $0.title == "Copy ↩" })
        try sendKey(code: 36, characters: "\r", to: window)
        show()
        try sendKey(code: 18, characters: "1", modifiers: .command, to: window)
        show()
        try sendKey(code: 36, characters: "\r", modifiers: .command, to: window)
        fixture.service.primaryAction = .paste
        show()
        try sendKey(code: 36, characters: "\r", modifiers: .command, to: window)
        XCTAssertEqual(copied, Array(repeating: entry, count: 4))
    }

    func testActionsMenuUsesCapturedEntryAfterHistoryAndSelectionChange() async throws {
        let now = Date()
        let entry = ClipboardHistoryEntry(text: "Original entry", copiedAt: now)
        let other = ClipboardHistoryEntry(text: "Other entry", copiedAt: now.addingTimeInterval(-1))
        let fixture = await makeFixture(entries: [entry, other], now: now)
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var copied: ClipboardHistoryEntry?
        controller.show(canPaste: true, onPaste: { _ in XCTFail("Unexpected paste") },
            onCopy: {
                XCTAssertFalse(controller.isVisible)
                copied = $0
            }, onCreateSnippet: { _ in XCTFail("Unexpected create") }, onDismiss: { _ in })
        let menu = controller.makeActionsMenu()
        let paste = try XCTUnwrap(menu.item(withTitle: "Paste"))
        let copy = try XCTUnwrap(menu.item(withTitle: "Copy"))
        XCTAssertTrue(paste.isEnabled)
        XCTAssertEqual(paste.keyEquivalent, "\r")
        XCTAssertEqual(paste.keyEquivalentModifierMask, [])
        XCTAssertEqual(copy.keyEquivalent, "\r")
        XCTAssertEqual(copy.keyEquivalentModifierMask, .command)
        XCTAssertNotNil(menu.item(withTitle: "Create Snippet"))
        XCTAssertNotNil(menu.item(withTitle: "Delete"))

        fixture.clipboard.text = "Newly captured entry"
        fixture.clipboard.changeCount += 1
        fixture.service.capturePendingCopy()
        let window = try pickerWindow(excluding: initialWindows)
        let table = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        menu.performActionForItem(at: menu.index(of: copy))
        XCTAssertEqual(copied, entry)
    }

    func testActionsMenuRejectsRemovedEntryAndOldPresentationAndDisablesUnavailablePaste() async throws {
        let now = Date()
        let entry = ClipboardHistoryEntry(text: "Entry", copiedAt: now)
        let remaining = ClipboardHistoryEntry(text: "Remaining", copiedAt: now.addingTimeInterval(-1))
        let fixture = await makeFixture(entries: [entry, remaining], now: now)
        defer { fixture.cleanup() }
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var chosen = false
        func show() {
            controller.show(canPaste: false, onPaste: { _ in chosen = true }, onCopy: { _ in chosen = true },
                onCreateSnippet: { _ in chosen = true }, onDismiss: { _ in })
        }
        show()
        let menu = controller.makeActionsMenu()
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Paste")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Copy")).isEnabled)
        fixture.service.delete(id: entry.id)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Copy"))
        XCTAssertFalse(chosen)
        XCTAssertTrue(controller.isVisible)

        let previousSessionMenu = controller.makeActionsMenu()
        show()
        previousSessionMenu.performActionForItem(at: previousSessionMenu.indexOfItem(withTitle: "Copy"))
        XCTAssertFalse(chosen)
        XCTAssertTrue(controller.isVisible)
        let currentMenu = controller.makeActionsMenu()
        currentMenu.performActionForItem(at: currentMenu.indexOfItem(withTitle: "Copy"))
        XCTAssertTrue(chosen)
        XCTAssertFalse(controller.isVisible)
    }

    func testCommandNineUsesFilteredRankAndPastesLiteralEntryAfterDismissal() async throws {
        let now = Date()
        let matches = (0..<10).map { index in
            ClipboardHistoryEntry(text: "needle \(index)\n  {date}\t{clipboard}\n",
                copiedAt: now.addingTimeInterval(-Double(index + 1)))
        }
        let unrelated = ClipboardHistoryEntry(text: "Most recent unrelated entry", copiedAt: now)
        let fixture = await makeFixture(entries: [unrelated] + matches, now: now)
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var events: [String] = []
        var pasted: ClipboardHistoryEntry?
        controller.show(canPaste: true, onPaste: {
            XCTAssertFalse(controller.isVisible)
            pasted = $0
            events.append("paste")
        }, onCopy: { _ in XCTFail("Number shortcut should paste when a destination exists") },
        onCreateSnippet: { _ in XCTFail("Number shortcut should not create a snippet") }, onDismiss: {
            XCTAssertFalse($0)
            events.append("dismiss")
        })
        let window = try pickerWindow(excluding: initialWindows)
        let views = descendants(of: try XCTUnwrap(window.contentView))
        let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        search.stringValue = "needle"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(table.numberOfRows, 10)

        let ninthCell = try XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns.first, row: 8))
        let ninthHint = try XCTUnwrap(descendants(of: ninthCell).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "clipboardHistoryQuickSelectionShortcut"
        })
        XCTAssertEqual(ninthHint.stringValue, "⌘9")
        XCTAssertFalse(ninthHint.isHidden)
        let tenthCell = try XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns.first, row: 9))
        let tenthHint = try XCTUnwrap(descendants(of: tenthCell).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "clipboardHistoryQuickSelectionShortcut"
        })
        XCTAssertTrue(tenthHint.isHidden)
        XCTAssertEqual(tenthHint.stringValue, "")

        try sendKey(code: 25, characters: "9", modifiers: .command, to: window)
        XCTAssertEqual(pasted, matches[8])
        XCTAssertEqual(events, ["dismiss", "paste"])
        XCTAssertFalse(controller.isVisible)
    }

    func testNumberShortcutCopiesWithoutTargetAndAcceptsNumericPad() async throws {
        let now = Date()
        let first = ClipboardHistoryEntry(text: "First entry", copiedAt: now)
        let second = ClipboardHistoryEntry(text: "  Literal second entry\n{clipboard}\n", copiedAt: now.addingTimeInterval(-1))
        let fixture = await makeFixture(entries: [first, second], now: now)
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var events: [String] = []
        var copied: ClipboardHistoryEntry?
        controller.show(canPaste: false, onPaste: { _ in XCTFail("No paste target was captured") }, onCopy: {
            XCTAssertFalse(controller.isVisible)
            copied = $0
            events.append("copy")
        }, onCreateSnippet: { _ in XCTFail("Unexpected create") }, onDismiss: { _ in events.append("dismiss") })
        let window = try pickerWindow(excluding: initialWindows)
        try sendKey(code: 84, characters: "2", modifiers: [.command, .numericPad, .capsLock], to: window)
        XCTAssertEqual(copied, second)
        XCTAssertEqual(events, ["dismiss", "copy"])
    }

    func testMissingRowsRepeatsAndAdditionalModifiersDoNotActivateNumberShortcut() async throws {
        let fixture = await makeFixture(entries: [ClipboardHistoryEntry(text: "One entry")])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var chosen = false
        controller.show(canPaste: true, onPaste: { _ in chosen = true }, onCopy: { _ in chosen = true },
            onCreateSnippet: { _ in chosen = true }, onDismiss: { _ in })
        let window = try pickerWindow(excluding: initialWindows)
        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(
            code: 25, characters: "9", modifiers: .command, window: window)))
        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(
            code: 18, characters: "1", modifiers: .command, isARepeat: true, window: window)))
        let extraModifiers: [NSEvent.ModifierFlags] = [.shift, .option, .control]
        for extra in extraModifiers {
            XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(
                code: 18, characters: "1", modifiers: [.command, extra], window: window)))
        }
        XCTAssertFalse(chosen)
        XCTAssertTrue(controller.isVisible)
    }

    func testNumberShortcutLeavesMarkedSearchTextToInputMethod() async throws {
        let fixture = await makeFixture(entries: [ClipboardHistoryEntry(text: "needle")])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var chosen = false
        controller.show(canPaste: true, onPaste: { _ in chosen = true }, onCopy: { _ in chosen = true },
            onCreateSnippet: { _ in chosen = true }, onDismiss: { _ in })
        let window = try pickerWindow(excluding: initialWindows)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setMarkedText("needle", selectedRange: NSRange(location: 6, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(
            code: 18, characters: "1", modifiers: .command, window: window)))
        XCTAssertFalse(chosen)
        XCTAssertTrue(controller.isVisible)
        editor.unmarkText()
    }

    func testLiveAppearanceChangePreservesPreviewWithoutBackgroundCard() async throws {
        let entry = ClipboardHistoryEntry(text: "  A clipboard preview\n\twith exact whitespace.\n")
        let fixture = await makeFixture(entries: [entry])
        defer { fixture.cleanup() }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        NSApp.appearance = NSAppearance(named: .aqua)
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        controller.show(canPaste: true, onPaste: { _ in XCTFail("Unexpected paste") },
            onCopy: { _ in XCTFail("Unexpected copy") }, onCreateSnippet: { _ in XCTFail("Unexpected create") },
            onDismiss: { _ in })
        let window = try pickerWindow(excluding: initialWindows)
        let views = descendants(of: try XCTUnwrap(window.contentView))
        let surface = try XCTUnwrap(views.first { $0.identifier?.rawValue == "clipboardHistoryPreviewSurface" })
        let preview = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { !$0.isEditable })
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        XCTAssertNil(window.appearance)
        XCTAssertNil(surface.appearance)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(surface.layer?.backgroundColor)
        preview.setSelectedRange(NSRange(location: 2, length: 9))
        let selectedRow = table.selectedRow

        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(surface.layer?.backgroundColor)
        XCTAssertEqual(surface.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(preview.string, entry.text)
        XCTAssertEqual(preview.selectedRange(), NSRange(location: 2, length: 9))
        XCTAssertEqual(table.selectedRow, selectedRow)
        XCTAssertTrue(controller.isVisible)

        NSApp.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(surface.layer?.backgroundColor)
    }

    func testReturnPastesLiteralTextAfterDismissal() async throws {
        let entry = ClipboardHistoryEntry(text: "  {date}\n\t{clipboard}\n")
        let fixture = await makeFixture(entries: [entry])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var events: [String] = []
        var pasted: ClipboardHistoryEntry?
        controller.show(canPaste: true, onPaste: {
            XCTAssertFalse(controller.isVisible)
            pasted = $0
            events.append("paste")
        }, onCopy: { _ in XCTFail("Return should paste when a destination is available") },
        onCreateSnippet: { _ in XCTFail("Return should not create a snippet") }, onDismiss: {
            XCTAssertFalse($0)
            events.append("dismiss")
        })
        let window = try pickerWindow(excluding: initialWindows)
        XCTAssertFalse(window.canBecomeMain)
        try sendKey(code: 36, characters: "\r", to: window)
        XCTAssertEqual(events, ["dismiss", "paste"])
        XCTAssertEqual(pasted, entry)
        XCTAssertFalse(controller.isVisible)
        controller.dismiss(returnFocus: true)
        XCTAssertEqual(events, ["dismiss", "paste"], "Ending a session twice must not duplicate callbacks")
    }

    func testCommandReturnCopiesAndCommandNCreatesAfterDismissal() async throws {
        let entry = ClipboardHistoryEntry(text: "Selected clipboard text")
        let fixture = await makeFixture(entries: [entry])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var events: [String] = []
        func show() {
            controller.show(canPaste: true, onPaste: { _ in XCTFail("Command action must not paste") },
                onCopy: {
                    XCTAssertEqual($0, entry)
                    XCTAssertFalse(controller.isVisible)
                    events.append("copy")
                }, onCreateSnippet: {
                    XCTAssertEqual($0, entry)
                    XCTAssertFalse(controller.isVisible)
                    events.append("create")
                }, onDismiss: { _ in events.append("dismiss") })
        }
        show()
        let window = try pickerWindow(excluding: initialWindows)
        try sendKey(code: 36, characters: "\r", modifiers: .command, to: window)
        XCTAssertEqual(events, ["dismiss", "copy"])
        show()
        try sendKey(code: 45, characters: "n", modifiers: .command, to: window)
        XCTAssertEqual(events, ["dismiss", "copy", "dismiss", "create"])
    }

    func testReturnCopiesWhenThereIsNoPasteTarget() async throws {
        let entry = ClipboardHistoryEntry(text: "A copy-only selection")
        let fixture = await makeFixture(entries: [entry])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var copied: ClipboardHistoryEntry?
        controller.show(canPaste: false, onPaste: { _ in XCTFail("No destination was captured") },
            onCopy: { copied = $0 }, onCreateSnippet: { _ in XCTFail("Unexpected create") }, onDismiss: { _ in })
        try sendKey(code: 36, characters: "\r", to: pickerWindow(excluding: initialWindows))
        XCTAssertEqual(copied, entry)
        XCTAssertFalse(controller.isVisible)
    }

    func testNewCopiesKeepSelectionAndPreviewWhitespaceThenDeletionUpdatesSearch() async throws {
        let now = Date()
        let newer = ClipboardHistoryEntry(text: "First entry", copiedAt: now.addingTimeInterval(-1))
        let selected = ClipboardHistoryEntry(text: "  alpha\n\t{date}  \n", copiedAt: now.addingTimeInterval(-2))
        let fixture = await makeFixture(entries: [newer, selected], now: now)
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        controller.show(canPaste: true, onPaste: { _ in XCTFail("Unexpected paste") },
            onCopy: { _ in XCTFail("Unexpected copy") }, onCreateSnippet: { _ in XCTFail("Unexpected create") },
            onDismiss: { _ in })
        let window = try pickerWindow(excluding: initialWindows)
        let views = descendants(of: try XCTUnwrap(window.contentView))
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
        let preview = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { !$0.isEditable })
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(table.enclosingScrollView).frame.height, window.frame.height * 0.4)
        XCTAssertGreaterThan(try XCTUnwrap(preview.enclosingScrollView).frame.width, window.frame.width * 0.4)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(preview.string, selected.text)

        fixture.clipboard.text = "Newly copied text"
        fixture.clipboard.changeCount += 1
        fixture.service.capturePendingCopy()
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertEqual(preview.string, selected.text)

        search.stringValue = "  alpha  "
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(preview.string, selected.text)
        XCTAssertTrue(controller.isVisible, "Spaces in a query must not choose a result")
        try sendKey(code: 51, characters: "\u{7f}", modifiers: .command, to: window)
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertEqual(preview.string, "")
        XCTAssertFalse(fixture.service.entries.contains { $0.id == selected.id })
        XCTAssertTrue(controller.isVisible, "Deleting a result should keep the picker open")
        await fixture.service.waitForPendingPersistence()
    }

    func testDisabledHistoryDismissesOnceAndEscapeRequestsFocusRestoration() async throws {
        let fixture = await makeFixture(entries: [ClipboardHistoryEntry(text: "Entry")])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var returnFocusValues: [Bool] = []
        func show() {
            controller.show(canPaste: true, onPaste: { _ in XCTFail("Unexpected paste") },
                onCopy: { _ in XCTFail("Unexpected copy") }, onCreateSnippet: { _ in XCTFail("Unexpected create") },
                onDismiss: { returnFocusValues.append($0) })
        }
        show()
        let window = try pickerWindow(excluding: initialWindows)
        try sendKey(code: 53, characters: "\u{1b}", to: window)
        XCTAssertEqual(returnFocusValues, [true])
        show()
        fixture.service.setEnabled(false)
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(returnFocusValues, [true, false])
        controller.dismiss()
        XCTAssertEqual(returnFocusValues, [true, false])
    }

    func testEmptyHistoryDoesNotChooseAnythingAndNativeEditingCommandsAreNotConsumed() async throws {
        let fixture = await makeFixture(entries: [])
        defer { fixture.cleanup() }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ClipboardHistoryPanelController(service: fixture.service)
        defer { controller.dismiss() }
        var chosen = false
        controller.show(canPaste: true, onPaste: { _ in chosen = true }, onCopy: { _ in chosen = true },
            onCreateSnippet: { _ in chosen = true }, onDismiss: { _ in })
        let window = try pickerWindow(excluding: initialWindows)
        try sendKey(code: 36, characters: "\r", to: window)
        try sendKey(code: 36, characters: "\r", modifiers: .command, to: window)
        XCTAssertFalse(chosen)
        XCTAssertTrue(controller.isVisible)
        for selector in [#selector(NSResponder.deleteBackward(_:)),
                         #selector(NSResponder.moveWordLeft(_:)),
                         #selector(NSResponder.insertTab(_:))] {
            XCTAssertFalse(controller.control(NSSearchField(), textView: NSTextView(), doCommandBy: selector))
        }
    }

    private func pickerWindow(excluding initialWindows: Set<Int>) throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { !initialWindows.contains($0.windowNumber) && $0.isVisible })
    }

    private func sendKey(
        code: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        to window: NSWindow
    ) throws {
        let event = try keyEvent(code: code, characters: characters, modifiers: modifiers, window: window)
        // Deliver to this panel only: never inject keystrokes into the user's app.
        window.sendEvent(event)
    }

    private func keyEvent(
        code: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        isARepeat: Bool = false,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isARepeat, keyCode: code))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeFixture(entries: [ClipboardHistoryEntry], now: Date = Date()) async -> Fixture {
        let suite = "ClipboardHistoryPanelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: ClipboardHistoryService.enabledPreferenceKey)
        let clipboard = PanelTestPasteboard()
        let service = ClipboardHistoryService(defaults: defaults,
            storage: PanelTestStorage(entries: entries), pasteboardProvider: { clipboard },
            frontmostBundleID: { nil }, now: { now }, schedulesTimer: false)
        await service.waitForPendingPersistence()
        return Fixture(service: service, clipboard: clipboard, defaults: defaults, suite: suite)
    }

    private struct Fixture {
        let service: ClipboardHistoryService
        let clipboard: PanelTestPasteboard
        let defaults: UserDefaults
        let suite: String

        func cleanup() {
            service.setEnabled(false)
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private final class PanelTestPasteboard: ClipboardHistoryPasteboardReading {
    var changeCount = 0
    var typeNames = ["public.utf8-plain-text"]
    var text: String?
    func readText() -> String? { text }
}

nonisolated private struct PanelTestStorage: ClipboardHistoryPersisting {
    let entries: [ClipboardHistoryEntry]
    var directoryExists: Bool { true }
    func prepareDirectory() throws {}
    func load() throws -> [ClipboardHistoryEntry] { entries }
    func save(_ entries: [ClipboardHistoryEntry]) throws {}
    func clear() throws {}
}
#endif
