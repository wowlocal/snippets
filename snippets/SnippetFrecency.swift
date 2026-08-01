import Foundation

/// Tuning constants and pure ranking math for usage-based ordering of
/// suggestions.
///
/// Deliberately free of AppKit and actor isolation so `Tests/` can compile it
/// standalone with `swiftc`, the same way `SuggestionTriggerContext` is tested.
enum SnippetFrecency {
    // MARK: - Decay

    /// One sprint. Short enough that an abandoned snippet stops crowding the
    /// panel within a few weeks, long enough that a weekly habit survives
    /// between uses (a 7-day gap keeps 2^(-0.5) = 71% of the peak).
    static let halfLifeDays: Double = 14
    static var halfLifeSeconds: Double { halfLifeDays * 86_400 }
    static let rebaseIntervalSeconds: Double = 30 * 86_400
    static let maxElapsedSeconds: Double = 400 * 86_400

    // MARK: - Event weights

    static let expandWeight: Double = 1.0
    static let pasteWeight: Double = 1.0
    /// Copying from the in-app list is a browsing gesture, not an insertion.
    /// Below `meaningfulnessFloor` on purpose: a single copy must be
    /// arithmetically indistinguishable from never having touched the snippet.
    static let copyWeight: Double = 0.25

    // MARK: - Clamps

    static let maxWeight: Double = 1e12
    static let rebaseWeightThreshold: Double = 1e9
    static let pruneThreshold: Double = 0.001
    /// Decayed weight below which a snippet ranks as if it had no history.
    /// Collapses "barely ever used" into an exact 0.0 so the lower tie-breaks
    /// resolve on display order instead of on months-old noise.
    static let meaningfulnessFloor: Double = 0.5
    /// 2100-01-01.
    static let maxTimestamp: Double = 4_102_444_800

    // MARK: - Capacities

    static let maxRecords = 5_000
    static let maxBindingKeys = 400
    static let maxBindingEntriesPerKey = 4
    static let maxBindingPrefixLength = 8
    static let bindingCompetitorDecay: Double = 0.7
    /// Ceiling on a binding weight, in units of `growth(now)`. At 1.0, escaping
    /// a wrong binding provably takes exactly one correction.
    static let bindingWeightCap: Double = 1.0

    // MARK: - Recording

    static let coalescingWindowSeconds: Double = 1.0
    static let persistDebounceSeconds: Double = 5.0
    static let maxStalenessSeconds: Double = 60.0
}

/// Every comparison key for one suggestion row, precomputed.
///
/// Building these once per element and sorting over them (rather than deriving
/// them inside the sort closure) is what keeps the comparator free of string
/// folding on the keystroke path.
struct SnippetRankingKey {
    var score: Int = 0
    var keywordRank: Int = 0
    var isPinned: Bool = false
    var bindingWeight: Double = 0
    var frecency: Double = 0
    var displayOrder: Int = 0
    var displayName: String = ""
    var id: UUID = UUID()
}

extension SnippetFrecency {

    /// Multiplier converting a use at `now` into the frame anchored at `epoch`.
    ///
    /// Because the factor depends only on time, never on which snippet is being
    /// scored, comparing raw stored weights is identical to comparing their
    /// decayed values at any instant. That is what lets the comparator run
    /// without touching the clock.
    static func growth(epoch: Double, now: Double, halfLifeSeconds h: Double) -> Double {
        guard epoch.isFinite, now.isFinite, h.isFinite, h > 0 else { return 1 }
        let elapsed = min(max(now - epoch, 0), maxElapsedSeconds)
        let factor = exp2(elapsed / h)
        return (factor.isFinite && factor >= 1) ? factor : 1
    }

    /// Always returns a finite, non-negative weight. A non-finite `Double`
    /// reaching the comparator would make `!=` true and `>` false, which is not
    /// a strict weak ordering — `Array.sorted` may then trap inside the
    /// event-tap callback.
    ///
    /// An overflow to `+infinity` saturates at the ceiling rather than
    /// collapsing to zero: it means "enormous", and discarding a snippet's
    /// whole history over one overflow would be the worse failure. `NaN`
    /// carries no such meaning and becomes zero. Values arriving from disk are
    /// held to a stricter rule — `SnippetUsageFile.sanitized` drops anything
    /// non-finite outright, because there the number is untrusted input rather
    /// than the result of our own arithmetic.
    static func clamp(weight: Double) -> Double {
        guard !weight.isNaN else { return 0 }
        return min(max(weight, 0), maxWeight)
    }

    static func foldedForMatching(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// 3 exact / 2 prefix / 1 fuzzy-on-keyword / 0. Matches the ranking the
    /// engine applied inline before this moved out of the comparator; note the
    /// last tier keys off matched ranges, not off `Result.matched`.
    static func keywordRank(
        foldedKeyword: String,
        foldedQuery: String,
        hasKeywordMatchRanges: Bool
    ) -> Int {
        if foldedKeyword == foldedQuery { return 3 }
        if foldedKeyword.hasPrefix(foldedQuery) { return 2 }
        return hasKeywordMatchRanges ? 1 : 0
    }

    /// Total, deterministic order. Usage only ever breaks ties that would
    /// otherwise fall through to "whichever you happened to create first".
    static func ranks(_ lhs: SnippetRankingKey, before rhs: SnippetRankingKey) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.keywordRank != rhs.keywordRank { return lhs.keywordRank > rhs.keywordRank }
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.bindingWeight != rhs.bindingWeight { return lhs.bindingWeight > rhs.bindingWeight }
        if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
        if lhs.displayOrder != rhs.displayOrder { return lhs.displayOrder < rhs.displayOrder }
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Empty-query branch. Pin is a strict outer key and display order a strict
    /// final one, so two distinct positions are never equal in both directions.
    static func emptyQueryRanks(
        lhsPinned: Bool, lhsFrecency: Double, lhsOrder: Int,
        rhsPinned: Bool, rhsFrecency: Double, rhsOrder: Int
    ) -> Bool {
        if lhsPinned != rhsPinned { return lhsPinned }
        if lhsFrecency != rhsFrecency { return lhsFrecency > rhsFrecency }
        return lhsOrder < rhsOrder
    }

    /// Nil for anything too long to store. Truncating instead would alias
    /// distinct queries onto one key.
    static func bindingKey(for query: String) -> String? {
        let folded = foldedForMatching(query)
        guard !folded.isEmpty, folded.count <= maxBindingPrefixLength else { return nil }
        return folded
    }

    // MARK: - Pure recording logic
    //
    // Extracted so the tests can drive coalescing and debounce without a
    // main-actor store or a real clock.

    /// Collapses key auto-repeat and double delivery. Keyed on the pair
    /// (snippet, event kind) rather than the snippet alone: a copy and an
    /// expansion of the same snippet within a second are two separate
    /// intentions, and swallowing the second would be wrong.
    static func shouldCoalesce(
        lastID: UUID?, lastEventTag: Int?, lastAt: Double?,
        id: UUID, eventTag: Int, now: Double
    ) -> Bool {
        guard let lastID, let lastEventTag, let lastAt else { return false }
        return lastID == id && lastEventTag == eventTag
            && (now - lastAt) < coalescingWindowSeconds
    }

    /// Debounce with a staleness ceiling. A bare trailing debounce would never
    /// write at all for a user who expands something every few seconds.
    static func flushDelay(now: Double, firstDirtyAt: Double?) -> Double {
        let sinceFirst = max(0, now - (firstDirtyAt ?? now))
        return max(0, min(persistDebounceSeconds, maxStalenessSeconds - sinceFirst))
    }

    /// Corrections needed to escape a saturated binding. Exactly 1 while
    /// `bindingWeightCap` is 1.0.
    static var bindingRecoveryCorrections: Int {
        let ratio = log(max(bindingWeightCap, 1)) / log(1 / bindingCompetitorDecay)
        return Int(ratio.rounded(.down)) + 1
    }
}

/// Ranking data frozen for the lifetime of one suggestion session.
///
/// The panel refreshes up to three times per keystroke (once locally, twice
/// after accessibility resyncs); all three must rank against identical data or
/// rows would reshuffle under the user's fingers between typing and Return.
struct FrecencySnapshot {
    static let empty = FrecencySnapshot(weights: [:], bindings: [:], cutoff: .infinity)

    /// Copy-on-write reference to the store's dictionary: capturing is one
    /// retain, not a copy.
    let weights: [UUID: Double]
    let bindings: [String: [UUID: Double]]
    /// `meaningfulnessFloor` scaled into the epoch frame. Scaling the threshold
    /// once beats scaling N weights, and keeps `exp2` off the hot path.
    let cutoff: Double

    func value(for id: UUID) -> Double {
        guard let weight = weights[id], weight >= cutoff else { return 0 }
        return weight
    }

    func bindingTable(forQuery query: String) -> [UUID: Double] {
        guard let key = SnippetFrecency.bindingKey(for: query) else { return [:] }
        return bindings[key] ?? [:]
    }
}
