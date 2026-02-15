import AppKit

final class SnippetRowCellView: NSTableCellView {
    private let indicatorView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let keywordLabel = NSTextField(labelWithString: "")
    private var isSelectedStyle = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            isSelectedStyle = backgroundStyle == .emphasized
            applyTextColors()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        keywordLabel.font = .systemFont(ofSize: 12)
        keywordLabel.lineBreakMode = .byTruncatingTail

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        indicatorView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let labelsStack = NSStackView(views: [nameLabel, keywordLabel])
        labelsStack.orientation = .vertical
        labelsStack.spacing = 2

        let rootStack = NSStackView(views: [indicatorView, labelsStack])
        rootStack.orientation = .horizontal
        rootStack.spacing = 10
        rootStack.alignment = .centerY
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with snippet: Snippet) {
        nameLabel.stringValue = snippet.displayName
        keywordLabel.stringValue = snippet.normalizedKeyword

        if snippet.isPinned {
            indicatorView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
            indicatorView.contentTintColor = .systemYellow
        } else {
            indicatorView.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            indicatorView.contentTintColor = snippet.isEnabled ? .systemGreen : .secondaryLabelColor
        }

        applyTextColors()
    }

    private func applyTextColors() {
        nameLabel.textColor = .labelColor
        keywordLabel.textColor = .secondaryLabelColor
    }
}

final class SnippetTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.10).setFill()
        path.fill()
    }
}
