import Foundation

nonisolated struct SuggestionItem: Equatable, Sendable {
    let snippet: Snippet
    let isSecure: Bool
    let score: Int
    let nameMatchRanges: [NSRange]
    let keywordMatchRanges: [NSRange]
    /// Precomputed so the comparator never folds strings on the keystroke path.
    let keywordRank: Int
    let bindingWeight: Double
    let frecency: Double

    init(
        snippet: Snippet,
        isSecure: Bool = false,
        score: Int,
        nameMatchRanges: [NSRange] = [],
        keywordMatchRanges: [NSRange] = [],
        keywordRank: Int = 0,
        bindingWeight: Double = 0,
        frecency: Double = 0
    ) {
        self.snippet = snippet
        self.isSecure = isSecure
        self.score = score
        self.nameMatchRanges = nameMatchRanges
        self.keywordMatchRanges = keywordMatchRanges
        self.keywordRank = keywordRank
        self.bindingWeight = bindingWeight
        self.frecency = frecency
    }
}


/// Main-actor-owned metadata index. It retains the current Snippet values for
/// selection, but prepares only display names, keywords, and tags for matching.
@MainActor
final class SuggestionSearchIndex {
    struct Entry {
        let snippet: Snippet
        let isSecure: Bool
        let name: String
        let keyword: String
        let foldedKeyword: String
        let preparedName: FuzzyMatch.PreparedTarget
        let preparedKeyword: FuzzyMatch.PreparedTarget
        let preparedTags: [FuzzyMatch.PreparedTarget]
    }

    struct Snapshot {
        let entries: [Entry]
        let byID: [UUID: Entry]
        let displayOrder: [UUID: Int]
        let ordinaryExactMatches: [String: Snippet]
        let locale: Locale

        func unambiguousOrdinaryMatch(for query: String) -> Snippet? {
            guard !query.contains(where: { $0.unicodeScalars.count > 1 }) else { return nil }
            return ordinaryExactMatches[query.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: locale)]
        }
    }

    private var ordinary: [Snippet] = []
    private var secure: [Snippet] = []
    private var cached: Snapshot?
    private(set) var snapshotBuildCount = 0
    private(set) var preparedFieldBuildCount = 0

    func snapshot(ordinary: [Snippet], secure: [Snippet], locale: Locale = .current) -> Snapshot {
        if let cached, cached.locale.identifier == locale.identifier,
           self.ordinary == ordinary, self.secure == secure { return cached }
        let reusable = cached?.locale.identifier == locale.identifier ? cached?.byID ?? [:] : [:]
        let secureIDs = Set(secure.map(\.id))
        let entries = SnippetDisplayOrder.sorted(ordinary + secure).map { snippet in
            let name = snippet.displayName
            let keyword = snippet.normalizedKeyword
            let old = reusable[snippet.id]
            let sameName = old?.name == name
            let sameKeyword = old?.keyword == keyword
            let sameTags = old?.snippet.tags == snippet.tags
            preparedFieldBuildCount += (sameName ? 0 : 1) + (sameKeyword ? 0 : 1)
                + (sameTags ? 0 : snippet.tags.count)
            return Entry(
                snippet: snippet, isSecure: secureIDs.contains(snippet.id), name: name, keyword: keyword,
                foldedKeyword: sameKeyword ? old!.foldedKeyword : keyword.folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: locale),
                preparedName: sameName ? old!.preparedName : FuzzyMatch.PreparedTarget(name, locale: locale),
                preparedKeyword: sameKeyword ? old!.preparedKeyword : FuzzyMatch.PreparedTarget(keyword, locale: locale),
                preparedTags: sameTags ? old!.preparedTags : snippet.tags.map {
                    FuzzyMatch.PreparedTarget($0, locale: locale)
                })
        }

        // Only ordinary enabled records can auto-expand. Adjacent lexicographic
        // keys are sufficient to detect a longer keyword with the same prefix.
        let groups = Dictionary(grouping: entries.filter {
            !$0.isSecure && $0.snippet.isEnabled && !$0.foldedKeyword.isEmpty
        }, by: \.foldedKeyword)
        let keywords = groups.keys.sorted()
        var exact: [String: Snippet] = [:]
        for (index, keyword) in keywords.enumerated() {
            guard let group = groups[keyword], group.count == 1 else { continue }
            if index + 1 < keywords.count, keywords[index + 1].hasPrefix(keyword) { continue }
            exact[keyword] = group[0].snippet
        }
        let snapshot = Snapshot(
            entries: entries,
            byID: Dictionary(uniqueKeysWithValues: entries.map { ($0.snippet.id, $0) }),
            displayOrder: Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.snippet.id, $0.offset) }),
            ordinaryExactMatches: exact, locale: locale)
        self.ordinary = ordinary
        self.secure = secure
        self.cached = snapshot
        snapshotBuildCount += 1
        return snapshot
    }
}

extension SuggestionSearchIndex {
    /// The backslash panel shows eight rows. Keep only that prefix while scanning,
    /// without materializing and sorting every matching item in the library.
    static func top<S: Sequence>(
        _ candidates: S, limit: Int, ranks: (S.Element, S.Element) -> Bool
    ) -> [S.Element] {
        guard limit > 0 else { return [] }
        var results: [S.Element] = []
        results.reserveCapacity(limit)
        for candidate in candidates {
            if results.count == limit, !ranks(candidate, results[limit - 1]) { continue }
            var low = 0
            var high = results.count
            while low < high {
                let middle = (low + high) / 2
                if ranks(candidate, results[middle]) { high = middle } else { low = middle + 1 }
            }
            results.insert(candidate, at: low)
            if results.count > limit { results.removeLast() }
        }
        return results
    }
}

extension SuggestionSearchIndex {
    static func suggestions(query: String, snapshot: Snapshot, frecency: FrecencySnapshot) -> [SuggestionItem] {
        let entries = snapshot.entries.lazy.filter { $0.snippet.isEnabled && !$0.keyword.isEmpty }
        if query.isEmpty {
            return top(entries, limit: 8) { lhs, rhs in
                SnippetFrecency.emptyQueryRanks(
                    lhsPinned: lhs.snippet.isPinned, lhsFrecency: frecency.value(for: lhs.snippet.id),
                    lhsOrder: snapshot.displayOrder[lhs.snippet.id]!,
                    rhsPinned: rhs.snippet.isPinned, rhsFrecency: frecency.value(for: rhs.snippet.id),
                    rhsOrder: snapshot.displayOrder[rhs.snippet.id]!)
            }.map { SuggestionItem(snippet: $0.snippet, isSecure: $0.isSecure,
                                   score: 0, frecency: frecency.value(for: $0.snippet.id)) }
        }

        let prepared = FuzzyMatch.PreparedQuery(query, locale: snapshot.locale)
        let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: snapshot.locale)
        let binding = frecency.bindingTable(forQuery: query)
        var workspace = FuzzyMatch.Workspace()
        let candidates = entries.compactMap { entry -> (entry: Entry, key: SnippetRankingKey)? in
            let name = FuzzyMatch.score(query: prepared, target: entry.preparedName,
                                       includingRanges: false, workspace: &workspace)
            let keyword = FuzzyMatch.score(query: prepared, target: entry.preparedKeyword,
                                          includingRanges: false, workspace: &workspace)
            guard name.matched || keyword.matched else { return nil }
            return (entry, SnippetRankingKey(
                score: max(name.score, keyword.score),
                keywordRank: SnippetFrecency.keywordRank(
                    foldedKeyword: entry.foldedKeyword, foldedQuery: foldedQuery,
                    hasKeywordMatchRanges: keyword.matched && !prepared.isEmpty),
                isPinned: entry.snippet.isPinned, bindingWeight: binding[entry.snippet.id] ?? 0,
                frecency: frecency.value(for: entry.snippet.id),
                displayOrder: snapshot.displayOrder[entry.snippet.id]!,
                displayName: entry.name, id: entry.snippet.id))
        }
        return top(candidates, limit: 8, ranks: { SnippetFrecency.ranks($0.key, before: $1.key) }).map {
            let name = FuzzyMatch.score(query: prepared, target: $0.entry.preparedName, workspace: &workspace)
            let keyword = FuzzyMatch.score(query: prepared, target: $0.entry.preparedKeyword, workspace: &workspace)
            return SuggestionItem(
                snippet: $0.entry.snippet, isSecure: $0.entry.isSecure, score: $0.key.score,
                nameMatchRanges: name.matchedRanges, keywordMatchRanges: keyword.matchedRanges,
                keywordRank: $0.key.keywordRank, bindingWeight: $0.key.bindingWeight, frecency: $0.key.frecency)
        }
    }
}
