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

nonisolated enum SuggestionContextRefreshResult: Equatable {
    case synced
    case localFallback
    case missingTrigger
    case unavailable

    nonisolated var canUseForExpansion: Bool {
        switch self {
        case .synced, .localFallback:
            return true
        case .missingTrigger, .unavailable:
            return false
        }
    }
}
