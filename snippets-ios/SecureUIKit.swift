import UIKit
import UniformTypeIdentifiers

enum SecureSnippetCapturePhase: Equatable {
    case ordinary
    case protectedRedaction
    case protectedPlaintext
    case failedClosed

    var suppressesUIKitDrawing: Bool { self != .ordinary }
    var keepsProtectedSurfaceVisible: Bool {
        self == .protectedRedaction || self == .protectedPlaintext || self == .failedClosed
    }
}

enum SecureSnippetForcedRedactionReason: Equatable {
    case sceneCapture
    case rendererFailure
}

/// A text view that removes UIKit's ambient disclosure routes while a secure snippet
/// is revealed. Copying a secure snippet remains an explicit app action backed by
/// `SnippetActionService`, which authenticates and uses an expiring local pasteboard.
final class SecureSnippetTextView: UITextView {
    let secureCaptureSurfaceView = SecureSnippetCaptureSurfaceView()

    var isSecureContentMode = false {
        didSet {
            guard oldValue != isSecureContentMode else { return }
            applyContentMode()
        }
    }

    /// Called after protected pixels have been synchronously redacted and the
    /// text storage has been cleared. Plaintext is supplied only if the view held
    /// a revealed secure body, so the owner can persist it without rereading the
    /// now-empty UITextView.
    var onSecureCaptureForcedRedaction: ((String?, SecureSnippetForcedRedactionReason) -> Void)?

    var secureCaptureBackgroundColor: UIColor = .secondarySystemBackground {
        didSet { invalidateSecureCaptureRenderer() }
    }

    private(set) var secureCapturePhase: SecureSnippetCapturePhase = .ordinary
    private var securePlaintextIsLoaded = false
    private var isChangingSecureStorage = false
    private var savedNativeLayerOpacity: Float?
    private var savedTintColor: UIColor?
    private var sceneCaptureStateOverrideForTesting: UISceneCaptureState?
    private var sceneCaptureTraitRegistration: (any UITraitChangeRegistration)?
    private lazy var secureCaptureRenderer: SecureSnippetCaptureRenderer = {
        let renderer = SecureSnippetCaptureRenderer(
            textView: self,
            surfaceView: secureCaptureSurfaceView
        )
        renderer.onFailure = { [weak self] in self?.secureCaptureRendererDidFail() }
        return renderer
    }()

    var secureCaptureCaretColor: UIColor { savedTintColor ?? .systemBlue }

    private static let secureAllowedActions: Set<String> = [
        "delete:",
        "paste:",
        "select:",
        "selectAll:",
    ]
    private weak var undoManagerWithDisabledRegistration: UndoManager?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        commonSecureInitialization()
        smartDashesType = .no
        smartQuotesType = .no
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonSecureInitialization()
        smartDashesType = .no
        smartQuotesType = .no
    }

    private func commonSecureInitialization() {
        secureCaptureSurfaceView.isHidden = true
        secureCaptureSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        sceneCaptureTraitRegistration = registerForTraitChanges(
            [UITraitSceneCaptureState.self]
        ) { (view: SecureSnippetTextView, _) in
            view.reevaluateSceneCaptureState()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard isSecureContentMode else {
            return super.canPerformAction(action, withSender: sender)
        }
        let name = NSStringFromSelector(action)
        guard Self.secureAllowedActions.contains(name) else { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.cut(sender)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The text drag interaction can be installed lazily when the view joins a
        // window, after secure mode was first selected.
        if isSecureContentMode { applyContentMode() }
        reevaluateSceneCaptureState()
        invalidateSecureCaptureRenderer()
    }

    override func draw(_ rect: CGRect) {
        guard !isSecureContentMode,
              !secureCapturePhase.suppressesUIKitDrawing else { return }
        super.draw(rect)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateSecureCaptureRenderer()
    }

    override var text: String! {
        didSet {
            guard !isChangingSecureStorage else { return }
            invalidateSecureCaptureRenderer()
        }
    }

    override var attributedText: NSAttributedString! {
        didSet {
            guard !isChangingSecureStorage else { return }
            invalidateSecureCaptureRenderer()
        }
    }

    override var selectedRange: NSRange {
        didSet { invalidateSecureCaptureRenderer() }
    }

    override var contentOffset: CGPoint {
        didSet { invalidateSecureCaptureRenderer() }
    }

    /// Arms a protected neutral frame before a controller decrypts or assigns a
    /// secure body. Native UITextView compositing is suppressed synchronously.
    @discardableResult
    func bindSecureRedacted() -> Bool {
        suppressNativePresentation()
        isSecureContentMode = true
        secureCapturePhase = .protectedRedaction
        securePlaintextIsLoaded = false

        guard secureCaptureRenderer.arm() else { return false }
        replaceTextStorage(with: "")
        return true
    }

    /// Restores ordinary UIKit drawing only after old secure storage and every
    /// protected frame have been removed.
    func bindOrdinaryText(_ ordinaryText: String) {
        suppressNativePresentation()
        if secureCapturePhase == .protectedPlaintext {
            _ = secureCaptureRenderer.renderRedaction()
        }
        replaceTextStorage(with: "")
        securePlaintextIsLoaded = false
        secureCaptureRenderer.clear(keepFallbackVisible: false)
        secureCapturePhase = .ordinary
        isSecureContentMode = false
        restoreNativePresentation()
        replaceTextStorage(with: ordinaryText)
        setNeedsDisplay()
    }

    /// Plaintext may enter UITextView storage only in an inactive scene with a
    /// healthy, already-attached protected renderer.
    var canAcceptSecurePlaintext: Bool {
        secureCapturePhase == .protectedRedaction
            && currentSceneCaptureState == .inactive
            && secureCaptureRenderer.captureProtectionEnabledForInspection
            && secureCaptureRenderer.displayLayerIsAttachedForInspection
    }

    @discardableResult
    func displaySecurePlaintext(_ plaintext: String) -> Bool {
        guard canAcceptSecurePlaintext else { return false }
        replaceTextStorage(with: plaintext)
        securePlaintextIsLoaded = true
        secureCapturePhase = .protectedPlaintext
        guard secureCaptureRenderer.renderPlaintext() else { return false }
        return secureCapturePhase == .protectedPlaintext
    }

    /// Redacts and clears a revealed body. `notifyOwner` is false when the owner
    /// has already persisted it, such as the vault-will-lock path.
    func redactAndClearSecurePlaintext(notifyOwner: Bool = false) {
        guard isSecureContentMode else { return }
        let plaintext = securePlaintextIsLoaded ? (text ?? "") : nil
        if secureCapturePhase == .protectedPlaintext {
            guard secureCaptureRenderer.renderRedaction() else { return }
        }
        secureCapturePhase = .protectedRedaction
        securePlaintextIsLoaded = false
        replaceTextStorage(with: "")
        if notifyOwner, let plaintext {
            onSecureCaptureForcedRedaction?(plaintext, .sceneCapture)
        }
    }

    func invalidateSecureCaptureRenderer() {
        guard !isChangingSecureStorage else { return }
        switch secureCapturePhase {
        case .protectedPlaintext:
            secureCaptureRenderer.invalidate(plaintext: true)
        case .protectedRedaction:
            secureCaptureRenderer.invalidate(plaintext: false)
        case .ordinary, .failedClosed:
            break
        }
    }

    func secureSelectionDidChange() {
        invalidateSecureCaptureRenderer()
    }

    func secureCaptureSurfaceDidLayout() {
        invalidateSecureCaptureRenderer()
    }

    func setSceneCaptureStateForTesting(_ state: UISceneCaptureState?) {
        sceneCaptureStateOverrideForTesting = state
        reevaluateSceneCaptureState()
    }

    func renderSecureFrameForInspection(
        plaintext: Bool
    ) -> SecureSnippetCaptureRenderer.RenderedFrameInspection? {
        secureCaptureRenderer.renderFrameForInspection(plaintext: plaintext)
    }

    var secureCaptureProtectionEnabledForInspection: Bool {
        secureCaptureRenderer.captureProtectionEnabledForInspection
    }

    var secureCaptureLayerAttachedForInspection: Bool {
        secureCaptureRenderer.displayLayerIsAttachedForInspection
    }

    var secureCapturePreventsDisplaySleepForInspection: Bool {
        secureCaptureRenderer.preventsDisplaySleepForInspection
    }

    var nativePlaintextLayerSuppressedForInspection: Bool {
        layer.opacity == 0 && secureCapturePhase.suppressesUIKitDrawing
    }

    private var currentSceneCaptureState: UISceneCaptureState {
        sceneCaptureStateOverrideForTesting ?? traitCollection.sceneCaptureState
    }

    private func reevaluateSceneCaptureState() {
        guard secureCapturePhase == .protectedPlaintext,
              currentSceneCaptureState != .inactive else { return }
        let plaintext = securePlaintextIsLoaded ? (text ?? "") : nil
        guard secureCaptureRenderer.renderRedaction() else { return }
        secureCapturePhase = .protectedRedaction
        securePlaintextIsLoaded = false
        replaceTextStorage(with: "")
        onSecureCaptureForcedRedaction?(plaintext, .sceneCapture)
    }

    private func secureCaptureRendererDidFail() {
        guard secureCapturePhase != .failedClosed else { return }
        let plaintext = securePlaintextIsLoaded ? (text ?? "") : nil
        secureCapturePhase = .failedClosed
        securePlaintextIsLoaded = false
        replaceTextStorage(with: "")
        onSecureCaptureForcedRedaction?(plaintext, .rendererFailure)
    }

    private func replaceTextStorage(with value: String) {
        isChangingSecureStorage = true
        text = value
        isChangingSecureStorage = false
    }

    private func suppressNativePresentation() {
        if savedNativeLayerOpacity == nil { savedNativeLayerOpacity = layer.opacity }
        if savedTintColor == nil { savedTintColor = tintColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
        tintColor = .clear
        setNeedsDisplay()
        layer.displayIfNeeded()
    }

    private func restoreNativePresentation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = savedNativeLayerOpacity ?? 1
        CATransaction.commit()
        savedNativeLayerOpacity = nil
        tintColor = savedTintColor ?? .systemBlue
        savedTintColor = nil
    }

    private func applyContentMode() {
        if isSecureContentMode {
            autocapitalizationType = .none
            autocorrectionType = .no
            spellCheckingType = .no
            textContentType = .password
            smartInsertDeleteType = .no
            smartDashesType = .no
            smartQuotesType = .no
            writingToolsBehavior = .none
            isFindInteractionEnabled = false
            allowsEditingTextAttributes = false
            textDragInteraction?.isEnabled = false
            if undoManagerWithDisabledRegistration == nil,
               let manager = undoManager {
                manager.removeAllActions()
                manager.disableUndoRegistration()
                undoManagerWithDisabledRegistration = manager
            }
        } else {
            autocapitalizationType = .sentences
            autocorrectionType = .default
            spellCheckingType = .default
            textContentType = nil
            smartInsertDeleteType = .default
            writingToolsBehavior = .default
            isFindInteractionEnabled = true
            textDragInteraction?.isEnabled = true
            if let manager = undoManagerWithDisabledRegistration {
                // UITextView can replace its undo manager while the store reloads and
                // the editor rebinds. Balance the manager we actually disabled instead
                // of calling enable on a fresh manager whose disable count is zero.
                if !manager.isUndoRegistrationEnabled {
                    manager.enableUndoRegistration()
                }
                undoManagerWithDisabledRegistration = nil
            }
        }
        if isFirstResponder { reloadInputViews() }
    }
}

enum RecoveryKeyPasteboard {
    static let lifetime: TimeInterval = 5 * 60

    static func options(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [
            .localOnly: true,
            .expirationDate: now.addingTimeInterval(lifetime),
        ]
    }

    static func copy(
        _ recoveryKey: String,
        to pasteboard: UIPasteboard = .general,
        now: Date = Date()
    ) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: recoveryKey]],
            options: options(now: now))
    }
}

enum RecoveryKeyInputProtection {
    static func configure(_ field: UITextField) {
        field.isSecureTextEntry = true
        field.textContentType = .password
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
    }
}
