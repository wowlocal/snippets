import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class SuggestionPanelKeyboardTests: XCTestCase {
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
