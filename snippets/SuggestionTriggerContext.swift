import Foundation

struct SuggestionTriggerContext: Equatable {
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
}

enum SuggestionContextRefreshResult: Equatable {
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
