import XCTest

#if os(macOS)
@testable import Snippets_Debug

@MainActor
final class SuggestionResultsUpdaterTests: XCTestCase {
    func testKeyThenDuplicateBrowserNotificationsPresentOnlyOnce() {
        let updater = SuggestionResultsUpdater()
        let snippets = [Snippet(name: "Project", keyword: "project", content: "Body")]
        var presentations = 0
        for _ in 0..<4 { // optimistic key, scheduled read, value and selection notifications
            updater.updateIfNeeded(query: "pr", ordinary: snippets, secure: []) {
                presentations += 1
            }
        }
        XCTAssertEqual(presentations, 1)
        updater.updateIfNeeded(query: "pro", ordinary: snippets, secure: []) {
            presentations += 1
        }
        XCTAssertEqual(presentations, 2)
    }

    func testBodyOnlyRemoteEditRefreshesTheSnippetUsedForSelection() {
        let updater = SuggestionResultsUpdater()
        var snippet = Snippet(name: "Project", keyword: "project", content: "Before")
        var selected: Snippet?
        updater.updateIfNeeded(query: "pr", ordinary: [snippet], secure: []) {
            selected = snippet
        }
        // Do not rely on timestamps for invalidation; equal timestamps can merge.
        snippet.content = "After"
        updater.updateIfNeeded(query: "pr", ordinary: [snippet], secure: []) {
            selected = snippet
        }
        XCTAssertEqual(selected?.content, "After")
    }

    func testSecureTransitionWithIdenticalShellRefreshesPresentation() {
        let updater = SuggestionResultsUpdater()
        let shell = Snippet(name: "Project", keyword: "project", content: "")
        var secureBadge = false
        updater.updateIfNeeded(query: "pr", ordinary: [shell], secure: []) {}
        updater.updateIfNeeded(query: "pr", ordinary: [], secure: [shell]) {
            secureBadge = true
        }
        XCTAssertTrue(secureBadge)
        updater.updateIfNeeded(query: "pr", ordinary: [shell], secure: []) {
            secureBadge = false
        }
        XCTAssertFalse(secureBadge)
    }

    func testLibraryChangesAndLocaleChangesRefreshResults() {
        let updater = SuggestionResultsUpdater()
        let first = Snippet(name: "First", keyword: "first", content: "Body")
        let second = Snippet(name: "Second", keyword: "second", content: "Body")
        var presentations = 0
        func update(_ snippets: [Snippet], locale: String = "en_US") {
            updater.updateIfNeeded(query: "", ordinary: snippets, secure: [],
                                   localeIdentifier: locale) { presentations += 1 }
        }
        update([first, second])
        update([second, first])
        update([second])
        var edited = second
        edited.isEnabled = false
        update([edited])
        edited.isPinned = true
        update([edited])
        edited.keyword = "changed"
        update([edited])
        edited.name = "Renamed"
        update([edited])
        update([edited], locale: "tr_TR")
        XCTAssertEqual(presentations, 8)
    }

    func testEmptyResultsAreCoalescedButNewSessionAlwaysPresents() {
        let updater = SuggestionResultsUpdater()
        var presentations = 0
        for _ in 0..<2 {
            updater.updateIfNeeded(query: "missing", ordinary: [], secure: []) {
                presentations += 1
            }
        }
        XCTAssertEqual(presentations, 1)
        updater.reset() // dismissal/reactivation also replaces the frozen ranking snapshot
        updater.updateIfNeeded(query: "missing", ordinary: [], secure: []) {
            presentations += 1
        }
        XCTAssertEqual(presentations, 2)
    }
}
#endif
