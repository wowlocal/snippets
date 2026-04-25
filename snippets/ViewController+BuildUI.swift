import AppKit

private enum MainLayoutMetrics {
    static let sidebarMinWidth: CGFloat = 260
    static let sidebarMaxWidth: CGFloat = 520
    static let sidebarPreferredFraction: CGFloat = 0.28
    static let editorMinWidth: CGFloat = 320
    static let editorComfortWidth: CGFloat = 520
    static let editorHorizontalPadding: CGFloat = 24
    static let minimumInlineSidebarWidth: CGFloat = 300
    static let splitViewAutosaveName = NSSplitView.AutosaveName("SnippetsMainSplitView")
    static let splitViewDividerPositionDefaultsKey = "SnippetsMainSplitDividerPosition"
    static let sidebarCollapsedDefaultsKey = "SnippetsMainSidebarCollapsed"
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
        ActionShortcutDescriptor(title: "Toggle Sidebar", shortcut: "⌘B", isEssential: true),
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
        LiquidGlassDesign.configureEditorSurface(view, backgroundColor: backgroundColor)
    }

    func buildUI() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        view = rootView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.distribution = .fill
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(rootStack)

        let banner = buildPermissionBanner()
        rootStack.addArrangedSubview(banner)

        permissionBannerDivider.boxType = .separator
        rootStack.addArrangedSubview(permissionBannerDivider)

        configureMainSplitViewController()
        addChild(mainSplitViewController)

        let splitView = mainSplitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        rootStack.addArrangedSubview(splitView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMainSplitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: mainSplitView
        )

        [banner, permissionBannerDivider, splitView].forEach {
            $0.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }
        banner.setContentHuggingPriority(.required, for: .vertical)
        permissionBannerDivider.setContentHuggingPriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: rootView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        buildSearchSuggestionOverlay(in: rootView)
        buildActionOverlay(in: rootView)
    }

    func configureMainSplitViewController() {
        guard mainSplitViewController.splitViewItems.isEmpty else { return }

        let managedSplitView = NSSplitView()
        managedSplitView.isVertical = true
        managedSplitView.dividerStyle = .thin
        managedSplitView.autosaveName = MainLayoutMetrics.splitViewAutosaveName

        mainSplitViewController.splitView = managedSplitView
        mainSplitViewController.minimumThicknessForInlineSidebars = MainLayoutMetrics.minimumInlineSidebarWidth

        let sidebarController = NSViewController()
        sidebarController.view = buildSidebar()

        let editorController = NSViewController()
        editorController.view = buildEditor()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = MainLayoutMetrics.sidebarMinWidth
        sidebarItem.maximumThickness = MainLayoutMetrics.sidebarMaxWidth
        sidebarItem.preferredThicknessFraction = MainLayoutMetrics.sidebarPreferredFraction
        sidebarItem.canCollapse = true

        if #available(macOS 11.0, *) {
            sidebarItem.allowsFullHeightLayout = true
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let contentItem = NSSplitViewItem(viewController: editorController)
        contentItem.minimumThickness = MainLayoutMetrics.editorMinWidth
        contentItem.holdingPriority = .defaultLow

        if #available(macOS 26.0, *) {
            contentItem.automaticallyAdjustsSafeAreaInsets = true
        }

        mainSplitViewController.addSplitViewItem(sidebarItem)
        mainSplitViewController.addSplitViewItem(contentItem)

        mainSidebarSplitItem = sidebarItem
        mainContentSplitItem = contentItem
        sidebarItem.isCollapsed = UserDefaults.standard.bool(forKey: MainLayoutMetrics.sidebarCollapsedDefaultsKey)
    }

    @objc
    func handleMainSplitViewDidResize(_ notification: Notification) {
        guard mainSplitView.subviews.count >= 2 else { return }

        updateSnippetTextViewWrappingWidth()
        if isSearchSuggestionOverlayVisible {
            updateSearchSuggestionOverlay()
        }
        storeSidebarCollapsedState(isCollapsed: isSidebarCollapsed)

        guard !isSidebarCollapsed else { return }

        let position = mainSplitView.subviews[0].frame.width
        guard position.isFinite, position > 0 else { return }

        UserDefaults.standard.set(Double(position), forKey: MainLayoutMetrics.splitViewDividerPositionDefaultsKey)
    }

    func restoreMainSplitViewDividerIfNeeded() {
        guard !hasRestoredSplitViewDivider else { return }
        guard mainSplitView.subviews.count >= 2 else { return }
        guard !isSidebarCollapsed else { return }

        let storedPosition = UserDefaults.standard.double(forKey: MainLayoutMetrics.splitViewDividerPositionDefaultsKey)
        guard storedPosition > 0 else {
            hasRestoredSplitViewDivider = true
            return
        }

        let proposedMaximum = mainSplitView.bounds.width - mainSplitView.dividerThickness
        guard proposedMaximum > 0 else { return }

        let clampedPosition = clampedSidebarWidth(in: mainSplitView, proposedWidth: CGFloat(storedPosition))
        mainSplitView.setPosition(clampedPosition, ofDividerAt: 0)

        hasRestoredSplitViewDivider = true
    }

    func storeSidebarCollapsedState(isCollapsed: Bool) {
        UserDefaults.standard.set(isCollapsed, forKey: MainLayoutMetrics.sidebarCollapsedDefaultsKey)
    }

    func updateSnippetTextViewWrappingWidth() {
        guard let scrollView = snippetTextView.enclosingScrollView else { return }

        let availableWidth = scrollView.contentView.bounds.width
        guard availableWidth.isFinite, availableWidth > 0 else { return }
        guard abs(snippetTextView.frame.width - availableWidth) > 0.5 else { return }

        let availableHeight = max(snippetTextView.frame.height, scrollView.contentView.bounds.height)
        snippetTextView.setFrameSize(NSSize(width: availableWidth, height: availableHeight))

        if let textContainer = snippetTextView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
            let fullRange = NSRange(location: 0, length: snippetTextView.string.utf16.count)
            snippetTextView.layoutManager?.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            snippetTextView.layoutManager?.ensureLayout(for: textContainer)
        }
    }

    func clampedSidebarWidth(in splitView: NSSplitView, proposedWidth: CGFloat) -> CGFloat {
        let availableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
        let minimumSidebarWidth = min(MainLayoutMetrics.sidebarMinWidth, availableWidth)
        let maximumSidebarWidth = max(
            minimumSidebarWidth,
            min(MainLayoutMetrics.sidebarMaxWidth, availableWidth - MainLayoutMetrics.editorMinWidth)
        )
        return min(max(proposedWidth, minimumSidebarWidth), maximumSidebarWidth)
    }

    func buildPermissionBanner() -> NSView {
        let container = permissionBannerContainer
        container.translatesAutoresizingMaskIntoConstraints = false

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
            if #available(macOS 26.0, *) {
                $0.bezelStyle = .glass
            } else {
                $0.bezelStyle = .rounded
            }
            permissionButtonsStack.addArrangedSubview($0)
        }

        let leadingStatusStack = NSStackView(views: [permissionIconView, permissionTitleLabel, permissionStatusLabel])
        leadingStatusStack.orientation = .horizontal
        leadingStatusStack.spacing = 8
        leadingStatusStack.alignment = .centerY

        stack.addArrangedSubview(leadingStatusStack)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(permissionButtonsStack)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let surface = LiquidGlassDesign.makeTransientSurface(
            containing: contentView,
            cornerRadius: 0,
            fallbackMaterial: .contentBackground,
            tintColor: NSColor.systemOrange.withAlphaComponent(0.08)
        )
        container.addSubview(surface)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        return container
    }

    func buildSidebar() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.distribution = .fill
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        tableScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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
        let preferredSidebarTableHeight = tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        preferredSidebarTableHeight.priority = .defaultLow
        preferredSidebarTableHeight.isActive = true

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedSnippet)
        deleteButton.image = LiquidGlassDesign.symbol("trash", pointSize: 13)
        deleteButton.imagePosition = .imageLeading
        if #available(macOS 26.0, *) {
            deleteButton.bezelStyle = .glass
        } else {
            deleteButton.bezelStyle = .rounded
        }

        let footerTopRow = NSStackView(views: [deleteButton, NSView(), importExportMessageLabel])
        footerTopRow.orientation = .horizontal
        footerTopRow.spacing = 6
        footerTopRow.alignment = .centerY
        footerTopRow.setContentHuggingPriority(.required, for: .vertical)
        footerTopRow.setContentCompressionResistancePriority(.required, for: .vertical)

        importExportMessageLabel.font = .systemFont(ofSize: 12)
        importExportMessageLabel.textColor = .secondaryLabelColor
        importExportMessageLabel.alignment = .right
        importExportMessageLabel.lineBreakMode = .byTruncatingTail
        importExportMessageLabel.maximumNumberOfLines = 1
        importExportMessageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rootStack.addArrangedSubview(tableScrollView)
        rootStack.addArrangedSubview(footerTopRow)

        rootStack.setCustomSpacing(8, after: tableScrollView)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        let surface = LiquidGlassDesign.makeSidebarSurface(containing: contentView)
        container.addSubview(surface)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
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
        snippetScrollView.hasHorizontalScroller = false
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
        snippetTextView.isHorizontallyResizable = false
        snippetTextView.autoresizingMask = [.width]
        snippetTextView.minSize = NSSize(width: 0, height: 220)
        snippetTextView.isVerticallyResizable = true
        snippetTextView.textContainerInset = NSSize(width: 8, height: 8)
        snippetTextView.textContainer?.widthTracksTextView = true
        snippetTextView.textContainer?.lineBreakMode = .byCharWrapping
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
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 2

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
        let preferredEditorWidth = stack.widthAnchor.constraint(
            equalTo: contentView.widthAnchor,
            constant: -(MainLayoutMetrics.editorHorizontalPadding * 2)
        )
        preferredEditorWidth.isActive = true

        stack.setCustomSpacing(8, after: nameLabel)
        stack.setCustomSpacing(8, after: keywordLabel)
        stack.setCustomSpacing(4, after: keywordRow)
        stack.setCustomSpacing(10, after: snippetLabel)
        stack.setCustomSpacing(8, after: previewSeparator)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MainLayoutMetrics.editorHorizontalPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -MainLayoutMetrics.editorHorizontalPadding),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        return container
    }

    func buildActionOverlay(in rootView: NSView) {
        actionOverlayView.translatesAutoresizingMaskIntoConstraints = false
        actionOverlayView.wantsLayer = true
        actionOverlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.07).cgColor
        actionOverlayView.isHidden = true
        actionOverlayView.onBackgroundClick = { [weak self] in
            self?.closeActionPanel()
        }

        actionPanelView.translatesAutoresizingMaskIntoConstraints = false

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

        let panelContentView = NSView()
        panelContentView.translatesAutoresizingMaskIntoConstraints = false
        panelContentView.addSubview(actionStack)

        let actionSurface = LiquidGlassDesign.makeTransientSurface(
            containing: panelContentView,
            cornerRadius: LiquidGlassDesign.Metrics.panelCornerRadius,
            fallbackMaterial: .popover,
			tintColor: NSColor.darkGray.withAlphaComponent(0.1)
        )

        actionPanelView.addSubview(actionSurface)
        actionOverlayView.addSubview(actionPanelView)
        rootView.addSubview(actionOverlayView)

        let preferredActionPanelWidth = actionPanelView.widthAnchor.constraint(equalToConstant: 340)
        preferredActionPanelWidth.priority = .defaultHigh
        preferredActionPanelWidth.isActive = true

        NSLayoutConstraint.activate([
            actionOverlayView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            actionOverlayView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            actionOverlayView.topAnchor.constraint(equalTo: rootView.topAnchor),
            actionOverlayView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            actionPanelView.centerXAnchor.constraint(equalTo: actionOverlayView.centerXAnchor),
            actionPanelView.centerYAnchor.constraint(equalTo: actionOverlayView.centerYAnchor),
            actionPanelView.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            actionPanelView.leadingAnchor.constraint(greaterThanOrEqualTo: actionOverlayView.leadingAnchor, constant: 20),
            actionPanelView.trailingAnchor.constraint(lessThanOrEqualTo: actionOverlayView.trailingAnchor, constant: -20),

            actionSurface.leadingAnchor.constraint(equalTo: actionPanelView.leadingAnchor),
            actionSurface.trailingAnchor.constraint(equalTo: actionPanelView.trailingAnchor),
            actionSurface.topAnchor.constraint(equalTo: actionPanelView.topAnchor),
            actionSurface.bottomAnchor.constraint(equalTo: actionPanelView.bottomAnchor),

            actionStack.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor, constant: 16),
            actionStack.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -16),
            actionStack.topAnchor.constraint(equalTo: panelContentView.topAnchor, constant: 18),
            actionStack.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor, constant: -14)
        ])
    }

    func updateActionPanelShortcutVisibility(showAll: Bool) {
        for shortcutRow in actionShortcutRows {
            shortcutRow.view.isHidden = !showAll && !shortcutRow.isEssential
        }

        actionPanelTipLabel.stringValue = showAll ? ActionPanelContent.expandedTip : ActionPanelContent.compactTip
    }
}
