import AppKit
import QuickLookUI

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

    /// Arms the protected rendering path before the caller puts decrypted text in
    /// `NSTextStorage`. This first presents an opaque protected redaction frame and
    /// suppresses every AppKit text/caret/selection draw primitive.
    @discardableResult
    func setSecurePresentationEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard secureCapturePolicy.phase == .ordinary else {
                return secureCapturePolicy.phase != .failedClosed
            }
            secureCapturePolicy.arm()
            guard secureCaptureRenderer.arm() else {
                secureCapturePolicy.failClosed()
                return false
            }
            needsDisplay = true
            return true
        }

        // Plaintext must be gone before ordinary AppKit drawing can be restored.
        assert(super.string.isEmpty, "Clear secure plaintext before disabling capture protection")
        guard super.string.isEmpty else {
            secureCaptureRenderer.failClosed()
            return false
        }
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
        string = ""
        return setSecurePresentationEnabled(false)
    }

    /// Controls protected pixels only; it does not unlock the vault or restore
    /// ordinary AppKit drawing. Hover policy can safely call this independently.
    @discardableResult
    func setSecurePixelsVisible(_ visible: Bool) -> Bool {
        guard secureCapturePolicy.permitsPlaintextInTextStorage else { return false }
        secureCapturePolicy.setPlaintextPixelsVisible(visible)
        return visible
            ? secureCaptureRenderer.renderPlaintext()
            : secureCaptureRenderer.renderRedaction()
    }

    func refreshSecurePresentation() {
        secureCaptureRenderer.invalidate()
    }

    func setSecureCaptureFailureHandler(_ handler: @escaping () -> Void) {
        secureCaptureRenderer.onFailure = handler
    }

    func secureCaptureRendererDidFail() {
        secureCapturePolicy.failClosed()
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

    var secureCaptureObservesScrollForInspection: Bool {
        secureCaptureRenderer.observesScrollForInspection
    }

    var emptyStatePrompt: String = "" {
        didSet { needsDisplay = true }
    }

    /// Assigning `string` replaces the text without going through
    /// `didChangeText()`, and `applySnippetToEditor` is exactly that path, so
    /// the prompt would otherwise survive selecting a snippet that has content.
    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            if secureCapturePolicy.suppressesUnprotectedDrawing {
                secureCaptureRenderer.invalidate()
            }
            needsDisplay = true
        }
    }

    /// With no snippet selected the editor is disabled and empty; "Paste or
    /// type…" would be inviting the user to do something the view refuses.
    override var isEditable: Bool {
        didSet { needsDisplay = true }
    }

    override func didChangeText() {
        super.didChangeText()
        secureCaptureRenderer.invalidate()
        needsDisplay = true
    }

    // MARK: - Secure plaintext containment

    /// AppKit reaches the pasteboard through several different public entry
    /// points (Edit menu, Services, dragging, and callers invoking these methods
    /// directly). Every one is guarded; hiding Copy in a menu is not a boundary.
    override func copy(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.cut(sender)
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
        secureCaptureRenderer.invalidate()
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        guard !secureCapturePolicy.suppressesUnprotectedDrawing else {
            secureCaptureRenderer.invalidate()
            return
        }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        secureCaptureRenderer.invalidate()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        secureCaptureRenderer.invalidate()
    }

    override func scroll(_ point: NSPoint) {
        super.scroll(point)
        secureCaptureRenderer.invalidate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        secureCaptureRenderer.invalidate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        secureCaptureRenderer.invalidate()
    }

    /// Typing `{` offers the placeholder tokens, which is what replaced the
    /// permanent list of them that used to sit under this box. An action at the
    /// point of need rather than a line to read and transcribe.
    override func insertText(_ string: Any, replacementRange: NSRange) {
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
