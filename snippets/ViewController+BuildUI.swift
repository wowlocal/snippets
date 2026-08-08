import AppKit

enum MainLayoutMetrics {
    static let sidebarMinWidth: CGFloat = 260
    static let sidebarMaxWidth: CGFloat = 520
    static let sidebarPreferredFraction: CGFloat = 0.28
    static let editorMinWidth: CGFloat = 230
    static let editorHorizontalPadding: CGFloat = 24
    static let previewMaxHeight: CGFloat = 150
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

/// An action the list's empty state can offer. The raw values are view tags, so
/// none of them may be 0 — that is every untagged view in the stack.
enum ListEmptyStateAction: Int {
    case newSnippet = 1
    case newFromClipboard = 2
    case importSnippets = 3
}

private enum ActionPanelContent {
    static let shortcuts: [ActionShortcutDescriptor] = [
        // The mechanic the whole app exists for led this list nowhere: a user
        // could read every row and still not know a snippet is typed, not clicked.
        ActionShortcutDescriptor(title: "Expand a Snippet", shortcut: "\\keyword", isEssential: true),
        // Beside it, because the two typed-syntax rows belong together. This is
        // where the placeholder vocabulary is written down now that the list of
        // tokens no longer sits permanently under the content box; the tokens
        // themselves are offered by completion the moment a `{` is typed.
        ActionShortcutDescriptor(title: "Insert a Placeholder", shortcut: "{", isEssential: true),
        ActionShortcutDescriptor(title: "Copy Snippet", shortcut: "↩", isEssential: true),
        ActionShortcutDescriptor(title: "Paste Snippet", shortcut: "⌘↩", isEssential: true),
        ActionShortcutDescriptor(title: "Search", shortcut: "⌘F", isEssential: true),
        ActionShortcutDescriptor(title: "Toggle Sidebar", shortcut: "⌘B", isEssential: true),
        ActionShortcutDescriptor(title: "Create New Snippet", shortcut: "⌘N", isEssential: true),
        // Beside ⌘N, where the File menu also puts it: this panel is where the
        // app's shortcuts are written down, and a list that promises all of them
        // and omits the clipboard capture reads as "there isn't one".
        ActionShortcutDescriptor(title: "New from Clipboard", shortcut: "⇧⌘N", isEssential: true),
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
        // Escape is the only way out of the panel, so it cannot be one of the
        // rows you have to already know about Option to discover.
        ActionShortcutDescriptor(title: "Dismiss Panel", shortcut: "esc", isEssential: true)
    ]

    // "Esc dismisses." is already a row in the list below, and it is `isEssential`
    // so it is in the compact list too — the tip line was saying it twice on one
    // screen. ⌥ rather than "Option" because every other glyph here is a glyph.
    static let compactTip = "Hold ⌥ for all shortcuts."
    static let expandedTip = "Release ⌥ for essentials."
}

/// Editor strings that more than one file has to agree on.
enum EditorCopy {
    /// What Name says when there is no content to show the sidebar title from.
    static let namePlaceholderFallback = "Optional"
    static let namePlaceholderCharacterLimit = 60
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

        if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
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

        permissionStatusLabel.font = .systemFont(ofSize: 13)
        permissionStatusLabel.textColor = .secondaryLabelColor
        permissionStatusLabel.lineBreakMode = .byTruncatingTail

        // No "Refresh": that button existed only because nothing else re-checked
        // the grant, which made the user do the app's polling by hand. The app
        // now re-checks whenever it comes forward, which is exactly the moment
        // someone returns from System Settings. And a bare noun is not a button
        // title — "Open Accessibility Settings" says what the click does.
        let requestButton = NSButton(title: "Request Permission", target: self, action: #selector(requestPermission))
        let accessibilityButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))

        permissionButtonsStack.orientation = .horizontal
        permissionButtonsStack.spacing = 8
        [requestButton, accessibilityButton].forEach {
            $0.controlSize = .small
            if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
                $0.bezelStyle = .glass
            } else {
                $0.bezelStyle = .rounded
            }
            permissionButtonsStack.addArrangedSubview($0)
        }

        // Icon and sentence, no title. "Permissions Required" in bold alert
        // colour was immediately followed by a sentence saying the same thing at
        // greater length, and the triangle already carries the severity.
        let leadingStatusStack = NSStackView(views: [permissionIconView, permissionStatusLabel])
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

    private func buildListEmptyState(in listContainer: NSView) {
        listEmptyStateIconView.imageScaling = .scaleProportionallyDown
        listEmptyStateIconView.contentTintColor = .tertiaryLabelColor
        listEmptyStateIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)

        listEmptyStateLabel.font = .systemFont(ofSize: 12)
        listEmptyStateLabel.textColor = .secondaryLabelColor
        listEmptyStateLabel.alignment = .center

        listEmptyStateClearButton.target = self
        listEmptyStateClearButton.action = #selector(clearTagFiltersFromEmptyState)
        listEmptyStateClearButton.controlSize = .small
        if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
            listEmptyStateClearButton.bezelStyle = .glass
        } else {
            listEmptyStateClearButton.bezelStyle = .rounded
        }

        listEmptyStateView.orientation = .vertical
        listEmptyStateView.spacing = 8
        listEmptyStateView.alignment = .centerX
        listEmptyStateView.translatesAutoresizingMaskIntoConstraints = false
        listEmptyStateView.isHidden = true
        listEmptyStateView.addArrangedSubview(listEmptyStateIconView)
        listEmptyStateView.addArrangedSubview(listEmptyStateLabel)
        for button in makeListEmptyStateActionButtons() {
            listEmptyStateView.addArrangedSubview(button)
            // One column of matching buttons: the sidebar is 260pt at its
            // narrowest, where "New from Clipboard" alone fills the row.
            button.widthAnchor.constraint(equalTo: listEmptyStateView.widthAnchor).isActive = true
        }
        listEmptyStateView.addArrangedSubview(listEmptyStateClearButton)
        listEmptyStateView.setCustomSpacing(12, after: listEmptyStateLabel)

        listContainer.addSubview(listEmptyStateView)

        NSLayoutConstraint.activate([
            listEmptyStateView.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            listEmptyStateView.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor, constant: -24),
            listEmptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: listContainer.leadingAnchor, constant: 12),
            listEmptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: listContainer.trailingAnchor, constant: -12)
        ])
    }

    private func makeListEmptyStateActionButtons() -> [NSButton] {
        [
            makeListEmptyStateActionButton(
                title: "New Snippet",
                action: #selector(createSnippet(_:)),
                tag: .newSnippet
            ),
            makeListEmptyStateActionButton(
                title: "New from Clipboard",
                action: #selector(createSnippetFromClipboard(_:)),
                tag: .newFromClipboard
            ),
            // Import is the shortest path from "no snippets" to a full library,
            // and it lived three levels deep in Menu ▸ More ▸ Import…
            makeListEmptyStateActionButton(
                title: "Import…",
                action: #selector(runImport(_:)),
                tag: .importSnippets
            )
        ]
    }

    private func makeListEmptyStateActionButton(
        title: String,
        action: Selector,
        tag: ListEmptyStateAction
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.tag = tag.rawValue
        button.controlSize = .small
        if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
        return button
    }

    /// Shows exactly `actions` in the empty state. The buttons are found by tag
    /// rather than held: a hidden arranged subview is detached from the stack's
    /// `subviews`, so `viewWithTag` would stop seeing one the moment it is hidden.
    func showListEmptyStateActions(_ actions: Set<ListEmptyStateAction>) {
        for view in listEmptyStateView.arrangedSubviews {
            guard let action = ListEmptyStateAction(rawValue: view.tag) else { continue }
            view.isHidden = !actions.contains(action)
        }
    }

    @objc private func clearTagFiltersFromEmptyState() {
        clearTagFilters()
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
        tableScrollView.scrollerStyle = .overlay

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SnippetColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.focusRingType = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
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

        tagFilterBar.isHidden = true
        tagFilterBar.onToggleTag = { [weak self] tag in
            self?.toggleTagFilter(tag)
        }
        tagFilterBar.onClearFilters = { [weak self] in
            self?.clearTagFilters()
        }

        let listContainer = LiquidGlassDesign.makeScrollFadeContainer(containing: tableScrollView)
        listContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        listContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        buildListEmptyState(in: listContainer)

        let preferredSidebarTableHeight = listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        preferredSidebarTableHeight.priority = .defaultLow
        preferredSidebarTableHeight.isActive = true

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedSnippet)
        deleteButton.image = LiquidGlassDesign.symbol("trash", pointSize: 13)
        deleteButton.imagePosition = .imageLeading
        if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
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

        rootStack.addArrangedSubview(tagFilterBar)
        rootStack.addArrangedSubview(listContainer)
        rootStack.addArrangedSubview(footerTopRow)

        tagFilterBar.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        rootStack.setCustomSpacing(8, after: listContainer)

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

        let stack = editorStack
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        nameField.delegate = self
        // A demonstration rather than a sentence: with the field empty this
        // greys out the exact title the sidebar row will use, which is the rule
        // "first line is used if blank" shown instead of described.
        // `updateNameFieldPlaceholder` keeps it in step with the content.
        nameField.placeholderString = EditorCopy.namePlaceholderFallback
        nameField.controlSize = .large

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
        // "…the text this snippet expands to" was the app's whole mechanic
        // restated in its most prominent spot on every new snippet forever, and
        // three wrapped lines of grey at a narrow width. The "Snippet" label
        // beside the box already names the field.
        snippetTextView.emptyStatePrompt = "Paste or type"
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

        keywordPrefixLabel.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        keywordPrefixLabel.textColor = .tertiaryLabelColor
        keywordPrefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        keywordPrefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        keywordField.delegate = self
        keywordField.placeholderString = "sig"
        keywordField.controlSize = .large

        // A keyword that cannot expand — empty, duplicated, or in a prefix
        // collision — says so through the field's own tooltip rather than a line
        // of prose under it. The sentence was permanent furniture for a state
        // most snippets are never in, and reserving its row left a gap under
        // every keyword that was perfectly fine.

        // This row does come and go — it exists only
        // while there is no keyword — so it collapses out of the stack rather
        // than reserving a gap under every snippet that already works.
        editorSuggestedKeywordsFlow.collapsedRowLimit = 1
        editorSuggestedKeywordsFlow.isHidden = true

        tagsField.delegate = self
        tagsField.placeholderString = "work, email"
        tagsField.controlSize = .large
        tagsField.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        tagsField.completionDelay = 0.2

        // Without a row limit the editor's chips cannot collapse, so eight
        // suggestions wrap to four rows at the narrow end and push Enabled off
        // screen on every new snippet. The filter bar has always had this.
        editorSuggestedTagsFlow.collapsedRowLimit = 1
        editorSuggestedTagsFlow.isHidden = true

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledStateChanged)
        enabledCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        let previewContainer = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        configureEditorSurface(previewContainer, backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08))

        previewValueField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        previewValueField.lineBreakMode = .byCharWrapping
        previewValueField.maximumNumberOfLines = 8
        previewValueField.allowsDefaultTighteningForTruncation = false
        previewValueField.translatesAutoresizingMaskIntoConstraints = false
        previewValueField.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        previewContainer.addSubview(previewValueField)

        NSLayoutConstraint.activate([
            previewValueField.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 10),
            previewValueField.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            previewValueField.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            previewValueField.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8)
        ])

        previewSectionStack.isHidden = true

        let keywordRow = NSStackView(views: [keywordPrefixLabel, keywordField])
        keywordRow.orientation = .horizontal
        keywordRow.spacing = 2
        keywordRow.alignment = .firstBaseline

        // Content leads: it is the only field a snippet cannot do without, and
        // the keyword follows because it is the only one that makes it fire.
        // Name, tags and the enabled toggle are all optional, so they sink.
        //
        // Keyword, Name, Tags must stay in this order: `editorNeighbor` in
        // ViewController+TextEditing.swift is a hand-wired tab loop that walks
        // exactly this sequence.
        let snippetSection = EditorFormSection(
            title: "Snippet",
            fields: [snippetContainer],
            labelSpacing: 10
        )
        // Reuses the stack the controller already holds, so `updatePreview` goes
        // on hiding one view and now collapses the label with it.
        let previewSection = EditorFormSection(
            title: "Preview",
            fields: [previewContainer],
            row: previewSectionStack
        )
        let keywordSection = EditorFormSection(
            title: "Keyword",
            fields: [keywordRow, editorSuggestedKeywordsFlow],
            fieldSpacing: 6
        )
        let nameSection = EditorFormSection(title: "Name", fields: [nameField])
        let tagsSection = EditorFormSection(
            title: "Tags",
            fields: [tagsField, editorSuggestedTagsFlow],
            fieldSpacing: 6
        )
        // No label of its own — the checkbox states a property rather than
        // filling a field, and its own title already says which.
        let enabledSection = EditorFormSection(
            title: nil,
            fields: [enabledCheckbox],
            pinsFieldWidths: false
        )

        editorSections = [
            snippetSection, previewSection, keywordSection,
            nameSection, tagsSection, enabledSection
        ]

        contentView.addSubview(stack)
        container.addSubview(scrollView)

        for section in editorSections {
            stack.addArrangedSubview(section.row)
            section.row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        previewContainer.heightAnchor.constraint(lessThanOrEqualToConstant: MainLayoutMetrics.previewMaxHeight).isActive = true
        let preferredEditorWidth = stack.widthAnchor.constraint(
            equalTo: contentView.widthAnchor,
            constant: -(MainLayoutMetrics.editorHorizontalPadding * 2)
        )
        preferredEditorWidth.isActive = true

        // The preview is a section that comes and goes, so it needs a wider gap
        // below it than the sections that are always there — otherwise its
        // arrival and departure shifts Keyword by the same amount as any other
        // row and it reads as part of the same block.
        stack.setCustomSpacing(16, after: previewSectionStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // Greater-than, not equal. Pinning the document view's bottom to the
            // clip view's bottom forced them to the same height, so the editor
            // could never be taller than its viewport and therefore never
            // scrolled: measured at a 300pt window, the document, the clip and
            // the scroll view all reported 546pt and the scroller stayed hidden,
            // i.e. the bottom of the form was pushed off the window with nothing
            // offering it back. As an inequality the document still fills a tall
            // window — which is what lets the content box grow — and grows past a
            // short one, where the scroller appears. Measured after: document 564
            // against a 300pt clip, scrollable.
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

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

        // Not "Keyboard Shortcuts": the first two rows are `\keyword` and `{`,
        // which are typed syntax rather than keyboard shortcuts.
        let actionTitle = NSTextField(labelWithString: "Shortcuts")
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
