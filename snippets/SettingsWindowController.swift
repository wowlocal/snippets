import AppKit
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController = SettingsTabViewController()

    init() {
        let window = NSWindow(contentViewController: settingsViewController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 720, height: 480))
        window.contentMinSize = NSSize(width: 1, height: 1)
        window.minSize = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1, height: 1)).size
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
            window.titlebarSeparatorStyle = .none
        }

        super.init(window: window)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        settingsViewController.reloadFromStorage()
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private let generalViewController = GeneralSettingsViewController()
    private let browsersViewController = BrowserSettingsViewController()

    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = false

        addTab(title: "General", symbolName: "gearshape", viewController: generalViewController)
        addTab(title: "Browsers", symbolName: "globe", viewController: browsersViewController)
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
    }

    func reloadFromStorage() {
        generalViewController.reloadFromStorage()
        browsersViewController.reloadFromStorage()
    }

    private func addTab(title: String, symbolName: String, viewController: NSViewController) {
        viewController.title = title

        let item = NSTabViewItem(viewController: viewController)
        item.label = title
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        addTabViewItem(item)
    }
}

@MainActor
private final class GeneralSettingsViewController: NSViewController {
    private let quitBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let selectionSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let promptSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let resetButton = NSButton(title: "Reset to Ask Every Time", target: nil, action: nil)
    private let paleThemeCheckbox = NSButton(checkboxWithTitle: "Pale Theme", target: nil, action: nil)
    private let cliInstallButton = NSButton(title: "Install CLI Tool", target: nil, action: nil)
    private let cliStatusLabel = NSTextField(wrappingLabelWithString: "")

    private static let cliInstallURL = URL(filePath: "/usr/local/bin/snippets-cli")

    private static let cliBinaryName = "snippets-cli"

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

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

        let themeSeparator = NSBox()
        themeSeparator.boxType = .separator

        let themeIntroLabel = makeSecondaryLabel("Reduce accent colors throughout the interface for a quieter, more muted look.")

        paleThemeCheckbox.target = self
        paleThemeCheckbox.action = #selector(handlePaleThemeChanged(_:))
        paleThemeCheckbox.state = ThemeManager.isPaleTheme ? .on : .off

        let paleThemeRow = NSStackView(views: [paleThemeCheckbox, NSView()])
        paleThemeRow.orientation = .horizontal
        paleThemeRow.alignment = .centerY

        let cliSeparator = NSBox()
        cliSeparator.boxType = .separator

        let cliIntroLabel = makeSecondaryLabel("Install snippets-cli to /usr/local/bin so agents and terminal scripts can interact with your snippets.")

        cliInstallButton.target = self
        cliInstallButton.action = #selector(installCLI)
        LiquidGlassDesign.configureActionButton(cliInstallButton, symbolName: "terminal")

        cliStatusLabel.font = .systemFont(ofSize: 12)
        cliStatusLabel.textColor = .secondaryLabelColor

        let cliRow = NSStackView(views: [cliInstallButton, NSView()])
        cliRow.orientation = .horizontal
        cliRow.alignment = .centerY

        stack.addArrangedSubview(introLabel)
        stack.addArrangedSubview(behaviorRow)
        stack.addArrangedSubview(selectionSummaryLabel)
        stack.addArrangedSubview(promptSummaryLabel)
        stack.addArrangedSubview(resetRow)
        stack.addArrangedSubview(themeSeparator)
        stack.addArrangedSubview(themeIntroLabel)
        stack.addArrangedSubview(paleThemeRow)
        stack.addArrangedSubview(cliSeparator)
        stack.addArrangedSubview(cliIntroLabel)
        stack.addArrangedSubview(cliRow)
        stack.addArrangedSubview(cliStatusLabel)

        behaviorRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        selectionSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        promptSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        themeSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliIntroLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        configureQuitBehaviorPopup()
        reloadFromStorage()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 720, height: 480)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalQuitBehaviorChange),
            name: .snippetsQuitBehaviorChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalPaleThemeChange),
            name: .snippetsPaleThemeChanged,
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
        applyThemeColors()
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

    private func installCLIWithPrivileges(source: URL, destination: URL) {
        let src = source.path.replacingOccurrences(of: "'", with: "'\\''")
        let dst = destination.path.replacingOccurrences(of: "'", with: "'\\''")
        let dir = destination.deletingLastPathComponent().path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"mkdir -p '\(dir)' && ln -sf '\(src)' '\(dst)'\" with administrator privileges"

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

    @objc private func handleExternalPaleThemeChange() {
        applyThemeColors()
    }

    @objc private func handlePaleThemeChanged(_ sender: NSButton) {
        ThemeManager.isPaleTheme = sender.state == .on
    }

    private func applyThemeColors() {
        paleThemeCheckbox.state = ThemeManager.isPaleTheme ? .on : .off
        ThemeManager.applyToggleAppearance(to: paleThemeCheckbox)
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

        let introLabel = makeSecondaryLabel("Add custom Chromium-based apps for enhanced accessibility priming. Built-in support already includes Chrome, Chromium, Edge, Brave, Opera, Vivaldi, and Arc.")
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

        stack.addArrangedSubview(introLabel)
        stack.addArrangedSubview(builtInLabel)
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(tableSurface)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(statusLabel)

        tableSurface.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let preferredTableHeight = tableSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
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

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 720, height: 480)
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

private func makeSettingsPane() -> (NSView, NSStackView) {
    let rootView = NSView()
    rootView.translatesAutoresizingMaskIntoConstraints = false
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setHuggingPriority(.required, for: .vertical)
    stack.setContentCompressionResistancePriority(.required, for: .vertical)
    rootView.addSubview(stack)

    let guide = rootView.safeAreaLayoutGuide

    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
        stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -24)
    ])

    return (rootView, stack)
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
