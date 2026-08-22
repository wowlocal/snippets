import AppKit
import AuthenticationServices
import CoreImage
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import UniformTypeIdentifiers
import Vision

private enum SettingsLayout {
    static let defaultContentWidth: CGFloat = 660
    static let minimumContentWidth: CGFloat = 620
}

private enum SettingsPane: String, CaseIterable {
    case general
    case expansion
    case sync
    case secure
    case backup
    case integrations
    case diagnostics

    var title: String {
        switch self {
        case .general: "General"
        case .expansion: "Expansion"
        case .sync: "Sync"
        case .secure: "Secure"
        case .backup: "Backup"
        case .integrations: "Integrations"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .expansion: "textformat"
        case .sync: "arrow.triangle.2.circlepath"
        case .secure: "lock"
        case .backup: "externaldrive"
        case .integrations: "puzzlepiece.extension"
        case .diagnostics: "waveform.path.ecg"
        }
    }

    var contentHeight: CGFloat {
        switch self {
        case .general: 330
        case .expansion: 560
        case .sync: 480
        case .secure: 480
        case .backup: 300
        case .integrations: 500
        case .diagnostics: 480
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController = SettingsTabViewController()

    init() {
        let window = NSWindow(contentViewController: settingsViewController)
        window.title = SettingsPane.general.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(
            width: SettingsLayout.defaultContentWidth,
            height: SettingsPane.general.contentHeight
        ))
        window.contentMinSize = NSSize(
            width: SettingsLayout.minimumContentWidth,
            height: SettingsPane.general.contentHeight
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .visible
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.setFrameAutosaveName("SnippetsCompactSettingsWindow")

        super.init(window: window)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        settingsViewController.reloadFromStorage()
        settingsViewController.resizeForCurrentPane(animated: false)
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showSyncSettings() {
        settingsViewController.selectSync()
        showSettings()
    }
}

@MainActor
private final class SettingsTabViewController: NSTabViewController, NSSearchFieldDelegate {
    private static let searchItemIdentifier = NSToolbarItem.Identifier("SnippetsSettingsSearch")

    private let generalViewController = GeneralSettingsViewController()
    private let expansionViewController = ExpansionSettingsViewController()
    private let vaultViewController = VaultSettingsViewController()
    private let syncViewController = SyncSettingsViewController()
    private let backupViewController = BackupSettingsViewController()
    private let browsersViewController = BrowserSettingsViewController()
    private let diagnosticsViewController = DiagnosticsSettingsViewController()
    private let searchResultsViewController = SettingsSearchResultsViewController()
    private var searchResultsPanel: SettingsSearchResultsPanel?
    private weak var searchField: NSSearchField?

    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = false

        addTab(.general, viewController: generalViewController)
        addTab(.expansion, viewController: expansionViewController)
        addTab(.sync, viewController: syncViewController)
        addTab(.secure, viewController: vaultViewController)
        addTab(.backup, viewController: backupViewController)
        addTab(.integrations, viewController: browsersViewController)
        addTab(.diagnostics, viewController: diagnosticsViewController)

        searchResultsViewController.onSelection = { [weak self] entry in
            self?.select(entry.pane, highlighting: entry.needles)
            self?.finishSearch()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let toolbar = view.window?.toolbar else { return }
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        resizeForCurrentPane(animated: false)
    }

    func reloadFromStorage() {
        generalViewController.reloadFromStorage()
        expansionViewController.reloadFromStorage()
        vaultViewController.reloadFromStorage()
        syncViewController.reloadFromStorage()
        browsersViewController.reloadFromStorage()
        diagnosticsViewController.reloadFromStorage()
    }

    func selectSync() {
        select(.sync, highlighting: [])
    }

    func resizeForCurrentPane(animated: Bool) {
        guard selectedTabViewItemIndex >= 0,
              selectedTabViewItemIndex < tabViewItems.count,
              let rawValue = tabViewItems[selectedTabViewItemIndex].identifier as? String,
              let pane = SettingsPane(rawValue: rawValue) else { return }
        resizeWindow(for: pane, animated: animated)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let rawValue = tabViewItem?.identifier as? String,
              let pane = SettingsPane(rawValue: rawValue) else { return }
        view.window?.title = pane.title
        resizeWindow(for: pane, animated: view.window?.isVisible == true)
    }

    override func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers = super.toolbarAllowedItemIdentifiers(toolbar)
        identifiers.append(contentsOf: [.flexibleSpace, Self.searchItemIdentifier])
        return identifiers
    }

    override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers = super.toolbarDefaultItemIdentifiers(toolbar)
        identifiers.append(contentsOf: [.flexibleSpace, Self.searchItemIdentifier])
        return identifiers
    }

    override func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.searchItemIdentifier else {
            return super.toolbar(
                toolbar,
                itemForItemIdentifier: itemIdentifier,
                willBeInsertedIntoToolbar: flag
            )
        }

        let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
        item.label = ""
        item.paletteLabel = "Search Settings"
        item.toolTip = "Search Settings"
        item.visibilityPriority = .high
        item.preferredWidthForSearchField = 160
        item.searchField.placeholderString = "Search Settings"
        item.searchField.delegate = self
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        searchField = item.searchField
        return item
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResultsViewController.update(query: query)

        guard !query.isEmpty else {
            closeSearchResults()
            return
        }
        showSearchResults(relativeTo: field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        closeSearchResults()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            searchResultsViewController.moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            searchResultsViewController.moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            return searchResultsViewController.activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            finishSearch()
            return true
        default:
            return false
        }
    }

    private func addTab(_ pane: SettingsPane, viewController: NSViewController) {
        viewController.title = pane.title

        let item = NSTabViewItem(viewController: viewController)
        item.identifier = pane.rawValue
        item.label = pane.title
        item.image = NSImage(
            systemSymbolName: pane.symbolName,
            accessibilityDescription: pane.title
        )
        addTabViewItem(item)
    }

    private func select(_ pane: SettingsPane, highlighting needles: [String]) {
        guard let index = tabViewItems.firstIndex(where: {
            ($0.identifier as? String) == pane.rawValue
        }) else { return }
        let didChangePane = selectedTabViewItemIndex != index
        selectedTabViewItemIndex = index
        view.window?.title = pane.title
        if !didChangePane {
            resizeWindow(for: pane, animated: view.window?.isVisible == true)
        }

        guard !needles.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let target = self.firstMatchingView(
                    in: self.tabViewItems[index].viewController?.view,
                    needles: needles
                  ) else { return }
            target.scrollToVisible(target.bounds)
            target.alphaValue = 0.35
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.55
                target.animator().alphaValue = 1
            }
            NSAccessibility.post(element: target, notification: .focusedUIElementChanged)
        }
    }

    private func resizeWindow(for pane: SettingsPane, animated: Bool) {
        guard let window = view.window else { return }

        let contentWidth = max(
            SettingsLayout.minimumContentWidth,
            window.contentLayoutRect.width
        )
        let contentHeight = measuredContentHeight(for: pane, width: contentWidth)
        let contentSize = NSSize(width: contentWidth, height: contentHeight)
        window.contentMinSize = NSSize(
            width: SettingsLayout.minimumContentWidth,
            height: contentHeight
        )
        let targetSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        ).size
        guard abs(window.frame.width - targetSize.width) > 0.5
                || abs(window.frame.height - targetSize.height) > 0.5 else { return }

        var frame = window.frame
        frame.origin.x += (frame.width - targetSize.width) / 2
        frame.origin.y += frame.height - targetSize.height
        frame.size = targetSize
        window.setFrame(frame, display: true, animate: animated)
    }

    private func measuredContentHeight(for pane: SettingsPane, width: CGFloat) -> CGFloat {
        guard let controller = viewController(for: pane) else { return pane.contentHeight }
        controller.loadViewIfNeeded()

        let paneView = controller.view
        // The selected pane is already installed in NSTabViewController's content
        // container at this width. Do not give it a provisional height here: doing so
        // detaches its frame from that container just before the window animation.
        // When the window then grows, AppKit can leave the pane at the old bottom edge,
        // producing a large empty area above its content.
        if abs(paneView.frame.width - width) > 0.5 {
            paneView.setFrameSize(NSSize(width: width, height: paneView.frame.height))
        }
        paneView.layoutSubtreeIfNeeded()

        guard let stack = paneView.subviews.first(where: { $0 is NSStackView }) as? NSStackView else {
            return pane.contentHeight
        }
        // `frame.height` can include space distributed into a flexible arranged view
        // from the previously selected (taller) pane. Feeding that expanded frame back
        // into the window size makes the extra space permanent. `fittingSize` is the
        // compact Auto Layout height for the current visible controls.
        let measuredHeight = ceil(stack.fittingSize.height + 48)
        guard measuredHeight.isFinite, measuredHeight > 48 else {
            return pane.contentHeight
        }
        return max(220, measuredHeight)
    }

    private func viewController(for pane: SettingsPane) -> NSViewController? {
        tabViewItems.first(where: {
            ($0.identifier as? String) == pane.rawValue
        })?.viewController
    }

    private func firstMatchingView(in root: NSView?, needles: [String]) -> NSView? {
        guard let root else { return nil }
        let normalizedNeedles = needles.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let candidate: String?
        if let field = root as? NSTextField {
            candidate = field.stringValue
        } else if let button = root as? NSButton {
            candidate = button.title
        } else {
            candidate = nil
        }

        if let candidate {
            let normalized = candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if normalizedNeedles.contains(where: normalized.contains) { return root }
        }
        for child in root.subviews {
            if let result = firstMatchingView(in: child, needles: needles) { return result }
        }
        return nil
    }

    private func finishSearch() {
        closeSearchResults()
        searchField?.stringValue = ""
        searchResultsViewController.update(query: "")
    }

    private func showSearchResults(relativeTo field: NSSearchField) {
        guard let parentWindow = field.window else { return }
        let originalFirstResponder = parentWindow.firstResponder
        let panel = searchResultsPanel ?? makeSearchResultsPanel()
        searchResultsPanel = panel

        let fieldRectInWindow = field.convert(field.bounds, to: nil)
        let fieldRectOnScreen = parentWindow.convertToScreen(fieldRectInWindow)
        let panelSize = NSSize(
            width: 340,
            height: searchResultsViewController.preferredPanelHeight
        )
        let visibleFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        var origin = NSPoint(
            x: fieldRectOnScreen.maxX - panelSize.width,
            y: fieldRectOnScreen.minY - panelSize.height - 6
        )
        if let visibleFrame {
            origin.x = min(
                max(origin.x, visibleFrame.minX + 8),
                visibleFrame.maxX - panelSize.width - 8
            )
            if origin.y < visibleFrame.minY + 8 {
                origin.y = min(
                    fieldRectOnScreen.maxY + 6,
                    visibleFrame.maxY - panelSize.height - 8
                )
            }
        }
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: panel.isVisible)

        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)

        // A results window is informational while the user types. Keep the exact
        // field editor alive even if AppKit adjusts the toolbar during panel ordering.
        if let originalFirstResponder,
           parentWindow.firstResponder !== originalFirstResponder {
            parentWindow.makeFirstResponder(originalFirstResponder)
        }
    }

    private func makeSearchResultsPanel() -> SettingsSearchResultsPanel {
        let panel = SettingsSearchResultsPanel(contentViewController: searchResultsViewController)
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    private func closeSearchResults() {
        guard let panel = searchResultsPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

@MainActor
private final class SettingsSearchResultsPanel: NSPanel {
    convenience init(contentViewController: NSViewController) {
        self.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct MacSettingsSearchEntry {
    let title: String
    let pane: SettingsPane
    let terms: [String]
    let needles: [String]

    static let all: [MacSettingsSearchEntry] = [
        .init(title: "Cmd+Q Behavior", pane: .general,
              terms: ["quit", "close", "hide", "menu bar", "ask every time"],
              needles: ["Pressing Cmd+Q"]),
        .init(title: "Install Command Line Tool", pane: .general,
              terms: ["cli", "terminal", "snippets-cli", "/usr/local/bin"],
              needles: ["Command Line Tool"]),
        .init(title: "Global Shortcuts", pane: .expansion,
              terms: ["hotkey", "keyboard", "secure paste", "command backslash"],
              needles: ["Global Shortcuts"]),
        .init(title: "Accessibility Permission", pane: .expansion,
              terms: ["open accessibility settings", "paste", "permission"],
              needles: ["Open Accessibility Settings"]),
        .init(title: "Matched Letters Appearance", pane: .expansion,
              terms: ["highlight", "accent", "tint", "search match"],
              needles: ["Matched Letters"]),
        .init(title: "Rank Suggestions by Usage", pane: .expansion,
              terms: ["ranking", "frecency", "frequently used", "most used"],
              needles: ["Rank suggestions"]),
        .init(title: "Remember Selection for Typed Prefix", pane: .expansion,
              terms: ["suggestion ranking", "picked snippet", "query prefix"],
              needles: ["Remember which snippet"]),
        .init(title: "Reset Usage Data", pane: .expansion,
              terms: ["clear ranking", "forget usage", "suggestions"],
              needles: ["Reset Usage Data"]),
        .init(title: "Enable iCloud Sync", pane: .sync,
              terms: ["cloud sync", "turn on", "devices"],
              needles: ["Cloud Sync"]),
        .init(title: "Cloud Provider", pane: .sync,
              terms: ["icloud", "snippets cloud", "server"],
              needles: ["Cloud provider"]),
        .init(title: "Sync Now", pane: .sync,
              terms: ["refresh", "download", "upload", "cloud"],
              needles: ["Sync Now"]),
        .init(title: "Sync Account Recovery", pane: .sync,
              terms: ["account review", "resume", "reset cloud", "binding mismatch"],
              needles: ["Cloud Sync"]),
        .init(title: "Set Up Secure Snippets", pane: .secure,
              terms: ["vault", "touch id", "login password", "encrypt"],
              needles: ["Secure Snippets"]),
        .init(title: "Lock Secure Snippets", pane: .secure,
              terms: ["lock now", "vault", "authentication"],
              needles: ["Lock Now"]),
        .init(title: "Recovery Key", pane: .secure,
              terms: ["restore", "recover", "vault key"],
              needles: ["Secure Snippets"]),
        .init(title: "Secure Snippet Storage", pane: .secure,
              terms: ["health", "encrypted on disk", "keychain"],
              needles: ["Storage"]),
        .init(title: "Forget Secure Snippets", pane: .secure,
              terms: ["delete vault", "remove", "reset secure"],
              needles: ["Forget Secure Snippets"]),
        .init(title: "Import and Export", pane: .backup,
              terms: ["backup", "sharing", "library", "restore", "transfer"],
              needles: ["Library Transfer"]),
        .init(title: "Encrypted Backup", pane: .backup,
              terms: ["password", "secure", "restore", "private", "safekeeping"],
              needles: ["Encrypted Backup"]),
        .init(title: "Chromium Apps", pane: .integrations,
              terms: ["browser", "chrome", "edge", "brave", "opera", "vivaldi", "arc"],
              needles: ["Chromium Apps"]),
        .init(title: "Add Chromium App", pane: .integrations,
              terms: ["choose app", "custom browser", "application"],
              needles: ["Add App"]),
        .init(title: "Add Bundle ID", pane: .integrations,
              terms: ["bundle identifier", "custom chromium"],
              needles: ["Add Bundle ID"]),
        .init(title: "Remove Chromium App", pane: .integrations,
              terms: ["remove selected", "clear all", "bundle id"],
              needles: ["Remove Selected"]),
        .init(title: "Persistent Diagnostics", pane: .diagnostics,
              terms: ["logs", "retention", "privacy", "json lines"],
              needles: ["Persistent Diagnostics"]),
        .init(title: "Expansion Accessibility Logging", pane: .diagnostics,
              terms: ["verbose", "ax diagnostics", "keystroke", "this session", "always"],
              needles: ["Expansion Accessibility logging"]),
        .init(title: "Export Diagnostic Logs", pane: .diagnostics,
              terms: ["share logs", "jsonl", "support"],
              needles: ["Export Logs"]),
        .init(title: "Delete Diagnostic Logs", pane: .diagnostics,
              terms: ["clear logs", "remove diagnostics", "privacy"],
              needles: ["Delete Logs"]),
    ]

    static func results(for query: String) -> [MacSettingsSearchEntry] {
        all.compactMap { entry -> (entry: MacSettingsSearchEntry, score: Int)? in
            guard let score = entry.score(for: query) else { return nil }
            return (entry, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.entry.title.localizedCaseInsensitiveCompare(rhs.entry.title) == .orderedAscending
        }
        .map(\.entry)
    }

    private func score(for query: String) -> Int? {
        let normalizedQuery = Self.normalize(query)
        let tokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let normalizedTitle = Self.normalize(title)
        let normalizedPane = Self.normalize(pane.title)
        let normalizedTerms = terms.map(Self.normalize)
        let titleWords = normalizedTitle.split(whereSeparator: \.isWhitespace).map(String.init)
        let paneWords = normalizedPane.split(whereSeparator: \.isWhitespace).map(String.init)
        let fields = [normalizedTitle, normalizedPane] + normalizedTerms
        guard tokens.allSatisfy({ token in
            if token.count < 3 {
                return titleWords.contains(where: { $0.hasPrefix(token) })
                    || paneWords.contains(where: { $0.hasPrefix(token) })
            }
            return fields.contains(where: { $0.contains(token) })
        }) else { return nil }

        var score = 0
        if normalizedTitle == normalizedQuery { score += 1_000 }
        else if normalizedTitle.hasPrefix(normalizedQuery) { score += 700 }
        else if normalizedTitle.contains(normalizedQuery) { score += 500 }
        if normalizedPane == normalizedQuery { score += 350 }
        else if normalizedPane.hasPrefix(normalizedQuery) { score += 220 }

        for token in tokens {
            if titleWords.contains(where: { $0 == token }) { score += 160 }
            else if titleWords.contains(where: { $0.hasPrefix(token) }) { score += 120 }
            else if normalizedTitle.contains(token) { score += 80 }

            if normalizedTerms.contains(where: { $0 == token }) { score += 70 }
            else if normalizedTerms.contains(where: { $0.hasPrefix(token) }) { score += 50 }
            else if normalizedTerms.contains(where: { $0.contains(token) }) { score += 30 }
        }
        return score - min(normalizedTitle.count, 80)
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

@MainActor
private final class SettingsSearchResultsViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    var onSelection: ((MacSettingsSearchEntry) -> Void)?

    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No Results")
    private var entries: [MacSettingsSearchEntry] = []

    var preferredPanelHeight: CGFloat {
        entries.isEmpty ? 82 : CGFloat(min(entries.count, 6)) * tableView.rowHeight + 12
    }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SettingsSearchResult"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 46
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        tableView.refusesFirstResponder = true
        tableView.target = self
        tableView.action = #selector(activateClickedResult)
        scrollView.documentView = tableView

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = trimmed.isEmpty ? [] : MacSettingsSearchEntry.results(for: trimmed)
        loadViewIfNeeded()
        emptyLabel.isHidden = trimmed.isEmpty || !entries.isEmpty
        tableView.reloadData()
        if entries.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        let current = tableView.selectedRow
        let next: Int
        if current < 0 {
            next = delta < 0 ? entries.count - 1 : 0
        } else {
            next = min(max(current + delta, 0), entries.count - 1)
        }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func activateSelection() -> Bool {
        guard !entries.isEmpty else { return false }
        let row = entries.indices.contains(tableView.selectedRow) ? tableView.selectedRow : 0
        onSelection?(entries[row])
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: entry.title)
        let detail = NSTextField(labelWithString: entry.pane.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        cell.addSubview(title)
        cell.addSubview(detail)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        return cell
    }

    @objc private func activateClickedResult() {
        let row = entries.indices.contains(tableView.clickedRow)
            ? tableView.clickedRow
            : tableView.selectedRow
        guard entries.indices.contains(row) else { return }
        onSelection?(entries[row])
    }
}

@MainActor
private final class GeneralSettingsViewController: NSViewController {
    private let quitBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let selectionSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let promptSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let resetButton = NSButton(title: "Reset to Ask Every Time", target: nil, action: nil)
    private let cliInstallButton = NSButton(title: "Install CLI Tool", target: nil, action: nil)
    private let cliStatusLabel = NSTextField(wrappingLabelWithString: "")

    private static let cliInstallURL = URL(filePath: "/usr/local/bin/snippets-cli")

    private static let cliBinaryName = "snippets-cli"

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

        let closingTitle = makeSettingsSectionTitle("Closing Snippets")
        let introLabel = makeSecondaryLabel("Choose what happens when you press Cmd+Q. This matches the remembered choice from the quit confirmation dialog.")

        let behaviorLabel = NSTextField(labelWithString: "Pressing Cmd+Q:")
        behaviorLabel.textColor = .secondaryLabelColor
        behaviorLabel.font = .systemFont(ofSize: 13)
        behaviorLabel.alignment = .right
        behaviorLabel.setContentHuggingPriority(.required, for: .horizontal)
        behaviorLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true

        quitBehaviorPopup.target = self
        quitBehaviorPopup.action = #selector(handleQuitBehaviorChanged(_:))
        quitBehaviorPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let behaviorRow = NSStackView(views: [behaviorLabel, quitBehaviorPopup, NSView()])
        behaviorRow.orientation = .horizontal
        behaviorRow.alignment = .centerY
        behaviorRow.spacing = 12

        selectionSummaryLabel.font = .systemFont(ofSize: 13)
        selectionSummaryLabel.textColor = .labelColor

        promptSummaryLabel.font = .systemFont(ofSize: 12)
        promptSummaryLabel.textColor = .secondaryLabelColor

        resetButton.target = self
        resetButton.action = #selector(resetQuitBehavior)
        LiquidGlassDesign.configureActionButton(resetButton, symbolName: "arrow.counterclockwise")

        let resetRow = NSStackView(views: [resetButton, NSView()])
        resetRow.orientation = .horizontal
        resetRow.alignment = .centerY

        let cliSeparator = NSBox.horizontalSeparator()
        let cliTitle = makeSettingsSectionTitle("Command Line Tool")

        let cliIntroLabel = makeSecondaryLabel("Install snippets-cli to /usr/local/bin so agents and terminal scripts can interact with your snippets.")

        cliInstallButton.target = self
        cliInstallButton.action = #selector(installCLI)
        LiquidGlassDesign.configureActionButton(cliInstallButton, symbolName: "terminal")

        cliStatusLabel.font = .systemFont(ofSize: 12)
        cliStatusLabel.textColor = .secondaryLabelColor

        let cliRow = NSStackView(views: [cliInstallButton, NSView()])
        cliRow.orientation = .horizontal
        cliRow.alignment = .centerY

        stack.addArrangedSubview(closingTitle)
        stack.addArrangedSubview(introLabel)
        stack.addArrangedSubview(behaviorRow)
        stack.addArrangedSubview(selectionSummaryLabel)
        stack.addArrangedSubview(promptSummaryLabel)
        stack.addArrangedSubview(resetRow)
        stack.addArrangedSubview(cliSeparator)
        stack.addArrangedSubview(cliTitle)
        stack.addArrangedSubview(cliIntroLabel)
        stack.addArrangedSubview(cliRow)
        stack.addArrangedSubview(cliStatusLabel)

        behaviorRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        selectionSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        promptSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliIntroLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        configureQuitBehaviorPopup()
        reloadFromStorage()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalQuitBehaviorChange),
            name: .snippetsQuitBehaviorChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func reloadFromStorage() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        selectQuitBehavior(appDelegate.quitBehaviorPreference)
        selectionSummaryLabel.stringValue = appDelegate.quitBehaviorPreferenceDescription

        if appDelegate.hasRememberedQuitBehavior {
            promptSummaryLabel.stringValue = "A remembered Cmd+Q preference is active. Choose \u{201C}Ask Every Time\u{201D} or use the reset button if you want the dialog back."
        } else {
            promptSummaryLabel.stringValue = "Snippets will show the Cmd+Q choice dialog until you select a remembered behavior."
        }

        resetButton.isEnabled = appDelegate.hasRememberedQuitBehavior
        updateCLIStatus()
    }

    private func updateCLIStatus() {
        let installURL = Self.cliInstallURL
        let fm = FileManager.default

        guard let cliSourceURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(Self.cliBinaryName)
        else {
            cliInstallButton.isEnabled = false
            cliStatusLabel.stringValue = "snippets-cli not found in app bundle."
            return
        }

        cliInstallButton.isEnabled = true

        let destExists = fm.fileExists(atPath: installURL.path)
        let pointsHere: Bool = {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: installURL.path) else { return false }
            return dest == cliSourceURL.path
        }()

        if destExists && pointsHere {
            cliInstallButton.title = "Reinstall CLI Tool"
            cliStatusLabel.stringValue = "Installed at \(installURL.path)"
        } else if destExists {
            cliInstallButton.title = "Install CLI Tool"
            cliStatusLabel.stringValue = "\(installURL.path) exists but points elsewhere. Clicking install will replace it."
        } else {
            cliInstallButton.title = "Install CLI Tool"
            cliStatusLabel.stringValue = "Not installed."
        }
    }

    @objc private func installCLI() {
        guard let cliSourceURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(Self.cliBinaryName)
        else {
            cliStatusLabel.stringValue = "Could not locate snippets-cli inside the app bundle."
            return
        }

        let installURL = Self.cliInstallURL
        let fm = FileManager.default

        do {
            let binDir = installURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: binDir.path) {
                try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: installURL.path) {
                try fm.removeItem(at: installURL)
            }
            try fm.createSymbolicLink(at: installURL, withDestinationURL: cliSourceURL)
            updateCLIStatus()
        } catch {
            installCLIWithPrivileges(source: cliSourceURL, destination: installURL)
        }
    }

    /// Escapes a value for embedding in an AppleScript double-quoted string
    /// literal (backslashes and double quotes are the only escapes needed).
    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func installCLIWithPrivileges(source: URL, destination: URL) {
        // Two escaping layers: paths become AppleScript string literals (escaping
        // \ and "), and AppleScript's `quoted form of` handles shell quoting.
        // Raw paths are never interpolated into the shell command itself.
        let script = """
        set srcPath to \(appleScriptStringLiteral(source.path))
        set dstPath to \(appleScriptStringLiteral(destination.path))
        set dirPath to \(appleScriptStringLiteral(destination.deletingLastPathComponent().path))
        do shell script "mkdir -p " & quoted form of dirPath & " && ln -sf " & quoted form of srcPath & " " & quoted form of dstPath with administrator privileges
        """

        var appleScriptError: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&appleScriptError)

        if let errDict = appleScriptError {
            let msg = errDict[NSAppleScript.errorMessage] as? String ?? "unknown error"
            cliStatusLabel.stringValue = "Installation failed: \(msg)"
        } else {
            updateCLIStatus()
        }
    }

    @objc private func handleQuitBehaviorChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let preference = AppDelegate.QuitBehaviorPreference(rawValue: rawValue),
              let appDelegate = NSApp.delegate as? AppDelegate
        else { return }

        appDelegate.updateQuitBehaviorPreference(preference)
        reloadFromStorage()
    }

    @objc private func resetQuitBehavior() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.resetQuitBehaviorPreference(nil)
        reloadFromStorage()
    }

    @objc private func handleExternalQuitBehaviorChange() {
        reloadFromStorage()
    }

    private func configureQuitBehaviorPopup() {
        quitBehaviorPopup.removeAllItems()

        for preference in AppDelegate.QuitBehaviorPreference.allCases {
            quitBehaviorPopup.addItem(withTitle: preference.menuTitle)
            quitBehaviorPopup.lastItem?.representedObject = preference.rawValue
        }
    }

    private func selectQuitBehavior(_ preference: AppDelegate.QuitBehaviorPreference) {
        let targetRawValue = preference.rawValue

        for item in quitBehaviorPopup.itemArray where (item.representedObject as? String) == targetRawValue {
            quitBehaviorPopup.select(item)
            return
        }
    }
}

@MainActor
private final class ExpansionSettingsViewController: NSViewController {
    private let globalHotkeyCheckbox = NSButton(
        checkboxWithTitle: "Enable \(GlobalHotkeyManager.securePasteDisplayString) and \(GlobalHotkeyManager.displayString) global shortcuts",
        target: nil,
        action: nil
    )
    private let globalHotkeyStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let matchHighlightPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let matchHighlightSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let frecencyCheckbox = NSButton(
        checkboxWithTitle: "Rank suggestions by how often I use them",
        target: nil,
        action: nil
    )
    private let selectionMemoryCheckbox = NSButton(
        checkboxWithTitle: "Remember which snippet I pick for each typed prefix",
        target: nil,
        action: nil
    )
    private let frecencyStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let resetUsageButton = NSButton(title: "Reset Usage Data", target: nil, action: nil)

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

        let shortcutsTitle = makeSettingsSectionTitle("Global Shortcuts")
        let hotkeyIntro = makeSecondaryLabel(
            "Press \(GlobalHotkeyManager.securePasteDisplayString) to search and insert without using the clipboard. "
            + "Press \(GlobalHotkeyManager.displayString) to show, hide, or launch Snippets. "
            + "Secure snippets authenticate on every insertion and are never copied."
        )
        globalHotkeyCheckbox.target = self
        globalHotkeyCheckbox.action = #selector(handleGlobalHotkeyChanged(_:))
        globalHotkeyStatusLabel.font = .systemFont(ofSize: 12)
        globalHotkeyStatusLabel.textColor = .secondaryLabelColor

        let accessibilityButton = NSButton(
            title: "Open Accessibility Settings…",
            target: self,
            action: #selector(openAccessibilitySettings)
        )
        LiquidGlassDesign.configureActionButton(accessibilityButton, symbolName: "hand.raised")
        let accessibilityRow = NSStackView(views: [accessibilityButton, NSView()])
        accessibilityRow.orientation = .horizontal

        let matchSeparator = NSBox.horizontalSeparator()
        let matchTitle = makeSettingsSectionTitle("Matched Letters")
        let matchIntro = makeSecondaryLabel(
            "Choose how the suggestion panel marks letters matched by your query. Changes apply to the next panel you open."
        )
        let matchLabel = NSTextField(labelWithString: "Appearance:")
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.alignment = .right
        matchLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        matchHighlightPopup.target = self
        matchHighlightPopup.action = #selector(handleMatchHighlightChanged(_:))
        let matchRow = NSStackView(views: [matchLabel, matchHighlightPopup, NSView()])
        matchRow.orientation = .horizontal
        matchRow.alignment = .centerY
        matchRow.spacing = 10
        matchHighlightSummaryLabel.font = .systemFont(ofSize: 12)
        matchHighlightSummaryLabel.textColor = .secondaryLabelColor

        let rankingSeparator = NSBox.horizontalSeparator()
        let rankingTitle = makeSettingsSectionTitle("Suggestion Ranking")
        let rankingIntro = makeSecondaryLabel(
            "Frequently used snippets can move to the top. Pinned snippets and exact keyword matches always keep priority; usage stays on this Mac."
        )
        frecencyCheckbox.target = self
        frecencyCheckbox.action = #selector(handleFrecencyChanged(_:))
        selectionMemoryCheckbox.target = self
        selectionMemoryCheckbox.action = #selector(handleSelectionMemoryChanged(_:))
        frecencyStatusLabel.font = .systemFont(ofSize: 12)
        frecencyStatusLabel.textColor = .secondaryLabelColor
        resetUsageButton.target = self
        resetUsageButton.action = #selector(resetUsageData)
        LiquidGlassDesign.configureActionButton(resetUsageButton, symbolName: "arrow.counterclockwise")
        let resetRow = NSStackView(views: [resetUsageButton, NSView()])
        resetRow.orientation = .horizontal

        for item in [
            shortcutsTitle,
            hotkeyIntro,
            globalHotkeyCheckbox,
            globalHotkeyStatusLabel,
            accessibilityRow,
            matchSeparator,
            matchTitle,
            matchIntro,
            matchRow,
            matchHighlightSummaryLabel,
            rankingSeparator,
            rankingTitle,
            rankingIntro,
            frecencyCheckbox,
            selectionMemoryCheckbox,
            frecencyStatusLabel,
            resetRow,
        ] {
            stack.addArrangedSubview(item)
        }

        for item in [
            hotkeyIntro,
            globalHotkeyStatusLabel,
            matchSeparator,
            matchIntro,
            matchRow,
            matchHighlightSummaryLabel,
            rankingSeparator,
            rankingIntro,
            frecencyStatusLabel,
        ] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        configureMatchHighlightPopup()
        reloadFromStorage()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalGlobalHotkeyChange),
            name: .snippetsGlobalHotkeyChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func reloadFromStorage() {
        guard isViewLoaded else { return }
        updateGlobalHotkeyControls()
        applyMatchHighlightControls()
        applyFrecencyControls()
    }

    private func updateGlobalHotkeyControls() {
        let manager = GlobalHotkeyManager.shared
        manager.syncRegistration()
        globalHotkeyCheckbox.state = manager.isEnabled ? .on : .off
        if !manager.isEnabled {
            globalHotkeyStatusLabel.stringValue = "Global shortcuts are off."
        } else if manager.isActive && manager.isSecurePasteActive {
            globalHotkeyStatusLabel.stringValue = "Both shortcuts are ready. Secure Paste requires Accessibility access."
        } else if manager.isActive {
            globalHotkeyStatusLabel.stringValue = "\(GlobalHotkeyManager.displayString) works, but macOS couldn't register \(GlobalHotkeyManager.securePasteDisplayString)."
        } else if manager.isSecurePasteActive {
            globalHotkeyStatusLabel.stringValue = "\(GlobalHotkeyManager.securePasteDisplayString) works, but macOS couldn't register \(GlobalHotkeyManager.displayString)."
        } else {
            globalHotkeyStatusLabel.stringValue = "macOS couldn't register either shortcut. Another app may be using them."
        }
    }

    @objc private func handleExternalGlobalHotkeyChange() {
        updateGlobalHotkeyControls()
    }

    @objc private func handleGlobalHotkeyChanged(_ sender: NSButton) {
        GlobalHotkeyManager.shared.isEnabled = sender.state == .on
        updateGlobalHotkeyControls()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func configureMatchHighlightPopup() {
        matchHighlightPopup.removeAllItems()
        for style in MatchHighlightStyle.allCases {
            matchHighlightPopup.addItem(withTitle: style.menuTitle)
            matchHighlightPopup.lastItem?.representedObject = style.rawValue
        }
    }

    private func applyMatchHighlightControls() {
        let style = MatchHighlightPreference.style
        for item in matchHighlightPopup.itemArray
        where (item.representedObject as? String) == style.rawValue {
            matchHighlightPopup.select(item)
            break
        }
        matchHighlightSummaryLabel.stringValue = style.summary
    }

    @objc private func handleMatchHighlightChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let style = MatchHighlightStyle(rawValue: rawValue) else { return }
        MatchHighlightPreference.style = style
        applyMatchHighlightControls()
    }

    private func applyFrecencyControls() {
        guard let usageStore = (NSApp.delegate as? AppDelegate)?.usageStore else { return }

        frecencyCheckbox.state = usageStore.isRankingEnabled ? .on : .off
        selectionMemoryCheckbox.state = usageStore.isSelectionMemoryEnabled ? .on : .off
        selectionMemoryCheckbox.isEnabled = usageStore.isRankingEnabled && !usageStore.isReadOnly
        let tracked = usageStore.trackedSnippetCount
        if usageStore.isReadOnly {
            frecencyStatusLabel.stringValue = "Usage data was written by a newer version. Ranking is paused."
        } else {
            frecencyStatusLabel.stringValue = tracked == 0
                ? "No usage recorded yet."
                : "Tracking \(tracked) snippet\(tracked == 1 ? "" : "s") — \(usageStore.storageFootprintDescription)."
        }
        resetUsageButton.isEnabled = tracked > 0 && !usageStore.isReadOnly
    }

    @objc private func handleFrecencyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: SnippetUsageStore.rankingEnabledKey)
        applyFrecencyControls()
    }

    @objc private func handleSelectionMemoryChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: SnippetUsageStore.selectionMemoryEnabledKey)
        if !enabled {
            (NSApp.delegate as? AppDelegate)?.usageStore.forgetAllBindings()
        }
        applyFrecencyControls()
    }

    @objc private func resetUsageData() {
        guard let usageStore = (NSApp.delegate as? AppDelegate)?.usageStore,
              usageStore.trackedSnippetCount > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Reset Usage Data?"
        alert.informativeText = "Suggestions return to pinned-then-newest-first order. Your snippets are not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Usage Data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        usageStore.eraseAll()
        applyFrecencyControls()
        frecencyStatusLabel.stringValue = "Usage data reset."
    }
}

@MainActor
private final class BackupSettingsViewController: NSViewController {
    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

        let transferTitle = makeSettingsSectionTitle("Library Transfer")
        let transferDescription = makeSecondaryLabel(
            "Import a Snippets library or export ordinary snippets for sharing. "
            + "Sharing exports are not encrypted and never include secure-snippet text."
        )
        let importButton = NSButton(
            title: "Import Library…",
            target: self,
            action: #selector(importLibrary)
        )
        LiquidGlassDesign.configureActionButton(importButton, symbolName: "square.and.arrow.down")
        let exportButton = NSButton(
            title: "Export for Sharing…",
            target: self,
            action: #selector(exportForSharing)
        )
        LiquidGlassDesign.configureActionButton(exportButton, symbolName: "square.and.arrow.up")
        let transferButtons = NSStackView(views: [importButton, exportButton, NSView()])
        transferButtons.orientation = .horizontal
        transferButtons.alignment = .centerY
        transferButtons.spacing = 8

        let separator = NSBox.horizontalSeparator()

        let encryptedTitle = makeSettingsSectionTitle("Encrypted Backup")
        let encryptedDescription = makeSecondaryLabel(
            "Create a password-protected backup of ordinary and secure snippets for safekeeping. "
            + "You need the password to restore it."
        )
        let encryptedButton = NSButton(
            title: "Export Encrypted Backup…",
            target: self,
            action: #selector(exportEncryptedBackup)
        )
        LiquidGlassDesign.configureActionButton(encryptedButton, symbolName: "lock.doc")
        let encryptedButtonRow = NSStackView(views: [encryptedButton, NSView()])
        encryptedButtonRow.orientation = .horizontal
        encryptedButtonRow.alignment = .centerY

        for item in [
            transferTitle,
            transferDescription,
            transferButtons,
            separator,
            encryptedTitle,
            encryptedDescription,
            encryptedButtonRow,
        ] {
            stack.addArrangedSubview(item)
        }

        for item in [
            transferDescription,
            transferButtons,
            separator,
            encryptedDescription,
            encryptedButtonRow,
        ] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func importLibrary() {
        (NSApp.delegate as? AppDelegate)?.importSnippets(nil)
    }

    @objc private func exportForSharing() {
        (NSApp.delegate as? AppDelegate)?.exportSnippets(nil)
    }

    @objc private func exportEncryptedBackup() {
        (NSApp.delegate as? AppDelegate)?.exportEncryptedBackup(nil)
    }
}

@MainActor
private final class BrowserSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct BundleIDRow {
        let appName: String
        let bundleID: String
        let installed: Bool
    }

    private enum ColumnID {
        static let app = NSUserInterfaceItemIdentifier("SettingsAppColumn")
        static let bundleID = NSUserInterfaceItemIdentifier("SettingsBundleIDColumn")
    }

    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let removeButton = NSButton(title: "Remove Selected", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear All", target: nil, action: nil)

    private var customBundleIDs: [String] = []
    private var rows: [BundleIDRow] = []

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

        let title = makeSettingsSectionTitle("Chromium Apps")
        let introLabel = makeSecondaryLabel("Add custom Chromium-based apps so Snippets primes their accessibility and inserts text the way Chromium accepts it. Built-in support already includes Chrome, Chromium, Edge, Brave, Opera, Vivaldi, and Arc.")
        let builtInLabel = makeTertiaryLabel("Use this pane only for extra apps that are not covered by the built-in browser list.")

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let appColumn = NSTableColumn(identifier: ColumnID.app)
        appColumn.title = "App"
        appColumn.width = 220
        appColumn.resizingMask = .userResizingMask

        let bundleIDColumn = NSTableColumn(identifier: ColumnID.bundleID)
        bundleIDColumn.title = "Bundle ID"
        bundleIDColumn.width = 420
        bundleIDColumn.resizingMask = .autoresizingMask

        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(bundleIDColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.rowHeight = 32
        tableView.allowsEmptySelection = true
        tableView.delegate = self
        tableView.dataSource = self
        if #available(macOS 11.0, *) {
            tableView.style = .inset
        }
        scrollView.documentView = tableView

        let addAppButton = NSButton(title: "Add App...", target: self, action: #selector(addApp))
        let addBundleIDButton = NSButton(title: "Add Bundle ID...", target: self, action: #selector(addBundleID))
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        LiquidGlassDesign.configureActionButton(addAppButton, symbolName: "app.badge")
        LiquidGlassDesign.configureActionButton(addBundleIDButton, symbolName: "plus.square")
        LiquidGlassDesign.configureActionButton(removeButton, symbolName: "minus.circle")
        LiquidGlassDesign.configureActionButton(clearButton, symbolName: "trash")

        let tableSurface = NSView()
        tableSurface.translatesAutoresizingMaskIntoConstraints = false
        LiquidGlassDesign.configureRoundedLayer(
            tableSurface,
            cornerRadius: LiquidGlassDesign.Metrics.contentCornerRadius,
            borderColor: NSColor.separatorColor.withAlphaComponent(0.18),
            backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.16)
        )
        tableSurface.addSubview(scrollView)

        let buttonRow = NSStackView(views: [addAppButton, addBundleIDButton, NSView(), removeButton, clearButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(introLabel)
        stack.addArrangedSubview(builtInLabel)
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(tableSurface)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(statusLabel)

        tableSurface.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let preferredTableHeight = tableSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        preferredTableHeight.priority = .defaultLow
        preferredTableHeight.isActive = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: tableSurface.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableSurface.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: tableSurface.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableSurface.bottomAnchor)
        ])
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        reloadFromStorage()
    }

    func reloadFromStorage() {
        customBundleIDs = ChromiumBundleIDSettings.additionalBundleIDs()
        statusLabel.stringValue = ""
        rebuildRows()
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.prompt = "Add App"
        panel.message = "Choose an app to add its bundle identifier."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
            showWarningAlert(
                title: "Couldn't Read Bundle ID",
                message: "\(url.lastPathComponent) doesn't expose a bundle identifier."
            )
            return
        }

        appendBundleIDs([bundleID], source: url.lastPathComponent)
    }

    @objc private func addBundleID() {
        let alert = NSAlert()
        alert.messageText = "Add Bundle ID"
        alert.informativeText = "Paste one or more bundle IDs (one per line; commas and semicolons also work)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let inputScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 86))
        inputScrollView.borderType = .bezelBorder
        inputScrollView.hasVerticalScroller = true

        let inputTextView = NSTextView(frame: inputScrollView.bounds)
        inputTextView.isRichText = false
        inputTextView.isAutomaticQuoteSubstitutionEnabled = false
        inputTextView.isAutomaticTextReplacementEnabled = false
        inputTextView.isAutomaticSpellingCorrectionEnabled = false
        inputTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inputTextView.textContainerInset = NSSize(width: 6, height: 6)
        inputTextView.textContainer?.widthTracksTextView = true
        inputScrollView.documentView = inputTextView
        alert.accessoryView = inputScrollView

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let incoming = ChromiumBundleIDSettings.normalizedBundleIDs(from: inputTextView.string)
        guard !incoming.isEmpty else {
            statusLabel.stringValue = "No bundle IDs were added."
            return
        }

        appendBundleIDs(incoming, source: nil)
    }

    @objc private func removeSelected() {
        let selected = tableView.selectedRow
        guard selected >= 0 && selected < customBundleIDs.count else { return }

        var updated = customBundleIDs
        let removed = updated.remove(at: selected)
        applyAndPersist(updated)
        statusLabel.stringValue = "Removed \(removed)."
    }

    @objc private func clearAll() {
        guard !customBundleIDs.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Clear All Custom Bundle IDs?"
        alert.informativeText = "Built-in browser IDs stay enabled. This only removes your custom entries."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyAndPersist([])
        statusLabel.stringValue = "Cleared all custom bundle IDs."
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    private func appendBundleIDs(_ incoming: [String], source: String?) {
        var updated = customBundleIDs
        var seen = Set(customBundleIDs.map { $0.lowercased() })
        var addedCount = 0

        for bundleID in incoming {
            let key = bundleID.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            updated.append(bundleID)
            addedCount += 1
        }

        guard addedCount > 0 else {
            statusLabel.stringValue = "Those bundle IDs are already in the list."
            return
        }

        applyAndPersist(updated)
        if let source {
            statusLabel.stringValue = "Added \(addedCount) bundle ID from \(source)."
        } else {
            statusLabel.stringValue = "Added \(addedCount) bundle ID(s)."
        }
    }

    private func applyAndPersist(_ updatedBundleIDs: [String]) {
        customBundleIDs = updatedBundleIDs
        ChromiumBundleIDSettings.saveAdditionalBundleIDs(updatedBundleIDs)
        NotificationCenter.default.post(name: .snippetsChromiumBundleIDsChanged, object: nil)
        rebuildRows()
    }

    private func rebuildRows() {
        rows = customBundleIDs.map { bundleID in
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return BundleIDRow(
                    appName: appName(from: appURL),
                    bundleID: bundleID,
                    installed: true
                )
            }

            return BundleIDRow(
                appName: "Unknown App",
                bundleID: bundleID,
                installed: false
            )
        }

        countLabel.stringValue = "\(customBundleIDs.count) custom app(s)"
        tableView.reloadData()
        updateButtonStates()
    }

    private func appName(from appURL: URL) -> String {
        guard let bundle = Bundle(url: appURL) else {
            return appURL.deletingPathExtension().lastPathComponent
        }

        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let name = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String,
           !name.isEmpty {
            return name
        }

        return appURL.deletingPathExtension().lastPathComponent
    }

    private func updateButtonStates() {
        let hasSelection = tableView.selectedRow >= 0 && tableView.selectedRow < rows.count
        removeButton.isEnabled = hasSelection
        clearButton.isEnabled = !rows.isEmpty
    }

    private func showWarningAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < rows.count, let tableColumn else { return nil }
        let item = rows[row]

        if tableColumn.identifier == ColumnID.app {
            let text = item.installed ? item.appName : "Unknown App (not installed)"
            return configuredCell(
                identifier: NSUserInterfaceItemIdentifier("SettingsAppCell"),
                text: text,
                font: .systemFont(ofSize: 12),
                color: item.installed ? .labelColor : .secondaryLabelColor
            )
        }

        return configuredCell(
            identifier: NSUserInterfaceItemIdentifier("SettingsBundleIDCell"),
            text: item.bundleID,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: .labelColor
        )
    }

    private func configuredCell(
        identifier: NSUserInterfaceItemIdentifier,
        text: String,
        font: NSFont,
        color: NSColor
    ) -> NSTableCellView {
        let cell: NSTableCellView
        let textField: NSTextField

        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView,
           let existing = reused.textField {
            cell = reused
            textField = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        textField.font = font
        textField.textColor = color
        textField.lineBreakMode = .byTruncatingMiddle
        textField.stringValue = text
        return cell
    }
}

// MARK: - Secure snippets

@MainActor
private final class VaultSettingsViewController: NSViewController {
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let tierLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "Set Up Secure Snippets", target: nil, action: nil)
    private let lockButton = NSButton(title: "Lock Now", target: nil, action: nil)
    private let resetButton = NSButton(title: "Forget Secure Snippets", target: nil, action: nil)
    private let healthLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

        let title = NSTextField(labelWithString: "Secure Snippets")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        // The honest version. A settings pane that says "end-to-end encrypted" and stops
        // there is the reason people put things in a text expander that should not be in
        // one.
        let intro = makeSecondaryLabel(
            "A secure snippet's text is encrypted on disk and unlocked with Touch ID or your login password. "
            + "Its name, keyword and tags are not encrypted \u{2014} Snippets has to recognise the keyword "
            + "while the vault is locked, so anyone with access to this Mac's files can see that a "
            + "secure snippet exists and what it is called, just not what it contains.")

        let limits = makeTertiaryLabel(
            "Secure snippets never appear in exports or share links, and are never expanded "
            + "automatically by typing their keyword \u{2014} you pick them from the list. "
            + "This protects your snippets at rest and in transit; it cannot protect them from "
            + "someone using your Mac while you are signed in.")

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        LiquidGlassDesign.configureActionButton(primaryButton, symbolName: "lock.shield")

        lockButton.target = self
        lockButton.action = #selector(lockNow)
        LiquidGlassDesign.configureActionButton(lockButton, symbolName: "lock")

        resetButton.target = self
        resetButton.action = #selector(forgetVault)
        resetButton.bezelStyle = .rounded
        resetButton.hasDestructiveAction = true

        let buttonRow = NSStackView(views: [primaryButton, lockButton, NSView()])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let healthTitle = NSTextField(labelWithString: "Storage")
        healthTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(tierLabel)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(limits)
        stack.addArrangedSubview(NSBox.horizontalSeparator())
        stack.addArrangedSubview(healthTitle)
        stack.addArrangedSubview(healthLabel)
        stack.addArrangedSubview(resetButton)

        for label in [intro, limits, statusLabel, tierLabel, healthLabel] {
            label.preferredMaxLayoutWidth = 620
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadFromStorage()
    }

    func reloadFromStorage() {
        guard isViewLoaded, let app = NSApp.delegate as? AppDelegate else { return }
        let secure = app.secureStore
        let session = app.vaultSession

        if secure.isUnreadable {
            statusLabel.stringValue =
                "The secure vault exists but this build cannot read it. It has been left untouched."
            primaryButton.isHidden = true
            lockButton.isHidden = true
        } else {
            switch session.state {
            case .noKey where !secure.hasVault:
                statusLabel.stringValue = "Not set up on this Mac."
                primaryButton.title = "Set Up Secure Snippets"
                primaryButton.isHidden = false
                lockButton.isHidden = true
            case .noKey:
                // Records exist but the key does not — a restored file, or a keychain the
                // user cleared. Say so precisely; "locked" would be a lie that leads to a
                // Touch ID prompt that can never succeed.
                statusLabel.stringValue =
                    "\(secure.count) secure snippet(s) are here, but the key for them is not on this Mac. "
                    + "They cannot be read until the key is restored."
                primaryButton.title = "Restore with Recovery Key"
                primaryButton.isHidden = !secure.hasRecoveryKey
                lockButton.isHidden = true
            case .locked:
                statusLabel.stringValue = "\(secure.count) secure snippet(s). Locked."
                primaryButton.title = secure.hasRecoveryKey ? "Unlock" : "Unlock & Set Up Recovery"
                primaryButton.isHidden = false
                lockButton.isHidden = true
            case .unlocked(let until):
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                statusLabel.stringValue =
                    "\(secure.count) secure snippet(s). Unlocked until \(formatter.string(from: until))."
                primaryButton.title = "Set Up Recovery Key"
                primaryButton.isHidden = secure.hasRecoveryKey
                lockButton.isHidden = false
            }
        }

        tierLabel.stringValue = session.keychainStatusDescription
        tierLabel.textColor = session.syncsBetweenDevices ? .secondaryLabelColor : .tertiaryLabelColor
        resetButton.isHidden = secure.isUnreadable || !secure.hasVault

        // The degraded-write signal the review asked for. Previously this was NSLogged
        // and nothing read it, so a user whose filesystem cannot lock sat in a
        // permanently lossy configuration with no indication at all.
        switch app.store.writeHealth {
        case .healthy:
            healthLabel.stringValue = "Snippets are saved normally."
            healthLabel.textColor = .secondaryLabelColor
        case .contended(let attempts):
            healthLabel.stringValue =
                "Another program is writing your snippets at the same time as Snippets "
                + "(last save took \(attempts) attempts). Nothing has been lost, but if this "
                + "persists something else is editing the library."
            healthLabel.textColor = .systemOrange
        case .unlocked:
            healthLabel.stringValue =
                "This location does not support file locking, so Snippets cannot fully "
                + "coordinate with other programs writing the same library. Concurrent edits "
                + "may be lost. This usually means your home folder is on a network drive."
            healthLabel.textColor = .systemRed
        }
    }

    @objc private func primaryAction() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await performPrimaryAction(app)
        }
    }

    private func performPrimaryAction(_ app: AppDelegate) async {
        do {
            switch app.vaultSession.state {
            case .noKey where !app.secureStore.hasVault:
                try app.secureStore.createVaultIfNeeded(
                    confirmRecoveryKey: presentRecoveryKeyForSaving)
                try await app.vaultSession.unlock(reason: "Unlock your secure snippets")

            case .noKey:
                guard let recoveryKey = requestRecoveryKey() else { return }
                try app.secureStore.restoreKey(fromRecoveryKey: recoveryKey)
                try await app.vaultSession.unlock(reason: "Restore your secure snippets")

            case .locked:
                try await app.vaultSession.unlock(reason: "Unlock your secure snippets")
                if !app.secureStore.hasRecoveryKey {
                    _ = try app.secureStore.addRecoveryKeyIfNeeded(
                        confirmRecoveryKey: presentRecoveryKeyForSaving)
                }

            case .unlocked:
                _ = try app.secureStore.addRecoveryKeyIfNeeded(
                    confirmRecoveryKey: presentRecoveryKeyForSaving)
            }
        } catch SecureSnippetStore.Failure.setupCancelled {
            // Setup never committed, so cancellation needs no warning.
        } catch {
            showVaultError(error)
        }
        reloadFromStorage()
    }

    private func requestRecoveryKey() -> String? {
        let alert = NSAlert()
        alert.messageText = "Restore secure snippets"
        alert.informativeText = "Enter the recovery key you saved when this vault was created."

        let field = NSTextField(string: "")
        field.placeholderString = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX"
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 430, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    @objc private func lockNow() {
        (NSApp.delegate as? AppDelegate)?.vaultSession.lock()
        reloadFromStorage()
    }

    /// Destructive and irreversible, so the confirmation names the number and says the
    /// word "permanently" rather than asking "are you sure?".
    @objc private func forgetVault() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let count = app.secureStore.count

        // Refused outright while sync is on — the next fetch would immediately restore
        // a locally removed shared vault. Meeting a destructive confirmation first only
        // to be told "no" afterwards is worse than being told now.
        guard !SyncCoordinator.isEnabled else {
            let alert = NSAlert()
            alert.messageText = "Turn off cloud sync first"
            alert.informativeText = "\(SecureSnippetStore.Failure.forgetRequiresSyncOff)"
            alert.runModal()
            return
        }

        // Turning the checkbox off cancels the active CloudKit task, but cancellation
        // across an awaited backend call is not instantaneous. Do not delete beneath the
        // old engine until it has returned and can no longer write a base or tombstones.
        guard app.syncCoordinator.isQuiescent else {
            let alert = NSAlert()
            alert.messageText = "Cloud sync is still stopping"
            alert.informativeText = "Wait a moment for the current sync round to finish, then try again."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = app.secureStore.usesSynchronizableVaultKey
            ? "Remove \(count) secure snippet(s) from this Mac?"
            : "Permanently delete \(count) secure snippet(s)?"
        // A synchronizable Keychain item cannot be deleted locally: its deletion would
        // reach every Mac. The store therefore preserves the shared key and identity and
        // removes only this Mac's vault. Device-only builds keep the original permanent
        // deletion semantics.
        alert.informativeText = app.secureStore.usesSynchronizableVaultKey
            ? "This permanently removes this Mac's encrypted copies while preserving the "
                + "shared key. Snippets cannot tell whether these records finished syncing "
                + "or another Mac has a copy. Anything that exists only on this Mac will be "
                + "lost; re-enabling cloud sync can restore only records already uploaded. "
                + "There is no local undo."
            : "This deletes the encrypted snippets and the key that opens them. "
                + "There is no undo, and no export or backup of this app contains their text."
        alert.addButton(withTitle: app.secureStore.usesSynchronizableVaultKey ? "Remove" : "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try app.secureStore.forgetEverything(
                syncIsQuiescent: app.syncCoordinator.isQuiescent)
            app.syncLibrary.forgetSecureProjectionMetadata()
        } catch {
            showVaultError(error)
        }
        reloadFromStorage()
    }

    private func showVaultError(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Secure snippets"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}

private extension NSBox {
    static func horizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)
        return box
    }
}

/// The opt-in switch for the selected cloud provider, and an honest account of what it does.
///
/// Off by default, and off means nothing is constructed — see `SyncCoordinator`.
///
/// This pane used to carry two "waiting" states and a paragraph of manual setup, because
/// sync sealed with the vault key: it could not start without Secure Snippets and could
/// not run without an unlocked vault, and a second Mac minted its own key and could not
/// read a thing. `SyncKeyStore` and `VaultIdentityStore` removed all three, so what is
/// left to say is what actually happens.
@MainActor
private final class SyncSettingsViewController: NSViewController {
    private let enableCheckbox = NSButton(
        checkboxWithTitle: "Sync snippets with the selected cloud", target: nil, action: nil)
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let configureCloudButton = NSButton(title: "Configure…", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)
    private let recoveryButton = NSButton(title: "", target: nil, action: nil)
    private let secondMacLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var actionRow = NSStackView(views: [
        syncNowButton,
        recoveryButton,
        NSView(),
    ])
    private weak var cloudAccountSheet: NSWindow?
    private var backendSelection: SyncBackendSelectionStore {
        (NSApp.delegate as? AppDelegate)?.backendSelection ?? SyncBackendSelectionStore()
    }
    private lazy var cloudBootstrap = SnippetsCloudAccountBootstrap(
        selection: backendSelection)

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

        let title = NSTextField(labelWithString: "Cloud Sync")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let cloudFeatureEnabled = backendSelection.snippetsCloudEnabled
        let intro = makeSecondaryLabel(cloudFeatureEnabled
            ? "Choose iCloud or Snippets Cloud without migrating away from either one. "
                + "Only the selected provider is writable. Every snippet is encrypted on this Mac "
                + "before it leaves; both providers carry the same opaque wire records."
            : "Snippets are encrypted on this Mac before iCloud sync sends them. "
                + "How often you use each snippet always remains local.")

        let providers = backendSelection.availableProviders
        providerPopup.addItems(withTitles: providers.map(\.displayName))
        for (index, provider) in providers.enumerated() {
            providerPopup.item(at: index)?.representedObject = provider.rawValue
        }
        providerPopup.target = self
        providerPopup.action = #selector(handleProviderChanged(_:))
        configureCloudButton.target = self
        configureCloudButton.action = #selector(showSnippetsCloudAccount)
        LiquidGlassDesign.configureActionButton(configureCloudButton, symbolName: "server.rack")
        let providerLabel = NSTextField(labelWithString: "Cloud provider:")
        providerLabel.textColor = .secondaryLabelColor
        let providerRow = NSStackView(views: [providerLabel, providerPopup, configureCloudButton, NSView()])
        providerRow.orientation = .horizontal
        providerRow.alignment = .centerY
        providerRow.spacing = 8
        providerRow.isHidden = !cloudFeatureEnabled

        if !cloudFeatureEnabled {
            enableCheckbox.title = "Sync snippets with iCloud"
        }

        enableCheckbox.target = self
        enableCheckbox.action = #selector(handleEnabledChanged(_:))

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        syncNowButton.target = self
        syncNowButton.action = #selector(syncNow)
        LiquidGlassDesign.configureActionButton(syncNowButton, symbolName: "arrow.triangle.2.circlepath")

        recoveryButton.target = self
        recoveryButton.action = #selector(performRecovery)
        recoveryButton.bezelStyle = .rounded

        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        // Usage data is the one thing that must never travel, and README already promises
        // it. Saying so here is cheaper than a support question.
        let limits = makeTertiaryLabel(
            "How often you use each snippet stays on this Mac and never syncs. "
            + "Use Sync Now if a change from another device has not appeared yet.")

        secondMacLabel.font = .systemFont(ofSize: 12)
        secondMacLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(providerRow)
        stack.addArrangedSubview(enableCheckbox)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(actionRow)
        stack.addArrangedSubview(NSBox.horizontalSeparator())
        stack.addArrangedSubview(secondMacLabel)
        stack.addArrangedSubview(limits)

        for label in [intro, limits, statusLabel, secondMacLabel] {
            label.preferredMaxLayoutWidth = 620
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let coordinator = Self.coordinator else { return }
        // Redraw as rounds complete, so "Syncing…" does not stay on screen after it stops.
        coordinator.onStateChange = { [weak self] _ in
            self?.reloadFromStorage()
            (self?.parent as? SettingsTabViewController)?.resizeForCurrentPane(animated: true)
        }
        reloadFromStorage()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        Self.coordinator?.onStateChange = nil
    }

    private static var coordinator: SyncCoordinator? {
        (NSApp.delegate as? AppDelegate)?.syncCoordinator
    }

    func reloadFromStorage() {
        guard isViewLoaded, let coordinator = Self.coordinator else { return }

        enableCheckbox.state = SyncCoordinator.isEnabled ? .on : .off
        let selection = backendSelection
        if let item = providerPopup.itemArray.first(where: {
            ($0.representedObject as? String) == selection.provider.rawValue
        }) {
            providerPopup.select(item)
        }
        configureCloudButton.isHidden = !selection.snippetsCloudEnabled
            || selection.provider != .snippetsCloud
        configureCloudButton.title = if selection.cloudCredentialResetRequired {
            "Reset Cloud Sign-In…"
        } else if selection.hasPendingRemoteRevocation || selection.hasPendingLocalErase {
            "Retry Sign Out…"
        } else {
            "Configure…"
        }
        statusLabel.stringValue = coordinator.statusDescription

        // Shown whenever sync is on, not only when an engine exists: a start that failed
        // on the keychain leaves no engine and no poll timer, and this button is what
        // retries it. Hiding it there was offering "relaunch the app" as the only cure.
        if let action = coordinator.recoveryAction {
            syncNowButton.isHidden = true
            recoveryButton.title = action.buttonTitle
            recoveryButton.isHidden = false
        } else {
            syncNowButton.isHidden = !coordinator.canRequestManualSync
            recoveryButton.isHidden = true
        }
        actionRow.isHidden = syncNowButton.isHidden && recoveryButton.isHidden

        let advice = secondMacAdvice()
        secondMacLabel.stringValue = advice
        secondMacLabel.isHidden = advice.isEmpty
    }

    /// What to do about another Mac — which, for the first time, is usually "nothing".
    ///
    /// Both keys ride iCloud Keychain: `K_sync` seals the wire and `K_lib` opens secure
    /// snippets, and `VaultIdentityStore` carries the vault's `kid` and salt alongside
    /// them so the second Mac joins this vault rather than minting a rival. So the
    /// interesting cases are the two where that channel is not available, and those are
    /// worth naming precisely rather than covering with one paragraph of hedging.
    private func secondMacAdvice() -> String {
        guard SyncCoordinator.isEnabled, let app = NSApp.delegate as? AppDelegate else { return "" }
        if backendSelection.provider == .snippetsCloud {
            return "Another device joins this library through approved pairing or recovery. "
                + "The server never receives the portable sync-v1 key. Switching back to "
                + "iCloud keeps using the existing CloudKit container and implementation."
        }
        let session = app.vaultSession

        guard session.syncsBetweenDevices else {
            // No `keychain-access-groups` in this binary, so `KeychainSecretStore` is on
            // the login-keychain tier and nothing it holds leaves this Mac. Release
            // builds are entitled; a local or unsigned build is not, and silently
            // syncing nothing would look like a bug in sync itself.
            return "This build cannot use iCloud Keychain, so its keys stay on this Mac. "
                + "Another Mac running it will receive snippets it cannot decrypt. "
                + "A signed release build syncs its keys automatically."
        }

        if app.secureStore.hasVault, case .noKey = session.state {
            return "This Mac has \(app.secureStore.count) secure snippet(s) whose key has not "
                + "arrived from iCloud Keychain. Ordinary snippets sync regardless. Check that "
                + "iCloud Keychain is on in System Settings, or restore the key with your "
                + "recovery key under Secure Snippets."
        }

        return "Setting up another Mac: sign in to the same iCloud account, keep iCloud "
            + "Keychain on, and tick this same box there. Nothing needs copying \u{2014} the "
            + "encryption key travels in your iCloud Keychain, and secure snippets come with it."
    }

    @objc private func handleEnabledChanged(_ sender: NSButton) {
        guard let coordinator = Self.coordinator else { return }
        coordinator.setEnabled(sender.state == .on)
        reloadFromStorage()
        (parent as? SettingsTabViewController)?.resizeForCurrentPane(animated: true)
    }

    @objc private func handleProviderChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let provider = SyncBackendSelectionStore.Provider(rawValue: rawValue) else { return }
        switch provider {
        case .iCloud:
            confirmProviderSwitch(to: .iCloud)
        case .snippetsCloud:
            guard backendSelection.snippetsCloudEnabled else { return }
            showSnippetsCloudAccount()
        }
    }

    @objc private func showSnippetsCloudAccount() {
        guard cloudAccountSheet == nil, let parent = view.window else { return }
        let controller = MacSnippetsCloudAccountViewController(
            bootstrap: cloudBootstrap,
            selection: backendSelection,
            coordinator: Self.coordinator,
            snippetCount: {
                (NSApp.delegate as? AppDelegate)?.store.snippets.count ?? 0
            },
            continueSetup: { [weak self] in
                self?.closeCloudAccountSheet()
                self?.configureSnippetsCloud()
            },
            switchToCloud: { [weak self] in
                self?.closeCloudAccountSheet()
                self?.confirmProviderSwitch(to: .snippetsCloud)
            },
            syncNow: { [weak self] in
                self?.closeCloudAccountSheet()
                self?.syncSnippetsCloudBeforeShowingReady()
            },
            addDevice: { [weak self] in
                self?.closeCloudAccountSheet()
                self?.promptForPairingInvitation()
            },
            replaceRecoveryKit: { [weak self] in
                self?.closeCloudAccountSheet()
                self?.runCloudTask("Couldn’t Replace Recovery Kit") {
                    guard let self else { return }
                    try self.presentCloudState(
                        try await self.cloudBootstrap.prepareRecoveryReplacement())
                }
            },
            changeAccount: { [weak self] in
                self?.closeCloudAccountSheet()
                self?.confirmCloudAccountChange()
            },
            changeLibrary: { [weak self] in
                self?.closeCloudAccountSheet()
                self?.runCloudTask("Couldn’t Change Library") {
                    guard let self else { return }
                    do {
                        try self.presentCloudState(try await self.cloudBootstrap.changeLibrary(
                            chooseLibrary: self.chooseCloudLibrary))
                    } catch is CancellationError {
                        // Explicit chooser cancellation leaves the current library intact.
                    }
                }
            },
            disconnect: { [weak self] in
                self?.closeCloudAccountSheet()
                self?.confirmCloudSignOut()
            })
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Snippets Cloud"
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 580, height: 610))
        controller.close = { [weak self] in self?.closeCloudAccountSheet() }
        cloudAccountSheet = sheet
        parent.beginSheet(sheet)
    }

    private func confirmProviderSwitch(to provider: SyncBackendSelectionStore.Provider) {
        let current = backendSelection.provider
        guard current != provider else {
            reloadFromStorage()
            return
        }
        if provider == .snippetsCloud,
           (try? cloudBootstrap.state()) != .ready {
            configureSnippetsCloud()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Switch Sync to \(provider.displayName)?"
        let count = (NSApp.delegate as? AppDelegate)?.store.snippets.count ?? 0
        alert.informativeText = "Current provider: \(current.displayName)\nNew provider: \(provider.displayName)\(provider == .snippetsCloud ? " · Library ID \(cloudBootstrap.libraryID ?? "—")" : "")\nOn this Mac: \(count) snippets\n\nThe current cloud library will not be deleted. Changes from both copies are compared and merged before sync is verified."
        alert.addButton(withTitle: "Switch and Sync")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            reloadFromStorage()
            return
        }
        syncSelectedProviderAfterSwitch(provider)
    }

    private func syncSelectedProviderAfterSwitch(
        _ provider: SyncBackendSelectionStore.Provider
    ) {
        guard let coordinator = Self.coordinator, let parent = view.window else { return }
        let progress = NSAlert()
        progress.messageText = "Switching to \(provider.displayName)…"
        progress.informativeText = "Checking destination · comparing libraries · uploading changes · verifying sync"
        progress.addButton(withTitle: "Please Wait")
        progress.buttons.first?.isEnabled = false
        progress.beginSheetModal(for: parent)
        Task { @MainActor [weak self, weak progressWindow = progress.window] in
            guard let self else { return }
            let result = await coordinator.switchProvider(to: provider)
            if let progressWindow, let sheetParent = progressWindow.sheetParent {
                sheetParent.endSheet(progressWindow)
            }
            reloadFromStorage()
            let done = NSAlert()
            if case .completed(.idle(let lastSync)) = result, lastSync != nil {
                done.messageText = "Switch Complete"
                done.informativeText = "\(provider.displayName) is active and the library is up to date."
            } else {
                done.alertStyle = .warning
                done.messageText = "Switch Needs Attention"
                done.informativeText = "Your libraries were not deleted. \(coordinator.statusDescription)"
            }
            done.runModal()
        }
    }

    private func closeCloudAccountSheet() {
        guard let sheet = cloudAccountSheet, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
        reloadFromStorage()
    }

    @objc private func configureSnippetsCloud() {
        let selection = backendSelection
        guard selection.snippetsCloudEnabled else { return }
        if selection.cloudCredentialResetRequired {
            confirmUnreadableCloudCredentialReset()
            return
        }
        if selection.hasPendingRemoteRevocation || selection.hasPendingLocalErase {
            retryInterruptedCloudSignOut()
            return
        }
        if selection.hasCloudSession {
            do {
                try presentCloudState(cloudBootstrap.state())
            } catch {
                showCloudError("Couldn’t Open Snippets Cloud", error: error)
            }
            return
        }
        guard let bundled = SyncBackendSelectionStore.bundledServerURL,
              SyncBackendSelectionStore.bundledOAuthRedirectURL != nil else {
            let unavailable = NSAlert()
            unavailable.messageText = "Snippets Cloud Isn’t Configured"
            unavailable.informativeText = "This build has no verified cloud endpoint and HTTPS sign-in callback. A self-hosted build must pin both at build time."
            unavailable.runModal()
            return
        }
        signInToSnippetsCloud(bundled, selection: selection)
    }

    private func confirmUnreadableCloudCredentialReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Unreadable Cloud Sign-In?"
        alert.informativeText = "Snippets cannot verify the saved sign-in history or confirm that every older sign-in was disconnected. First revoke Snippets in your identity provider’s connected-app settings. Reset removes this Mac’s cloud connection and its access to open the library; local snippets and the cloud library are not deleted."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset This Mac")
        alert.buttons[1].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runCloudTask("Couldn’t Reset Cloud Sign-In") { [weak self] in
            guard let self else { return }
            if let coordinator = Self.coordinator {
                try await coordinator.withQuiescedCloudTransport {
                    try self.cloudBootstrap.resetUnreadableCredentialsOnThisDevice()
                }
            } else {
                try self.cloudBootstrap.resetUnreadableCredentialsOnThisDevice()
            }
            self.reloadFromStorage()
        }
    }

    private func retryInterruptedCloudSignOut() {
        runCloudTask("Couldn’t Finish Signing Out") { [weak self] in
            guard let self else { return }
            if let coordinator = Self.coordinator {
                try await coordinator.withQuiescedCloudTransport {
                    try await self.cloudBootstrap.signOutThisDevice()
                }
            } else {
                try await self.cloudBootstrap.signOutThisDevice()
            }
            self.reloadFromStorage()
        }
    }

    private func signInToSnippetsCloud(
        _ serverURL: URL,
        selection: SyncBackendSelectionStore,
        changeAccount: Bool = false
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await cloudBootstrap.signIn(
                    serverURL: serverURL,
                    changeAccount: changeAccount,
                    chooseLibrary: chooseCloudLibrary,
                    presentationContext: self)
                try presentCloudState(state)
            } catch {
                showCloudError("Couldn’t Sign In to Snippets Cloud", error: error)
            }
            reloadFromStorage()
        }
    }

    private func confirmCloudAccountChange() {
        guard let server = SyncBackendSelectionStore.bundledServerURL else { return }
        let alert = NSAlert()
        alert.messageText = "Change Snippets Cloud Account?"
        alert.informativeText = "Current library: Library ID \(cloudBootstrap.libraryID ?? "—")\n\nYour current cloud library and local snippets will not be deleted. After sign-in, Snippets will show the new Library ID and ask before switching."
        alert.addButton(withTitle: "Choose Another Account")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        signInToSnippetsCloud(
            server,
            selection: backendSelection,
            changeAccount: true)
    }

    private func chooseCloudLibrary(
        _ choices: [SnippetsCloudLibraryChoice]
    ) async throws -> UUID {
        let alert = NSAlert()
        let isSwitchConfirmation = choices.count == 1 && cloudBootstrap.libraryID != nil
        alert.messageText = isSwitchConfirmation
            ? "Switch Snippets Library?"
            : "Choose a Snippets Library"
        alert.informativeText = isSwitchConfirmation
            ? "Current: Library ID \(cloudBootstrap.libraryID ?? "—")\nNew: Library ID \(choices[0].libraryID)\n\nThe current cloud library will not be deleted. The new library may require an approved device or recovery kit."
            : "This account can open more than one encrypted library. Choose which one to use on this Mac."
        for choice in choices {
            let role = choice.role.prefix(1).uppercased() + choice.role.dropFirst()
            alert.addButton(withTitle: "Library ID \(choice.libraryID) · \(role)")
        }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { throw CancellationError() }
        return choices[index].spaceID
    }

    private func presentCloudState(_ state: SnippetsCloudAccountBootstrap.State) throws {
        switch state {
        case .signedOut:
            configureSnippetsCloud()
        case .ready:
            continueAfterCloudBecameReady()
        case .needsTrustedDeviceOrRecovery:
            presentCloudUnlockMenu()
        case .waitingForApproval(let payload, let code, let expiresAt):
            presentPairingQR(
                payload: payload,
                confirmationCode: code,
                expiresAt: expiresAt)
        case .approvalReady(let code):
            confirmPairingApproval(code: code)
        case .strongAuthenticationRequired(let action):
            requestStrongAuthentication(for: action)
        case .recoveryKitAuthenticationRequired:
            authenticateRecoveryKitPresentation()
        case .recoveryKitReady(let payload, let code):
            presentRecoveryKit(payload: payload, longCode: code)
        }
    }

    private func authenticateRecoveryKitPresentation() {
        runCloudTask("Couldn’t Reveal Recovery Kit") { [weak self] in
            guard let self else { return }
            try await requireMacOwnerAuthentication(
                reason: "Reveal your Snippets Cloud recovery kit")
            try self.presentCloudState(
                self.cloudBootstrap.revealRecoveryKitAfterLocalAuthentication())
        }
    }

    private func presentCloudUnlockMenu() {
        let alert = NSAlert()
        alert.messageText = "Unlock Your Encrypted Library"
        alert.informativeText = "Use a device that already has this library, or your offline recovery kit. Snippets Cloud cannot read or recover the library key."
        alert.addButton(withTitle: "Use an Approved Device")
        alert.addButton(withTitle: "Recovery Kit…")
        alert.addButton(withTitle: "I Have Neither")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            runCloudTask("Couldn’t Create Invitation") { [weak self] in
                guard let self else { return }
                try self.presentCloudState(try await self.cloudBootstrap.beginPairing())
            }
        case .alertSecondButtonReturn:
            promptForRecoveryInput()
        case .alertThirdButtonReturn:
            let warning = NSAlert()
            warning.alertStyle = .critical
            warning.messageText = "Old Data Cannot Be Recovered"
            warning.informativeText = "The account can still be used, but without any approved device or the recovery kit, old encrypted snippets are mathematically unrecoverable. Snippets Cloud has no decryption key."
            warning.runModal()
        default:
            break
        }
    }

    private func syncSnippetsCloudBeforeShowingReady() {
        guard let coordinator = Self.coordinator else { return }
        let progress = NSAlert()
        progress.messageText = "Syncing Your Library…"
        progress.informativeText = "Account connected. Snippets is downloading and verifying your encrypted library."
        let window = progress.window
        window.level = .modalPanel
        progress.addButton(withTitle: "Please Wait")
        progress.buttons.first?.isEnabled = false
        progress.beginSheetModal(for: view.window!)
        Task { @MainActor [weak self, weak window] in
            guard let self else { return }
            let result = await coordinator.requestSync()
            if let window, let parent = window.sheetParent { parent.endSheet(window) }
            reloadFromStorage()
            let resultAlert = NSAlert()
            if case .completed(.idle(let lastSync)) = result, lastSync != nil {
                resultAlert.messageText = "Snippets Cloud Is Up to Date"
                resultAlert.informativeText = "The first verified sync completed successfully."
            } else {
                resultAlert.alertStyle = .warning
                resultAlert.messageText = "Account Connected — Sync Needs Attention"
                resultAlert.informativeText = "Your local snippets are safe. Setup remains incomplete until a sync finishes. \(coordinator.statusDescription)"
            }
            resultAlert.runModal()
        }
    }

    private func presentPairingQR(
        payload: String,
        confirmationCode: String,
        expiresAt: Date
    ) {
        guard let parent = view.window else { return }
        let controller = MacCloudPairingWaitViewController(
            payload: payload,
            confirmationCode: confirmationCode,
            expiresAt: expiresAt,
            poll: { [cloudBootstrap] in try await cloudBootstrap.checkPairing() },
            cancel: { [cloudBootstrap] in try? await cloudBootstrap.cancelPairing() },
            stateChanged: { [weak self] state in try? self?.presentCloudState(state) })
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Add This Mac"
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 560, height: 620))
        controller.close = { [weak parent, weak sheet] in
            guard let parent, let sheet else { return }
            parent.endSheet(sheet)
        }
        parent.beginSheet(sheet)
    }

    private func presentRecoveryKit(payload: String, longCode: String) {
        guard let parent = view.window else { return }
        let controller = MacRecoveryKitViewController(
            payload: payload,
            longCode: longCode,
            verified: { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await cloudBootstrap.acknowledgeRecoveryKitSaved()
                        continueAfterCloudBecameReady()
                    } catch {
                        showCloudError("Couldn’t Finish Setup", error: error)
                    }
                }
            })
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Save Your Recovery Kit"
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 600, height: 680))
        controller.close = { [weak parent, weak sheet] in
            guard let parent, let sheet else { return }
            parent.endSheet(sheet)
        }
        parent.beginSheet(sheet)
    }

    private func continueAfterCloudBecameReady() {
        reloadFromStorage()
        if backendSelection.provider == .snippetsCloud {
            Self.coordinator?.reloadProviderSelection()
            syncSnippetsCloudBeforeShowingReady()
        } else {
            confirmProviderSwitch(to: .snippetsCloud)
        }
    }

    private func promptForPairingInvitation() {
        promptForCloudPayload(
            title: "New Device Invitation",
            message: "Paste the invitation copied from the new device, or read a saved QR image.",
            actionTitle: "Review Device",
            supportsImage: true
        ) { [weak self] payload in
            self?.runCloudTask("Couldn’t Read Invitation") {
                guard let self else { return }
                try self.presentCloudState(
                    try await self.cloudBootstrap.prepareApproval(qrPayload: payload))
            }
        }
    }

    private func promptForRecoveryInput() {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        field.placeholderString = "XXXX-XXXX-…"
        let progress = NSTextField(labelWithString:
            "Spaces and hyphens are handled automatically. The long code has 52 characters.")
        progress.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [field, progress])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: 58)
        let alert = NSAlert()
        alert.messageText = "Recovery Kit"
        alert.informativeText = "Enter the long code, paste it, or read a saved recovery QR image."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Paste and Restore")
        alert.addButton(withTitle: "Read QR Image…")
        alert.addButton(withTitle: "Cancel")
        let restore: (String) -> Void = { [weak self] value in
            guard let self else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("{") {
                let normalized = SnippetsCloudRecoveryVerification.normalized(trimmed)
                    .filter { ($0 >= "A" && $0 <= "Z") || ($0 >= "2" && $0 <= "7") }
                guard normalized.count == 52 else {
                    let incomplete = NSAlert()
                    incomplete.alertStyle = .warning
                    incomplete.messageText = "Recovery Code Is Incomplete"
                    incomplete.informativeText = "Enter all 52 letters and numbers, or read the saved QR image."
                    incomplete.runModal()
                    promptForRecoveryInput()
                    return
                }
            }
            self.runCloudTask("Couldn’t Restore Library") {
                try self.presentCloudState(
                    try await self.cloudBootstrap.restore(recoveryCodeOrQR: value))
            }
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            restore(field.stringValue)
        case .alertSecondButtonReturn:
            restore(NSPasteboard.general.string(forType: .string) ?? "")
        case .alertThirdButtonReturn:
            readQRImage(completion: restore)
        default:
            break
        }
    }

    private func promptForCloudPayload(
        title: String,
        message: String,
        actionTitle: String,
        supportsImage: Bool,
        completion: @escaping (String) -> Void
    ) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        field.placeholderString = "Code or QR payload"
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: actionTitle)
        if supportsImage { alert.addButton(withTitle: "Read QR Image…") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 4_096 else { return }
            completion(value)
        case .alertSecondButtonReturn where supportsImage:
            readQRImage(completion: completion)
        default:
            break
        }
    }

    private func readQRImage(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            showCloudError("Couldn’t Read QR Image", error: SnippetsCloudAccountBootstrap.Failure.invalidInvitation)
            return
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            guard let payload = request.results?.first?.payloadStringValue,
                  !payload.isEmpty, payload.utf8.count <= 4_096 else {
                throw SnippetsCloudAccountBootstrap.Failure.invalidInvitation
            }
            completion(payload)
        } catch {
            showCloudError("Couldn’t Read QR Image", error: error)
        }
    }

    private func confirmPairingApproval(code: String) {
        let alert = NSAlert()
        alert.messageText = "Add This iPhone or Mac?"
        alert.informativeText = SnippetsCloudPairingApprovalCopy.message(
            code: code,
            localAuthentication: "Touch ID or the Mac password")
        alert.addButton(
            withTitle: SnippetsCloudPairingApprovalCopy.approveButtonTitle(code: code))
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            authenticateAndContinue(action: .approveDevice)
        } else {
            try? cloudBootstrap.cancelApproval()
        }
    }

    private func requestStrongAuthentication(for action: SnippetsCloudAccountBootstrap.StrongAction) {
        if action == .createInitialRecovery {
            let alert = NSAlert()
            alert.messageText = "Protect Your Recovery Kit"
            alert.informativeText = "Finish with a fresh passkey check. Apple or Google may identify the account, but they never become the key to your snippets."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { continueWithStrongCloudSignIn() }
        } else {
            authenticateAndContinue(action: action)
        }
    }

    private func authenticateAndContinue(action: SnippetsCloudAccountBootstrap.StrongAction) {
        runCloudTask("Approval Failed") { [weak self] in
            guard let self else { return }
            try await requireMacOwnerAuthentication(reason: action == .approveDevice
                ? "Approve a new device for your encrypted Snippets library"
                : "Replace your Snippets Cloud recovery kit")
            self.continueWithStrongCloudSignIn()
        }
    }

    private func continueWithStrongCloudSignIn() {
        guard let server = cloudBootstrap.selection.cloudCoordinates?.serverURL else {
            showCloudError("Couldn’t Continue", error: SnippetsCloudAccountBootstrap.Failure.invalidState)
            return
        }
        runCloudTask("Secure Approval Failed") { [weak self] in
            guard let self else { return }
            try self.presentCloudState(try await self.cloudBootstrap.signIn(
                serverURL: server,
                strong: true,
                chooseLibrary: self.chooseCloudLibrary,
                presentationContext: self))
        }
    }

    private func confirmCloudSignOut() {
        let recoveryStatus = cloudBootstrap.recoveryKitStatus
        let recoveryMessage = switch recoveryStatus {
        case .verifiedCurrent: "verified against the current cloud recovery envelope."
        case .knownReplaced:
            "your previously saved recovery kit was replaced and can no longer unlock this library."
        case .statusUnconfirmed:
            "the saved verification will be checked against the server before disconnecting."
        case .neverVerified: "not verified on this Mac."
        case .replacementInProgress: "finish saving and checking the replacement recovery kit first."
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Disconnect Snippets Cloud from This Mac?"
        alert.informativeText = "This removes this Mac’s cloud connection and its access to open the library. Your cloud library is not deleted. You will need another approved device or the recovery kit to reconnect.\n\nRecovery check: \(recoveryMessage)"
        alert.addButton(withTitle: "Cancel")
        guard recoveryStatus != .knownReplaced,
              recoveryStatus != .replacementInProgress else {
            alert.runModal()
            return
        }
        alert.addButton(withTitle: "Disconnect This Mac")
        alert.buttons[1].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runCloudTask("Couldn’t Sign Out") { [weak self] in
            guard let self else { return }
            if let coordinator = Self.coordinator {
                try await coordinator.withQuiescedCloudTransport {
                    try await self.cloudBootstrap.signOutThisDevice()
                }
            } else {
                try await self.cloudBootstrap.signOutThisDevice()
            }
            self.reloadFromStorage()
        }
    }

    private func runCloudTask(
        _ title: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor [weak self] in
            do { try await operation() }
            catch { self?.showCloudError(title, error: error) }
        }
    }

    private func showCloudError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? "Snippets Cloud could not complete the request. Your local snippets are unchanged; try again."
        var recovery: (() -> Void)?
        if let failure = error as? SnippetsCloudAccountBootstrap.Failure {
            switch failure {
            case .service(let code) where [
                "sign_in_required", "authentication_required", "refresh_token_missing",
                "reauthentication_required", "scope_review_required",
            ].contains(code):
                alert.addButton(withTitle: "Continue Sign-In")
                recovery = { [weak self] in
                    guard let self,
                          let server = SyncBackendSelectionStore.bundledServerURL else { return }
                    signInToSnippetsCloud(server, selection: backendSelection)
                }
            case .service("library_key_required"), .recoveryUnavailable:
                alert.addButton(withTitle: "Choose Recovery Method")
                recovery = { [weak self] in self?.presentCloudUnlockMenu() }
            case .pairingExpired, .service("pairing_expired"), .service("pairing_missing"):
                alert.addButton(withTitle: "Create New Invitation")
                recovery = { [weak self] in
                    self?.runCloudTask("Couldn’t Create Invitation") {
                        guard let self else { return }
                        try self.presentCloudState(try await self.cloudBootstrap.beginPairing())
                    }
                }
            default:
                break
            }
        }
        if recovery != nil {
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        let response = alert.runModal()
        if recovery != nil, response == .alertFirstButtonReturn { recovery?() }
    }

    @objc private func syncNow() {
        Self.coordinator?.syncNow()
        reloadFromStorage()
    }

    @objc private func performRecovery() {
        guard let coordinator = Self.coordinator,
              let action = coordinator.recoveryAction else { return }
        guard MacSyncRecoveryConfirmation.shouldPerform(
            action,
            coordinator: coordinator
        ) else { return }
        coordinator.performRecovery(action)
        reloadFromStorage()
    }
}

extension SyncSettingsViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        _ = session
        return view.window!
    }
}

@MainActor
private final class MacSnippetsCloudAccountViewController: NSViewController {
    private let bootstrap: SnippetsCloudAccountBootstrap
    private let selection: SyncBackendSelectionStore
    private let coordinator: SyncCoordinator?
    private let snippetCount: () -> Int
    private let continueSetup: () -> Void
    private let switchToCloud: () -> Void
    private let syncNowAction: () -> Void
    private let addDevice: () -> Void
    private let replaceRecoveryKit: () -> Void
    private let changeAccount: () -> Void
    private let changeLibrary: () -> Void
    private let disconnect: () -> Void
    private var syncObservation: UUID?
    var close: (() -> Void)?

    init(
        bootstrap: SnippetsCloudAccountBootstrap,
        selection: SyncBackendSelectionStore,
        coordinator: SyncCoordinator?,
        snippetCount: @escaping () -> Int,
        continueSetup: @escaping () -> Void,
        switchToCloud: @escaping () -> Void,
        syncNow: @escaping () -> Void,
        addDevice: @escaping () -> Void,
        replaceRecoveryKit: @escaping () -> Void,
        changeAccount: @escaping () -> Void,
        changeLibrary: @escaping () -> Void,
        disconnect: @escaping () -> Void
    ) {
        self.bootstrap = bootstrap
        self.selection = selection
        self.coordinator = coordinator
        self.snippetCount = snippetCount
        self.continueSetup = continueSetup
        self.switchToCloud = switchToCloud
        self.syncNowAction = syncNow
        self.addDevice = addDevice
        self.replaceRecoveryKit = replaceRecoveryKit
        self.changeAccount = changeAccount
        self.changeLibrary = changeLibrary
        self.disconnect = disconnect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await bootstrap.refreshRecoveryKitStatus()
            guard isViewLoaded else { return }
            let frame = view.frame
            loadView()
            view.frame = frame
        }
        guard syncObservation == nil else { return }
        syncObservation = coordinator?.addStateObserver { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            let frame = self.view.frame
            self.loadView()
            self.view.frame = frame
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let syncObservation {
            coordinator?.removeStateObserver(syncObservation)
            self.syncObservation = nil
        }
    }

    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        view.addSubview(scroll)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let heading = NSTextField(labelWithString: accountStatusTitle)
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(section(
            title: "Account",
            lines: [
                bootstrap.libraryID.map { "Snippets Cloud · Library ID \($0)" }
                    ?? "No Snippets Cloud account is connected.",
                "Selected encrypted library",
            ]))
        stack.addArrangedSubview(section(
            title: "Sync",
            lines: [
                "Active storage: \(selection.provider.displayName)",
                syncStatus,
                "\(snippetCount()) snippets on this Mac",
            ]))
        stack.addArrangedSubview(section(
            title: "Security",
            lines: [
                "Library access: \(libraryAccess)",
                "Recovery kit: \(recoveryKitStatus)",
            ]))

        let actionHeading = NSTextField(labelWithString: "Account Actions")
        actionHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(actionHeading)
        for action in visibleActions {
            let button = NSButton(
                title: action.title(for: state),
                target: self,
                action: action.selector)
            button.bezelStyle = .rounded
            button.contentTintColor = action == .disconnect ? .systemRed : .controlAccentColor
            stack.addArrangedSubview(button)
        }
        let done = NSButton(title: "Done", target: self, action: #selector(closeSheet))
        stack.addArrangedSubview(done)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -24),
        ])
    }

    private enum Action: Equatable {
        case continueSetup, switchToCloud, syncNow, addDevice, replaceRecovery
        case changeAccount, changeLibrary, disconnect

        var selector: Selector {
            switch self {
            case .continueSetup:
                #selector(MacSnippetsCloudAccountViewController.continueSetupPressed)
            case .switchToCloud:
                #selector(MacSnippetsCloudAccountViewController.switchToCloudPressed)
            case .syncNow: #selector(MacSnippetsCloudAccountViewController.syncNowPressed)
            case .addDevice: #selector(MacSnippetsCloudAccountViewController.addDevicePressed)
            case .replaceRecovery:
                #selector(MacSnippetsCloudAccountViewController.replaceRecoveryPressed)
            case .changeAccount:
                #selector(MacSnippetsCloudAccountViewController.changeAccountPressed)
            case .changeLibrary:
                #selector(MacSnippetsCloudAccountViewController.changeLibraryPressed)
            case .disconnect:
                #selector(MacSnippetsCloudAccountViewController.disconnectPressed)
            }
        }

        func title(for state: SnippetsCloudAccountBootstrap.State) -> String {
            switch self {
            case .continueSetup:
                switch state {
                case .signedOut: "Sign In to Snippets Cloud…"
                case .waitingForApproval: "Return to Device Approval…"
                case .recoveryKitAuthenticationRequired, .recoveryKitReady:
                    "Save and Check Recovery Kit…"
                default: "Continue Setup…"
                }
            case .switchToCloud: "Use Snippets Cloud for Sync…"
            case .syncNow: "Sync Now"
            case .addDevice: "Scan a New Device Invitation…"
            case .replaceRecovery: "Replace Recovery Kit…"
            case .changeAccount: "Change Account…"
            case .changeLibrary: "Change Library…"
            case .disconnect: "Disconnect This Mac…"
            }
        }
    }

    private var state: SnippetsCloudAccountBootstrap.State {
        (try? bootstrap.state()) ?? .signedOut
    }

    private var visibleActions: [Action] {
        switch state {
        case .signedOut:
            [.continueSetup]
        case .ready:
            (selection.provider == .snippetsCloud ? [.syncNow] : [.switchToCloud])
                + [.addDevice, .replaceRecovery, .changeLibrary, .changeAccount, .disconnect]
        case .strongAuthenticationRequired(.replaceRecovery),
             .recoveryKitAuthenticationRequired, .recoveryKitReady:
            [.continueSetup, .changeAccount]
        case .needsTrustedDeviceOrRecovery, .waitingForApproval,
             .approvalReady, .strongAuthenticationRequired:
            [.continueSetup, .changeAccount, .disconnect]
        }
    }

    private var accountStatusTitle: String {
        switch state {
        case .signedOut: "Not Connected"
        case .ready: "Account Connected"
        case .needsTrustedDeviceOrRecovery: "Library Locked"
        case .waitingForApproval: "Waiting for Device Approval"
        case .approvalReady, .strongAuthenticationRequired(.approveDevice):
            "Device Approval Required"
        case .strongAuthenticationRequired(.createInitialRecovery),
             .strongAuthenticationRequired(.replaceRecovery),
             .recoveryKitAuthenticationRequired, .recoveryKitReady:
            "Recovery Kit Needs to Be Saved"
        }
    }

    private var syncStatus: String {
        guard selection.provider == .snippetsCloud else {
            return "Snippets Cloud is not the active storage"
        }
        if case .idle(let lastSync) = coordinator?.state, lastSync != nil {
            return "Up to date"
        }
        if case .syncing = coordinator?.state { return "Syncing your library…" }
        return coordinator?.statusDescription ?? "Sync has not completed yet"
    }

    private var libraryAccess: String {
        switch state {
        case .ready, .recoveryKitAuthenticationRequired, .recoveryKitReady,
             .strongAuthenticationRequired(.replaceRecovery), .approvalReady,
             .strongAuthenticationRequired(.approveDevice):
            "unlocked on this Mac"
        case .needsTrustedDeviceOrRecovery, .waitingForApproval:
            "waiting for an approved device or recovery kit"
        case .strongAuthenticationRequired(.createInitialRecovery):
            "preparing library access"
        case .signedOut:
            "sign in first"
        }
    }

    private var recoveryKitStatus: String {
        switch bootstrap.recoveryKitStatus {
        case .verifiedCurrent: "verified against the current cloud recovery envelope"
        case .knownReplaced:
            "the previously saved recovery kit was replaced and no longer works"
        case .statusUnconfirmed:
            "saved verification has not yet been confirmed against the current cloud envelope"
        case .neverVerified: "not verified on this Mac"
        case .replacementInProgress: "replacement still needs to be saved and checked"
        }
    }

    private func section(title: String, lines: [String]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let labels = lines.map { value -> NSTextField in
            let label = NSTextField(wrappingLabelWithString: value)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 500
            return label
        }
        let stack = NSStackView(views: [titleLabel] + labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    @objc private func continueSetupPressed() { continueSetup() }
    @objc private func switchToCloudPressed() { switchToCloud() }
    @objc private func syncNowPressed() { syncNowAction() }
    @objc private func addDevicePressed() { addDevice() }
    @objc private func replaceRecoveryPressed() { replaceRecoveryKit() }
    @objc private func changeAccountPressed() { changeAccount() }
    @objc private func changeLibraryPressed() { changeLibrary() }
    @objc private func disconnectPressed() { disconnect() }
    @objc private func closeSheet() { close?() }
}

@MainActor
private final class MacCloudPairingWaitViewController: NSViewController {
    private let payload: String
    private let confirmationCode: String
    private let expiresAt: Date
    private let poll: () async throws -> SnippetsCloudAccountBootstrap.State
    private let cancel: () async -> Void
    private let stateChanged: (SnippetsCloudAccountBootstrap.State) -> Void
    private let status = NSTextField(wrappingLabelWithString: "")
    private var pollingTask: Task<Void, Never>?
    private var checkInProgress = false
    var close: (() -> Void)?

    init(
        payload: String,
        confirmationCode: String,
        expiresAt: Date,
        poll: @escaping () async throws -> SnippetsCloudAccountBootstrap.State,
        cancel: @escaping () async -> Void,
        stateChanged: @escaping (SnippetsCloudAccountBootstrap.State) -> Void
    ) {
        self.payload = payload
        self.confirmationCode = confirmationCode
        self.expiresAt = expiresAt
        self.poll = poll
        self.cancel = cancel
        self.stateChanged = stateChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let instructions = NSTextField(wrappingLabelWithString:
            "On a device that already opens this library, open Snippets Cloud, choose Add device, and scan this QR. Confirm that both devices show the same code.")
        instructions.alignment = .center
        instructions.preferredMaxLayoutWidth = 500
        let image = NSImageView(image: qrImage(payload) ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        let code = NSTextField(labelWithString: "Check code: \(confirmationCode)")
        code.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        code.setAccessibilityLabel("Confirmation code")
        code.setAccessibilityValue(confirmationCode)
        status.alignment = .center
        status.textColor = .controlAccentColor
        status.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        status.preferredMaxLayoutWidth = 500
        let check = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        let cancelButton = NSButton(
            title: "Cancel Pairing",
            target: self,
            action: #selector(cancelPairing))
        let stack = NSStackView(views: [instructions, image, code, status, check, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
            image.widthAnchor.constraint(equalToConstant: 300),
            image.heightAnchor.constraint(equalToConstant: 300),
        ])
        updateStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startPolling()
    }

    override func viewWillDisappear() {
        pollingTask?.cancel()
        pollingTask = nil
        super.viewWillDisappear()
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                updateStatus()
                guard expiresAt > Date() else {
                    status.stringValue = "Invitation expired. Create a new invitation to continue."
                    status.textColor = .systemRed
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await checkOnce()
            }
        }
    }

    private func checkOnce() async {
        guard !checkInProgress, expiresAt > Date() else { return }
        checkInProgress = true
        defer { checkInProgress = false }
        do {
            let state = try await poll()
            if case .waitingForApproval = state {
                updateStatus()
                return
            }
            pollingTask?.cancel()
            close?()
            stateChanged(state)
        } catch {
            status.stringValue = "Couldn’t check approval. Your invitation is still safe; Snippets will keep trying."
            status.textColor = .systemOrange
        }
    }

    private func updateStatus() {
        let seconds = max(0, Int(ceil(expiresAt.timeIntervalSinceNow)))
        status.textColor = .controlAccentColor
        status.stringValue = String(
            format: "Waiting for approval… %02d:%02d",
            seconds / 60,
            seconds % 60)
    }

    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 300, height: 300))
    }

    @objc private func checkAgain() {
        Task { @MainActor [weak self] in await self?.checkOnce() }
    }

    @objc private func cancelPairing() {
        Task { await cancel() }
        close?()
    }
}

@MainActor
private final class MacRecoveryKitViewController: NSViewController, NSTextFieldDelegate {
    private let payload: String
    private let longCode: String
    private let verified: () -> Void
    var close: (() -> Void)?

    private let contentStack = NSStackView()
    private let verificationStack = NSStackView()
    private let verificationField = NSSecureTextField()
    private let verificationError = NSTextField(labelWithString:
        "Those characters do not match the recovery kit.")
    private var inactivityObserver: NSObjectProtocol?

    init(payload: String, longCode: String, verified: @escaping () -> Void) {
        self.payload = payload
        self.longCode = longCode
        self.verified = verified
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        view.addSubview(scroll)

        let explanation = centeredLabel(
            "Keep this QR or long code offline. It is the only fallback if every approved device is lost.")
        let image = NSImageView(image: qrImage(payload) ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let code = centeredLabel(longCode)
        code.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
        code.setAccessibilityLabel("Recovery code")
        code.setAccessibilityValue(longCode)

        let copy = NSButton(title: "Copy Code", target: self, action: #selector(copyCode))
        let save = NSButton(title: "Save Recovery Sheet…", target: self, action: #selector(saveSheet))
        let printButton = NSButton(title: "Print…", target: self, action: #selector(printSheet))
        let actions = NSStackView(views: [copy, save, printButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let warning = centeredLabel(
            "Anyone with this kit and access to your account can unlock the library. Keep it offline and private.")
        warning.textColor = .systemRed

        let verify = NSButton(title: "Check Saved Copy", target: self, action: #selector(showVerification))
        verify.keyEquivalent = "\r"
        let later = NSButton(title: "Save Later", target: self, action: #selector(closeSheet))

        [explanation, image, code, actions, warning, verify, later]
            .forEach(contentStack.addArrangedSubview)
        configure(stack: contentStack)

        let verifyMessage = centeredLabel(
            "Use the copy you saved and enter its final 8 characters. This checks the copy on this Mac; it cannot prove where it was stored.")
        verificationField.placeholderString = "Final 8 characters"
        verificationField.delegate = self
        verificationError.textColor = .systemRed
        verificationError.isHidden = true
        let confirm = NSButton(title: "Complete Recovery Check", target: self, action: #selector(verifyCode))
        confirm.keyEquivalent = "\r"
        let showAgain = NSButton(
            title: "Show Recovery Kit Again",
            target: self,
            action: #selector(showContent))
        [verifyMessage, verificationField, verificationError, confirm, showAgain]
            .forEach(verificationStack.addArrangedSubview)
        configure(stack: verificationStack)
        verificationStack.isHidden = true

        let root = NSStackView(views: [contentStack, verificationStack])
        root.orientation = .vertical
        root.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(root)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            root.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -32),
            root.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -24),
            image.widthAnchor.constraint(equalToConstant: 280),
            image.heightAnchor.constraint(equalToConstant: 280),
            verificationField.widthAnchor.constraint(equalToConstant: 260),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard inactivityObserver == nil else { return }
        inactivityObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.view.isHidden = true
                self?.close?()
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        verificationField.stringValue = ""
        if let inactivityObserver {
            NotificationCenter.default.removeObserver(inactivityObserver)
            self.inactivityObserver = nil
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        _ = obj
        let normalized = SnippetsCloudRecoveryVerification.normalized(
            verificationField.stringValue)
        verificationField.stringValue = String(
            normalized.suffix(SnippetsCloudRecoveryVerification.suffixLength))
        verificationError.isHidden = true
    }

    private func configure(stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
    }

    private func centeredLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.alignment = .center
        label.preferredMaxLayoutWidth = 500
        return label
    }

    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 280, height: 280))
    }

    private func recoverySheetView() -> NSView {
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        let title = NSTextField(labelWithString: "Snippets Cloud Recovery Kit")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 56, y: 710, width: 500, height: 34)
        let image = NSImageView(frame: NSRect(x: 166, y: 385, width: 280, height: 280))
        image.image = qrImage(payload)
        let code = NSTextField(wrappingLabelWithString: longCode)
        code.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        code.alignment = .center
        code.frame = NSRect(x: 56, y: 300, width: 500, height: 60)
        let warning = NSTextField(wrappingLabelWithString:
            "Keep this sheet offline and private. Anyone with it and access to your account can unlock your library.")
        warning.alignment = .center
        warning.frame = NSRect(x: 76, y: 215, width: 460, height: 54)
        [title, image, code, warning].forEach(sheet.addSubview)
        return sheet
    }

    @objc private func copyCode() {
        let pasteboard = NSPasteboard.general
        let marker = UUID().uuidString
        let markerType = NSPasteboard.PasteboardType("com.khm.snippets.recovery-marker")
        pasteboard.clearContents()
        pasteboard.setString(longCode, forType: .string)
        pasteboard.setString(marker, forType: markerType)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            guard pasteboard.string(forType: markerType) == marker else { return }
            pasteboard.clearContents()
        }
    }

    @objc private func saveSheet() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Snippets Cloud Recovery Kit.pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let printable = recoverySheetView()
            try? printable.dataWithPDF(inside: printable.bounds).write(to: url, options: .atomic)
        }
    }

    @objc private func printSheet() {
        recoverySheetView().printView(nil)
    }

    @objc private func showVerification() {
        contentStack.isHidden = true
        verificationStack.isHidden = false
        view.window?.makeFirstResponder(verificationField)
    }

    @objc private func showContent() {
        verificationField.stringValue = ""
        verificationError.isHidden = true
        verificationStack.isHidden = true
        contentStack.isHidden = false
    }

    @objc private func verifyCode() {
        guard SnippetsCloudRecoveryVerification.matches(
            longCode: longCode,
            enteredSuffix: verificationField.stringValue) else {
            verificationError.isHidden = false
            return
        }
        verificationField.stringValue = ""
        close?()
        verified()
    }

    @objc private func closeSheet() { close?() }
}

@MainActor
private func requireMacOwnerAuthentication(reason: String) async throws {
    let context = LAContext()
    context.touchIDAuthenticationAllowableReuseDuration = 0
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        throw error ?? SnippetsCloudAccountBootstrap.Failure.invalidState
    }
    guard try await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: reason) else {
        throw SnippetsCloudAccountBootstrap.Failure.invalidState
    }
}

@MainActor
private final class DiagnosticsSettingsViewController: NSViewController {
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private let expansionVerbosePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exportButton = NSButton(title: "Export Logs…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Logs", target: nil, action: nil)

    private static var service: DiagnosticsService? {
        (NSApp.delegate as? AppDelegate)?.diagnostics
    }

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

        let title = NSTextField(labelWithString: "Persistent Diagnostics")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let intro = makeSecondaryLabel(
            "Snippets keeps privacy-filtered operational events for up to "
            + "\(DiagnosticsService.retentionDays) days. Logs rotate daily or at 1 MB, "
            + "whichever comes first, and use at most 24 MB on this device.")
        let privacy = makeTertiaryLabel(
            "Exports are plaintext JSON Lines. They can include app and OS versions, "
            + "operation counts, CloudKit callback and scheduler states, error families and "
            + "numeric codes, and secure-snippet keywords. When expansion verbose logging is "
            + "enabled, they can also include "
            + "content-free Accessibility stages, outcomes, state transitions, query lengths, "
            + "and numeric AX error codes. Snippet bodies, names, tags, paths, record IDs, keys and "
            + "ciphertext are never accepted by the logging API.")

        let expansionVerboseTitle = NSTextField(labelWithString: "Expansion Accessibility logging")
        expansionVerboseTitle.font = .systemFont(ofSize: 13, weight: .medium)
        expansionVerbosePopup.removeAllItems()
        for mode in ExpansionVerboseLoggingMode.allCases {
            expansionVerbosePopup.addItem(withTitle: mode.title)
            expansionVerbosePopup.lastItem?.representedObject = mode.rawValue
        }
        expansionVerbosePopup.target = self
        expansionVerbosePopup.action = #selector(changeExpansionVerboseLogging)
        let expansionVerboseRow = NSStackView(views: [
            expansionVerboseTitle,
            NSView(),
            expansionVerbosePopup,
        ])
        expansionVerboseRow.orientation = .horizontal
        expansionVerboseRow.alignment = .centerY
        expansionVerboseRow.spacing = 10
        let expansionVerboseHelp = makeTertiaryLabel(
            "Off records no per-keystroke AX diagnostics. This Session resets when Snippets quits; "
            + "Always remains enabled across launches. Typed text is never recorded.")

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        privacyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        privacyLabel.textColor = .systemRed
        privacyLabel.isHidden = true

        exportButton.target = self
        exportButton.action = #selector(exportLogs)
        LiquidGlassDesign.configureActionButton(exportButton, symbolName: "square.and.arrow.up")
        deleteButton.target = self
        deleteButton.action = #selector(confirmDeleteLogs)
        LiquidGlassDesign.configureActionButton(deleteButton, symbolName: "trash")

        let buttons = NSStackView(views: [exportButton, deleteButton, NSView()])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(expansionVerboseRow)
        stack.addArrangedSubview(expansionVerboseHelp)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(privacyLabel)
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(NSBox.horizontalSeparator())
        stack.addArrangedSubview(privacy)

        expansionVerboseRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for label in [intro, expansionVerboseHelp, privacy, statusLabel, privacyLabel] {
            label.preferredMaxLayoutWidth = 620
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadFromStorage()
    }

    func reloadFromStorage() {
        guard isViewLoaded, let service = Self.service else { return }
        let verboseMode = service.expansionVerboseLogging.mode
        expansionVerbosePopup.selectItem(
            withTitle: verboseMode.title)
        let summary = service.summary()
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(min(summary.byteCount, UInt64(Int64.max))),
            countStyle: .file)
        if summary.storageAvailable {
            statusLabel.stringValue = summary.fileCount == 0
                ? "No diagnostic events are stored yet."
                : "\(summary.fileCount) log file(s), \(bytes) stored on this Mac."
        } else {
            statusLabel.stringValue = "The diagnostics folder is unavailable."
        }
        privacyLabel.stringValue = summary.privacyCleanupNeeded
            ? "Legacy audit cleanup could not finish. Export is safe, but Vault/audit.json still needs removal."
            : ""
        privacyLabel.isHidden = !summary.privacyCleanupNeeded
        exportButton.isEnabled = summary.storageAvailable && summary.fileCount > 0
        deleteButton.isEnabled = summary.fileCount > 0
    }

    @objc private func changeExpansionVerboseLogging() {
        guard let service = Self.service,
              let rawValue = expansionVerbosePopup.selectedItem?.representedObject as? String,
              let mode = ExpansionVerboseLoggingMode(rawValue: rawValue) else { return }
        service.expansionVerboseLogging.setMode(mode)
    }

    @objc private func exportLogs() {
        guard let service = Self.service else { return }
        let panel = NSSavePanel()
        panel.title = "Export Snippets Diagnostics"
        panel.nameFieldStringValue = DiagnosticsService.suggestedExportFilename()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "jsonl", conformingTo: .json) ?? .json,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        setButtonsEnabled(false)
        Task { [weak self] in
            do {
                let result = try await service.export(to: url)
                self?.showResult(
                    title: "Diagnostics Exported",
                    message: "Exported \(result.recordCount) event(s) as privacy-filtered JSON Lines.")
            } catch {
                self?.showResult(
                    title: "Couldn’t Export Diagnostics",
                    message: (error as? LocalizedError)?.errorDescription
                        ?? "The export could not be created.")
            }
            self?.setButtonsEnabled(true)
            self?.reloadFromStorage()
        }
    }

    @objc private func confirmDeleteLogs() {
        guard let service = Self.service else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Diagnostic Logs?"
        alert.informativeText = "This permanently removes the retained diagnostics and any legacy reveal-audit file from this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Logs")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setButtonsEnabled(false)
        Task { [weak self] in
            await service.deleteStoredLogs()
            self?.setButtonsEnabled(true)
            self?.reloadFromStorage()
        }
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        exportButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
    }

    private func showResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private func makeSettingsPane() -> (NSView, NSStackView) {
    let rootView = NSView()
    // NSTabViewController sizes pane roots by frame. Pane switches and the window-height
    // animation happen in the same run-loop turn, so the newly selected root must grow
    // with its container instead of retaining the previous pane's shorter height.
    rootView.autoresizingMask = [.width, .height]
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    if #available(macOS 26.0, *) {
        rootView.prefersCompactControlSizeMetrics = true
    }

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setHuggingPriority(.required, for: .vertical)
    stack.setContentCompressionResistancePriority(.required, for: .vertical)
    rootView.addSubview(stack)

    NSLayoutConstraint.activate([
        // NSTabViewController already places each pane below the settings toolbar. A
        // pane's window-derived safe area can briefly retain the previous toolbar
        // geometry while the window animates between pane heights, which used to add
        // a second, sometimes very large top inset. Pinning to the pane itself also
        // matches measuredContentHeight's fixed 24pt top and bottom allowance.
        stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
        stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -24)
    ])

    return (rootView, stack)
}

private func makeSettingsSectionTitle(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 14, weight: .semibold)
    label.textColor = .labelColor
    return label
}

private func makeSecondaryLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 13)
    label.textColor = .secondaryLabelColor
    return label
}

private func makeTertiaryLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .tertiaryLabelColor
    return label
}

@MainActor
enum MacSyncRecoveryConfirmation {
    /// Shared by the main Sync menu and Settings so a safety action behaves identically
    /// wherever the user notices it. Returning false leaves the exact durable halt
    /// untouched; the coordinator still rejects a stale action after a positive result.
    static func shouldPerform(
        _ action: SyncRecoveryAction,
        coordinator: SyncCoordinator
    ) -> Bool {
        guard let title = action.confirmationTitle,
              let buttonTitle = action.confirmationButtonTitle else { return true }

        let alert = NSAlert()
        alert.alertStyle = action.isDestructiveConfirmation ? .critical : .warning
        alert.messageText = title
        alert.informativeText = coordinator.statusDescription + "\n\n" + action.explanation
        // Return must never approve a trust-boundary decision. Account change and
        // cloud restore can disclose/replace remote data even though they are not
        // styled red, so Cancel is the default for every confirmation.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: buttonTitle)
        alert.buttons[1].keyEquivalent = ""
        if action.isDestructiveConfirmation {
            alert.buttons[1].hasDestructiveAction = true
        }
        return alert.runModal() == .alertSecondButtonReturn
    }
}
