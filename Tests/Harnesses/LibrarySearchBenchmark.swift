import Foundation

/// Synthetic CPU measurements only: no stores, pasteboard, AX, disk index, or UI.
@main @MainActor
enum LibrarySearchBenchmark {
    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }

    static func report(_ label: String, old: [Double], new: [Double]) {
        let a = old.sorted(), b = new.sorted()
        let p95 = Int(ceil(Double(a.count) * 0.95)) - 1
        print(String(format: "%@ old_p50=%.3fms new_p50=%.3fms old_p95=%.3fms new_p95=%.3fms",
                     label, a[a.count / 2], b[b.count / 2], a[p95], b[p95]))
    }

    static func oldTagUsage(_ snippets: [Snippet]) -> [(String, Int)] {
        var canonical: [String: String] = [:]
        var counts: [String: Int] = [:]
        for snippet in snippets {
            for tag in snippet.tags {
                let key = SnippetTagging.filterKey(for: tag)
                if canonical[key] == nil { canonical[key] = tag }
                counts[key, default: 0] += 1
            }
        }
        return canonical.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .map { ($0.value, counts[$0.key] ?? 0) }
    }

    static func main() {
        var checksum = 0
        func body(_ count: Int) -> String {
            // Every ASCII letter is present: misses must exercise byte search,
            // not just the membership mask over an artificial one-letter body.
            String(String(repeating: "abcdefghijklmnopqrstuvwxyz ", count: (count + 26) / 27).prefix(count))
        }
        for count in [1_000, 10_000] {
            let bodyBytes = count == 1_000 ? 4_096 : 512
            let snippets = (0..<count).map { i in
                Snippet(name: "\(i.isMultiple(of: 5) ? "Ghost" : "Project") \(i)",
                    keyword: "\(i.isMultiple(of: 5) ? "ghost" : "project").\(i)",
                    content: body(bodyBytes) + "\(i)", tags: ["Work", "tag\(i % 8)"],
                    isPinned: i.isMultiple(of: 9), createdAt: Date(timeIntervalSince1970: Double(i)))
            }
            let reference = ReferenceSnippetSearchIndex()
            let current = SnippetSearchIndex()
            var projection = SnippetLibraryProjection()
            let cold = ContinuousClock.now
            let initial = projection.snapshot(ordinary: snippets, secure: [])
            _ = current.results(in: initial.sorted, searchText: "g", activeTagKeys: [])
            print(String(format: "library rows=%d body_bytes=%d prepare=%.3fms", count, bodyBytes, milliseconds(cold)))
            for query in ["g", "gh", "gho", "ghost", "ghx", "zz"] {
                var oldTimes: [Double] = [], newTimes: [Double] = []
                for iteration in 0..<23 {
                    // Each measured query adds one character. Repeating the exact
                    // same query would overstate narrowing, especially for misses.
                    _ = current.results(in: initial.sorted, searchText: String(query.dropLast()), activeTagKeys: [])
                    let oldStart = ContinuousClock.now
                    let tags = oldTagUsage(snippets)
                    let old = reference.results(in: SnippetDisplayOrder.sorted(snippets), searchText: query, activeTagKeys: [])
                    let oldTime = milliseconds(oldStart)
                    let newStart = ContinuousClock.now
                    let snapshot = projection.snapshot(ordinary: snippets, secure: [])
                    let new = current.results(in: snapshot.sorted, searchText: query, activeTagKeys: [])
                    let newTime = milliseconds(newStart)
                    precondition(old == new)
                    precondition(tags.map { $0.0 } == snapshot.tags && tags.map { $0.1 } == snapshot.tagUsage.map(\.count))
                    checksum &+= new.count + tags.count
                    if iteration >= 3 { oldTimes.append(oldTime); newTimes.append(newTime) }
                }
                report("library rows=\(count) query=\(query)", old: oldTimes, new: newTimes)
            }
            precondition(projection.buildCount == 1)
        }

        let clips = (0..<1_000).map { ClipboardHistoryEntry(text:
            ($0.isMultiple(of: 5) ? "Café token " : "Notes ") + body(4_096) + "\($0)") }
        var clipboard = ClipboardHistorySearchIndex()
        let cold = ContinuousClock.now
        _ = clipboard.results("c", in: clips)
        print(String(format: "clipboard rows=1000 body_bytes=4096 prepare=%.3fms", milliseconds(cold)))
        for query in ["c", "cafe", "cafe token", "zz"] {
            var oldTimes: [Double] = [], newTimes: [Double] = []
            for iteration in 0..<23 {
                let oldStart = ContinuousClock.now
                let old = ClipboardHistory.search(query, in: clips)
                let oldTime = milliseconds(oldStart)
                let newStart = ContinuousClock.now
                let new = clipboard.results(query, in: clips)
                let newTime = milliseconds(newStart)
                precondition(old == new)
                checksum &+= new.count
                if iteration >= 3 { oldTimes.append(oldTime); newTimes.append(newTime) }
            }
            report("clipboard rows=1000 query=\(query)", old: oldTimes, new: newTimes)
        }
        precondition(clipboard.preparedEntryCount == clips.count)

        let sources = (0..<1_000).map { SuggestionHighlightSource(query: .init("proj"),
            name: .init("Project \($0)"), keyword: .init("project.\($0)")) }
        var oldTimes: [Double] = [], newTimes: [Double] = []
        var workspace = FuzzyMatch.Workspace()
        for iteration in 0..<33 {
            let oldStart = ContinuousClock.now
            let all = sources.map { $0.resolve(workspace: &workspace) }
            let oldTime = milliseconds(oldStart)
            let newStart = ContinuousClock.now
            for source in sources {
                checksum &+= FuzzyMatch.score(query: source.query, target: source.name,
                    includingRanges: false, workspace: &workspace).score
                checksum &+= FuzzyMatch.score(query: source.query, target: source.keyword,
                    includingRanges: false, workspace: &workspace).score
            }
            let visible = sources.prefix(8).map { $0.resolve(workspace: &workspace) }
            let newTime = milliseconds(newStart)
            precondition(visible == Array(all.prefix(8)))
            if iteration >= 3 { oldTimes.append(oldTime); newTimes.append(newTime) }
        }
        report("picker matching+highlights rows=1000 visible=8", old: oldTimes, new: newTimes)
        print("checksum=\(checksum)")
    }
}
