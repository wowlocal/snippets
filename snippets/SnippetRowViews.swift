import AppKit

/// Not file-private: the search overlay's rows carry the same three states and
/// used to draw them with a copy of this class that only knew two.
final class DotView: NSView {
    /// A ring rather than a second fill colour, because the dot has to carry three
    /// states and colour alone cannot. Shape survives dark mode and colour
    /// blindness.
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
        return hasKeyword ? .systemGreen : .systemOrange
    }

    var nameColor: NSColor { isEnabled ? .labelColor : .secondaryLabelColor }

    /// Matches the ring the dot draws for the same state; a disabled snippet
    /// keeps the muted colour because "off" is the failure that applies there.
    var keywordColor: NSColor {
        guard isEnabled else { return .tertiaryLabelColor }
        return hasKeyword ? .secondaryLabelColor : .systemOrange
    }

    var previewColor: NSColor { isEnabled ? .secondaryLabelColor : .tertiaryLabelColor }
}

final class SnippetRowCellView: NSTableCellView {
    private let dotView = DotView()
    private let pinView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let keywordLabel = NSTextField(labelWithString: "")
    private let contentPreviewLabel = NSTextField(labelWithString: "")
    private let tagDotsStack = NSStackView()
    private var status = SnippetRowStatus.unconfigured
    private var renderedTagState: (tags: [String], muted: Bool)?
    private static let maxVisibleTagDots = 6

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
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        tagDotsStack.orientation = .horizontal
        tagDotsStack.spacing = 4
        tagDotsStack.alignment = .centerY
        tagDotsStack.setContentHuggingPriority(.required, for: .horizontal)
        tagDotsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Reserve one indicator column and two fixed text lines. Keeping the
        // preview in the layout even when hidden makes every row share baselines.
        let indicatorContainer = NSView()
        let labelsContainer = NSView()
        for field in [nameLabel, contentPreviewLabel, keywordLabel] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.usesSingleLineMode = true
            field.maximumNumberOfLines = 1
            field.setContentHuggingPriority(.required, for: .vertical)
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            labelsContainer.addSubview(field)
        }
        tagDotsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsContainer.addSubview(tagDotsStack)
        indicatorContainer.addSubview(dotView)
        indicatorContainer.addSubview(pinView)
        for view in [indicatorContainer, labelsContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            indicatorContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            indicatorContainer.widthAnchor.constraint(equalToConstant: 10),
            indicatorContainer.heightAnchor.constraint(equalToConstant: 10),
            indicatorContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            dotView.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
            pinView.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            pinView.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),

            labelsContainer.leadingAnchor.constraint(equalTo: indicatorContainer.trailingAnchor, constant: 8),
            labelsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labelsContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: labelsContainer.leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: labelsContainer.topAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: tagDotsStack.leadingAnchor, constant: -6),
            tagDotsStack.trailingAnchor.constraint(equalTo: labelsContainer.trailingAnchor),
            tagDotsStack.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            contentPreviewLabel.leadingAnchor.constraint(equalTo: labelsContainer.leadingAnchor),
            contentPreviewLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            contentPreviewLabel.bottomAnchor.constraint(equalTo: labelsContainer.bottomAnchor),
            contentPreviewLabel.trailingAnchor.constraint(lessThanOrEqualTo: keywordLabel.leadingAnchor, constant: -8),
            keywordLabel.trailingAnchor.constraint(equalTo: labelsContainer.trailingAnchor),
            keywordLabel.firstBaselineAnchor.constraint(equalTo: contentPreviewLabel.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter isSecure: the row belongs to a vault record. Its `content` is empty
    ///   because the vault hands out shells, so without this the row would render blank
    ///   and read as an unfinished draft rather than as something deliberately hidden.
    func configure(with snippet: Snippet, isSecure: Bool = false) {
        status = SnippetRowStatus(snippet)

        nameLabel.stringValue = snippet.displayName
        keywordLabel.stringValue = status.keywordText
        keywordLabel.isHidden = false

        // A secure snippet arrives here as a shell with empty content, which would
        // otherwise render as a blank row indistinguishable from an unfinished draft.
        // Show that something is deliberately hidden instead.
        if isSecure {
            contentPreviewLabel.stringValue = "••••••••"
            contentPreviewLabel.isHidden = false
        } else {
            // Uncut: the label truncates at the row's own edge, so a count decided
            // up front would leave the "…" mid-row with empty space after it on any
            // sidebar wider than the minimum.
            let preview = snippet.contentFirstLineUntruncated
            contentPreviewLabel.stringValue = preview
            // With no name the title above is already this exact line; printing it
            // twice in one row reads as a rendering bug.
            let hasName = !snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            contentPreviewLabel.isHidden = preview.isEmpty || !hasName
        }

        updateTagDots(tags: snippet.tags, muted: !snippet.isEnabled)

        if snippet.isPinned {
            dotView.isHidden = true
            pinView.isHidden = false
            pinView.contentTintColor = .systemYellow
        } else {
            dotView.isHidden = false
            pinView.isHidden = true
            dotView.style = status.dotStyle
            dotView.color = status.dotColor
        }

        applyTextColors()
    }

    private func updateTagDots(tags: [String], muted: Bool) {
        guard renderedTagState?.tags != tags || renderedTagState?.muted != muted else { return }
        renderedTagState = (tags, muted)

        tagDotsStack.arrangedSubviews.forEach { view in
            tagDotsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let markers = TagDotView.makeMarkers(
            for: tags,
            maxCount: Self.maxVisibleTagDots,
            muted: muted
        )
        markers.forEach(tagDotsStack.addArrangedSubview)
        tagDotsStack.isHidden = markers.isEmpty
    }

    private func applyTextColors() {
        nameLabel.textColor = status.isEnabled ? .labelColor : LibraryRowAppearance.previewText
        keywordLabel.textColor = status.isEnabled && !status.hasKeyword
            ? LibraryRowAppearance.warningText : LibraryRowAppearance.keywordText
        contentPreviewLabel.textColor = LibraryRowAppearance.previewText
        dotView.color = status.isEnabled
            ? (status.hasKeyword ? LibraryRowAppearance.enabledIndicator : LibraryRowAppearance.warningText)
            : status.dotColor
        pinView.contentTintColor = .systemYellow
    }
}

class SnippetTableRowView: NSTableRowView {
    private let highlightView = RowHighlightView(frame: .zero)
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            if oldValue != isHovering {
                updateHighlight()
            }
        }
    }

    /// Horizontal inset of the highlight pill inside the row.
    var highlightHorizontalInset: CGFloat { 5 }

    /// Vertical inset of the highlight pill inside the row.
    var highlightVerticalInset: CGFloat { 1 }

    /// The floating suggestion panel never becomes key, but its selected row still
    /// needs an outline because it has no inactive-window state of its own.
    var drawsSelectionBorderWhenWindowInactive: Bool { false }

    var hoverHighlightOpacity: CGFloat { 1 }

    var usesLibraryAppearance: Bool { true }

    override var isEmphasized: Bool {
        get {
            guard usesLibraryAppearance, let window, window.isKeyWindow,
                  let table = superview as? NSTableView,
                  let responder = window.firstResponder as? NSView else { return false }
            return responder === table || responder.isDescendant(of: table)
        }
        set { updateHighlight() }
    }

    /// With `selectionHighlightStyle = .none` AppKit has no selection of its own to
    /// draw, so redraw explicitly rather than trusting it to dirty the row — the
    /// suggestion panel moves its selection with the arrow keys without reloading.
    override var isSelected: Bool {
        didSet {
            if oldValue != isSelected {
                updateHighlight()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(highlightView, positioned: .below, relativeTo: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowKeyStatusDidChange(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowKeyStatusDidChange(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(self,
            selector: #selector(windowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHighlight()
    }

    override func layout() {
        super.layout()
        highlightView.frame = LiquidGlassDesign.rowHighlightRect(
            in: bounds,
            horizontalInset: highlightHorizontalInset,
            verticalInset: highlightVerticalInset
        )
        updateHighlight()
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

    @objc private func windowKeyStatusDidChange(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        syncHoverWithMouseLocation()
        updateHighlight()
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        updateHighlight()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // The layer-backed highlight subview paints this without the jagged legacy
        // `NSBezierPath.stroke()` edge.
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // The highlight subview paints selection, so AppKit never adds its own
        // full-width bar over the rounded shape.
    }

    private func updateHighlight() {
        let windowIsActive = window?.isKeyWindow != false
        highlightView.alphaValue = isSelected ? 1 : hoverHighlightOpacity
        highlightView.update(
            isSelected: isSelected,
            isHovering: isHovering,
            drawsSelectionBorder: windowIsActive || drawsSelectionBorderWhenWindowInactive,
            usesLibraryAppearance: usesLibraryAppearance,
            isEmphasized: isEmphasized
        )
    }
}

/// Row background for the suggestion panel.
///
/// The panel is a `.nonactivatingPanel` with `becomesKeyOnlyIfNeeded` that is only
/// ever ordered front, so it is never key. AppKit's own selection would therefore
/// paint the unemphasized grey bar — a flat opaque smear across translucent glass.
/// The table runs `selectionHighlightStyle = .none` and this view paints instead.
final class SuggestionTableRowView: SnippetTableRowView {
    override var usesLibraryAppearance: Bool { false }
    override var drawsSelectionBorderWhenWindowInactive: Bool { true }
    override var hoverHighlightOpacity: CGFloat { 0.35 }

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
}
