import AppKit

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
        wantsLayer = true
        layer?.cornerRadius = 6

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 14, weight: .medium)
        let shortcutField = NSTextField(labelWithString: shortcut)
        shortcutField.font = .systemFont(ofSize: 14, weight: .regular)
        shortcutField.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [titleField, NSView(), shortcutField])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
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
