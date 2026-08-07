import Foundation

/// How one keyword relates to another *enabled* keyword, in the only terms the
/// expansion engine has: `unambiguousExactMatch` fires a keyword when it is the
/// single exact match and no longer enabled keyword starts with it. That prefix
/// relation runs one way, so its two ends are two different failures on two
/// different snippets — and anything that tests only one end protects the
/// keyword being typed while silently killing the one already in the library.
enum KeywordRelation: Equatable {
    case unrelated
    case duplicate
    /// `other` extends this keyword, so this one never auto-expands.
    case blockedByLonger
    /// This keyword extends `other`, so `other` stops auto-expanding.
    case blocksShorter

    /// Both sides must already be folded the way the engine folds them —
    /// `SnippetTagging.filterKey`, which is byte-identical to the engine's own
    /// `normalizedForSuggestionMatching`.
    static func between(_ keyword: String, _ other: String) -> KeywordRelation {
        if keyword == other { return .duplicate }
        if other.hasPrefix(keyword) { return .blockedByLonger }
        if keyword.hasPrefix(other) { return .blocksShorter }
        return .unrelated
    }
}

/// The keywords a human might plausibly have typed for a snippet, derived from
/// what the snippet already says about itself.
enum KeywordSuggestions {
    /// Longer than this and a word is abbreviated instead of offered whole:
    /// "email" is already a keyword, "signature" is a word you shorten before
    /// you type it twenty times a day.
    private static let wholeWordMaxLength = 6
    private static let abbreviationLengths = [4, 3]
    /// A single character fires on nearly anything and has a prefix relation
    /// with nearly everything, so two is the shortest thing worth offering.
    private static let minimumLength = 2
    private static let maximumInitials = 5

    /// A first line that opens with a URL is the audit's own example of derived
    /// junk (`\https://github.com/…`); stepping over the scheme lands on the
    /// host, which is a word the user recognises.
    private static let ignoredLeadingWords: Set<String> = ["http", "https", "www"]

    /// Ordered best-first, deduplicated, and already folded the way
    /// `KeywordRelation` needs. Nothing here is measured against the library —
    /// the caller does that, because only it knows what is enabled.
    static func candidates(name: String, contentFirstLine: String) -> [String] {
        var candidates: [String] = []

        // A name is a label somebody chose, and labels get shortened two ways:
        // the opening word, and the initials of the whole thing.
        let nameWords = words(in: name)
        if let firstWord = nameWords.first {
            appendAbbreviations(of: firstWord, to: &candidates)
        }
        if nameWords.count > 1 {
            append(String(nameWords.prefix(maximumInitials).compactMap(\.first)), to: &candidates)
        }

        // Content is a sentence rather than a label: its initials spell nothing,
        // so only its first real word is worth anything.
        if let firstWord = words(in: contentFirstLine).first(where: { !ignoredLeadingWords.contains($0) }) {
            appendAbbreviations(of: firstWord, to: &candidates)
        }

        return candidates
    }

    private static func appendAbbreviations(of word: String, to candidates: inout [String]) {
        guard word.count > wholeWordMaxLength else {
            append(word, to: &candidates)
            return
        }

        for length in abbreviationLengths {
            append(String(word.prefix(length)), to: &candidates)
        }
    }

    private static func append(_ candidate: String, to candidates: inout [String]) {
        guard candidate.count >= minimumLength, !candidates.contains(candidate) else { return }
        candidates.append(candidate)
    }

    /// Folding first is what turns "Café Order" into "cafe" instead of "caf".
    /// Everything outside a-z0-9 is a boundary, so what comes out is always
    /// typeable and never one of the multi-scalar graphemes the engine refuses
    /// to expand — a phrase with no such characters at all yields nothing, which
    /// is the right answer: there is no keyword in it to guess.
    private static func words(in phrase: String) -> [String] {
        SnippetTagging.filterKey(for: phrase)
            .lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .map(String.init)
    }
}
