import AppKit

/// A text field that wraps and grows to fit its text, or its placeholder while empty,
/// instead of scrolling a long value such as a repository address out of sight. Give it
/// a width; it supplies its own height, re-measured as the user types.
final class GrowingTextField: NSTextField {
    private var measuredWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        usesSingleLineMode = false
        maximumNumberOfLines = 0
        lineBreakMode = .byCharWrapping
        cell?.wraps = true
        cell?.isScrollable = false
    }

    override var intrinsicContentSize: NSSize {
        guard let cell = cell?.copy() as? NSTextFieldCell, bounds.width > 0 else {
            return super.intrinsicContentSize
        }
        // While editing, the field editor holds the live text.
        let text = currentEditor()?.string ?? stringValue
        cell.stringValue = text.isEmpty ? (placeholderString ?? "") : text
        let fitting = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude))
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(fitting.height))
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }

    override var stringValue: String {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        // The height depends on the width, which is known only after layout.
        if abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
