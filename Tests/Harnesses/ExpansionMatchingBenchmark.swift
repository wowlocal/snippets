import Foundation

/// Synthetic metadata only; no store, AX, or AppKit. Compare the same workload
/// against an older FuzzyMatch.swift with the script's --baseline-ref option.
@main
enum ExpansionMatchingBenchmark {
    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }

    static func report(_ label: String, samples: [Double], checksum: Int) {
        let sorted = samples.sorted()
        let n = sorted.count
        let median = (sorted[(n - 1) / 2] + sorted[n / 2]) / 2
        let p95 = sorted[Int(ceil(Double(n) * 0.95)) - 1]
        print(String(format: "%@ p50=%.3fms p95=%.3fms checksum=%d", label, median, p95, checksum))
    }

    static func main() {
        for corpus in ["ascii", "unicode"] {
            for count in [100, 1_000] {
                let fixtures = (0..<count).map { i in
                    corpus == "ascii" ? ("Project \(i) link", "project.\(i)")
                        : ("Проект \(i) café", "проект.\(i)")
                }
                let queries = corpus == "ascii" ? ["p", "pr", "proj", "zz"] : ["п", "пр", "cafe", "zz"]
                #if PREPARED_FUZZY_BENCHMARK
                let start = ContinuousClock.now
                let prepared = fixtures.map { (FuzzyMatch.PreparedTarget($0.0), FuzzyMatch.PreparedTarget($0.1)) }
                print(String(format: "prepare corpus=%@ rows=%d duration=%.3fms", corpus, count, milliseconds(start)))
                #endif
                for query in queries {
                    var samples: [Double] = []
                    var checksum = 0
                    for iteration in 0..<35 {
                        let start = ContinuousClock.now
                        for fixture in fixtures {
                            let a = FuzzyMatch.score(query: query, target: fixture.0)
                            let b = FuzzyMatch.score(query: query, target: fixture.1)
                            checksum &+= a.score &+ b.score &+ (a.matched ? 1 : 0) &+ (b.matched ? 1 : 0)
                        }
                        let elapsed = milliseconds(start)
                        if iteration >= 5 { samples.append(elapsed) }
                    }
                    let label = "corpus=\(corpus) rows=\(count) query=\(query)"
                    report("oneshot \(label)", samples: samples, checksum: checksum)
                    #if PREPARED_FUZZY_BENCHMARK
                    var warmSamples: [Double] = []
                    var warmChecksum = 0
                    var highlightChecksum = 0
                    var workspace = FuzzyMatch.Workspace()
                    for iteration in 0..<35 {
                        let start = ContinuousClock.now
                        let needle = FuzzyMatch.PreparedQuery(query)
                        for fixture in prepared {
                            let a = FuzzyMatch.score(query: needle, target: fixture.0, includingRanges: false, workspace: &workspace)
                            let b = FuzzyMatch.score(query: needle, target: fixture.1, includingRanges: false, workspace: &workspace)
                            warmChecksum &+= a.score &+ b.score &+ (a.matched ? 1 : 0) &+ (b.matched ? 1 : 0)
                        }
                        // All generated rows tie; highlight the first visible eight.
                        for fixture in prepared.prefix(8) {
                            highlightChecksum &+= FuzzyMatch.score(query: needle, target: fixture.0, workspace: &workspace).matchedRanges.count
                            highlightChecksum &+= FuzzyMatch.score(query: needle, target: fixture.1, workspace: &workspace).matchedRanges.count
                        }
                        let elapsed = milliseconds(start)
                        if iteration >= 5 { warmSamples.append(elapsed) }
                    }
                    precondition(warmChecksum == checksum)
                    report("prepared \(label)", samples: warmSamples, checksum: warmChecksum)
                    print("highlightChecksum=\(highlightChecksum)")
                    #endif
                }
            }
        }
    }
}
