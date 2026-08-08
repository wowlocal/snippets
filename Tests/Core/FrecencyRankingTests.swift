import Foundation
import Testing

@testable import SnippetsCore

// Ported from the standalone `Tests/SnippetFrecencyTests.swift` executable. Every
// assertion message is the original one, because each names the property being
// pinned rather than the code path it happens to walk.

// MARK: - Assertions

/// The legacy `assertClose`, kept so every tolerance and every message from the
/// standalone executable survives the port unchanged.
private func expectClose(
    _ actual: Double, _ expected: Double, tolerance: Double, _ message: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual - expected) <= tolerance,
        "\(message) - expected \(expected) ± \(tolerance), got \(actual)",
        sourceLocation: sourceLocation
    )
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

@Suite("Frecency decay and ranking")
struct FrecencyRankingTests {

    // MARK: - Decay

    @Test func oneHalfLifeDoublesTheEpochFrameWeight() {
        expectClose(
            SnippetFrecency.growth(epoch: 0, now: 14 * day, halfLifeSeconds: halfLife),
            2.0, tolerance: 1e-9, "one half-life doubles the epoch-frame weight")
        expectClose(
            SnippetFrecency.growth(epoch: 0, now: 56 * day, halfLifeSeconds: halfLife),
            16.0, tolerance: 1e-9, "four half-lives")

        expectClose(6 * pow(2.0, -45.0 / 14.0), 0.6465, tolerance: 1e-3, "6 uses 45 days ago")
        expectClose(0.25 * pow(2.0, -30.0 / 14.0), 0.0566, tolerance: 1e-4, "one copy after 30 days")
    }

    /// The central theorem: raw stored weights rank identically at every
    /// instant, so the comparator never needs the clock.
    @Test func rawAndDecayedWeightsInduceTheSameOrderAtEveryInstant() {
        let uses: [(Double, Double)] = [(0, 1.0), (3 * day, 1.0), (40 * day, 1.0)]
        var weights: [Double] = []
        for (time, weight) in uses {
            weights.append(weight * SnippetFrecency.growth(epoch: 0, now: time, halfLifeSeconds: halfLife))
        }
        for readAt in [40 * day, 400 * day] {
            let decayed = weights.map { $0 * exp2(-readAt / halfLife) }
            let rawOrder = weights.enumerated().sorted { $0.element > $1.element }.map(\.offset)
            let decayedOrder = decayed.enumerated().sorted { $0.element > $1.element }.map(\.offset)
            #expect(rawOrder == decayedOrder, "raw and decayed weights induce the same order")
        }
    }

    @Test func everyUsageRhythmReachesItsPublishedSteadyState() {
        expectClose(steadyState(usesPerDay: 8), 162.08, tolerance: 0.81, "8/day steady state")
        expectClose(steadyState(usesPerDay: 4), 81.29, tolerance: 0.41, "4/day steady state")
        expectClose(steadyState(usesPerDay: 2), 40.90, tolerance: 0.21, "2/day steady state")
        expectClose(steadyState(usesPerDay: 1), 20.70, tolerance: 0.11, "1/day steady state")
        expectClose(steadyState(usesPerDay: 3.0 / 7.0), 9.17, tolerance: 0.05, "3/week steady state")
        expectClose(steadyState(usesPerDay: 1.0 / 7.0), 3.41, tolerance: 0.02, "1/week steady state")
        expectClose(steadyState(usesPerDay: 1.0 / 30.0), 1.29, tolerance: 0.01, "1/month steady state")
    }

    @Test func theWeekdayRhythmPeaksAfterFridayAndBottomsAfterMonday() {
        // Phase-dependent by construction; there is deliberately no test for
        // the 14.93 continuous approximation, which occurs nowhere in the cycle.
        expectClose(businessDaySteadyState(readOnWeekday: 4), 15.50, tolerance: 0.01,
                    "weekday rhythm peaks right after a Friday use")
        expectClose(businessDaySteadyState(readOnWeekday: 0), 14.36, tolerance: 0.01,
                    "weekday rhythm bottoms right after a Monday use")
    }

    @Test func oneCopyIsNoiseAndOneExpansionCounts() {
        #expect(SnippetFrecency.copyWeight < SnippetFrecency.meaningfulnessFloor,
                "one copy is noise")
        #expect(SnippetFrecency.expandWeight >= SnippetFrecency.meaningfulnessFloor,
                "one expansion counts")
    }

    @Test func aBrokenClockNeverProducesAWeightTheComparatorCouldTrapOn() {
        let now = 1_800_000_000.0

        #expect(SnippetFrecency.growth(epoch: now + 10 * 365 * day, now: now, halfLifeSeconds: halfLife)
                == 1.0, "a backwards clock counts the use at face value")
        let ancient = SnippetFrecency.growth(epoch: now - 10 * 365 * day, now: now, halfLifeSeconds: halfLife)
        #expect(ancient.isFinite && ancient <= exp2(400.0 / 14.0) + 1,
                "a forwards clock stays finite and bounded by the 400-day cap")
        #expect(SnippetFrecency.growth(epoch: .nan, now: now, halfLifeSeconds: halfLife) == 1.0,
                "a non-finite epoch degrades to no growth")
        #expect(SnippetFrecency.growth(epoch: 0, now: now, halfLifeSeconds: 0) == 1.0,
                "a zero half-life degrades to no growth")

        #expect(SnippetFrecency.clamp(weight: .nan) == 0, "NaN clamps to zero")
        #expect(SnippetFrecency.clamp(weight: .infinity) == SnippetFrecency.maxWeight,
                "an overflow saturates at the ceiling rather than losing the history")
        #expect(SnippetFrecency.clamp(weight: -.infinity) == 0, "negative infinity clamps to zero")
        #expect(SnippetFrecency.clamp(weight: -5) == 0, "negative clamps to zero")
        #expect(SnippetFrecency.clamp(weight: .infinity).isFinite,
                "clamp never returns a value the comparator could trap on")
    }

    // MARK: - Rescale

    @Test func aRebasePreservesEveryPairwiseRatioAndThePermutation() throws {
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
        let referenceBefore = try #require(doc.records[reference]).weight
        let referenceAfter = try #require(shifted.records[reference]).weight
        for id in ids where id != reference {
            let before = try #require(doc.records[id]).weight / referenceBefore
            let after = try #require(shifted.records[id]).weight / referenceAfter
            expectClose(after, before, tolerance: 1e-9, "rebase preserves pairwise ratios")
        }

        let orderBefore = doc.records.sorted { $0.value.weight > $1.value.weight }.map(\.key)
        let orderAfter = shifted.records.sorted { $0.value.weight > $1.value.weight }.map(\.key)
        #expect(orderBefore == orderAfter, "rebase preserves the permutation")

        // The binding ceiling is stated in units of growth, and rebase scales
        // both the weights and that reference by the same factor.
        let growthBefore = SnippetFrecency.growth(
            epoch: doc.epoch, now: doc.epoch, halfLifeSeconds: halfLife)
        let bindingBefore = try #require(doc.bindings["re"]?[bindingID])
        let bindingAfter = try #require(shifted.bindings["re"]?[bindingID])
        #expect(bindingBefore <= SnippetFrecency.bindingWeightCap * growthBefore * 4 + 1e-9,
                "binding fixture starts within a scaled ceiling")
        let ratio = bindingAfter / bindingBefore
        let recordRatio = referenceAfter / referenceBefore
        expectClose(ratio, recordRatio, tolerance: 1e-9,
                    "bindings and records rescale by the identical factor")
    }

    /// A changed half-life is absorbed at load: values are preserved at the
    /// instant of the rebase, and the new constant is written down.
    @Test func aChangedHalfLifeIsAbsorbedAtLoadUsingTheOldConstant() throws {
        let old = SnippetUsageDocument(
            version: 1, epoch: 1_700_000_000, halfLifeDays: 30,
            records: ["A": SnippetUsageRecord(weight: 8, count: 1, lastUsedAt: 0),
                      "B": SnippetUsageRecord(weight: 2, count: 1, lastUsedAt: 0)],
            bindings: [:])
        let migrated = SnippetUsageFile.rebasedIfNeeded(old, now: old.epoch + 45 * day)
        #expect(migrated.halfLifeDays == SnippetFrecency.halfLifeDays, "half-life is relabelled")
        let a = try #require(migrated.records["A"]).weight
        let b = try #require(migrated.records["B"]).weight
        expectClose(a / b, 4.0, tolerance: 1e-9, "ratios survive a half-life change")
        expectClose(a, 8 * exp2(-45.0 / 30.0), tolerance: 1e-9,
                    "the old half-life governs the conversion")
    }

    // MARK: - Document

    @Test func theDocumentUsesExactlyTheAbbreviatedKeysAndRoundTrips() throws {
        let id = UUID().uuidString
        let doc = SnippetUsageDocument(
            version: 1, epoch: 1_785_312_000, halfLifeDays: 14,
            records: [id: SnippetUsageRecord(weight: 162.08, count: 4412, lastUsedAt: 1_785_312_000)],
            bindings: ["sig": [id: 4.41]],
            recordsClearedAt: 0, bindingsClearedAt: 0)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["v", "epoch", "h", "w", "b", "rc", "bc"],
                "the document uses exactly the abbreviated keys")
        let records = try #require(object["w"] as? [String: Any])
        let record = try #require(records[id] as? [String: Any])
        #expect(Set(record.keys) == ["s", "n", "l"],
                "records use exactly the abbreviated keys")

        let decoded = try JSONDecoder().decode(SnippetUsageDocument.self, from: data)
        #expect(decoded == doc, "the document round-trips")
    }

    @Test func everyMalformedDocumentDegradesToEmptyAndWritable() {
        // Every one of these must land on "empty and writable", never on a
        // thrown error and never on read-only.
        for json in ["", "{{{", "[]", "{}", "{\"v\":1}", "{\"v\":1,\"w\":{}}",
                     "{\"epoch\":123", String(repeating: "x", count: 4096)] {
            if let doc = decode(json) {
                #expect(doc.records.isEmpty, "degraded input \(json.prefix(12)) yields no records")
                #expect(doc.version <= SnippetUsageDocument.currentVersion,
                        "degraded input is not mistaken for a future version")
            }
        }

        // The totality of the decoder is what keeps a future format out of the
        // "corrupt" branch, where an old build would overwrite a new one.
        #expect(decode("{}") != nil, "an empty object decodes rather than failing")
        #expect(decode("{\"v\":1}") != nil, "a version-only object decodes rather than failing")
    }

    /// The probe reads a version even when the full decoder cannot.
    @Test func theVersionProbeReadsAFileTheFullDecoderCannot() throws {
        let futureShape = "{\"v\":99,\"w\":\"a string, not a dictionary\"}"
        let probe = try? JSONDecoder().decode(
            SnippetUsageVersionProbe.self, from: futureShape.data(using: .utf8)!)
        #expect(probe?.v == 99, "the probe reads the version out of an otherwise undecodable file")
        #expect(decode(futureShape) == nil,
                "the full decoder does fail on that shape — which is the whole reason the probe exists")
    }

    @Test func hostileValuesAreClampedButNonFiniteWeightsAreDropped() throws {
        let validID = UUID().uuidString
        let hostile = """
        {"v":1,"epoch":-1e18,"h":9e99,"rc":null,"w":{
          "\(validID)":{"s":1e300,"n":-3,"l":9e99},
          "not-a-uuid":{"s":5,"n":1,"l":0}
        },"b":{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"\(validID)":3}}}
        """
        let decoded = try #require(decode(hostile), "hostile document should still decode")
        let clean = SnippetUsageFile.sanitized(decoded)

        #expect(clean.epoch.isFinite && clean.epoch >= 0, "epoch is clamped into range")
        #expect(clean.halfLifeDays >= 1 && clean.halfLifeDays <= 365, "half-life is clamped into range")
        #expect(clean.records["not-a-uuid"] == nil, "a non-UUID record key is dropped")
        #expect(clean.records[validID]?.weight == SnippetFrecency.maxWeight,
                "an overflowing weight is clamped, not dropped")
        #expect((clean.records[validID]?.count ?? -1) >= 0, "a negative count is clamped")
        #expect((clean.records[validID]?.lastUsedAt ?? .infinity) <= SnippetFrecency.maxTimestamp,
                "a runaway timestamp is clamped")
        #expect(clean.bindings.isEmpty, "an over-long binding key is dropped")

        // Untrusted input is held to a stricter rule than our own arithmetic:
        // anything non-finite off disk is dropped rather than saturated.
        for poison in [Double.nan, .infinity, -.infinity, 0, -1] {
            let doc = SnippetUsageDocument(
                version: 1, epoch: 0, halfLifeDays: 14,
                records: [validID: SnippetUsageRecord(weight: poison, count: 1, lastUsedAt: 0)],
                bindings: [:])
            #expect(SnippetUsageFile.sanitized(doc).records.isEmpty,
                    "a weight of \(poison) is dropped on load")
        }
    }

    // MARK: - Comparator
    //
    // The legacy suite drew every comparator fixture from one `SeededRandom(seed: 7)`
    // stream shared across the whole function. Split into separate tests, each one
    // seeds its own stream from 7, so every test below is still reproducible on its
    // own and none depends on the order the others ran in.

    /// The single most important test: with no usage data the order is
    /// element-for-element what it was before the feature existed.
    @Test func emptyUsageReproducesThePreFeatureOrderExactly() {
        var random = SeededRandom(seed: 7)
        for iteration in 0..<300 {
            let keys = makeKeys(count: 40, random: &random, withUsage: false)
            let new = keys.sorted { SnippetFrecency.ranks($0, before: $1) }.map(\.id)
            let old = keys.sorted { legacyRanks($0, $1) }.map(\.id)
            #expect(new == old, "empty usage reproduces the pre-feature order exactly (iteration \(iteration))")
            // swift-testing does not stop at the first failure, and 300 identical
            // failures would bury the one that matters.
            if new != old { return }
        }
    }

    /// Usage never crosses a tier above it.
    @Test func aHigherTierDecidesRegardlessOfUsage() {
        var random = SeededRandom(seed: 7)
        for iteration in 0..<5000 {
            var lhs = makeKeys(count: 1, random: &random, withUsage: true)[0]
            var rhs = makeKeys(count: 1, random: &random, withUsage: true)[0]
            guard lhs.score != rhs.score || lhs.keywordRank != rhs.keywordRank || lhs.isPinned != rhs.isPinned
            else { continue }
            let withUsage = SnippetFrecency.ranks(lhs, before: rhs)
            lhs.bindingWeight = 0; lhs.frecency = 0
            rhs.bindingWeight = 0; rhs.frecency = 0
            let withoutUsage = SnippetFrecency.ranks(lhs, before: rhs)
            #expect(withUsage == withoutUsage,
                    "a higher tier decides regardless of usage (trial \(iteration))")
            if withUsage != withoutUsage { return }
        }
    }

    /// Disaster scenario: a fully typed keyword must beat red-hot usage.
    @Test func anExactKeywordOutranksRedHotFrecency() {
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
        #expect(exact.score == hot.score, "a prefix match scores the same on both")
        #expect(exact.keywordRank == 3, "the fully typed keyword is an exact keyword match")
        #expect(hot.keywordRank == 2, "the longer keyword is only a prefix match")
        #expect([exact, hot].sorted { SnippetFrecency.ranks($0, before: $1) }.first?.id == exactID,
                "exact keyword outranks hot frecency")
    }

    /// Pin is a strict outer key on both surfaces.
    @Test func neitherUsageNorSelectionMemoryOutranksAPin() {
        #expect(
            SnippetFrecency.emptyQueryRanks(lhsPinned: false, lhsFrecency: 1e6, lhsOrder: 99,
                                            rhsPinned: true, rhsFrecency: 0, rhsOrder: 0)
            == false, "hot unpinned never precedes cold pinned in the empty-query branch")
        let hotUnpinned = SnippetRankingKey(score: 3, keywordRank: 2, isPinned: false,
                                            bindingWeight: 1e6, frecency: 1e6, displayOrder: 99,
                                            displayName: "hot", id: UUID())
        let coldPinned = SnippetRankingKey(score: 3, keywordRank: 2, isPinned: true,
                                           bindingWeight: 0, frecency: 0, displayOrder: 0,
                                           displayName: "cold", id: UUID())
        #expect(SnippetFrecency.ranks(hotUnpinned, before: coldPinned) == false,
                "neither usage nor selection memory outranks a pin")
    }

    /// Strict weak ordering. Without it `Array.sorted` is undefined, and it
    /// would be undefined inside the event-tap callback.
    @Test func ranksIsAStrictWeakOrdering() {
        for seed in 0..<40 {
            var fuzz = SeededRandom(seed: UInt64(seed) &+ 1)
            let keys = makeKeys(count: 16, random: &fuzz, withUsage: true)
            let holds = isStrictWeakOrdering(keys)
            #expect(holds, "ranks() is a strict weak ordering (seed \(seed))")
            if !holds { return }
        }
    }

    /// Determinism: heavy duplication, many shufflings, one result.
    @Test func theUuidTerminatorMakesTheOrderDeterministic() {
        var random = SeededRandom(seed: 7)
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
            #expect(shuffled.sorted { SnippetFrecency.ranks($0, before: $1) }.map(\.id) == reference,
                    "the uuid terminator makes the order deterministic")
        }
    }

    /// Sanitized hostile data cannot reach the comparator.
    @Test func sanitizedWeightsKeepTheOrderingTotal() {
        var random = SeededRandom(seed: 7)
        let poisoned = SnippetUsageDocument(
            version: 1, epoch: 1_700_000_000, halfLifeDays: 14,
            records: [UUID().uuidString: SnippetUsageRecord(weight: .nan, count: 1, lastUsedAt: 0),
                      UUID().uuidString: SnippetUsageRecord(weight: .infinity, count: 1, lastUsedAt: 0)],
            bindings: [:])
        let cleaned = SnippetUsageFile.sanitized(poisoned)
        #expect(cleaned.records.values.allSatisfy { $0.weight.isFinite },
                "sanitize removes every non-finite weight")
        var poisonKeys = makeKeys(count: 100, random: &random, withUsage: true)
        for (index, weight) in cleaned.records.values.enumerated() where index < poisonKeys.count {
            poisonKeys[index].frecency = weight.weight
        }
        #expect(isStrictWeakOrdering(Array(poisonKeys.prefix(16))),
                "sanitized weights keep the ordering total")
    }

    // MARK: - Empty-query branch

    @Test func theCapIsAppliedAfterRankingNotInDisplayOrder() {
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
        #expect(Array(ordered) == Array(0..<8), "the highest-ranked eight are returned")

        let reversed: [Double] = (0..<20).map { Double($0) }
        let reversedTop = (0..<20)
            .sorted { lhs, rhs in
                SnippetFrecency.emptyQueryRanks(
                    lhsPinned: false, lhsFrecency: reversed[lhs], lhsOrder: lhs,
                    rhsPinned: false, rhsFrecency: reversed[rhs], rhsOrder: rhs)
            }
            .prefix(8)
        #expect(Array(reversedTop) == Array((12..<20).reversed()),
                "the most used win even when they sit last in display order")

        let allZero = (0..<20).sorted { lhs, rhs in
            SnippetFrecency.emptyQueryRanks(
                lhsPinned: false, lhsFrecency: 0, lhsOrder: lhs,
                rhsPinned: false, rhsFrecency: 0, rhsOrder: rhs)
        }
        #expect(allZero == Array(0..<20), "with no usage the input order is returned unchanged")
    }

    // MARK: - Fuzzy match tie precision

    @Test func everyPrefixMatchOfTheSameLengthScoresIdentically() throws {
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
            #expect(!scores.isEmpty, "the fixture has prefix matches at length \(length)")
            let target = try #require(expected[length])
            for score in scores {
                #expect(score == target, "prefix match of length \(length) scores identically")
            }
        }
    }
}
