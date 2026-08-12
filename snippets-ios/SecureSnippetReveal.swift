import UIKit

enum SecureSnippetRevealSource: Hashable {
    case touchHold
    case hover
}

enum SecureSnippetRevealTransition: Equatable {
    case none
    case reveal
    case redact
}

struct SecureSnippetAuthenticationToken: Equatable {
    fileprivate let bindingGeneration: UInt64
    fileprivate let requestGeneration: UInt64
}

/// Pure, fail-closed policy for the short interval in which a secure body may be
/// present in UIKit text storage. Authentication is deliberately separate from
/// visual disclosure: a successful prompt only reaches `authenticatedRedacted`.
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
    private var activeSources: Set<SecureSnippetRevealSource> = []

    var isSecure: Bool { state != .ordinary }
    var isProtectedPlaintext: Bool { state == .protectedPlaintext }
    var isAuthenticated: Bool {
        state == .authenticatedRedacted
            || state == .presentingPlaintext
            || state == .protectedPlaintext
    }
    var isAuthenticating: Bool { state == .authenticating }
    var isCaptureBlocked: Bool { isSecure && !sceneCaptureIsInactive }
    var hasContinuousRevealSource: Bool { !activeSources.isEmpty }
    var permitsTextMutation: Bool {
        state == .protectedPlaintext
            && !activeSources.isEmpty
            && appAndSceneAreActive
            && sceneCaptureIsInactive
            && rendererIsHealthy
    }

    mutating func bindOrdinary() {
        bindingGeneration &+= 1
        authenticationRequestGeneration &+= 1
        activeSources.removeAll()
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
        activeSources.removeAll()
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
        // Never inherit a touch or hover that began before authentication ended.
        activeSources.removeAll()
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
        activeSources.removeAll()
        state = .locked
        return true
    }

    mutating func begin(source: SecureSnippetRevealSource) -> SecureSnippetRevealTransition {
        guard state == .authenticatedRedacted
                || state == .presentingPlaintext
                || state == .protectedPlaintext else {
            return .none
        }
        activeSources.insert(source)
        guard state == .authenticatedRedacted,
              environmentPermitsReveal else { return .none }
        return .reveal
    }

    mutating func end(source: SecureSnippetRevealSource) -> SecureSnippetRevealTransition {
        activeSources.remove(source)
        guard (state == .presentingPlaintext || state == .protectedPlaintext),
              activeSources.isEmpty else { return .none }
        state = .authenticatedRedacted
        return .redact
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
        activeSources.removeAll()
        guard state != .ordinary, state != .failedClosed else { return }
        state = vaultIsStillUnlocked ? .authenticatedRedacted : .locked
    }

    mutating func setAppAndSceneAreActive(_ active: Bool) -> SecureSnippetRevealTransition {
        appAndSceneAreActive = active
        guard !active else { return .none }
        activeSources.removeAll()
        return transitionProtectedPlaintextToRedacted()
    }

    mutating func setSceneCaptureIsInactive(_ inactive: Bool) -> SecureSnippetRevealTransition {
        sceneCaptureIsInactive = inactive
        guard !inactive else { return .none }
        activeSources.removeAll()
        return transitionProtectedPlaintextToRedacted()
    }

    mutating func cancelContinuousReveal() -> SecureSnippetRevealTransition {
        activeSources.removeAll()
        return transitionProtectedPlaintextToRedacted()
    }

    mutating func rendererFailed() -> SecureSnippetRevealTransition {
        guard state != .ordinary else { return .none }
        let needsRedaction = state == .presentingPlaintext || state == .protectedPlaintext
        activeSources.removeAll()
        rendererIsHealthy = false
        state = .failedClosed
        return needsRedaction ? .redact : .none
    }

    mutating func lock() -> SecureSnippetRevealTransition {
        guard state != .ordinary else { return .none }
        let needsRedaction = state == .presentingPlaintext || state == .protectedPlaintext
        bindingGeneration &+= 1
        authenticationRequestGeneration &+= 1
        activeSources.removeAll()
        state = rendererIsHealthy ? .locked : .failedClosed
        return needsRedaction ? .redact : .none
    }

    private var environmentPermitsReveal: Bool {
        !activeSources.isEmpty
            && appAndSceneAreActive
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

enum SecureSnippetHoverIntent: Equatable {
    case none
    case begin
    case end

    static func resolve(
        gestureState: UIGestureRecognizer.State,
        locationIsInside: Bool
    ) -> Self {
        switch gestureState {
        case .began, .changed:
            locationIsInside ? .begin : .end
        case .ended, .cancelled, .failed:
            .end
        case .possible:
            .none
        @unknown default:
            .end
        }
    }
}

/// Safe-copy overlay used after authentication. Its hold target remains a sibling
/// of the text view, so one finger can maintain disclosure while another positions
/// the caret, types, or scrolls the editor.
final class SecureSnippetRevealOverlayView: UIView {
    enum Presentation: Equatable {
        case hidden
        case authenticatedRedacted
        case protectedPlaintext
        case captureBlocked
        case failedClosed
    }

    let holdButton = UIButton(type: .system)
    var prefersHover = false {
        didSet { applyPresentation() }
    }
    var protectedBackgroundColor: UIColor = .secondarySystemBackground {
        didSet { applyPresentation() }
    }
    var onHoldChanged: ((Bool) -> Void)?

    var presentation: Presentation = .hidden {
        didSet { applyPresentation() }
    }

    private let symbolView = UIImageView()
    private let messageLabel = UILabel()
    private let messageStack = UIStackView()
    private var holdButtonConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard presentation == .protectedPlaintext else {
            return super.hitTest(point, with: event)
        }
        let buttonPoint = holdButton.convert(point, from: self)
        guard holdButton.point(inside: buttonPoint, with: event) else { return nil }
        return holdButton.hitTest(buttonPoint, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard presentation != .hidden else { return false }
        guard presentation != .protectedPlaintext else {
            let buttonPoint = holdButton.convert(point, from: self)
            return holdButton.point(inside: buttonPoint, with: event)
        }
        return super.point(inside: point, with: event)
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

        holdButton.translatesAutoresizingMaskIntoConstraints = false
        holdButton.accessibilityIdentifier = "secure-reveal-hold"
        holdButton.accessibilityLabel = "Hold to reveal and edit secure content"
        holdButton.isExclusiveTouch = false
        holdButton.isMultipleTouchEnabled = true
        holdButton.addTarget(
            self,
            action: #selector(holdBegan),
            for: [.touchDown, .touchDragEnter])
        holdButton.addTarget(
            self,
            action: #selector(holdEnded),
            for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])

        addSubview(messageStack)
        addSubview(holdButton)
        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 22),
            messageStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),
        ])
        holdButtonConstraints = [
            holdButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            holdButton.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            holdButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            holdButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            holdButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            holdButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ]
        NSLayoutConstraint.activate(holdButtonConstraints)
        applyPresentation()
    }

    func detachHoldButtonForParking() {
        NSLayoutConstraint.deactivate(holdButtonConstraints)
        holdButton.removeFromSuperview()
        holdButton.translatesAutoresizingMaskIntoConstraints = true
    }

    func reattachHoldButtonFromParking() {
        guard holdButton.superview !== self else { return }
        holdButton.removeFromSuperview()
        holdButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(holdButton)
        NSLayoutConstraint.activate(holdButtonConstraints)
    }

    var activeHoldButtonConstraintCountForInspection: Int {
        holdButtonConstraints.lazy.filter(\.isActive).count
    }

    private func applyPresentation() {
        isHidden = presentation == .hidden
        guard presentation != .hidden else {
            accessibilityElementsHidden = true
            return
        }
        accessibilityElementsHidden = false

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "eye.fill")
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = AppTheme.tint

        switch presentation {
        case .hidden:
            break
        case .authenticatedRedacted:
            backgroundColor = protectedBackgroundColor
            symbolView.image = UIImage(systemName: "eye")
            messageLabel.text = prefersHover
                ? "Hover over the editor or hold to reveal and edit"
                : "Hold to reveal and edit"
            messageStack.isHidden = false
            holdButton.isHidden = false
            holdButton.isEnabled = true
            configuration.title = "Hold to Reveal"
            holdButton.accessibilityLabel = "Hold to reveal and edit secure content"
            accessibilityViewIsModal = false
        case .protectedPlaintext:
            backgroundColor = .clear
            messageStack.isHidden = true
            holdButton.isHidden = false
            holdButton.isEnabled = true
            configuration.title = prefersHover ? "Move Away to Hide" : "Keep Holding to Reveal"
            holdButton.accessibilityLabel = prefersHover
                ? "Secure content is revealed. Move the pointer away to hide it."
                : "Keep holding to reveal and edit secure content"
            accessibilityViewIsModal = false
        case .captureBlocked:
            backgroundColor = protectedBackgroundColor
            symbolView.image = UIImage(systemName: "record.circle")
            messageLabel.text = "Screen recording detected. Secure content stays hidden."
            messageStack.isHidden = false
            holdButton.isHidden = true
            holdButton.isEnabled = false
            accessibilityViewIsModal = true
        case .failedClosed:
            backgroundColor = protectedBackgroundColor
            symbolView.image = UIImage(systemName: "exclamationmark.shield")
            messageLabel.text = "Protected display unavailable. Secure content stays hidden."
            messageStack.isHidden = false
            holdButton.isHidden = true
            holdButton.isEnabled = false
            accessibilityViewIsModal = true
        }
        holdButton.configuration = configuration
    }

    @objc private func holdBegan() {
        onHoldChanged?(true)
    }

    @objc private func holdEnded() {
        onHoldChanged?(false)
    }
}

/// Window-level host used while a phone hold gesture is active. Only the parked
/// hold control participates in hit testing; every other touch passes through to
/// the editor beneath it so a second finger can position the caret or scroll.
final class SecureHoldParkingView: UIView {
    weak var holdControl: UIView?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let holdControl,
              !holdControl.isHidden,
              holdControl.isUserInteractionEnabled else { return false }
        let controlPoint = holdControl.convert(point, from: self)
        return holdControl.point(inside: controlPoint, with: event)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event), let holdControl else { return nil }
        let controlPoint = holdControl.convert(point, from: self)
        return holdControl.hitTest(controlPoint, with: event)
    }
}
