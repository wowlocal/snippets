import Foundation

/// Outcome of one atomic Accessibility replacement.
nonisolated enum AccessibilityReplacement: Equatable {
    case delivered
    /// The field does not expose readable text or writable attributes.
    case unavailable
    /// The text before the caret was read and it is not what we expected.
    case rejected
}

nonisolated enum AccessibilityReplacementPolicy {
    enum Action: Equatable {
        case commit
        case abort
        case useEvents
    }

    /// A rejected replacement fails closed only when the delete count came from Accessibility in the
    /// first place. With a locally tracked count, Accessibility is merely lagging — which is the
    /// normal state in Chromium and Electron — so the event path stays the answer there.
    nonisolated static func action(
        for outcome: AccessibilityReplacement,
        provenance: TriggerDeletion.Provenance
    ) -> Action {
        switch outcome {
        case .delivered:
            return .commit
        case .unavailable:
            return .useEvents
        case .rejected:
            return provenance == .accessibilityConfirmed ? .abort : .useEvents
        }
    }
}

/// How the Accessibility path may write into a given host, if at all.
nonisolated enum AccessibilityInsertionPolicy {
    enum Strategy: Equatable {
        /// Overwrite just the trigger's range. Surgical, and what every well-behaved host wants.
        case selectedText
        /// Rewrite the field's whole value. Chromium only, and only in the browser's own UI —
        /// the caller still has to prove the target is not rendered page content.
        case wholeValue
        /// Leave the host to the event path.
        case none
    }

    /// `globallyEnabled` is `nil` when the user never set the switch.
    ///
    /// Chromium is decided by host because its omnibox is the one failure the verification step
    /// cannot see. A selected-text write there lands in the text it draws and never reaches the edit
    /// model, so `AXValue` reads back exactly what we wrote while Return still navigates to what the
    /// user typed — `\crew` expands to a URL on screen and then searches the web for `\crew`. The
    /// model is not in the Accessibility tree, so no read tells that apart from a real success. A
    /// whole-value write does reach the model, which is why Chromium gets that strategy instead of a
    /// flat refusal.
    nonisolated static func strategy(
        bundleID: String?,
        globallyEnabled: Bool?,
        hostIsChromiumFamily: Bool,
        excludedBundleIDs: [String]
    ) -> Strategy {
        if globallyEnabled == false { return .none }
        // No bundle ID is no evidence against the host; the outcome checks still guard the write.
        guard let bundleID else { return .selectedText }
        if excludedBundleIDs.contains(bundleID) { return .none }
        return hostIsChromiumFamily ? .wholeValue : .selectedText
    }
}

nonisolated enum AccessibilityTextReplacement {
    struct Plan: Equatable {
        /// UTF-16 range that will be selected and overwritten.
        let replacementRange: NSRange
        /// UTF-16 location of the collapsed caret after the write.
        let caretLocation: Int
    }

    enum PlanResult: Equatable {
        case plan(Plan)
        case unavailable
        case rejected
    }

    /// The one place a Character count becomes a UTF-16 offset. The bridge is `String.Index`, never
    /// arithmetic on lengths: `textBeforeCaret` ends exactly at the caret, so its last N characters
    /// pin the trigger's UTF-16 length in the very rendition the host just handed us.
    nonisolated static func plan(
        textBeforeCaret: String,
        caretRange: NSRange,
        expectedTrigger: String,
        triggerCharacterCount: Int,
        replacementUTF16Length: Int
    ) -> PlanResult {
        guard triggerCharacterCount > 0,
              expectedTrigger.count == triggerCharacterCount,
              caretRange.location >= 0,
              caretRange.length >= 0
        else { return .unavailable }

        guard textBeforeCaret.count >= triggerCharacterCount else { return .rejected }

        let start = textBeforeCaret.index(textBeforeCaret.endIndex, offsetBy: -triggerCharacterCount)
        let actual = String(textBeforeCaret[start...])
        guard actual == expectedTrigger else { return .rejected }

        let triggerUTF16Length = actual.utf16.count
        // Offsets contradict the text we just read: an inconsistent AX model, not evidence that the
        // text changed, so the event path is still fair game.
        guard caretRange.location >= triggerUTF16Length else { return .unavailable }

        let location = caretRange.location - triggerUTF16Length
        // An active selection is folded into the range, matching what backspaces would do.
        let length = triggerUTF16Length + caretRange.length

        return .plan(Plan(
            replacementRange: NSRange(location: location, length: length),
            caretLocation: location + replacementUTF16Length
        ))
    }

    /// Chromium and Electron can answer `.success` to a write that did nothing, so the write is
    /// verified rather than trusted.
    nonisolated static func writeLanded(
        valueBefore: String,
        valueAfter: String,
        plan: Plan,
        replacement: String
    ) -> Bool {
        let text = valueAfter as NSString
        let inserted = NSRange(location: plan.replacementRange.location, length: replacement.utf16.count)
        if inserted.location >= 0,
           NSMaxRange(inserted) <= text.length,
           text.substring(with: inserted) == replacement {
            return true
        }

        // The host may have normalized what it stored (composition form, line endings); the expected
        // length delta still tells us the edit landed.
        let expectedDelta = replacement.utf16.count - plan.replacementRange.length
        return text.length - (valueBefore as NSString).length == expectedDelta
    }
}
