import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

@MainActor
final class ViewController: NSViewController {
    private lazy var store: SnippetStore = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.store
        }
        return SnippetStore()
    }()

    private lazy var engine: SnippetExpansionEngine = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.expansionEngine
        }
        return SnippetExpansionEngine(store: store)
    }()

    private var localKeyMonitor: Any?

    private var visibleSnippets: [Snippet] = []
    private var selectedSnippetID: UUID?
    private var isApplyingSnippetToEditor = false

    private var importExportMessage: String? {
        didSet {
            importExportMessageLabel.stringValue = importExportMessage ?? ""
            importExportMessageLabel.isHidden = importExportMessage == nil
        }
    }

    private let permissionIconView = NSImageView()
    private let permissionTitleLabel = NSTextField(labelWithString: "")
    private let permissionStatusLabel = NSTextField(labelWithString: "")

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let lastActionLabel = NSTextField(labelWithString: "")
    private let importExportMessageLabel = NSTextField(labelWithString: "")

    private let nameField = NSTextField(string: "")
    private let snippetTextView = NSTextView()
    private let keywordField = NSTextField(string: "")
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let previewValueField = NSTextField(wrappingLabelWithString: "")

    private let actionOverlayView = ActionOverlayView()
    private let actionPanelView = NSVisualEffectView()
    private let actionPasteRow = ActionShortcutRow(title: "Paste Snippet", shortcut: "⌘↩")
    private let actionEditRow = ActionShortcutRow(title: "Edit Snippet", shortcut: "⌘E")
    private let actionDuplicateRow = ActionShortcutRow(title: "Duplicate Snippet", shortcut: "⌘D")
    private let actionPinRow = ActionShortcutRow(title: "Pin Snippet", shortcut: "⌘.")

    override func viewDidLoad() {
        super.viewDidLoad()

        buildUI()
        bindState()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCreateNewNotification),
            name: .snippetsCreateNew,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleActionsNotification),
            name: .snippetsToggleActions,
            object: nil
        )

        engine.startIfNeeded()
        reloadVisibleSnippets(keepSelection: false)
        if let firstID = visibleSnippets.first?.id {
            selectSnippet(id: firstID, focusEditorName: false)
        } else {
            applySelectedSnippetToEditor()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        view.window?.title = "Snippets"
        view.window?.minSize = NSSize(width: 980, height: 640)

        installKeyboardMonitorIfNeeded()

        if tableView.selectedRow == -1, !visibleSnippets.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        view.window?.makeFirstResponder(tableView)
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func buildUI() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        view = rootView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(rootStack)

        let banner = buildPermissionBanner()
        rootStack.addArrangedSubview(banner)

        let divider = NSBox()
        divider.boxType = .separator
        rootStack.addArrangedSubview(divider)

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        let editor = buildEditor()

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(editor)

        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 390).isActive = true
        splitView.setPosition(330, ofDividerAt: 0)

        rootStack.addArrangedSubview(splitView)

        [banner, divider, splitView].forEach {
            $0.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: rootView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        buildActionOverlay(in: rootView)
    }

    private func buildPermissionBanner() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.15).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        permissionIconView.imageScaling = .scaleProportionallyDown
        permissionIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        permissionIconView.translatesAutoresizingMaskIntoConstraints = false
        permissionIconView.widthAnchor.constraint(equalToConstant: 16).isActive = true

        permissionTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        permissionStatusLabel.font = .systemFont(ofSize: 13)
        permissionStatusLabel.textColor = .secondaryLabelColor
        permissionStatusLabel.lineBreakMode = .byTruncatingTail

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPermissions))
        let requestButton = NSButton(title: "Request Permission", target: self, action: #selector(requestPermission))
        let accessibilityButton = NSButton(title: "Accessibility", target: self, action: #selector(openAccessibilitySettings))
        let inputButton = NSButton(title: "Input Monitoring", target: self, action: #selector(openInputSettings))

        [refreshButton, requestButton, accessibilityButton, inputButton].forEach {
            $0.controlSize = .small
            $0.bezelStyle = .rounded
            stack.addArrangedSubview($0)
        }

        let leadingStatusStack = NSStackView(views: [permissionIconView, permissionTitleLabel, permissionStatusLabel])
        leadingStatusStack.orientation = .horizontal
        leadingStatusStack.spacing = 8
        leadingStatusStack.alignment = .centerY

        stack.insertArrangedSubview(leadingStatusStack, at: 0)
        stack.insertArrangedSubview(NSView(), at: 1)

        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        return container
    }

    private func buildSidebar() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.12).cgColor

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .centerY

        let titleLabel = NSTextField(labelWithString: "Snippets")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let importButton = NSButton(title: "Import", target: self, action: #selector(runImport))
        importButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading
        importButton.bezelStyle = .rounded

        let exportButton = NSButton(title: "Export", target: self, action: #selector(runExport))
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportButton.imagePosition = .imageLeading
        exportButton.bezelStyle = .rounded

        let newButton = NSButton(title: "New", target: self, action: #selector(createSnippet))
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading
        newButton.bezelStyle = .rounded
        newButton.bezelColor = .systemBlue
        newButton.contentTintColor = .white
        newButton.keyEquivalent = "n"
        newButton.keyEquivalentModifierMask = [.command]

        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(NSView())
        headerStack.addArrangedSubview(importButton)
        headerStack.addArrangedSubview(exportButton)
        headerStack.addArrangedSubview(newButton)

        searchField.placeholderString = "Search snippets"
        searchField.delegate = self
        searchField.controlSize = .regular

        let tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.borderType = .noBorder
        tableScrollView.drawsBackground = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SnippetColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.focusRingType = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.delegate = self
        tableView.dataSource = self

        tableScrollView.documentView = tableView
        tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedSnippet)
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteButton.imagePosition = .imageLeading
        deleteButton.bezelStyle = .rounded

        let footerTopRow = NSStackView(views: [deleteButton, NSView(), lastActionLabel])
        footerTopRow.orientation = .horizontal
        footerTopRow.spacing = 8
        footerTopRow.alignment = .centerY

        lastActionLabel.font = .systemFont(ofSize: 12)
        lastActionLabel.textColor = .secondaryLabelColor
        lastActionLabel.lineBreakMode = .byTruncatingTail

        let mapLabel = NSTextField(labelWithString: "Raycast map: ↩ copy, ⌘K actions, ⌘N new, arrows move, Esc back")
        mapLabel.font = .systemFont(ofSize: 11)
        mapLabel.textColor = .secondaryLabelColor
        mapLabel.lineBreakMode = .byWordWrapping
        mapLabel.maximumNumberOfLines = 2

        importExportMessageLabel.font = .systemFont(ofSize: 12)
        importExportMessageLabel.textColor = .secondaryLabelColor
        importExportMessageLabel.lineBreakMode = .byWordWrapping
        importExportMessageLabel.maximumNumberOfLines = 2
        importExportMessageLabel.isHidden = true

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(searchField)
        rootStack.addArrangedSubview(tableScrollView)
        rootStack.addArrangedSubview(footerTopRow)
        rootStack.addArrangedSubview(mapLabel)
        rootStack.addArrangedSubview(importExportMessageLabel)

        rootStack.setCustomSpacing(12, after: headerStack)
        rootStack.setCustomSpacing(8, after: searchField)
        rootStack.setCustomSpacing(8, after: tableScrollView)

        container.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        return container
    }

    private func buildEditor() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .left

        nameField.delegate = self
        nameField.placeholderString = "Temporary Password"
        nameField.controlSize = .large

        let snippetLabel = NSTextField(labelWithString: "Snippet")
        snippetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.alignment = .left

        let snippetScrollView = NSScrollView()
        snippetScrollView.translatesAutoresizingMaskIntoConstraints = false
        snippetScrollView.hasVerticalScroller = true
        snippetScrollView.borderType = .bezelBorder
        snippetScrollView.scrollerStyle = .overlay

        snippetTextView.delegate = self
        snippetTextView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        snippetTextView.isRichText = false
        snippetTextView.isAutomaticQuoteSubstitutionEnabled = false
        snippetTextView.isAutomaticTextReplacementEnabled = false
        snippetTextView.isAutomaticDataDetectionEnabled = false
        snippetTextView.minSize = NSSize(width: 0, height: 220)
        snippetTextView.isVerticallyResizable = true
        snippetTextView.textContainerInset = NSSize(width: 8, height: 8)
        snippetTextView.textContainer?.widthTracksTextView = true
        snippetTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        snippetScrollView.documentView = snippetTextView
        snippetScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let placeholderLabel = NSTextField(labelWithString: "Dynamic placeholders: {clipboard}, {date}, {time}, {datetime}, {date:yyyy-MM-dd}")
        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .left

        let keywordLabel = NSTextField(labelWithString: "Keyword")
        keywordLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        keywordLabel.textColor = .secondaryLabelColor
        keywordLabel.alignment = .left

        keywordField.delegate = self
        keywordField.placeholderString = "\\tp"
        keywordField.controlSize = .large

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledStateChanged)
        enabledCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        let previewLabel = NSTextField(labelWithString: "Preview")
        previewLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.alignment = .left

        let previewContainer = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = 8
        previewContainer.layer?.borderWidth = 1
        previewContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        previewContainer.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor

        previewValueField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        previewValueField.lineBreakMode = .byWordWrapping
        previewValueField.maximumNumberOfLines = 0
        previewValueField.allowsDefaultTighteningForTruncation = false
        previewValueField.translatesAutoresizingMaskIntoConstraints = false

        previewContainer.addSubview(previewValueField)

        NSLayoutConstraint.activate([
            previewValueField.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 10),
            previewValueField.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            previewValueField.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            previewValueField.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8)
        ])

        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(snippetLabel)
        stack.addArrangedSubview(snippetScrollView)
        stack.addArrangedSubview(placeholderLabel)
        stack.addArrangedSubview(keywordLabel)
        stack.addArrangedSubview(keywordField)
        stack.addArrangedSubview(enabledCheckbox)
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(previewLabel)
        stack.addArrangedSubview(previewContainer)

        contentView.addSubview(stack)
        container.addSubview(scrollView)

        [nameField, snippetScrollView, placeholderLabel, keywordField, separator, previewContainer].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 820).isActive = true
        let preferredEditorWidth = stack.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -40)
        preferredEditorWidth.priority = .defaultHigh
        preferredEditorWidth.isActive = true

        stack.setCustomSpacing(8, after: nameLabel)
        stack.setCustomSpacing(10, after: snippetLabel)
        stack.setCustomSpacing(8, after: keywordLabel)
        stack.setCustomSpacing(8, after: separator)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        return container
    }

    private func buildActionOverlay(in rootView: NSView) {
        actionOverlayView.translatesAutoresizingMaskIntoConstraints = false
        actionOverlayView.wantsLayer = true
        actionOverlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        actionOverlayView.isHidden = true
        actionOverlayView.onBackgroundClick = { [weak self] in
            self?.closeActionPanel()
        }

        actionPanelView.translatesAutoresizingMaskIntoConstraints = false
        actionPanelView.material = .menu
        actionPanelView.blendingMode = .withinWindow
        actionPanelView.state = .active
        actionPanelView.wantsLayer = true
        actionPanelView.layer?.cornerRadius = 12
        actionPanelView.layer?.borderWidth = 1
        actionPanelView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        let actionTitle = NSTextField(labelWithString: "Actions")
        actionTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        actionTitle.alignment = .center

        let separator = NSBox()
        separator.boxType = .separator

        let actionNewRow = ActionShortcutRow(title: "Create New Snippet", shortcut: "⌘N")

        let tip = NSTextField(labelWithString: "esc to dismiss")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .tertiaryLabelColor
        tip.alignment = .center

        let actionStack = NSStackView(views: [
            actionTitle,
            actionPasteRow,
            actionEditRow,
            actionDuplicateRow,
            actionPinRow,
            separator,
            actionNewRow,
            tip
        ])
        actionStack.orientation = .vertical
        actionStack.spacing = 2
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        actionStack.setCustomSpacing(10, after: actionTitle)
        actionStack.setCustomSpacing(6, after: separator)
        actionStack.setCustomSpacing(8, after: actionNewRow)

        [actionTitle, separator, tip].forEach {
            $0.widthAnchor.constraint(equalTo: actionStack.widthAnchor).isActive = true
        }

        actionPanelView.addSubview(actionStack)
        actionOverlayView.addSubview(actionPanelView)
        rootView.addSubview(actionOverlayView)

        NSLayoutConstraint.activate([
            actionOverlayView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            actionOverlayView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            actionOverlayView.topAnchor.constraint(equalTo: rootView.topAnchor),
            actionOverlayView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            actionPanelView.centerXAnchor.constraint(equalTo: actionOverlayView.centerXAnchor),
            actionPanelView.centerYAnchor.constraint(equalTo: actionOverlayView.centerYAnchor),
            actionPanelView.widthAnchor.constraint(equalToConstant: 340),

            actionStack.leadingAnchor.constraint(equalTo: actionPanelView.leadingAnchor, constant: 10),
            actionStack.trailingAnchor.constraint(equalTo: actionPanelView.trailingAnchor, constant: -10),
            actionStack.topAnchor.constraint(equalTo: actionPanelView.topAnchor, constant: 14),
            actionStack.bottomAnchor.constraint(equalTo: actionPanelView.bottomAnchor, constant: -10)
        ])
    }

    private func bindState() {
        store.onChange = { [weak self] in
            guard let self else { return }
            reloadVisibleSnippets(keepSelection: true)
            if !isEditingDetails {
                applySelectedSnippetToEditor()
            }
        }

        engine.onStateChange = { [weak self] in
            guard let self else { return }
            updatePermissionBanner()
            permissionStatusLabel.stringValue = engine.statusText
            lastActionLabel.stringValue = engine.lastExpansionName.map { "Last action: \($0)" } ?? ""
        }
    }

    private func updatePermissionBanner() {
        if engine.accessibilityGranted {
            permissionIconView.image = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: nil)
            permissionIconView.contentTintColor = .systemGreen
            permissionTitleLabel.stringValue = "Permissions Ready"
            permissionTitleLabel.textColor = .systemGreen
        } else {
            permissionIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            permissionIconView.contentTintColor = .systemOrange
            permissionTitleLabel.stringValue = "Permissions Required"
            permissionTitleLabel.textColor = .systemOrange
        }
        permissionStatusLabel.stringValue = engine.statusText
    }

    private func reloadVisibleSnippets(keepSelection: Bool) {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let sorted = store.snippetsSortedForDisplay()
        if query.isEmpty {
            visibleSnippets = sorted
        } else {
            visibleSnippets = sorted.filter { snippet in
                snippet.displayName.lowercased().contains(query)
                    || snippet.normalizedKeyword.lowercased().contains(query)
                    || snippet.content.lowercased().contains(query)
            }
        }

        if !keepSelection {
            selectedSnippetID = visibleSnippets.first?.id
        } else if let selectedSnippetID, !visibleSnippets.contains(where: { $0.id == selectedSnippetID }) {
            self.selectedSnippetID = visibleSnippets.first?.id
        }

        tableView.reloadData()
        syncTableSelectionWithSelectedSnippet()
        updateActionPanelPinLabel()
        deleteButton.isEnabled = selectedSnippetID != nil
    }

    private func syncTableSelectionWithSelectedSnippet() {
        guard let selectedSnippetID,
              let row = visibleSnippets.firstIndex(where: { $0.id == selectedSnippetID }) else {
            if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
            return
        }

        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    private func applySelectedSnippetToEditor() {
        guard let snippet = selectedSnippet else {
            isApplyingSnippetToEditor = true
            nameField.stringValue = ""
            snippetTextView.string = ""
            keywordField.stringValue = ""
            enabledCheckbox.state = .off
            updatePreview(withTemplate: "")
            setEditorEnabled(false)
            isApplyingSnippetToEditor = false
            return
        }

        isApplyingSnippetToEditor = true
        nameField.stringValue = snippet.name
        snippetTextView.string = snippet.content
        keywordField.stringValue = snippet.normalizedKeyword
        enabledCheckbox.state = snippet.isEnabled ? .on : .off
        updatePreview(withTemplate: snippet.content)
        setEditorEnabled(true)
        isApplyingSnippetToEditor = false
    }

    private func setEditorEnabled(_ enabled: Bool) {
        nameField.isEnabled = enabled
        snippetTextView.isEditable = enabled
        keywordField.isEnabled = enabled
        enabledCheckbox.isEnabled = enabled

        if !enabled {
            previewValueField.stringValue = "Preview appears here once snippet text is entered"
        }
    }

    private var selectedSnippet: Snippet? {
        guard let selectedSnippetID else { return nil }
        return store.snippet(id: selectedSnippetID)
    }

    private func updateSelectedSnippetFromEditor() {
        guard !isApplyingSnippetToEditor, var snippet = selectedSnippet else { return }

        snippet.name = nameField.stringValue
        snippet.content = snippetTextView.string

        let sanitizedKeyword = keywordField.stringValue.replacingOccurrences(of: " ", with: "")
        if sanitizedKeyword != keywordField.stringValue {
            keywordField.stringValue = sanitizedKeyword
        }
        snippet.keyword = sanitizedKeyword

        snippet.isEnabled = enabledCheckbox.state == .on

        store.update(snippet)
        updatePreview(withTemplate: snippet.content)
    }

    private func updatePreview(withTemplate template: String) {
        let rendered = PlaceholderResolver.resolve(template: template)
        previewValueField.stringValue = rendered.isEmpty
            ? "Preview appears here once snippet text is entered"
            : rendered
    }

    private var isEditingDetails: Bool {
        guard let firstResponder = view.window?.firstResponder else { return false }
        if firstResponder === snippetTextView {
            return true
        }
        if firstResponder === nameField.currentEditor() || firstResponder === keywordField.currentEditor() {
            return true
        }
        return false
    }

    private func installKeyboardMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let lowerCharacters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == UInt16(kVK_Escape) {
            if !actionOverlayView.isHidden {
                closeActionPanel()
            } else {
                view.window?.makeFirstResponder(tableView)
            }
            return nil
        }

        if flags == [.command] && lowerCharacters == "k" {
            toggleActionPanel()
            return nil
        }

        if flags == [.command] && lowerCharacters == "n" {
            createSnippet(nil)
            return nil
        }

        if flags == [.command] && event.keyCode == UInt16(kVK_Delete) {
            deleteSelectedSnippet(nil)
            return nil
        }

        if flags == [.command, .shift] && lowerCharacters == "i" {
            runImport(nil)
            return nil
        }

        if flags == [.command, .shift] && lowerCharacters == "e" {
            runExport(nil)
            return nil
        }

        if !actionOverlayView.isHidden {
            if flags == [.command] && isReturnKey(event) {
                pasteSelectedSnippet()
                closeActionPanel()
                return nil
            }
            if flags == [.command] && lowerCharacters == "e" {
                editSelectedSnippet()
                return nil
            }
            if flags == [.command] && lowerCharacters == "d" {
                duplicateSelectedSnippet()
                return nil
            }
            if flags == [.command] && lowerCharacters == "." {
                togglePinnedSelectedSnippet()
                return nil
            }
            return event
        }

        if flags.isEmpty && isReturnKey(event) && isListContext {
            copySelectedSnippet()
            return nil
        }

        return event
    }

    private var isListContext: Bool {
        guard let firstResponder = view.window?.firstResponder else { return true }

        if firstResponder === tableView || firstResponder === tableView.enclosingScrollView {
            return true
        }

        if firstResponder === searchField.currentEditor() || firstResponder === searchField {
            return true
        }

        if firstResponder === snippetTextView {
            return false
        }

        if firstResponder === nameField.currentEditor() || firstResponder === keywordField.currentEditor() {
            return false
        }

        return true
    }

    private func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
    }

    private func selectSnippet(id: UUID, focusEditorName: Bool) {
        selectedSnippetID = id
        syncTableSelectionWithSelectedSnippet()
        applySelectedSnippetToEditor()
        updateActionPanelPinLabel()

        if focusEditorName {
            view.window?.makeFirstResponder(nameField)
        }
    }

    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Import / Export Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func toggleActionPanel() {
        if actionOverlayView.isHidden {
            openActionPanel()
        } else {
            closeActionPanel()
        }
    }

    private func openActionPanel() {
        let hasSelection = selectedSnippet != nil
        updateActionPanelPinLabel()
        [actionPasteRow, actionEditRow, actionDuplicateRow, actionPinRow].forEach {
            $0.alphaValue = hasSelection ? 1.0 : 0.3
        }
        actionOverlayView.isHidden = false
        view.window?.makeFirstResponder(tableView)
    }

    private func closeActionPanel() {
        actionOverlayView.isHidden = true
        view.window?.makeFirstResponder(tableView)
    }

    private func updateActionPanelPinLabel() {
        let isPinned = selectedSnippet?.isPinned == true
        actionPinRow.setTitle(isPinned ? "Unpin Snippet" : "Pin Snippet")
    }

    @objc private func refreshPermissions() {
        engine.refreshAccessibilityStatus(prompt: false)
    }

    @objc private func requestPermission() {
        engine.requestAccessibilityPermission()
    }

    @objc private func openAccessibilitySettings() {
        engine.openAccessibilitySettings()
    }

    @objc private func openInputSettings() {
        engine.openInputMonitoringSettings()
    }

    @objc private func handleCreateNewNotification() {
        createSnippet(nil)
    }

    @objc private func handleToggleActionsNotification() {
        toggleActionPanel()
    }

    @objc private func createSnippet(_ sender: Any?) {
        let snippet = store.addSnippet()
        importExportMessage = nil
        reloadVisibleSnippets(keepSelection: true)
        selectSnippet(id: snippet.id, focusEditorName: true)
    }

    @objc private func deleteSelectedSnippet(_ sender: Any?) {
        guard let selectedSnippetID else { return }
        store.delete(snippetID: selectedSnippetID)
        reloadVisibleSnippets(keepSelection: true)
        applySelectedSnippetToEditor()
        closeActionPanel()
    }

    private func editSelectedSnippet() {
        guard selectedSnippet != nil else { return }
        closeActionPanel()
        view.window?.makeFirstResponder(nameField)
    }

    private func duplicateSelectedSnippet() {
        guard let selectedSnippetID,
              let duplicate = store.duplicate(snippetID: selectedSnippetID) else { return }

        importExportMessage = "Duplicated \(duplicate.displayName)."
        reloadVisibleSnippets(keepSelection: true)
        selectSnippet(id: duplicate.id, focusEditorName: true)
        closeActionPanel()
    }

    private func togglePinnedSelectedSnippet() {
        guard let selectedSnippetID else { return }
        store.togglePinned(snippetID: selectedSnippetID)

        let isPinned = store.snippet(id: selectedSnippetID)?.isPinned == true
        importExportMessage = isPinned ? "Pinned snippet." : "Unpinned snippet."

        reloadVisibleSnippets(keepSelection: true)
        closeActionPanel()
    }

    private func copySelectedSnippet() {
        guard let selectedSnippet else { return }
        engine.copySnippetToClipboard(selectedSnippet)
        importExportMessage = "Copied \(selectedSnippet.displayName) to clipboard."
    }

    private func pasteSelectedSnippet() {
        guard let selectedSnippet else { return }
        engine.pasteSnippetIntoFrontmostApp(selectedSnippet)
        importExportMessage = "Pasting \(selectedSnippet.displayName)."
    }

    @objc private func runImport(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a snippets JSON file to import."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let count = try store.importSnippets(from: url)
            importExportMessage = "Imported \(count) snippet(s) from \(url.lastPathComponent)."
            reloadVisibleSnippets(keepSelection: true)
            if selectedSnippetID == nil, let id = visibleSnippets.first?.id {
                selectSnippet(id: id, focusEditorName: false)
            }
            view.window?.makeFirstResponder(tableView)
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc private func runExport(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "snippets-export.json"
        panel.message = "Choose where to save your snippets export."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let count = try store.exportSnippets(to: url)
            importExportMessage = "Exported \(count) snippet(s) to \(url.lastPathComponent)."
            view.window?.makeFirstResponder(tableView)
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc private func enabledStateChanged() {
        updateSelectedSnippetFromEditor()
    }
}

extension ViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleSnippets.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SnippetTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleSnippets.indices.contains(row) else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("SnippetRowCell")
        let snippet = visibleSnippets[row]

        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SnippetRowCellView) ?? {
            let view = SnippetRowCellView()
            view.identifier = identifier
            return view
        }()

        cell.configure(with: snippet)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < visibleSnippets.count else {
            selectedSnippetID = nil
            applySelectedSnippetToEditor()
            updateActionPanelPinLabel()
            deleteButton.isEnabled = false
            return
        }

        selectedSnippetID = visibleSnippets[row].id
        applySelectedSnippetToEditor()
        updateActionPanelPinLabel()
        deleteButton.isEnabled = true
    }
}

extension ViewController: NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field == searchField {
            reloadVisibleSnippets(keepSelection: true)
            if selectedSnippetID == nil, let firstID = visibleSnippets.first?.id {
                selectSnippet(id: firstID, focusEditorName: false)
            }
            return
        }

        if field == nameField || field == keywordField {
            updateSelectedSnippetFromEditor()
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === snippetTextView else { return }
        updateSelectedSnippetFromEditor()
    }
}

private final class SnippetRowCellView: NSTableCellView {
    private let indicatorView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let keywordLabel = NSTextField(labelWithString: "")
    private var isSelectedStyle = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            isSelectedStyle = backgroundStyle == .emphasized
            applyTextColors()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        keywordLabel.font = .systemFont(ofSize: 12)
        keywordLabel.lineBreakMode = .byTruncatingTail

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        indicatorView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let labelsStack = NSStackView(views: [nameLabel, keywordLabel])
        labelsStack.orientation = .vertical
        labelsStack.spacing = 2

        let rootStack = NSStackView(views: [indicatorView, labelsStack])
        rootStack.orientation = .horizontal
        rootStack.spacing = 10
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
        nameLabel.stringValue = snippet.displayName
        keywordLabel.stringValue = snippet.normalizedKeyword

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
        nameLabel.textColor = .labelColor
        keywordLabel.textColor = .secondaryLabelColor
    }
}

private final class SnippetTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.10).setFill()
        path.fill()
    }
}

private final class ActionOverlayView: NSView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

private final class ActionShortcutRow: NSView {
    private let titleField = NSTextField(labelWithString: "")

    init(title: String, shortcut: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 14, weight: .medium)
        let shortcutField = NSTextField(labelWithString: shortcut)
        shortcutField.font = .systemFont(ofSize: 14, weight: .regular)
        shortcutField.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [titleField, NSView(), shortcutField])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) {
        titleField.stringValue = title
    }
}
