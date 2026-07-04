import AppKit

enum TagColorPalette {
    private static let baseColors: [NSColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemMint,
        .systemTeal,
        .systemCyan,
        .systemBlue,
        .systemIndigo,
        .systemPurple,
        .systemPink,
        .systemBrown
    ]

    private static let colors: [NSColor] = baseColors.map(muted)

    /// Deterministic color for a tag — stable across launches and machines,
    /// so the same tag always renders with the same color (Raycast-style).
    static func color(for tag: String) -> NSColor {
        let key = SnippetTagging.filterKey(for: tag)
        return colors[Int(fnv1aHash(key) % UInt64(colors.count))]
    }

    /// Full-saturation system colors turn a sidebar with many tags into
    /// confetti, so tags render in softened renditions of the same hues:
    /// pastel in dark mode, inky in light mode where text needs to stay
    /// readable against bright backgrounds.
    private static func muted(_ base: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            resolved.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(hue: hue, saturation: saturation * 0.5, brightness: min(brightness, 0.92), alpha: alpha)
                : NSColor(hue: hue, saturation: saturation * 0.65, brightness: brightness * 0.72, alpha: alpha)
        }
    }

    static func swatchImage(for tag: String, diameter: CGFloat = 12) -> NSImage {
        let color = color(for: tag)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

final class TagChipView: NSView {
    enum Style {
        case tinted
        case filled
        case muted
    }

    private let label = NSTextField(labelWithString: "")
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    private var color: NSColor = .secondaryLabelColor
    private var style: Style = .tinted
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            if oldValue != isHovering {
                needsDisplay = true
            }
        }
    }

    var onClick: (() -> Void)? {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    init(fontSize: CGFloat = 10) {
        horizontalPadding = fontSize * 0.7
        verticalPadding = fontSize * 0.25
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding)
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, color: NSColor, style: Style) {
        self.color = color
        self.style = style
        label.stringValue = text
        label.textColor = textColor
        toolTip = text
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    func setAccessibility(label accessibilityLabel: String, isButton: Bool) {
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityRole(isButton ? .button : .staticText)
    }

    private var textColor: NSColor {
        switch style {
        case .tinted:
            return color
        case .filled:
            return Self.contrastingTextColor(on: color)
        case .muted:
            return .secondaryLabelColor
        }
    }

    /// Filled chips sit on the tag color itself, which resolves to a light
    /// pastel in dark mode and a deep tone in light mode — pick the text
    /// color per resolved background luminance.
    private static func contrastingTextColor(on background: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = background
            appearance.performAsCurrentDrawingAppearance {
                resolved = background.usingColorSpace(.sRGB) ?? background
            }
            let luminance = 0.299 * resolved.redComponent
                + 0.587 * resolved.greenComponent
                + 0.114 * resolved.blueComponent
            return luminance > 0.55 ? NSColor.black.withAlphaComponent(0.85) : .white
        }
    }

    private var fillColor: NSColor {
        let hovering = isHovering && onClick != nil
        switch style {
        case .tinted:
            return color.withAlphaComponent(hovering ? 0.22 : 0.13)
        case .filled:
            return color.withAlphaComponent(hovering ? 1.0 : 0.92)
        case .muted:
            return NSColor.secondaryLabelColor.withAlphaComponent(hovering ? 0.2 : 0.12)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        fillColor.setFill()
        path.fill()
    }

    override func resetCursorRects() {
        if onClick != nil {
            addCursorRect(bounds, cursor: .pointingHand)
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
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let onClick else {
            super.mouseUp(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick()
        }
    }

    /// Builds display chips for a snippet's tags, capping at `maxCount` and
    /// appending a "+N" overflow chip when needed.
    static func makeChips(
        for tags: [String],
        maxCount: Int,
        fontSize: CGFloat = 10,
        muted: Bool = false
    ) -> [TagChipView] {
        guard !tags.isEmpty else { return [] }

        var chips: [TagChipView] = tags.prefix(maxCount).map { tag in
            let chip = TagChipView(fontSize: fontSize)
            chip.configure(
                text: tag,
                color: TagColorPalette.color(for: tag),
                style: muted ? .muted : .tinted
            )
            return chip
        }

        if tags.count > maxCount {
            let overflow = TagChipView(fontSize: fontSize)
            overflow.configure(
                text: "+\(tags.count - maxCount)",
                color: .secondaryLabelColor,
                style: .muted
            )
            overflow.toolTip = tags.dropFirst(maxCount).joined(separator: ", ")
            chips.append(overflow)
        }

        return chips
    }
}

/// Lays out chip views left-to-right with wrapping. When `collapsedRowLimit`
/// is set and the chips need more rows, the tail is hidden behind a "+N"
/// toggle chip that expands the view in place.
final class TagFlowView: NSView {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6
    var collapsedRowLimit: Int?

    private var chips: [NSView] = []
    private let toggleChip = TagChipView(fontSize: 11)
    private var isExpanded = false
    private var computedHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        toggleChip.translatesAutoresizingMaskIntoConstraints = true
        toggleChip.autoresizingMask = []
        toggleChip.isHidden = true
        toggleChip.onClick = { [weak self] in
            guard let self else { return }
            isExpanded.toggle()
            needsLayout = true
        }
        addSubview(toggleChip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func setChips(_ newChips: [NSView]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = newChips
        for chip in chips {
            chip.translatesAutoresizingMaskIntoConstraints = true
            chip.autoresizingMask = []
            addSubview(chip)
        }
        needsLayout = true
        layoutFlow()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: computedHeight)
    }

    override func layout() {
        super.layout()
        layoutFlow()
    }

    private func layoutFlow() {
        let width = bounds.width
        guard width > 1 else { return }

        let sizes = chips.map { chip -> NSSize in
            let fitting = chip.fittingSize
            return NSSize(width: min(fitting.width, width), height: fitting.height)
        }
        let rowHeight = sizes.map(\.height).max() ?? 0

        let totalRows = rowCount(for: sizes, width: width)
        let needsToggle = collapsedRowLimit.map { totalRows > $0 } ?? false

        var visibleCount = chips.count
        if needsToggle, !isExpanded, let limit = collapsedRowLimit {
            visibleCount = collapsedVisibleCount(sizes: sizes, width: width, rowLimit: limit)
        }

        if needsToggle {
            let hiddenCount = chips.count - visibleCount
            configureToggle(hiddenCount: hiddenCount)
            toggleChip.isHidden = false
        } else {
            toggleChip.isHidden = true
        }

        var x: CGFloat = 0
        var y: CGFloat = 0
        for (index, chip) in chips.enumerated() {
            guard index < visibleCount else {
                chip.isHidden = true
                continue
            }
            chip.isHidden = false

            let size = sizes[index]
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
            }
            chip.frame = NSRect(x: x, y: y, width: size.width, height: rowHeight)
            x += size.width + horizontalSpacing
        }

        if !toggleChip.isHidden {
            let size = toggleChip.fittingSize
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
            }
            toggleChip.frame = NSRect(x: x, y: y, width: size.width, height: max(rowHeight, size.height))
        }

        let hasContent = !chips.isEmpty || !toggleChip.isHidden
        let newHeight = hasContent ? y + rowHeight : 0
        if abs(newHeight - computedHeight) > 0.5 {
            computedHeight = newHeight
            invalidateIntrinsicContentSize()
        }
    }

    private func rowCount(for sizes: [NSSize], width: CGFloat) -> Int {
        guard !sizes.isEmpty else { return 0 }

        var rows = 1
        var x: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                rows += 1
                x = 0
            }
            x += size.width + horizontalSpacing
        }
        return rows
    }

    private func collapsedVisibleCount(sizes: [NSSize], width: CGFloat, rowLimit: Int) -> Int {
        // Measure the toggle at its widest plausible title so the reserved
        // space never comes up short.
        configureToggle(hiddenCount: chips.count)
        let toggleWidth = toggleChip.fittingSize.width

        var visibleCount = 0
        var row = 1
        var x: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                row += 1
                x = 0
            }
            if row > rowLimit {
                break
            }
            if row == rowLimit, visibleCount < sizes.count - 1 {
                let remainingAfter = width - (x + size.width + horizontalSpacing)
                if remainingAfter < toggleWidth {
                    break
                }
            }
            x += size.width + horizontalSpacing
            visibleCount += 1
        }
        return visibleCount
    }

    private func configureToggle(hiddenCount: Int) {
        let title = isExpanded ? "Less" : "+\(hiddenCount)"
        toggleChip.configure(text: title, color: .secondaryLabelColor, style: .muted)
        toggleChip.toolTip = isExpanded ? "Show fewer tags" : "Show all tags"
        toggleChip.setAccessibility(
            label: isExpanded ? "Show fewer tags" : "Show \(hiddenCount) more tags",
            isButton: true
        )
    }
}

/// Wrapping row of toggleable tag chips used to filter the snippet list,
/// with a leading clear-filters control.
final class TagFilterBarView: NSView {
    struct Item: Equatable {
        let tag: String
        let count: Int
    }

    var onToggleTag: ((String) -> Void)?
    var onClearFilters: (() -> Void)?

    private let clearButton = NSButton()
    private let flow = TagFlowView()
    private var renderedItems: [Item] = []
    private var renderedActiveKeys: Set<String> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.setButtonType(.momentaryChange)
        clearButton.target = self
        clearButton.action = #selector(clearFilters)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        flow.collapsedRowLimit = 2

        addSubview(clearButton)
        addSubview(flow)

        NSLayoutConstraint.activate([
            clearButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            clearButton.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            clearButton.widthAnchor.constraint(equalToConstant: 18),
            clearButton.heightAnchor.constraint(equalToConstant: 18),

            flow.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 6),
            flow.trailingAnchor.constraint(equalTo: trailingAnchor),
            flow.topAnchor.constraint(equalTo: topAnchor),
            flow.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateClearButton(hasActiveFilters: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(items: [Item], activeKeys: Set<String>) {
        guard items != renderedItems || activeKeys != renderedActiveKeys else { return }
        renderedItems = items
        renderedActiveKeys = activeKeys

        let chips = items.map { item -> TagChipView in
            let chip = TagChipView(fontSize: 11)
            let isActive = activeKeys.contains(SnippetTagging.filterKey(for: item.tag))
            chip.configure(
                text: item.tag,
                color: TagColorPalette.color(for: item.tag),
                style: isActive ? .filled : .tinted
            )
            chip.toolTip = filterTooltip(for: item, isActive: isActive)
            chip.setAccessibility(
                label: "Filter by tag \(item.tag), \(isActive ? "on" : "off"), \(item.count) snippet\(item.count == 1 ? "" : "s")",
                isButton: true
            )
            chip.onClick = { [weak self] in
                self?.onToggleTag?(item.tag)
            }
            return chip
        }
        flow.setChips(chips)

        updateClearButton(hasActiveFilters: !activeKeys.isEmpty)
    }

    private func filterTooltip(for item: Item, isActive: Bool) -> String {
        let count = "\(item.count) snippet\(item.count == 1 ? "" : "s")"
        let action = isActive ? "Click to stop filtering by this tag" : "Click to filter by this tag"
        return "\(item.tag) — \(count)\n\(action)"
    }

    private func updateClearButton(hasActiveFilters: Bool) {
        if hasActiveFilters {
            clearButton.image = LiquidGlassDesign.symbol("xmark.circle.fill", pointSize: 12)
            clearButton.contentTintColor = .secondaryLabelColor
            clearButton.isEnabled = true
            clearButton.toolTip = "Clear tag filters"
            clearButton.setAccessibilityLabel("Clear tag filters")
        } else {
            clearButton.image = LiquidGlassDesign.symbol("tag", pointSize: 11)
            clearButton.contentTintColor = .tertiaryLabelColor
            clearButton.isEnabled = false
            clearButton.toolTip = "Filter snippets by tag"
            clearButton.setAccessibilityLabel("Tag filters")
        }
    }

    @objc private func clearFilters() {
        onClearFilters?()
    }
}
