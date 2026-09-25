import Foundation

/// Full CPU path for one changed backslash query: snapshot validation, matching,
/// ranking, top eight, highlights, and ordinary exact-keyword resolution. No AX/UI.
@main @MainActor
enum SuggestionSearchBenchmark {
    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }

    static func baseline(_ query: String, ordinary: [Snippet], secure: [Snippet]) -> ([SuggestionItem], UUID?) {
        let secureIDs = Set(secure.map(\.id))
        let snippets = SnippetDisplayOrder.sorted(ordinary + secure).filter { $0.isEnabled && !$0.normalizedKeyword.isEmpty }
        let foldedQuery = SnippetFrecency.foldedForMatching(query)
        let scored = snippets.enumerated().compactMap { offset, snippet -> (SnippetRankingKey, SuggestionItem)? in
            let name = ReferenceFuzzyMatch.score(query: query, target: snippet.displayName)
            let keyword = ReferenceFuzzyMatch.score(query: query, target: snippet.normalizedKeyword)
            guard name.matched || keyword.matched else { return nil }
            let rank = SnippetFrecency.keywordRank(foldedKeyword: SnippetFrecency.foldedForMatching(snippet.normalizedKeyword),
                foldedQuery: foldedQuery, hasKeywordMatchRanges: !keyword.matchedRanges.isEmpty)
            let item = SuggestionItem(snippet: snippet, isSecure: secureIDs.contains(snippet.id),
                score: max(name.score, keyword.score), nameMatchRanges: name.matchedRanges,
                keywordMatchRanges: keyword.matchedRanges, keywordRank: rank)
            let key = SnippetRankingKey(score: item.score, keywordRank: rank, isPinned: snippet.isPinned,
                displayOrder: offset, displayName: snippet.displayName, id: snippet.id)
            return (key, item)
        }.sorted { SnippetFrecency.ranks($0.0, before: $1.0) }.prefix(8).map { $0.1 }
        let enabled = ordinary.filter { $0.isEnabled && !$0.normalizedKeyword.isEmpty }.sorted {
            if $0.normalizedKeyword.count == $1.normalizedKeyword.count { return $0.updatedAt > $1.updatedAt }
            return $0.normalizedKeyword.count > $1.normalizedKeyword.count
        }
        var exact: [UUID] = []
        var longer = false
        for snippet in enabled {
            let keyword = SnippetFrecency.foldedForMatching(snippet.normalizedKeyword)
            if keyword == foldedQuery { exact.append(snippet.id) }
            else if keyword.hasPrefix(foldedQuery) { longer = true }
        }
        return (scored, exact.count == 1 && !longer ? exact[0] : nil)
    }

    static func main() {
        for count in [100, 1_000, 10_000] {
            var ordinary: [Snippet] = []
            var secure: [Snippet] = []
            for i in 0..<count {
                let words = [("Ghost settings", "ghost"), ("Project link", "project"),
                             ("Привет café", "hello"), ("Release checklist", "release")][i % 4]
                let snippet = Snippet(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
                    name: "\(words.0) \(i)", keyword: "\(words.1).\(i)", content: "Synthetic body", tags: ["work"],
                    isEnabled: !i.isMultiple(of: 19), isPinned: i.isMultiple(of: 17),
                    createdAt: Date(timeIntervalSince1970: Double(i)), updatedAt: Date(timeIntervalSince1970: Double(i)))
                if i.isMultiple(of: 7) {
                    var shell = snippet
                    shell.content = ""
                    secure.append(shell)
                } else { ordinary.append(snippet) }
            }
            let index = SuggestionSearchIndex()
            let buildStart = ContinuousClock.now
            _ = index.snapshot(ordinary: ordinary, secure: secure)
            print(String(format: "snapshot rows=%d build=%.3fms", count, milliseconds(buildStart)))
            for query in ["gh", "pr", "cafe", "ghost.40", "zz"] {
                var oldSamples: [Double] = []
                var newSamples: [Double] = []
                var checksum = 0
                let iterations = count == 10_000 ? 15 : 35
                for iteration in 0..<iterations {
                    let oldStart = ContinuousClock.now
                    let old = baseline(query, ordinary: ordinary, secure: secure)
                    let oldMS = milliseconds(oldStart)
                    let newStart = ContinuousClock.now
                    let snapshot = index.snapshot(ordinary: ordinary, secure: secure)
                    let items = SuggestionSearchIndex.suggestions(query: query, snapshot: snapshot, frecency: .empty)
                    let exact = snapshot.unambiguousOrdinaryMatch(for: query)?.id
                    let newMS = milliseconds(newStart)
                    precondition(old.0 == items && old.1 == exact, "Search output changed")
                    checksum &+= items.reduce(0) { $0 + $1.score + $1.nameMatchRanges.count + $1.keywordMatchRanges.count }
                    if iteration >= 5 { oldSamples.append(oldMS); newSamples.append(newMS) }
                }
                oldSamples.sort(); newSamples.sort()
                let n = oldSamples.count
                let oldMedian = (oldSamples[(n - 1) / 2] + oldSamples[n / 2]) / 2
                let newMedian = (newSamples[(n - 1) / 2] + newSamples[n / 2]) / 2
                let p95 = Int(ceil(Double(n) * 0.95)) - 1
                print(String(format: "rows=%d query=%@ old_p50=%.3fms new_p50=%.3fms old_p95=%.3fms new_p95=%.3fms speedup=%.1fx checksum=%d",
                    count, query, oldMedian, newMedian, oldSamples[p95], newSamples[p95], oldMedian / newMedian, checksum))
            }
            precondition(index.snapshotBuildCount == 1)
        }
    }
}
