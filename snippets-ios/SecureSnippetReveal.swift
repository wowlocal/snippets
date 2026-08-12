import UIKit

enum SecureSnippetRevealTransition: Equatable {
    case none
    case reveal
    case redact
}

struct SecureSnippetAuthenticationToken: Equatable {
    fileprivate let bindingGeneration: UInt64
    fileprivate let requestGeneration: UInt64
}

/// Pure, fail-closed policy for an authenticated secure-editor session.
struct SecureSnippetRevealPolicy {
    enum State: Equatable {
        case ordinary
        case locked
        case authenticating
        case authenticatedRedacted
        case presentingPlaintext
        case protectedPlaintext
        case failedClosed
    }

    private(set) var state: State = .ordinary
    private(set) var bindingGeneration: UInt64 = 0
    private(set) var appAndSceneAreActive = false
    private(set) var sceneCaptureIsInactive = false
    private(set) var rendererIsHealthy = false

    private var authenticationRequestGeneration: UInt64 = 0
    var isSecure: Bool { state != .ordinary }
    var isProtectedPlaintext: Bool { state == .protectedPlaintext }
    var isAuthenticated: Bool {
        state == .authenticatedRedacted
            || state == .presentingPlaintext
            || state == .protectedPlaintext
    }
    var isAuthenticating: Bool { state == .authenticating }
    var isCaptureBlocked: Bool { isSecure && !sceneCaptureIsInactive }
    var permitsTextMutation: Bool {
        state == .protectedPlaintext
            && appAndSceneAreActive
            && sceneCaptureIsInactive
            && rendererIsHealthy
    }

    mutating func bindOrdinary() {
        bindingGeneration &+= 1
        authenticationRequestGeneration &+= 1
        rendererIsHealthy = false
        state = .ordinary
    }

    mutating func bindSecure(
        rendererIsHealthy: Bool,
        appAndSceneAreActive: Bool,
        sceneCaptureIsInactive: Bool
    ) {
        bindingGeneration &+= 1
        authenticationRequestGeneration &+= 1
        self.rendererIsHealthy = rendererIsHealthy
        self.appAndSceneAreActive = appAndSceneAreActive
        self.sceneCaptureIsInactive = sceneCaptureIsInactive
        state = rendererIsHealthy ? .locked : .failedClosed
    }

    mutating func beginAuthentication() -> SecureSnippetAuthenticationToken? {
        guard state == .locked else { return nil }
        authenticationRequestGeneration &+= 1
        state = .authenticating
        return SecureSnippetAuthenticationToken(
            bindingGeneration: bindingGeneration,
            requestGeneration: authenticationRequestGeneration)
    }

    @discardableResult
    mutating func authenticationSucceeded(
        token: SecureSnippetAuthenticationToken
    ) -> Bool {
        guard authenticationTokenIsCurrent(token), state == .authenticating else {
            return false
        }
        state = .authenticatedRedacted
        return true
    }

    @discardableResult
    mutating func authenticationFailed(
        token: SecureSnippetAuthenticationToken
    ) -> Bool {
        guard authenticationTokenIsCurrent(token), state == .authenticating else {
            return false
        }
        state = .locked
        return true
    }

    mutating func beginAuthenticatedReveal() -> SecureSnippetRevealTransition {
        guard state == .authenticatedRedacted, environmentPermitsReveal else { return .none }
        return .reveal
    }

    /// Called after plaintext has entered protected text storage and its AV
    /// presentation was scheduled, but before those pixels can become visible.
    @discardableResult
    mutating func beginPlaintextPresentation() -> Bool {
        guard state == .authenticatedRedacted, environmentPermitsReveal else {
            return false
        }
        state = .presentingPlaintext
        return true
    }

    /// Called only from the renderer's generation-guarded presentation callback.
    @discardableResult
    mutating func confirmProtectedPlaintext() -> Bool {
        guard state == .presentingPlaintext, environmentPermitsReveal else {
            return false
        }
        state = .protectedPlaintext
        return true
    }

    mutating func revealAttemptFailed(vaultIsStillUnlocked: Bool) {
        guard state != .ordinary, state != .failedClosed else { return }
        state = .locked
    }

    mutating func setAppAndSceneAreActive(_ active: Bool) -> SecureSnippetRevealTransition {
        appAndSceneAreActive = active
        guard !active else { return .none }
        return transitionProtectedPlaintextToRedacted()
    }

    mutating func setSceneCaptureIsInactive(_ inactive: Bool) -> SecureSnippetRevealTransition {
        sceneCaptureIsInactive = inactive
        guard !inactive else { return .none }
        return transitionProtectedPlaintextToRedacted()
    }

    mutating func cancelReveal() -> SecureSnippetRevealTransition {
        return transitionProtectedPlaintextToRedacted()
    }

    mutating func rendererFailed() -> SecureSnippetRevealTransition {
        guard state != .ordinary else { return .none }
        let needsRedaction = state == .presentingPlaintext || state == .protectedPlaintext
        rendererIsHealthy = false
        state = .failedClosed
        return needsRedaction ? .redact : .none
    }

    mutating func lock() -> SecureSnippetRevealTransition {
        guard state != .ordinary else { return .none }
        let needsRedaction = state == .presentingPlaintext || state == .protectedPlaintext
        bindingGeneration &+= 1
        authenticationRequestGeneration &+= 1
        state = rendererIsHealthy ? .locked : .failedClosed
        return needsRedaction ? .redact : .none
    }

    private var environmentPermitsReveal: Bool {
        appAndSceneAreActive
            && sceneCaptureIsInactive
            && rendererIsHealthy
    }

    private func authenticationTokenIsCurrent(
        _ token: SecureSnippetAuthenticationToken
    ) -> Bool {
        token.bindingGeneration == bindingGeneration
            && token.requestGeneration == authenticationRequestGeneration
    }

    private mutating func transitionProtectedPlaintextToRedacted()
        -> SecureSnippetRevealTransition {
        guard state == .presentingPlaintext || state == .protectedPlaintext else {
            return .none
        }
        state = .authenticatedRedacted
        return .redact
    }
}

extension SecureSnippetRevealPolicy.State {
    var diagnosticState: DiagnosticSecureEditorState {
        switch self {
        case .ordinary: .ordinary
        case .locked: .locked
        case .authenticating: .authenticating
        case .authenticatedRedacted: .authenticatedRedacted
        case .presentingPlaintext: .presentingPlaintext
        case .protectedPlaintext: .protectedPlaintext
        case .failedClosed: .failedClosed
        }
    }
}

extension VaultSession.State {
    var diagnosticState: DiagnosticVaultState {
        switch self {
        case .noKey: .noKey
        case .locked: .locked
        case .unlocked: .unlocked
        }
    }
}

extension DiagnosticSecureEditorReason {
    static func storeRefresh(_ source: SnippetStore.ChangeSource) -> Self {
        switch source {
        case .local: .storeRefreshLocal
        case .external: .storeRefreshExternal
        case .remoteSync: .storeRefreshRemoteSync
        }
    }
}

/// Records only semantic policy changes. Renderer refresh callbacks can occur for every
/// edit, selection, scroll, or layout pass; omitting no-op transitions keeps this event
/// useful without turning protected text interaction into a hot logging loop.
@MainActor
@discardableResult
func updateSecureRevealPolicy<Result>(
    _ policy: inout SecureSnippetRevealPolicy,
    surface: DiagnosticSecureEditorSurface,
    reason: DiagnosticSecureEditorReason,
    vaultState: DiagnosticVaultState,
    _ update: (inout SecureSnippetRevealPolicy) -> Result
) -> Result {
    let from = policy.state.diagnosticState
    let result = update(&policy)
    let to = policy.state.diagnosticState
    if from != to {
        Diagnostics.record(.secureEditorTransition(
            surface: surface,
            from: from,
            to: to,
            reason: reason,
            vaultState: vaultState))
    }
    return result
}

/// Fail-closed status overlay shown only when protected display is unavailable.
final class SecureSnippetRevealOverlayView: UIView {
    enum Presentation: Equatable {
        case hidden
        case captureBlocked
        case failedClosed
    }

    var protectedBackgroundColor: UIColor = .secondarySystemBackground {
        didSet { applyPresentation() }
    }

    var presentation: Presentation = .hidden {
        didSet { applyPresentation() }
    }

    private let symbolView = UIImageView()
    private let messageLabel = UILabel()
    private let messageStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        presentation != .hidden && super.point(inside: point, with: event)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "secure-reveal-overlay"
        isAccessibilityElement = false

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.tintColor = .secondaryLabel
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 28,
            weight: .medium)
        symbolView.isAccessibilityElement = false

        messageLabel.font = AppTheme.scaledFont(
            size: 15,
            weight: .semibold,
            textStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.isAccessibilityElement = false

        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.axis = .vertical
        messageStack.alignment = .center
        messageStack.spacing = 10
        messageStack.addArrangedSubview(symbolView)
        messageStack.addArrangedSubview(messageLabel)

        addSubview(messageStack)
        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 22),
            messageStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),
        ])
        applyPresentation()
    }

    private func applyPresentation() {
        isHidden = presentation == .hidden
        guard presentation != .hidden else {
            accessibilityElementsHidden = true
            return
        }
        accessibilityElementsHidden = false

        switch presentation {
        case .hidden:
            break
        case .captureBlocked:
            backgroundColor = protectedBackgroundColor
            symbolView.image = UIImage(systemName: "record.circle")
            messageLabel.text = "Screen recording detected. Secure content stays hidden."
            messageStack.isHidden = false
            accessibilityViewIsModal = true
        case .failedClosed:
            backgroundColor = protectedBackgroundColor
            symbolView.image = UIImage(systemName: "exclamationmark.shield")
            messageLabel.text = "Protected display unavailable. Secure content stays hidden."
            messageStack.isHidden = false
            accessibilityViewIsModal = true
        }
    }
}
