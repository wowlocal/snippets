import Foundation

/// Synthetic inputs only. Compile alongside the shipping FuzzyMatch implementation.
/// This measures two field matches per row, excluding store, ranking, AppKit, and AX.
@main
enum ExpansionMatchingBenchmark {
    static func main() {
        let clock = ContinuousClock()
        var checksum = 0
        for count in [100, 1_000] {
            let fixtures = (0..<count).map {
                (name: "Project \($0) link", keyword: "project.\($0)")
            }
            for query in ["p", "pr", "proj"] {
                var samples: [Double] = []
                for iteration in 0..<55 {
                    let start = clock.now
                    for fixture in fixtures {
                        let name = FuzzyMatch.score(query: query, target: fixture.name)
                        let keyword = FuzzyMatch.score(query: query, target: fixture.keyword)
                        checksum &+= name.score &+ keyword.score
                            &+ name.matchedRanges.count &+ keyword.matchedRanges.count
                    }
                    let duration = start.duration(to: clock.now).components
                    let milliseconds = Double(duration.seconds) * 1_000
                        + Double(duration.attoseconds) / 1e15
                    if iteration >= 5 { samples.append(milliseconds) }
                }
                samples.sort()
                print(String(format: "rows=%d queryLength=%d p50=%.3fms p95=%.3fms max=%.3fms",
                             count, query.count, (samples[24] + samples[25]) / 2,
                             samples[47], samples[49]))
            }
        }
        print("checksum=\(checksum)")
    }
}
