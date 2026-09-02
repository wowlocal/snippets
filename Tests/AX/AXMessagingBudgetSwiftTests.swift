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
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: true,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true
        ) == .replaceSecureValue)
    }

    @Test("Secure Paste fails closed for a password field without a writable value")
    func securePasteRequiresWritableSecureValue() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: true,
            valueIsSettable: false,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true
        ) == .unavailable)
    }

    @Test("Secure Paste prefers the advertised browser range operation in web text fields")
    func securePasteUsesWebRangeReplacement() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true
        ) == .replaceWebRange)
    }

    @Test("ordinary picker content uses the same direct input as secure content")
    func ordinaryPickerContentUsesDirectInput() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: false
        ) == .typeUnicode)
    }

    @Test("Secure Paste fails closed when a web operation is not advertised")
    func securePasteRequiresAdvertisedWebCapability() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: false
        ) == .unavailable)
    }

    @Test("Secure Paste refuses the native route for generic web controls")
    func securePasteRefusesNoneligibleWebControls() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: true
        ) == .unavailable)
    }

    @Test("web eligibility includes standard single-line and multiline text roles")
    func securePasteRecognizesStandardWebTextRoles() {
        #expect(SecurePasteDeliveryPolicy.isEligibleWebTextRole("AXTextField"))
        #expect(SecurePasteDeliveryPolicy.isEligibleWebTextRole("AXComboBox"))
        #expect(SecurePasteDeliveryPolicy.isEligibleWebTextRole("AXTextArea"))
        #expect(!SecurePasteDeliveryPolicy.isEligibleWebTextRole("AXGroup"))
        #expect(!SecurePasteDeliveryPolicy.isEligibleWebTextRole(nil))
    }

    @Test("web range delivery requires both replacement and readback capabilities")
    func securePasteRequiresCompleteWebRangeCapabilities() {
        #expect(SecurePasteDeliveryPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: [
                "AXReplaceRangeWithText",
                "AXStringForRange",
                "AXBoundsForRange",
            ]
        ))
        #expect(!SecurePasteDeliveryPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: ["AXReplaceRangeWithText"]
        ))
        #expect(!SecurePasteDeliveryPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: ["AXStringForRange"]
        ))
    }

    @Test("native delivery does not depend on writable AX selected text")
    func nativeDeliveryDoesNotDependOnAXSelectedText() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: false
        ) == .typeUnicode)
    }

    @Test("native direct input selection requires no host identity")
    func securePasteUsesDirectUnicodeForNativeAndCustomTextSurfaces() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: false,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: false
        ) == .typeUnicode)
    }

    @Test("direct input accepts printable Unicode and reconstructs one tagged key event")
    func securePasteDirectInputBuildsUnicodeEvent() throws {
        let text = "токен-😀"
        let tag: Int64 = 0x5A17
        let events = try #require(SecurePasteDirectInputPolicy.makeEvents(
            text: text,
            eventTag: tag
        ))

        var actualLength = 0
        var utf16 = [UniChar](repeating: 0, count: text.utf16.count)
        events.keyDown.keyboardGetUnicodeString(
            maxStringLength: utf16.count,
            actualStringLength: &actualLength,
            unicodeString: &utf16
        )

        #expect(String(decoding: utf16.prefix(actualLength), as: UTF16.self) == text)
        #expect(events.keyDown.getIntegerValueField(.keyboardEventKeycode)
            == Int64(SecurePasteDirectInputPolicy.unicodeOnlyVirtualKey))
        #expect(events.keyDown.getIntegerValueField(.eventSourceUserData) == tag)
        #expect(events.keyUp.getIntegerValueField(.eventSourceUserData) == tag)
    }

    @Test("direct input rejects controls, empty content, and oversized content")
    func securePasteDirectInputValidationFailsClosed() {
        #expect(SecurePasteDirectInputPolicy.validation(of: "token-😀") == .allowed)
        #expect(SecurePasteDirectInputPolicy.validation(of: "") == .empty)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\nb") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\rb") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\tb") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\0b") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\u{0085}b") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(
            of: String(repeating: "x", count: SecurePasteDirectInputPolicy.maximumUTF16Count + 1)
        ) == .tooLong)
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

    @Test("Secure Paste waits for authentication secure input before restoring an ordinary field")
    func securePasteWaitsForAuthenticationSecureInput() {
        #expect(SecurePasteAuthenticationHandoffPolicy.shouldWaitForSecureInputToClear(
            targetIsSecureTextField: false,
            secureInputWasEnabledAtCapture: false
        ))
        #expect(SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
            waitForAuthenticationSecureInputToClear: true,
            secureEventInputEnabled: true
        ))
        #expect(!SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
            waitForAuthenticationSecureInputToClear: true,
            secureEventInputEnabled: false
        ))
    }

    @Test("Secure Paste preserves password fields and pre-existing secure terminal input")
    func securePastePreservesLegitimateSecureInput() {
        #expect(!SecurePasteAuthenticationHandoffPolicy.shouldWaitForSecureInputToClear(
            targetIsSecureTextField: true,
            secureInputWasEnabledAtCapture: false
        ))
        #expect(!SecurePasteAuthenticationHandoffPolicy.shouldWaitForSecureInputToClear(
            targetIsSecureTextField: false,
            secureInputWasEnabledAtCapture: true
        ))
        #expect(!SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
            waitForAuthenticationSecureInputToClear: false,
            secureEventInputEnabled: true
        ))
    }

    @Test("Secure Paste focus confirmations must be consecutive")
    func securePasteFocusConfirmationsResetAfterInterruption() {
        var confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: 0,
                targetIsFrontmost: true,
                focusWasReasserted: true
            )
        #expect(confirmations == 1)
        #expect(!SecurePasteAuthenticationHandoffPolicy.focusIsStable(
            consecutiveConfirmations: confirmations
        ))

        confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: confirmations,
                targetIsFrontmost: false,
                focusWasReasserted: false
            )
        #expect(confirmations == 0)

        confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: confirmations,
                targetIsFrontmost: true,
                focusWasReasserted: true
            )
        #expect(confirmations == 1)
        confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: confirmations,
                targetIsFrontmost: true,
                focusWasReasserted: true
            )
        #expect(SecurePasteAuthenticationHandoffPolicy.focusIsStable(
            consecutiveConfirmations: confirmations
        ))
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
