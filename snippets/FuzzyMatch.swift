import Foundation

struct FuzzyMatch {
    struct Result {
        let score: Int
        let matched: Bool
        let matchedRanges: [NSRange]
    }

    static func score(query: String, target: String) -> Result {
        let query = query.lowercased().map(String.init)
        let targetCharacters = Array(target)
        let targetIndices = Array(target.indices)

        guard !query.isEmpty else { return Result(score: 0, matched: true, matchedRanges: []) }
        guard !targetCharacters.isEmpty else { return Result(score: 0, matched: false, matchedRanges: []) }

        var score = 0
        var queryIndex = 0
        var consecutive = 0
        var previousMatchIndex = -2
        var matchedRanges: [NSRange] = []

        for (targetIndex, char) in targetCharacters.enumerated() {
            guard queryIndex < query.count else { break }

            if String(char).lowercased() == query[queryIndex] {
                score += 1

                // Consecutive match bonus
                if targetIndex == previousMatchIndex + 1 {
                    consecutive += 1
                    score += consecutive * 2
                } else {
                    consecutive = 0
                }

                // Start-of-word bonus
                if targetIndex == 0 || !targetCharacters[targetIndex - 1].isLetter {
                    score += 3
                }

                // First character bonus
                if queryIndex == 0 && targetIndex == 0 {
                    score += 5
                }

                let rangeStart = targetIndices[targetIndex]
                let rangeEnd = target.index(after: rangeStart)
                matchedRanges.append(NSRange(rangeStart..<rangeEnd, in: target))

                previousMatchIndex = targetIndex
                queryIndex += 1
            } else {
                consecutive = 0
            }
        }

        let matched = queryIndex == query.count
        return Result(
            score: matched ? score : 0,
            matched: matched,
            matchedRanges: matched ? matchedRanges : []
        )
    }
}
