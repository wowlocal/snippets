import Foundation

// Standalone executable, matching Tests/SuggestionTriggerContextTests.swift.
// Build and run:
//
//   swiftc -O snippets/Core/Snippet.swift snippets/KeywordSuggestions.swift \
//          Tests/KeywordSuggestionsTests.swift -o /tmp/keyword-suggestion-tests \
//          && /tmp/keyword-suggestion-tests

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) — expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum KeywordSuggestionsTests {
    static func main() {
        // The trap: a one-directional filter offers `email` beside an existing
        // `\em` and stops `\em` from expanding. Both ends have to be visible.
        assertEqual(KeywordRelation.between("email", "em"), .blocksShorter, "longer candidate kills the incumbent")
        assertEqual(KeywordRelation.between("em", "email"), .blockedByLonger, "shorter candidate is swallowed")
        assertEqual(KeywordRelation.between("sig", "sig"), .duplicate, "exact match")
        // The same correction applied to append-a-digit disambiguation.
        assertEqual(KeywordRelation.between("sig2", "sig"), .blocksShorter, "sig2 beside sig kills sig")
        assertEqual(KeywordRelation.between("sig", "tp"), .unrelated, "nothing in common")

        // A label abbreviates two ways: the opening word and the initials.
        assertEqual(
            KeywordSuggestions.candidates(name: "Signature Block", contentFirstLine: "Best regards"),
            ["sign", "sig", "sb", "best"],
            "name-first candidates, then content"
        )
        // Short enough to type as it stands.
        assertEqual(
            KeywordSuggestions.candidates(name: "Email", contentFirstLine: ""),
            ["email"],
            "a short word is offered whole"
        )
        // Diacritics fold the way the engine folds them, so the keyword stays typeable.
        assertEqual(
            KeywordSuggestions.candidates(name: "Café Order", contentFirstLine: ""),
            ["cafe", "co"],
            "folded, not truncated at the accent"
        )
        // Content is a sentence: its initials spell nothing, so only its first real
        // word is offered — and the URL scheme is stepped over rather than offered.
        assertEqual(
            KeywordSuggestions.candidates(name: "", contentFirstLine: "https://github.com/mike/snippets"),
            ["github"],
            "the scheme is not a keyword, the host might be"
        )
        assertEqual(
            KeywordSuggestions.candidates(name: "", contentFirstLine: "Thanks so much for the update"),
            ["thanks"],
            "no initials from content"
        )
        // Nothing to derive from beats junk derived from nothing.
        assertEqual(KeywordSuggestions.candidates(name: "", contentFirstLine: ""), [], "empty snippet offers nothing")
        assertEqual(KeywordSuggestions.candidates(name: "日本語", contentFirstLine: "こんにちは"), [], "no typeable word")
        assertEqual(KeywordSuggestions.candidates(name: "A", contentFirstLine: ""), [], "one character is not a keyword")
        assertEqual(
            KeywordSuggestions.candidates(name: "A B", contentFirstLine: ""),
            ["ab"],
            "initials survive where the single-letter word does not"
        )
        // Duplicates collapse: the whole name and its own first word are one candidate.
        assertEqual(
            KeywordSuggestions.candidates(name: "Invoice", contentFirstLine: "Invoice for services"),
            ["invo", "inv"],
            "name and content agreeing produce one pair, not two"
        )

        print("KeywordSuggestionsTests passed")
    }
}
