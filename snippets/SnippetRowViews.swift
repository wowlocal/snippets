import AppKit

final class SnippetRowCellView: NSTableCellView {
    private let indicatorView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let keywordLabel = NSTextField(labelWithString: "")
    private let contentPreviewLabel = NSTextField(labelWithString: "")
    private var isDisabledSnippet = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            applyTextColors()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        keywordLabel.font = .systemFont(ofSize: 11, weight: .medium)
        keywordLabel.lineBreakMode = .byTruncatingTail
        keywordLabel.setContentHuggingPriority(.required, for: .horizontal)
        keywordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentPreviewLabel.font = .systemFont(ofSize: 12)
        contentPreviewLabel.lineBreakMode = .byTruncatingTail
        contentPreviewLabel.maximumNumberOfLines = 1

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.widthAnchor.constraint(equalToConstant: 10).isActive = true
        indicatorView.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let topRow = NSStackView(views: [nameLabel, keywordLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.alignment = .firstBaseline

        let labelsStack = NSStackView(views: [topRow, contentPreviewLabel])
        labelsStack.orientation = .vertical
        labelsStack.spacing = 2
        labelsStack.alignment = .leading

        let rootStack = NSStackView(views: [indicatorView, labelsStack])
        rootStack.orientation = .horizontal
        rootStack.spacing = 8
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
        isDisabledSnippet = !snippet.isEnabled

        nameLabel.stringValue = snippet.displayName

        let keyword = snippet.normalizedKeyword
        keywordLabel.stringValue = keyword
        keywordLabel.isHidden = keyword.isEmpty

        let preview = snippet.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
        contentPreviewLabel.stringValue = preview
        contentPreviewLabel.isHidden = preview.isEmpty

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
        if isDisabledSnippet {
            nameLabel.textColor = .secondaryLabelColor
            keywordLabel.textColor = .tertiaryLabelColor
            contentPreviewLabel.textColor = .tertiaryLabelColor
        } else {
            nameLabel.textColor = .labelColor
            keywordLabel.textColor = .secondaryLabelColor
            contentPreviewLabel.textColor = .tertiaryLabelColor
        }
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
