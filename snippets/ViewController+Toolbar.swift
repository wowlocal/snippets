import AppKit

private extension NSToolbar.Identifier {
    static let snippetsMain = NSToolbar.Identifier("SnippetsMainToolbar")
}

private extension NSToolbarItem.Identifier {
    static let snippetsSearch = NSToolbarItem.Identifier("SnippetsToolbarSearch")
    static let snippetsMore = NSToolbarItem.Identifier("SnippetsToolbarMore")
    static let snippetsNew = NSToolbarItem.Identifier("SnippetsToolbarNew")
}

extension ViewController: NSToolbarDelegate {
    func configureMainWindowChrome(_ window: NSWindow) {
        window.title = "Snippets"
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false

        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
        }

        guard !hasConfiguredMainWindowToolbar || window.toolbar?.identifier != .snippetsMain else {
            return
        }

        let toolbar = NSToolbar(identifier: .snippetsMain)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        window.toolbar = toolbar
        hasConfiguredMainWindowToolbar = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .flexibleSpace,
            .snippetsSearch,
            .snippetsMore,
            .flexibleSpace,
            .snippetsNew
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .snippetsSearch,
            .snippetsMore,
            .snippetsNew,
            .space,
            .flexibleSpace
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sidebar"
            item.paletteLabel = "Toggle Sidebar"
            item.toolTip = "Toggle Sidebar (Command-B)"
            item.image = LiquidGlassDesign.symbol("sidebar.leading", pointSize: 16)
            item.target = self
            item.action = #selector(toggleSidebarAnimated(_:))
            LiquidGlassDesign.configureSecondaryToolbarItem(item)
            item.visibilityPriority = .standard
            return item

        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: mainSplitView,
                dividerIndex: 0
            )

        case .snippetsSearch:
            configureToolbarSearchField()
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search Snippets"
            item.toolTip = "Search Snippets"
            item.searchField = searchField
            item.preferredWidthForSearchField = 220
            item.visibilityPriority = .low
            return item

        case .snippetsMore:
            if #available(macOS 26.0, *) {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                configureMoreToolbarItem(item)
                let button = makeMoreToolbarButton(toolTip: item.toolTip)
                item.view = button
                return item
            }

            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            configureMoreToolbarItem(item)
            item.image = LiquidGlassDesign.symbol("ellipsis.circle", pointSize: 16, weight: .medium)
            item.menu = makeMoreMenu()
            item.showsIndicator = true
            item.isBordered = false
            return item

        case .snippetsNew:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New"
            item.paletteLabel = "New Snippet"
            item.toolTip = "Create New Snippet (Command-N)"
            item.image = LiquidGlassDesign.symbol("plus", pointSize: 16, weight: .semibold)
            item.target = self
            item.action = #selector(createSnippet(_:))
            LiquidGlassDesign.configurePrimaryToolbarItem(item)
            item.visibilityPriority = .standard
            return item

        default:
            return nil
        }
    }

    private func configureToolbarSearchField() {
        searchField.placeholderString = "Search snippets"
        searchField.delegate = self
        searchField.controlSize = .regular
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
    }

    private func configureMoreToolbarItem(_ item: NSToolbarItem) {
        item.label = "More"
        item.paletteLabel = "More"
        item.toolTip = "Import, Export, and Settings"
        item.visibilityPriority = .low
    }

    private func makeMoreToolbarButton(toolTip: String?) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(showMoreMenu(_:)))
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.controlSize = .regular
        button.isBordered = true
        button.imagePosition = .noImage
        button.setButtonType(.momentaryPushIn)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }

        let ellipsisView = NSImageView(image: LiquidGlassDesign.symbol("ellipsis.circle", pointSize: 18, weight: .medium) ?? NSImage())
        let chevronView = NSImageView(image: LiquidGlassDesign.symbol("chevron.down", pointSize: 9, weight: .semibold) ?? NSImage())
        [ellipsisView, chevronView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.contentTintColor = .labelColor
            $0.symbolConfiguration = .init(hierarchicalColor: .labelColor)
        }

        let imageStack = NSStackView(views: [ellipsisView, chevronView])
        imageStack.translatesAutoresizingMaskIntoConstraints = false
        imageStack.orientation = .horizontal
        imageStack.alignment = .centerY
        imageStack.spacing = 6
        imageStack.distribution = .gravityAreas
        button.addSubview(imageStack)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 36),
            imageStack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            imageStack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ellipsisView.widthAnchor.constraint(equalToConstant: 22),
            ellipsisView.heightAnchor.constraint(equalToConstant: 22),
            chevronView.widthAnchor.constraint(equalToConstant: 9),
            chevronView.heightAnchor.constraint(equalToConstant: 9)
        ])

        return button
    }
}
