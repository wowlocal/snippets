import Foundation
import XCTest
@testable import SnippetsCore

final class SnippetSearchIndexTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testSearchPreservesInputOrderAndMatchesEveryField() {
        let first = Snippet(
            name: "Café Reply",
            keyword: "respond-now",
            content: "Bonjour from Paris",
            tags: ["Work", "Urgent"],
            isPinned: true
        )
        let second = Snippet(
            name: "Résumé",
            keyword: "career",
            content: "Experience and education",
            tags: ["Personal"]
        )
        let third = Snippet(
            name: "Status",
            keyword: "weekly",
            content: "Everything is green",
            tags: ["Work"]
        )
        let index = SnippetSearchIndex()
        let snippets = [first, second, third]

        XCTAssertEqual(
            index.results(in: snippets, searchText: "", activeTagKeys: [], locale: locale),
            snippets
        )
        XCTAssertEqual(
            index.results(in: snippets, searchText: "reply", activeTagKeys: [], locale: locale),
            [first]
        )
        XCTAssertEqual(
            index.results(in: snippets, searchText: "respond", activeTagKeys: [], locale: locale),
            [first]
        )
        XCTAssertEqual(
            index.results(in: snippets, searchText: "from par", activeTagKeys: [], locale: locale),
            [first]
        )
        XCTAssertEqual(
            index.results(in: snippets, searchText: "urgent", activeTagKeys: [], locale: locale),
            [first]
        )
    }

    func testSearchIsCaseAndDiacriticInsensitiveAndTrimsQuery() {
        let snippet = Snippet(
            name: "CAFÉ Notes",
            keyword: "Résumé",
            content: "À bientôt",
            tags: ["Crème Brûlée"]
        )
        let index = SnippetSearchIndex()

        for query in ["  cafe\n", "resume", "A BIENTOT", "creme brulee"] {
            XCTAssertEqual(
                index.results(in: [snippet], searchText: query, activeTagKeys: [], locale: locale),
                [snippet],
                "Expected \(query.debugDescription) to match"
            )
        }
    }

    func testTagFiltersUseANDSemanticsAndCanonicalKeys() {
        let both = Snippet(name: "Both", keyword: "both", content: "", tags: ["Wörk", "Urgent"])
        let work = Snippet(name: "Work", keyword: "work", content: "", tags: ["WORK"])
        let personal = Snippet(name: "Personal", keyword: "personal", content: "", tags: ["Personal"])
        let index = SnippetSearchIndex()
        let workKey = SnippetTagging.filterKey(for: "work")
        let urgentKey = SnippetTagging.filterKey(for: "URGENT")

        XCTAssertEqual(
            index.results(
                in: [both, work, personal],
                searchText: "",
                activeTagKeys: [workKey],
                locale: locale
            ),
            [both, work]
        )
        XCTAssertEqual(
            index.results(
                in: [both, work, personal],
                searchText: "",
                activeTagKeys: [workKey, urgentKey],
                locale: locale
            ),
            [both]
        )
    }

    func testRepeatedQueriesReuseNormalizedFieldsAndRelevantChangesInvalidateExactlyOneEntry() {
        let first = Snippet(name: "First", keyword: "one", content: "shared phrase")
        var second = Snippet(name: "Second", keyword: "two", content: "other phrase")
        let index = SnippetSearchIndex()

        _ = index.results(in: [first, second], searchText: "shared", activeTagKeys: [], locale: locale)
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)
        XCTAssertEqual(index.statistics.lastSnapshotEntryBuildCount, 2)

        _ = index.results(in: [first, second], searchText: "other", activeTagKeys: [], locale: locale)
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)
        XCTAssertEqual(index.statistics.lastSnapshotEntryBuildCount, 0)

        // Presentation-only changes return the current value without rebuilding text.
        second.isPinned = true
        _ = index.results(in: [first, second], searchText: "other", activeTagKeys: [], locale: locale)
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)
        XCTAssertEqual(index.statistics.lastSnapshotEntryBuildCount, 0)

        // Source fields, rather than updatedAt, are the invalidation authority.
        second.content = "replacement phrase"
        XCTAssertEqual(
            index.results(
                in: [first, second],
                searchText: "replacement",
                activeTagKeys: [],
                locale: locale
            ),
            [second]
        )
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 3)
        XCTAssertEqual(index.statistics.lastSnapshotEntryBuildCount, 1)
    }

    func testRemovedEntriesAreNotRetainedAndNewEntriesAreNormalizedOnce() {
        let first = Snippet(name: "First", keyword: "first", content: "one")
        let second = Snippet(name: "Second", keyword: "second", content: "two")
        let index = SnippetSearchIndex()

        _ = index.results(in: [first, second], searchText: "", activeTagKeys: [], locale: locale)
        _ = index.results(in: [second], searchText: "", activeTagKeys: [], locale: locale)
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)
        XCTAssertEqual(index.statistics.lastSnapshotEntryBuildCount, 0)

        let replacement = Snippet(name: "Replacement", keyword: "new", content: "three")
        _ = index.results(in: [second, replacement], searchText: "", activeTagKeys: [], locale: locale)
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 3)
        XCTAssertEqual(index.statistics.lastSnapshotEntryBuildCount, 1)
    }

    func testLocaleChangeInvalidatesNormalizedEntries() {
        let snippet = Snippet(name: "Istanbul", keyword: "city", content: "")
        let index = SnippetSearchIndex()

        _ = index.results(
            in: [snippet],
            searchText: "istanbul",
            activeTagKeys: [],
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 1)

        _ = index.results(
            in: [snippet],
            searchText: "istanbul",
            activeTagKeys: [],
            locale: Locale(identifier: "tr_TR")
        )
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)
        XCTAssertEqual(index.statistics.lastSnapshotEntryBuildCount, 1)
    }

    func testSecureShellSearchNeverRequiresPlaintextContent() {
        let secureShell = Snippet(
            name: "Private Token",
            keyword: "token",
            content: "",
            tags: ["Secrets"]
        )
        let index = SnippetSearchIndex()

        XCTAssertEqual(
            index.results(in: [secureShell], searchText: "private", activeTagKeys: [], locale: locale),
            [secureShell]
        )
        XCTAssertTrue(
            index.results(
                in: [secureShell],
                searchText: "decrypted body",
                activeTagKeys: [],
                locale: locale
            ).isEmpty
        )
    }

    func testNormalizedPayloadIsBoundedAndOverflowStillSearchesCorrectly() {
        let index = SnippetSearchIndex(maximumNormalizedBytes: 512)
        let small = Snippet(name: "Small", keyword: "small", content: "short")
        let oversized = Snippet(
            name: "Large",
            keyword: "large",
            content: String(repeating: "bounded searchable body ", count: 100)
        )

        XCTAssertEqual(
            index.results(
                in: [small, oversized],
                searchText: "searchable body",
                activeTagKeys: [],
                locale: locale
            ),
            [oversized]
        )
        XCTAssertLessThanOrEqual(index.statistics.estimatedNormalizedBytes, 512)
        XCTAssertEqual(index.statistics.uncachedEntryCount, 1)

        let builds = index.statistics.normalizedEntryBuildCount
        XCTAssertEqual(
            index.results(
                in: [small, oversized],
                searchText: "bounded",
                activeTagKeys: [],
                locale: locale
            ),
            [oversized]
        )
        XCTAssertEqual(
            index.statistics.normalizedEntryBuildCount,
            builds,
            "an identical library must reuse its immutable bounded snapshot"
        )
    }

    func testPipelineDropsQueuedStaleRequest() {
        let worker = DispatchQueue(label: "SnippetSearchPipelineTests.worker")
        let gate = DispatchSemaphore(value: 0)
        let workerBlocked = expectation(description: "worker blocked")
        worker.async {
            workerBlocked.fulfill()
            gate.wait()
        }
        wait(for: [workerBlocked], timeout: 1)

        let index = SnippetSearchIndex()
        let pipeline = SnippetSearchPipeline(index: index, queue: worker)
        let staleSnippet = Snippet(name: "Stale", keyword: "stale", content: "")
        let snippet = Snippet(name: "Current", keyword: "current", content: "")
        let staleCompletion = expectation(description: "stale completion")
        staleCompletion.isInverted = true
        let currentCompletion = expectation(description: "current completion")

        pipeline.submit(
            snippets: [staleSnippet],
            searchText: "stale",
            activeTagKeys: [],
            locale: locale
        ) { _ in
            staleCompletion.fulfill()
        }
        pipeline.submit(
            snippets: [snippet],
            searchText: "current",
            activeTagKeys: [],
            locale: locale
        ) { response in
            XCTAssertEqual(response.snippets, [snippet])
            currentCompletion.fulfill()
        }

        gate.signal()
        wait(for: [currentCompletion, staleCompletion], timeout: 0.3)
        XCTAssertEqual(
            index.statistics.normalizedEntryBuildCount,
            1,
            "the replaced pending library must never be normalized"
        )
    }
}
