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
    case presentationRevoked
    case rendererFailure
}

/// A text view that removes UIKit's ambient disclosure routes while a secure snippet
/// is revealed. Copying a secure snippet remains an explicit app action backed by
/// `SnippetActionService`, which authenticates and uses an expiring local pasteboard.
final class SecureSnippetTextView: UITextView {
    let secureCaptureSurfaceView = SecureSnippetCaptureSurfaceView()

    private var secureContentMode = false
    private var ordinaryIsAccessibilityElement = false
    private var ordinaryAccessibilityElementsHidden = false
    private var ordinaryAccessibilityIdentifier: String?

    var isSecureContentMode: Bool {
        get { secureContentMode }
        set {
            guard secureContentMode != newValue else { return }

            if !secureContentMode && newValue {
                ordinaryIsAccessibilityElement = super.isAccessibilityElement
                ordinaryAccessibilityElementsHidden = super.accessibilityElementsHidden
                ordinaryAccessibilityIdentifier = super.accessibilityIdentifier
            }
            if secureContentMode && !newValue {
                // Keep the view outside the accessibility tree until the last secure
                // characters have left UIKit's text storage. This also makes every
                // controller rebind/teardown fail closed if it merely switches modes.
                replaceTextStorage(with: "")
            }
            secureContentMode = newValue
            applyContentMode()
        }
    }

    /// Called after protected pixels have been synchronously redacted and the
    /// text storage has been cleared. Plaintext is supplied only if the view held
    /// a revealed secure body, so the owner can persist it without rereading the
    /// now-empty UITextView.
    var onSecureCaptureForcedRedaction: ((String?, SecureSnippetForcedRedactionReason) -> Void)?
    var onSecureSceneCaptureStateChanged: ((UISceneCaptureState) -> Void)?
    var onSecurePlaintextPresented: (() -> Void)?

    var secureCaptureBackgroundColor: UIColor = .secondarySystemBackground {
        didSet { invalidateSecureCaptureRenderer() }
    }

    private(set) var secureCapturePhase: SecureSnippetCapturePhase = .ordinary
    private var securePlaintextIsLoaded = false
    private var secureEditingIsAuthorized = false
    private var securePlaintextAcceptanceIsAuthorized = false
    private var secureContinuousRevealIsAuthorized = false
    private var isChangingSecureStorage = false
    private var savedNativeLayerOpacity: Float?
    private var savedTintColor: UIColor?
    private var sceneCaptureStateOverrideForTesting: UISceneCaptureState?
    private var foregroundPresentationOverrideForTesting: Bool?
    private var sceneCaptureTraitRegistration: (any UITraitChangeRegistration)?
    private var visualTraitRegistration: (any UITraitChangeRegistration)?
    private lazy var secureCaptureRenderer: SecureSnippetCaptureRenderer = {
        let renderer = SecureSnippetCaptureRenderer(
            textView: self,
            surfaceView: secureCaptureSurfaceView
        )
        renderer.onFailure = { [weak self] in self?.secureCaptureRendererDidFail() }
        renderer.onPlaintextPresented = { [weak self] in
            guard let self else { return }
            self.onSecurePlaintextPresented?()
        }
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
        visualTraitRegistration = registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitDisplayScale.self,
            UITraitPreferredContentSizeCategory.self,
            UITraitAccessibilityContrast.self,
        ]) { (view: SecureSnippetTextView, _) in
            view.invalidateSecureCaptureRenderer()
        }
    }

    // UIKit has no public equivalent of AppKit's protected-content accessibility
    // client filtering. Exclude the complete UITextView subtree and redact every
    // textual accessibility property while secure mode is active. Overriding the
    // accessors prevents a later visual-reveal update from accidentally re-exposing
    // plaintext through VoiceOver, Voice Control, Switch Control, or UI automation.
    override var isAccessibilityElement: Bool {
        get { isSecureContentMode ? false : super.isAccessibilityElement }
        set { super.isAccessibilityElement = isSecureContentMode ? false : newValue }
    }

    override var accessibilityElementsHidden: Bool {
        get { isSecureContentMode ? true : super.accessibilityElementsHidden }
        set { super.accessibilityElementsHidden = isSecureContentMode ? true : newValue }
    }

    override var accessibilityLabel: String? {
        get { isSecureContentMode ? nil : super.accessibilityLabel }
        set { super.accessibilityLabel = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityValue: String? {
        get { isSecureContentMode ? nil : super.accessibilityValue }
        set { super.accessibilityValue = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityHint: String? {
        get { isSecureContentMode ? nil : super.accessibilityHint }
        set { super.accessibilityHint = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityIdentifier: String? {
        get { isSecureContentMode ? nil : super.accessibilityIdentifier }
        set { super.accessibilityIdentifier = isSecureContentMode ? nil : newValue }
    }

    override var isAccessibilityElementBlock: AXBoolReturnBlock? {
        get { isSecureContentMode ? { false } : super.isAccessibilityElementBlock }
        set { super.isAccessibilityElementBlock = isSecureContentMode ? { false } : newValue }
    }

    override var accessibilityLabelBlock: AXStringReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityLabelBlock }
        set { super.accessibilityLabelBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityValueBlock: AXStringReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityValueBlock }
        set { super.accessibilityValueBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityHintBlock: AXStringReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityHintBlock }
        set { super.accessibilityHintBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityIdentifierBlock: AXStringReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityIdentifierBlock }
        set { super.accessibilityIdentifierBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityAttributedLabelBlock: AXAttributedStringReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityAttributedLabelBlock }
        set { super.accessibilityAttributedLabelBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityAttributedValueBlock: AXAttributedStringReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityAttributedValueBlock }
        set { super.accessibilityAttributedValueBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityAttributedHintBlock: AXAttributedStringReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityAttributedHintBlock }
        set { super.accessibilityAttributedHintBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityTextualContextBlock: AXTextualContextReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityTextualContextBlock }
        set { super.accessibilityTextualContextBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityUserInputLabelsBlock: AXStringArrayReturnBlock? {
        get { isSecureContentMode ? { [] } : super.accessibilityUserInputLabelsBlock }
        set { super.accessibilityUserInputLabelsBlock = isSecureContentMode ? { [] } : newValue }
    }

    override var accessibilityAttributedUserInputLabelsBlock: AXAttributedStringArrayReturnBlock? {
        get { isSecureContentMode ? { [] } : super.accessibilityAttributedUserInputLabelsBlock }
        set {
            super.accessibilityAttributedUserInputLabelsBlock = isSecureContentMode ? { [] } : newValue
        }
    }

    override var accessibilityElementsHiddenBlock: AXBoolReturnBlock? {
        get { isSecureContentMode ? { true } : super.accessibilityElementsHiddenBlock }
        set { super.accessibilityElementsHiddenBlock = isSecureContentMode ? { true } : newValue }
    }

    override var accessibilityElementsBlock: AXArrayReturnBlock? {
        get { isSecureContentMode ? { [] } : super.accessibilityElementsBlock }
        set { super.accessibilityElementsBlock = isSecureContentMode ? { [] } : newValue }
    }

    override var automationElementsBlock: AXArrayReturnBlock? {
        get { isSecureContentMode ? { [] } : super.automationElementsBlock }
        set { super.automationElementsBlock = isSecureContentMode ? { [] } : newValue }
    }

    override var accessibilityPreviousTextNavigationElement: Any? {
        get { isSecureContentMode ? nil : super.accessibilityPreviousTextNavigationElement }
        set { super.accessibilityPreviousTextNavigationElement = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityNextTextNavigationElement: Any? {
        get { isSecureContentMode ? nil : super.accessibilityNextTextNavigationElement }
        set { super.accessibilityNextTextNavigationElement = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityPreviousTextNavigationElementBlock: AXObjectReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityPreviousTextNavigationElementBlock }
        set { super.accessibilityPreviousTextNavigationElementBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityNextTextNavigationElementBlock: AXObjectReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityNextTextNavigationElementBlock }
        set { super.accessibilityNextTextNavigationElementBlock = isSecureContentMode ? { nil } : newValue }
    }

    override var accessibilityTextInputResponder: (any UITextInput)? {
        get { isSecureContentMode ? nil : super.accessibilityTextInputResponder }
        set { super.accessibilityTextInputResponder = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityTextInputResponderBlock: AXUITextInputReturnBlock? {
        get { isSecureContentMode ? { nil } : super.accessibilityTextInputResponderBlock }
        set { super.accessibilityTextInputResponderBlock = isSecureContentMode ? { nil } : newValue }
    }

    override func accessibilityHitTest(_ point: CGPoint, event: UIEvent?) -> Any? {
        guard !isSecureContentMode else { return nil }
        return super.accessibilityHitTest(point, event: event)
    }

    override func accessibilityElementCount() -> Int {
        isSecureContentMode ? 0 : super.accessibilityElementCount()
    }

    override func accessibilityElement(at index: Int) -> Any? {
        guard !isSecureContentMode else { return nil }
        return super.accessibilityElement(at: index)
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard !isSecureContentMode else { return NSNotFound }
        return super.index(ofAccessibilityElement: element)
    }

    override var accessibilityElements: [Any]? {
        get { isSecureContentMode ? [] : super.accessibilityElements }
        set { super.accessibilityElements = isSecureContentMode ? [] : newValue }
    }

    override var automationElements: [Any]? {
        get { isSecureContentMode ? [] : super.automationElements }
        set { super.automationElements = isSecureContentMode ? [] : newValue }
    }

    override var accessibilityAttributedLabel: NSAttributedString? {
        get { isSecureContentMode ? nil : super.accessibilityAttributedLabel }
        set { super.accessibilityAttributedLabel = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityAttributedValue: NSAttributedString? {
        get { isSecureContentMode ? nil : super.accessibilityAttributedValue }
        set { super.accessibilityAttributedValue = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityAttributedHint: NSAttributedString? {
        get { isSecureContentMode ? nil : super.accessibilityAttributedHint }
        set { super.accessibilityAttributedHint = isSecureContentMode ? nil : newValue }
    }

    override var accessibilityUserInputLabels: [String]? {
        get { isSecureContentMode ? [] : super.accessibilityUserInputLabels }
        set { super.accessibilityUserInputLabels = isSecureContentMode ? [] : newValue }
    }

    override var accessibilityAttributedUserInputLabels: [NSAttributedString]? {
        get { isSecureContentMode ? [] : super.accessibilityAttributedUserInputLabels }
        set {
            super.accessibilityAttributedUserInputLabels = isSecureContentMode ? [] : newValue
        }
    }

    override var accessibilityTextualContext: UIAccessibilityTextualContext? {
        get { isSecureContentMode ? nil : super.accessibilityTextualContext }
        set { super.accessibilityTextualContext = isSecureContentMode ? nil : newValue }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard isSecureContentMode else {
            return super.canPerformAction(action, withSender: sender)
        }
        guard permitsSecureTextMutation else { return false }
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

    override func paste(_ sender: Any?) {
        guard permitsSecureTextMutation else { return }
        super.paste(sender)
    }

    override func delete(_ sender: Any?) {
        guard permitsSecureTextMutation else { return }
        super.delete(sender)
    }

    override func insertText(_ text: String) {
        guard permitsSecureTextMutation else { return }
        super.insertText(text)
    }

    override func deleteBackward() {
        guard permitsSecureTextMutation else { return }
        super.deleteBackward()
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard permitsSecureTextMutation else { return }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    override func replace(_ range: UITextRange, withText text: String) {
        guard permitsSecureTextMutation else { return }
        super.replace(range, withText: text)
    }

    override func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        guard permitsSecureTextMutation else { return }
        super.insertDictationResult(dictationResult)
    }

    override func insertText(
        _ text: String,
        alternatives: [String],
        style: UITextAlternativeStyle
    ) {
        guard permitsSecureTextMutation else { return }
        super.insertText(text, alternatives: alternatives, style: style)
    }

    override func setAttributedMarkedText(
        _ markedText: NSAttributedString?,
        selectedRange: NSRange
    ) {
        guard permitsSecureTextMutation else { return }
        super.setAttributedMarkedText(markedText, selectedRange: selectedRange)
    }

    override func insertAttributedText(_ string: NSAttributedString) {
        guard permitsSecureTextMutation else { return }
        super.insertAttributedText(string)
    }

    override func replace(
        _ range: UITextRange,
        withAttributedText attributedText: NSAttributedString
    ) {
        guard permitsSecureTextMutation else { return }
        super.replace(range, withAttributedText: attributedText)
    }

    override func insertTextPlaceholder(with size: CGSize) -> UITextPlaceholder {
        // There is no nullable result. When secure mutation is paused, create the
        // framework placeholder and immediately remove it before returning the
        // now-inert token so no placeholder reaches text storage.
        let placeholder = super.insertTextPlaceholder(with: size)
        guard permitsSecureTextMutation else {
            super.remove(placeholder)
            return placeholder
        }
        return placeholder
    }

    override func remove(_ textPlaceholder: UITextPlaceholder) {
        guard permitsSecureTextMutation else { return }
        super.remove(textPlaceholder)
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
            if isSecureContentMode, !permitsSecureTextMutation {
                replaceTextStorage(with: "")
                return
            }
            invalidateSecureCaptureRenderer()
        }
    }

    override var attributedText: NSAttributedString! {
        didSet {
            guard !isChangingSecureStorage else { return }
            if isSecureContentMode, !permitsSecureTextMutation {
                replaceTextStorage(with: "")
                return
            }
            invalidateSecureCaptureRenderer()
        }
    }

    override var selectedRange: NSRange {
        didSet { invalidateSecureCaptureRenderer() }
    }

    override var contentOffset: CGPoint {
        didSet { invalidateSecureCaptureRenderer() }
    }

    override var font: UIFont? {
        didSet { invalidateSecureCaptureRenderer() }
    }

    override var textContainerInset: UIEdgeInsets {
        didSet { invalidateSecureCaptureRenderer() }
    }

    override var typingAttributes: [NSAttributedString.Key: Any] {
        didSet { invalidateSecureCaptureRenderer() }
    }

    /// Arms a protected neutral frame before a controller decrypts or assigns a
    /// secure body. Native UITextView compositing is suppressed synchronously.
    @discardableResult
    func bindSecureRedacted() -> Bool {
        suppressNativePresentation()
        isSecureContentMode = true
        isEditable = false
        secureCapturePhase = .protectedRedaction
        securePlaintextIsLoaded = false
        secureEditingIsAuthorized = false
        securePlaintextAcceptanceIsAuthorized = false
        secureContinuousRevealIsAuthorized = false
        replaceTextStorage(with: "")
        return secureCaptureRenderer.arm()
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
        secureEditingIsAuthorized = false
        securePlaintextAcceptanceIsAuthorized = false
        secureContinuousRevealIsAuthorized = false
        secureCaptureRenderer.clear(keepFallbackVisible: false)
        secureCapturePhase = .ordinary
        isSecureContentMode = false
        isEditable = true
        restoreNativePresentation()
        replaceTextStorage(with: ordinaryText)
        setNeedsDisplay()
    }

    /// Plaintext may enter UITextView storage only in an inactive scene with a
    /// healthy, already-attached protected renderer.
    var canAcceptSecurePlaintext: Bool {
        secureCapturePhase == .protectedRedaction
            && securePlaintextAcceptanceIsAuthorized
            && currentSceneCaptureState == .inactive
            && foregroundPresentationIsAllowed
            && secureCaptureRenderer.captureProtectionEnabledForInspection
            && secureCaptureRenderer.displayLayerIsAttachedForInspection
            && secureCaptureRenderer.canBeginPlaintextPresentation
    }

    var permitsSecureTextMutation: Bool {
        !isSecureContentMode
            || (secureCapturePhase == .protectedPlaintext && secureEditingIsAuthorized)
    }

    var secureSceneCaptureState: UISceneCaptureState { currentSceneCaptureState }

    func setSecureEditingAuthorized(_ authorized: Bool) {
        secureEditingIsAuthorized = authorized
            && isSecureContentMode
            && secureCapturePhase == .protectedPlaintext
    }

    func setSecurePlaintextAcceptanceAuthorized(_ authorized: Bool) {
        securePlaintextAcceptanceIsAuthorized = authorized && isSecureContentMode
    }

    func setSecureContinuousRevealAuthorized(_ authorized: Bool) {
        secureContinuousRevealIsAuthorized = authorized && isSecureContentMode
    }

    @discardableResult
    func displaySecurePlaintext(_ plaintext: String) -> Bool {
        guard canAcceptSecurePlaintext else { return false }
        replaceTextStorage(with: plaintext)
        securePlaintextIsLoaded = true
        secureCapturePhase = .protectedPlaintext
        guard secureCaptureRenderer.renderPlaintext() else {
            securePlaintextAcceptanceIsAuthorized = false
            secureContinuousRevealIsAuthorized = false
            isEditable = false
            secureCapturePhase = .protectedRedaction
            securePlaintextIsLoaded = false
            _ = secureCaptureRenderer.renderRedaction()
            replaceTextStorage(with: "")
            return false
        }
        return secureCapturePhase == .protectedPlaintext
    }

    /// Redacts and clears a revealed body. `notifyOwner` is false when the owner
    /// has already persisted it, such as the vault-will-lock path.
    @discardableResult
    func redactAndClearSecurePlaintext(notifyOwner: Bool = false) -> String? {
        guard isSecureContentMode else { return nil }
        let plaintext = securePlaintextIsLoaded ? (text ?? "") : nil
        secureEditingIsAuthorized = false
        securePlaintextAcceptanceIsAuthorized = false
        secureContinuousRevealIsAuthorized = false
        // Revoke editing/storage state before invoking any observer callback. The
        // renderer's redaction path is allocation-free and always leaves AV hidden.
        isEditable = false
        secureCapturePhase = .protectedRedaction
        securePlaintextIsLoaded = false
        _ = secureCaptureRenderer.renderRedaction()
        replaceTextStorage(with: "")
        if notifyOwner, let plaintext {
            onSecureCaptureForcedRedaction?(plaintext, .sceneCapture)
        }
        return plaintext
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

    func setSecureForegroundActiveForTesting(_ active: Bool?) {
        foregroundPresentationOverrideForTesting = active
    }

    func setForegroundPresentationAllowedForTesting(_ allowed: Bool?) {
        foregroundPresentationOverrideForTesting = allowed
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

    var secureCaptureDisplayLayerHiddenForInspection: Bool {
        secureCaptureRenderer.displayLayerIsHiddenForInspection
    }

    var secureCaptureFallbackVisibleForInspection: Bool {
        secureCaptureRenderer.fallbackLayerIsVisibleForInspection
    }

    var secureCaptureFrameGenerationForInspection: UInt64 {
        secureCaptureRenderer.frameGenerationForInspection
    }

    var secureCapturePendingGenerationForInspection: UInt64? {
        secureCaptureRenderer.pendingPresentationGenerationForInspection
    }

    func setSecureCaptureFlushCompletionOverrideForTesting(
        _ override: (((@escaping () -> Void)) -> Void)?
    ) {
        secureCaptureRenderer.setFlushCompletionOverrideForTesting(override)
    }

    func setSecureCaptureRendererFailedForTesting(_ failed: Bool?) {
        secureCaptureRenderer.setRendererFailedOverrideForTesting(failed)
    }

    var secureCaptureMayPresentPlaintextNow: Bool {
        secureCapturePhase == .protectedPlaintext
            && securePlaintextIsLoaded
            && secureContinuousRevealIsAuthorized
            && currentSceneCaptureState == .inactive
            && foregroundPresentationIsAllowed
    }

    /// A generation-current AV presentation may still be rejected if the app,
    /// scene, capture state, or continuous reveal source changed while the
    /// renderer's asynchronous flush was in flight. Clear storage and notify the
    /// owner synchronously; a late completion must never leave policy and pixels
    /// disagreeing about whether plaintext is disclosed.
    func secureCapturePresentationWasRevoked() {
        guard secureCapturePhase == .protectedPlaintext else { return }
        let plaintext = securePlaintextIsLoaded ? (text ?? "") : nil
        secureEditingIsAuthorized = false
        securePlaintextAcceptanceIsAuthorized = false
        secureContinuousRevealIsAuthorized = false
        isEditable = false
        secureCapturePhase = .protectedRedaction
        securePlaintextIsLoaded = false
        _ = secureCaptureRenderer.renderRedaction()
        replaceTextStorage(with: "")
        onSecureCaptureForcedRedaction?(plaintext, .presentationRevoked)
    }

    private var foregroundPresentationIsAllowed: Bool {
        if let foregroundPresentationOverrideForTesting {
            return foregroundPresentationOverrideForTesting
        }
        return UIApplication.shared.applicationState == .active
            && window?.windowScene?.activationState == .foregroundActive
    }

    private var currentSceneCaptureState: UISceneCaptureState {
        sceneCaptureStateOverrideForTesting ?? traitCollection.sceneCaptureState
    }

    private func reevaluateSceneCaptureState() {
        let state = currentSceneCaptureState
        if secureCapturePhase == .protectedPlaintext, state != .inactive {
            let plaintext = securePlaintextIsLoaded ? (text ?? "") : nil
            secureEditingIsAuthorized = false
            securePlaintextAcceptanceIsAuthorized = false
            secureContinuousRevealIsAuthorized = false
            isEditable = false
            secureCapturePhase = .protectedRedaction
            securePlaintextIsLoaded = false
            _ = secureCaptureRenderer.renderRedaction()
            replaceTextStorage(with: "")
            onSecureCaptureForcedRedaction?(plaintext, .sceneCapture)
        }
        onSecureSceneCaptureStateChanged?(state)
    }

    private func secureCaptureRendererDidFail() {
        guard secureCapturePhase != .failedClosed else { return }
        let plaintext = securePlaintextIsLoaded ? (text ?? "") : nil
        isEditable = false
        secureCapturePhase = .failedClosed
        securePlaintextIsLoaded = false
        secureEditingIsAuthorized = false
        securePlaintextAcceptanceIsAuthorized = false
        secureContinuousRevealIsAuthorized = false
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
            super.isAccessibilityElement = false
            super.accessibilityElementsHidden = true
            super.accessibilityLabel = nil
            super.accessibilityValue = nil
            super.accessibilityHint = nil
            super.accessibilityIdentifier = nil
            super.accessibilityAttributedLabel = nil
            super.accessibilityAttributedValue = nil
            super.accessibilityAttributedHint = nil
            super.accessibilityUserInputLabels = []
            super.accessibilityAttributedUserInputLabels = []
            super.accessibilityTextualContext = nil
            super.isAccessibilityElementBlock = { false }
            super.accessibilityLabelBlock = { nil }
            super.accessibilityValueBlock = { nil }
            super.accessibilityHintBlock = { nil }
            super.accessibilityIdentifierBlock = { nil }
            super.accessibilityAttributedLabelBlock = { nil }
            super.accessibilityAttributedValueBlock = { nil }
            super.accessibilityAttributedHintBlock = { nil }
            super.accessibilityTextualContextBlock = { nil }
            super.accessibilityUserInputLabelsBlock = { [] }
            super.accessibilityAttributedUserInputLabelsBlock = { [] }
            super.accessibilityElementsHiddenBlock = { true }
            super.accessibilityElements = []
            super.automationElements = []
            super.accessibilityElementsBlock = { [] }
            super.automationElementsBlock = { [] }
            super.accessibilityPreviousTextNavigationElement = nil
            super.accessibilityNextTextNavigationElement = nil
            super.accessibilityPreviousTextNavigationElementBlock = { nil }
            super.accessibilityNextTextNavigationElementBlock = { nil }
            super.accessibilityTextInputResponder = nil
            super.accessibilityTextInputResponderBlock = { nil }
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
            super.isAccessibilityElement = ordinaryIsAccessibilityElement
            super.accessibilityElementsHidden = ordinaryAccessibilityElementsHidden
            super.accessibilityIdentifier = ordinaryAccessibilityIdentifier
            super.accessibilityUserInputLabels = nil
            super.accessibilityAttributedUserInputLabels = nil
            super.isAccessibilityElementBlock = nil
            super.accessibilityLabelBlock = nil
            super.accessibilityValueBlock = nil
            super.accessibilityHintBlock = nil
            super.accessibilityIdentifierBlock = nil
            super.accessibilityAttributedLabelBlock = nil
            super.accessibilityAttributedValueBlock = nil
            super.accessibilityAttributedHintBlock = nil
            super.accessibilityTextualContextBlock = nil
            super.accessibilityUserInputLabelsBlock = nil
            super.accessibilityAttributedUserInputLabelsBlock = nil
            super.accessibilityElementsHiddenBlock = nil
            super.accessibilityElements = nil
            super.automationElements = nil
            super.accessibilityElementsBlock = nil
            super.automationElementsBlock = nil
            super.accessibilityPreviousTextNavigationElementBlock = nil
            super.accessibilityNextTextNavigationElementBlock = nil
            super.accessibilityTextInputResponderBlock = nil
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

/// A metadata-free accessibility sibling for a protected secure body.
///
/// The secure text view itself is intentionally unavailable to assistive technology,
/// including while pixels are visible. This element communicates that limitation
/// without ever receiving the snippet body, name, keyword, or tags.
final class SecureBodyAccessibilityNoticeView: UIView {
    enum State {
        case hidden
        case locked
        case authenticatedRedacted
        case visuallyRevealed
    }

    static let protectedLabel = "Protected secure snippet body"
    static let lockedValue =
        "Use Reveal Secure Content to show it visually. The text is unavailable to accessibility."
    static let authenticatedValue =
        "Authenticated. Hover over the editor or hold to show it visually. The text is unavailable to accessibility."
    static let revealedValue =
        "Content is shown visually. The text remains unavailable to accessibility."

    var state: State = .hidden {
        didSet { applyState() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityIdentifier = "secure-body-protection"
        accessibilityTraits = .staticText
        applyState()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityIdentifier = "secure-body-protection"
        accessibilityTraits = .staticText
        applyState()
    }

    private func applyState() {
        switch state {
        case .hidden:
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            accessibilityLabel = nil
            accessibilityValue = nil
            accessibilityHint = nil
        case .locked:
            isAccessibilityElement = true
            accessibilityElementsHidden = false
            accessibilityLabel = Self.protectedLabel
            accessibilityValue = Self.lockedValue
            accessibilityHint = nil
        case .authenticatedRedacted:
            isAccessibilityElement = true
            accessibilityElementsHidden = false
            accessibilityLabel = Self.protectedLabel
            accessibilityValue = Self.authenticatedValue
            accessibilityHint = nil
        case .visuallyRevealed:
            isAccessibilityElement = true
            accessibilityElementsHidden = false
            accessibilityLabel = Self.protectedLabel
            accessibilityValue = Self.revealedValue
            accessibilityHint = nil
        }
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
