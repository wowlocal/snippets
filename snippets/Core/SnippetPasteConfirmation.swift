import Foundation

/// A cheap, bounded fingerprint of the caret and the text right before it. Deliberately not the
/// field's whole value: in a real editor that is the entire document, re-serialized over
/// Accessibility IPC on every poll.
nonisolated struct PasteCaretFingerprint: Equatable {
    let caretLocation: Int
    let selectionLength: Int
    let textBeforeCaret: String
}

nonisolated enum PasteProgress: Equatable {
    /// Changed text before the caret matches the replacement tail.
    case pasteObserved
    /// Caret movement without matching text is not evidence of this paste.
    case forwardEditObserved
    /// Movement backwards or a change without forward motion: our deletes are still arriving.
    case pendingEditObserved
    case idle
    case unreadable
}

nonisolated enum PasteConfirmationAbort: Equatable {
    case frontmostAppChanged
    case focusedElementChanged
    case pasteboardSuperseded
    case secureInputEnabled
    case newExpansionStarted
    case applicationTerminating
}

nonisolated enum PasteConfirmationVerdict: Equatable {
    case confirmed
    case keepWaiting
    case timedOut
    case abandoned(PasteConfirmationAbort)

    var diagnosticOutcome: DiagnosticPasteOutcome {
        switch self {
        case .confirmed: .textObserved
        case .timedOut: .timedOut
        case .keepWaiting: .interrupted
        case .abandoned(.pasteboardSuperseded): .pasteboardSuperseded
        case .abandoned(.secureInputEnabled): .secureInputEnabled
        case .abandoned(.frontmostAppChanged), .abandoned(.focusedElementChanged): .targetChanged
        case .abandoned(.newExpansionStarted), .abandoned(.applicationTerminating): .interrupted
        }
    }
}

nonisolated enum SnippetPasteConfirmationPolicy {
    struct Tuning: Equatable {
        var pollInterval: Duration = .milliseconds(20)
        /// Wall-clock ceiling, independent of the attempt count: on a stalled host each poll can
        /// cost up to the Accessibility messaging timeout, so counting attempts alone is not a bound.
        var maxWait: Duration = .milliseconds(1200)
        var maxAttempts: Int = 60
        var fingerprintTailLength: Int = 32

        static let `default` = Tuning()
    }

    struct Input: Equatable {
        var attempt: Int
        var elapsed: Duration
        var progress: PasteProgress
        var abort: PasteConfirmationAbort?
    }

    nonisolated static func verdict(
        _ input: Input,
        tuning: Tuning = .default
    ) -> PasteConfirmationVerdict {
        if let abort = input.abort { return .abandoned(abort) }
        if input.progress == .pasteObserved { return .confirmed }
        if input.attempt >= tuning.maxAttempts || input.elapsed >= tuning.maxWait { return .timedOut }
        // An unreadable host gets the entire bounded window. Neither a timer nor unrelated
        // caret motion can confirm a paste; the caller must preserve the timed-out outcome.
        return .keepWaiting
    }

    nonisolated static func progress(
        before: PasteCaretFingerprint?,
        after: PasteCaretFingerprint?,
        pastedText: String,
        tailLength: Int
    ) -> PasteProgress {
        guard let before, let after else { return .unreadable }

        let delta = after.caretLocation - before.caretLocation
        // Require forward motion and changed matching text. Our backspaces can expose an old
        // occurrence of the snippet; matching that suffix must not release the clipboard early.
        // A renderer that resets the caret into an earlier node remains unconfirmed.
        if delta > 0, after.selectionLength == 0, after.textBeforeCaret != before.textBeforeCaret {
            let tail = confirmationTail(of: pastedText, maxLength: tailLength)
            let observed = confirmationTail(of: after.textBeforeCaret, maxLength: tailLength)
            if !tail.isEmpty, observed.hasSuffix(tail) { return .pasteObserved }
        }
        if delta > 0 { return .forwardEditObserved }
        if after != before { return .pendingEditObserved }
        return .idle
    }

    /// A multiline paste leaves only its last line in the AX node before the caret, so the tail is
    /// the comparable part.
    nonisolated static func confirmationTail(of text: String, maxLength: Int) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isNewline { trimmed = trimmed.dropLast() }
        guard let lineStart = trimmed.lastIndex(where: \.isNewline) else {
            return String(trimmed.suffix(maxLength))
        }
        return String(trimmed[trimmed.index(after: lineStart)...].suffix(maxLength))
    }
}
