import AppKit

/// One synchronous Accessibility interaction's wall-clock budget.
///
/// `AXUIElementSetMessagingTimeout` is deliberately applied before every message: Apple scopes
/// that timeout to the exact `AXUIElement` object, so an equal child/parent object does not inherit
/// it. The timeout also is not an aggregate deadline. Shrinking it to the time left here is what
/// prevents a chain of individually bounded calls from holding the event-tap callback for seconds.
@MainActor
final class AXMessagingBudget {
    nonisolated static let interactiveTimeoutSeconds: Float = 0.4

    enum StopReason: Equatable {
        case deadlineExceeded
        case messagingTimedOut
        case timeoutConfigurationFailed(AXError)

        var telemetryValue: String {
            switch self {
            case .deadlineExceeded:
                return "deadline"
            case .messagingTimedOut:
                return "timeout"
            case .timeoutConfigurationFailed:
                return "timeout-configuration"
            }
        }
    }

    private let startedAt: ContinuousClock.Instant
    private let deadline: ContinuousClock.Instant
    private let perMessageTimeoutSeconds: Float
    private let now: () -> ContinuousClock.Instant
    private let setMessagingTimeout: (AXUIElement, Float) -> AXError
    private(set) var stopReason: StopReason?

    init(
        totalTimeoutSeconds: Float = AXMessagingBudget.interactiveTimeoutSeconds,
        perMessageTimeoutSeconds: Float = AXMessagingBudget.interactiveTimeoutSeconds,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
        setMessagingTimeout: @escaping (AXUIElement, Float) -> AXError = {
            AXUIElementSetMessagingTimeout($0, $1)
        }
    ) {
        let total = max(0, Double(totalTimeoutSeconds))
        let startedAt = now()
        self.startedAt = startedAt
        deadline = startedAt.advanced(by: .seconds(total))
        self.perMessageTimeoutSeconds = max(0, perMessageTimeoutSeconds)
        self.now = now
        self.setMessagingTimeout = setMessagingTimeout
    }

    var canContinue: Bool {
        remainingSeconds() != nil
    }

    var elapsedMilliseconds: Double {
        let current = now()
        guard current >= startedAt else { return 0 }
        return Self.seconds(in: startedAt.duration(to: current)) * 1_000
    }

    /// Applies the remaining timeout to this exact object. A message must not be sent when this
    /// returns false: doing so would silently fall back to Accessibility's multi-second default.
    @discardableResult
    func bind(_ element: AXUIElement) -> Bool {
        guard let remaining = remainingSeconds() else { return false }
        let timeout = min(perMessageTimeoutSeconds, Float(remaining))
        guard timeout > 0 else {
            stopReason = stopReason ?? .deadlineExceeded
            return false
        }

        let result = setMessagingTimeout(element, timeout)
        guard result == .success else {
            stopReason = .timeoutConfigurationFailed(result)
            return false
        }
        return true
    }

    func copyAttributeValue(
        of element: AXUIElement,
        attribute: CFString,
        into value: inout CFTypeRef?
    ) -> AXError {
        guard bind(element) else { return .cannotComplete }
        return record(
            AXUIElementCopyAttributeValue(element, attribute, &value)
        )
    }

    func copyParameterizedAttributeValue(
        of element: AXUIElement,
        attribute: CFString,
        parameter: CFTypeRef,
        into value: inout CFTypeRef?
    ) -> AXError {
        guard bind(element) else { return .cannotComplete }
        return record(
            AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        )
    }

    func copyAttributeNames(
        of element: AXUIElement,
        into value: inout CFArray?
    ) -> AXError {
        guard bind(element) else { return .cannotComplete }
        return record(AXUIElementCopyAttributeNames(element, &value))
    }

    func setAttributeValue(
        of element: AXUIElement,
        attribute: CFString,
        value: CFTypeRef
    ) -> AXError {
        guard bind(element) else { return .cannotComplete }
        return record(AXUIElementSetAttributeValue(element, attribute, value))
    }

    /// Successful writes and permanent capability answers are safe to remember. Messaging and
    /// permission failures are transient; caching those would leave a recovered host unprimed for
    /// the rest of its process lifetime.
    static func primingResultIsCacheable(_ result: AXError) -> Bool {
        switch result {
        case .success, .attributeUnsupported, .notImplemented:
            return true
        default:
            return false
        }
    }

    private func record(_ result: AXError) -> AXError {
        if result == .cannotComplete {
            stopReason = stopReason ?? .messagingTimedOut
        } else {
            _ = remainingSeconds()
        }
        return result
    }

    private func remainingSeconds() -> Double? {
        guard stopReason == nil else { return nil }

        let current = now()
        guard current < deadline else {
            stopReason = .deadlineExceeded
            return nil
        }

        let seconds = Self.seconds(in: current.duration(to: deadline))
        guard seconds > 0 else {
            stopReason = .deadlineExceeded
            return nil
        }
        return seconds
    }

    private static func seconds(in duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Chooses Secure Paste's one and only delivery channel before any plaintext write.
///
/// A password field's current value is intentionally never read. Chromium is also
/// selected up front: its web controls can report a successful `AXSelectedText` write
/// that never reaches the page's edit model. Trying AX first and an event second is not
/// safe because a delayed AX action could then insert the same text twice. Secure bodies
/// never take Chromium's multi-event route because a page handler can move focus between
/// events and redirect the suffix.
nonisolated enum SecurePasteDeliveryPolicy {
    enum Strategy: Equatable {
        case replaceSecureValue
        case replaceSelection
        case postUnicodeText
        case securePayloadRequiresAtomicField
        case unavailable
    }

    static func strategy(
        payloadIsSecure: Bool,
        targetIsSecureTextField: Bool,
        valueIsSettable: Bool,
        selectedTextIsSettable: Bool,
        hostIsChromiumFamily: Bool,
        secureEventInputEnabled: Bool
    ) -> Strategy {
        if targetIsSecureTextField {
            return valueIsSettable ? .replaceSecureValue : .unavailable
        }
        if hostIsChromiumFamily {
            if payloadIsSecure { return .securePayloadRequiresAtomicField }
            return secureEventInputEnabled ? .unavailable : .postUnicodeText
        }
        if selectedTextIsSettable {
            return .replaceSelection
        }
        return .unavailable
    }

    /// Chromium may require multi-event delivery for an ordinary field. A secure body
    /// must not even be materialized unless the captured control has already been
    /// positively identified as a password field with one settable atomic writer.
    static func mayMaterializeSecurePayload(
        hostIsChromiumFamily: Bool,
        targetIsSecureTextField: Bool?,
        secureValueIsSettable: Bool
    ) -> Bool {
        guard hostIsChromiumFamily else { return true }
        return targetIsSecureTextField == true && secureValueIsSettable
    }
}

/// The caller must distinguish a refusal before delivery from uncertainty after a
/// write. An attempted write is terminal: timeout or an unchanged immediate read-back
/// never authorizes a second channel or an automatic retry.
nonisolated enum SecurePasteDeliveryOutcome: Equatable {
    case confirmed
    case failedBeforeAttempt
    case securePayloadRequiresAtomicField
    case attemptedAmbiguous

    var writeWasAttempted: Bool {
        switch self {
        case .confirmed, .attemptedAmbiguous:
            true
        case .failedBeforeAttempt, .securePayloadRequiresAtomicField:
            false
        }
    }

    var shouldRestoreCapturedFocus: Bool {
        self == .failedBeforeAttempt || self == .securePayloadRequiresAtomicField
    }
}

nonisolated struct SecurePasteSelectionSnapshot: Equatable {
    let location: Int
    let length: Int
}

/// Positive confirmation for Chromium's clipboard-free Unicode event path. Caret
/// movement alone is insufficient because a host that ignores the Unicode payload may
/// translate the event's virtual key instead. The bounded inserted-text read must agree
/// too; an absent or stale read remains ambiguous and is never retried.
nonisolated enum SecurePasteUnicodeConfirmationPolicy {
    static func confirms(
        before: SecurePasteSelectionSnapshot,
        after: SecurePasteSelectionSnapshot,
        replacementUTF16Length: Int,
        replacementTailMatches: Bool
    ) -> Bool {
        guard before.location >= 0,
              before.length >= 0,
              after.location >= 0,
              replacementUTF16Length > 0,
              replacementTailMatches,
              after.length == 0
        else { return false }
        let (expectedLocation, overflow) = before.location.addingReportingOverflow(
            replacementUTF16Length
        )
        return !overflow && after.location == expectedLocation
    }
}

/// Quartz text events are intentionally planned before the first post. Chromium's own
/// macOS injector treats roughly 20 UTF-16 code units as the per-event ceiling and
/// emits one extended grapheme at a time. Control characters are refused up front:
/// representing a newline as a keyboard event can submit a single-line web form,
/// which is not equivalent to pasting text.
nonisolated enum SecurePasteUnicodeEventPolicy {
    static let maximumUTF16CodeUnitsPerEvent = 20
    static let maximumTotalUTF16CodeUnits = 4_096
    static let maximumEventCount = 1_024

    static func canDeliver(_ text: String) -> Bool {
        guard !text.isEmpty,
              text.utf16.count <= maximumTotalUTF16CodeUnits
        else { return false }

        var eventCount = 0
        for character in text {
            eventCount += 1
            guard eventCount <= maximumEventCount else { return false }
            let chunk = String(character)
            guard chunk.utf16.count <= maximumUTF16CodeUnitsPerEvent,
                  !character.isNewline
            else { return false }

            let containsActionLikeScalar = chunk.unicodeScalars.contains { scalar in
                let value = scalar.value
                return value <= 0x1F
                    || (0x7F...0x9F).contains(value)
                    || (0xF700...0xF8FF).contains(value)
            }
            guard !containsActionLikeScalar else { return false }
        }
        return true
    }
}

/// The Secure Paste picker is security-biased without making security a search
/// relevance override. A better name/keyword match wins first; secure status breaks
/// otherwise equal matches before frecency and display order do.
nonisolated enum SecurePasteSuggestionRankingPolicy {
    enum Decision: Equatable {
        case lhsFirst
        case rhsFirst
        case tied
    }

    static func decision(
        lhsScore: Int,
        lhsKeywordRank: Int,
        lhsIsSecure: Bool,
        rhsScore: Int,
        rhsKeywordRank: Int,
        rhsIsSecure: Bool
    ) -> Decision {
        if lhsScore != rhsScore {
            return lhsScore > rhsScore ? .lhsFirst : .rhsFirst
        }
        if lhsKeywordRank != rhsKeywordRank {
            return lhsKeywordRank > rhsKeywordRank ? .lhsFirst : .rhsFirst
        }
        if lhsIsSecure != rhsIsSecure {
            return lhsIsSecure ? .lhsFirst : .rhsFirst
        }
        return .tied
    }
}
