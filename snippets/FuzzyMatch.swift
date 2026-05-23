import Foundation

struct FuzzyMatch {
    struct Result {
        let score: Int
        let matched: Bool
        let matchedRanges: [NSRange]
    }

    private struct SearchCharacter {
        let character: Character
        let originalRange: Range<String.Index>
        let isWordStart: Bool
    }

    private struct CandidateState {
        let targetIndex: Int
        let consecutive: Int
        let score: Int
        let matchedRanges: [NSRange]
    }

    private struct StateKey: Hashable {
        let targetIndex: Int
        let consecutive: Int
    }

    static func score(query: String, target: String) -> Result {
        let queryCharacters = normalizedCharacters(for: query).map(\.character)
        let targetCharacters = normalizedCharacters(for: target)

        guard !queryCharacters.isEmpty else { return Result(score: 0, matched: true, matchedRanges: []) }
        guard !targetCharacters.isEmpty else { return Result(score: 0, matched: false, matchedRanges: []) }

        var states = initialStates(
            matching: queryCharacters[0],
            in: targetCharacters,
            target: target
        )
        guard !states.isEmpty else { return Result(score: 0, matched: false, matchedRanges: []) }

        for queryIndex in queryCharacters.indices.dropFirst() {
            var nextStatesByKey: [StateKey: CandidateState] = [:]
            let queryCharacter = queryCharacters[queryIndex]

            for state in states {
                let nextTargetIndex = state.targetIndex + 1
                guard nextTargetIndex < targetCharacters.count else { continue }

                for targetIndex in nextTargetIndex..<targetCharacters.count
                    where targetCharacters[targetIndex].character == queryCharacter {
                    let candidate = extendedState(
                        from: state,
                        queryIndex: queryIndex,
                        targetIndex: targetIndex,
                        targetCharacters: targetCharacters,
                        target: target
                    )
                    let key = StateKey(
                        targetIndex: candidate.targetIndex,
                        consecutive: candidate.consecutive
                    )

                    if let existing = nextStatesByKey[key] {
                        if candidateRanksBefore(candidate, existing) {
                            nextStatesByKey[key] = candidate
                        }
                    } else {
                        nextStatesByKey[key] = candidate
                    }
                }
            }

            states = Array(nextStatesByKey.values)
            guard !states.isEmpty else { return Result(score: 0, matched: false, matchedRanges: []) }
        }

        guard let best = states.max(by: { candidateRanksBefore($1, $0) }) else {
            return Result(score: 0, matched: false, matchedRanges: [])
        }

        return Result(
            score: best.score,
            matched: true,
            matchedRanges: best.matchedRanges
        )
    }

    private static func normalizedCharacters(for string: String) -> [SearchCharacter] {
        var result: [SearchCharacter] = []
        var index = string.startIndex
        var previousOriginalCharacter: Character?

        while index < string.endIndex {
            let nextIndex = string.index(after: index)
            let originalCharacter = string[index]
            let folded = String(originalCharacter).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let originalRange = index..<nextIndex

            for (foldedIndex, foldedCharacter) in folded.enumerated() {
                result.append(
                    SearchCharacter(
                        character: foldedCharacter,
                        originalRange: originalRange,
                        isWordStart: foldedIndex == 0 && (previousOriginalCharacter?.isLetter != true)
                    )
                )
            }

            previousOriginalCharacter = originalCharacter
            index = nextIndex
        }

        return result
    }

    private static func initialStates(
        matching queryCharacter: Character,
        in targetCharacters: [SearchCharacter],
        target: String
    ) -> [CandidateState] {
        targetCharacters.indices.compactMap { targetIndex in
            guard targetCharacters[targetIndex].character == queryCharacter else { return nil }
            return CandidateState(
                targetIndex: targetIndex,
                consecutive: 0,
                score: scoreContribution(
                    queryIndex: 0,
                    targetIndex: targetIndex,
                    consecutive: 0,
                    targetCharacters: targetCharacters
                ),
                matchedRanges: [NSRange(targetCharacters[targetIndex].originalRange, in: target)]
            )
        }
    }

    private static func extendedState(
        from state: CandidateState,
        queryIndex: Int,
        targetIndex: Int,
        targetCharacters: [SearchCharacter],
        target: String
    ) -> CandidateState {
        let consecutive = targetIndex == state.targetIndex + 1 ? state.consecutive + 1 : 0
        let score = state.score + scoreContribution(
            queryIndex: queryIndex,
            targetIndex: targetIndex,
            consecutive: consecutive,
            targetCharacters: targetCharacters
        )
        return CandidateState(
            targetIndex: targetIndex,
            consecutive: consecutive,
            score: score,
            matchedRanges: state.matchedRanges + [NSRange(targetCharacters[targetIndex].originalRange, in: target)]
        )
    }

    private static func scoreContribution(
        queryIndex: Int,
        targetIndex: Int,
        consecutive: Int,
        targetCharacters: [SearchCharacter]
    ) -> Int {
        var score = 1

        if consecutive > 0 {
            score += consecutive * 2
        }

        if targetCharacters[targetIndex].isWordStart {
            score += 3
        }

        if queryIndex == 0 && targetIndex == 0 {
            score += 5
        }

        return score
    }

    private static func candidateRanksBefore(_ lhs: CandidateState, _ rhs: CandidateState) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }

        if lhs.targetIndex != rhs.targetIndex {
            return lhs.targetIndex < rhs.targetIndex
        }

        let lhsStart = lhs.matchedRanges.first?.location ?? Int.max
        let rhsStart = rhs.matchedRanges.first?.location ?? Int.max
        if lhsStart != rhsStart {
            return lhsStart < rhsStart
        }

        return lhs.consecutive > rhs.consecutive
    }
}
