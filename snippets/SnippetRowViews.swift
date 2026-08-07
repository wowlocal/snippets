import AppKit

/// Not file-private: the search overlay's rows carry the same three states and
/// used to draw them with a copy of this class that only knew two.
final class DotView: NSView {
    /// A ring rather than a second fill colour, because the dot has to carry three
    /// states and colour alone cannot: the pale theme collapses `snippetDotColor`,
    /// `pinColor` and `alertColor` all onto `.secondaryLabelColor`, which is also
    /// the disabled fill. Shape survives that, survives dark mode, and survives
    /// colour blindness.
    enum Style {
        case filled
        case ring
    }

    var style: Style = .filled {
        didSet { needsDisplay = true }
    }

    var color: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .filled:
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        case .ring:
            let lineWidth: CGFloat = 2
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()
        }
    }
}

/// Everything a row says about whether a snippet will expand at all.
///
/// `SnippetStore` and `SnippetExpansionEngine` both skip a snippet with no
/// keyword, so "switched off" and "no keyword" are two separate dead states —
/// and a snippet can be in both at once, which is why this keeps the two facts
/// instead of collapsing them into one three-way enum.
///
/// The library list and the search overlay draw this same answer in their own
/// fonts and layouts. Deciding it in one place is what stops them drifting: the
/// overlay carried a transcribed copy of the list's rules and so kept every bug
/// they had long after the list was fixed.
struct SnippetRowStatus {
    let isEnabled: Bool
    let keyword: String

    private init(isEnabled: Bool, keyword: String) {
        self.isEnabled = isEnabled
        self.keyword = keyword
    }

    init(_ snippet: Snippet) {
        self.init(isEnabled: snippet.isEnabled, keyword: snippet.normalizedKeyword)
    }

    /// Stand-in for a cell nothing has configured yet. Only its colours are ever
    /// read, and only if AppKit flips `backgroundStyle` before the first row.
    static let unconfigured = SnippetRowStatus(isEnabled: true, keyword: "")

    var hasKeyword: Bool { !keyword.isEmpty }

    /// Spelled out rather than hidden: a keyword-less snippet never expands, and
    /// a blank slot said nothing about why. It also gives that state a text form —
    /// the dot beside it is a plain view VoiceOver has nothing to say about.
    var keywordText: String { hasKeyword ? "\\\(keyword)" : "No keyword" }

    var dotStyle: DotView.Style { isEnabled && !hasKeyword ? .ring : .filled }

    var dotColor: NSColor {
        guard isEnabled else { return .secondaryLabelColor }
        return hasKeyword ? ThemeManager.snippetDotColor : ThemeManager.alertColor
    }

    var nameColor: NSColor { isEnabled ? .labelColor : .secondaryLabelColor }

    /// Matches the ring the dot draws for the same state; a disabled snippet
    /// keeps the muted colour because "off" is the failure that applies there.
    var keywordColor: NSColor {
        guard isEnabled else { return .tertiaryLabelColor }
        return hasKeyword ? .secondaryLabelColor : ThemeManager.alertColor
    }

    var previewColor: NSColor { isEnabled ? .secondaryLabelColor : .tertiaryLabelColor }
}

final class SnippetRowCellView: NSTableCellView {
    private let dotView = DotView()
    private let pinView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let keywordLabel = NSTextField(labelWithString: "")
    private let contentPreviewLabel = NSTextField(labelWithString: "")
    private let tagChipsStack = NSStackView()
    private var status = SnippetRowStatus.unconfigured
    private var renderedTagState: (tags: [String], muted: Bool)?
    private static let maxVisibleTagChips = 3

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
        contentPreviewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        tagChipsStack.orientation = .horizontal
        tagChipsStack.spacing = 4
        tagChipsStack.alignment = .centerY
        tagChipsStack.setContentHuggingPriority(.required, for: .horizontal)
        tagChipsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let topRow = NSStackView(views: [nameLabel, keywordLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.alignment = .firstBaseline

        let bottomRowSpacer = NSView()
        bottomRowSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let bottomRow = NSStackView(views: [contentPreviewLabel, bottomRowSpacer, tagChipsStack])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 6
        bottomRow.alignment = .centerY

        let labelsStack = NSStackView(views: [topRow, bottomRow])
        labelsStack.orientation = .vertical
        labelsStack.spacing = 2
        labelsStack.alignment = .leading
        bottomRow.widthAnchor.constraint(equalTo: labelsStack.widthAnchor).isActive = true

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
        status = SnippetRowStatus(snippet)

        nameLabel.stringValue = snippet.displayName
        keywordLabel.stringValue = status.keywordText
        keywordLabel.isHidden = false

        let preview = snippet.contentFirstLine
        contentPreviewLabel.stringValue = preview
        // With no name the title above is already this exact line; printing it
        // twice in one row reads as a rendering bug.
        let hasName = !snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        contentPreviewLabel.isHidden = preview.isEmpty || !hasName

        updateTagChips(tags: snippet.tags, muted: !snippet.isEnabled)

        if snippet.isPinned {
            dotView.isHidden = true
            pinView.isHidden = false
            pinView.contentTintColor = ThemeManager.pinColor
        } else {
            dotView.isHidden = false
            pinView.isHidden = true
            dotView.style = status.dotStyle
            dotView.color = status.dotColor
        }

        applyTextColors()
    }

    private func updateTagChips(tags: [String], muted: Bool) {
        guard renderedTagState?.tags != tags || renderedTagState?.muted != muted else { return }
        renderedTagState = (tags, muted)

        tagChipsStack.arrangedSubviews.forEach { view in
            tagChipsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let chips = TagChipView.makeChips(
            for: tags,
            maxCount: Self.maxVisibleTagChips,
            muted: muted
        )
        chips.forEach(tagChipsStack.addArrangedSubview)
        tagChipsStack.isHidden = chips.isEmpty
    }

    private func applyTextColors() {
        nameLabel.textColor = status.nameColor
        keywordLabel.textColor = status.keywordColor
        contentPreviewLabel.textColor = status.previewColor
    }
}

class SnippetTableRowView: NSTableRowView {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            if oldValue != isHovering {
                needsDisplay = true
            }
        }
    }

    /// Horizontal inset of the highlight pill inside the row.
    var highlightHorizontalInset: CGFloat { 5 }

    /// Vertical inset of the highlight pill inside the row.
    var highlightVerticalInset: CGFloat { 1 }

    /// Shape and edge of the highlight pill, split out so a subclass can carry its
    /// own design without reaching into `drawHighlight`, which is private and so
    /// invisible to subclasses even in this file. Every default is the shared
    /// `LiquidGlassDesign` value, so this class draws exactly what it drew before
    /// the hooks existed.
    func highlightRect(in bounds: NSRect) -> NSRect {
        LiquidGlassDesign.rowHighlightRect(
            in: bounds,
            horizontalInset: highlightHorizontalInset,
            verticalInset: highlightVerticalInset
        )
    }

    var highlightCornerRadius: CGFloat {
        LiquidGlassDesign.rowHighlightCornerRadius
    }

    func highlightStrokeColor(isDark: Bool) -> NSColor? {
        LiquidGlassDesign.rowHighlightStrokeColor(isDark: isDark)
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    /// With `selectionHighlightStyle = .none` AppKit has no selection of its own to
    /// draw, so redraw explicitly rather than trusting it to dirty the row — the
    /// suggestion panel moves its selection with the arrow keys without reloading.
    override var isSelected: Bool {
        didSet {
            if oldValue != isSelected {
                needsDisplay = true
            }
        }
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
        guard isSelected || isHovering else { return }
        drawHighlight(isSelected: isSelected)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Selection is drawn in drawBackground so hover and selected states share the same footprint.
    }

    private func drawHighlight(isSelected: Bool) {
        let path = NSBezierPath(
            roundedRect: highlightRect(in: bounds),
            xRadius: highlightCornerRadius,
            yRadius: highlightCornerRadius
        )
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = LiquidGlassDesign.rowHighlightFillColor(isSelected: isSelected, isDark: isDark)
        color.setFill()
        path.fill()

        if isSelected, let strokeColor = highlightStrokeColor(isDark: isDark) {
            strokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Row background for the suggestion panel.
///
/// The panel is a `.nonactivatingPanel` with `becomesKeyOnlyIfNeeded` that is only
/// ever ordered front, so it is never key. AppKit's own selection would therefore
/// paint the unemphasized grey bar — a flat opaque smear across translucent glass.
/// The table runs `selectionHighlightStyle = .none` and this view paints instead.
final class SuggestionTableRowView: SnippetTableRowView {
    /// Concentric with the glass surface: the pill's corner arc and the panel's
    /// share a centre, so the gap around the pill is even on every side.
    override var highlightHorizontalInset: CGFloat {
        LiquidGlassDesign.Metrics.concentricRowInset
    }

    /// Row rects tile contiguously and carry half of `intercellSpacing.height`
    /// above and below their cell, so half the spacing lands the pill exactly on
    /// the cell frame and leaves a full-spacing gap between neighbouring pills.
    override var highlightVerticalInset: CGFloat {
        let spacing = (superview as? NSTableView)?.intercellSpacing.height ?? 4
        return max(1, spacing / 2)
    }

    /// The shared helper floors the pre-26 insets at 10/7, which suits a row inside
    /// one of our windows but throws both insets above away — pre-26 the panel drew
    /// a 300x36 pill in a 320x50 row, and none of its own tuning reached the screen.
    override func highlightRect(in bounds: NSRect) -> NSRect {
        LiquidGlassDesign.floatingPanelRowHighlightRect(
            in: bounds,
            horizontalInset: highlightHorizontalInset,
            verticalInset: highlightVerticalInset
        )
    }

    override var highlightCornerRadius: CGFloat {
        LiquidGlassDesign.floatingPanelRowHighlightCornerRadius
    }

    override func highlightStrokeColor(isDark: Bool) -> NSColor? {
        LiquidGlassDesign.floatingPanelRowHighlightStrokeColor(isDark: isDark)
    }
}
