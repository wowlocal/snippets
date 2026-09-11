import AppKit

/// Reads text before the selection start (or the collapsed caret), without
/// confusing a terminal's placeholder {0, 0} with a real document position.
@MainActor
struct SuggestionAXTextReader {
    enum Stage { case selectedRange, rangeText, value }

    struct Failure {
        let stage: Stage
        let error: AXError
        var allowsLocalTracking = false
        var mayReadAncestor = false
    }

    enum Result {
        case text(String)
        case unavailable(Failure)
    }

    var copyAttribute: (CFString, inout CFTypeRef?) -> AXError
    var copyParameterizedAttribute: (CFString, CFTypeRef, inout CFTypeRef?) -> AXError
    var isSelectionSettable: () -> (AXError, Bool)

    func read(maxCharacters: Int) -> Result {
        var value: CFTypeRef?
        let rangeResult = copyAttribute(kAXSelectedTextRangeAttribute as CFString, &value)
        guard rangeResult == .success else {
            let capabilityUnavailable = Self.isCapabilityUnavailable(rangeResult)
            var role: CFTypeRef?
            _ = copyAttribute(kAXRoleAttribute as CFString, &role)
            let isTextControl = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]
                .contains(role as? String ?? "")
            return .unavailable(Failure(
                stage: .selectedRange, error: rangeResult,
                allowsLocalTracking: capabilityUnavailable && role as? String == kAXTextAreaRole,
                mayReadAncestor: capabilityUnavailable && !isTextControl))
        }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange else {
            return .unavailable(Failure(stage: .selectedRange, error: .illegalArgument))
        }
        var selection = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selection),
              selection.location >= 0, selection.location != NSNotFound,
              selection.length >= 0,
              selection.length < Int.max - selection.location else {
            // Malformed ranges must not authorize local backspaces or an
            // ancestor's unrelated text. A valid nonempty selection is useful:
            // Chrome selects its autocomplete suffix after the typed trigger,
            // and replacement already includes that suffix in the deleted range.
            return .unavailable(Failure(stage: .selectedRange, error: .illegalArgument))
        }

        if selection.location == 0 {
            // A real selection beginning at zero has no text before it. Only
            // the collapsed {0, 0} case needs terminal-placeholder detection.
            if selection.length > 0 { return .text("") }
            let (settableResult, settable) = isSelectionSettable()
            if settableResult == .success && settable { return .text("") }
            guard settableResult == .success || Self.isCapabilityUnavailable(settableResult) else {
                return .unavailable(Failure(stage: .selectedRange, error: settableResult))
            }
            let parameter = AXValueCreate(.cfRange, &selection)!
            var bounds: CFTypeRef?
            let boundsResult = copyParameterizedAttribute(
                kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &bounds)
            if boundsResult == .success {
                var rect = CGRect.zero
                if let bounds, CFGetTypeID(bounds) == AXValueGetTypeID(),
                   AXValueGetType(bounds as! AXValue) == .cgRect,
                   AXValueGetValue(bounds as! AXValue, .cgRect, &rect),
                   rect.origin.x.isFinite, rect.origin.y.isFinite,
                   rect.width.isFinite, rect.width >= 0,
                   rect.height.isFinite, rect.height > 0 {
                    return .text("")
                }
                return .unavailable(Failure(stage: .rangeText, error: .illegalArgument))
            }
            // Positive capability evidence only: a timeout is not proof that
            // this surface lacks a caret. {0, 0} alone is not proof either.
            var role: CFTypeRef?
            _ = copyAttribute(kAXRoleAttribute as CFString, &role)
            return .unavailable(Failure(
                stage: .rangeText, error: boundsResult,
                allowsLocalTracking: settableResult == .success && !settable
                    && Self.isCapabilityUnavailable(boundsResult)
                    && role as? String == kAXTextAreaRole))
        }

        let start = max(0, selection.location - max(0, maxCharacters))
        var range = CFRange(location: start, length: selection.location - start)
        let parameter = AXValueCreate(.cfRange, &range)!
        var textValue: CFTypeRef?
        let textResult = copyParameterizedAttribute(
            kAXStringForRangeParameterizedAttribute as CFString, parameter, &textValue)
        if textResult == .success {
            guard let text = textValue as? String, text.utf16.count == range.length else {
                return .unavailable(Failure(stage: .rangeText, error: .illegalArgument))
            }
            return .text(text)
        }
        guard Self.isCapabilityUnavailable(textResult) else {
            return .unavailable(Failure(stage: .rangeText, error: textResult))
        }

        // Browsers may supply AXValue without AXStringForRange. Do not clamp
        // an out-of-bounds caret: that would manufacture confirmation from a
        // different, older snapshot of the document.
        var wholeValue: CFTypeRef?
        let valueResult = copyAttribute(kAXValueAttribute as CFString, &wholeValue)
        guard valueResult == .success else {
            return .unavailable(Failure(stage: .value, error: valueResult))
        }
        guard let text = wholeValue as? String,
              selection.location <= (text as NSString).length,
              selection.length <= (text as NSString).length - selection.location else {
            return .unavailable(Failure(stage: .value, error: .illegalArgument))
        }
        return .text((text as NSString).substring(with: NSRange(
            location: start, length: range.length)))
    }

    private static func isCapabilityUnavailable(_ error: AXError) -> Bool {
        [.attributeUnsupported, .parameterizedAttributeUnsupported, .noValue, .notImplemented]
            .contains(error)
    }
}

extension SuggestionAXTextReader {
    init(element: AXUIElement, budget: AXMessagingBudget) {
        copyAttribute = { attribute, value in
            budget.copyAttributeValue(of: element, attribute: attribute, into: &value)
        }
        copyParameterizedAttribute = { attribute, parameter, value in
            budget.copyParameterizedAttributeValue(
                of: element, attribute: attribute, parameter: parameter, into: &value)
        }
        isSelectionSettable = {
            guard budget.bind(element) else { return (.cannotComplete, false) }
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(
                element, kAXSelectedTextRangeAttribute as CFString, &settable)
            return (result, settable.boolValue)
        }
    }
}
