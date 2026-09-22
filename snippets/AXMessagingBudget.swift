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

    func copyParameterizedAttributeNames(
        of element: AXUIElement,
        into value: inout CFArray?
    ) -> AXError {
        guard bind(element) else { return .cannotComplete }
        return record(AXUIElementCopyParameterizedAttributeNames(element, &value))
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

/// Chooses the one plaintext-bearing transport a Secure Paste attempt is allowed to
/// make before any secret text is materialized.
///
/// A password field's current value is intentionally never read. That rules out the
/// ordinary read/modify/write insertion path and also means a failed write must not be
/// followed by a second strategy: the first call may have landed even if its reply was
/// lost. Native secure fields retain whole-value replacement. A browser-backed secure
/// field instead needs the keyboard input path: AXValue can acknowledge the setter
/// without updating the form's input-event-driven model. Ordinary web fields retain an
/// explicitly advertised, range-scoped browser operation. Other captured text surfaces
/// uses one PID-bound Unicode keyboard event instead of trusting an unverifiable
/// `AXSelectedText` success. This is based only on target capabilities; secure and
/// ordinary snippets use the same transport and no host identity enters the decision.
nonisolated enum SecurePasteDeliveryPolicy {
    private static let requiredWebRangeParameterizedAttributes: Set<String> = [
        "AXReplaceRangeWithText",
        kAXStringForRangeParameterizedAttribute as String,
    ]

    enum Strategy: Equatable {
        case replaceSecureValue
        case typeSecureUnicode
        case replaceWebRange
        case typeUnicode
        case unavailable
    }

    static func strategy(
        targetIsSecureTextField: Bool,
        valueIsSettable: Bool,
        targetIsInsideWebArea: Bool,
        targetHasEligibleWebTextRole: Bool,
        webRangeReplacementIsAvailable: Bool
    ) -> Strategy {
        if targetIsSecureTextField {
            if targetIsInsideWebArea {
                return targetHasEligibleWebTextRole ? .typeSecureUnicode : .unavailable
            }
            return valueIsSettable ? .replaceSecureValue : .unavailable
        }
        if targetIsInsideWebArea {
            return targetHasEligibleWebTextRole && webRangeReplacementIsAvailable
                ? .replaceWebRange
                : .unavailable
        }
        return .typeUnicode
    }

    static func isEligibleWebTextRole(_ role: String?) -> Bool {
        switch role {
        case "AXTextField", "AXComboBox", "AXTextArea":
            true
        default:
            false
        }
    }

    static func supportsWebRangeReplacement(
        advertisedParameterizedAttributes: Set<String>
    ) -> Bool {
        requiredWebRangeParameterizedAttributes.isSubset(
            of: advertisedParameterizedAttributes
        )
    }

    /// Container evidence can address an AX write but cannot route a keyboard event.
    /// Secure web input therefore always needs the concrete field to own focus, even
    /// if an explicit selection or descendant search originally found it.
    static func permitsDirectInput(
        isSecureWebField: Bool, hasContainerBinding: Bool, exactFieldHasKeyboardFocus: Bool
    ) -> Bool {
        isSecureWebField ? exactFieldHasKeyboardFocus : !hasContainerBinding
    }

    /// AX setters have no application-level acknowledgement. Never mistake an
    /// accepted password write for verified delivery, and never retry after it.
    static func secureValueWriteResult(_ error: AXError) -> SecurePasteResult {
        .attemptedAmbiguous
    }

    /// Distinguish native ancestry from failed/incomplete web ancestry without
    /// reading values. Unknown must not choose the native password setter.
    static func webAncestry<Element: Equatable>(
        of element: Element, canContinue: () -> Bool,
        role: (Element) -> String?, parent: (Element) -> Element?
    ) -> Bool? {
        var current = element
        var visited: [Element] = []
        for _ in 0..<16 {
            guard canContinue(), !visited.contains(current), let currentRole = role(current),
                  canContinue() else { return nil }
            if currentRole == "AXWebArea" { return true }
            if currentRole == "AXWindow" || currentRole == "AXApplication" { return false }
            visited.append(current)
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }
}

/// Once plaintext-bearing input has been sent, no outcome authorizes another
/// transport. Routine keyboard dispatch is unverified, but is not itself a failure.
/// AX errors or failed readback remain ambiguous: the request may still have landed.
nonisolated enum SecurePasteResult: Equatable {
    case inserted
    case dispatchedUnconfirmed
    case failedBeforeAttempt
    case blockedUnsafeControlCharacters
    case attemptedAmbiguous
}

/// Keeps an uncertain, potentially successful request from being presented like a
/// retryable preflight failure.
nonisolated enum SecurePasteCompletionPolicy {
    enum Reaction: Equatable {
        case none
        case restoreOriginalFocus
        case warnAfterRestoringFocus
        case warnWithoutRestoringFocus
    }

    static func reaction(after result: SecurePasteResult) -> Reaction {
        switch result {
        case .inserted, .dispatchedUnconfirmed:
            return .none
        case .failedBeforeAttempt:
            return .restoreOriginalFocus
        case .blockedUnsafeControlCharacters:
            return .warnAfterRestoringFocus
        case .attemptedAmbiguous:
            return .warnWithoutRestoringFocus
        }
    }
}

/// Keeps the LocalAuthentication keyboard handoff separate from Secure Paste's
/// plaintext-bearing AX write. A real password field, or a destination that already
/// owned Secure Event Input when it was captured, may legitimately keep secure input
/// enabled. Every other destination must wait for authentication's temporary ownership
/// to clear before focus confirmations can accumulate.
nonisolated enum SecurePasteAuthenticationHandoffPolicy {
    // Confirm the destination across two polling intervals after system authentication UI.
    static let requiredConsecutiveFocusConfirmations = 3

    static func shouldWaitForSecureInputToClear(
        targetIsSecureTextField: Bool,
        secureInputWasEnabledAtCapture: Bool
    ) -> Bool {
        !targetIsSecureTextField && !secureInputWasEnabledAtCapture
    }

    static func secureInputBlocksRestore(
        waitForAuthenticationSecureInputToClear: Bool,
        secureEventInputEnabled: Bool
    ) -> Bool {
        waitForAuthenticationSecureInputToClear && secureEventInputEnabled
    }

    static func updatedConsecutiveFocusConfirmations(
        current: Int,
        targetIsFrontmost: Bool,
        focusWasReasserted: Bool
    ) -> Int {
        guard targetIsFrontmost, focusWasReasserted else { return 0 }
        return min(current + 1, requiredConsecutiveFocusConfirmations)
    }

    static func focusIsStable(consecutiveConfirmations: Int) -> Bool {
        consecutiveConfirmations >= requiredConsecutiveFocusConfirmations
    }
}

/// Safety and event construction for direct input from the Secure Paste picker.
///
/// A single event avoids partial multi-event delivery and gives hosts one Unicode text
/// payload to commit. Control characters are refused because Return/newline in a shell
/// is execution, not insertion. The event is still inherently unconfirmable: Core
/// Graphics has no acknowledgement that a target framework consumed its Unicode text.
nonisolated enum SecurePasteDirectInputPolicy {
    static let maximumUTF16Count = 16_384
    /// No physical key maps to this value. A host that ignores the Unicode payload
    /// therefore cannot reinterpret the event as a printable hardware keystroke.
    static let unicodeOnlyVirtualKey = CGKeyCode.max

    enum Validation: Equatable {
        case allowed
        case empty
        case tooLong
        case containsControlCharacter
    }

    struct Events {
        let keyDown: CGEvent
        let keyUp: CGEvent
    }

    static func validation(of text: String) -> Validation {
        guard !text.isEmpty else { return .empty }
        guard text.utf16.count <= maximumUTF16Count else { return .tooLong }
        guard !text.unicodeScalars.contains(where: { scalar in
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
        }) else {
            return .containsControlCharacter
        }
        return .allowed
    }

    static func makeEvents(text: String, eventTag: Int64) -> Events? {
        guard validation(of: text) == .allowed,
              let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: unicodeOnlyVirtualKey,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: unicodeOnlyVirtualKey,
                keyDown: false
              )
        else { return nil }

        var utf16 = Array(text.utf16)
        defer {
            utf16.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                _ = memset_s(baseAddress, bytes.count, 0, bytes.count)
            }
            utf16.removeAll(keepingCapacity: false)
        }
        utf16.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.setIntegerValueField(.eventSourceUserData, value: eventTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: eventTag)
        return Events(keyDown: keyDown, keyUp: keyUp)
    }
}

/// Pure validation for the browser-only Secure Paste transport.
///
/// Browser accessibility bridges express text offsets in UTF-16 code units. Keep all
/// arithmetic in that coordinate space, bound every readback, and reject a replacement
/// whose final state could already be present before the one plaintext-bearing request.
nonisolated enum SecurePasteWebReplacementPolicy {
    static let maximumFieldUTF16Count = 1_000_000
    static let maximumReplacementUTF16Count = maximumFieldUTF16Count

    enum LineEndings: Equatable {
        case exact
        case webKitSingleLine
        case webKitMultiline
    }

    /// Only measured Safari controls opt in. Other browsers, roles and missing metadata
    /// retain exact original-text verification; AXTextArea alone is not engine evidence.
    static func lineEndings(bundleIdentifier: String?, role: String?) -> LineEndings {
        guard bundleIdentifier == "com.apple.Safari"
                || bundleIdentifier == "com.apple.SafariTechnologyPreview" else { return .exact }
        switch role {
        case "AXTextField": return .webKitSingleLine
        case "AXTextArea": return .webKitMultiline
        default: return .exact
        }
    }

    /// Expected host transformation, never the bytes sent to the browser. Preserve every
    /// non-CR/LF code unit (including spaces, tabs, Unicode separators and combining marks).
    static func expectedText(_ text: String, lineEndings: LineEndings) -> String {
        guard lineEndings != .exact,
              text.utf16.contains(where: { $0 == 13 || (lineEndings == .webKitSingleLine && $0 == 10) })
        else { return text }
        var result: [UInt16] = []
        result.reserveCapacity(text.utf16.count)
        var previousWasCR = false
        var lastNonNewlineEnd = 0
        for unit in text.utf16 {
            if unit == 10 && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = unit == 13
            if unit == 13 || unit == 10 {
                result.append(lineEndings == .webKitSingleLine ? 32 : 10)
            } else {
                result.append(unit)
                lastNonNewlineEnd = result.count
            }
        }
        if lineEndings == .webKitSingleLine {
            result.removeSubrange(lastNonNewlineEnd..<result.count)
        }
        return String(decoding: result, as: UTF16.self)
    }

    struct Snapshot: Equatable {
        let fieldUTF16Count: Int
        let selectionLocation: Int
        let selectionLength: Int
        let selectedText: String
    }

    struct Plan: Equatable {
        let replacementLocation: Int
        let replacementLength: Int
        let replacementUTF16Count: Int
        let expectedFieldUTF16Count: Int
        let caretLocation: Int
        let expectedText: String
    }

    static func snapshot(
        fieldUTF16Count: Int,
        selectionLocation: Int,
        selectionLength: Int,
        selectedText: String
    ) -> Snapshot? {
        guard fieldUTF16Count >= 0,
              fieldUTF16Count <= maximumFieldUTF16Count,
              selectionLocation >= 0,
              selectionLength >= 0,
              selectionLocation <= fieldUTF16Count,
              selectionLength <= fieldUTF16Count - selectionLocation,
              selectionLength <= maximumReplacementUTF16Count,
              selectedText.utf16.count == selectionLength
        else { return nil }

        return Snapshot(
            fieldUTF16Count: fieldUTF16Count,
            selectionLocation: selectionLocation,
            selectionLength: selectionLength,
            selectedText: selectedText
        )
    }

    static func plan(
        replacing snapshot: Snapshot, with replacement: String, lineEndings: LineEndings = .exact
    ) -> Plan? {
        // Bound the original request even when normalization would make it smaller.
        guard !replacement.isEmpty, replacement.utf16.count <= maximumReplacementUTF16Count else { return nil }
        let expected = expectedText(replacement, lineEndings: lineEndings)
        let replacementUTF16Count = expected.utf16.count
        guard replacementUTF16Count > 0,
              !(snapshot.selectionLength == replacementUTF16Count
                && utf16ContentsMatch(snapshot.selectedText, expected))
        else { return nil }

        let retainedCount = snapshot.fieldUTF16Count - snapshot.selectionLength
        guard replacementUTF16Count <= maximumFieldUTF16Count - retainedCount else {
            return nil
        }
        let expectedFieldUTF16Count = retainedCount + replacementUTF16Count
        guard replacementUTF16Count <= Int.max - snapshot.selectionLocation else {
            return nil
        }

        return Plan(
            replacementLocation: snapshot.selectionLocation,
            replacementLength: snapshot.selectionLength,
            replacementUTF16Count: replacementUTF16Count,
            expectedFieldUTF16Count: expectedFieldUTF16Count,
            caretLocation: snapshot.selectionLocation + replacementUTF16Count,
            expectedText: expected
        )
    }

    static func confirms(_ plan: Plan, fieldUTF16Count: Int?, insertedText: String?) -> Bool {
        guard fieldUTF16Count == plan.expectedFieldUTF16Count, let insertedText else { return false }
        return utf16ContentsMatch(insertedText, plan.expectedText)
    }

    static func utf16ContentsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
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
