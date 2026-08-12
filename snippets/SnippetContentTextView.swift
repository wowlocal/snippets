import AppKit
import QuickLookUI

/// A safe, non-interactive sibling that explains an intentionally blank secure
/// editor. It must never become the hit-test target: the text view underneath
/// owns the real cursor verification used by the hover reveal boundary.
final class SecureHoverHintOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Pure visibility decision kept separate from cursor verification. In
/// particular, protected plaintext is never accompanied by chrome that could
/// obscure selection, and every non-redaction phase fails hidden.
nonisolated enum SecureHoverHintPresentationPolicy {
    static func isVisible(
        capturePhase: SecureCapturePresentationPolicy.Phase,
        hoverPresentationIsArmed: Bool,
        isSecureContentMode: Bool,
        isEditable: Bool
    ) -> Bool {
        capturePhase == .protectedRedaction
            && hoverPresentationIsArmed
            && isSecureContentMode
            && isEditable
    }
}

/// The snippet content editor. `NSTextView` has no placeholder of its own, and
/// the prompt must never become real text: it would be stored, exported and
/// expanded. So it is drawn, not inserted — `string` stays empty the whole time
/// the prompt is on screen.
///
/// "Placeholder" already means a `{clipboard}`-style token everywhere else in
/// this app, hence `emptyStatePrompt`.
final class SnippetContentTextView: NSTextView {
    /// True only across the interval in which this view may hold plaintext
    /// decrypted from a secure snippet. The controller flips this before
    /// assigning the plaintext and after clearing it; ordinary snippets retain
    /// NSTextView's normal accessibility behavior.
    private(set) var mayContainSecurePlaintext = false

    func prepareForSecurePlaintextAccessibility() {
        assert(isAccessibilityProtectedContent(), "Set AppKit AX protection before secure presentation")
        mayContainSecurePlaintext = true
    }

    func securePlaintextWasClearedFromAccessibility() {
        // The ordering is part of the security boundary. In Debug, catch a new
        // caller that tries to make the value public while the secret remains.
        assert(string.isEmpty, "Clear secure plaintext before removing AX protection")
        mayContainSecurePlaintext = false
    }

    /// True for the whole lifetime of a selected secure record, including its
    /// locked/empty state. Set this before decrypted bytes enter `string` and
    /// clear the bytes before setting it back to false.
    var isSecureContentMode = false {
        didSet {
            guard oldValue != isSecureContentMode else { return }
            if !isSecureContentMode {
                _ = forceSecureHoverRedaction()
            }
            applyContentExposureMode()
        }
    }

    private struct AmbientTextServiceSettings {
        let continuousSpellChecking: Bool
        let grammarChecking: Bool
        let automaticSpellingCorrection: Bool
        let enabledTextCheckingTypes: NSTextCheckingTypes
        let smartInsertDelete: Bool
        let automaticQuoteSubstitution: Bool
        let automaticLinkDetection: Bool
        let automaticDataDetection: Bool
        let automaticDashSubstitution: Bool
        let automaticTextReplacement: Bool
        let automaticTextCompletion: Bool
        let inlinePredictionType: NSTextInputTraitType
        let mathExpressionCompletionType: NSTextInputTraitType
        let writingToolsBehavior: NSWritingToolsBehavior
        let usesFindPanel: Bool
        let usesFindBar: Bool
        let incrementalSearching: Bool
        let rolloverButtonForSelection: Bool
    }

    private var ordinaryTextServiceSettings: AmbientTextServiceSettings?

    private(set) var secureCapturePolicy = SecureCapturePresentationPolicy()
    private lazy var secureCaptureRenderer = SecureSnippetCaptureRenderer(textView: self)
    private(set) var secureHoverRevealPolicy = SecureHoverRevealPolicy()
    private var secureHoverTrackingArea: NSTrackingArea?
    private var secureHoverObservers: [NSObjectProtocol] = []
    private var isSynchronizingSecureHoverReveal = false
    private var isUpdatingSecureTrackingAreas = false
    private(set) var isClearingSecurePlaintextStorageForTeardown = false
    private var secureHoverValidationTimer: Timer?
    private var secureHoverHintVisibilityHandler: ((Bool) -> Void)?
    private var secureCopyRefusalHandler: (() -> Void)?
    private(set) var isSecureHoverHintVisible = false

    deinit {
        for observer in secureHoverObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        secureHoverValidationTimer?.invalidate()
    }

    /// Arms the protected rendering path before the caller puts decrypted text in
    /// `NSTextStorage`. This first presents an opaque protected redaction frame and
    /// suppresses every AppKit text/caret/selection draw primitive.
    @discardableResult
    func setSecurePresentationEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard isSecureContentMode else { return false }
            guard secureCapturePolicy.phase == .ordinary else {
                return secureCapturePolicy.phase != .failedClosed
            }
            secureCapturePolicy.arm()
            guard secureCaptureRenderer.arm() else {
                secureCapturePolicy.failClosed()
                return false
            }
            beginSecureHoverTracking()
            needsDisplay = true
            return true
        }

        // Plaintext must be gone before ordinary AppKit drawing can be restored.
        assert(super.string.isEmpty, "Clear secure plaintext before disabling capture protection")
        guard super.string.isEmpty else {
            secureCaptureRenderer.failClosed()
            return false
        }
        // `clear()` below synchronously hides and flushes the protected layer.
        // Avoid asking the renderer for a new frame after storage was cleared:
        // a teardown-time allocation failure must not run the save callback on
        // an intentionally empty editor.
        endSecureHoverTracking(redactDisplayedPixels: false)
        secureCaptureRenderer.clear()
        secureCapturePolicy.resetAfterPlaintextWasCleared()
        needsDisplay = true
        return true
    }

    /// Ordered secure-to-ordinary rebind hook. Call this before assigning an
    /// ordinary body; it clears old protected storage while drawing is still
    /// suppressed, removes the protected image, then restores AppKit drawing.
    @discardableResult
    func prepareForOrdinaryContentRebind() -> Bool {
        guard secureCapturePolicy.suppressesUnprotectedDrawing else { return true }
        _ = redactSecurePixelsBeforePlaintextClear()
        undoManager?.removeAllActions(withTarget: self)
        clearSecurePlaintextStorageForTeardown()
        return setSecurePresentationEnabled(false)
    }

    /// Hides and flushes a displayed plaintext sample while text storage still
    /// contains the current edit. Callers then clear storage without triggering
    /// a teardown-time renderer pass whose failure callback could observe an
    /// intentionally empty editor.
    @discardableResult
    func redactSecurePixelsBeforePlaintextClear() -> Bool {
        guard secureCapturePolicy.phase != .failedClosed else { return true }
        return forceSecureHoverRedaction()
    }

    /// Clears NSTextStorage without entering `string`'s ordinary secure-frame
    /// invalidation path. The caller has already redacted/flushed pixels while
    /// the real edit was present, so a second renderer pass here would only add
    /// a failure callback capable of observing this intentional empty value.
    func clearSecurePlaintextStorageForTeardown() {
        assert(secureCapturePolicy.suppressesUnprotectedDrawing)
        guard secureCapturePolicy.suppressesUnprotectedDrawing else { return }
        isClearingSecurePlaintextStorageForTeardown = true
        defer { isClearingSecurePlaintextStorageForTeardown = false }
        super.string = ""
        needsDisplay = true
    }

    /// Re-evaluates the process-wide cursor position and active window before
    /// applying the hover decision. Mouse-event coordinates are never trusted as
    /// authorization to reveal. This controls protected pixels only; it neither
    /// unlocks the vault nor decrypts content.
    @discardableResult
    func refreshSecureHoverRevealFromCurrentCursor() -> Bool {
        guard secureHoverRevealPolicy.presentationIsArmed else {
            return secureCapturePolicy.phase == .ordinary
        }
        if isSynchronizingSecureHoverReveal {
            return secureCapturePolicy.phase != .failedClosed
        }

        isSynchronizingSecureHoverReveal = true
        defer { isSynchronizingSecureHoverReveal = false }
        updateSecureHoverPolicyFromCurrentCursor()
        return applySecureHoverRevealDecision()
    }

    func refreshSecurePresentation() {
        invalidateSecureCaptureRenderer()
    }

    func invalidateSecureCaptureRenderer() {
        guard !isClearingSecurePlaintextStorageForTeardown else { return }
        secureCaptureRenderer.invalidate()
    }

    func setSecureCaptureFailureHandler(_ handler: @escaping () -> Void) {
        secureCaptureRenderer.onFailure = handler
    }

    /// Publishes only the safe presentation state, never content. The controller
    /// renders the affordance as a sibling above the protected capture layer so
    /// recordings retain the explanation while secure pixels remain omitted.
    func setSecureHoverHintVisibilityHandler(_ handler: @escaping (Bool) -> Void) {
        secureHoverHintVisibilityHandler = handler
        handler(isSecureHoverHintVisible)
    }

    /// Reports only the explicit responder-chain Copy action. The lower-level
    /// pasteboard, Services, drag, and sharing boundaries below keep failing
    /// silently: AppKit can query them speculatively, and such a capability check
    /// is not a user-visible copy attempt.
    func setSecureCopyRefusalHandler(_ handler: @escaping () -> Void) {
        secureCopyRefusalHandler = handler
    }

    func secureCaptureRendererDidFail() {
        endSecureHoverTracking(redactDisplayedPixels: false)
        secureCapturePolicy.failClosed()
        updateSecureHoverHintVisibility()
        super.string = ""
        super.isEditable = false
        needsDisplay = true
    }

    var secureCaptureDidFail: Bool { secureCapturePolicy.phase == .failedClosed }

    func secureCaptureFrameForInspection(
        plaintext: Bool
    ) -> SecureSnippetCaptureRenderer.RenderedFrameInspection? {
        secureCaptureRenderer.renderFrameForInspection(plaintext: plaintext)
    }

    var secureCaptureProtectionEnabledForInspection: Bool {
        secureCaptureRenderer.captureProtectionEnabledForInspection
    }

    var secureCaptureFrameGenerationForInspection: UInt64 {
        secureCaptureRenderer.frameGenerationForInspection
    }

    var secureCaptureObservesScrollForInspection: Bool {
        secureCaptureRenderer.observesScrollForInspection
    }

    var secureHoverTracksPointerForInspection: Bool {
        secureHoverRevealPolicy.presentationIsArmed
            && secureHoverTrackingArea != nil
            && secureHoverValidationTimer?.isValid == true
    }

    var secureHoverRevealsPixelsForInspection: Bool {
        secureHoverRevealPolicy.shouldRevealPlaintextPixels
            && secureCapturePolicy.rendersPlaintextPixels
    }

    /// Refreshes the independently verified cursor/window snapshot at the exact
    /// mutation boundary, then permits a secure edit only while the protected
    /// renderer is showing plaintext. This closes the interval between pointer
    /// exit and the tracking/timer callbacks; synthetic events are not trusted.
    private func secureHoverPermitsMutationNow() -> Bool {
        guard isSecureContentMode else { return isEditable }
        guard refreshSecureHoverRevealFromCurrentCursor() else { return false }
        return SecureHoverEditingPolicy.permitsMutation(
            capturePhase: secureCapturePolicy.phase,
            hoverPresentationIsArmed: secureHoverRevealPolicy.presentationIsArmed,
            hoverPolicyPermitsReveal: secureHoverRevealPolicy.shouldRevealPlaintextPixels,
            isSecureContentMode: true,
            isEditable: isEditable
        )
    }

    private func beginSecureHoverTracking() {
        secureHoverRevealPolicy.presentationDidArm()
        installSecureHoverObservers()
        rebuildSecureHoverTrackingArea()
        startSecureHoverValidationTimer()

        // Capture a fresh real-cursor snapshot so the controller can account for
        // a pointer that was already inside when it assigns the decrypted body.
        // Do not expose a frame here: arming itself always finishes redacted.
        updateSecureHoverPolicyFromCurrentCursor()
        updateSecureHoverHintVisibility()
    }

    private func endSecureHoverTracking(redactDisplayedPixels: Bool) {
        if redactDisplayedPixels {
            _ = forceSecureHoverRedaction()
        } else {
            secureHoverRevealPolicy.forceRedaction()
        }
        removeSecureHoverTrackingArea()
        removeSecureHoverObservers()
        secureHoverValidationTimer?.invalidate()
        secureHoverValidationTimer = nil
        secureHoverRevealPolicy.presentationDidEnd()
        updateSecureHoverHintVisibility()
    }

    private func startSecureHoverValidationTimer() {
        secureHoverValidationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.refreshSecureHoverRevealFromCurrentCursor()
            }
        }
        secureHoverValidationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installSecureHoverObservers() {
        removeSecureHoverObservers()
        let center = NotificationCenter.default
        let application = NSApplication.shared

        secureHoverObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: application,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.forceSecureHoverRedaction()
            }
        })
        secureHoverObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: application,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.refreshSecureHoverRevealFromCurrentCursor()
            }
        })

        guard let window else { return }
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            secureHoverObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = self?.refreshSecureHoverRevealFromCurrentCursor()
                }
            })
        }
        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification,
        ] {
            secureHoverObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = self?.forceSecureHoverRedaction()
                }
            })
        }
    }

    private func removeSecureHoverObservers() {
        for observer in secureHoverObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        secureHoverObservers.removeAll(keepingCapacity: true)
    }

    private func rebuildSecureHoverTrackingArea() {
        guard !isUpdatingSecureTrackingAreas else { return }
        isUpdatingSecureTrackingAreas = true
        defer { isUpdatingSecureTrackingAreas = false }
        removeSecureHoverTrackingArea()
        guard secureHoverRevealPolicy.presentationIsArmed, window != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .enabledDuringMouseDrag,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        secureHoverTrackingArea = area
    }

    private func removeSecureHoverTrackingArea() {
        if let secureHoverTrackingArea {
            removeTrackingArea(secureHoverTrackingArea)
        }
        secureHoverTrackingArea = nil
    }

    private func updateSecureHoverPolicyFromCurrentCursor() {
        let applicationIsActive = NSApp?.isActive == true
        guard let window,
              applicationIsActive,
              window.isKeyWindow,
              window.isVisible,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor else {
            secureHoverRevealPolicy.updateVerifiedEnvironment(
                cursorInsideViewport: false,
                applicationIsActive: applicationIsActive,
                windowIsKey: window?.isKeyWindow == true
            )
            return
        }

        let viewport = visibleRect.intersection(bounds)
        guard !viewport.isEmpty else {
            secureHoverRevealPolicy.updateVerifiedEnvironment(
                cursorInsideViewport: false,
                applicationIsActive: true,
                windowIsKey: true
            )
            return
        }

        let screenPoint = NSEvent.mouseLocation
        let screenRect = NSRect(origin: screenPoint, size: .zero)
        let windowPoint = window.convertFromScreen(screenRect).origin
        let localPoint = convert(windowPoint, from: nil)
        secureHoverRevealPolicy.updateVerifiedEnvironment(
            cursorInsideViewport: viewport.contains(localPoint),
            applicationIsActive: true,
            windowIsKey: true
        )
    }

    @discardableResult
    private func applySecureHoverRevealDecision() -> Bool {
        guard secureHoverRevealPolicy.presentationIsArmed,
              secureCapturePolicy.permitsPlaintextInTextStorage else { return false }
        let shouldReveal = secureHoverRevealPolicy.shouldRevealPlaintextPixels
            && isSecureContentMode
            && isEditable
        guard secureCapturePolicy.rendersPlaintextPixels != shouldReveal else { return true }

        secureCapturePolicy.setPlaintextPixelsVisible(shouldReveal)
        updateSecureHoverHintVisibility()
        let rendered = shouldReveal
            ? secureCaptureRenderer.renderPlaintext()
            : secureCaptureRenderer.renderRedaction()
        if !rendered {
            updateSecureHoverHintVisibility()
        }
        return rendered
    }

    /// Exit and activity-loss paths call this directly. If a plaintext sample is
    /// currently displayed, `renderRedaction()` synchronously hides the display
    /// layer and flushes that sample before returning.
    @discardableResult
    private func forceSecureHoverRedaction() -> Bool {
        secureHoverRevealPolicy.forceRedaction()
        guard secureCapturePolicy.permitsPlaintextInTextStorage else {
            updateSecureHoverHintVisibility()
            return secureCapturePolicy.phase == .ordinary
        }
        guard secureCapturePolicy.rendersPlaintextPixels else {
            updateSecureHoverHintVisibility()
            return true
        }
        secureCapturePolicy.setPlaintextPixelsVisible(false)
        let rendered = secureCaptureRenderer.renderRedaction()
        updateSecureHoverHintVisibility()
        return rendered
    }

    private func updateSecureHoverHintVisibility() {
        let shouldShow = SecureHoverHintPresentationPolicy.isVisible(
            capturePhase: secureCapturePolicy.phase,
            hoverPresentationIsArmed: secureHoverRevealPolicy.presentationIsArmed,
            isSecureContentMode: isSecureContentMode,
            isEditable: isEditable
        )
        guard shouldShow != isSecureHoverHintVisible else { return }
        isSecureHoverHintVisible = shouldShow
        secureHoverHintVisibilityHandler?(shouldShow)
    }

    func secureVisibleViewportDidChange() {
        _ = refreshSecureHoverRevealFromCurrentCursor()
    }

    var emptyStatePrompt: String = "" {
        didSet { needsDisplay = true }
    }

    /// Assigning `string` is the controller-only bind/clear path and intentionally
    /// bypasses the user-mutation hover gate. User actions must enter through the
    /// NSTextView methods guarded below. Assignment also skips `didChangeText()`,
    /// and `applySnippetToEditor` is exactly that path, so the prompt would otherwise
    /// survive selecting a snippet that has content.
    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            if secureCapturePolicy.rendersPlaintextPixels {
                invalidateSecureCaptureRenderer()
            }
            needsDisplay = true
        }
    }

    /// With no snippet selected the editor is disabled and empty; "Paste or
    /// type…" would be inviting the user to do something the view refuses.
    override var isEditable: Bool {
        didSet {
            if !isEditable {
                _ = forceSecureHoverRedaction()
            }
            updateSecureHoverHintVisibility()
            needsDisplay = true
        }
    }

    override func didChangeText() {
        super.didChangeText()
        if secureCapturePolicy.rendersPlaintextPixels {
            invalidateSecureCaptureRenderer()
        }
        needsDisplay = true
    }

    // MARK: - Secure plaintext containment

    /// NSTextView funnels typing, IME commits, key-binding deletes, paste,
    /// drag/drop, Services replacements, and its undo/redo replacements through
    /// these validation methods. Gate both variants because AppKit can choose
    /// either one for single- versus multi-range operations.
    override func shouldChangeText(
        inRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        guard secureHoverPermitsMutationNow() else { return false }
        return super.shouldChangeText(
            inRanges: affectedRanges,
            replacementStrings: replacementStrings
        )
    }

    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard secureHoverPermitsMutationNow() else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// Explicit ingress guards are defense in depth for direct callers and input
    /// methods. The central shouldChangeText gate remains authoritative for the
    /// actual storage replacement.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard secureHoverPermitsMutationNow() else { return }
        super.insertText(string, replacementRange: replacementRange)

        let inserted = (string as? String) ?? (string as? NSAttributedString)?.string
        // Completion is an ambient text service on AppKit. Ordinary snippets
        // keep the local token convenience; secure snippets keep the literal
        // brace and never enter the completion subsystem at all.
        guard inserted == "{", isEditable, !isSecureContentMode else { return }

        // Not synchronously: AppKit is still inside its own insertion here, and
        // the completion machinery reads the text storage this just wrote to.
        DispatchQueue.main.async { [weak self] in
            guard let self, isEditable else { return }
            complete(nil)
        }
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        guard secureHoverPermitsMutationNow() else {
            inputContext?.discardMarkedText()
            return
        }
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    /// AppKit reaches the pasteboard through several different public entry
    /// points (Edit menu, Services, dragging, and callers invoking these methods
    /// directly). Every one is guarded; hiding Copy in a menu is not a boundary.
    override func copy(_ sender: Any?) {
        guard !isSecureContentMode else {
            secureCopyRefusalHandler?()
            return
        }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.cut(sender)
    }

    override func delete(_ sender: Any?) {
        guard secureHoverPermitsMutationNow() else { return }
        super.delete(sender)
    }

    override func paste(_ sender: Any?) {
        guard secureHoverPermitsMutationNow() else { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard secureHoverPermitsMutationNow() else { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        guard secureHoverPermitsMutationNow() else { return }
        super.pasteAsRichText(sender)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        guard !isSecureContentMode else { return [] }
        return super.writablePasteboardTypes
    }

    override func writeSelection(
        to pboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard !isSecureContentMode else { return false }
        return super.writeSelection(to: pboard, type: type)
    }

    override func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard !isSecureContentMode else { return false }
        return super.writeSelection(to: pboard, types: types)
    }

    override func readSelection(
        from pboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard secureHoverPermitsMutationNow() else { return false }
        return super.readSelection(from: pboard, type: type)
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard secureHoverPermitsMutationNow() else { return false }
        return super.readSelection(from: pboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard secureHoverPermitsMutationNow() else { return false }
        return super.performDragOperation(sender)
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // Refuse both directions. A receive-only Service can still inspect the
        // selection while preparing its replacement, so it is not a safe exception.
        guard !isSecureContentMode else { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func dragSelection(
        with event: NSEvent,
        offset mouseOffset: NSSize,
        slideBack: Bool
    ) -> Bool {
        guard !isSecureContentMode else { return false }
        return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    override func dragImageForSelection(
        with event: NSEvent,
        origin: NSPointPointer?
    ) -> NSImage? {
        guard !isSecureContentMode else { return nil }
        return super.dragImageForSelection(with: event, origin: origin)
    }

    override func orderFrontSharingServicePicker(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.orderFrontSharingServicePicker(sender)
    }

    override func performFindPanelAction(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.performFindPanelAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.performTextFinderAction(sender)
    }

    override func startSpeaking(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.startSpeaking(sender)
    }

    override func quickLook(with event: NSEvent) {
        guard !isSecureContentMode else { return }
        super.quickLook(with: event)
    }

    override func quickLookPreviewItems(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.quickLookPreviewItems(sender)
    }

    override func toggleQuickLookPreviewPanel(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleQuickLookPreviewPanel(sender)
    }

    override func quickLookPreviewableItems(inRanges ranges: [NSValue]) -> [any QLPreviewItem] {
        guard !isSecureContentMode else { return [] }
        return super.quickLookPreviewableItems(inRanges: ranges)
    }

    override func checkSpelling(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.checkSpelling(sender)
    }

    override func showGuessPanel(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.showGuessPanel(sender)
    }

    override func checkTextInSelection(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.checkTextInSelection(sender)
    }

    override func checkTextInDocument(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.checkTextInDocument(sender)
    }

    override func checkText(
        in range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any]
    ) {
        guard !isSecureContentMode else { return }
        super.checkText(in: range, types: checkingTypes, options: options)
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleContinuousSpellChecking(sender)
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleGrammarChecking(sender)
    }

    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleAutomaticSpellingCorrection(sender)
    }

    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleAutomaticQuoteSubstitution(sender)
    }

    override func toggleAutomaticLinkDetection(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleAutomaticLinkDetection(sender)
    }

    override func toggleAutomaticDataDetection(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleAutomaticDataDetection(sender)
    }

    override func toggleAutomaticDashSubstitution(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleAutomaticDashSubstitution(sender)
    }

    override func toggleAutomaticTextReplacement(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleAutomaticTextReplacement(sender)
    }

    override func toggleSmartInsertDelete(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleSmartInsertDelete(sender)
    }

    override func toggleAutomaticTextCompletion(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.toggleAutomaticTextCompletion(sender)
    }

    override func orderFrontSubstitutionsPanel(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.orderFrontSubstitutionsPanel(sender)
    }

    @available(macOS 15.2, *)
    override func showWritingTools(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.showWritingTools(sender)
    }

    /// Menu validation and `tryToPerform` are defense in depth around the direct
    /// overrides above. The policy denies output actions without intercepting the
    /// many responder selectors NSTextView uses for ordinary keyboard editing.
    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        guard SnippetContentExposurePolicy.permitsResponderAction(
            named: NSStringFromSelector(action),
            whileSecure: isSecureContentMode
        ) else { return false }
        return super.tryToPerform(action, with: object)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return super.validateUserInterfaceItem(item) }
        if isSecureContentMode,
           Self.secureMutationActionNames.contains(NSStringFromSelector(action)),
           !secureHoverPermitsMutationNow() {
            return false
        }
        guard SnippetContentExposurePolicy.permitsResponderAction(
            named: NSStringFromSelector(action),
            whileSecure: isSecureContentMode
        ) else { return false }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isSecureContentMode else { return super.menu(for: event) }

        let menu = NSMenu()
        appendSecureMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), to: menu)
        appendSecureMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), to: menu)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        appendSecureMenuItem(title: "Paste", action: #selector(paste(_:)), to: menu)
        appendSecureMenuItem(title: "Select All", action: #selector(selectAll(_:)), to: menu)
        return menu
    }

    private func appendSecureMenuItem(title: String, action: Selector, to menu: NSMenu) {
        guard SnippetContentExposurePolicy.permitsResponderAction(
            named: NSStringFromSelector(action), whileSecure: true
        ) else { return }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = nil
        menu.addItem(item)
    }

    private static let secureMutationActionNames: Set<String> = [
        "undo:", "redo:",
        "paste:", "pasteAsPlainText:", "pasteAsRichText:",
        "delete:", "deleteBackward:", "deleteForward:",
        "deleteWordBackward:", "deleteWordForward:",
        "deleteToBeginningOfLine:", "deleteToEndOfLine:",
        "deleteToBeginningOfParagraph:", "deleteToEndOfParagraph:",
        "transpose:", "transposeWords:", "yank:",
        "insertNewline:", "insertNewlineIgnoringFieldEditor:",
        "insertTabIgnoringFieldEditor:",
    ]

    /// The responder chain normally resolves these actions to the text view's
    /// undo manager. Owning the actions here lets a redacted editor reject them
    /// before the manager consumes an entry; the replacement itself still goes
    /// through shouldChangeText as a second check.
    @objc func undo(_ sender: Any?) {
        guard secureHoverPermitsMutationNow() else { return }
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard secureHoverPermitsMutationNow() else { return }
        undoManager?.redo()
    }

    private func applyContentExposureMode() {
        if isSecureContentMode {
            if ordinaryTextServiceSettings == nil {
                ordinaryTextServiceSettings = AmbientTextServiceSettings(
                    continuousSpellChecking: isContinuousSpellCheckingEnabled,
                    grammarChecking: isGrammarCheckingEnabled,
                    automaticSpellingCorrection: isAutomaticSpellingCorrectionEnabled,
                    enabledTextCheckingTypes: enabledTextCheckingTypes,
                    smartInsertDelete: smartInsertDeleteEnabled,
                    automaticQuoteSubstitution: isAutomaticQuoteSubstitutionEnabled,
                    automaticLinkDetection: isAutomaticLinkDetectionEnabled,
                    automaticDataDetection: isAutomaticDataDetectionEnabled,
                    automaticDashSubstitution: isAutomaticDashSubstitutionEnabled,
                    automaticTextReplacement: isAutomaticTextReplacementEnabled,
                    automaticTextCompletion: isAutomaticTextCompletionEnabled,
                    inlinePredictionType: inlinePredictionType,
                    mathExpressionCompletionType: mathExpressionCompletionType,
                    writingToolsBehavior: writingToolsBehavior,
                    usesFindPanel: usesFindPanel,
                    usesFindBar: usesFindBar,
                    incrementalSearching: isIncrementalSearchingEnabled,
                    rolloverButtonForSelection: usesRolloverButtonForSelection)
            }

            stopSpeaking(nil)
            if #available(macOS 15.2, *) {
                writingToolsCoordinator?.stopWritingTools()
            }
            isContinuousSpellCheckingEnabled = false
            isGrammarCheckingEnabled = false
            isAutomaticSpellingCorrectionEnabled = false
            enabledTextCheckingTypes = 0
            smartInsertDeleteEnabled = false
            isAutomaticQuoteSubstitutionEnabled = false
            isAutomaticLinkDetectionEnabled = false
            isAutomaticDataDetectionEnabled = false
            isAutomaticDashSubstitutionEnabled = false
            isAutomaticTextReplacementEnabled = false
            isAutomaticTextCompletionEnabled = false
            inlinePredictionType = .no
            mathExpressionCompletionType = .no
            writingToolsBehavior = .none
            usesFindPanel = false
            usesFindBar = false
            isIncrementalSearchingEnabled = false
            usesRolloverButtonForSelection = false
        } else if let settings = ordinaryTextServiceSettings {
            isContinuousSpellCheckingEnabled = settings.continuousSpellChecking
            isGrammarCheckingEnabled = settings.grammarChecking
            isAutomaticSpellingCorrectionEnabled = settings.automaticSpellingCorrection
            enabledTextCheckingTypes = settings.enabledTextCheckingTypes
            smartInsertDeleteEnabled = settings.smartInsertDelete
            isAutomaticQuoteSubstitutionEnabled = settings.automaticQuoteSubstitution
            isAutomaticLinkDetectionEnabled = settings.automaticLinkDetection
            isAutomaticDataDetectionEnabled = settings.automaticDataDetection
            isAutomaticDashSubstitutionEnabled = settings.automaticDashSubstitution
            isAutomaticTextReplacementEnabled = settings.automaticTextReplacement
            isAutomaticTextCompletionEnabled = settings.automaticTextCompletion
            inlinePredictionType = settings.inlinePredictionType
            mathExpressionCompletionType = settings.mathExpressionCompletionType
            writingToolsBehavior = settings.writingToolsBehavior
            usesFindPanel = settings.usesFindPanel
            usesFindBar = settings.usesFindBar
            isIncrementalSearchingEnabled = settings.incrementalSearching
            usesRolloverButtonForSelection = settings.rolloverButtonForSelection
            ordinaryTextServiceSettings = nil
        }
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if secureCapturePolicy.rendersPlaintextPixels {
            invalidateSecureCaptureRenderer()
        }
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        guard !secureCapturePolicy.suppressesUnprotectedDrawing else {
            if secureCapturePolicy.rendersPlaintextPixels {
                invalidateSecureCaptureRenderer()
            }
            return
        }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        _ = refreshSecureHoverRevealFromCurrentCursor()
        invalidateSecureCaptureRenderer()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        _ = refreshSecureHoverRevealFromCurrentCursor()
        invalidateSecureCaptureRenderer()
    }

    override func scroll(_ point: NSPoint) {
        super.scroll(point)
        _ = refreshSecureHoverRevealFromCurrentCursor()
        invalidateSecureCaptureRenderer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildSecureHoverTrackingArea()
        _ = refreshSecureHoverRevealFromCurrentCursor()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, secureHoverRevealPolicy.presentationIsArmed {
            _ = forceSecureHoverRedaction()
            removeSecureHoverTrackingArea()
            removeSecureHoverObservers()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard secureHoverRevealPolicy.presentationIsArmed else { return }
        installSecureHoverObservers()
        rebuildSecureHoverTrackingArea()
        _ = refreshSecureHoverRevealFromCurrentCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // The event is only a wake-up signal. Reveal is based on the current
        // process-wide cursor position, not this potentially stale/synthetic event.
        _ = refreshSecureHoverRevealFromCurrentCursor()
    }

    override func mouseExited(with event: NSEvent) {
        // Redact before AppKit dispatches any later responder or tracking work.
        _ = forceSecureHoverRedaction()
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        _ = refreshSecureHoverRevealFromCurrentCursor()
    }

    override func mouseDown(with event: NSEvent) {
        _ = refreshSecureHoverRevealFromCurrentCursor()
        super.mouseDown(with: event)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        _ = refreshSecureHoverRevealFromCurrentCursor()
        invalidateSecureCaptureRenderer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateSecureCaptureRenderer()
    }

    /// The word being completed starts at the `{` the user typed, not wherever
    /// AppKit's word boundaries land inside `{da`. Without this the completion
    /// would insert a token beside the brace instead of replacing it.
    override var rangeForUserCompletion: NSRange {
        guard !isSecureContentMode else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let text = string as NSString
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0, caret.location <= text.length else {
            return super.rangeForUserCompletion
        }

        let precedingRange = NSRange(location: 0, length: caret.location)
        let braceRange = text.rangeOfCharacter(
            from: SnippetContentTextView.tokenBoundaryCharacters,
            options: .backwards,
            range: precedingRange
        )
        guard braceRange.location != NSNotFound, text.substring(with: braceRange) == "{" else {
            return super.rangeForUserCompletion
        }

        // A `{` further back than any token could reach, or with a line break in
        // between, is not the one being typed.
        let length = caret.location - braceRange.location
        guard length <= SnippetContentTextView.maximumTokenCompletionLength else {
            return super.rangeForUserCompletion
        }
        let partial = text.substring(with: NSRange(location: braceRange.location, length: length))
        guard !partial.contains(where: \.isNewline) else {
            return super.rangeForUserCompletion
        }

        return NSRange(location: braceRange.location, length: length)
    }

    /// Never fall through to NSSpellChecker if somebody invokes completion
    /// directly despite `rangeForUserCompletion` refusing a secure range.
    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String]? {
        guard isSecureContentMode else {
            if let index {
                return super.completions(
                    forPartialWordRange: charRange,
                    indexOfSelectedItem: index)
            }
            var ignoredIndex = 0
            return super.completions(
                forPartialWordRange: charRange,
                indexOfSelectedItem: &ignoredIndex)
        }

        index?.pointee = -1
        return []
    }

    private static let tokenBoundaryCharacters = CharacterSet(charactersIn: "{}\n")
    private static let maximumTokenCompletionLength = 24

    override func draw(_ dirtyRect: NSRect) {
        // Do not call `super`: it draws glyphs, selection backgrounds, marked text,
        // and a blinking insertion point into the ordinary window backing store.
        // Secure pixels are drawn only by the offscreen renderer above.
        guard !secureCapturePolicy.suppressesUnprotectedDrawing else { return }
        super.draw(dirtyRect)

        guard isEditable, !emptyStatePrompt.isEmpty, string.isEmpty else { return }

        // A line fragment starts one `lineFragmentPadding` inside the text
        // container, which itself sits inside `textContainerInset`, so the
        // prompt has to clear both to land on the same baseline as the first
        // character the user types.
        let padding = textContainer?.lineFragmentPadding ?? 0
        let originX = textContainerInset.width + padding
        let originY = textContainerInset.height
        let availableWidth = bounds.width - originX - textContainerInset.width - padding
        guard availableWidth > 0 else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let prompt = NSAttributedString(
            string: emptyStatePrompt,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        prompt.draw(in: NSRect(
            x: originX,
            y: originY,
            width: availableWidth,
            height: max(0, bounds.height - originY)
        ))
    }
}
