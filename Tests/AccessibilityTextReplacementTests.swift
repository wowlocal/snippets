import Foundation

// Standalone executable, matching Tests/SuggestionTriggerContextTests.swift.
// Build and run:
//
//   swiftc -O snippets/SuggestionTriggerContext.swift snippets/AccessibilityTextReplacement.swift \
//          Tests/AccessibilityTextReplacementTests.swift -o /tmp/ax-replacement-tests \
//          && /tmp/ax-replacement-tests

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) - expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum AccessibilityTextReplacementTests {
    static func main() {
        testTriggerDeletion()
        testPlanArithmetic()
        testPlanRejection()
        testWriteLanded()
        testPolicy()
        print("AccessibilityTextReplacement tests passed")
    }

    private static func testTriggerDeletion() {
        let context = SuggestionTriggerContext(query: "email", triggerLength: 6)
        assertEqual(context.triggerText, "\\email", "trigger text is the backslash plus the query")
        assertTrue(TriggerDeletion.confirmed(context).isSelfConsistent, "confirmed deletion agrees with itself")
        assertEqual(TriggerDeletion.confirmed(context).characterCount, 6, "confirmed deletes trigger plus query")
        assertEqual(
            TriggerDeletion.confirmed(context).provenance,
            .accessibilityConfirmed,
            "a confirmed read is what allows failing closed"
        )

        let local = TriggerDeletion.localTracking(query: "email")
        assertEqual(local.characterCount, 6, "local tracking counts the backslash too")
        assertEqual(local.expectedText, "\\email", "local tracking reconstructs the trigger")
        assertEqual(local.provenance, .localTracking, "local tracking never fails closed")
        assertTrue(local.isSelfConsistent, "local deletion agrees with itself")

        // Auto-expansion suppresses the key that completed the keyword, so the host is one behind.
        let pending = TriggerDeletion.pendingLastCharacter(query: "email")
        assertEqual(pending.characterCount, 5, "the suppressed final key was never applied by the host")
        assertEqual(pending.expectedText, "\\emai", "the host holds the trigger minus that key")
        assertTrue(pending.isSelfConsistent, "pending deletion agrees with itself")

        let emptyQuery = SuggestionTriggerContext(query: "", triggerLength: 1)
        assertEqual(TriggerDeletion.confirmed(emptyQuery).expectedText, "\\", "a bare trigger is just the backslash")
        assertTrue(TriggerDeletion.confirmed(emptyQuery).isSelfConsistent, "bare trigger agrees with itself")

        let emoji = TriggerDeletion.localTracking(query: "🎉")
        assertTrue(emoji.isSelfConsistent, "grapheme counting stays consistent for emoji queries")
    }

    private static func testPlanArithmetic() {
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "hello \\email",
                caretRange: NSRange(location: 12, length: 0),
                expectedTrigger: "\\email",
                triggerCharacterCount: 6,
                replacementUTF16Length: 20
            ),
            .plan(.init(replacementRange: NSRange(location: 6, length: 6), caretLocation: 26)),
            "plain ASCII maps one character to one UTF-16 unit"
        )

        // The caret offset is UTF-16 (7) while the read text is 6 characters: the trigger length must
        // come from the trigger's own UTF-16 width, not from the string's character count.
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "👋 \\em",
                caretRange: NSRange(location: 7, length: 0),
                expectedTrigger: "\\em",
                triggerCharacterCount: 3,
                replacementUTF16Length: 4
            ),
            .plan(.init(replacementRange: NSRange(location: 4, length: 3), caretLocation: 8)),
            "an emoji before the trigger shifts UTF-16 offsets but not the trigger width"
        )

        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "hi \\🎉",
                caretRange: NSRange(location: 6, length: 0),
                expectedTrigger: "\\🎉",
                triggerCharacterCount: 2,
                replacementUTF16Length: 3
            ),
            .plan(.init(replacementRange: NSRange(location: 3, length: 3), caretLocation: 6)),
            "an emoji inside the trigger is three UTF-16 units, not two"
        )

        // An active selection is folded into the replaced range instead of costing an extra backspace.
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "hello \\em",
                caretRange: NSRange(location: 9, length: 4),
                expectedTrigger: "\\em",
                triggerCharacterCount: 3,
                replacementUTF16Length: 5
            ),
            .plan(.init(replacementRange: NSRange(location: 6, length: 7), caretLocation: 11)),
            "the selection joins the replaced range and does not move the caret"
        )

        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "line one\n\\em",
                caretRange: NSRange(location: 12, length: 0),
                expectedTrigger: "\\em",
                triggerCharacterCount: 3,
                replacementUTF16Length: 2
            ),
            .plan(.init(replacementRange: NSRange(location: 9, length: 3), caretLocation: 11)),
            "newlines before the caret are ordinary characters"
        )
    }

    private static func testPlanRejection() {
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "hello \\other",
                caretRange: NSRange(location: 12, length: 0),
                expectedTrigger: "\\email",
                triggerCharacterCount: 6,
                replacementUTF16Length: 3
            ),
            .rejected,
            "different text before the caret is rejected, never guessed at"
        )
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "\\EMAIL",
                caretRange: NSRange(location: 6, length: 0),
                expectedTrigger: "\\email",
                triggerCharacterCount: 6,
                replacementUTF16Length: 3
            ),
            .rejected,
            "the comparison is exact, including case"
        )
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "\\em",
                caretRange: NSRange(location: 3, length: 0),
                expectedTrigger: "\\email",
                triggerCharacterCount: 6,
                replacementUTF16Length: 3
            ),
            .rejected,
            "too little text before the caret means the field changed"
        )
        // Offsets contradicting the text is a broken AX model, not proof the text moved — the event
        // path can still handle it.
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "\\email",
                caretRange: NSRange(location: 3, length: 0),
                expectedTrigger: "\\email",
                triggerCharacterCount: 6,
                replacementUTF16Length: 3
            ),
            .unavailable,
            "a caret offset shorter than the trigger is unavailable, not rejected"
        )
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "\\email",
                caretRange: NSRange(location: 6, length: 0),
                expectedTrigger: "\\emai",
                triggerCharacterCount: 6,
                replacementUTF16Length: 3
            ),
            .unavailable,
            "a caller whose own count disagrees with its text is refused"
        )
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "\\email",
                caretRange: NSRange(location: 6, length: 0),
                expectedTrigger: "",
                triggerCharacterCount: 0,
                replacementUTF16Length: 3
            ),
            .unavailable,
            "there is nothing to replace without a trigger"
        )
        assertEqual(
            AccessibilityTextReplacement.plan(
                textBeforeCaret: "",
                caretRange: NSRange(location: 0, length: 0),
                expectedTrigger: "\\em",
                triggerCharacterCount: 3,
                replacementUTF16Length: 3
            ),
            .rejected,
            "a caret at the very start cannot hold the trigger"
        )
    }

    private static func testWriteLanded() {
        let plan = AccessibilityTextReplacement.Plan(
            replacementRange: NSRange(location: 6, length: 6),
            caretLocation: 11
        )
        assertTrue(
            AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email",
                valueAfter: "hello world",
                plan: plan,
                replacement: "world"
            ),
            "the replacement is found where it was written"
        )
        assertTrue(
            !AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email",
                valueAfter: "hello \\email",
                plan: plan,
                replacement: "world"
            ),
            "a silent no-op is not a delivery"
        )
        // Hosts normalize what they store; the expected length delta still proves the edit landed.
        assertTrue(
            AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email",
                valueAfter: "hello WORLD",
                plan: plan,
                replacement: "world"
            ),
            "a normalized insertion of the same length still counts"
        )
        assertTrue(
            !AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email",
                valueAfter: "hi",
                plan: plan,
                replacement: "world"
            ),
            "an unrelated field value is not a delivery"
        )
    }

    private static func testPolicy() {
        assertEqual(
            AccessibilityReplacementPolicy.action(for: .delivered, provenance: .accessibilityConfirmed),
            .commit,
            "a delivered replacement commits"
        )
        assertEqual(
            AccessibilityReplacementPolicy.action(for: .delivered, provenance: .localTracking),
            .commit,
            "provenance does not matter once the write landed"
        )
        assertEqual(
            AccessibilityReplacementPolicy.action(for: .unavailable, provenance: .accessibilityConfirmed),
            .useEvents,
            "a field without writable attributes falls back to events"
        )
        assertEqual(
            AccessibilityReplacementPolicy.action(for: .unavailable, provenance: .localTracking),
            .useEvents,
            "the same fallback applies to locally tracked counts"
        )
        // Failing closed only makes sense when Accessibility vouched for the count in the first place.
        assertEqual(
            AccessibilityReplacementPolicy.action(for: .rejected, provenance: .accessibilityConfirmed),
            .abort,
            "a confirmed count that no longer matches must not type blindly"
        )
        assertEqual(
            AccessibilityReplacementPolicy.action(for: .rejected, provenance: .localTracking),
            .useEvents,
            "lagging Accessibility in Chromium keeps the working event path"
        )
    }
}
