import Foundation

/// How one keyword relates to another *enabled* keyword, in the only terms the
/// expansion engine has: `unambiguousExactMatch` fires a keyword when it is the
/// single exact match and no longer enabled keyword starts with it. That prefix
/// relation runs one way, so its two ends are two different failures on two
/// different snippets — and anything that tests only one end protects the
/// keyword being typed while silently killing the one already in the library.
nonisolated enum KeywordRelation: Equatable {
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
nonisolated enum KeywordSuggestions {
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

    /// Existing library keywords that help a person keep a naming convention
    /// while they type. These are references, not safe-to-use suggestions: an
    /// exact result may already belong to another snippet and selecting it would
    /// create the duplicate that the editor's conflict warning rejects.
    ///
    /// The ordinary substring cases make `doc` find both `doc.frontend` and
    /// `frontend.doc`. When more than one dot-separated part has been typed, the
    /// final fallback also ignores their order, so an accidental
    /// `frontend.doc` still points back to an existing `doc.frontend`.
    static func existingMatches(query rawQuery: String, among rawKeywords: [String]) -> [String] {
        let query = foldedKeyword(rawQuery)
        guard !query.isEmpty else { return [] }

        var seen = Set<String>()
        return rawKeywords.compactMap { rawKeyword -> (keyword: String, folded: String, rank: Int)? in
            let keyword = Snippet.sanitizedKeyword(rawKeyword)
            let folded = foldedKeyword(keyword)
            guard !folded.isEmpty, seen.insert(folded).inserted,
                  let rank = existingMatchRank(query: query, candidate: folded) else { return nil }
            return (keyword, folded, rank)
        }.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.folded != rhs.folded { return lhs.folded < rhs.folded }
            return lhs.keyword < rhs.keyword
        }.map(\.keyword)
    }

    /// The deterministic part of a shell-style Tab completion against existing
    /// library keywords.
    ///
    /// This deliberately has stricter semantics than `existingMatches`: the
    /// reference row may find a component in the middle of a keyword or in a
    /// different order, but completion must only extend a prefix the person has
    /// actually typed. It never picks one candidate over another. Instead it
    /// inserts their common continuation, capped at the next dot or hyphen (the
    /// latter is how `Snippet.sanitizedKeyword` stores a typed space). A later
    /// Tab can therefore advance one human-readable part at a time.
    ///
    /// Returning `nil` means there is no safe progress, so the platform keeps
    /// Tab's ordinary focus-navigation behavior.
    static func tabCompletion(query rawQuery: String, among rawKeywords: [String]) -> String? {
        let query = Snippet.sanitizedKeyword(rawQuery)
        let foldedQuery = foldedKeyword(query)
        guard !foldedQuery.isEmpty else { return nil }

        var seen = Set<String>()
        let targets = rawKeywords.compactMap { rawKeyword -> String? in
            let candidate = Snippet.sanitizedKeyword(rawKeyword)
            let foldedCandidate = foldedKeyword(candidate)
            guard !foldedCandidate.isEmpty,
                  seen.insert(foldedCandidate).inserted,
                  let suffixStart = suffixStart(in: candidate, matching: foldedQuery),
                  suffixStart < candidate.endIndex else { return nil }

            let suffix = candidate[suffixStart...]
            let boundary = suffix.firstIndex(where: isCompletionBoundary)
            let end = boundary.map { candidate.index(after: $0) } ?? candidate.endIndex
            return query + candidate[suffixStart..<end]
        }
        guard let first = targets.first else { return nil }

        let commonFoldedPrefix = targets.dropFirst().reduce(foldedKeyword(first)) {
            sharedFoldedPrefix($0, foldedKeyword($1))
        }
        guard commonFoldedPrefix.count > foldedQuery.count,
              let result = prefix(in: first, foldingTo: commonFoldedPrefix),
              foldedKeyword(result) != foldedQuery else { return nil }
        return result
    }

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

    private static func foldedKeyword(_ keyword: String) -> String {
        SnippetTagging.filterKey(for: Snippet.sanitizedKeyword(keyword))
    }

    /// Finds the source-string boundary corresponding to a folded query. Walking
    /// real Character boundaries avoids assuming that case/diacritic folding
    /// preserves either UTF-8 or UTF-16 length.
    private static func suffixStart(in candidate: String, matching foldedQuery: String) -> String.Index? {
        var end = candidate.startIndex
        while end < candidate.endIndex {
            end = candidate.index(after: end)
            let foldedPrefix = foldedKeyword(String(candidate[..<end]))
            if foldedPrefix == foldedQuery { return end }
            if !foldedQuery.hasPrefix(foldedPrefix) { return nil }
        }
        return nil
    }

    private static func isCompletionBoundary(_ character: Character) -> Bool {
        character == "." || character == "-" || character.isWhitespace
    }

    private static func sharedFoldedPrefix(_ lhs: String, _ rhs: String) -> String {
        String(zip(lhs, rhs).prefix { $0.0 == $0.1 }.map(\.0))
    }

    private static func prefix(in source: String, foldingTo foldedPrefix: String) -> String? {
        var end = source.startIndex
        while end < source.endIndex {
            end = source.index(after: end)
            let candidate = String(source[..<end])
            let foldedCandidate = foldedKeyword(candidate)
            if foldedCandidate == foldedPrefix { return candidate }
            if !foldedPrefix.hasPrefix(foldedCandidate) { return nil }
        }
        return foldedKeyword(source) == foldedPrefix ? source : nil
    }

    /// Smaller is better. Whole-keyword relationships lead, followed by a
    /// matching dot component and finally an order-independent component match.
    private static func existingMatchRank(query: String, candidate: String) -> Int? {
        if candidate == query { return 0 }
        if candidate.hasPrefix(query) { return 1 }

        let queryParts = keywordParts(query)
        let candidateParts = keywordParts(candidate)
        if candidateParts.contains(query) { return 2 }
        if candidateParts.contains(where: { $0.hasPrefix(query) }) { return 3 }
        if candidate.contains(query) { return 4 }

        guard queryParts.count > 1,
              unorderedParts(queryParts, matchDistinctPartsIn: candidateParts) else { return nil }
        return 5
    }

    private static func keywordParts(_ keyword: String) -> [String] {
        keyword.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }

    /// Query parts are matched longest-first and consume candidate parts. This
    /// keeps `doc.doc` from matching a keyword with only one `doc` component and
    /// avoids a short partial stealing the only component a longer part can use.
    private static func unorderedParts(_ queryParts: [String], matchDistinctPartsIn candidateParts: [String]) -> Bool {
        guard candidateParts.count >= queryParts.count else { return false }

        var available = candidateParts
        for queryPart in queryParts.sorted(by: { $0.count > $1.count }) {
            guard let index = available.firstIndex(where: { $0.contains(queryPart) }) else { return false }
            available.remove(at: index)
        }
        return true
    }
}
