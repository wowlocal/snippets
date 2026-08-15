import Foundation

nonisolated struct SuggestionTriggerContext: Equatable {
    let query: String
    let triggerLength: Int

    nonisolated static func context(inTextBeforeCaret textBeforeCaret: String) -> SuggestionTriggerContext? {
        guard let slashIndex = textBeforeCaret.lastIndex(of: "\\") else { return nil }

        let queryStart = textBeforeCaret.index(after: slashIndex)
        let query = String(textBeforeCaret[queryStart...])
        guard query.allSatisfy(isValidKeywordCharacter) else { return nil }

        return SuggestionTriggerContext(query: query, triggerLength: 1 + query.count)
    }

    nonisolated private static func isValidKeywordCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isNewline
    }

    /// The text the trigger occupies in the host's field.
    nonisolated var triggerText: String { "\\" + query }
}

/// What we intend to delete before the caret, and how much we trust that count.
nonisolated struct TriggerDeletion: Equatable {
    enum Provenance: Equatable {
        /// Counted from a fresh Accessibility read of the focused field.
        case accessibilityConfirmed
        /// Counted from our own key tracking, because Accessibility text was unreadable or stale.
        case localTracking
    }

    let characterCount: Int
    let expectedText: String
    let provenance: Provenance

    var isSelfConsistent: Bool { expectedText.count == characterCount }

    static func confirmed(_ context: SuggestionTriggerContext) -> TriggerDeletion {
        TriggerDeletion(
            characterCount: context.triggerLength,
            expectedText: context.triggerText,
            provenance: .accessibilityConfirmed
        )
    }

    static func localTracking(query: String) -> TriggerDeletion {
        TriggerDeletion(
            characterCount: 1 + query.count,
            expectedText: "\\" + query,
            provenance: .localTracking
        )
    }

    /// Auto-expansion suppresses the key that completed the keyword, so the host holds
    /// "\" + query minus that last character.
    static func pendingLastCharacter(query: String) -> TriggerDeletion {
        TriggerDeletion(
            characterCount: query.count,
            expectedText: "\\" + String(query.dropLast()),
            provenance: .localTracking
        )
    }
}

/// How much authority the suggestion query has over text in another process.
///
/// Display stays optimistic for responsiveness, but only an Accessibility-confirmed
/// context may authorize deletion. In particular, a physical Backspace says nothing
/// about whether the host deleted a character, an autocomplete selection, or merely
/// dismissed UI.
nonisolated enum SuggestionContextState: String, Codable, Equatable, Sendable {
    case axConfirmed = "ax_confirmed"
    case localDisplayOnly = "local_display_only"
    case uncertainAfterHostEdit = "uncertain_after_host_edit"

    nonisolated var canAuthorizeExpansion: Bool { self == .axConfirmed }

    /// Plain typing can update suggestions immediately, but the new host text has not
    /// yet been observed. An already-uncertain edit cannot be made trustworthy by more
    /// locally inferred input.
    nonisolated var afterLocalPrintableEdit: SuggestionContextState {
        self == .uncertainAfterHostEdit ? .uncertainAfterHostEdit : .localDisplayOnly
    }

    /// Backspace and host-owned editing commands have app-specific semantics.
    nonisolated var afterAmbiguousHostEdit: SuggestionContextState {
        .uncertainAfterHostEdit
    }
}

/// The narrow exception for terminal surfaces whose Accessibility model exposes
/// selection, but not the insertion caret.
///
/// Ghostty's `AXSelectedTextRange` describes a mouse selection in the rendered
/// terminal buffer. It therefore cannot confirm the command-line text immediately
/// before the shell cursor. Local tracking is allowed only while every other signal
/// still proves that this is the same uninterrupted suggestion session. In
/// particular, a Backspace or other host-owned edit moves the state to
/// `uncertainAfterHostEdit`, and a host that has ever supplied a real AX context is
/// never allowed to fall back to this exception.
nonisolated enum CaretlessTerminalSuggestionPolicy {
    private static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    private static let textAreaRole = "AXTextArea"

    static func isSupportedHost(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.lowercased() == ghosttyBundleIdentifier
    }

    static func canAuthorizeLocalTracking(
        bundleIdentifier: String?,
        focusedRole: String?,
        contextState: SuggestionContextState,
        hasAXConfirmedContext: Bool,
        isSecureSnippet: Bool,
        targetStillMatches: Bool
    ) -> Bool {
        isSupportedHost(bundleIdentifier: bundleIdentifier)
            && focusedRole == textAreaRole
            && contextState == .localDisplayOnly
            && !hasAXConfirmedContext
            && !isSecureSnippet
            && targetStillMatches
    }
}
