import XCTest

#if os(macOS)
@testable import Snippets_Debug

@MainActor
final class SuggestionSearchIndexTests: XCTestCase {
    func testTypingReusesPreparedFieldsAndBodyOnlyChangesUpdateSelection() throws {
        let index = SuggestionSearchIndex()
        var snippet = Snippet(name: "Project", keyword: "project", content: "Before", tags: ["work"])
        let original = index.snapshot(ordinary: [snippet], secure: [])
        XCTAssertEqual(index.preparedFieldBuildCount, 3)
        var workspace = FuzzyMatch.Workspace()
        for query in ["p", "pr", "proj", "pr", "", "missing"] {
            let snapshot = index.snapshot(ordinary: [snippet], secure: [])
            let entry = try XCTUnwrap(snapshot.entries.first)
            let actual = FuzzyMatch.score(query: .init(query), target: entry.preparedKeyword, workspace: &workspace)
            let expected = FuzzyMatch.score(query: query, target: "project")
            XCTAssertEqual(actual, expected)
        }
        XCTAssertEqual(index.snapshotBuildCount, 1)
        XCTAssertEqual(index.preparedFieldBuildCount, 3)
        snippet.content = "After"
        let changed = index.snapshot(ordinary: [snippet], secure: [])
        XCTAssertEqual(changed.unambiguousOrdinaryMatch(for: "project")?.content, "After")
        XCTAssertEqual(original.unambiguousOrdinaryMatch(for: "project")?.content, "Before")
        XCTAssertEqual(index.preparedFieldBuildCount, 3, "A payload change need not refold unchanged labels")
    }

    func testKeywordCollisionsPrefixesDisabledAndSecureRecords() {
        let index = SuggestionSearchIndex()
        let short = Snippet(name: "Short", keyword: "café", content: "A")
        var long = Snippet(name: "Long", keyword: "cafeteria", content: "B")
        let duplicate = Snippet(name: "Duplicate", keyword: "CAFE", content: "C")
        let secret = Snippet(name: "Secure", keyword: "cafe.secret", content: "")
        XCTAssertNil(index.snapshot(ordinary: [short, long], secure: []).unambiguousOrdinaryMatch(for: "cafe"))
        XCTAssertNil(index.snapshot(ordinary: [short, duplicate], secure: []).unambiguousOrdinaryMatch(for: "cafe"))
        long.isEnabled = false
        let snapshot = index.snapshot(ordinary: [short, long], secure: [secret])
        XCTAssertEqual(snapshot.unambiguousOrdinaryMatch(for: "CAFE")?.id, short.id)
        XCTAssertNil(snapshot.unambiguousOrdinaryMatch(for: "cafe.secret"))
        XCTAssertNil(snapshot.unambiguousOrdinaryMatch(for: "cafeteria"))
        XCTAssertNil(snapshot.unambiguousOrdinaryMatch(for: "cafe\u{301}"), "Deletion still rejects multi-scalar graphemes")
        XCTAssertNil(index.snapshot(ordinary: [], secure: [short]).unambiguousOrdinaryMatch(for: "cafe"))
        XCTAssertEqual(index.snapshot(ordinary: [short], secure: []).unambiguousOrdinaryMatch(for: "cafe")?.id, short.id)
    }

    func testMetadataEditsLocaleAndUnnamedContentInvalidatePreparation() throws {
        let index = SuggestionSearchIndex()
        var snippet = Snippet(name: "", keyword: "I", content: "Before", tags: ["tag"])
        let first = index.snapshot(ordinary: [snippet], secure: [], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(first.entries.first?.name, "Before")
        XCTAssertNotNil(first.unambiguousOrdinaryMatch(for: "i"))
        snippet.content = "After"
        snippet.keyword = "Other"
        snippet.tags = ["changed"]
        let next = index.snapshot(ordinary: [snippet], secure: [], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(next.entries.first?.name, "After")
        XCTAssertEqual(index.preparedFieldBuildCount, 6)
        snippet.keyword = "I"
        let turkish = index.snapshot(ordinary: [snippet], secure: [], locale: Locale(identifier: "tr_TR"))
        XCTAssertNil(turkish.unambiguousOrdinaryMatch(for: "i"))
        XCTAssertNotNil(turkish.unambiguousOrdinaryMatch(for: "ı"))
    }

    func testTopEightMatchesFullSortIncludingStableTies() {
        struct Candidate: Equatable { let score: Int; let order: Int }
        let candidates = (0..<1000).map { Candidate(score: ($0 * 37) % 17, order: $0) }
        for limit in [0, 1, 8, 1000, 1500] {
            let expected = Array(candidates.sorted { $0.score > $1.score }.prefix(limit))
            let actual = SuggestionSearchIndex.top(candidates.lazy, limit: limit) { $0.score > $1.score }
            XCTAssertEqual(actual, expected)
        }
    }

    func testPreparedRankingPreservesAllTiersAndTopEight() {
        let index = SuggestionSearchIndex()
        let snippets = (0..<80).map {
            Snippet(name: $0.isMultiple(of: 2) ? "Project \($0)" : "Report \($0)",
                    keyword: $0.isMultiple(of: 13) ? "" : "pr.\($0)", content: "Body",
                    isEnabled: !$0.isMultiple(of: 11), isPinned: $0.isMultiple(of: 9))
        }
        let snapshot = index.snapshot(ordinary: Array(snippets.prefix(60)), secure: Array(snippets.suffix(20)))
        let weights = Dictionary(uniqueKeysWithValues: snippets.enumerated().map { ($0.element.id, Double($0.offset % 7)) })
        let binding = [snippets[2].id: 1.0, snippets[9].id: 0.7]
        for query in ["", "p", "pr", "pr.1", "r", "missing"] {
            let frecency = FrecencySnapshot(weights: weights,
                bindings: SnippetFrecency.bindingKey(for: query).map { [$0: binding] } ?? [:], cutoff: 0.5)
            let candidates = snapshot.entries.compactMap { entry -> (SnippetRankingKey, SuggestionItem)? in
                guard entry.snippet.isEnabled, !entry.keyword.isEmpty else { return nil }
                let name = FuzzyMatch.score(query: query, target: entry.name)
                let keyword = FuzzyMatch.score(query: query, target: entry.keyword)
                guard name.matched || keyword.matched else { return nil }
                let key = SnippetRankingKey(score: max(name.score, keyword.score),
                    keywordRank: query.isEmpty ? 0 : SnippetFrecency.keywordRank(
                        foldedKeyword: entry.foldedKeyword, foldedQuery: SnippetFrecency.foldedForMatching(query),
                        hasKeywordMatchRanges: !keyword.matchedRanges.isEmpty),
                    isPinned: entry.snippet.isPinned,
                    bindingWeight: query.isEmpty ? 0 : binding[entry.snippet.id] ?? 0,
                    frecency: frecency.value(for: entry.snippet.id), displayOrder: snapshot.displayOrder[entry.snippet.id]!,
                    displayName: entry.name, id: entry.snippet.id)
                return (key, SuggestionItem(snippet: entry.snippet, isSecure: entry.isSecure,
                    score: key.score, nameMatchRanges: name.matchedRanges, keywordMatchRanges: keyword.matchedRanges,
                    keywordRank: key.keywordRank, bindingWeight: key.bindingWeight, frecency: key.frecency))
            }
            let expected = candidates.sorted {
                if query.isEmpty {
                    return SnippetFrecency.emptyQueryRanks(lhsPinned: $0.0.isPinned, lhsFrecency: $0.0.frecency,
                        lhsOrder: $0.0.displayOrder, rhsPinned: $1.0.isPinned, rhsFrecency: $1.0.frecency,
                        rhsOrder: $1.0.displayOrder)
                }
                return SnippetFrecency.ranks($0.0, before: $1.0)
            }.prefix(8).map { $0.1 }
            XCTAssertEqual(SuggestionSearchIndex.suggestions(query: query, snapshot: snapshot, frecency: frecency), expected)
        }
    }
}
#endif
