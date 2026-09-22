import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class SuggestionPanelKeyboardTests: XCTestCase {
    func testExplicitFieldSelectionConsumesClickAndDoesNotBecomeKey() throws {
        let controller = SecurePasteFieldSelectionController()
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let frame = NSRect(x: 200, y: 200, width: 360, height: 260)
        var selectedPoints: [CGPoint] = []
        controller.show(frame: frame, targetPID: ProcessInfo.processInfo.processIdentifier,
                        onSelection: { selectedPoints.append($0) })
        defer { controller.cancel() }
        let overlay = try XCTUnwrap(NSApp.windows.first {
            !initialWindows.contains($0.windowNumber) && $0.isVisible
        })
        XCTAssertFalse(overlay.canBecomeKey)
        XCTAssertFalse(overlay.canBecomeMain)
        let content = try XCTUnwrap(overlay.contentView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 100, y: 80), modifierFlags: [], timestamp: 0,
            windowNumber: overlay.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        content.mouseDown(with: event)
        XCTAssertEqual(selectedPoints.count, 1)
        XCTAssertFalse(controller.isVisible)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        XCTAssertEqual(selectedPoints.first, CGPoint(x: 300, y: screen.frame.maxY - 280))

        // A queued click on an old overlay must not select into a new session.
        controller.show(frame: frame, targetPID: ProcessInfo.processInfo.processIdentifier,
                        onSelection: { selectedPoints.append($0) })
        content.mouseDown(with: event)
        XCTAssertEqual(selectedPoints.count, 1)
        XCTAssertTrue(controller.isVisible)
    }

    func testTabConfirmsCurrentCommandBackslashSelection() {
        let controller = SuggestionPanelController()
        let snippet = Snippet(
            name: "Tab selection",
            keyword: "tab-selection",
            content: "Selected with Tab")
        var selectedSnippet: Snippet?

        controller.showSecurePaste(
            items: [SuggestionItem(snippet: snippet, score: 0)],
            anchorFocusedElement: nil,
            copiesToClipboard: true,
            onSearch: { _ in [SuggestionItem(snippet: snippet, score: 0)] },
            onSelect: { selectedSnippet = $0 },
            onCancel: { _ in XCTFail("Tab must confirm rather than cancel the picker") })

        let consumed = controller.control(
            NSSearchField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertTab(_:)))

        XCTAssertTrue(consumed)
        XCTAssertEqual(selectedSnippet, snippet)
        XCTAssertFalse(controller.isSecurePasteVisible)
    }

    func testCommandNumberUsesFilteredOrderAndDismissesBeforeDeliveringSnippet() throws {
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = SuggestionPanelController()
        defer { controller.dismissSecurePasteWithoutCallback() }
        let items = (1...10).map { index in
            SuggestionItem(snippet: Snippet(name: "Result \(index)", keyword: "item-\(index)",
                content: "Body \(index)"), isSecure: index == 3, score: 0)
        }
        let filtered = [items[8], items[2]]
        var selected: [Snippet] = []
        func show() {
            controller.showSecurePaste(items: items, anchorFocusedElement: nil, copiesToClipboard: true,
                onSearch: { _ in filtered }, onSelect: {
                    XCTAssertFalse(controller.isVisible)
                    selected.append($0)
                }, onCancel: { _ in XCTFail("A quick selection must not cancel") })
        }
        show()
        let window = try XCTUnwrap(NSApp.windows.first {
            !initialWindows.contains($0.windowNumber) && $0.isVisible
        })
        let search = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "filtered"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let table = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSTableView }.first)
        window.contentView?.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let hint = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "pickerQuickSelectionHint" })
        XCTAssertEqual(hint.stringValue, "⌘2")
        XCTAssertFalse(hint.isHidden)
        cell.layoutSubtreeIfNeeded()
        let hintAlignment = try XCTUnwrap(hint.superview)
            .convert(hint.alignmentRect(forFrame: hint.frame), to: cell)
        XCTAssertEqual(hintAlignment.maxX, cell.bounds.maxX - 14, accuracy: 1,
            "A short title must keep its shortcut at the trailing edge")

        // AppKit can route shortcuts through performKeyEquivalent before sendEvent.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(code: 19, characters: "2", window: window)))
        XCTAssertEqual(selected, [items[2].snippet], "Use the filtered item and the existing secure-selection callback")
        show()
        window.sendEvent(try key(code: 25, characters: "9", window: window))
        XCTAssertEqual(selected, [items[2].snippet, items[8].snippet])
    }

    func testQuickSelectionIgnoresMissingRowsRepeatsAndInlineSuggestions() throws {
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = SuggestionPanelController()
        defer { controller.dismiss() }
        let item = SuggestionItem(snippet: Snippet(name: "One", keyword: "one", content: "One"), score: 0)
        var selected = false
        controller.showSecurePaste(items: [item], anchorFocusedElement: nil, copiesToClipboard: true,
            onSearch: { _ in [] }, onSelect: { _ in selected = true }, onCancel: { _ in })
        let window = try XCTUnwrap(NSApp.windows.first {
            !initialWindows.contains($0.windowNumber) && $0.isVisible
        })
        XCTAssertTrue(window.performKeyEquivalent(with: try key(code: 25, characters: "9", window: window)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(code: 18, characters: "1", window: window, repeatKey: true)))
        for flags: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertFalse(window.performKeyEquivalent(with: try key(code: 18, characters: "1", window: window, flags: flags)))
        }
        XCTAssertTrue(controller.isSecurePasteVisible)
        XCTAssertFalse(selected)
        let search = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "no results"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(code: 18, characters: "1", window: window)))
        XCTAssertFalse(selected)
        controller.dismissSecurePasteWithoutCallback()

        controller.onSelect = { _ in selected = true }
        controller.show(items: [item])
        XCTAssertFalse(window.performKeyEquivalent(with: try key(code: 18, characters: "1", window: window)))
        XCTAssertFalse(selected, "Ordinary inline suggestions must leave application shortcuts alone")
        let table = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSTableView }.first)
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let hint = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "pickerQuickSelectionHint" })
        XCTAssertTrue(hint.isHidden)
    }

    func testQuickSelectionRecognizesAllNumberAndKeypadKeys() throws {
        let window = NSWindow()
        for (row, codes) in [[18, 83], [19, 84], [20, 85], [21, 86], [23, 87],
                             [22, 88], [26, 89], [28, 91], [25, 92]].enumerated() {
            for code in codes {
                let event = try key(code: UInt16(code), characters: "", window: window,
                    flags: [.command, .capsLock, .numericPad])
                XCTAssertEqual(PickerQuickSelection.row(for: event), row)
            }
        }
        XCTAssertNil(PickerQuickSelection.row(for: try key(code: 29, characters: "0", window: window)))
        XCTAssertNil(PickerQuickSelection.row(for: try key(code: 0, characters: "a", window: window)))
    }

    private func key(code: UInt16, characters: String, window: NSWindow,
                     flags: NSEvent.ModifierFlags = .command, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
#endif
