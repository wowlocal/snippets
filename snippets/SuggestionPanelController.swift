import AppKit

struct SuggestionItem {
    let snippet: Snippet
    let score: Int
}

@MainActor
final class SuggestionPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let tableView: NSTableView
    private let scrollView: NSScrollView
    private(set) var items: [SuggestionItem] = []
    private let maxVisible = 8
    private let rowHeight: CGFloat = 36
    private let panelWidth: CGFloat = 280

	private var maxVisibleRowsOnScreen: Int {
		let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.visibleFrame, false) })
		?? NSScreen.main

		guard let visibleFrame = screen?.visibleFrame else { return 8 }

		// Keep some margin so the panel doesn’t try to fill the whole screen
		let maxHeight = visibleFrame.height * 0.5

		let spacing = tableView.intercellSpacing.height
		let perRow = rowHeight + spacing

		// subtract scroll insets
		let insets = scrollView.contentInsets.top + scrollView.contentInsets.bottom
		let usable = max(0, maxHeight - insets)

		return max(1, Int(floor(usable / perRow)))
	}


    var onSelect: ((Snippet) -> Void)?
    var onDismiss: (() -> Void)?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var anchorRect: NSRect?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 8
        visualEffect.layer?.masksToBounds = true

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.rowHeight = 36
        tableView.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SuggestionColumn"))
        column.width = 280
        tableView.addTableColumn(column)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        visualEffect.frame = panel.contentView!.bounds
        visualEffect.autoresizingMask = [.width, .height]
        panel.contentView!.addSubview(visualEffect)

        scrollView.frame = visualEffect.bounds
        scrollView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(scrollView)

        super.init()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let snippet = items[row].snippet
        onSelect?(snippet)
    }

    var isVisible: Bool { panel.isVisible }

	func show(items: [SuggestionItem]) {
		self.items = items
		tableView.reloadData()

		let count = items.count
		guard count > 0 else { dismiss(); return }

		let visibleCount = min(count, maxVisible)

		// Make sure the table has computed row geometry
		tableView.noteNumberOfRowsChanged()
		tableView.layoutSubtreeIfNeeded()
		scrollView.layoutSubtreeIfNeeded()

		// Compute exact content height using real row rects
		let lastRowIndex = visibleCount - 1
		let lastRowRect = tableView.rect(ofRow: lastRowIndex)

		let insets = scrollView.contentInsets.top + scrollView.contentInsets.bottom
		let safety: CGFloat = 4 // prevents 1-row clipping due to rounding / visual effect view

		let height = lastRowRect.maxY + insets + safety

		panel.setContentSize(NSSize(width: panelWidth, height: height))

		// Position using the anchor from when suggestions first activated.
		// This prevents the panel from jumping as the caret moves.
		if anchorRect == nil {
			anchorRect = caretScreenRect() ?? fallbackCaretRect()
		}
		positionPanelAtAnchor()

		scrollView.hasVerticalScroller = (count > visibleCount)

		if !panel.isVisible {
			panel.orderFront(nil)
			installClickMonitors()
		}
		tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
	}


    /// Temporarily hide the panel (e.g. no results), preserving anchor position.
    func hide() {
        removeClickMonitors()
        panel.orderOut(nil)
        items = []
    }

    /// Fully end the suggestion session — clears anchor so next activation repositions.
    func dismiss() {
        hide()
        anchorRect = nil
    }

    func moveSelectionUp() {
        let current = tableView.selectedRow
        let next = current > 0 ? current - 1 : items.count - 1
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func moveSelectionDown() {
        let current = tableView.selectedRow
        let next = current < items.count - 1 ? current + 1 : 0
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func selectedSnippet() -> Snippet? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row].snippet
    }

    // MARK: - Click-Outside Dismissal

    private func installClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(event)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(event)
            return event
        }
    }

    private func removeClickMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard panel.isVisible else { return }
        let mouseLocation = NSEvent.mouseLocation
        if panel.frame.contains(mouseLocation) { return }
        onDismiss?()
    }

    // MARK: - Positioning

    private func positionPanelAtAnchor() {
        guard let rect = anchorRect else {
            // Last resort: use mouse position
            var origin = mousePosition()
            origin.y -= panel.frame.height + 4
            panel.setFrameOrigin(origin)
            return
        }

        // In AppKit coords: rect.origin is bottom-left, rect.maxY is top.
        // Place panel below the caret line (below rect.origin.y).
        var origin = NSPoint(x: rect.origin.x, y: rect.origin.y - panel.frame.height - 4)

        // Keep on screen
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.visibleFrame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + panelWidth > visible.maxX {
                origin.x = visible.maxX - panelWidth
            }
            if origin.x < visible.minX {
                origin.x = visible.minX
            }
            if origin.y < visible.minY {
                // Show above caret instead
                origin.y = rect.maxY + 4
            }
        }

        panel.setFrameOrigin(origin)
    }

    /// Try to get precise caret rect using AXBoundsForRange.
    private func caretScreenRect() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success else {
            return nil
        }
        let focused = focusedValue as! AXUIElement

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success else {
            return nil
        }

        // Get the CFRange so we can create alternative ranges if needed
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) else {
            return nil
        }

        // Try the selected range first
        if let rect = boundsForRange(of: focused, range: rangeValue!) {
            return rect
        }

        // Zero-length selection may fail in some apps (Safari, etc.)
        // Try a 1-char range ending at the insertion point
        if cfRange.length == 0 && cfRange.location > 0 {
            var altRange = CFRange(location: cfRange.location - 1, length: 1)
            if let altRangeValue = AXValueCreate(.cfRange, &altRange) {
                // This gives us the rect of the character just before the cursor
                return boundsForRange(of: focused, range: altRangeValue as CFTypeRef)
            }
        }

        return nil
    }

    private func boundsForRange(of element: AXUIElement, range: CFTypeRef) -> NSRect? {
        var bounds = CGRect.zero
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsValue) == .success else {
            return nil
        }

        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds) else {
            return nil
        }

        // Reject zero-size rects – some apps return success with garbage data
        guard bounds.width > 0 || bounds.height > 0 else { return nil }

        // Ensure a minimum height so the panel doesn't overlap the text
        if bounds.height < 14 { bounds.size.height = 14 }

        return axRectToAppKit(bounds)
    }

    /// Fallback: use the focused element's own position/size (works in Chrome omnibox, etc.)
    private func fallbackCaretRect() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success else {
            return nil
        }
        let focused = focusedValue as! AXUIElement

        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &posValue) == .success else {
            return nil
        }
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return axRectToAppKit(CGRect(origin: pos, size: size))
    }

    /// Convert an AX rectangle (top-left origin) to an AppKit rect (bottom-left origin).
    private func axRectToAppKit(_ rect: CGRect) -> NSRect? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let screenHeight = primaryScreen.frame.height
        let flippedY = screenHeight - rect.origin.y - rect.size.height
        return NSRect(x: rect.origin.x, y: flippedY, width: rect.size.width, height: rect.size.height)
    }

    private func mousePosition() -> NSPoint {
        NSEvent.mouseLocation
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell: SuggestionCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? SuggestionCellView {
            cell = reused
        } else {
            cell = SuggestionCellView()
            cell.identifier = cellID
        }

        let item = items[row]
        cell.configure(name: item.snippet.displayName, keyword: item.snippet.normalizedKeyword)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight
    }
}

// MARK: - Cell View

private final class SuggestionCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let keywordLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        keywordLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        keywordLabel.textColor = .secondaryLabelColor
        keywordLabel.lineBreakMode = .byTruncatingTail
        keywordLabel.translatesAutoresizingMaskIntoConstraints = false
        keywordLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        keywordLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(nameLabel)
        addSubview(keywordLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            keywordLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            keywordLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            keywordLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, keyword: String) {
        nameLabel.stringValue = name
        keywordLabel.stringValue = keyword
    }
}
