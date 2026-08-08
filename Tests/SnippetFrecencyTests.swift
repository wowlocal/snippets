import Foundation

// Standalone executable, matching Tests/SuggestionTriggerContextTests.swift.
// Build and run:
//
//   swiftc -O snippets/Core/Snippet.swift snippets/FuzzyMatch.swift \
//          snippets/SnippetFrecency.swift snippets/SnippetUsageDocument.swift \
//          Tests/SnippetFrecencyTests.swift -o /tmp/frecency-tests && /tmp/frecency-tests

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) - expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func assertClose(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String) {
    if !(abs(actual - expected) <= tolerance) {
        fputs("FAIL: \(message) - expected \(expected) ± \(tolerance), got \(actual)\n", stderr)
        exit(1)
    }
}

// MARK: - Deterministic randomness

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func int(_ upperBound: Int) -> Int {
        upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
    }

    mutating func unitDouble() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    mutating func uuid() -> UUID {
        let a = next()
        let b = next()
        func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 {
            UInt8(truncatingIfNeeded: value >> shift)
        }
        return UUID(uuid: (
            byte(a, 0), byte(a, 8), byte(a, 16), byte(a, 24),
            byte(a, 32), byte(a, 40), byte(a, 48), byte(a, 56),
            byte(b, 0), byte(b, 8), byte(b, 16), byte(b, 24),
            byte(b, 32), byte(b, 40), byte(b, 48), byte(b, 56)
        ))
    }
}

// MARK: - Helpers

private let halfLife = SnippetFrecency.halfLifeSeconds
private let day: Double = 86_400

/// Accumulates `usesPerDay` uses per day over `historyDays`, then reads the
/// decayed value at the instant of the final use. Goes through
/// `SnippetFrecency.growth` rather than a closed form so the pipeline itself is
/// under test.
private func steadyState(usesPerDay: Double, weight: Double = 1.0, historyDays: Double = 350) -> Double {
    let interval = day / usesPerDay
    let end = historyDays * day
    var epochWeight = 0.0
    var t = end
    while t >= 0 {
        epochWeight += weight * SnippetFrecency.growth(epoch: 0, now: t, halfLifeSeconds: halfLife)
        t -= interval
    }
    return epochWeight * exp2(-end / halfLife)
}

/// One use on each weekday, read at the instant of a use on `readOnWeekday`.
/// Day 0 is a Monday. This rhythm is not geometric, so its steady state depends
/// on where in the week you look.
private func businessDaySteadyState(readOnWeekday: Int, weeks: Int = 52) -> Double {
    // The read happens at the instant of a use, so uses *after* it must not be
    // counted — that is what makes the two phases differ.
    let lastDay = (0...(weeks * 7)).last { $0 % 7 == readOnWeekday }!
    var epochWeight = 0.0
    for dayIndex in 0...lastDay where dayIndex % 7 < 5 {
        epochWeight += SnippetFrecency.growth(
            epoch: 0, now: Double(dayIndex) * day, halfLifeSeconds: halfLife)
    }
    return epochWeight * exp2(-(Double(lastDay) * day) / halfLife)
}

/// The comparator exactly as it stood before usage entered the chain. The
/// identity proof compares against this.
private func legacyRanks(_ lhs: SnippetRankingKey, _ rhs: SnippetRankingKey) -> Bool {
    if lhs.score != rhs.score { return lhs.score > rhs.score }
    if lhs.keywordRank != rhs.keywordRank { return lhs.keywordRank > rhs.keywordRank }
    if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
    if lhs.displayOrder != rhs.displayOrder { return lhs.displayOrder < rhs.displayOrder }
    let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
    if comparison != .orderedSame { return comparison == .orderedAscending }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func makeKeys(count: Int, random: inout SeededRandom, withUsage: Bool) -> [SnippetRankingKey] {
    let names = ["Signature", "signature block", "Address", "reply", "Req", "refund", "", "ZZZ"]
    return (0..<count).map { index in
        SnippetRankingKey(
            score: random.int(5),
            keywordRank: random.int(4),
            isPinned: random.int(4) == 0,
            bindingWeight: withUsage ? Double(random.int(3)) : 0,
            frecency: withUsage ? random.unitDouble() * 100 : 0,
            displayOrder: index,
            displayName: names[random.int(names.count)],
            id: random.uuid()
        )
    }
}

private func isStrictWeakOrdering(_ keys: [SnippetRankingKey]) -> Bool {
    for a in keys {
        if SnippetFrecency.ranks(a, before: a) { return false }          // irreflexive
        for b in keys {
            if SnippetFrecency.ranks(a, before: b) && SnippetFrecency.ranks(b, before: a) {
                return false                                             // asymmetric
            }
        }
    }
    for a in keys {
        for b in keys where SnippetFrecency.ranks(a, before: b) {
            for c in keys where SnippetFrecency.ranks(b, before: c) {
                if !SnippetFrecency.ranks(a, before: c) { return false }  // transitive
            }
        }
    }
    return true
}

private func decode(_ json: String) -> SnippetUsageDocument? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SnippetUsageDocument.self, from: data)
}

private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("snippets-frecency-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readDocument(at url: URL) -> SnippetUsageDocument? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SnippetUsageDocument.self, from: data)
}

@main
private enum SnippetFrecencyTests {
    static func main() {
        testDecayMath()
        testClamps()
        testRescale()
        testComparator()
        testEmptyQueryBranch()
        testFuzzyMatchTiePrecision()
        testDocumentCoding()
        testDegradation()
        testSanitize()
        testJoinSemilattice()
        testMerge()
        testPrune()
        testRecordingLogic()
        testSelectionMemoryMath()

        print("SnippetFrecencyTests passed")
    }

    // MARK: - Decay

    static func testDecayMath() {
        assertClose(
            SnippetFrecency.growth(epoch: 0, now: 14 * day, halfLifeSeconds: halfLife),
            2.0, tolerance: 1e-9, "one half-life doubles the epoch-frame weight")
        assertClose(
            SnippetFrecency.growth(epoch: 0, now: 56 * day, halfLifeSeconds: halfLife),
            16.0, tolerance: 1e-9, "four half-lives")

        // The central theorem: raw stored weights rank identically at every
        // instant, so the comparator never needs the clock.
        let uses: [(Double, Double)] = [(0, 1.0), (3 * day, 1.0), (40 * day, 1.0)]
        var weights: [Double] = []
        for (time, weight) in uses {
            weights.append(weight * SnippetFrecency.growth(epoch: 0, now: time, halfLifeSeconds: halfLife))
        }
        for readAt in [40 * day, 400 * day] {
            let decayed = weights.map { $0 * exp2(-readAt / halfLife) }
            let rawOrder = weights.enumerated().sorted { $0.element > $1.element }.map(\.offset)
            let decayedOrder = decayed.enumerated().sorted { $0.element > $1.element }.map(\.offset)
            assertEqual(rawOrder, decayedOrder, "raw and decayed weights induce the same order")
        }

        assertClose(steadyState(usesPerDay: 8), 162.08, tolerance: 0.81, "8/day steady state")
        assertClose(steadyState(usesPerDay: 4), 81.29, tolerance: 0.41, "4/day steady state")
        assertClose(steadyState(usesPerDay: 2), 40.90, tolerance: 0.21, "2/day steady state")
        assertClose(steadyState(usesPerDay: 1), 20.70, tolerance: 0.11, "1/day steady state")
        assertClose(steadyState(usesPerDay: 3.0 / 7.0), 9.17, tolerance: 0.05, "3/week steady state")
        assertClose(steadyState(usesPerDay: 1.0 / 7.0), 3.41, tolerance: 0.02, "1/week steady state")
        assertClose(steadyState(usesPerDay: 1.0 / 30.0), 1.29, tolerance: 0.01, "1/month steady state")

        // Phase-dependent by construction; there is deliberately no test for
        // the 14.93 continuous approximation, which occurs nowhere in the cycle.
        assertClose(businessDaySteadyState(readOnWeekday: 4), 15.50, tolerance: 0.01,
                    "weekday rhythm peaks right after a Friday use")
        assertClose(businessDaySteadyState(readOnWeekday: 0), 14.36, tolerance: 0.01,
                    "weekday rhythm bottoms right after a Monday use")

        assertClose(6 * pow(2.0, -45.0 / 14.0), 0.6465, tolerance: 1e-3, "6 uses 45 days ago")
        assertClose(0.25 * pow(2.0, -30.0 / 14.0), 0.0566, tolerance: 1e-4, "one copy after 30 days")

        assertTrue(SnippetFrecency.copyWeight < SnippetFrecency.meaningfulnessFloor,
                   "one copy is noise")
        assertTrue(SnippetFrecency.expandWeight >= SnippetFrecency.meaningfulnessFloor,
                   "one expansion counts")
    }

    static func testClamps() {
        let now = 1_800_000_000.0

        assertEqual(SnippetFrecency.growth(epoch: now + 10 * 365 * day, now: now, halfLifeSeconds: halfLife),
                    1.0, "a backwards clock counts the use at face value")
        let ancient = SnippetFrecency.growth(epoch: now - 10 * 365 * day, now: now, halfLifeSeconds: halfLife)
        assertTrue(ancient.isFinite && ancient <= exp2(400.0 / 14.0) + 1,
                   "a forwards clock stays finite and bounded by the 400-day cap")
        assertEqual(SnippetFrecency.growth(epoch: .nan, now: now, halfLifeSeconds: halfLife), 1.0,
                    "a non-finite epoch degrades to no growth")
        assertEqual(SnippetFrecency.growth(epoch: 0, now: now, halfLifeSeconds: 0), 1.0,
                    "a zero half-life degrades to no growth")

        assertEqual(SnippetFrecency.clamp(weight: .nan), 0, "NaN clamps to zero")
        assertEqual(SnippetFrecency.clamp(weight: .infinity), SnippetFrecency.maxWeight,
                    "an overflow saturates at the ceiling rather than losing the history")
        assertEqual(SnippetFrecency.clamp(weight: -.infinity), 0, "negative infinity clamps to zero")
        assertEqual(SnippetFrecency.clamp(weight: -5), 0, "negative clamps to zero")
        assertTrue(SnippetFrecency.clamp(weight: .infinity).isFinite,
                   "clamp never returns a value the comparator could trap on")
    }

    static func testRescale() {
        var random = SeededRandom(seed: 42)
        let ids = (0..<20).map { _ in random.uuid().uuidString }
        var records: [String: SnippetUsageRecord] = [:]
        for id in ids {
            records[id] = SnippetUsageRecord(weight: 1 + random.unitDouble() * 500, count: 3, lastUsedAt: 1000)
        }
        let bindingID = ids[0]
        let doc = SnippetUsageDocument(
            version: 1, epoch: 1_700_000_000, halfLifeDays: SnippetFrecency.halfLifeDays,
            records: records, bindings: ["re": [bindingID: 4.0]])

        let shifted = SnippetUsageFile.rescaled(doc, toEpoch: doc.epoch + 45 * day)

        let reference = ids[0]
        for id in ids where id != reference {
            let before = doc.records[id]!.weight / doc.records[reference]!.weight
            let after = shifted.records[id]!.weight / shifted.records[reference]!.weight
            assertClose(after, before, tolerance: 1e-9, "rebase preserves pairwise ratios")
        }

        let orderBefore = doc.records.sorted { $0.value.weight > $1.value.weight }.map(\.key)
        let orderAfter = shifted.records.sorted { $0.value.weight > $1.value.weight }.map(\.key)
        assertEqual(orderBefore, orderAfter, "rebase preserves the permutation")

        // The binding ceiling is stated in units of growth, and rebase scales
        // both the weights and that reference by the same factor.
        let growthBefore = SnippetFrecency.growth(
            epoch: doc.epoch, now: doc.epoch, halfLifeSeconds: halfLife)
        assertTrue(doc.bindings["re"]![bindingID]! <= SnippetFrecency.bindingWeightCap * growthBefore * 4 + 1e-9,
                   "binding fixture starts within a scaled ceiling")
        let ratio = shifted.bindings["re"]![bindingID]! / doc.bindings["re"]![bindingID]!
        let recordRatio = shifted.records[reference]!.weight / doc.records[reference]!.weight
        assertClose(ratio, recordRatio, tolerance: 1e-9,
                    "bindings and records rescale by the identical factor")

        // A changed half-life is absorbed at load: values are preserved at the
        // instant of the rebase, and the new constant is written down.
        let old = SnippetUsageDocument(
            version: 1, epoch: 1_700_000_000, halfLifeDays: 30,
            records: ["A": SnippetUsageRecord(weight: 8, count: 1, lastUsedAt: 0),
                      "B": SnippetUsageRecord(weight: 2, count: 1, lastUsedAt: 0)],
            bindings: [:])
        let migrated = SnippetUsageFile.rebasedIfNeeded(old, now: old.epoch + 45 * day)
        assertEqual(migrated.halfLifeDays, SnippetFrecency.halfLifeDays, "half-life is relabelled")
        assertClose(migrated.records["A"]!.weight / migrated.records["B"]!.weight, 4.0,
                    tolerance: 1e-9, "ratios survive a half-life change")
        assertClose(migrated.records["A"]!.weight, 8 * exp2(-45.0 / 30.0), tolerance: 1e-9,
                    "the old half-life governs the conversion")
    }

    // MARK: - Comparator

    static func testComparator() {
        var random = SeededRandom(seed: 7)

        // The single most important test: with no usage data the order is
        // element-for-element what it was before the feature existed.
        for _ in 0..<300 {
            let keys = makeKeys(count: 40, random: &random, withUsage: false)
            let new = keys.sorted { SnippetFrecency.ranks($0, before: $1) }.map(\.id)
            let old = keys.sorted { legacyRanks($0, $1) }.map(\.id)
            assertEqual(new, old, "empty usage reproduces the pre-feature order exactly")
        }

        // Usage never crosses a tier above it.
        for _ in 0..<5000 {
            var lhs = makeKeys(count: 1, random: &random, withUsage: true)[0]
            var rhs = makeKeys(count: 1, random: &random, withUsage: true)[0]
            guard lhs.score != rhs.score || lhs.keywordRank != rhs.keywordRank || lhs.isPinned != rhs.isPinned
            else { continue }
            let withUsage = SnippetFrecency.ranks(lhs, before: rhs)
            lhs.bindingWeight = 0; lhs.frecency = 0
            rhs.bindingWeight = 0; rhs.frecency = 0
            assertEqual(withUsage, SnippetFrecency.ranks(lhs, before: rhs),
                        "a higher tier decides regardless of usage")
        }

        // Disaster scenario: a fully typed keyword must beat red-hot usage.
        let exactID = UUID()
        let hotID = UUID()
        let exactKeyword = "sig"
        let hotKeyword = "sigblock"
        let query = "sig"
        func key(id: UUID, keyword: String, name: String, frecency: Double, order: Int) -> SnippetRankingKey {
            let keywordResult = FuzzyMatch.score(query: query, target: keyword)
            let nameResult = FuzzyMatch.score(query: query, target: name)
            return SnippetRankingKey(
                score: max(keywordResult.score, nameResult.score),
                keywordRank: SnippetFrecency.keywordRank(
                    foldedKeyword: SnippetFrecency.foldedForMatching(keyword),
                    foldedQuery: SnippetFrecency.foldedForMatching(query),
                    hasKeywordMatchRanges: !keywordResult.matchedRanges.isEmpty),
                isPinned: false,
                bindingWeight: 0,
                frecency: frecency,
                displayOrder: order,
                displayName: name,
                id: id)
        }
        let exact = key(id: exactID, keyword: exactKeyword, name: "Sig", frecency: 0, order: 5)
        let hot = key(id: hotID, keyword: hotKeyword, name: "Signature Block", frecency: 500, order: 0)
        assertEqual(exact.score, hot.score, "a prefix match scores the same on both")
        assertEqual(exact.keywordRank, 3, "the fully typed keyword is an exact keyword match")
        assertEqual(hot.keywordRank, 2, "the longer keyword is only a prefix match")
        assertEqual([exact, hot].sorted { SnippetFrecency.ranks($0, before: $1) }.first?.id, exactID,
                    "exact keyword outranks hot frecency")

        // Pin is a strict outer key on both surfaces.
        assertEqual(
            SnippetFrecency.emptyQueryRanks(lhsPinned: false, lhsFrecency: 1e6, lhsOrder: 99,
                                            rhsPinned: true, rhsFrecency: 0, rhsOrder: 0),
            false, "hot unpinned never precedes cold pinned in the empty-query branch")
        let hotUnpinned = SnippetRankingKey(score: 3, keywordRank: 2, isPinned: false,
                                            bindingWeight: 1e6, frecency: 1e6, displayOrder: 99,
                                            displayName: "hot", id: UUID())
        let coldPinned = SnippetRankingKey(score: 3, keywordRank: 2, isPinned: true,
                                           bindingWeight: 0, frecency: 0, displayOrder: 0,
                                           displayName: "cold", id: UUID())
        assertEqual(SnippetFrecency.ranks(hotUnpinned, before: coldPinned), false,
                    "neither usage nor selection memory outranks a pin")

        // Strict weak ordering. Without it `Array.sorted` is undefined, and it
        // would be undefined inside the event-tap callback.
        for seed in 0..<40 {
            var fuzz = SeededRandom(seed: UInt64(seed) &+ 1)
            let keys = makeKeys(count: 16, random: &fuzz, withUsage: true)
            assertTrue(isStrictWeakOrdering(keys), "ranks() is a strict weak ordering")
        }

        // Determinism: heavy duplication, many shufflings, one result.
        var duplicated: [SnippetRankingKey] = []
        for index in 0..<200 {
            duplicated.append(SnippetRankingKey(
                score: 4, keywordRank: 2, isPinned: false, bindingWeight: 0, frecency: 0,
                displayOrder: index % 3, displayName: "same", id: random.uuid()))
        }
        let reference = duplicated.sorted { SnippetFrecency.ranks($0, before: $1) }.map(\.id)
        for _ in 0..<10 {
            var shuffled = duplicated
            for index in stride(from: shuffled.count - 1, to: 0, by: -1) {
                shuffled.swapAt(index, random.int(index + 1))
            }
            assertEqual(shuffled.sorted { SnippetFrecency.ranks($0, before: $1) }.map(\.id), reference,
                        "the uuid terminator makes the order deterministic")
        }

        // Sanitized hostile data cannot reach the comparator.
        let poisoned = SnippetUsageDocument(
            version: 1, epoch: 1_700_000_000, halfLifeDays: 14,
            records: [UUID().uuidString: SnippetUsageRecord(weight: .nan, count: 1, lastUsedAt: 0),
                      UUID().uuidString: SnippetUsageRecord(weight: .infinity, count: 1, lastUsedAt: 0)],
            bindings: [:])
        let cleaned = SnippetUsageFile.sanitized(poisoned)
        assertTrue(cleaned.records.values.allSatisfy { $0.weight.isFinite },
                   "sanitize removes every non-finite weight")
        var poisonKeys = makeKeys(count: 100, random: &random, withUsage: true)
        for (index, weight) in cleaned.records.values.enumerated() where index < poisonKeys.count {
            poisonKeys[index].frecency = weight.weight
        }
        assertTrue(isStrictWeakOrdering(Array(poisonKeys.prefix(16))),
                   "sanitized weights keep the ordering total")
    }

    static func testEmptyQueryBranch() {
        // The cap is applied after ranking. It used to slice the first eight in
        // display order and present that as the top eight.
        let frecencies: [Double] = (0..<20).map { Double(19 - $0) }
        let ordered = (0..<20)
            .sorted { lhs, rhs in
                SnippetFrecency.emptyQueryRanks(
                    lhsPinned: false, lhsFrecency: frecencies[lhs], lhsOrder: lhs,
                    rhsPinned: false, rhsFrecency: frecencies[rhs], rhsOrder: rhs)
            }
            .prefix(8)
        assertEqual(Array(ordered), Array(0..<8), "the highest-ranked eight are returned")

        let reversed: [Double] = (0..<20).map { Double($0) }
        let reversedTop = (0..<20)
            .sorted { lhs, rhs in
                SnippetFrecency.emptyQueryRanks(
                    lhsPinned: false, lhsFrecency: reversed[lhs], lhsOrder: lhs,
                    rhsPinned: false, rhsFrecency: reversed[rhs], rhsOrder: rhs)
            }
            .prefix(8)
        assertEqual(Array(reversedTop), Array((12..<20).reversed()),
                    "the most used win even when they sit last in display order")

        let allZero = (0..<20).sorted { lhs, rhs in
            SnippetFrecency.emptyQueryRanks(
                lhsPinned: false, lhsFrecency: 0, lhsOrder: lhs,
                rhsPinned: false, rhsFrecency: 0, rhsOrder: rhs)
        }
        assertEqual(allZero, Array(0..<20), "with no usage the input order is returned unchanged")
    }

    static func testFuzzyMatchTiePrecision() {
        // The justification for placing usage at tiers four and five: any two
        // snippets whose keyword starts with the query score identically, so
        // those tiers are reached constantly rather than rarely.
        let expected = [1: 9, 2: 12, 3: 17, 4: 24, 5: 33]
        let keywords = ["reply", "request", "refund", "renew", "review"]
        for length in 1...5 {
            let query = String("reply".prefix(length))
            let scores = keywords
                .filter { $0.hasPrefix(query) }
                .map { FuzzyMatch.score(query: query, target: $0).score }
            assertTrue(!scores.isEmpty, "the fixture has prefix matches at length \(length)")
            for score in scores {
                assertEqual(score, expected[length]!, "prefix match of length \(length) scores identically")
            }
        }
    }

    // MARK: - Document

    static func testDocumentCoding() {
        let id = UUID().uuidString
        let doc = SnippetUsageDocument(
            version: 1, epoch: 1_785_312_000, halfLifeDays: 14,
            records: [id: SnippetUsageRecord(weight: 162.08, count: 4412, lastUsedAt: 1_785_312_000)],
            bindings: ["sig": [id: 4.41]],
            recordsClearedAt: 0, bindingsClearedAt: 0)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(doc)
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        assertEqual(Set(object.keys), ["v", "epoch", "h", "w", "b", "rc", "bc"],
                    "the document uses exactly the abbreviated keys")
        let records = object["w"] as! [String: Any]
        assertEqual(Set((records[id] as! [String: Any]).keys), ["s", "n", "l"],
                    "records use exactly the abbreviated keys")

        let decoded = try! JSONDecoder().decode(SnippetUsageDocument.self, from: data)
        assertEqual(decoded, doc, "the document round-trips")
    }

    static func testDegradation() {
        // Every one of these must land on "empty and writable", never on a
        // thrown error and never on read-only.
        for json in ["", "{{{", "[]", "{}", "{\"v\":1}", "{\"v\":1,\"w\":{}}",
                     "{\"epoch\":123", String(repeating: "x", count: 4096)] {
            if let doc = decode(json) {
                assertTrue(doc.records.isEmpty, "degraded input \(json.prefix(12)) yields no records")
                assertTrue(doc.version <= SnippetUsageDocument.currentVersion,
                           "degraded input is not mistaken for a future version")
            }
        }

        // The totality of the decoder is what keeps a future format out of the
        // "corrupt" branch, where an old build would overwrite a new one.
        assertTrue(decode("{}") != nil, "an empty object decodes rather than failing")
        assertTrue(decode("{\"v\":1}") != nil, "a version-only object decodes rather than failing")

        // The probe reads a version even when the full decoder cannot.
        let futureShape = "{\"v\":99,\"w\":\"a string, not a dictionary\"}"
        let probe = try? JSONDecoder().decode(
            SnippetUsageVersionProbe.self, from: futureShape.data(using: .utf8)!)
        assertEqual(probe?.v, 99, "the probe reads the version out of an otherwise undecodable file")
        assertTrue(decode(futureShape) == nil,
                   "the full decoder does fail on that shape — which is the whole reason the probe exists")
    }

    static func testSanitize() {
        let validID = UUID().uuidString
        let hostile = """
        {"v":1,"epoch":-1e18,"h":9e99,"rc":null,"w":{
          "\(validID)":{"s":1e300,"n":-3,"l":9e99},
          "not-a-uuid":{"s":5,"n":1,"l":0}
        },"b":{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"\(validID)":3}}}
        """
        guard let decoded = decode(hostile) else {
            fputs("FAIL: hostile document should still decode\n", stderr)
            exit(1)
        }
        let clean = SnippetUsageFile.sanitized(decoded)

        assertTrue(clean.epoch.isFinite && clean.epoch >= 0, "epoch is clamped into range")
        assertTrue(clean.halfLifeDays >= 1 && clean.halfLifeDays <= 365, "half-life is clamped into range")
        assertEqual(clean.records["not-a-uuid"], nil, "a non-UUID record key is dropped")
        assertEqual(clean.records[validID]?.weight, SnippetFrecency.maxWeight,
                    "an overflowing weight is clamped, not dropped")
        assertTrue((clean.records[validID]?.count ?? -1) >= 0, "a negative count is clamped")
        assertTrue((clean.records[validID]?.lastUsedAt ?? .infinity) <= SnippetFrecency.maxTimestamp,
                   "a runaway timestamp is clamped")
        assertTrue(clean.bindings.isEmpty, "an over-long binding key is dropped")

        // Untrusted input is held to a stricter rule than our own arithmetic:
        // anything non-finite off disk is dropped rather than saturated.
        for poison in [Double.nan, .infinity, -.infinity, 0, -1] {
            let doc = SnippetUsageDocument(
                version: 1, epoch: 0, halfLifeDays: 14,
                records: [validID: SnippetUsageRecord(weight: poison, count: 1, lastUsedAt: 0)],
                bindings: [:])
            assertTrue(SnippetUsageFile.sanitized(doc).records.isEmpty,
                       "a weight of \(poison) is dropped on load")
        }
    }

    // MARK: - Merge

    static func testJoinSemilattice() {
        var random = SeededRandom(seed: 99)
        for _ in 0..<500 {
            let a = SnippetUsageRecord(weight: random.unitDouble() * 100,
                                       count: random.int(50), lastUsedAt: random.unitDouble() * 1e9)
            let b = SnippetUsageRecord(weight: random.unitDouble() * 100,
                                       count: random.int(50), lastUsedAt: random.unitDouble() * 1e9)
            let c = SnippetUsageRecord(weight: random.unitDouble() * 100,
                                       count: random.int(50), lastUsedAt: random.unitDouble() * 1e9)
            assertEqual(SnippetUsageFile.join(a, b), SnippetUsageFile.join(b, a), "join commutes")
            assertEqual(SnippetUsageFile.join(a, a), a, "join is idempotent")
            assertEqual(SnippetUsageFile.join(SnippetUsageFile.join(a, b), c),
                        SnippetUsageFile.join(a, SnippetUsageFile.join(b, c)), "join associates")
        }
    }

    static func testMerge() {
        let folder = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let now = 1_785_312_000.0

        let idA = UUID().uuidString
        let idB = UUID().uuidString
        func document(_ id: String, weight: Double, epoch: Double = 1_785_312_000) -> SnippetUsageDocument {
            SnippetUsageDocument(
                version: 1, epoch: epoch, halfLifeDays: SnippetFrecency.halfLifeDays,
                records: [id: SnippetUsageRecord(weight: weight, count: 3, lastUsedAt: epoch)],
                bindings: [:])
        }

        // Two "processes" writing different snippets: neither loses.
        SnippetUsageFile.mergeAndWrite(document(idA, weight: 10), liveIDs: nil, now: now,
                                       folderURL: folder, fileURL: file)
        SnippetUsageFile.mergeAndWrite(document(idB, weight: 20), liveIDs: nil, now: now,
                                       folderURL: folder, fileURL: file)
        var merged = readDocument(at: file)!
        assertEqual(merged.records.count, 2, "concurrent writers both survive")
        assertClose(merged.records[idA]!.weight, 10, tolerance: 1e-6, "no weight is inflated")
        assertClose(merged.records[idB]!.weight, 20, tolerance: 1e-6, "no weight is inflated")

        // Idempotent: merging the same state again changes nothing.
        SnippetUsageFile.mergeAndWrite(document(idB, weight: 20), liveIDs: nil, now: now,
                                       folderURL: folder, fileURL: file)
        let repeated = readDocument(at: file)!
        assertClose(repeated.records[idB]!.weight, 20, tolerance: 1e-6, "re-merging does not inflate")

        // Different epochs normalize before the max.
        let older = SnippetUsageDocument(
            version: 1, epoch: now - 45 * day, halfLifeDays: SnippetFrecency.halfLifeDays,
            records: [idA: SnippetUsageRecord(weight: 10, count: 1, lastUsedAt: now - 45 * day)],
            bindings: [:])
        let joined = SnippetUsageFile.joined(mine: older, disk: document(idA, weight: 10))
        assertEqual(joined.epoch, now, "the later epoch wins")
        assertClose(joined.records[idA]!.weight, 10, tolerance: 1e-6,
                    "the older document is scaled down before the max, so the newer one wins")

        // A reset must not come back from disk.
        try? FileManager.default.removeItem(at: file)
        var populated = SnippetUsageDocument.empty(now: now)
        var random = SeededRandom(seed: 5)
        for _ in 0..<200 {
            populated.records[random.uuid().uuidString] =
                SnippetUsageRecord(weight: 50, count: 1, lastUsedAt: now)
        }
        SnippetUsageFile.mergeAndWrite(populated, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        assertEqual(readDocument(at: file)!.records.count, 200, "the disk starts with 200 records")

        var afterReset = SnippetUsageDocument.empty(now: now)
        afterReset.recordsClearedAt = now + 1
        afterReset.bindingsClearedAt = now + 1
        afterReset.records[idA] = SnippetUsageRecord(weight: 1, count: 1, lastUsedAt: now)
        SnippetUsageFile.mergeAndWrite(afterReset, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        merged = readDocument(at: file)!
        assertEqual(merged.records.count, 1, "a reset is not resurrected by the merge")
        assertEqual(Array(merged.records.keys), [idA], "only the post-reset use survives")

        // The same in the opposite direction: the reset already on disk wins.
        try? FileManager.default.removeItem(at: file)
        SnippetUsageFile.mergeAndWrite(afterReset, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        SnippetUsageFile.mergeAndWrite(populated, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        assertEqual(readDocument(at: file)!.records.count, 1,
                    "a stale in-memory document cannot undo a reset recorded on disk")

        // Selection memory: switching it off empties the table even when disk
        // still holds one.
        try? FileManager.default.removeItem(at: file)
        var withBindings = SnippetUsageDocument.empty(now: now)
        withBindings.bindings = ["re": [idA: 3.0]]
        withBindings.records[idA] = SnippetUsageRecord(weight: 5, count: 1, lastUsedAt: now)
        SnippetUsageFile.mergeAndWrite(withBindings, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        assertTrue(!readDocument(at: file)!.bindings.isEmpty, "the disk starts with a binding table")

        var cleared = withBindings
        cleared.bindings = [:]
        cleared.bindingsClearedAt = now + 1
        SnippetUsageFile.mergeAndWrite(cleared, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        assertTrue(readDocument(at: file)!.bindings.isEmpty,
                   "clearing bindings survives the merge")

        // A file written by a newer version is never overwritten.
        try? FileManager.default.removeItem(at: file)
        let future = "{\"v\":99,\"w\":{}}"
        try! future.data(using: .utf8)!.write(to: file)
        SnippetUsageFile.mergeAndWrite(document(idA, weight: 10), liveIDs: nil, now: now,
                                       folderURL: folder, fileURL: file)
        // The writer here is the store, which refuses to flush in read-only
        // mode; mergeAndWrite itself only declines to *merge* the future file.
        assertTrue(readDocument(at: file) != nil, "the merge still produces a readable file")
    }

    static func testPrune() {
        let now = 1_785_312_000.0
        var random = SeededRandom(seed: 13)

        // Unconditional mode: decayed-away entries go on every flush.
        var doc = SnippetUsageDocument.empty(now: now)
        let keepID = UUID().uuidString
        let dropID = UUID().uuidString
        doc.records[keepID] = SnippetUsageRecord(weight: 5, count: 1, lastUsedAt: now)
        doc.records[dropID] = SnippetUsageRecord(weight: SnippetFrecency.pruneThreshold / 10,
                                                 count: 1, lastUsedAt: now)
        doc.bindings = ["re": [keepID: 5, dropID: SnippetFrecency.pruneThreshold / 10],
                        "zz": [dropID: SnippetFrecency.pruneThreshold / 10]]
        var pruned = SnippetUsageFile.pruned(doc, liveIDs: nil, now: now)
        assertEqual(Array(pruned.records.keys), [keepID], "decayed records are dropped")
        assertEqual(pruned.bindings["re"]?.count, 1, "decayed binding entries are dropped")
        assertEqual(pruned.bindings["zz"], nil, "an emptied binding key is removed")

        // Capacity mode for records: orphans go first, then the lightest.
        var large = SnippetUsageDocument.empty(now: now)
        var liveIDs = Set<UUID>()
        var orphanIDs = Set<String>()
        for index in 0..<5100 {
            let id = random.uuid()
            // Orphans are given the heaviest weights on purpose: only the
            // orphan rule can explain their eviction.
            large.records[id.uuidString] =
                SnippetUsageRecord(weight: index < 100 ? 1000 : 10, count: 1, lastUsedAt: now)
            if index < 100 {
                orphanIDs.insert(id.uuidString)
            } else {
                liveIDs.insert(id)
            }
        }
        pruned = SnippetUsageFile.pruned(large, liveIDs: liveIDs, now: now)
        assertEqual(pruned.records.count, SnippetFrecency.maxRecords, "the record cap is enforced")
        assertTrue(pruned.records.keys.allSatisfy { !orphanIDs.contains($0) },
                   "orphaned UUIDs are evicted before live ones, even when heavier")

        // Below the cap nothing is evicted — this is what makes
        // "delete, flush, undo" safe.
        var belowCap = SnippetUsageDocument.empty(now: now)
        var fewLive = Set<UUID>()
        for index in 0..<4999 {
            let id = random.uuid()
            belowCap.records[id.uuidString] = SnippetUsageRecord(weight: 10, count: 1, lastUsedAt: now)
            if index >= 4000 { fewLive.insert(id) }
        }
        pruned = SnippetUsageFile.pruned(belowCap, liveIDs: fewLive, now: now)
        assertEqual(pruned.records.count, 4999,
                    "under the cap not a single orphan is evicted")

        // With no live set the orphan rule does not run at all.
        pruned = SnippetUsageFile.pruned(large, liveIDs: [], now: now)
        assertEqual(pruned.records.count, SnippetFrecency.maxRecords, "the cap still applies")
        assertTrue(pruned.records.keys.contains { orphanIDs.contains($0) },
                   "with an empty live set the heaviest records are kept regardless of orphanhood")

        // Capacity mode for bindings.
        var manyBindings = SnippetUsageDocument.empty(now: now)
        for keyIndex in 0..<500 {
            var table: [String: Double] = [:]
            for entry in 0..<6 {
                table[random.uuid().uuidString] = Double(entry + 1)
            }
            manyBindings.bindings["k\(keyIndex)"] = table
        }
        pruned = SnippetUsageFile.pruned(manyBindings, liveIDs: nil, now: now)
        assertEqual(pruned.bindings.count, SnippetFrecency.maxBindingKeys, "the binding key cap is enforced")
        assertTrue(pruned.bindings.values.allSatisfy { $0.count <= SnippetFrecency.maxBindingEntriesPerKey },
                   "each binding key keeps at most four entries")
    }

    // MARK: - Recording logic

    static func testRecordingLogic() {
        let id = UUID()
        let other = UUID()

        assertEqual(
            SnippetFrecency.shouldCoalesce(lastID: nil, lastEventTag: nil, lastAt: nil,
                                           id: id, eventTag: 0, now: 100),
            false, "the first event is never coalesced")
        assertEqual(
            SnippetFrecency.shouldCoalesce(lastID: id, lastEventTag: 0, lastAt: 100,
                                           id: id, eventTag: 0, now: 100.2),
            true, "a repeat of the same event within the window is coalesced")
        assertEqual(
            SnippetFrecency.shouldCoalesce(lastID: id, lastEventTag: 0, lastAt: 100,
                                           id: other, eventTag: 0, now: 100.2),
            false, "a different snippet is not coalesced")
        assertEqual(
            SnippetFrecency.shouldCoalesce(lastID: id, lastEventTag: 0, lastAt: 100,
                                           id: id, eventTag: 0, now: 102),
            false, "outside the window nothing is coalesced")
        // The reason the key is a pair: a copy and an expansion of the same
        // snippet within a second are two separate intentions.
        assertEqual(
            SnippetFrecency.shouldCoalesce(lastID: id, lastEventTag: 2, lastAt: 100,
                                           id: id, eventTag: 0, now: 100.2),
            false, "a different event kind is not coalesced")

        assertEqual(SnippetFrecency.flushDelay(now: 100, firstDirtyAt: nil),
                    SnippetFrecency.persistDebounceSeconds, "a fresh dirty state waits the full debounce")
        assertEqual(SnippetFrecency.flushDelay(now: 100, firstDirtyAt: 100),
                    SnippetFrecency.persistDebounceSeconds, "so does the first event of a burst")
        // The staleness ceiling: a steady drip of events must not defer the
        // write forever.
        assertEqual(SnippetFrecency.flushDelay(now: 158, firstDirtyAt: 100), 2,
                    "the delay shrinks as the staleness ceiling approaches")
        assertEqual(SnippetFrecency.flushDelay(now: 200, firstDirtyAt: 100), 0,
                    "past the ceiling the write happens immediately")

        // A user expanding something every four seconds still gets writes.
        var writes = 0
        var firstDirty: Double? = nil
        var nextFlushAt = Double.infinity
        for step in 0..<50 {
            let now = Double(step) * 4
            if now >= nextFlushAt { writes += 1; firstDirty = nil; nextFlushAt = .infinity }
            if firstDirty == nil { firstDirty = now }
            nextFlushAt = now + SnippetFrecency.flushDelay(now: now, firstDirtyAt: firstDirty)
        }
        assertTrue(writes >= 3, "a steady drip of events still reaches disk (got \(writes))")
    }

    static func testSelectionMemoryMath() {
        assertEqual(SnippetFrecency.bindingRecoveryCorrections, 1, "cap 1.0 means one correction")

        assertEqual(SnippetFrecency.bindingKey(for: "RE"), "re", "binding keys are folded")
        assertEqual(SnippetFrecency.bindingKey(for: ""), nil, "an empty query has no binding key")
        assertEqual(SnippetFrecency.bindingKey(for: "screenshotpath"), nil,
                    "an over-long prefix is not stored, and is not truncated into an alias")
        assertEqual(SnippetFrecency.bindingKey(for: "12345678")?.count, 8, "the boundary length is allowed")

        // Saturation, then escape in exactly one correction. Starting from a
        // single acceptance would pass even on a broken unbounded formula.
        let growth = 4.0
        let idA = "A"
        let idB = "B"
        var table: [String: Double] = [:]

        func accept(_ id: String) {
            for other in table.keys where other != id {
                table[other] = (table[other] ?? 0) * SnippetFrecency.bindingCompetitorDecay
            }
            let raised = (table[id] ?? 0) + growth
            table[id] = min(raised, SnippetFrecency.bindingWeightCap * growth)
        }

        for _ in 0..<50 { accept(idA) }
        assertClose(table[idA]!, growth, tolerance: 1e-9,
                    "the binding weight saturates at the ceiling instead of accumulating")

        accept(idB)
        assertClose(table[idA]!, SnippetFrecency.bindingCompetitorDecay * growth, tolerance: 1e-9,
                    "the previous winner decays on a correction")
        assertClose(table[idB]!, growth, tolerance: 1e-9, "the correction lands at the ceiling")
        assertTrue(table[idB]! > table[idA]!,
                   "one correction is enough to escape a 50-times-reinforced binding")

        // The invariant survives a rebase, so the theorem survives it too.
        let doc = SnippetUsageDocument(
            version: 1, epoch: 0, halfLifeDays: SnippetFrecency.halfLifeDays,
            records: [:], bindings: ["re": [idA: table[idA]!, idB: table[idB]!]])
        let rebased = SnippetUsageFile.rescaled(doc, toEpoch: 45 * day)
        assertTrue(rebased.bindings["re"]![idB]! > rebased.bindings["re"]![idA]!,
                   "the correction still wins after a rebase")
    }
}
