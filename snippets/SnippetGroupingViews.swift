import AppKit

final class GroupFilterButton: NSButton {
    var filter: SnippetGroupFilter = .all

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.toggle)
        bezelStyle = .rounded
        controlSize = .small
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PillLabelView: NSView {
    private let textField = NSTextField(labelWithString: "")

    var stringValue: String {
        get { textField.stringValue }
        set {
            textField.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    var backgroundColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.12) {
        didSet {
            layer?.backgroundColor = backgroundColor.cgColor
        }
    }

    var textColor: NSColor = .secondaryLabelColor {
        didSet {
            textField.textColor = textColor
        }
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = textField.intrinsicContentSize
        return NSSize(width: labelSize.width + 12, height: max(18, labelSize.height + 4))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = backgroundColor.cgColor

        textField.font = .systemFont(ofSize: 11, weight: .medium)
        textField.textColor = textColor
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
