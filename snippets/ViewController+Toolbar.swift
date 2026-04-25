import AppKit

private extension NSToolbar.Identifier {
    static let snippetsMain = NSToolbar.Identifier("SnippetsMainToolbar")
}

private extension NSToolbarItem.Identifier {
    static let snippetsSearch = NSToolbarItem.Identifier("SnippetsToolbarSearch")
    static let snippetsShortcuts = NSToolbarItem.Identifier("SnippetsToolbarShortcuts")
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
            .snippetsShortcuts,
            .flexibleSpace,
            .snippetsNew
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .snippetsSearch,
            .snippetsShortcuts,
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

        case .snippetsShortcuts:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Shortcuts"
            item.paletteLabel = "Keyboard Shortcuts"
            item.toolTip = "Keyboard Shortcuts (Command-K)"
            item.image = LiquidGlassDesign.symbol("keyboard", pointSize: 13)
            item.target = self
            item.action = #selector(toggleActionPanel)
            LiquidGlassDesign.configureSecondaryToolbarItem(item)
            item.visibilityPriority = .low
            return item

        case .snippetsMore:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "More"
            item.paletteLabel = "More"
            item.toolTip = "Import, Export, and Settings"

            let button = NSButton(
                image: LiquidGlassDesign.symbol("ellipsis.circle", pointSize: 16) ?? NSImage(),
                target: self,
                action: #selector(showMoreMenu(_:))
            )
            button.toolTip = item.toolTip
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = true
            button.imagePosition = .imageOnly
            button.bezelStyle = .circular
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28)
            ])
            item.view = button
            item.visibilityPriority = .low
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
}
