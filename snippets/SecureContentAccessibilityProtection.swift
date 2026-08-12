import AppKit

/// Registers and applies AppKit's protected-content accessibility contract for
/// plaintext that came from the vault.
///
/// `NSAccessibility.setMayContainProtectedContent(_:)` is an application-wide
/// prerequisite: without it, AppKit ignores the per-element
/// `accessibilityProtectedContent` attribute. Registration is therefore a
/// fail-closed prerequisite for putting secure plaintext in any view. AppKit,
/// rather than this app, filters protected content for non-system accessibility
/// clients; keeping the normal accessibility value intact preserves VoiceOver.
@MainActor
final class SecureContentAccessibilityProtection {
    enum Availability: Equatable {
        case notRegistered
        case available
        case unavailable
    }

    typealias Registrar = (_ mayContainProtectedContent: Bool) -> Bool

    private let registrar: Registrar
    private(set) var availability: Availability = .notRegistered

    init(
        registrar: @escaping Registrar = { mayContainProtectedContent in
            NSAccessibility.setMayContainProtectedContent(mayContainProtectedContent)
        }
    ) {
        self.registrar = registrar
    }

    /// Called once during application launch, before secure plaintext can be
    /// presented. A failed registration remains sticky for this process: a
    /// later reveal must not silently proceed without the system contract.
    @discardableResult
    func registerApplication() -> Bool {
        switch availability {
        case .available:
            return true
        case .unavailable:
            return false
        case .notRegistered:
            let succeeded = registrar(true)
            availability = succeeded ? .available : .unavailable
            return succeeded
        }
    }

    var canPresentSecurePlaintext: Bool {
        availability == .available
    }

    /// Marks every view that is about to receive secure plaintext. Call this
    /// synchronously before assigning any content. The return value is the
    /// reveal gate; callers must not decrypt or assign plaintext when it is
    /// `false`.
    @discardableResult
    func beginProtecting(_ views: [NSView]) -> Bool {
        guard canPresentSecurePlaintext else { return false }
        for view in views {
            view.setAccessibilityProtectedContent(true)
        }
        return true
    }

    /// Removes the per-element declaration. Callers are responsible for first
    /// replacing every secure value in `views`; this API is intentionally
    /// separate from `beginProtecting` so capture/exfiltration defenses can use
    /// the same presentation boundary without reaching into AppKit AX details.
    func endProtecting(_ views: [NSView]) {
        for view in views {
            if let textView = view as? NSTextView {
                assert(textView.string.isEmpty, "Clear secure text before removing AX protection")
            } else if let textField = view as? NSTextField {
                assert(textField.stringValue.isEmpty, "Clear secure text before removing AX protection")
            }
            view.setAccessibilityProtectedContent(false)
        }
    }
}
