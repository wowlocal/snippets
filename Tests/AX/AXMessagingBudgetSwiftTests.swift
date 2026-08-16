import AppKit
import Testing
@testable import SnippetsAX

@Suite("Accessibility messaging budget")
@MainActor
struct AXMessagingBudgetSwiftTests {
    @Test("per-object timeouts shrink to one aggregate deadline")
    func shrinkingTimeoutNeverExceedsAggregateDeadline() {
        var now = ContinuousClock().now
        var configuredTimeouts: [Float] = []
        let element = AXUIElementCreateSystemWide()
        let budget = AXMessagingBudget(
            totalTimeoutSeconds: 0.4,
            perMessageTimeoutSeconds: 0.4,
            now: { now },
            setMessagingTimeout: { _, timeout in
                configuredTimeouts.append(timeout)
                return .success
            }
        )

        #expect(budget.bind(element))
        #expect(abs(configuredTimeouts[0] - 0.4) <= 0.001)

        now = now.advanced(by: .milliseconds(125))
        #expect(budget.bind(element))
        #expect(abs(configuredTimeouts[1] - 0.275) <= 0.001)

        now = now.advanced(by: .milliseconds(276))
        #expect(!budget.bind(element))
        #expect(configuredTimeouts.count == 2)
        #expect(budget.stopReason == .deadlineExceeded)
        #expect(abs(budget.elapsedMilliseconds - 401) <= 0.001)
    }

    @Test("a timeout-configuration failure prevents the AX message")
    func timeoutConfigurationFailureStopsInteraction() {
        let budget = AXMessagingBudget(
            setMessagingTimeout: { _, _ in .invalidUIElement }
        )

        #expect(!budget.bind(AXUIElementCreateSystemWide()))
        #expect(budget.stopReason == .timeoutConfigurationFailed(.invalidUIElement))
    }

    @Test("only permanent priming answers are cached")
    func onlyPermanentPrimingAnswersAreCached() {
        #expect(AXMessagingBudget.primingResultIsCacheable(.success))
        #expect(AXMessagingBudget.primingResultIsCacheable(.attributeUnsupported))
        #expect(AXMessagingBudget.primingResultIsCacheable(.notImplemented))
        #expect(!AXMessagingBudget.primingResultIsCacheable(.cannotComplete))
        #expect(!AXMessagingBudget.primingResultIsCacheable(.apiDisabled))
        #expect(!AXMessagingBudget.primingResultIsCacheable(.invalidUIElement))
        #expect(!AXMessagingBudget.primingResultIsCacheable(.illegalArgument))
    }

    @Test("Secure Paste replaces a positively identified password field")
    func securePastePrefersWholeSecureValue() {
        #expect(SecurePasteAccessibilityPolicy.strategy(
            targetIsSecureTextField: true,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true,
            selectedTextIsSettable: true
        ) == .replaceSecureValue)
    }

    @Test("Secure Paste fails closed for a password field without a writable value")
    func securePasteRequiresWritableSecureValue() {
        #expect(SecurePasteAccessibilityPolicy.strategy(
            targetIsSecureTextField: true,
            valueIsSettable: false,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true,
            selectedTextIsSettable: true
        ) == .unavailable)
    }

    @Test("Secure Paste prefers the advertised browser range operation in web text fields")
    func securePasteUsesWebRangeReplacement() {
        #expect(SecurePasteAccessibilityPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true,
            selectedTextIsSettable: true
        ) == .replaceWebRange)
    }

    @Test("Secure Paste uses selection insertion for an ordinary text field")
    func securePasteUsesSelectionOutsidePasswordFields() {
        #expect(SecurePasteAccessibilityPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: false,
            selectedTextIsSettable: true
        ) == .replaceSelection)
    }

    @Test("Secure Paste fails closed when a web operation is not advertised")
    func securePasteRequiresAdvertisedWebCapability() {
        #expect(SecurePasteAccessibilityPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: false,
            selectedTextIsSettable: true
        ) == .unavailable)
    }

    @Test("Secure Paste refuses the native route for generic web controls")
    func securePasteRefusesNoneligibleWebControls() {
        #expect(SecurePasteAccessibilityPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: true,
            selectedTextIsSettable: true
        ) == .unavailable)
    }

    @Test("web eligibility includes standard single-line and multiline text roles")
    func securePasteRecognizesStandardWebTextRoles() {
        #expect(SecurePasteAccessibilityPolicy.isEligibleWebTextRole("AXTextField"))
        #expect(SecurePasteAccessibilityPolicy.isEligibleWebTextRole("AXComboBox"))
        #expect(SecurePasteAccessibilityPolicy.isEligibleWebTextRole("AXTextArea"))
        #expect(!SecurePasteAccessibilityPolicy.isEligibleWebTextRole("AXGroup"))
        #expect(!SecurePasteAccessibilityPolicy.isEligibleWebTextRole(nil))
    }

    @Test("web range delivery requires both replacement and readback capabilities")
    func securePasteRequiresCompleteWebRangeCapabilities() {
        #expect(SecurePasteAccessibilityPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: [
                "AXReplaceRangeWithText",
                "AXStringForRange",
                "AXBoundsForRange",
            ]
        ))
        #expect(!SecurePasteAccessibilityPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: ["AXReplaceRangeWithText"]
        ))
        #expect(!SecurePasteAccessibilityPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: ["AXStringForRange"]
        ))
    }

    @Test("Secure Paste never overwrites an ordinary unreadable field wholesale")
    func securePasteRefusesUnsafeWholeValueFallback() {
        #expect(SecurePasteAccessibilityPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: false,
            selectedTextIsSettable: false
        ) == .unavailable)
    }

    @Test("an ambiguous Secure Paste attempt is not treated as a retryable failure")
    func securePasteAmbiguityDoesNotRestoreFocus() {
        #expect(SecurePasteCompletionPolicy.reaction(after: .inserted) == .none)
        #expect(SecurePasteCompletionPolicy.reaction(
            after: .failedBeforeAttempt
        ) == .restoreOriginalFocus)
        #expect(SecurePasteCompletionPolicy.reaction(
            after: .attemptedAmbiguous
        ) == .warnWithoutRestoringFocus)
    }

    @Test("web replacement planning uses UTF-16 offsets")
    func webReplacementUsesUTF16Offsets() throws {
        let snapshot = try #require(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 10,
            selectionLocation: 3,
            selectionLength: 4,
            selectedText: "3456"
        ))
        let plan = try #require(SecurePasteWebReplacementPolicy.plan(
            replacing: snapshot,
            with: "a😀b"
        ))

        #expect(plan.replacementLocation == 3)
        #expect(plan.replacementLength == 4)
        #expect(plan.replacementUTF16Count == 4)
        #expect(plan.expectedFieldUTF16Count == 10)
        #expect(plan.caretLocation == 7)
    }

    @Test("web replacement rejects an invalid or unreadable selection")
    func webReplacementRejectsInvalidSelection() {
        #expect(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 5,
            selectionLocation: 4,
            selectionLength: 2,
            selectedText: "45"
        ) == nil)
        #expect(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 5,
            selectionLocation: 1,
            selectionLength: 2,
            selectedText: "😀"
        ) != nil)
        #expect(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 5,
            selectionLocation: 1,
            selectionLength: 1,
            selectedText: "😀"
        ) == nil)
    }

    @Test("web replacement accepts multiline and bounded large payloads")
    func webReplacementPreservesExistingSnippetShapes() throws {
        let snapshot = try #require(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 3,
            selectionLocation: 0,
            selectionLength: 3,
            selectedText: "old"
        ))

        #expect(SecurePasteWebReplacementPolicy.plan(replacing: snapshot, with: "old") == nil)
        #expect(SecurePasteWebReplacementPolicy.plan(replacing: snapshot, with: "a\nb") != nil)
        #expect(SecurePasteWebReplacementPolicy.plan(
            replacing: snapshot,
            with: String(repeating: "x", count: 999_999)
        ) != nil)
        #expect(SecurePasteWebReplacementPolicy.plan(
            replacing: snapshot,
            with: String(repeating: "x", count: 1_000_001)
        ) == nil)
    }

    @Test("web replacement confirmation is exact instead of canonically equivalent")
    func webReplacementConfirmationUsesExactUTF16() {
        let first = "a\u{0301}\u{0327}"
        let reordered = "a\u{0327}\u{0301}"

        #expect(first == reordered)
        #expect(!SecurePasteWebReplacementPolicy.utf16ContentsMatch(first, reordered))
        #expect(SecurePasteWebReplacementPolicy.utf16ContentsMatch(first, first))
    }

    @Test("Secure Paste keeps relevance ahead of security preference")
    func securePasteRelevanceComesFirst() {
        #expect(SecurePasteSuggestionRankingPolicy.decision(
            lhsScore: 20,
            lhsKeywordRank: 1,
            lhsIsSecure: false,
            rhsScore: 10,
            rhsKeywordRank: 3,
            rhsIsSecure: true
        ) == .lhsFirst)
    }

    @Test("Secure Paste ranks secure snippets first when relevance ties")
    func securePasteSecurityBreaksRelevanceTie() {
        #expect(SecurePasteSuggestionRankingPolicy.decision(
            lhsScore: 20,
            lhsKeywordRank: 2,
            lhsIsSecure: false,
            rhsScore: 20,
            rhsKeywordRank: 2,
            rhsIsSecure: true
        ) == .rhsFirst)
    }

    @Test("Secure Paste leaves equal security rows to normal ranking")
    func securePasteRankingFallsThrough() {
        #expect(SecurePasteSuggestionRankingPolicy.decision(
            lhsScore: 20,
            lhsKeywordRank: 2,
            lhsIsSecure: true,
            rhsScore: 20,
            rhsKeywordRank: 2,
            rhsIsSecure: true
        ) == .tied)
    }
}
