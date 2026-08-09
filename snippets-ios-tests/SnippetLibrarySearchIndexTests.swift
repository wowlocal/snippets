import XCTest
@testable import Snippets

@MainActor
final class SnippetLibrarySearchIndexTests: XCTestCase {
    func testIndexedResultsRemainEquivalentToUncachedQuerySemantics() {
        let snippets = fixtures()
        let index = SnippetLibrarySearchIndex()
        let cases: [(String, Set<String>)] = [
            ("", []),
            ("  CAFE\n", []),
            ("resume", []),
            ("weekly status", ["work"]),
            ("urgent", ["work", "urgent"]),
            ("private body", []),
            ("missing", []),
        ]

        for (searchText, activeTagKeys) in cases {
            XCTAssertEqual(
                index.results(
                    in: snippets,
                    searchText: searchText,
                    activeTagKeys: activeTagKeys
                ),
                uncachedResults(
                    in: snippets,
                    searchText: searchText,
                    activeTagKeys: activeTagKeys
                ),
                "Mismatch for query \(searchText.debugDescription) and tags \(activeTagKeys)"
            )
        }
    }

    func testRelevantFieldUpdateInvalidatesEntryEvenWithoutTimestampAdvance() {
        let index = SnippetLibrarySearchIndex()
        var snippet = Snippet(
            name: "Reference",
            keyword: "docs",
            content: "old searchable phrase",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(
            index.results(in: [snippet], searchText: "old searchable", activeTagKeys: []).all,
            [snippet]
        )
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 1)

        // Deliberately preserve updatedAt. The index compares every relevant source
        // field as well, which protects callers that assemble values outside the store.
        snippet.content = "new searchable phrase"
        XCTAssertTrue(
            index.results(in: [snippet], searchText: "old searchable", activeTagKeys: []).isEmpty
        )
        XCTAssertEqual(
            index.results(in: [snippet], searchText: "new searchable", activeTagKeys: []).all,
            [snippet]
        )
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)

        snippet.isPinned = true
        let pinned = index.results(in: [snippet], searchText: "new", activeTagKeys: [])
        XCTAssertEqual(pinned.pinned, [snippet])
        XCTAssertTrue(pinned.snippets.isEmpty)
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)
    }

    func testRemovedSnippetsArePrunedFromCache() {
        let index = SnippetLibrarySearchIndex()
        let first = Snippet(name: "First", keyword: "first", content: "shared term")
        let second = Snippet(name: "Second", keyword: "second", content: "shared term")

        XCTAssertEqual(
            index.results(
                in: [first, second],
                searchText: "shared",
                activeTagKeys: []
            ).all,
            [first, second]
        )
        XCTAssertEqual(index.statistics.cachedSnippetCount, 2)

        XCTAssertEqual(
            index.results(in: [second], searchText: "shared", activeTagKeys: []).all,
            [second]
        )
        XCTAssertEqual(index.statistics.cachedSnippetCount, 1)
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let index = SnippetLibrarySearchIndex()
        let snippet = Snippet(
            name: "CAFÉ Notes",
            keyword: "Résumé",
            content: "À bientôt",
            tags: ["Crème Brûlée"]
        )

        for query in ["cafe", "RESUME", "a bientot", "creme brulee"] {
            XCTAssertEqual(
                index.results(in: [snippet], searchText: query, activeTagKeys: []).all,
                [snippet],
                "Expected \(query) to match folded fields"
            )
        }
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 1)
    }

    func testOversizedEntryIsSearchedButNotRetained() {
        let index = SnippetLibrarySearchIndex(
            maximumPayloadBytes: 128,
            maximumEntryCount: 10
        )
        let snippet = Snippet(
            name: "Large",
            keyword: "large",
            content: String(repeating: "body ", count: 100)
        )

        XCTAssertEqual(
            index.results(in: [snippet], searchText: "body", activeTagKeys: []).all,
            [snippet]
        )
        XCTAssertEqual(index.statistics.cachedSnippetCount, 0)
        XCTAssertLessThanOrEqual(index.statistics.estimatedPayloadBytes, 128)

        _ = index.results(in: [snippet], searchText: "large", activeTagKeys: [])
        XCTAssertEqual(index.statistics.normalizedEntryBuildCount, 2)
    }

    private func fixtures() -> [Snippet] {
        let pinned = Snippet(
            name: "Café Reply",
            keyword: "reply",
            content: "Bonjour",
            tags: ["Work", "Urgent"],
            isPinned: true
        )
        let unnamed = Snippet(
            name: "   ",
            keyword: "status",
            content: "\n Weekly Status\nEverything is green",
            tags: ["Work"]
        )
        let personal = Snippet(
            name: "Résumé",
            keyword: "cv",
            content: "Experience",
            tags: ["Personal"]
        )
        // This has the shape of a secure shell: searchable metadata, no plaintext body.
        let secureShell = Snippet(
            name: "Private Token",
            keyword: "token",
            content: "",
            tags: ["Urgent"]
        )
        return [pinned, unnamed, personal, secureShell]
    }

    private func uncachedResults(
        in snippets: [Snippet],
        searchText: String,
        activeTagKeys: Set<String>
    ) -> SnippetLibraryQuery.Results {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        let filtered = snippets.filter { snippet in
            guard activeTagKeys.allSatisfy({ snippet.hasTag(withKey: $0) }) else {
                return false
            }
            guard !query.isEmpty else { return true }
            let fields = [
                snippet.displayName,
                snippet.normalizedKeyword,
                snippet.content,
            ] + snippet.tags
            return fields.contains {
                $0.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ).contains(query)
            }
        }
        return SnippetLibraryQuery.Results(
            pinned: filtered.filter(\.isPinned),
            snippets: filtered.filter { !$0.isPinned }
        )
    }
}
