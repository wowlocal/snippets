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
            payloadIsSecure: true,
            targetIsSecureTextField: true,
            valueIsSettable: true,
            selectedTextIsSettable: true,
            hostIsChromiumFamily: true,
            secureEventInputEnabled: true
        ) == .replaceSecureValue)
    }

    @Test("Secure Paste uses selection insertion for an ordinary text field")
    func securePasteUsesSelectionOutsidePasswordFields() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            payloadIsSecure: false,
            targetIsSecureTextField: false,
            valueIsSettable: true,
            selectedTextIsSettable: true,
            hostIsChromiumFamily: false,
            secureEventInputEnabled: false
        ) == .replaceSelection)
    }

    @Test("a secure body still uses one selection write in a native ordinary field")
    func secureBodyUsesAtomicNativeSelectionWrite() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            payloadIsSecure: true,
            targetIsSecureTextField: false,
            valueIsSettable: true,
            selectedTextIsSettable: true,
            hostIsChromiumFamily: false,
            secureEventInputEnabled: false
        ) == .replaceSelection)
    }

    @Test("Secure Paste never overwrites an ordinary unreadable field wholesale")
    func securePasteRefusesUnsafeWholeValueFallback() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            payloadIsSecure: false,
            targetIsSecureTextField: false,
            valueIsSettable: true,
            selectedTextIsSettable: false,
            hostIsChromiumFamily: false,
            secureEventInputEnabled: false
        ) == .unavailable)
    }

    @Test("Secure Paste never falls back to selection writes in a password field")
    func securePasteRefusesSelectionOnlyPasswordField() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            payloadIsSecure: true,
            targetIsSecureTextField: true,
            valueIsSettable: false,
            selectedTextIsSettable: true,
            hostIsChromiumFamily: false,
            secureEventInputEnabled: false
        ) == .unavailable)
    }

    @Test("Chromium ordinary fields select Unicode events before any AX write")
    func chromiumUsesUnicodeEventsUpFront() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            payloadIsSecure: false,
            targetIsSecureTextField: false,
            valueIsSettable: true,
            selectedTextIsSettable: true,
            hostIsChromiumFamily: true,
            secureEventInputEnabled: false
        ) == .postUnicodeText)
    }

    @Test("Chromium event delivery fails closed during Secure Event Input")
    func chromiumRefusesUnicodeEventsDuringSecureInput() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            payloadIsSecure: false,
            targetIsSecureTextField: false,
            valueIsSettable: true,
            selectedTextIsSettable: true,
            hostIsChromiumFamily: true,
            secureEventInputEnabled: true
        ) == .unavailable)
    }

    @Test("Chromium events never carry a secure snippet body")
    func chromiumSecurePayloadFailsClosed() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            payloadIsSecure: true,
            targetIsSecureTextField: false,
            valueIsSettable: true,
            selectedTextIsSettable: true,
            hostIsChromiumFamily: true,
            secureEventInputEnabled: false
        ) == .securePayloadRequiresAtomicField)
    }

    @Test("Chromium materializes a secure body only for a proven atomic password writer")
    func chromiumSecurePayloadPreAuthenticationGateFailsClosed() {
        #expect(!SecurePasteDeliveryPolicy.mayMaterializeSecurePayload(
            hostIsChromiumFamily: true,
            targetIsSecureTextField: false,
            secureValueIsSettable: false
        ))
        #expect(!SecurePasteDeliveryPolicy.mayMaterializeSecurePayload(
            hostIsChromiumFamily: true,
            targetIsSecureTextField: nil,
            secureValueIsSettable: false
        ))
        #expect(!SecurePasteDeliveryPolicy.mayMaterializeSecurePayload(
            hostIsChromiumFamily: true,
            targetIsSecureTextField: true,
            secureValueIsSettable: false
        ))
        #expect(SecurePasteDeliveryPolicy.mayMaterializeSecurePayload(
            hostIsChromiumFamily: true,
            targetIsSecureTextField: true,
            secureValueIsSettable: true
        ))
        #expect(SecurePasteDeliveryPolicy.mayMaterializeSecurePayload(
            hostIsChromiumFamily: false,
            targetIsSecureTextField: nil,
            secureValueIsSettable: false
        ))
    }

    @Test("an ambiguous write remains visibly attempted")
    func ambiguousWriteCannotMasqueradeAsPreflightFailure() {
        #expect(SecurePasteDeliveryOutcome.attemptedAmbiguous.writeWasAttempted)
        #expect(!SecurePasteDeliveryOutcome.attemptedAmbiguous.shouldRestoreCapturedFocus)
        #expect(!SecurePasteDeliveryOutcome.failedBeforeAttempt.writeWasAttempted)
        #expect(SecurePasteDeliveryOutcome.failedBeforeAttempt.shouldRestoreCapturedFocus)
        #expect(!SecurePasteDeliveryOutcome.securePayloadRequiresAtomicField.writeWasAttempted)
        #expect(SecurePasteDeliveryOutcome.securePayloadRequiresAtomicField.shouldRestoreCapturedFocus)
    }

    @Test("Unicode confirmation requires exact text and exact caret movement")
    func unicodeConfirmationIsPositiveOnly() {
        let before = SecurePasteSelectionSnapshot(location: 4, length: 3)
        let after = SecurePasteSelectionSnapshot(location: 10, length: 0)

        #expect(SecurePasteUnicodeConfirmationPolicy.confirms(
            before: before,
            after: after,
            replacementUTF16Length: 6,
            replacementTailMatches: true
        ))
        #expect(!SecurePasteUnicodeConfirmationPolicy.confirms(
            before: before,
            after: after,
            replacementUTF16Length: 6,
            replacementTailMatches: false
        ))
        #expect(!SecurePasteUnicodeConfirmationPolicy.confirms(
            before: before,
            after: SecurePasteSelectionSnapshot(location: 9, length: 0),
            replacementUTF16Length: 6,
            replacementTailMatches: true
        ))
        #expect(!SecurePasteUnicodeConfirmationPolicy.confirms(
            before: before,
            after: SecurePasteSelectionSnapshot(location: 4, length: 6),
            replacementUTF16Length: 6,
            replacementTailMatches: true
        ))
        #expect(!SecurePasteUnicodeConfirmationPolicy.confirms(
            before: SecurePasteSelectionSnapshot(location: .max, length: 0),
            after: after,
            replacementUTF16Length: 1,
            replacementTailMatches: true
        ))
    }

    @Test("Unicode event planning preserves long text but refuses action-like input")
    func unicodeEventPlanningIsBoundedAndPassive() {
        #expect(SecurePasteUnicodeEventPolicy.canDeliver(String(repeating: "long text ", count: 20)))
        #expect(SecurePasteUnicodeEventPolicy.canDeliver("emoji: 👨‍👩‍👧‍👦"))
        #expect(!SecurePasteUnicodeEventPolicy.canDeliver("first\nsecond"))
        #expect(!SecurePasteUnicodeEventPolicy.canDeliver("left\tright"))
        #expect(!SecurePasteUnicodeEventPolicy.canDeliver("left\u{F700}right"))
        #expect(!SecurePasteUnicodeEventPolicy.canDeliver(String(
            repeating: "a",
            count: SecurePasteUnicodeEventPolicy.maximumEventCount + 1
        )))

        let twentyUnitGrapheme = "a" + String(repeating: "\u{0301}", count: 19)
        #expect(twentyUnitGrapheme.count == 1)
        #expect(!SecurePasteUnicodeEventPolicy.canDeliver(String(
            repeating: twentyUnitGrapheme,
            count: SecurePasteUnicodeEventPolicy.maximumTotalUTF16CodeUnits / 20 + 1
        )))

        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 20)
        #expect(oversizedGrapheme.count == 1)
        #expect(!SecurePasteUnicodeEventPolicy.canDeliver(oversizedGrapheme))
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
