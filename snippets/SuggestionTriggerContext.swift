import Foundation

struct SuggestionTriggerContext: Equatable {
    let query: String
    let triggerLength: Int

    static func context(inTextBeforeCaret textBeforeCaret: String) -> SuggestionTriggerContext? {
        guard let slashIndex = textBeforeCaret.lastIndex(of: "\\") else { return nil }

        let queryStart = textBeforeCaret.index(after: slashIndex)
        let query = String(textBeforeCaret[queryStart...])
        guard query.allSatisfy(isValidKeywordCharacter) else { return nil }

        return SuggestionTriggerContext(query: query, triggerLength: 1 + query.count)
    }

    private static func isValidKeywordCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isNewline
    }
}
