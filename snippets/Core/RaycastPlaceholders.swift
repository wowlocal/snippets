import Foundation

// Compiled into the app and the test package — see `Snippet.swift`. Only the import
// path calls this: `SnippetLibraryCodec.decode` deliberately does not know the Raycast
// dialect exists, and moving this here must not change that.

nonisolated enum RaycastPlaceholders {
    /// Legacy Raycast exports used this spelling. Current Raycast uses
    /// `{date format="…"}` directly, which `PlaceholderResolver` understands and
    /// therefore needs no rewrite. Keeping this compatibility parser here means an
    /// old export and a current export converge on the same explicit, quoted grammar.
    private static let legacyTemporalRegex = try? NSRegularExpression(
        pattern: #"\{(date|time|datetime) "([^"]+)"\}"#
    )

    /// Rewrites the legacy `{date "…"}` family into the current
    /// `{date format="…"}` spelling — but only when `PlaceholderResolver` can read the
    /// entire result back. Current Raycast placeholders are already in that spelling
    /// and pass through byte for byte.
    ///
    /// This used to be a blind `stringByReplacingMatches` with the template `{date:$1}`,
    /// which accepted anything between the quotes. Anything the resolver's token grammar
    /// then rejected passed through the resolver untouched *by design*, so an imported
    /// library typed the literal text `{date:MMM d, yyyy}` into the user's document on
    /// every expansion. The explicit quoted grammar handles spaces, punctuation,
    /// Unicode and ICU quoted literals without making compact code such as
    /// `{date:value,time:value}` ambiguous. The full-token guard below closes the rest
    /// of the space: when it fires the legacy spelling is left exactly as written rather
    /// than manufacturing an inert native-looking token.
    static func converted(_ text: String) -> String {
        guard let legacyTemporalRegex else { return text }

        let range = NSRange(text.startIndex..., in: text)
        var converted = text

        // Reversed, like `PlaceholderResolver.resolve`: the ranges are measured against
        // `text` and applied to `converted`, so replacements have to run back to front.
        for match in legacyTemporalRegex.matches(in: text, options: [], range: range).reversed() {
            guard
                match.numberOfRanges == 3,
                let kindRange = Range(match.range(at: 1), in: text),
                let patternRange = Range(match.range(at: 2), in: text),
                let fullRange = Range(match.range(at: 0), in: text)
            else {
                continue
            }

            let token = "{\(text[kindRange]) format=\"\(text[patternRange])\"}"
            guard PlaceholderResolver.isResolvablePlaceholder(token) else { continue }
            converted.replaceSubrange(fullRange, with: token)
        }

        return converted
    }
}
