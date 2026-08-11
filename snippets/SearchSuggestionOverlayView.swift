import AppKit

final class SearchSuggestionOverlayView: NSView {
    private let stackView = NSStackView()
    private var rowViews: [SearchSuggestionRowView] = []
    private var snippets: [Snippet] = []
    private var selectedIndex: Int?
    private let maxVisibleRows = 8
    private let rowHeight: CGFloat = 58
    private let verticalInset: CGFloat = 6

    var onSelect: ((Snippet) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -8)

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = true
        contentView.addSubview(stackView)

        let surface = LiquidGlassDesign.makeTransientSurface(
            containing: contentView,
            cornerRadius: 14,
            fallbackMaterial: .popover,
            tintColor: NSColor.darkGray.withAlphaComponent(0.1)
        )
        addSubview(surface)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: verticalInset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snippets: [Snippet], selectedSnippetID: UUID?) {
        self.snippets = Array(snippets.prefix(maxVisibleRows))
        rebuildRows()
        selectSnippet(id: selectedSnippetID)
    }

    func preferredHeight(maxHeight: CGFloat) -> CGFloat {
        let count = min(snippets.count, maxVisibleRows)
        guard count > 0 else { return 0 }

        let contentHeight = (CGFloat(count) * rowHeight) + (verticalInset * 2)
        return min(contentHeight, maxHeight)
    }

    func containsFirstResponder(in window: NSWindow?) -> Bool {
        guard let firstResponder = window?.firstResponder as? NSView else { return false }
        return firstResponder.isDescendant(of: self)
    }

    func moveSelectionDown() {
        guard !snippets.isEmpty else { return }
        let current = selectedIndex ?? -1
        let next = current >= 0 && current < snippets.count - 1 ? current + 1 : 0
        selectRow(next)
    }

    func moveSelectionUp() {
        guard !snippets.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = current > 0 ? current - 1 : snippets.count - 1
        selectRow(next)
    }

    func selectedSnippet() -> Snippet? {
        guard let selectedIndex, snippets.indices.contains(selectedIndex) else { return nil }
        return snippets[selectedIndex]
    }

    private func rebuildRows() {
        rowViews.forEach { rowView in
            stackView.removeArrangedSubview(rowView)
            rowView.removeFromSuperview()
        }

        rowViews = snippets.enumerated().map { index, snippet in
            let rowView = SearchSuggestionRowView()
            rowView.configure(with: snippet)
            rowView.onClick = { [weak self] in
                guard let self, snippets.indices.contains(index) else { return }
                selectRow(index)
                onSelect?(snippets[index])
            }
            stackView.addArrangedSubview(rowView)
            NSLayoutConstraint.activate([
                rowView.heightAnchor.constraint(equalToConstant: rowHeight),
                rowView.widthAnchor.constraint(equalTo: stackView.widthAnchor)
            ])
            return rowView
        }
    }

    private func selectSnippet(id: UUID?) {
        if let id, let row = snippets.firstIndex(where: { $0.id == id }) {
            selectRow(row)
        } else if !snippets.isEmpty {
            selectRow(0)
        } else {
            selectedIndex = nil
            updateSelection()
        }
    }

    private func selectRow(_ row: Int) {
        guard snippets.indices.contains(row) else { return }
        selectedIndex = row
        updateSelection()
    }

    private func updateSelection() {
        for (index, rowView) in rowViews.enumerated() {
            rowView.isSelected = index == selectedIndex
        }
    }
}

private final class SearchSuggestionRowView: NSView {
    private let highlightView = RowHighlightView(frame: .zero)
    private let dotView = DotView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let keywordLabel = NSTextField(labelWithString: "")
    private let contentPreviewLabel = NSTextField(labelWithString: "")
    private let tagChipsStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var status = SnippetRowStatus.unconfigured
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            updateHighlight()
        }
    }

    var onClick: (() -> Void)?

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateHighlight()
            applyTextColors()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.setContentHuggingPriority(.required, for: .horizontal)
        dotView.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        keywordLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        keywordLabel.lineBreakMode = .byTruncatingTail
        keywordLabel.maximumNumberOfLines = 1
        keywordLabel.translatesAutoresizingMaskIntoConstraints = false
        keywordLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        keywordLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentPreviewLabel.font = .systemFont(ofSize: 13, weight: .medium)
        contentPreviewLabel.lineBreakMode = .byTruncatingTail
        contentPreviewLabel.maximumNumberOfLines = 1
        contentPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        contentPreviewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentPreviewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tagChipsStack.orientation = .horizontal
        tagChipsStack.spacing = 4
        tagChipsStack.alignment = .centerY
        tagChipsStack.translatesAutoresizingMaskIntoConstraints = false
        tagChipsStack.setContentHuggingPriority(.required, for: .horizontal)
        tagChipsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        [highlightView, dotView, nameLabel, keywordLabel, tagChipsStack, contentPreviewLabel].forEach(addSubview)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 10),
            dotView.heightAnchor.constraint(equalToConstant: 10),

            nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            keywordLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            keywordLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            keywordLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            tagChipsStack.leadingAnchor.constraint(greaterThanOrEqualTo: keywordLabel.trailingAnchor, constant: 8),
            tagChipsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            tagChipsStack.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            contentPreviewLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            contentPreviewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            contentPreviewLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            contentPreviewLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func layout() {
        super.layout()
        highlightView.frame = LiquidGlassDesign.rowHighlightRect(
            in: bounds,
            horizontalInset: 8,
            verticalInset: 3
        )
    }

    private func updateHighlight() {
        highlightView.update(isSelected: isSelected, isHovering: isHovering)
    }

    func configure(with snippet: Snippet) {
        status = SnippetRowStatus(snippet)

        nameLabel.stringValue = snippet.displayName
        // Monospaced only when there is something to type: this slot is otherwise
        // reserved for literal keywords, and "No keyword" is not one of them.
        keywordLabel.font = status.hasKeyword
            ? .monospacedSystemFont(ofSize: 12, weight: .medium)
            : .systemFont(ofSize: 12, weight: .medium)
        keywordLabel.stringValue = status.keywordText
        keywordLabel.isHidden = false

        let preview = snippet.contentFirstLine
        contentPreviewLabel.stringValue = preview
        // With no name the title above is already this exact line; printing it
        // twice in one row reads as a rendering bug.
        let hasName = !snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        contentPreviewLabel.isHidden = preview.isEmpty || !hasName

        dotView.style = status.dotStyle
        dotView.color = status.dotColor

        tagChipsStack.arrangedSubviews.forEach { view in
            tagChipsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let chips = TagChipView.makeChips(
            for: snippet.tags,
            maxCount: 3,
            muted: !snippet.isEnabled
        )
        chips.forEach(tagChipsStack.addArrangedSubview)
        tagChipsStack.isHidden = chips.isEmpty

        applyTextColors()
    }

    private func applyTextColors() {
        nameLabel.textColor = status.nameColor
        keywordLabel.textColor = status.keywordColor
        contentPreviewLabel.textColor = status.previewColor
    }
}
