import AppKit

extension ViewController {
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

    func buildPermissionBanner() -> NSView {
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

        let titleLabel = NSTextField(labelWithString: "Snippets")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let moreButton = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")!, target: self, action: #selector(showMoreMenu(_:)))
        moreButton.bezelStyle = .rounded
        moreButton.isBordered = false
        moreButton.toolTip = "Import, Export..."

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
        headerStack.addArrangedSubview(moreButton)
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
        tableView.rowHeight = 58
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

        let helpButton = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Keyboard Shortcuts")!, target: nil, action: nil)
        helpButton.bezelStyle = .rounded
        helpButton.isBordered = false
        helpButton.toolTip = "↩ Copy  ⌘K Actions  ⌘N New  ⌘F Search  ⌘⌫ Delete  ↑↓ Navigate  ⎋ Back"

        let footerTopRow = NSStackView(views: [deleteButton, helpButton, NSView(), lastActionLabel])
        footerTopRow.orientation = .horizontal
        footerTopRow.spacing = 6
        footerTopRow.alignment = .centerY

        lastActionLabel.font = .systemFont(ofSize: 12)
        lastActionLabel.textColor = .secondaryLabelColor
        lastActionLabel.lineBreakMode = .byTruncatingTail

        importExportMessageLabel.font = .systemFont(ofSize: 12)
        importExportMessageLabel.textColor = .secondaryLabelColor
        importExportMessageLabel.lineBreakMode = .byWordWrapping
        importExportMessageLabel.maximumNumberOfLines = 2
        importExportMessageLabel.isHidden = true

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(searchField)
        rootStack.addArrangedSubview(tableScrollView)
        rootStack.addArrangedSubview(footerTopRow)
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
        keywordField.placeholderString = "tp"
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

        let separator = NSBox()
        separator.boxType = .separator

        previewSectionStack.orientation = .vertical
        previewSectionStack.spacing = 8
        previewSectionStack.alignment = .leading
        previewSectionStack.addArrangedSubview(previewLabel)
        previewSectionStack.addArrangedSubview(previewContainer)
        previewContainer.widthAnchor.constraint(equalTo: previewSectionStack.widthAnchor).isActive = true

        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(keywordLabel)
        stack.addArrangedSubview(keywordField)
        stack.addArrangedSubview(enabledCheckbox)
        stack.addArrangedSubview(snippetLabel)
        stack.addArrangedSubview(snippetScrollView)
        stack.addArrangedSubview(placeholderLabel)
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(previewSectionStack)

        contentView.addSubview(stack)
        container.addSubview(scrollView)

        [nameField, keywordField, snippetScrollView, placeholderLabel, separator, previewSectionStack].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 820).isActive = true
        let preferredEditorWidth = stack.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -40)
        preferredEditorWidth.priority = .defaultHigh
        preferredEditorWidth.isActive = true

        stack.setCustomSpacing(8, after: nameLabel)
        stack.setCustomSpacing(8, after: keywordLabel)
        stack.setCustomSpacing(10, after: snippetLabel)
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

    func buildActionOverlay(in rootView: NSView) {
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
}
