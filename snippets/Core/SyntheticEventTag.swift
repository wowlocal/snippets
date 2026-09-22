import Foundation

/// Marker Snippets writes into `kCGEventSourceUserData` on every CGEvent it posts, so the
/// expansion tap can tell its own injection apart from real typing without a timing heuristic.
nonisolated enum SnippetSyntheticEvent {
    /// ASCII "SNPTEXPD". Real keystrokes carry 0 here, so any nonzero constant works; eight
    /// app-specific bytes keep us clear of the small values other automation tools plausibly use.
    static let tag: Int64 = 0x534E_5054_4558_5044

    enum Origin: Equatable {
        case user
        case selfInjected
    }

    /// A missing field means the event did not come from CoreGraphics, which our own posts always
    /// do — treating it as user input fails open, and losing real keystrokes is the worse error.
    nonisolated static func origin(eventUserData: Int64?) -> Origin {
        guard let eventUserData else { return .user }
        return eventUserData == tag ? .selfInjected : .user
    }
}

/// Once a suggestion accepts a keystroke, it owns that key's repeats and release. The
/// state deliberately outlives insertion: a held Tab must not begin moving focus merely
/// because a fast insertion or authentication has finished.
///
/// The event tap arms this only after accepting a suggestion, consults it before interpreting
/// user input, and resets it when monitoring stops or restarts. It must not be reset by normal
/// suggestion dismissal, Secure Input, authentication, or insertion completion: these can
/// precede the physical key-up. If a secure surface hides that release from the tap, a new
/// non-repeating down discards stale ownership rather than swallowing the next press.
nonisolated struct SnippetSuggestionAcceptanceKeys {
    enum Phase {
        case keyDown
        case keyUp
    }

    private enum Key: UInt16 {
        case returnKey = 36
        case tab = 48
        case keypadEnter = 76
    }

    private var heldKeys: Set<UInt16> = []

    /// Called only for a key-down the suggestion handler actually accepted and suppressed.
    /// Keeping the accepted identities closed prevents unrelated shortcuts from acquiring
    /// accidental key-up suppression.
    @discardableResult
    mutating func recordAcceptedKeyDown(keyCode: UInt16) -> Bool {
        guard Key(rawValue: keyCode) != nil else { return false }
        heldKeys.insert(keyCode)
        return true
    }

    mutating func consume(
        keyCode: UInt16,
        phase: Phase,
        origin: SnippetSyntheticEvent.Origin,
        isAutorepeat: Bool = false,
        keyIsDownInHIDState: Bool = false
    ) -> Bool {
        // Our injected key-up cannot stand in for the user's physical release, and our
        // injected events must always reach their target.
        guard origin == .user, heldKeys.contains(keyCode) else { return false }
        switch phase {
        case .keyDown:
            guard isAutorepeat else {
                // A tap can miss a release during Secure Input. There is no reliable way
                // to distinguish the resulting fresh press from another app's replay with
                // its repeat bit cleared; preserve fresh user input in that ambiguity.
                heldKeys.remove(keyCode)
                return false
            }
        case .keyUp:
            // An unmarked release is not necessarily a physical release. The HID state
            // observation can keep a replay from releasing an accepted, still-held key.
            // This is not an authenticity check and never overrides a fresh key-down.
            if !keyIsDownInHIDState {
                heldKeys.remove(keyCode)
            }
        }
        return true
    }

    mutating func reset() {
        heldKeys.removeAll()
    }
}
