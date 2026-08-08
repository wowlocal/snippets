import Foundation

// Compiled into the app and the test package — see `Snippet.swift`. Only the import
// path calls this: `SnippetLibraryCodec.decode` deliberately does not know the Raycast
// dialect exists, and moving this here must not change that.

nonisolated enum RaycastPlaceholders {
    private static let dateRegex = try? NSRegularExpression(
        pattern: #"\{date "([^"]+)"\}"#
    )

    /// Rewrites Raycast's `{date "…"}` into this app's `{date:…}` — but only when the
    /// result is a token `PlaceholderResolver` will actually read back.
    ///
    /// This used to be a blind `stringByReplacingMatches` with the template `{date:$1}`,
    /// which accepted anything between the quotes. Anything the resolver's token grammar
    /// then rejected passed through the resolver untouched *by design*, so an imported
    /// library typed the literal text `{date:MMM d, yyyy}` into the user's document on
    /// every expansion. Widening that grammar fixed the common formats; this guard is
    /// what closes the rest of the space, because there will always be a format the
    /// grammar does not admit and the importer must not be the thing that invents a
    /// dead token. When the guard fires the Raycast spelling is left exactly as written:
    /// still inert, but visibly foreign, and the user's own text is never rewritten into
    /// something that merely looks native.
    static func converted(_ text: String) -> String {
        guard let dateRegex else { return text }

        let range = NSRange(text.startIndex..., in: text)
        var converted = text

        // Reversed, like `PlaceholderResolver.resolve`: the ranges are measured against
        // `text` and applied to `converted`, so replacements have to run back to front.
        for match in dateRegex.matches(in: text, options: [], range: range).reversed() {
            guard
                match.numberOfRanges == 2,
                let patternRange = Range(match.range(at: 1), in: text),
                let fullRange = Range(match.range(at: 0), in: text)
            else {
                continue
            }

            let token = "{date:\(text[patternRange])}"
            guard PlaceholderResolver.isResolvablePlaceholder(token) else { continue }
            converted.replaceSubrange(fullRange, with: token)
        }

        return converted
    }
}
