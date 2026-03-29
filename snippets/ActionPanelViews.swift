import AppKit

extension NSFont {
    static func actionPanelRoundedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = baseFont.fontDescriptor.withDesign(.rounded),
              let roundedFont = NSFont(descriptor: descriptor, size: size) else {
            return baseFont
        }
        return roundedFont
    }
}

final class ActionOverlayView: NSView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

final class ActionShortcutRow: NSView {
    private let titleField = NSTextField(labelWithString: "")

    init(title: String, shortcut: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleField.stringValue = title
        titleField.font = .actionPanelRoundedSystemFont(ofSize: 14, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        let shortcutField = NSTextField(labelWithString: shortcut)
        shortcutField.font = .systemFont(ofSize: 14, weight: .medium)
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.alignment = .right
        shortcutField.setContentHuggingPriority(.required, for: .horizontal)
        shortcutField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [titleField, NSView(), shortcutField])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) {
        titleField.stringValue = title
    }
}
