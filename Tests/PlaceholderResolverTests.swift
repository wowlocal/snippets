import AppKit
import Foundation

// Standalone executable, matching Tests/KeywordSuggestionsTests.swift.
// Build and run:
//
//   swiftc -O snippets/PlaceholderResolver.swift \
//          Tests/PlaceholderResolverTests.swift -o /tmp/placeholder-resolver-tests \
//          && /tmp/placeholder-resolver-tests

private func assertTrue(_ actual: Bool, _ message: String) {
    if !actual {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) — expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum PlaceholderResolverTests {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    static func run() {
        // The point of the whole file. The content editor's `{` completion and
        // the resolver read from the same place precisely so a menu can never
        // offer a token the resolver would leave sitting in the text. If someone
        // adds a token to the list without teaching the resolver about it, this
        // is what says so.
        assertTrue(
            PlaceholderResolver.completionTokensAllResolve(),
            "every token offered by { completion must be one the resolver replaces"
        )
        assertTrue(!PlaceholderResolver.completionTokens.isEmpty, "the completion list is not empty")

        // Each token is a complete `{…}` form, because completion replaces the
        // brace the user typed rather than appending after it.
        for token in PlaceholderResolver.completionTokens {
            assertTrue(token.hasPrefix("{"), "\(token) starts with a brace")
            assertTrue(token.hasSuffix("}"), "\(token) ends with a brace")
        }

        // Typing "{" offers all of them; typing "{da" narrows. The filter is a
        // plain prefix match on these strings, so this pins the vocabulary
        // against a rename that would silently empty the menu.
        let afterDa = PlaceholderResolver.completionTokens.filter { $0.hasPrefix("{da") }
        assertEqual(afterDa, ["{date}", "{datetime}", "{date:yyyy-MM-dd}"], "{da narrows to the date family")

        // The resolver's own contract, unchanged by this pass but relied on by
        // the completion list above.
        assertTrue(PlaceholderResolver.containsResolvablePlaceholder(in: "TP-{date:yyyyMMdd}-{clipboard}"),
                   "the starter snippet's content resolves")
        assertTrue(!PlaceholderResolver.containsResolvablePlaceholder(in: "{nonsense}"),
                   "an unknown token is not resolvable")
        assertTrue(!PlaceholderResolver.containsResolvablePlaceholder(in: "{date:}"),
                   "an empty date format is not resolvable")
        assertTrue(!PlaceholderResolver.containsResolvablePlaceholder(in: "no tokens at all"),
                   "plain text has nothing to resolve")

        print("PlaceholderResolverTests passed")
    }
}
