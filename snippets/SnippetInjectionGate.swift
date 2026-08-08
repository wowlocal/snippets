import Foundation

/// Why an expansion cannot start or continue.
nonisolated enum SnippetInjectionRefusal: Equatable {
    case secureEventInput
    case secureSnippetRequiresAuthentication
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
        isSecureSnippet: Bool,
        secureSnippetIsAuthenticated: Bool,
        isListening: Bool,
        ownAppIsFrontmost: Bool,
        deleteCount: Int
    ) -> SnippetInjectionRefusal? {
        if secureEventInputEnabled { return .secureEventInput }
        if isSecureSnippet && !secureSnippetIsAuthenticated {
            return .secureSnippetRequiresAuthentication
        }
        if !isListening { return .notListening }
        if ownAppIsFrontmost { return .ownAppIsFrontmost }
        if deleteCount <= 0 { return .nothingToDelete }
        return nil
    }

    /// App activation normally invalidates the caret/trigger snapshot. The one
    /// exception is an authentication flow we initiated ourselves: LocalAuthentication
    /// can briefly activate Snippets or a system UI process and enable Secure Event
    /// Input before returning to the original target.
    nonisolated static func applicationActivationInvalidatesContext(
        activatedPID: Int32?,
        ownPID: Int32,
        secureAuthenticationTargetPID: Int32?,
        secureExpansionTargetPID: Int32? = nil,
        secureEventInputEnabled: Bool
    ) -> Bool {
        // LocalAuthentication may activate an implementation-detail system process
        // before or after Secure Event Input flips, so no PID whitelist is complete.
        // Mouse/key monitors still invalidate real interaction, and the authenticated
        // path restores the original app and re-reads the exact trigger before writing.
        if secureAuthenticationTargetPID != nil { return false }

        // NSWorkspace can deliver the target's activation notification after
        // LocalAuthentication has returned and the insertion has already been queued.
        // That delayed notification confirms the target we just revalidated; it is not
        // a new app switch and must not cancel the queued insertion.
        if let secureExpansionTargetPID, activatedPID == secureExpansionTargetPID {
            return false
        }

        // Outside our own prompt, Secure Event Input must tear down the tracked
        // context because no subsequent key event may arrive to do it for us.
        if secureEventInputEnabled { return true }
        if activatedPID == ownPID { return false }
        return true
    }

    /// Synthetic wins over secure input: our own tagged event must be ignored outright, not treated
    /// as user typing that clears the buffer.
    nonisolated static func inputDisposition(
        origin: SnippetSyntheticEvent.Origin,
        secureEventInputEnabled: Bool,
        isListening: Bool,
        isInjecting: Bool,
        ownAppIsFrontmost: Bool,
        isAuthenticatingSecureSuggestion: Bool = false
    ) -> SnippetInputDisposition {
        if origin == .selfInjected { return .ignore }
        // Password fallback is typed into LocalAuthentication's own secure UI, not
        // into the target whose trigger we saved. Pass those events through without
        // teaching the matcher the password or invalidating that saved trigger. The
        // authenticated path restores the target and re-reads the exact trigger before
        // it is allowed to delete anything.
        if isAuthenticatingSecureSuggestion { return .ignore }
        if secureEventInputEnabled { return .resetAndPassThrough }
        if !isListening { return .ignore }
        if isInjecting { return .ignore }
        if ownAppIsFrontmost { return .resetAndPassThrough }
        return .process
    }

    /// Clicking "Use Password" or the password field belongs to the same system
    /// authentication flow as its keystrokes. Outside that narrowly-scoped flow, a
    /// global click still invalidates the caret snapshot immediately.
    nonisolated static func pointerInteractionInvalidatesContext(
        secureAuthenticationTargetPID: Int32?
    ) -> Bool {
        secureAuthenticationTargetPID == nil
    }
}
