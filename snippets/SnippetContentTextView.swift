import AppKit

/// The snippet content editor. `NSTextView` has no placeholder of its own, and
/// the prompt must never become real text: it would be stored, exported and
/// expanded. So it is drawn, not inserted — `string` stays empty the whole time
/// the prompt is on screen.
///
/// "Placeholder" already means a `{clipboard}`-style token everywhere else in
/// this app, hence `emptyStatePrompt`.
final class SnippetContentTextView: NSTextView {
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
        needsDisplay = true
    }

    /// Typing `{` offers the placeholder tokens, which is what replaced the
    /// permanent list of them that used to sit under this box. An action at the
    /// point of need rather than a line to read and transcribe.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)

        let inserted = (string as? String) ?? (string as? NSAttributedString)?.string
        guard inserted == "{", isEditable else { return }

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

    private static let tokenBoundaryCharacters = CharacterSet(charactersIn: "{}\n")
    private static let maximumTokenCompletionLength = 24

    override func draw(_ dirtyRect: NSRect) {
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
