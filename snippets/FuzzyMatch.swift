import Foundation

struct FuzzyMatch {
    struct Result {
        let score: Int
        let matched: Bool
    }

    static func score(query: String, target: String) -> Result {
        let query = Array(query.lowercased())
        let target = Array(target.lowercased())

        guard !query.isEmpty else { return Result(score: 0, matched: true) }
        guard !target.isEmpty else { return Result(score: 0, matched: false) }

        var score = 0
        var queryIndex = 0
        var consecutive = 0
        var previousMatchIndex = -2

        for (targetIndex, char) in target.enumerated() {
            guard queryIndex < query.count else { break }

            if char == query[queryIndex] {
                score += 1

                // Consecutive match bonus
                if targetIndex == previousMatchIndex + 1 {
                    consecutive += 1
                    score += consecutive * 2
                } else {
                    consecutive = 0
                }

                // Start-of-word bonus
                if targetIndex == 0 || !target[targetIndex - 1].isLetter {
                    score += 3
                }

                // First character bonus
                if queryIndex == 0 && targetIndex == 0 {
                    score += 5
                }

                previousMatchIndex = targetIndex
                queryIndex += 1
            } else {
                consecutive = 0
            }
        }

        let matched = queryIndex == query.count
        return Result(score: matched ? score : 0, matched: matched)
    }
}
