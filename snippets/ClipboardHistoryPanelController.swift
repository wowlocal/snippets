import AppKit

private final class ClipboardHistoryPanel: NSPanel {
    var handlePickerCommand: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handlePickerCommand?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePickerCommand?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class ClipboardHistorySearchField: NSSearchField {
    override var needsPanelToBecomeKey: Bool { true }
}

/// A quiet reading surface over the panel's glass, without another material or blur.
private final class ClipboardHistoryPreviewSurface: NSView {
    override var allowsVibrancy: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("clipboardHistoryPreviewSurface")
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        // CGColor does not retain the semantic color's dynamic appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.32).cgColor
        }
    }
}

/// A keyboard-enabled, non-activating picker. The caller captures its destination
/// before showing this panel and owns restoring focus and delivering the text.
@MainActor
final class ClipboardHistoryPanelController: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate,
    NSWindowDelegate
{
    private let service: ClipboardHistoryService
    private let panel: ClipboardHistoryPanel
    private let searchField = ClipboardHistorySearchField()
    private let tableView = NSTableView()
    private let listScrollView = NSScrollView()
    private let previewScrollView = NSScrollView()
    private let previewView = NSTextView(frame: .zero)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "Paste ↩", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy ⌘↩", target: nil, action: nil)
    private let createButton = NSButton(title: "Create Snippet ⌘N", target: nil, action: nil)
    private let deleteButton = NSButton()
    private var items: [ClipboardHistoryEntry] = []
    private var canPaste = false
    private var pasteAction: ((ClipboardHistoryEntry) -> Void)?
    private var copyAction: ((ClipboardHistoryEntry) -> Void)?
    private var createAction: ((ClipboardHistoryEntry) -> Void)?
    private var dismissalAction: ((Bool) -> Void)?
    private var presentationStartedWithHiddenApplication = false
    private var presentationGeneration = 0
    private var isEndingPresentation = false
    private var isReloading = false
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?

    init(service: ClipboardHistoryService) {
        self.service = service
        panel = ClipboardHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        configureContent()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyDidChange),
            name: ClipboardHistoryService.didChangeNotification,
            object: service
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isVisible: Bool { panel.isVisible }

    func show(
        canPaste: Bool,
        onPaste: @escaping (ClipboardHistoryEntry) -> Void,
        onCopy: @escaping (ClipboardHistoryEntry) -> Void,
        onCreateSnippet: @escaping (ClipboardHistoryEntry) -> Void,
        onDismiss: @escaping (Bool) -> Void
    ) {
        dismiss()
        guard service.isEnabled else {
            onDismiss(false)
            return
        }
        self.canPaste = canPaste
        pasteAction = onPaste
        copyAction = onCopy
        createAction = onCreateSnippet
        dismissalAction = onDismiss
        presentationGeneration += 1
        presentationStartedWithHiddenApplication = NSApp.isHidden
        panel.canHide = false
        searchField.stringValue = ""
        primaryButton.title = canPaste ? "Paste ↩" : "Copy ↩"
        primaryButton.setAccessibilityLabel(canPaste ? "Paste selected clipboard entry" : "Copy selected clipboard entry")
        reloadEntries(preservingSelection: false)
        positionPanel()

        if presentationStartedWithHiddenApplication {
            // As with Secure Paste, showing a non-activating panel can unhide the
            // process. Keep only this panel exempt so the library stays hidden.
            panel.orderFrontRegardless()
            NSApp.hide(nil)
            panel.orderFrontRegardless()
        } else {
            panel.orderFrontRegardless()
        }
        panel.makeKey()
        panel.makeFirstResponder(searchField)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        installEventMonitors()
    }

    func dismiss(returnFocus: Bool = false) {
        guard let dismissal = dismissalAction, !isEndingPresentation else { return }
        isEndingPresentation = true
        presentationGeneration += 1
        dismissalAction = nil
        pasteAction = nil
        copyAction = nil
        createAction = nil
        removeEventMonitors()
        panel.orderOut(nil)
        panel.makeFirstResponder(nil)
        if presentationStartedWithHiddenApplication { NSApp.hide(nil) }
        presentationStartedWithHiddenApplication = false
        panel.canHide = true
        items = []
        tableView.reloadData()
        previewView.string = ""
        searchField.stringValue = ""
        isEndingPresentation = false
        // Clear the caller's picker state before a selection callback can start
        // focus restoration, insertion, or opening the snippet editor.
        dismissal(returnFocus)
    }

    private func configurePanel() {
        panel.delegate = self
        panel.handlePickerCommand = { [weak self] event in self?.handleKeyEvent(event) ?? false }
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityTitle("Clipboard History")
    }

    private func configureContent() {
        let title = NSTextField(labelWithString: "Clipboard History")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let shortcut = NSTextField(labelWithString: "⌘⇧V")
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        let titleRow = NSStackView(views: [title, NSView(), shortcut])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        searchField.placeholderString = "Search clipboard history"
        searchField.setAccessibilityLabel("Search clipboard history")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        let header = NSStackView(views: [titleRow, searchField, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 10
        header.setContentHuggingPriority(.required, for: .vertical)
        header.translatesAutoresizingMaskIntoConstraints = false
        for child in [titleRow, searchField, statusLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        }

        configureList()
        configurePreview()
        let previewTitle = NSTextField(labelWithString: "Preview")
        previewTitle.font = .systemFont(ofSize: 11, weight: .medium)
        previewTitle.textColor = .secondaryLabelColor
        previewTitle.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        let previewSurface = ClipboardHistoryPreviewSurface()
        previewSurface.translatesAutoresizingMaskIntoConstraints = false
        [previewTitle, previewScrollView].forEach(previewSurface.addSubview)
        [listScrollView, divider, previewSurface, emptyLabel].forEach(body.addSubview)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = configureFooter()
        let topRule = NSBox()
        topRule.boxType = .separator
        topRule.translatesAutoresizingMaskIntoConstraints = false
        let bottomRule = NSBox()
        bottomRule.boxType = .separator
        bottomRule.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        [header, topRule, body, bottomRule, footer].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            topRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            topRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 3),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomRule.topAnchor, constant: -3),
            bottomRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: bottomRule.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            listScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            listScrollView.topAnchor.constraint(equalTo: body.topAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            listScrollView.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.45),
            divider.leadingAnchor.constraint(equalTo: listScrollView.trailingAnchor, constant: 1),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: body.topAnchor, constant: 5),
            divider.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -5),
            previewSurface.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 4),
            previewSurface.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
            previewSurface.topAnchor.constraint(equalTo: body.topAnchor, constant: 5),
            previewSurface.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -5),
            previewTitle.leadingAnchor.constraint(equalTo: previewSurface.leadingAnchor, constant: 10),
            previewTitle.trailingAnchor.constraint(equalTo: previewSurface.trailingAnchor, constant: -6),
            previewTitle.topAnchor.constraint(equalTo: previewSurface.topAnchor, constant: 5),
            previewScrollView.leadingAnchor.constraint(equalTo: previewSurface.leadingAnchor),
            previewScrollView.trailingAnchor.constraint(equalTo: previewSurface.trailingAnchor),
            previewScrollView.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 5),
            previewScrollView.bottomAnchor.constraint(equalTo: previewSurface.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: listScrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: listScrollView.trailingAnchor, constant: -20),
            emptyLabel.centerYAnchor.constraint(equalTo: listScrollView.centerYAnchor),
        ])

        let surface = LiquidGlassDesign.makeFloatingPanelSurface(
            containing: content,
            usesPickerAppearance: true
        )
        let root = panel.contentView!
        root.wantsLayer = true
        root.layer?.cornerRadius = LiquidGlassDesign.effectivePanelCornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func configureList() {
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.rowHeight = 57
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setAccessibilityLabel("Clipboard history entries, newest first")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClipboardHistory"))
        column.width = 306
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(performPrimaryAction)
        listScrollView.documentView = tableView
        listScrollView.drawsBackground = false
        listScrollView.hasVerticalScroller = true
        listScrollView.scrollerStyle = .overlay
        listScrollView.automaticallyAdjustsContentInsets = false
        listScrollView.contentInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        listScrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configurePreview() {
        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.isRichText = false
        previewView.drawsBackground = false
        previewView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewView.textColor = .labelColor
        previewView.textContainerInset = NSSize(width: 10, height: 5)
        previewView.isHorizontallyResizable = false
        previewView.isVerticallyResizable = true
        previewView.minSize = .zero
        previewView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        previewView.autoresizingMask = [.width]
        previewView.textContainer?.widthTracksTextView = true
        previewView.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
        previewView.setAccessibilityLabel("Full clipboard entry preview")
        previewScrollView.documentView = previewView
        previewScrollView.drawsBackground = false
        previewScrollView.hasVerticalScroller = true
        previewScrollView.scrollerStyle = .overlay
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureFooter() -> NSStackView {
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryButton.target = self
        primaryButton.action = #selector(performPrimaryAction)
        copyButton.target = self
        copyButton.action = #selector(copySelection)
        copyButton.setAccessibilityLabel("Copy selected clipboard entry")
        createButton.target = self
        createButton.action = #selector(createSnippet)
        createButton.setAccessibilityLabel("Create snippet from selected clipboard entry")
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete clipboard entry")
        deleteButton.imagePosition = .imageOnly
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelection)
        deleteButton.toolTip = "Delete selected entry (⌘⌫)"
        deleteButton.setAccessibilityLabel("Delete selected clipboard entry")
        for button in [primaryButton, copyButton, createButton, deleteButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        let footer = NSStackView(views: [countLabel, NSView(), deleteButton, createButton, copyButton, primaryButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        return footer
    }

    private func positionPanel() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }
        let frame = screen.visibleFrame
        let size = NSSize(width: min(680, frame.width - 32), height: min(420, frame.height - 32))
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    @objc private func historyDidChange() {
        guard dismissalAction != nil else { return }
        guard service.isEnabled else {
            dismiss()
            return
        }
        reloadEntries(preservingSelection: true)
    }

    private func reloadEntries(preservingSelection: Bool) {
        let selectedID = preservingSelection ? selectedEntry?.id : nil
        let previousRow = preservingSelection ? tableView.selectedRow : 0
        let previousPreviewID = selectedEntry?.id
        isReloading = true
        items = service.search(searchField.stringValue)
        tableView.reloadData()
        if !items.isEmpty {
            let row = selectedID.flatMap { id in items.firstIndex { $0.id == id } }
                ?? min(max(previousRow, 0), items.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        isReloading = false
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.stringValue = searchField.stringValue.isEmpty
            ? "Your copied text will appear here.\nCopy something to get started."
            : "No matching clipboard entries."
        countLabel.stringValue = "\(items.count) \(items.count == 1 ? "item" : "items")"
        statusLabel.stringValue = service.statusMessage ?? ""
        statusLabel.isHidden = service.statusMessage == nil
        updateSelection(resetPreviewScroll: previousPreviewID != selectedEntry?.id)
    }

    private var selectedEntry: ClipboardHistoryEntry? {
        guard items.indices.contains(tableView.selectedRow) else { return nil }
        return items[tableView.selectedRow]
    }

    private func updateSelection(resetPreviewScroll: Bool = true) {
        let selected = selectedEntry
        let text = selected?.text ?? ""
        if previewView.string != text { previewView.string = text }
        if resetPreviewScroll {
            previewView.setSelectedRange(NSRange(location: 0, length: 0))
            previewView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        for button in [primaryButton, copyButton, createButton, deleteButton] {
            button.isEnabled = selected != nil
        }
    }

    @objc private func performPrimaryAction() {
        finishSelection(using: canPaste ? pasteAction : copyAction)
    }

    @objc private func copySelection() { finishSelection(using: copyAction) }

    @objc private func createSnippet() { finishSelection(using: createAction) }

    private func finishSelection(using action: ((ClipboardHistoryEntry) -> Void)?) {
        guard let entry = selectedEntry, let action else {
            NSSound.beep()
            return
        }
        dismiss()
        action(entry)
    }

    @objc private func deleteSelection() {
        guard let selectedEntry else { return }
        service.delete(id: selectedEntry.id)
    }

    func controlTextDidChange(_ obj: Notification) {
        reloadEntries(preservingSelection: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            performPrimaryAction()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(returnFocus: true)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let row = (max(tableView.selectedRow, 0) + offset + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SuggestionTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ClipboardHistoryEntry")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipboardHistoryCellView
            ?? ClipboardHistoryCellView()
        cell.identifier = identifier
        cell.configure(entry: items[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        updateSelection()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, !isEndingPresentation else { return }
        let generation = presentationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationGeneration == generation,
                  self.panel.isVisible, !self.panel.isKeyWindow else { return }
            self.dismiss()
        }
    }

    private func installEventMonitors() {
        removeEventMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissForOutsideClick()
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            self.dismissForOutsideClick()
            return event
        }
    }

    /// Only the picker's explicit commands are intercepted. Search selection,
    /// copy/paste, word movement, deletion, IME composition, and Tab remain native.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard panel.isVisible, dismissalAction != nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            switch event.keyCode {
            case 36, 76: copySelection()
            case 45: createSnippet()
            case 51: deleteSelection()
            default: return false
            }
            return true
        }
        if modifiers.isEmpty, event.keyCode == 53 {
            // Let an input method cancel marked text before dismissing the panel.
            if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            dismiss(returnFocus: true)
            return true
        }
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            performPrimaryAction()
            return true
        }
        return false
    }

    private func removeEventMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        globalClickMonitor = nil
        localEventMonitor = nil
    }

    private func dismissForOutsideClick() {
        guard panel.isVisible else { return }
        let point = NSEvent.mouseLocation
        let frame = panel.frame
        if frame.contains(point) {
            let radius = LiquidGlassDesign.effectivePanelCornerRadius
            let dx = min(point.x - frame.minX, frame.maxX - point.x)
            let dy = min(point.y - frame.minY, frame.maxY - point.y)
            if dx >= radius || dy >= radius || hypot(radius - dx, radius - dy) <= radius { return }
        }
        dismiss()
    }
}

private final class ClipboardHistoryCellView: NSTableCellView {
    private let textLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textLabel.font = .systemFont(ofSize: 12, weight: .medium)
        textLabel.maximumNumberOfLines = 2
        textLabel.lineBreakMode = .byTruncatingTail
        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [textLabel, dateLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dateLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(entry: ClipboardHistoryEntry) {
        // Collapse whitespace in the compact row only. The preview and selection
        // callback always use the exact captured text, including indentation.
        textLabel.stringValue = String(entry.text.prefix(220))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if textLabel.stringValue.isEmpty { textLabel.stringValue = "Whitespace" }
        dateLabel.stringValue = Self.dateFormatter.string(from: entry.copiedAt)
        setAccessibilityLabel(textLabel.stringValue)
    }
}
