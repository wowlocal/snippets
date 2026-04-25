import AppKit

private final class DotView: NSView {
    var color: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

final class SnippetRowCellView: NSTableCellView {
    private let dotView = DotView()
    private let pinView = NSImageView()
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

        dotView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 10),
            dotView.heightAnchor.constraint(equalToConstant: 10),
        ])

        pinView.translatesAutoresizingMaskIntoConstraints = false
        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinView.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        NSLayoutConstraint.activate([
            pinView.widthAnchor.constraint(equalToConstant: 10),
            pinView.heightAnchor.constraint(equalToConstant: 10),
        ])

        let topRow = NSStackView(views: [nameLabel, keywordLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.alignment = .firstBaseline

        let labelsStack = NSStackView(views: [topRow, contentPreviewLabel])
        labelsStack.orientation = .vertical
        labelsStack.spacing = 2
        labelsStack.alignment = .leading

        let rootStack = NSStackView(views: [dotView, pinView, labelsStack])
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
        keywordLabel.stringValue = keyword.isEmpty ? "" : "\\\(keyword)"
        keywordLabel.isHidden = keyword.isEmpty

        let preview = snippet.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
        contentPreviewLabel.stringValue = preview
        contentPreviewLabel.isHidden = preview.isEmpty

        if snippet.isPinned {
            dotView.isHidden = true
            pinView.isHidden = false
            pinView.contentTintColor = ThemeManager.pinColor
        } else {
            dotView.isHidden = false
            pinView.isHidden = true
            dotView.color = snippet.isEnabled ? ThemeManager.snippetDotColor : .secondaryLabelColor
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
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            if oldValue != isHovering {
                needsDisplay = true
            }
        }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        hoverTrackingArea = nextTrackingArea

        syncHoverWithMouseLocation()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovering = false
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func syncHoverWithMouseLocation() {
        guard let window, window.isKeyWindow else {
            isHovering = false
            return
        }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInView = convert(mouseInWindow, from: nil)
        isHovering = bounds.contains(mouseInView)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)

        guard isHovering, !isSelected else { return }

        let hoverRect = bounds.insetBy(dx: 5, dy: 1)
        let path = NSBezierPath(
            roundedRect: hoverRect,
            xRadius: LiquidGlassDesign.Metrics.rowCornerRadius,
            yRadius: LiquidGlassDesign.Metrics.rowCornerRadius
        )
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.black.withAlphaComponent(0.035)
        color.setFill()
        path.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 5, dy: 1)
        let path = NSBezierPath(
            roundedRect: selectionRect,
            xRadius: LiquidGlassDesign.Metrics.rowCornerRadius,
            yRadius: LiquidGlassDesign.Metrics.rowCornerRadius
        )
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark
            ? NSColor.white.withAlphaComponent(0.13)
            : NSColor.controlAccentColor.withAlphaComponent(0.11)
        color.setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(isDark ? 0.20 : 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
