import AppKit

struct SuggestionItem {
    let snippet: Snippet
    let score: Int
    let nameMatchRanges: [NSRange]
    let keywordMatchRanges: [NSRange]

    init(
        snippet: Snippet,
        score: Int,
        nameMatchRanges: [NSRange] = [],
        keywordMatchRanges: [NSRange] = []
    ) {
        self.snippet = snippet
        self.score = score
        self.nameMatchRanges = nameMatchRanges
        self.keywordMatchRanges = keywordMatchRanges
    }
}

@MainActor
final class SuggestionPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let tableView: NSTableView
    private let scrollView: NSScrollView
    private(set) var items: [SuggestionItem] = []
    private let maxVisible = 8
    private let singleLineRowHeight: CGFloat = 46
    private let wrappedNameRowHeight: CGFloat = 62
    private let panelWidth: CGFloat = 280
    private let horizontalCellPadding: CGFloat = 20

    private var maxVisibleRowsOnScreen: Int {
        let anchorPoint = anchorRect.map { NSPoint(x: $0.midX, y: $0.midY) }
        let screen = (anchorPoint.flatMap { screenContaining(point: $0) })
            ?? screenContaining(point: NSEvent.mouseLocation)
            ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else { return 8 }

        // Keep some margin so the panel doesn't try to fill the whole screen.
        let maxHeight = visibleFrame.height * 0.5

        let spacing = tableView.intercellSpacing.height
        let perRow = wrappedNameRowHeight + spacing

        // Subtract scroll insets.
        let insets = scrollView.contentInsets.top + scrollView.contentInsets.bottom
        let usable = max(0, maxHeight - insets)

        return max(1, Int(floor(usable / perRow)))
    }

    var onSelect: ((Snippet) -> Void)?
    var onDismiss: (() -> Void)?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var anchorRect: NSRect?
    private var accessibilityPrimedPIDs: Set<pid_t> = []
    private var enhancedAccessibilityPrimedPIDs: Set<pid_t> = []

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
        tableView.rowHeight = singleLineRowHeight
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

        let visibleCount = min(count, maxVisible, maxVisibleRowsOnScreen)

        // Make sure the table has computed row geometry.
        tableView.noteNumberOfRowsChanged()
        tableView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        // Compute exact content height using real row rects.
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

    func resetAccessibilityPrimingCache() {
        accessibilityPrimedPIDs.removeAll()
        enhancedAccessibilityPrimedPIDs.removeAll()
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

        // Keep on screen.
        if let screen = screenContaining(point: NSPoint(x: rect.midX, y: rect.midY)) ?? NSScreen.main {
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
        guard let focused = frontmostFocusedElement() else { return nil }

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
            return normalizedAnchorRect(for: rect, focusedElement: focused)
        }

        // Zero-length selection may fail in some apps (Safari, etc.)
        // Try a 1-char range ending at the insertion point
        if cfRange.length == 0 && cfRange.location > 0 {
            var altRange = CFRange(location: cfRange.location - 1, length: 1)
            if let altRangeValue = AXValueCreate(.cfRange, &altRange) {
                // This gives us the rect of the character just before the cursor
                if let rect = boundsForRange(of: focused, range: altRangeValue as CFTypeRef) {
                    return normalizedAnchorRect(for: rect, focusedElement: focused)
                }
            }
        }

        return nil
    }

    /// Some native single-line fields report a caret line rect that sits inside the control.
    /// Keep caret X, but anchor vertically to the control's bottom so the panel appears below it.
    private func normalizedAnchorRect(for caretRect: NSRect, focusedElement: AXUIElement) -> NSRect {
        guard let role = stringAttribute(of: focusedElement, attribute: kAXRoleAttribute as CFString) else {
            return caretRect
        }

        guard let controlRect = preferredControlRect(for: focusedElement, caretRect: caretRect) ?? elementScreenRect(of: focusedElement) else {
            return caretRect
        }

        let isSingleLineRole = role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String)
        let isShortTextArea = role == (kAXTextAreaRole as String) && controlRect.height <= 56
        // Safari exposes nested AX elements in the address bar; allow this path for those
        // text-like roles so we can anchor below the containing control instead of line rect.
        let isSafariTextInput = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
            && (role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String) || role == (kAXTextAreaRole as String))
            && controlRect.height <= 90
        guard isSingleLineRole || isShortTextArea || isSafariTextInput else { return caretRect }

        guard controlRect.insetBy(dx: -2, dy: -2).intersects(caretRect) else { return caretRect }

        var adjusted = caretRect
        adjusted.origin.y = controlRect.minY
        adjusted.size.height = max(caretRect.height, controlRect.height)
        return adjusted
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
        guard let focused = frontmostFocusedElement() else { return nil }

        return elementScreenRect(of: focused)
    }

    /// Convert an AX rectangle (top-left origin) to an AppKit rect (bottom-left origin).
    private func axRectToAppKit(_ rect: CGRect) -> NSRect? {
        let flippedFromAX = convertedAXTopLeftRect(rect)
        if intersectsAnyScreen(flippedFromAX) {
            return flippedFromAX
        }

        // Some Chromium/Electron fields report AppKit-style global coordinates.
        let appKitAsIs = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
        if intersectsAnyScreen(appKitAsIs) {
            return appKitAsIs
        }

        // Keep previous behavior as the final fallback.
        return flippedFromAX
    }

    private func convertedAXTopLeftRect(_ rect: CGRect) -> NSRect {
        let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let flippedY = screenHeight - rect.origin.y - rect.size.height
        return NSRect(x: rect.origin.x, y: flippedY, width: rect.size.width, height: rect.size.height)
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        if let frameMatch = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) {
            return frameMatch
        }
        return NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(point) })
    }

    private func intersectsAnyScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.insetBy(dx: -1, dy: -1).intersects(rect)
        }
    }

    private func mousePosition() -> NSPoint {
        NSEvent.mouseLocation
    }

    private func frontmostFocusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        primeAccessibilityIfNeeded(for: app)

        if let focused = copyFocusedElement(from: app) {
            return deepestFocusedElement(startingAt: focused, maxDepth: 4)
        }

        // Retry once after forcing manual accessibility attributes for Chromium/Electron.
        primeAccessibilityIfNeeded(for: app, force: true)
        guard let focused = copyFocusedElement(from: app) else {
            return nil
        }
        return deepestFocusedElement(startingAt: focused, maxDepth: 4)
    }

    private func copyFocusedElement(from app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedValue as! AXUIElement)
    }

    private func deepestFocusedElement(startingAt root: AXUIElement, maxDepth: Int) -> AXUIElement {
        var current = root

        for _ in 0..<maxDepth {
            var nestedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXFocusedUIElementAttribute as CFString, &nestedValue) == .success,
                  let nestedValue,
                  CFGetTypeID(nestedValue) == AXUIElementGetTypeID() else {
                break
            }

            let nested = nestedValue as! AXUIElement
            if CFEqual(current, nested) {
                break
            }

            current = nested
        }

        return current
    }

    private func stringAttribute(of element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func elementScreenRect(of element: AXUIElement) -> NSRect? {
        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success else {
            return nil
        }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else {
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

    /// Walk up AX parents and pick the smallest plausible input control that still contains the caret.
    /// This avoids anchoring to Safari's inner text node, which can place the panel over typed text.
    private func preferredControlRect(for focusedElement: AXUIElement, caretRect: NSRect) -> NSRect? {
        let candidates = inputHierarchy(startingAt: focusedElement, maxDepth: 6).compactMap { element -> NSRect? in
            guard let rect = elementScreenRect(of: element) else { return nil }
            guard rect.width >= 40, rect.height >= 16, rect.height <= 90 else { return nil }
            guard rect.insetBy(dx: -2, dy: -2).intersects(caretRect) else { return nil }
            return rect
        }

        guard !candidates.isEmpty else { return nil }

        // Prefer a control box larger than the raw caret line when available.
        if let expanded = candidates
            .filter({ $0.height > caretRect.height + 4 })
            .min(by: { rectArea($0) < rectArea($1) }) {
            return expanded
        }

        return candidates.min(by: { rectArea($0) < rectArea($1) })
    }

    private func inputHierarchy(startingAt element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        var elements: [AXUIElement] = [element]
        var current = element

        for _ in 0..<maxDepth {
            guard let parent = parentElement(of: current) else { break }
            elements.append(parent)
            current = parent
        }

        return elements
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func rectArea(_ rect: NSRect) -> CGFloat {
        rect.width * rect.height
    }

    private func primeAccessibilityIfNeeded(for app: NSRunningApplication, force: Bool = false) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        let shouldSetEnhancedUI = isChromiumFamily(bundleIdentifier: app.bundleIdentifier)
        let hasManualPriming = accessibilityPrimedPIDs.contains(pid)
        let hasEnhancedPriming = enhancedAccessibilityPrimedPIDs.contains(pid)

        if !force && hasManualPriming && (!shouldSetEnhancedUI || hasEnhancedPriming) {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Electron documents this explicit opt-in switch for third-party ATs.
        if force || !hasManualPriming {
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            accessibilityPrimedPIDs.insert(pid)
        }

        // Chromium apps may require this to expose complete accessibility data
        // for non-VoiceOver assistive tools.
        if shouldSetEnhancedUI && (force || !hasEnhancedPriming) {
            _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            enhancedAccessibilityPrimedPIDs.insert(pid)
        }
    }

    private func isChromiumFamily(bundleIdentifier: String?) -> Bool {
        ChromiumBundleIDSettings.isChromiumFamily(bundleIdentifier: bundleIdentifier)
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
        cell.configure(
            name: item.snippet.displayName,
            keyword: item.snippet.normalizedKeyword,
            nameMatchRanges: item.nameMatchRanges,
            keywordMatchRanges: item.keywordMatchRanges
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return singleLineRowHeight }
        return shouldWrapName(for: items[row]) ? wrappedNameRowHeight : singleLineRowHeight
    }

    private func shouldWrapName(for item: SuggestionItem) -> Bool {
        let name = item.snippet.displayName as NSString
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let availableWidth = panelWidth - horizontalCellPadding
        let width = name.size(withAttributes: [.font: font]).width
        return width > availableWidth
    }
}

// MARK: - Cell View

private final class SuggestionCellView: NSTableCellView {
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        primaryLabel.lineBreakMode = .byWordWrapping
        primaryLabel.maximumNumberOfLines = 2
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.maximumNumberOfLines = 1
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let labelsStack = NSStackView(views: [primaryLabel, secondaryLabel])
        labelsStack.orientation = .vertical
        labelsStack.spacing = 1
        labelsStack.alignment = .leading
        labelsStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelsStack)

        NSLayoutConstraint.activate([
            labelsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labelsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labelsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelsStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            labelsStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),

            primaryLabel.widthAnchor.constraint(equalTo: labelsStack.widthAnchor),
            secondaryLabel.widthAnchor.constraint(equalTo: labelsStack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, keyword: String, nameMatchRanges: [NSRange], keywordMatchRanges: [NSRange]) {
        primaryLabel.attributedStringValue = highlightedString(
            name,
            font: .systemFont(ofSize: 13),
            color: .labelColor,
            matchRanges: nameMatchRanges
        )
        secondaryLabel.attributedStringValue = highlightedString(
            keyword,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: .secondaryLabelColor,
            matchRanges: keywordMatchRanges
        )
        secondaryLabel.isHidden = keyword.isEmpty
    }

    private func highlightedString(
        _ string: String,
        font: NSFont,
        color: NSColor,
        matchRanges: [NSRange]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color]
        )
        guard !string.isEmpty, !matchRanges.isEmpty else { return attributed }

        let highlightedFont = highlightedFont(for: font)
        let fullRange = NSRange(location: 0, length: (string as NSString).length)

        for range in matchRanges where NSIntersectionRange(range, fullRange).length == range.length {
            attributed.addAttributes(
                [
                    .font: highlightedFont,
                    .foregroundColor: NSColor.controlAccentColor
                ],
                range: range
            )
        }

        return attributed
    }

    private func highlightedFont(for font: NSFont) -> NSFont {
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return .monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        }

        return .systemFont(ofSize: font.pointSize, weight: .semibold)
    }
}
