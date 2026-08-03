import Foundation

// Standalone executable, matching Tests/SuggestionTriggerContextTests.swift.
// Build and run:
//
//   swiftc -O snippets/SnippetPasteConfirmation.swift \
//          Tests/SnippetPasteConfirmationTests.swift -o /tmp/paste-confirmation-tests \
//          && /tmp/paste-confirmation-tests

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

private func fingerprint(
    caret: Int,
    selection: Int = 0,
    tail: String = ""
) -> PasteCaretFingerprint {
    PasteCaretFingerprint(caretLocation: caret, selectionLength: selection, textBeforeCaret: tail)
}

private func input(
    attempt: Int,
    elapsedMilliseconds: Int,
    progress: PasteProgress,
    hadFingerprintBeforePaste: Bool = true,
    sawReadableFingerprintAfterPaste: Bool = true,
    firstForwardEditAttempt: Int? = nil,
    abort: PasteConfirmationAbort? = nil
) -> SnippetPasteConfirmationPolicy.Input {
    SnippetPasteConfirmationPolicy.Input(
        attempt: attempt,
        elapsed: .milliseconds(elapsedMilliseconds),
        progress: progress,
        hadFingerprintBeforePaste: hadFingerprintBeforePaste,
        sawReadableFingerprintAfterPaste: sawReadableFingerprintAfterPaste,
        firstForwardEditAttempt: firstForwardEditAttempt,
        abort: abort
    )
}

@main
private enum SnippetPasteConfirmationTests {
    static func main() {
        testProgress()
        testVerdict()
        testConfirmationTail()
        testBlindPathStaysConservative()
        print("SnippetPasteConfirmation tests passed")
    }

    private static func testProgress() {
        assertEqual(
            SnippetPasteConfirmationPolicy.progress(
                before: fingerprint(caret: 10),
                after: fingerprint(caret: 15),
                pastedText: "hello",
                tailLength: 32
            ),
            .pasteObserved,
            "the caret advanced by exactly the pasted length"
        )
        // utf16.count differs from character count here; measuring in the wrong unit misses the paste.
        assertEqual(
            SnippetPasteConfirmationPolicy.progress(
                before: fingerprint(caret: 4),
                after: fingerprint(caret: 6),
                pastedText: "🎉",
                tailLength: 32
            ),
            .pasteObserved,
            "an emoji snippet advances the caret by its UTF-16 width"
        )
        // Chromium can reset the caret into a fresh node, so the delta lies but the tail does not.
        assertEqual(
            SnippetPasteConfirmationPolicy.progress(
                before: fingerprint(caret: 40, tail: "\\sig"),
                after: fingerprint(caret: 5, tail: "Regards"),
                pastedText: "Regards",
                tailLength: 32
            ),
            .pasteObserved,
            "a matching tail confirms even when the caret location was reset"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.progress(
                before: fingerprint(caret: 10, tail: "Regards"),
                after: fingerprint(caret: 10, tail: "Regards"),
                pastedText: "Regards",
                tailLength: 32
            ),
            .idle,
            "an unchanged field never confirms, even when its tail already matched"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.progress(
                before: fingerprint(caret: 10, tail: "\\sig"),
                after: fingerprint(caret: 12, tail: "abc"),
                pastedText: "Regards",
                tailLength: 32
            ),
            .forwardEditObserved,
            "forward motion by the wrong amount is a normalized edit, not a confirmed paste"
        )
        // Our own backspaces are still arriving; confirming here would restore the clipboard early.
        assertEqual(
            SnippetPasteConfirmationPolicy.progress(
                before: fingerprint(caret: 10, tail: "\\sig"),
                after: fingerprint(caret: 7, tail: "\\s"),
                pastedText: "Regards",
                tailLength: 32
            ),
            .pendingEditObserved,
            "the caret moving backwards means deletions, not delivery"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.progress(
                before: nil,
                after: fingerprint(caret: 5),
                pastedText: "x",
                tailLength: 32
            ),
            .unreadable,
            "no baseline means nothing to compare"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.progress(
                before: fingerprint(caret: 5),
                after: nil,
                pastedText: "x",
                tailLength: 32
            ),
            .unreadable,
            "a host that stopped answering is unreadable"
        )
    }

    private static func testVerdict() {
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(input(attempt: 0, elapsedMilliseconds: 0, progress: .pasteObserved)),
            .confirmed,
            "an observed paste confirms on the first poll"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(
                input(attempt: 0, elapsedMilliseconds: 0, progress: .forwardEditObserved, firstForwardEditAttempt: 0)
            ),
            .keepWaiting,
            "a normalized edit waits for a stronger signal first"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(
                input(attempt: 5, elapsedMilliseconds: 100, progress: .forwardEditObserved, firstForwardEditAttempt: 0)
            ),
            .confirmed,
            "a normalized edit confirms once the grace window passes"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(input(attempt: 59, elapsedMilliseconds: 1180, progress: .idle)),
            .keepWaiting,
            "an idle host keeps waiting inside the budget"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(input(attempt: 60, elapsedMilliseconds: 1200, progress: .idle)),
            .timedOut,
            "the attempt ceiling ends the wait"
        )
        // A stalled host makes each poll cost up to the AX messaging timeout, so attempts alone are
        // not a bound.
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(input(attempt: 3, elapsedMilliseconds: 1200, progress: .idle)),
            .timedOut,
            "the wall-clock ceiling ends the wait independently of the attempt count"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(
                input(attempt: 19, elapsedMilliseconds: 380, progress: .unreadable, hadFingerprintBeforePaste: false)
            ),
            .keepWaiting,
            "a blind host is held for the full conservative delay"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(
                input(attempt: 20, elapsedMilliseconds: 400, progress: .unreadable, hadFingerprintBeforePaste: false)
            ),
            .confirmed,
            "a terminal with no readable state is accepted after the conservative delay"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(
                input(
                    attempt: 20,
                    elapsedMilliseconds: 400,
                    progress: .unreadable,
                    sawReadableFingerprintAfterPaste: false
                )
            ),
            .confirmed,
            "a host that went quiet right after the paste is accepted too"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(input(attempt: 30, elapsedMilliseconds: 600, progress: .idle)),
            .keepWaiting,
            "a host that answers but shows nothing is not accepted blindly"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.verdict(
                input(attempt: 0, elapsedMilliseconds: 0, progress: .pasteObserved, abort: .pasteboardSuperseded)
            ),
            .abandoned(.pasteboardSuperseded),
            "an abort outranks every other signal"
        )
    }

    private static func testConfirmationTail() {
        assertEqual(
            SnippetPasteConfirmationPolicy.confirmationTail(of: "Regards,\nMike\n", maxLength: 32),
            "Mike",
            "trailing newlines are dropped and only the last line is comparable"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.confirmationTail(of: "hello", maxLength: 3),
            "llo",
            "the tail is bounded"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.confirmationTail(of: "   \n  ", maxLength: 32),
            "  ",
            "whitespace-only text yields whatever whitespace remains"
        )
        assertEqual(
            SnippetPasteConfirmationPolicy.confirmationTail(of: "\n", maxLength: 32),
            "",
            "a newline-only snippet has no comparable tail, disabling the suffix check"
        )
    }

    private static func testBlindPathStaysConservative() {
        let tuning = SnippetPasteConfirmationPolicy.Tuning.default
        let blindHold = tuning.pollInterval * tuning.blindAcceptAttempt
        // The behaviour this replaced held the clipboard for a flat 350 ms. Tuning must never make
        // the blind path — the one with no evidence at all — riskier than what already shipped.
        assertTrue(
            blindHold >= .milliseconds(350),
            "the blind accept delay stays at least as conservative as the fixed delay it replaced"
        )
        assertTrue(
            tuning.maxWait > blindHold,
            "the overall budget outlasts the blind accept delay"
        )
    }
}
