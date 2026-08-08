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
