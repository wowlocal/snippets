import Foundation

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) - expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func assertNil<T>(_ actual: T?, _ message: String) {
    if actual != nil {
        fputs("FAIL: \(message) - expected nil, got \(String(describing: actual))\n", stderr)
        exit(1)
    }
}

@main
private enum SuggestionTriggerContextTests {
    static func main() {
        assertEqual(
            SuggestionTriggerContext.context(inTextBeforeCaret: "hello \\email"),
            SuggestionTriggerContext(query: "email", triggerLength: 6),
            "extracts query after trigger"
        )

        assertEqual(
            SuggestionTriggerContext.context(inTextBeforeCaret: "hello \\"),
            SuggestionTriggerContext(query: "", triggerLength: 1),
            "empty query after trigger is active"
        )

        assertEqual(
            SuggestionTriggerContext.context(inTextBeforeCaret: "\\first and \\sec"),
            SuggestionTriggerContext(query: "sec", triggerLength: 4),
            "uses last trigger before caret"
        )

        assertNil(
            SuggestionTriggerContext.context(inTextBeforeCaret: "\\first and text"),
            "whitespace after trigger ends keyword query"
        )

        assertNil(
            SuggestionTriggerContext.context(inTextBeforeCaret: "plain text"),
            "missing trigger is not active"
        )

        print("SuggestionTriggerContextTests passed")
    }
}
