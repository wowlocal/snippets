import AppKit

private enum MainLayoutMetrics {
    static let sidebarMinWidth: CGFloat = 300
    static let editorMinWidth: CGFloat = 360
    static let splitViewAutosaveName = NSSplitView.AutosaveName("SnippetsMainSplitView")
    static let splitViewDividerPositionDefaultsKey = "SnippetsMainSplitDividerPosition"
}

private enum EditorSurfaceMetrics {
    static let cornerRadius: CGFloat = 8
    static let borderWidth: CGFloat = 1
}

private struct ActionShortcutDescriptor {
    let title: String
    let shortcut: String
    let isEssential: Bool
}

private enum ActionPanelContent {
    static let shortcuts: [ActionShortcutDescriptor] = [
        ActionShortcutDescriptor(title: "Copy Snippet", shortcut: "↩", isEssential: true),
        ActionShortcutDescriptor(title: "Paste Snippet", shortcut: "⌘↩", isEssential: true),
        ActionShortcutDescriptor(title: "Search", shortcut: "⌘F", isEssential: true),
        ActionShortcutDescriptor(title: "Create New Snippet", shortcut: "⌘N", isEssential: true),
        ActionShortcutDescriptor(title: "Edit Snippet", shortcut: "⌘E", isEssential: true),
        ActionShortcutDescriptor(title: "Delete Snippet", shortcut: "⌘⌫", isEssential: true),
        ActionShortcutDescriptor(title: "Copy Share Link", shortcut: "⇧⌘C", isEssential: false),
        ActionShortcutDescriptor(title: "Duplicate Snippet", shortcut: "⌘D", isEssential: false),
        ActionShortcutDescriptor(title: "Enable / Disable", shortcut: "⌘/", isEssential: true),
        ActionShortcutDescriptor(title: "Pin / Unpin", shortcut: "⌘.", isEssential: true),
        ActionShortcutDescriptor(title: "Import", shortcut: "⇧⌘I", isEssential: false),
        ActionShortcutDescriptor(title: "Export", shortcut: "⇧⌘E", isEssential: false),
        ActionShortcutDescriptor(title: "Toggle Shortcuts", shortcut: "⌘K", isEssential: false),
        ActionShortcutDescriptor(title: "Next Snippet", shortcut: "⌃N", isEssential: false),
        ActionShortcutDescriptor(title: "Previous Snippet", shortcut: "⌃P", isEssential: false),
        ActionShortcutDescriptor(title: "Dismiss Panel", shortcut: "esc", isEssential: false)
    ]

    static let compactTip = "Hold Option for all keybindings. Esc dismisses."
    static let expandedTip = "Release Option for essentials. Esc dismisses."
}

extension ViewController {
    func configureEditorSurface(_ view: NSView, backgroundColor: NSColor) {
        view.wantsLayer = true
        view.layer?.cornerRadius = EditorSurfaceMetrics.cornerRadius
        view.layer?.borderWidth = EditorSurfaceMetrics.borderWidth
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.backgroundColor = backgroundColor.cgColor
        view.layer?.masksToBounds = true
    }

    func buildUI() {
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

        permissionBannerDivider.boxType = .separator
        rootStack.addArrangedSubview(permissionBannerDivider)

        let splitView = mainSplitView
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        let editor = buildEditor()

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(editor)

        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.autosaveName = MainLayoutMetrics.splitViewAutosaveName

        rootStack.addArrangedSubview(splitView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMainSplitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )

        [banner, permissionBannerDivider, splitView].forEach {
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

    @objc
    func handleMainSplitViewDidResize(_ notification: Notification) {
        guard mainSplitView.subviews.count >= 2 else { return }

        let position = mainSplitView.subviews[0].frame.width
        guard position.isFinite, position > 0 else { return }

        UserDefaults.standard.set(Double(position), forKey: MainLayoutMetrics.splitViewDividerPositionDefaultsKey)
    }

    func restoreMainSplitViewDividerIfNeeded() {
        guard !hasRestoredSplitViewDivider else { return }
        guard mainSplitView.subviews.count >= 2 else { return }

        let storedPosition = UserDefaults.standard.double(forKey: MainLayoutMetrics.splitViewDividerPositionDefaultsKey)
        guard storedPosition > 0 else {
            hasRestoredSplitViewDivider = true
            return
        }

        let proposedMinimum: CGFloat = 0
        let proposedMaximum = mainSplitView.bounds.width - mainSplitView.dividerThickness
        guard proposedMaximum > 0 else { return }

        let minPosition = splitView(mainSplitView, constrainMinCoordinate: proposedMinimum, ofSubviewAt: 0)
        let maxPosition = splitView(mainSplitView, constrainMaxCoordinate: proposedMaximum, ofSubviewAt: 0)
        let clampedPosition = min(max(CGFloat(storedPosition), minPosition), max(minPosition, maxPosition))
        mainSplitView.setPosition(clampedPosition, ofDividerAt: 0)

        hasRestoredSplitViewDivider = true
    }

    func clampedSidebarWidth(in splitView: NSSplitView, proposedWidth: CGFloat) -> CGFloat {
        let availableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
        let minimumSidebarWidth = min(MainLayoutMetrics.sidebarMinWidth, availableWidth)
        let maximumSidebarWidth = max(minimumSidebarWidth, availableWidth - MainLayoutMetrics.editorMinWidth)
        return min(max(proposedWidth, minimumSidebarWidth), maximumSidebarWidth)
    }

    func buildPermissionBanner() -> NSView {
        let container = permissionBannerContainer
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

        permissionButtonsStack.orientation = .horizontal
        permissionButtonsStack.spacing = 8
        [refreshButton, requestButton, accessibilityButton].forEach {
            $0.controlSize = .small
            $0.bezelStyle = .rounded
            permissionButtonsStack.addArrangedSubview($0)
        }

        let leadingStatusStack = NSStackView(views: [permissionIconView, permissionTitleLabel, permissionStatusLabel])
        leadingStatusStack.orientation = .horizontal
        leadingStatusStack.spacing = 8
        leadingStatusStack.alignment = .centerY

        stack.addArrangedSubview(leadingStatusStack)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(permissionButtonsStack)

        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        return container
    }

    func buildSidebar() -> NSView {
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

        let headerActionsStack = NSStackView()
        headerActionsStack.orientation = .horizontal
        headerActionsStack.spacing = 6
        headerActionsStack.alignment = .centerY
        headerActionsStack.setContentHuggingPriority(.required, for: .horizontal)
        headerActionsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        searchField.placeholderString = "Search snippets"
        searchField.delegate = self
        searchField.controlSize = .regular
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let moreButton = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")!, target: self, action: #selector(showMoreMenu(_:)))
        moreButton.controlSize = .small
        moreButton.bezelStyle = .rounded
        moreButton.isBordered = false
        moreButton.toolTip = "Import, Export..."
        moreButton.setContentHuggingPriority(.required, for: .horizontal)
        moreButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        newButton.target = self
        newButton.action = #selector(createSnippet)
        let plusConfig = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(plusConfig)
        newButton.controlSize = .small
        newButton.imagePosition = .imageLeading
        newButton.imageHugsTitle = true
        newButton.bezelStyle = .rounded
        newButton.bezelColor = ThemeManager.newButtonBezelColor
        newButton.setContentHuggingPriority(.required, for: .horizontal)
        newButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        newButton.keyEquivalent = "n"
        newButton.keyEquivalentModifierMask = [.command]
        applyThemeColors()

        let helpButton = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Keyboard Shortcuts")!, target: self, action: #selector(toggleActionPanel))
        helpButton.controlSize = .small
        helpButton.bezelStyle = .rounded
        helpButton.isBordered = false
        helpButton.toolTip = "Keyboard Shortcuts (⌘K)"
        helpButton.setContentHuggingPriority(.required, for: .horizontal)
        helpButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerStack.addArrangedSubview(searchField)
        headerActionsStack.addArrangedSubview(helpButton)
        headerActionsStack.addArrangedSubview(moreButton)
        headerActionsStack.addArrangedSubview(newButton)
        headerStack.addArrangedSubview(headerActionsStack)

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
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.contextMenuProvider = { [weak self] row in
            self?.makeSnippetContextMenu(for: row)
        }

        tableScrollView.documentView = tableView
        tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedSnippet)
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteButton.imagePosition = .imageLeading
        deleteButton.bezelStyle = .rounded

        let footerTopRow = NSStackView(views: [deleteButton, NSView(), importExportMessageLabel])
        footerTopRow.orientation = .horizontal
        footerTopRow.spacing = 6
        footerTopRow.alignment = .centerY

        importExportMessageLabel.font = .systemFont(ofSize: 12)
        importExportMessageLabel.textColor = .secondaryLabelColor
        importExportMessageLabel.alignment = .right
        importExportMessageLabel.lineBreakMode = .byTruncatingTail
        importExportMessageLabel.maximumNumberOfLines = 1
        importExportMessageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(tableScrollView)
        rootStack.addArrangedSubview(footerTopRow)

        rootStack.setCustomSpacing(10, after: headerStack)
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

    func buildEditor() -> NSView {
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

        let snippetContainer = NSView()
        snippetContainer.translatesAutoresizingMaskIntoConstraints = false
        configureEditorSurface(snippetContainer, backgroundColor: .textBackgroundColor)

        let snippetScrollView = NSScrollView()
        snippetScrollView.translatesAutoresizingMaskIntoConstraints = false
        snippetScrollView.hasVerticalScroller = true
        snippetScrollView.borderType = .noBorder
        snippetScrollView.drawsBackground = false
        snippetScrollView.scrollerStyle = .overlay

        snippetTextView.delegate = self
        snippetTextView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        snippetTextView.textColor = .textColor
        snippetTextView.drawsBackground = false
        snippetTextView.isRichText = false
        snippetTextView.isAutomaticQuoteSubstitutionEnabled = false
        snippetTextView.isAutomaticTextReplacementEnabled = false
        snippetTextView.isAutomaticDataDetectionEnabled = false
        snippetTextView.allowsUndo = true
        snippetTextView.autoresizingMask = [.width]
        snippetTextView.minSize = NSSize(width: 0, height: 220)
        snippetTextView.isVerticallyResizable = true
        snippetTextView.textContainerInset = NSSize(width: 8, height: 8)
        snippetTextView.textContainer?.widthTracksTextView = true
        snippetTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        snippetScrollView.documentView = snippetTextView
        snippetContainer.addSubview(snippetScrollView)
        snippetContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        NSLayoutConstraint.activate([
            snippetScrollView.leadingAnchor.constraint(equalTo: snippetContainer.leadingAnchor),
            snippetScrollView.trailingAnchor.constraint(equalTo: snippetContainer.trailingAnchor),
            snippetScrollView.topAnchor.constraint(equalTo: snippetContainer.topAnchor),
            snippetScrollView.bottomAnchor.constraint(equalTo: snippetContainer.bottomAnchor)
        ])

        let placeholderLabel = NSTextField(labelWithString: "Dynamic placeholders: {clipboard}, {date}, {time}, {datetime}, {date:yyyy-MM-dd}")
        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .left

        let keywordLabel = NSTextField(labelWithString: "Keyword")
        keywordLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        keywordLabel.textColor = .secondaryLabelColor
        keywordLabel.alignment = .left

        keywordPrefixLabel.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        keywordPrefixLabel.textColor = .tertiaryLabelColor
        keywordPrefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        keywordPrefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        keywordField.delegate = self
        keywordField.placeholderString = "tp"
        keywordField.controlSize = .large

        keywordWarningLabel.font = .systemFont(ofSize: 12)
        keywordWarningLabel.textColor = ThemeManager.alertColor
        keywordWarningLabel.alignment = .left
        keywordWarningLabel.isHidden = true

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledStateChanged)
        enabledCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        let previewLabel = NSTextField(labelWithString: "Preview")
        previewLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.alignment = .left

        let previewContainer = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        configureEditorSurface(previewContainer, backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08))

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

        previewSeparator.boxType = .separator
        previewSeparator.isHidden = true

        previewSectionStack.orientation = .vertical
        previewSectionStack.spacing = 8
        previewSectionStack.alignment = .leading
        previewSectionStack.isHidden = true
        previewSectionStack.addArrangedSubview(previewLabel)
        previewSectionStack.addArrangedSubview(previewContainer)
        previewContainer.widthAnchor.constraint(equalTo: previewSectionStack.widthAnchor).isActive = true

        let keywordRow = NSStackView(views: [keywordPrefixLabel, keywordField])
        keywordRow.orientation = .horizontal
        keywordRow.spacing = 2
        keywordRow.alignment = .firstBaseline

        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(keywordLabel)
        stack.addArrangedSubview(keywordRow)
        stack.addArrangedSubview(keywordWarningLabel)
        stack.addArrangedSubview(enabledCheckbox)
        stack.addArrangedSubview(snippetLabel)
        stack.addArrangedSubview(snippetContainer)
        stack.addArrangedSubview(placeholderLabel)
        stack.addArrangedSubview(previewSeparator)
        stack.addArrangedSubview(previewSectionStack)

        contentView.addSubview(stack)
        container.addSubview(scrollView)

        [nameField, keywordRow, keywordWarningLabel, snippetContainer, placeholderLabel, previewSeparator, previewSectionStack].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        let preferredEditorWidth = stack.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -40)
        preferredEditorWidth.priority = .defaultHigh
        preferredEditorWidth.isActive = true

        stack.setCustomSpacing(8, after: nameLabel)
        stack.setCustomSpacing(8, after: keywordLabel)
        stack.setCustomSpacing(4, after: keywordRow)
        stack.setCustomSpacing(10, after: snippetLabel)
        stack.setCustomSpacing(8, after: previewSeparator)

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

    func buildActionOverlay(in rootView: NSView) {
        actionOverlayView.translatesAutoresizingMaskIntoConstraints = false
        actionOverlayView.wantsLayer = true
        actionOverlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        actionOverlayView.isHidden = true
        actionOverlayView.onBackgroundClick = { [weak self] in
            self?.closeActionPanel()
        }

        actionPanelView.translatesAutoresizingMaskIntoConstraints = false
        actionPanelView.material = .popover
        actionPanelView.blendingMode = .withinWindow
        actionPanelView.state = .active
        actionPanelView.wantsLayer = true
        actionPanelView.layer?.cornerRadius = 14
        actionPanelView.layer?.borderWidth = 1
        actionPanelView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.14).cgColor
        actionPanelView.layer?.masksToBounds = true

        let actionTitle = NSTextField(labelWithString: "Keyboard Shortcuts")
        actionTitle.font = .actionPanelRoundedSystemFont(ofSize: 18, weight: .semibold)
        actionTitle.alignment = .center

        actionShortcutStack.orientation = .vertical
        actionShortcutStack.spacing = 2
        actionShortcutStack.translatesAutoresizingMaskIntoConstraints = false
        actionShortcutRows = ActionPanelContent.shortcuts.map { descriptor in
            let row = ActionShortcutRow(title: descriptor.title, shortcut: descriptor.shortcut)
            actionShortcutStack.addArrangedSubview(row)
            return (view: row, isEssential: descriptor.isEssential)
        }

        actionPanelTipLabel.font = .systemFont(ofSize: 11, weight: .medium)
        actionPanelTipLabel.textColor = .tertiaryLabelColor
        actionPanelTipLabel.alignment = .center

        let actionStack = NSStackView(views: [actionTitle, actionShortcutStack, actionPanelTipLabel])
        actionStack.orientation = .vertical
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        actionStack.setCustomSpacing(10, after: actionTitle)
        actionStack.setCustomSpacing(10, after: actionShortcutStack)

        [actionTitle, actionPanelTipLabel].forEach {
            $0.widthAnchor.constraint(equalTo: actionStack.widthAnchor).isActive = true
        }

        updateActionPanelShortcutVisibility(showAll: false)

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
            actionPanelView.leadingAnchor.constraint(greaterThanOrEqualTo: actionOverlayView.leadingAnchor, constant: 20),
            actionPanelView.trailingAnchor.constraint(lessThanOrEqualTo: actionOverlayView.trailingAnchor, constant: -20),

            actionStack.leadingAnchor.constraint(equalTo: actionPanelView.leadingAnchor, constant: 14),
            actionStack.trailingAnchor.constraint(equalTo: actionPanelView.trailingAnchor, constant: -14),
            actionStack.topAnchor.constraint(equalTo: actionPanelView.topAnchor, constant: 16),
            actionStack.bottomAnchor.constraint(equalTo: actionPanelView.bottomAnchor, constant: -12)
        ])
    }

    func updateActionPanelShortcutVisibility(showAll: Bool) {
        for shortcutRow in actionShortcutRows {
            shortcutRow.view.isHidden = !showAll && !shortcutRow.isEssential
        }

        actionPanelTipLabel.stringValue = showAll ? ActionPanelContent.expandedTip : ActionPanelContent.compactTip
    }
}

extension ViewController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        clampedSidebarWidth(in: splitView, proposedWidth: proposedPosition)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        MainLayoutMetrics.sidebarMinWidth
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let maxAllowedSidebarWidth = proposedMaximumPosition - MainLayoutMetrics.editorMinWidth
        let constrainedMaximum = max(MainLayoutMetrics.sidebarMinWidth, maxAllowedSidebarWidth)
        return min(proposedMaximumPosition, constrainedMaximum)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView === mainSplitView, splitView.subviews.count >= 2 else {
            splitView.adjustSubviews()
            return
        }

        let sidebarView = splitView.subviews[0]
        let editorView = splitView.subviews[1]
        let sidebarWidth = clampedSidebarWidth(in: splitView, proposedWidth: sidebarView.frame.width)

        var sidebarFrame = sidebarView.frame
        sidebarFrame.origin = CGPoint(x: 0, y: 0)
        sidebarFrame.size = CGSize(width: sidebarWidth, height: splitView.bounds.height)
        sidebarView.frame = sidebarFrame

        let editorOriginX = sidebarFrame.maxX + splitView.dividerThickness
        var editorFrame = editorView.frame
        editorFrame.origin = CGPoint(x: editorOriginX, y: 0)
        editorFrame.size = CGSize(width: max(0, splitView.bounds.width - editorOriginX), height: splitView.bounds.height)
        editorView.frame = editorFrame
    }
}
