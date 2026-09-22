import Foundation

/// Outcome of one direct Accessibility replacement (cross-process reads/writes are not atomic).
nonisolated enum AccessibilityReplacement: Equatable {
    case delivered
    /// The field does not expose readable text or writable attributes.
    case unavailable
    /// The text before the caret was read and it is not what we expected.
    case rejected
    /// The selection transaction lost its proof before invoking a text setter. Do not fall back.
    case cancelledBeforeText
    /// A write was attempted but its result could not be verified. Never follow it with a second edit.
    case attemptedUnconfirmed
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
        case .cancelledBeforeText, .attemptedUnconfirmed:
            return .abort
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
              caretRange.location != NSNotFound,
              caretRange.length >= 0,
              caretRange.length < Int.max - caretRange.location,
              replacementUTF16Length >= 0
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
        guard replacementUTF16Length < Int.max - location else { return .unavailable }
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
        guard let expectedValue = expectedValue(
            valueBefore: valueBefore, plan: plan, replacement: replacement) else { return false }
        // Verify the complete edit, including both untouched sides. Matching only the inserted
        // prefix can acknowledge a no-op; matching a length delta can acknowledge somebody else's
        // edit. Swift's canonical Unicode equality permits composition normalization, but casing,
        // line-ending conversion and unrelated same-length text are not proof of our write.
        return valueAfter == expectedValue
    }

    nonisolated static func expectedValue(
        valueBefore: String,
        plan: Plan,
        replacement: String
    ) -> String? {
        let originalLength = valueBefore.utf16.count
        let range = plan.replacementRange
        // Do not trust a malformed plan, even if unrelated text happens to match afterwards.
        // Subtract only after proving each bound so NSMaxRange cannot overflow.
        guard range.location >= 0, range.length >= 0,
              range.location <= originalLength,
              range.length <= originalLength - range.location else { return nil }

        guard let stringRange = Range(range, in: valueBefore),
              stringRange.lowerBound.samePosition(in: valueBefore.unicodeScalars) != nil,
              stringRange.upperBound.samePosition(in: valueBefore.unicodeScalars) != nil else { return nil }
        return valueBefore.replacingCharacters(in: stringRange, with: replacement)
    }

    /// Normalization may change UTF-16 offsets even when the whole edit is confirmed. The exact
    /// untouched suffix anchors the inserted text's end in the actual host rendition; without it
    /// leave the host's caret alone instead of reusing a possibly obsolete planned offset.
    nonisolated static func confirmedCaretLocation(
        valueBefore: String,
        valueAfter: String,
        plan: Plan,
        replacement: String
    ) -> Int? {
        guard writeLanded(valueBefore: valueBefore, valueAfter: valueAfter,
                          plan: plan, replacement: replacement),
              let originalRange = Range(plan.replacementRange, in: valueBefore) else { return nil }
        let suffix = valueBefore[originalRange.upperBound...].utf16
        let actual = valueAfter.utf16
        guard actual.count >= suffix.count,
              actual.suffix(suffix.count).elementsEqual(suffix) else { return nil }
        let location = actual.count - suffix.count
        guard Range(NSRange(location: location, length: 0), in: valueAfter) != nil else { return nil }
        return location
    }
}

/// A bounded, verified selection for the host's own paste operation. Preparing the selection
/// changes no text: the trigger and any original selection are replaced together by one paste.
/// Keep this snapshot in memory only; its text is not diagnostic data.
nonisolated struct VerifiedTriggerSelection: Equatable {
    static let maximumReadUTF16Length = 10_000

    let originalSelection: NSRange
    let replacementRange: NSRange
    let expectedText: String

    private init(originalSelection: NSRange, replacementRange: NSRange, expectedText: String) {
        self.originalSelection = originalSelection
        self.replacementRange = replacementRange
        self.expectedText = expectedText
    }

    enum Preparation: Equatable {
        case verified(VerifiedTriggerSelection)
        case unavailable
        case rejected
    }

    /// `textBeforeCaret` may be a bounded suffix of the field, but it must end exactly at the
    /// original selection's start. `selectedText` is the host's text in that original selection.
    static func make(
        deletion: TriggerDeletion,
        textBeforeCaret: String,
        originalSelection: NSRange,
        selectedText: String
    ) -> VerifiedTriggerSelection? {
        guard case let .verified(selection) = prepare(
            deletion: deletion,
            textBeforeCaret: textBeforeCaret,
            originalSelection: originalSelection,
            readSelectedText: { selectedText }) else { return nil }
        return selection
    }

    /// Prove the trigger before asking the host for the selected suffix. A suffix read failure
    /// must not downgrade an already observed trigger mismatch into permission for Backspace.
    static func prepare(
        deletion: TriggerDeletion,
        textBeforeCaret: String,
        originalSelection: NSRange,
        readSelectedText: () -> String?
    ) -> Preparation {
        guard deletion.characterCount > 0,
              deletion.isSelfConsistent,
              originalSelection.location >= 0,
              originalSelection.location != NSNotFound,
              originalSelection.length >= 0,
              originalSelection.length <= maximumReadUTF16Length,
              originalSelection.length < Int.max - originalSelection.location
        else { return .unavailable }

        let beforeLength = textBeforeCaret.utf16.count
        guard textBeforeCaret.count >= deletion.characterCount else { return .rejected }

        let triggerStart = textBeforeCaret.index(
            textBeforeCaret.endIndex, offsetBy: -deletion.characterCount)
        let actualTrigger = textBeforeCaret[triggerStart...]
        // String equality accepts canonically equivalent Unicode. AX ranges describe the exact
        // UTF-16 rendition, so even an equivalent spelling must be re-read before selecting it.
        guard actualTrigger.utf16.elementsEqual(deletion.expectedText.utf16) else { return .rejected }
        guard beforeLength <= maximumReadUTF16Length - originalSelection.length,
              beforeLength <= originalSelection.location,
              case let .plan(plan) = AccessibilityTextReplacement.plan(
                textBeforeCaret: textBeforeCaret,
                caretRange: originalSelection,
                expectedTrigger: deletion.expectedText,
                triggerCharacterCount: deletion.characterCount,
                replacementUTF16Length: 0)
        else { return .unavailable }
        guard let selectedText = readSelectedText() else { return .unavailable }
        guard selectedText.utf16.count == originalSelection.length else { return .rejected }

        return .verified(VerifiedTriggerSelection(
            originalSelection: originalSelection,
            replacementRange: plan.replacementRange,
            expectedText: String(actualTrigger) + selectedText))
    }

    /// Re-read both range and selected text before paste or a conservative selection rollback.
    /// Equal lengths alone cannot distinguish our selection from a concurrent edit.
    func matches(range: NSRange, text: String) -> Bool {
        range == replacementRange && text.utf16.elementsEqual(expectedText.utf16)
    }

    /// A browser can accept a selection request before its AX cache observes it. Only the
    /// unchanged original range is pending; another range or changed text is a real conflict.
    func observation(range: NSRange?, text: String?) -> TriggerSelectionObservation {
        guard let range else { return .unavailable }
        guard range == originalSelection || range == replacementRange else { return .rangeChanged }
        guard let text else { return .unavailable }
        guard text.utf16.elementsEqual(expectedText.utf16) else { return .textChanged }
        return range == replacementRange ? .replacement : .original
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.originalSelection == rhs.originalSelection
            && lhs.replacementRange == rhs.replacementRange
            && lhs.expectedText.utf16.elementsEqual(rhs.expectedText.utf16)
    }
}

/// The selected-text setter has two distinct failure boundaries. Before the text setter is
/// invoked, only selection may have changed and the caller can conservatively restore it. After
/// that call even a failed reply can hide a completed edit: no rollback, fallback or retry is safe.
nonisolated enum AccessibilitySelectedTextTransaction {
    enum Result: Equatable {
        case delivered
        case selectionUnconfirmed
        case textUnconfirmed
    }

    static func run(
        contextIsValid: () -> Bool,
        originalSelectionMatches: () -> Bool,
        selectTrigger: () -> Bool,
        selectedTriggerMatches: () -> Bool,
        writeText: () -> Bool,
        confirmText: () -> Bool,
        finishCaret: () -> Void,
        restoreSelection: () -> Void
    ) -> Result {
        guard contextIsValid(), originalSelectionMatches(), contextIsValid() else {
            return .selectionUnconfirmed
        }
        var textWriteAttempted = false
        defer {
            if !textWriteAttempted { restoreSelection() }
        }
        guard selectTrigger(), selectedTriggerMatches(), contextIsValid() else {
            return .selectionUnconfirmed
        }
        textWriteAttempted = true
        guard writeText(), confirmText() else { return .textUnconfirmed }
        // A delivered write belongs to its original field even if focus moved during readback.
        // Only adjust the caret while the caller can still prove the original context.
        if contextIsValid() { finishCaret() }
        return .delivered
    }
}

typealias TriggerSelectionObservation = DiagnosticSelectionObservation

/// One selection request, bounded asynchronous AX acknowledgement, then at most one native paste.
/// AX setters acknowledge dispatch, not renderer completion. Never turn a stale read into either
/// permission to paste or a destructive fallback. All host callbacks stay on the caller's main actor.
nonisolated enum SelectionPasteTransaction {
    enum Result: Equatable, Sendable {
        case posted
        case contextChanged
        case originalSelectionChanged
        case selectionWriteFailed
        case selectionChanged
        case selectionTimedOut
    }

    typealias Phase = DiagnosticSelectionPhase
    typealias Progress = DiagnosticSelectionConfirmation

    struct Report: Equatable, Sendable {
        let result: Result
        let progress: Progress
    }

    // A second bound prevents a faulty clock/wait adapter from spinning. Production waits survive
    // task cancellation; the context guard then decides whether any further mutation is allowed.
    static let timeout: Duration = .milliseconds(400)
    static let pollInterval: Duration = .milliseconds(12)
    static let maximumPolls = 40

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let bounded = min(.seconds(600), max(.zero, duration)).components
        return bounded.seconds * 1_000 + bounded.attoseconds / 1_000_000_000_000_000
    }

    @MainActor
    static func run(
        contextIsValid: () -> Bool,
        observeSelection: () -> TriggerSelectionObservation,
        selectTrigger: () -> Bool,
        captureBaseline: () -> Void,
        postPaste: () -> Void,
        wait: (Duration) async -> Void,
        now: () -> ContinuousClock.Instant = { .now }
    ) async -> Report {
        var progress = Progress()
        func finish(_ result: Result) -> Report { Report(result: result, progress: progress) }
        guard contextIsValid() else { return finish(.contextChanged) }
        progress.observation = observeSelection()
        guard contextIsValid() else { return finish(.contextChanged) }
        guard progress.observation == .original else { return finish(.originalSelectionChanged) }
        progress.phase = .selectionRequest
        progress.writeAttempted = true
        guard selectTrigger() else { return finish(.selectionWriteFailed) }

        progress.phase = .confirmation
        let start = now()
        while true {
            let allowedBeforeRead = contextIsValid()
            progress.waitMilliseconds = milliseconds(start.duration(to: now()))
            guard allowedBeforeRead else { return finish(.contextChanged) }
            guard start.duration(to: now()) < timeout else { return finish(.selectionTimedOut) }
            progress.observation = observeSelection()
            progress.polls += 1
            let contextMatches = contextIsValid() // Recheck after every blocking AX reply.
            let elapsed = start.duration(to: now())
            progress.waitMilliseconds = milliseconds(elapsed)
            guard contextMatches else { return finish(.contextChanged) }
            guard elapsed < timeout else { return finish(.selectionTimedOut) }
            switch progress.observation {
            case .replacement:
                captureBaseline()
                progress.phase = .finalValidation
                progress.observation = observeSelection()
                guard contextIsValid() else { return finish(.contextChanged) }
                // Once confirmed, loss of that proof is not a pending initial request anymore.
                guard progress.observation == .replacement else { return finish(.selectionChanged) }
                postPaste() // No await between the final proof, context check and dispatch.
                return finish(.posted)
            case .original, .unavailable:
                guard progress.polls < maximumPolls else { return finish(.selectionTimedOut) }
                await wait(min(pollInterval, timeout - elapsed))
            case .rangeChanged, .textChanged, .notRead:
                return finish(.selectionChanged)
            }
        }
    }

    /// Called only after an attempted selection with no paste. An original-range reply may predate
    /// the still-pending request, so it is never immediately reported as `notNeeded`. Wait for our
    /// exact selection, restore once, and acknowledge that restoration asynchronously too. If the
    /// host never acknowledges or the user takes over, report uncertainty and stop without edits.
    @MainActor
    static func restore(
        contextIsValid: () -> Bool,
        observeSelection: () -> TriggerSelectionObservation,
        restoreOriginal: () -> Bool,
        wait: (Duration) async -> Void,
        now: () -> ContinuousClock.Instant = { .now }
    ) async -> DiagnosticPasteSelectionRestoration {
        var restorationRequested = false
        var start = now()
        var polls = 0
        while true {
            guard contextIsValid() else { return .skippedContextChanged }
            guard start.duration(to: now()) < timeout, polls < maximumPolls else { return .timedOut }
            let observation = observeSelection()
            guard contextIsValid() else { return .skippedContextChanged }
            let elapsed = start.duration(to: now())
            guard elapsed < timeout else { return .timedOut }
            polls += 1
            switch observation {
            case .replacement where !restorationRequested:
                restorationRequested = true
                guard restoreOriginal() else { return .failed }
                // Give the single restore request its own bounded acknowledgement window.
                start = now()
                polls = 0
                continue
            case .original where restorationRequested:
                return .restored
            case .original, .replacement, .unavailable:
                await wait(min(pollInterval, timeout - elapsed))
            case .rangeChanged, .textChanged, .notRead:
                return .skippedContextChanged
            }
        }
    }
}
