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
    /// The caret advanced by exactly the pasted length, or the text before it now ends with what we
    /// pasted.
    case pasteObserved
    /// Forward movement, but not by our length — the host normalized something.
    case forwardEditObserved
    /// Movement backwards or a change without forward motion: our deletes are still arriving.
    case pendingEditObserved
    case idle
    case unreadable
}

nonisolated enum PasteConfirmationAbort: Equatable {
    case frontmostAppChanged
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
}

nonisolated enum SnippetPasteConfirmationPolicy {
    struct Tuning: Equatable {
        var pollInterval: Duration = .milliseconds(20)
        /// Wall-clock ceiling, independent of the attempt count: on a stalled host each poll can
        /// cost up to the Accessibility messaging timeout, so counting attempts alone is not a bound.
        var maxWait: Duration = .milliseconds(1200)
        var maxAttempts: Int = 60
        /// 100 ms for a stronger signal to show up before accepting a normalized edit.
        var forwardEditGrace: Int = 5
        /// 400 ms — deliberately no shorter than the fixed 350 ms delay this replaced, because a
        /// host that tells us nothing is exactly where the old delay was already too short.
        var blindAcceptAttempt: Int = 20
        var fingerprintTailLength: Int = 32

        static let `default` = Tuning()
    }

    struct Input: Equatable {
        var attempt: Int
        var elapsed: Duration
        var progress: PasteProgress
        var hadFingerprintBeforePaste: Bool
        var sawReadableFingerprintAfterPaste: Bool
        var firstForwardEditAttempt: Int?
        var abort: PasteConfirmationAbort?
    }

    nonisolated static func verdict(
        _ input: Input,
        tuning: Tuning = .default
    ) -> PasteConfirmationVerdict {
        if let abort = input.abort { return .abandoned(abort) }
        if input.progress == .pasteObserved { return .confirmed }
        if input.attempt >= tuning.maxAttempts || input.elapsed >= tuning.maxWait { return .timedOut }
        if let first = input.firstForwardEditAttempt, input.attempt - first >= tuning.forwardEditGrace {
            return .confirmed
        }
        if input.attempt >= tuning.blindAcceptAttempt,
           !input.hadFingerprintBeforePaste || !input.sawReadableFingerprintAfterPaste {
            return .confirmed
        }
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
        if after.selectionLength == 0,
           delta == pastedText.utf16.count || delta == pastedText.unicodeScalars.count {
            return .pasteObserved
        }

        // Only when something actually changed: a field that already ended with the same characters
        // would otherwise confirm a paste that never happened.
        if after != before {
            let tail = confirmationTail(of: pastedText, maxLength: tailLength)
            if !tail.isEmpty, after.textBeforeCaret.hasSuffix(tail) { return .pasteObserved }
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
