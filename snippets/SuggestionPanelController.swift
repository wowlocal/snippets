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

    var onSelect: ((Snippet) -> Void)?

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
    }

    var isVisible: Bool { panel.isVisible }

    func show(items: [SuggestionItem]) {
        self.items = items
        tableView.reloadData()

        let visibleCount = min(items.count, maxVisible)
        guard visibleCount > 0 else {
            dismiss()
            return
        }

        let intercell: CGFloat = 2
        let height = CGFloat(visibleCount) * (rowHeight + intercell) + 12 // +12 for content insets
        panel.setContentSize(NSSize(width: panelWidth, height: height))

        positionPanel()

        if !panel.isVisible {
            panel.orderFront(nil)
        }

        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func dismiss() {
        panel.orderOut(nil)
        items = []
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

    // MARK: - Positioning

    private func positionPanel() {
        var origin = caretScreenPosition() ?? mousePosition()

        // Place panel below the caret
        origin.y -= panel.frame.height + 4

        // Keep on screen
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(origin, $0.visibleFrame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + panelWidth > visible.maxX {
                origin.x = visible.maxX - panelWidth
            }
            if origin.x < visible.minX {
                origin.x = visible.minX
            }
            if origin.y < visible.minY {
                // Show above caret instead
                origin.y += panel.frame.height + 8 + 20
            }
        }

        panel.setFrameOrigin(origin)
    }

    private func caretScreenPosition() -> NSPoint? {
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

        var bounds = CGRect.zero
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue!, &boundsValue) == .success else {
            return nil
        }

        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds) else {
            return nil
        }

        // AX coordinates have origin at top-left of main screen; convert to bottom-left
        guard let mainScreen = NSScreen.main else { return nil }
        let screenHeight = mainScreen.frame.height
        let flippedY = screenHeight - bounds.origin.y - bounds.size.height

        return NSPoint(x: bounds.origin.x, y: flippedY)
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
