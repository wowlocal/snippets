import Foundation
import Testing

@testable import SnippetsCore

// The gate decides whether a keystroke belongs to the user, to us, or to a system
// authentication sheet — and the paste path decides when it is safe to give the
// clipboard back. Both are pure decision tables, so every case below is the failure
// it prevents rather than the branch it happens to walk.

// MARK: - Fixtures

/// The two processes every activation rule is written against: us, and the app whose
/// caret we saved.
private let ownPID: Int32 = 10
private let targetPID: Int32 = 20

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

// MARK: - Suite

@Suite("Injection gate and paste confirmation")
struct InjectionGateTests {

    // MARK: 1. Synthetic event tag

    @Suite("Synthetic event tag")
    struct SyntheticTagTests {

        @Test func ourOwnTagIsRecognizedAndEveryOtherValueReadsAsUserInput() {
            #expect(
                SnippetSyntheticEvent.origin(eventUserData: SnippetSyntheticEvent.tag)
                    == .selfInjected,
                "our own tag is recognized"
            )
            #expect(
                SnippetSyntheticEvent.origin(eventUserData: 0) == .user,
                "real keystrokes carry zero"
            )
            #expect(
                SnippetSyntheticEvent.origin(eventUserData: nil) == .user,
                "a missing field fails open to user input"
            )
            #expect(
                SnippetSyntheticEvent.origin(eventUserData: SnippetSyntheticEvent.tag &+ 1) == .user,
                "neighbouring values are not ours"
            )
            #expect(
                SnippetSyntheticEvent.origin(eventUserData: 1) == .user,
                "small values another automation tool might use are not ours"
            )
        }

        @Test func theTagStaysClearOfTheValuesOtherAutomationToolsPlausiblyUse() {
            #expect(SnippetSyntheticEvent.tag != 0, "tag must be distinguishable from real input")
            #expect(
                SnippetSyntheticEvent.tag > 0xFFFF,
                "tag stays clear of the small values other tools plausibly use"
            )
        }
    }

    // MARK: 2. Refusal precedence

    @Suite("Refusal precedence")
    struct RefusalTests {

        @Test func secureInputOutranksEveryOtherRefusal() {
            #expect(
                SnippetInjectionGate.refusal(
                    secureEventInputEnabled: true,
                    isSecureSnippet: true,
                    secureSnippetIsAuthenticated: false,
                    isListening: false,
                    ownAppIsFrontmost: true,
                    deleteCount: 0
                ) == .secureEventInput,
                "secure input outranks every other refusal"
            )
            #expect(
                SnippetInjectionGate.refusal(
                    secureEventInputEnabled: true,
                    isSecureSnippet: false,
                    secureSnippetIsAuthenticated: false,
                    isListening: true,
                    ownAppIsFrontmost: false,
                    deleteCount: 6
                ) == .secureEventInput,
                "secure input refuses an otherwise valid expansion"
            )
        }

        @Test func aSecureSnippetIsRefusedBeforeAnyTriggerDeletionUnlessItIsAuthenticated() {
            #expect(
                SnippetInjectionGate.refusal(
                    secureEventInputEnabled: false,
                    isSecureSnippet: true,
                    secureSnippetIsAuthenticated: false,
                    isListening: true,
                    ownAppIsFrontmost: false,
                    deleteCount: 6
                ) == .secureSnippetRequiresAuthentication,
                "a secure display shell is refused before any trigger deletion"
            )
            #expect(
                SnippetInjectionGate.refusal(
                    secureEventInputEnabled: false,
                    isSecureSnippet: true,
                    secureSnippetIsAuthenticated: true,
                    isListening: true,
                    ownAppIsFrontmost: false,
                    deleteCount: 6
                ) == nil,
                "an explicitly authenticated secure expansion is allowed"
            )
        }

        @Test func anEmptyDeletionAndOurOwnFrontmostWindowAreBothRefused() {
            #expect(
                SnippetInjectionGate.refusal(
                    secureEventInputEnabled: false,
                    isSecureSnippet: false,
                    secureSnippetIsAuthenticated: false,
                    isListening: true,
                    ownAppIsFrontmost: false,
                    deleteCount: 0
                ) == .nothingToDelete,
                "an empty deletion is refused"
            )
            #expect(
                SnippetInjectionGate.refusal(
                    secureEventInputEnabled: false,
                    isSecureSnippet: false,
                    secureSnippetIsAuthenticated: false,
                    isListening: true,
                    ownAppIsFrontmost: true,
                    deleteCount: 6
                ) == .ownAppIsFrontmost,
                "we never inject into ourselves"
            )
        }

        @Test func aHealthyExpansionIsAllowed() {
            #expect(
                SnippetInjectionGate.refusal(
                    secureEventInputEnabled: false,
                    isSecureSnippet: false,
                    secureSnippetIsAuthenticated: false,
                    isListening: true,
                    ownAppIsFrontmost: false,
                    deleteCount: 6
                ) == nil,
                "a healthy expansion is allowed"
            )
        }
    }

    // MARK: 3. Input disposition

    @Suite("Input disposition")
    struct InputDispositionTests {

        @Test func aSpaceShortcutUsesActualFocusInsteadOfItsModifiers() {
            #expect(
                !SnippetInjectionGate.spaceShortcutFocusInvalidatesContext(
                    inputSourceChanged: false,
                    expectedTargetPID: targetPID,
                    focusedApplicationPID: targetPID,
                    frontmostApplicationPID: targetPID),
                "a shortcut that leaves keyboard focus in the target preserves the context"
            )
            #expect(
                SnippetInjectionGate.spaceShortcutFocusInvalidatesContext(
                    inputSourceChanged: false,
                    expectedTargetPID: targetPID,
                    focusedApplicationPID: 30,
                    frontmostApplicationPID: targetPID),
                "system-wide keyboard focus catches a nonactivating launcher"
            )
            #expect(
                SnippetInjectionGate.spaceShortcutFocusInvalidatesContext(
                    inputSourceChanged: false,
                    expectedTargetPID: targetPID,
                    focusedApplicationPID: nil,
                    frontmostApplicationPID: 30),
                "NSWorkspace remains the fallback when AX focus is unavailable"
            )
            #expect(
                !SnippetInjectionGate.spaceShortcutFocusInvalidatesContext(
                    inputSourceChanged: false,
                    expectedTargetPID: targetPID,
                    focusedApplicationPID: nil,
                    frontmostApplicationPID: nil),
                "an unavailable post-shortcut observation does not guess that focus moved"
            )
            #expect(
                SnippetInjectionGate.spaceShortcutFocusInvalidatesContext(
                    inputSourceChanged: false,
                    expectedTargetPID: nil,
                    focusedApplicationPID: targetPID,
                    frontmostApplicationPID: targetPID),
                "without an original target there is no context safe to retain"
            )
            #expect(
                !SnippetInjectionGate.spaceShortcutFocusInvalidatesContext(
                    inputSourceChanged: true,
                    expectedTargetPID: targetPID,
                    focusedApplicationPID: 30,
                    frontmostApplicationPID: targetPID),
                "an actual input-source change wins over transient switcher focus"
            )
        }

        @Test func ourOwnEventsAreIgnoredEvenWhenNothingElseWouldSkipThem() {
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .selfInjected,
                    secureEventInputEnabled: false,
                    isListening: true,
                    isInjecting: false,
                    ownAppIsFrontmost: false
                ) == .ignore,
                "our own events are skipped even when nothing else would skip them"
            )
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .selfInjected,
                    secureEventInputEnabled: true,
                    isListening: true,
                    isInjecting: true,
                    ownAppIsFrontmost: false
                ) == .ignore,
                "synthetic outranks secure input: our event must not be read as typing that resets"
            )
        }

        @Test func secureInputDropsStateWithoutSuppressingTheKey() {
            // The regression this guards: never swallow keys while the user types a password.
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .user,
                    secureEventInputEnabled: true,
                    isListening: true,
                    isInjecting: false,
                    ownAppIsFrontmost: false
                ) == .resetAndPassThrough,
                "secure input drops state without suppressing the key"
            )
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .user,
                    secureEventInputEnabled: true,
                    isListening: true,
                    isInjecting: true,
                    ownAppIsFrontmost: false
                ) == .resetAndPassThrough,
                "secure input flipping mid-injection still clears the buffer"
            )
        }

        @Test func theAuthenticationSheetPassesKeysThroughWithoutCollectingThem() {
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .user,
                    secureEventInputEnabled: true,
                    isListening: true,
                    isInjecting: true,
                    ownAppIsFrontmost: false,
                    isAuthenticatingSecureSuggestion: true
                ) == .ignore,
                "password fallback passes through without invalidating its saved target"
            )
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .user,
                    secureEventInputEnabled: false,
                    isListening: true,
                    isInjecting: true,
                    ownAppIsFrontmost: true,
                    isAuthenticatingSecureSuggestion: true
                ) == .ignore,
                "authentication-sheet typing is never collected as a snippet query"
            )
        }

        @Test func inputDuringInjectionOrWhileStoppedIsIgnored() {
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .user,
                    secureEventInputEnabled: false,
                    isListening: true,
                    isInjecting: true,
                    ownAppIsFrontmost: false
                ) == .ignore,
                "user input during injection is ignored, not treated as typing"
            )
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .user,
                    secureEventInputEnabled: false,
                    isListening: false,
                    isInjecting: false,
                    ownAppIsFrontmost: false
                ) == .ignore,
                "a stopped engine ignores input"
            )
        }

        @Test func typingInOurOwnWindowResetsWhileOrdinaryTypingIsProcessed() {
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .user,
                    secureEventInputEnabled: false,
                    isListening: true,
                    isInjecting: false,
                    ownAppIsFrontmost: true
                ) == .resetAndPassThrough,
                "typing in our own window resets the tracked context"
            )
            #expect(
                SnippetInjectionGate.inputDisposition(
                    origin: .user,
                    secureEventInputEnabled: false,
                    isListening: true,
                    isInjecting: false,
                    ownAppIsFrontmost: false
                ) == .process,
                "ordinary typing is processed"
            )
        }
    }

    // MARK: 4. Activation invalidation

    @Suite("Activation invalidation")
    struct ActivationTests {

        @Test func ourOwnAuthenticationActivationDoesNotInvalidateItsOwnPendingExpansion() {
            #expect(
                !SnippetInjectionGate.applicationActivationInvalidatesContext(
                    activatedPID: ownPID,
                    ownPID: ownPID,
                    secureAuthenticationTargetPID: targetPID,
                    secureEventInputEnabled: true),
                "our Touch ID activation does not invalidate its own pending expansion"
            )
            #expect(
                !SnippetInjectionGate.applicationActivationInvalidatesContext(
                    activatedPID: targetPID,
                    ownPID: ownPID,
                    secureAuthenticationTargetPID: targetPID,
                    secureEventInputEnabled: false),
                "returning focus to the authenticated target is expected"
            )
        }

        @Test func aStaleAuthenticationActivationCannotCancelInsertionIntoTheStillFrontmostTarget() {
            #expect(
                !SnippetInjectionGate.applicationActivationInvalidatesContext(
                    activatedPID: 30,
                    currentFrontmostPID: targetPID,
                    ownPID: ownPID,
                    secureAuthenticationTargetPID: nil,
                    secureExpansionTargetPID: targetPID,
                    secureEventInputEnabled: false),
                "a stale authentication activation cannot cancel insertion into the still-frontmost target"
            )
        }

        @Test func aRealSwitchAwayFromTheRestoredTargetStillCancelsInsertion() {
            #expect(
                SnippetInjectionGate.applicationActivationInvalidatesContext(
                    activatedPID: 30,
                    currentFrontmostPID: 30,
                    ownPID: ownPID,
                    secureAuthenticationTargetPID: nil,
                    secureExpansionTargetPID: targetPID,
                    secureEventInputEnabled: false),
                "a real switch away from the restored target still cancels insertion"
            )
        }

        @Test func theNotificationPIDRemainsAFallbackWhenFrontmostStateIsUnavailable() {
            #expect(
                !SnippetInjectionGate.applicationActivationInvalidatesContext(
                    activatedPID: targetPID,
                    currentFrontmostPID: nil,
                    ownPID: ownPID,
                    secureAuthenticationTargetPID: nil,
                    secureExpansionTargetPID: targetPID,
                    secureEventInputEnabled: false),
                "the notification PID remains a fallback when frontmost state is unavailable"
            )
        }

        @Test func authenticationImplementationProcessesDoNotInvalidateTheSavedTarget() {
            #expect(
                !SnippetInjectionGate.applicationActivationInvalidatesContext(
                    activatedPID: 30,
                    ownPID: ownPID,
                    secureAuthenticationTargetPID: targetPID,
                    secureEventInputEnabled: false),
                "authentication implementation processes do not invalidate the saved target"
            )
        }

        @Test func unrelatedSecureInputStillTearsDownAnOrdinarySuggestion() {
            #expect(
                SnippetInjectionGate.applicationActivationInvalidatesContext(
                    activatedPID: 30,
                    ownPID: ownPID,
                    secureAuthenticationTargetPID: nil,
                    secureEventInputEnabled: true),
                "unrelated secure input still tears down an ordinary suggestion"
            )
        }

        @Test func ourNonactivatingSuggestionUIDoesNotInvalidateItsOwnSession() {
            #expect(
                !SnippetInjectionGate.applicationActivationInvalidatesContext(
                    activatedPID: ownPID,
                    ownPID: ownPID,
                    secureAuthenticationTargetPID: nil,
                    secureEventInputEnabled: false),
                "our nonactivating suggestion UI does not invalidate its own session"
            )
        }

        @Test func aPointerClickInvalidatesEverythingExceptThePendingAuthenticationFlow() {
            #expect(
                !SnippetInjectionGate.pointerInteractionInvalidatesContext(
                    secureAuthenticationTargetPID: targetPID),
                "clicking Use Password belongs to the pending authentication flow"
            )
            #expect(
                SnippetInjectionGate.pointerInteractionInvalidatesContext(
                    secureAuthenticationTargetPID: nil),
                "an ordinary global click still invalidates its caret snapshot"
            )
        }
    }

    // MARK: 5. Paste progress

    @Suite("Paste progress")
    struct PasteProgressTests {

        @Test func theCaretAdvancingByExactlyThePastedLengthIsAConfirmedPaste() {
            #expect(
                SnippetPasteConfirmationPolicy.progress(
                    before: fingerprint(caret: 10),
                    after: fingerprint(caret: 15),
                    pastedText: "hello",
                    tailLength: 32
                ) == .pasteObserved,
                "the caret advanced by exactly the pasted length"
            )
            // utf16.count differs from character count here; measuring in the wrong unit misses the paste.
            #expect(
                SnippetPasteConfirmationPolicy.progress(
                    before: fingerprint(caret: 4),
                    after: fingerprint(caret: 6),
                    pastedText: "🎉",
                    tailLength: 32
                ) == .pasteObserved,
                "an emoji snippet advances the caret by its UTF-16 width"
            )
        }

        @Test func aMatchingTailConfirmsEvenWhenTheCaretLocationWasReset() {
            // Chromium can reset the caret into a fresh node, so the delta lies but the tail does not.
            #expect(
                SnippetPasteConfirmationPolicy.progress(
                    before: fingerprint(caret: 40, tail: "\\sig"),
                    after: fingerprint(caret: 5, tail: "Regards"),
                    pastedText: "Regards",
                    tailLength: 32
                ) == .pasteObserved,
                "a matching tail confirms even when the caret location was reset"
            )
        }

        @Test func anUnchangedFieldNeverConfirmsEvenWhenItsTailAlreadyMatched() {
            #expect(
                SnippetPasteConfirmationPolicy.progress(
                    before: fingerprint(caret: 10, tail: "Regards"),
                    after: fingerprint(caret: 10, tail: "Regards"),
                    pastedText: "Regards",
                    tailLength: 32
                ) == .idle,
                "an unchanged field never confirms, even when its tail already matched"
            )
        }

        @Test func forwardMotionByTheWrongAmountIsANormalizedEditRatherThanAPaste() {
            #expect(
                SnippetPasteConfirmationPolicy.progress(
                    before: fingerprint(caret: 10, tail: "\\sig"),
                    after: fingerprint(caret: 12, tail: "abc"),
                    pastedText: "Regards",
                    tailLength: 32
                ) == .forwardEditObserved,
                "forward motion by the wrong amount is a normalized edit, not a confirmed paste"
            )
        }

        @Test func theCaretMovingBackwardsMeansDeletionsRatherThanDelivery() {
            // Our own backspaces are still arriving; confirming here would restore the clipboard early.
            #expect(
                SnippetPasteConfirmationPolicy.progress(
                    before: fingerprint(caret: 10, tail: "\\sig"),
                    after: fingerprint(caret: 7, tail: "\\s"),
                    pastedText: "Regards",
                    tailLength: 32
                ) == .pendingEditObserved,
                "the caret moving backwards means deletions, not delivery"
            )
        }

        @Test func aMissingFingerprintOnEitherSideIsUnreadable() {
            #expect(
                SnippetPasteConfirmationPolicy.progress(
                    before: nil,
                    after: fingerprint(caret: 5),
                    pastedText: "x",
                    tailLength: 32
                ) == .unreadable,
                "no baseline means nothing to compare"
            )
            #expect(
                SnippetPasteConfirmationPolicy.progress(
                    before: fingerprint(caret: 5),
                    after: nil,
                    pastedText: "x",
                    tailLength: 32
                ) == .unreadable,
                "a host that stopped answering is unreadable"
            )
        }
    }

    // MARK: 6. Paste verdict

    @Suite("Paste verdict")
    struct PasteVerdictTests {

        @Test func anObservedPasteConfirmsOnTheFirstPoll() {
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(attempt: 0, elapsedMilliseconds: 0, progress: .pasteObserved)
                ) == .confirmed,
                "an observed paste confirms on the first poll"
            )
        }

        @Test func aNormalizedEditWaitsForTheGraceWindowAndThenConfirms() {
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(
                        attempt: 0, elapsedMilliseconds: 0, progress: .forwardEditObserved,
                        firstForwardEditAttempt: 0)
                ) == .keepWaiting,
                "a normalized edit waits for a stronger signal first"
            )
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(
                        attempt: 5, elapsedMilliseconds: 100, progress: .forwardEditObserved,
                        firstForwardEditAttempt: 0)
                ) == .confirmed,
                "a normalized edit confirms once the grace window passes"
            )
        }

        @Test func theAttemptCeilingAndTheWallClockCeilingEachEndTheWaitOnTheirOwn() {
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(attempt: 59, elapsedMilliseconds: 1180, progress: .idle)
                ) == .keepWaiting,
                "an idle host keeps waiting inside the budget"
            )
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(attempt: 60, elapsedMilliseconds: 1200, progress: .idle)
                ) == .timedOut,
                "the attempt ceiling ends the wait"
            )
            // A stalled host makes each poll cost up to the AX messaging timeout, so attempts alone are
            // not a bound.
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(attempt: 3, elapsedMilliseconds: 1200, progress: .idle)
                ) == .timedOut,
                "the wall-clock ceiling ends the wait independently of the attempt count"
            )
        }

        @Test func aBlindHostIsHeldForTheFullConservativeDelayAndThenAccepted() {
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(
                        attempt: 19, elapsedMilliseconds: 380, progress: .unreadable,
                        hadFingerprintBeforePaste: false)
                ) == .keepWaiting,
                "a blind host is held for the full conservative delay"
            )
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(
                        attempt: 20, elapsedMilliseconds: 400, progress: .unreadable,
                        hadFingerprintBeforePaste: false)
                ) == .confirmed,
                "a terminal with no readable state is accepted after the conservative delay"
            )
        }

        @Test func aHostThatWentQuietRightAfterThePasteIsAcceptedToo() {
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(
                        attempt: 20,
                        elapsedMilliseconds: 400,
                        progress: .unreadable,
                        sawReadableFingerprintAfterPaste: false
                    )
                ) == .confirmed,
                "a host that went quiet right after the paste is accepted too"
            )
        }

        @Test func aHostThatAnswersButShowsNothingIsNotAcceptedBlindly() {
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(attempt: 30, elapsedMilliseconds: 600, progress: .idle)
                ) == .keepWaiting,
                "a host that answers but shows nothing is not accepted blindly"
            )
        }

        @Test func anAbortOutranksEveryOtherSignal() {
            #expect(
                SnippetPasteConfirmationPolicy.verdict(
                    input(
                        attempt: 0, elapsedMilliseconds: 0, progress: .pasteObserved,
                        abort: .pasteboardSuperseded)
                ) == .abandoned(.pasteboardSuperseded),
                "an abort outranks every other signal"
            )
        }
    }

    // MARK: 7. Confirmation tail and tuning

    @Suite("Confirmation tail and tuning")
    struct ConfirmationTailTests {

        @Test func trailingNewlinesAreDroppedAndOnlyTheLastLineIsComparable() {
            #expect(
                SnippetPasteConfirmationPolicy.confirmationTail(of: "Regards,\nMike\n", maxLength: 32)
                    == "Mike",
                "trailing newlines are dropped and only the last line is comparable"
            )
        }

        @Test func theTailIsBounded() {
            #expect(
                SnippetPasteConfirmationPolicy.confirmationTail(of: "hello", maxLength: 3) == "llo",
                "the tail is bounded"
            )
        }

        @Test func whitespaceOnlyTextYieldsWhateverWhitespaceRemains() {
            #expect(
                SnippetPasteConfirmationPolicy.confirmationTail(of: "   \n  ", maxLength: 32) == "  ",
                "whitespace-only text yields whatever whitespace remains"
            )
        }

        @Test func aNewlineOnlySnippetHasNoComparableTail() {
            #expect(
                SnippetPasteConfirmationPolicy.confirmationTail(of: "\n", maxLength: 32) == "",
                "a newline-only snippet has no comparable tail, disabling the suffix check"
            )
        }

        @Test func theBlindPathStaysAtLeastAsConservativeAsTheFixedDelayItReplaced() {
            let tuning = SnippetPasteConfirmationPolicy.Tuning.default
            let blindHold = tuning.pollInterval * tuning.blindAcceptAttempt
            let fixedDelayItReplaced = Duration.milliseconds(350)
            // The behaviour this replaced held the clipboard for a flat 350 ms. Tuning must never make
            // the blind path — the one with no evidence at all — riskier than what already shipped.
            #expect(
                blindHold >= fixedDelayItReplaced,
                "the blind accept delay stays at least as conservative as the fixed delay it replaced"
            )
            #expect(
                tuning.maxWait > blindHold,
                "the overall budget outlasts the blind accept delay"
            )
        }
    }
}
