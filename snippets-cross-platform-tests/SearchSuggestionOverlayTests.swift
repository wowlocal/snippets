import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class SearchSuggestionOverlayTests: XCTestCase {
    func testSelectionScrollsInShortPanelAndSurvivesRefresh() throws {
        let overlay = SearchSuggestionOverlayView(frame: NSRect(x: 0, y: 0, width: 340, height: 190))
        let snippets = (0..<8).map { Snippet(name: "Result \($0)", keyword: "result.\($0)", content: "") }
        let window = NSWindow(contentRect: overlay.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = overlay
        defer {
            window.contentView = nil
            window.close()
        }

        overlay.update(snippets: snippets, selectedSnippetID: snippets[0].id)
        settle(overlay)
        let scrollView = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scrollView.documentView)
        let stack = try XCTUnwrap(document.subviews.compactMap { $0 as? NSStackView }.first)
        let rows = stack.arrangedSubviews
        XCTAssertEqual(rows.count, snippets.count)
        XCTAssertGreaterThan(document.bounds.height, scrollView.contentView.bounds.height)

        func assertVisible(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(overlay.selectedSnippet()?.id, snippets[index].id, file: file, line: line)
            let rect = rows[index].convert(rows[index].bounds, to: document)
            let visible = scrollView.documentVisibleRect
            XCTAssertGreaterThanOrEqual(rect.minY, visible.minY - 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxY, visible.maxY + 0.5, file: file, line: line)
        }

        assertVisible(0)
        for index in 1..<snippets.count {
            overlay.moveSelectionDown()
            settle(overlay)
            assertVisible(index)
        }
        XCTAssertGreaterThan(scrollView.documentVisibleRect.minY, 0)

        // The main controller refreshes the overlay after applying each selection.
        overlay.update(snippets: snippets, selectedSnippetID: snippets.last?.id)
        settle(overlay)
        let refreshedStack = try XCTUnwrap(document.subviews.compactMap { $0 as? NSStackView }.first)
        let lastRow = try XCTUnwrap(refreshedStack.arrangedSubviews.last)
        XCTAssertTrue(scrollView.documentVisibleRect.contains(lastRow.convert(lastRow.bounds, to: document)))

        window.setContentSize(NSSize(width: 340, height: 130))
        settle(overlay)
        XCTAssertTrue(scrollView.documentVisibleRect.contains(lastRow.convert(lastRow.bounds, to: document)))

        // Moving past the last result wraps to the top; Up wraps back to the bottom.
        overlay.moveSelectionDown()
        settle(overlay)
        XCTAssertEqual(overlay.selectedSnippet()?.id, snippets.first?.id)
        let firstRow = try XCTUnwrap(refreshedStack.arrangedSubviews.first)
        XCTAssertTrue(scrollView.documentVisibleRect.contains(firstRow.convert(firstRow.bounds, to: document)))
        overlay.moveSelectionUp()
        settle(overlay)
        XCTAssertEqual(overlay.selectedSnippet()?.id, snippets.last?.id)
        XCTAssertTrue(scrollView.documentVisibleRect.contains(lastRow.convert(lastRow.bounds, to: document)))

        overlay.update(snippets: Array(snippets.prefix(2)), selectedSnippetID: snippets[0].id)
        settle(overlay)
        XCTAssertEqual(overlay.selectedSnippet()?.id, snippets[0].id)
        let filteredRow = try XCTUnwrap(refreshedStack.arrangedSubviews.first)
        XCTAssertTrue(scrollView.documentVisibleRect.contains(filteredRow.convert(filteredRow.bounds, to: document)))
    }

    private func settle(_ overlay: SearchSuggestionOverlayView) {
        overlay.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
#endif
