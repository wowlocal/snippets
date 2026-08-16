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

/// Chooses the one Accessibility write a Secure Paste attempt is allowed to make.
///
/// A password field's current value is intentionally never read. That rules out the
/// ordinary read/modify/write insertion path and also means a failed write must not be
/// followed by a second strategy: the first call may have landed even if its reply was
/// lost. For a positively identified secure field, replacing `AXValue` matches password
/// manager fill semantics. Everywhere else, only `AXSelectedText` is narrow enough to be
/// safe — it inserts at the caret or replaces the user's selection without overwriting an
/// unreadable field wholesale.
nonisolated enum SecurePasteAccessibilityPolicy {
    enum Strategy: Equatable {
        case replaceSecureValue
        case replaceSelection
        case unavailable
    }

    static func strategy(
        targetIsSecureTextField: Bool,
        valueIsSettable: Bool,
        selectedTextIsSettable: Bool
    ) -> Strategy {
        if targetIsSecureTextField, valueIsSettable {
            return .replaceSecureValue
        }
        if selectedTextIsSettable {
            return .replaceSelection
        }
        return .unavailable
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
