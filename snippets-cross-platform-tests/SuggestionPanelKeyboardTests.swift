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
}
#endif
