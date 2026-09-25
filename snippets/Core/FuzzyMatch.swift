import Foundation

/// Prepared strings, cheap rejection, reusable scoring buffers, and late highlighting.
/// The scoring contract is unchanged: 1 per character, 3 at word starts, 5 at the
/// start of the target, and 2 * streak for consecutive characters.
nonisolated struct FuzzyMatch {
    struct Result: Equatable, Sendable {
        let score: Int
        let matched: Bool
        let matchedRanges: [NSRange]

        static let noMatch = Result(score: 0, matched: false, matchedRanges: [])
    }

    struct PreparedQuery: Sendable {
        fileprivate let characters: [Character]
        fileprivate let mask: ASCIIMask
        var isEmpty: Bool { characters.isEmpty }

        init(_ text: String, locale: Locale = .current) {
            let normalized = normalize(text, locale: locale)
            characters = normalized.characters
            mask = normalized.mask
        }
    }

    struct PreparedTarget: Sendable {
        fileprivate let characters: [Character]
        fileprivate let ranges: [NSRange]
        fileprivate let wordStarts: [Bool]
        fileprivate let mask: ASCIIMask
        fileprivate let positions: [Character: [Int]]

        init(_ text: String, locale: Locale = .current) {
            let normalized = normalize(text, locale: locale)
            characters = normalized.characters
            ranges = normalized.ranges
            wordStarts = normalized.wordStarts
            mask = normalized.mask
            var positions: [Character: [Int]] = [:]
            for (index, character) in characters.enumerated() {
                positions[character, default: []].append(index)
            }
            self.positions = positions
        }
    }

    /// One owner per search operation; no shared mutable/global scratch state.
    /// Score-only passes never build trace nodes or per-candidate highlight arrays.
    struct Workspace {
        fileprivate var previous: [State] = []
        fileprivate var next: [State] = []
        fileprivate var trace: [Trace] = []
    }

    fileprivate struct State {
        let targetIndex: Int
        let consecutive: Int
        let score: Int
        let start: Int
        let trace: Int
    }

    fileprivate struct Trace {
        let targetIndex: Int
        let parent: Int
    }

    fileprivate struct ASCIIMask: Sendable {
        var low: UInt64 = 0
        var high: UInt64 = 0

        mutating func insert(_ character: Character) {
            guard let byte = character.asciiValue else { return }
            if byte < 64 { low |= 1 << byte } else { high |= 1 << (byte - 64) }
        }

        func contains(_ other: ASCIIMask) -> Bool {
            low & other.low == other.low && high & other.high == other.high
        }
    }

    static func score(query: String, target: String) -> Result {
        let locale = Locale.current
        var workspace = Workspace()
        return score(query: PreparedQuery(query, locale: locale),
                     target: PreparedTarget(target, locale: locale), workspace: &workspace)
    }

    static func score(
        query: PreparedQuery,
        target: PreparedTarget,
        includingRanges: Bool = true,
        workspace: inout Workspace
    ) -> Result {
        let pattern = query.characters
        guard !pattern.isEmpty else { return Result(score: 0, matched: true, matchedRanges: []) }
        guard pattern.count <= target.characters.count,
              target.mask.contains(query.mask) else { return .noMatch }

        // A subsequence probe rejects wrong order/repetitions without scoring. Walk
        // occurrence lists instead of scanning every suffix for every partial match.
        var earliest = -1
        for character in pattern {
            guard let positions = target.positions[character],
                  let index = positions.first(where: { $0 > earliest }) else { return .noMatch }
            earliest = index
        }

        workspace.previous.removeAll(keepingCapacity: true)
        workspace.next.removeAll(keepingCapacity: true)
        workspace.trace.removeAll(keepingCapacity: true)
        let firstPositions = target.positions[pattern[0]]!
        let lastPossibleFirst = target.characters.count - pattern.count
        for index in firstPositions where index <= lastPossibleFirst {
            let score = 1 + (target.wordStarts[index] ? 3 : 0) + (index == 0 ? 5 : 0)
            let trace = appendTrace(index, parent: -1, enabled: includingRanges, workspace: &workspace)
            workspace.previous.append(State(targetIndex: index, consecutive: 0,
                                            score: score, start: target.ranges[index].location, trace: trace))
        }

        for queryIndex in pattern.indices.dropFirst() {
            workspace.next.removeAll(keepingCapacity: true)
            var prefixCursor = 0
            var bestGap: State?
            let lastPossible = target.characters.count - (pattern.count - queryIndex)
            for index in target.positions[pattern[queryIndex]]! where index <= lastPossible {
                // All non-adjacent predecessors have the same extension bonus. Keep
                // their best score/start once instead of enumerating every path.
                while prefixCursor < workspace.previous.count,
                      workspace.previous[prefixCursor].targetIndex < index - 1 {
                    let candidate = workspace.previous[prefixCursor]
                    if bestGap == nil || candidate.score > bestGap!.score
                        || (candidate.score == bestGap!.score && candidate.start < bestGap!.start) {
                        bestGap = candidate
                    }
                    prefixCursor += 1
                }
                let base = 1 + (target.wordStarts[index] ? 3 : 0)
                if let bestGap {
                    let trace = appendTrace(index, parent: bestGap.trace,
                                            enabled: includingRanges, workspace: &workspace)
                    workspace.next.append(State(targetIndex: index, consecutive: 0,
                                                score: bestGap.score + base,
                                                start: bestGap.start, trace: trace))
                }
                // Preserve every adjacent streak: a currently lower score can win
                // later because our consecutive bonus grows with streak length.
                var adjacent = prefixCursor
                while adjacent < workspace.previous.count,
                      workspace.previous[adjacent].targetIndex == index - 1 {
                    let predecessor = workspace.previous[adjacent]
                    let streak = predecessor.consecutive + 1
                    let trace = appendTrace(index, parent: predecessor.trace,
                                            enabled: includingRanges, workspace: &workspace)
                    workspace.next.append(State(targetIndex: index, consecutive: streak,
                                                score: predecessor.score + base + streak * 2,
                                                start: predecessor.start, trace: trace))
                    adjacent += 1
                }
            }
            swap(&workspace.previous, &workspace.next)
            guard !workspace.previous.isEmpty else { return .noMatch }
        }

        let best = workspace.previous.max { ranks($1, before: $0) }!
        guard includingRanges else { return Result(score: best.score, matched: true, matchedRanges: []) }
        var ranges: [NSRange] = []
        ranges.reserveCapacity(pattern.count)
        var node = best.trace
        while node >= 0 {
            let step = workspace.trace[node]
            ranges.append(target.ranges[step.targetIndex])
            node = step.parent
        }
        ranges.reverse()
        return Result(score: best.score, matched: true, matchedRanges: ranges)
    }

    private static func appendTrace(
        _ index: Int, parent: Int, enabled: Bool, workspace: inout Workspace
    ) -> Int {
        guard enabled else { return -1 }
        let result = workspace.trace.count
        workspace.trace.append(Trace(targetIndex: index, parent: parent))
        return result
    }

    private static func ranks(_ lhs: State, before rhs: State) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.targetIndex != rhs.targetIndex { return lhs.targetIndex < rhs.targetIndex }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.consecutive > rhs.consecutive
    }

    private struct Normalized {
        var characters: [Character] = []
        var ranges: [NSRange] = []
        var wordStarts: [Bool] = []
        var mask = ASCIIMask()
    }

    private static let asciiCharacters = (0..<128).map { Character(UnicodeScalar($0)!) }

    private static func normalize(_ text: String, locale: Locale) -> Normalized {
        var result = Normalized()
        // Turkish/Azeri I folding is locale-specific. Those locales use the same
        // Foundation path as Unicode instead of assuming ASCII uppercasing rules.
        let language = locale.language.languageCode?.identifier
        if language != "tr", language != "az", text.utf8.allSatisfy({ $0 < 128 }), !text.contains("\r\n") {
            let count = text.utf8.count
            result.characters.reserveCapacity(count)
            result.ranges.reserveCapacity(count)
            result.wordStarts.reserveCapacity(count)
            var previousWasLetter = false
            for (index, byte) in text.utf8.enumerated() {
                let folded = byte >= 65 && byte <= 90 ? byte + 32 : byte
                let character = asciiCharacters[Int(folded)]
                result.characters.append(character)
                result.ranges.append(NSRange(location: index, length: 1))
                result.wordStarts.append(!previousWasLetter)
                result.mask.insert(character)
                previousWasLetter = (folded >= 97 && folded <= 122)
            }
            return result
        }

        var utf16Offset = 0
        var previousWasLetter = false
        for original in text {
            let string = String(original)
            let length = string.utf16.count
            let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            for (index, character) in folded.enumerated() {
                result.characters.append(character)
                result.ranges.append(NSRange(location: utf16Offset, length: length))
                result.wordStarts.append(index == 0 && !previousWasLetter)
                result.mask.insert(character)
            }
            utf16Offset += length
            previousWasLetter = original.isLetter
        }
        return result
    }
}
