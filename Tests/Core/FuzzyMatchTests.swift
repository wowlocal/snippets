import Foundation
import Testing
@testable import SnippetsCore

@Suite("Prepared fuzzy matching")
struct FuzzyMatchTests {
    private struct Token {
        let character: Character
        let range: NSRange
        let wordStart: Bool
    }

    private func tokens(_ text: String, locale: Locale) -> [Token] {
        var result: [Token] = []
        var offset = 0
        var previous: Character?
        for original in text {
            let string = String(original)
            let range = NSRange(location: offset, length: string.utf16.count)
            for (index, character) in string.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: locale).enumerated() {
                result.append(Token(character: character, range: range,
                                    wordStart: index == 0 && previous?.isLetter != true))
            }
            offset += range.length
            previous = original
        }
        return result
    }

    // Independent exhaustive oracle: enumerate alignments, not DP states. Multiple
    // middle paths can tie completely; the old dictionary traversal picked any of
    // them. Accept those equivalent highlights, but require every scoring/tie tier.
    private func optimal(_ query: String, _ target: String, locale: Locale) -> [FuzzyMatch.Result] {
        let needle = tokens(query, locale: locale).map(\.character)
        let haystack = tokens(target, locale: locale)
        if needle.isEmpty { return [.init(score: 0, matched: true, matchedRanges: [])] }
        var best: (score: Int, end: Int, start: Int, streak: Int)?
        var results: [FuzzyMatch.Result] = []
        func visit(_ path: [Int], score: Int, streak: Int) {
            if path.count == needle.count {
                let key = (score, path.last!, haystack[path[0]].range.location, streak)
                if let best {
                    let lhs = [key.0, -key.1, -key.2, key.3]
                    let rhs = [best.score, -best.end, -best.start, best.streak]
                    if lhs.lexicographicallyPrecedes(rhs) { return }
                    if lhs != rhs { results.removeAll() }
                }
                best = key
                results.append(.init(score: score, matched: true,
                                     matchedRanges: path.map { haystack[$0].range }))
                return
            }
            let start = (path.last ?? -1) + 1
            guard start < haystack.count else { return }
            for index in start..<haystack.count where haystack[index].character == needle[path.count] {
                let nextStreak = path.last.map { index == $0 + 1 ? streak + 1 : 0 } ?? 0
                let bonus = 1 + (haystack[index].wordStart ? 3 : 0)
                    + (path.isEmpty && index == 0 ? 5 : 0) + nextStreak * 2
                visit(path + [index], score: score + bonus, streak: nextStreak)
            }
        }
        visit([], score: 0, streak: 0)
        return results.isEmpty ? [.noMatch] : results
    }

    @Test func exhaustiveSmallInputsPreserveScoresAndHighlightTieBreaks() {
        func strings(maxLength: Int) -> [String] {
            var all = [""]
            var row = [""]
            for _ in 0..<maxLength {
                row = row.flatMap { prefix in ["a", "b", " "].map { prefix + $0 } }
                all += row
            }
            return all
        }
        let locale = Locale(identifier: "en_US")
        var workspace = FuzzyMatch.Workspace()
        for target in strings(maxLength: 5) {
            let preparedTarget = FuzzyMatch.PreparedTarget(target, locale: locale)
            for query in strings(maxLength: 3) {
                let preparedQuery = FuzzyMatch.PreparedQuery(query, locale: locale)
                let result = FuzzyMatch.score(query: preparedQuery, target: preparedTarget, workspace: &workspace)
                let expected = optimal(query, target, locale: locale)
                #expect(expected.contains(result), "query=\(query), target=\(target)")
                let scoreOnly = FuzzyMatch.score(query: preparedQuery, target: preparedTarget,
                                                includingRanges: false, workspace: &workspace)
                #expect(scoreOnly.score == result.score && scoreOnly.matched == result.matched)
                #expect(scoreOnly.matchedRanges.isEmpty)
                if !expected.contains(result) { return }
            }
        }
    }

    @Test func unicodeAndLocaleFoldingPreserveUTF16Ranges() {
        let targets = ["Café", "Cafe\u{301}", "Straße", "ßss ß", "İIıi", "Привет мир",
                       "👩🏽‍💻 cafe", "🇫🇷 Français", "ﬃ file", "a\r\nb", "Kelvin", "\u{301}a"]
        let queries = ["", "cafe", "é", "ss", "sss", "i", "I", "ı", "прм", "👩🏽‍💻", "ffi", "ab", "\r\n", "k"]
        var workspace = FuzzyMatch.Workspace()
        for localeID in ["en_US", "tr_TR", "az_AZ", "lt_LT"] {
            let locale = Locale(identifier: localeID)
            for target in targets {
                for query in queries {
                    let result = FuzzyMatch.score(query: .init(query, locale: locale),
                                                 target: .init(target, locale: locale), workspace: &workspace)
                    #expect(optimal(query, target, locale: locale).contains(result),
                            "locale=\(localeID), query=\(query), target=\(target)")
                }
            }
        }
    }

    @Test func repeatedCharactersAndWorkspaceReuseKeepTheBestStreak() {
        var workspace = FuzzyMatch.Workspace()
        for (query, target) in [("aaab", "aa aaaaab"), ("ababa", "a b ababa"),
                                ("aaaaaa", String(repeating: "a", count: 256)),
                                ("zz", "z"), ("", ""), ("ab", "ba")] {
            let result = FuzzyMatch.score(query: .init(query), target: .init(target), workspace: &workspace)
            if target.count < 20 {
                #expect(optimal(query, target, locale: .current).contains(result))
            } else {
                #expect(result.score == 44)
                #expect(result.matchedRanges == (0..<6).map { NSRange(location: $0, length: 1) })
            }
        }
    }
}
