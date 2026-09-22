import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class ClipboardHistoryPanelTests: XCTestCase {
    func testLiveAppearanceChangePreservesPreviewAndUpdatesReadingSurface() async throws {
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
        let light = try XCTUnwrap(surface.layer?.backgroundColor)
        preview.setSelectedRange(NSRange(location: 2, length: 9))
        let selectedRow = table.selectedRow

        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.contentView?.layoutSubtreeIfNeeded()
        let dark = try XCTUnwrap(surface.layer?.backgroundColor)
        XCTAssertNotEqual(light, dark, "The cached layer color must follow a live appearance change")
        XCTAssertEqual(surface.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(preview.string, entry.text)
        XCTAssertEqual(preview.selectedRange(), NSRange(location: 2, length: 9))
        XCTAssertEqual(table.selectedRow, selectedRow)
        XCTAssertTrue(controller.isVisible)

        NSApp.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.layer?.backgroundColor, light)
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
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
        // Deliver to this panel only: never inject keystrokes into the user's app.
        window.sendEvent(event)
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
