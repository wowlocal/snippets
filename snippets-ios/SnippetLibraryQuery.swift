import Foundation

nonisolated struct SnippetLibraryQuery {
    struct Results: Equatable {
        let pinned: [Snippet]
        let snippets: [Snippet]

        var all: [Snippet] { pinned + snippets }
        var isEmpty: Bool { pinned.isEmpty && snippets.isEmpty }
    }

    static func results(
        in snippets: [Snippet],
        searchText: String,
        activeTagKeys: Set<String>
    ) -> Results {
        let matches: [Snippet]
        if SnippetSearchSnapshot.normalizedQuery(searchText).isEmpty {
            matches = SnippetSearchSnapshot.resultsForEmptySearch(
                in: snippets,
                activeTagKeys: activeTagKeys
            )
        } else {
            matches = sharedSearchIndex.results(
                in: snippets,
                searchText: searchText,
                activeTagKeys: activeTagKeys
            )
        }
        return Results(
            pinned: matches.filter(\.isPinned),
            snippets: matches.filter { !$0.isPinned }
        )
    }

    private static let sharedSearchIndex = SnippetSearchIndex()
}
