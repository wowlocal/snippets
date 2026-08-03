import Foundation

/// Why an expansion cannot start or continue.
nonisolated enum SnippetInjectionRefusal: Equatable {
    case secureEventInput
    case notListening
    case ownAppIsFrontmost
    case nothingToDelete
}

/// What to do with an incoming key event.
nonisolated enum SnippetInputDisposition: Equatable {
    case process
    /// Drop tracked state but never suppress the key — the host must still see it.
    case resetAndPassThrough
    case ignore
}

nonisolated enum SnippetInjectionGate {
    /// Evaluated before an expansion starts and again after every suspension point, so a flag that
    /// flips mid-injection cannot leave the host's text half deleted.
    nonisolated static func refusal(
        secureEventInputEnabled: Bool,
        isListening: Bool,
        ownAppIsFrontmost: Bool,
        deleteCount: Int
    ) -> SnippetInjectionRefusal? {
        if secureEventInputEnabled { return .secureEventInput }
        if !isListening { return .notListening }
        if ownAppIsFrontmost { return .ownAppIsFrontmost }
        if deleteCount <= 0 { return .nothingToDelete }
        return nil
    }

    /// Synthetic wins over secure input: our own tagged event must be ignored outright, not treated
    /// as user typing that clears the buffer.
    nonisolated static func inputDisposition(
        origin: SnippetSyntheticEvent.Origin,
        secureEventInputEnabled: Bool,
        isListening: Bool,
        isInjecting: Bool,
        ownAppIsFrontmost: Bool
    ) -> SnippetInputDisposition {
        if origin == .selfInjected { return .ignore }
        if secureEventInputEnabled { return .resetAndPassThrough }
        if !isListening { return .ignore }
        if isInjecting { return .ignore }
        if ownAppIsFrontmost { return .resetAndPassThrough }
        return .process
    }
}
