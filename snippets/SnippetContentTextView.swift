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
