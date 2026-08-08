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
    private let vaultViewController = VaultSettingsViewController()
    private let syncViewController = SyncSettingsViewController()
    private let browsersViewController = BrowserSettingsViewController()

    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = false

        addTab(title: "General", symbolName: "gearshape", viewController: generalViewController)
        addTab(title: "Secure", symbolName: "lock", viewController: vaultViewController)
        // After Secure, because sync depends on it: the sealing key is the vault's.
        addTab(title: "Sync", symbolName: "arrow.triangle.2.circlepath", viewController: syncViewController)
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
        vaultViewController.reloadFromStorage()
        syncViewController.reloadFromStorage()
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
    private let globalHotkeyCheckbox = NSButton(
        checkboxWithTitle: "Open Snippets with \(GlobalHotkeyManager.displayString) from anywhere",
        target: nil,
        action: nil
    )
    private let globalHotkeyStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let paleThemeCheckbox = NSButton(checkboxWithTitle: "Pale Theme", target: nil, action: nil)
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

        let hotkeySeparator = NSBox()
        hotkeySeparator.boxType = .separator

        let hotkeyIntroLabel = makeSecondaryLabel("Press \(GlobalHotkeyManager.displayString) in any app to bring Snippets to the front, and again while Snippets is focused to hide it. Turn this off to leave the shortcut to other apps.")

        globalHotkeyCheckbox.target = self
        globalHotkeyCheckbox.action = #selector(handleGlobalHotkeyChanged(_:))

        let globalHotkeyRow = NSStackView(views: [globalHotkeyCheckbox, NSView()])
        globalHotkeyRow.orientation = .horizontal
        globalHotkeyRow.alignment = .centerY

        globalHotkeyStatusLabel.font = .systemFont(ofSize: 12)
        globalHotkeyStatusLabel.textColor = .secondaryLabelColor

        let themeSeparator = NSBox()
        themeSeparator.boxType = .separator

        let themeIntroLabel = makeSecondaryLabel("Reduce accent colors throughout the interface for a quieter, more muted look.")

        paleThemeCheckbox.target = self
        paleThemeCheckbox.action = #selector(handlePaleThemeChanged(_:))
        paleThemeCheckbox.state = ThemeManager.isPaleTheme ? .on : .off

        let paleThemeRow = NSStackView(views: [paleThemeCheckbox, NSView()])
        paleThemeRow.orientation = .horizontal
        paleThemeRow.alignment = .centerY

        let matchHighlightIntroLabel = makeSecondaryLabel("Choose how the panel that appears after you type \u{201C}\\\u{201D} marks the letters your query matched. The next panel picks up the change \u{2014} no need to restart.")

        let matchHighlightLabel = NSTextField(labelWithString: "Matched letters:")
        matchHighlightLabel.textColor = .secondaryLabelColor
        matchHighlightLabel.font = .systemFont(ofSize: 13)
        matchHighlightLabel.alignment = .right
        matchHighlightLabel.setContentHuggingPriority(.required, for: .horizontal)
        matchHighlightLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true

        matchHighlightPopup.target = self
        matchHighlightPopup.action = #selector(handleMatchHighlightChanged(_:))
        matchHighlightPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let matchHighlightRow = NSStackView(views: [matchHighlightLabel, matchHighlightPopup, NSView()])
        matchHighlightRow.orientation = .horizontal
        matchHighlightRow.alignment = .centerY
        matchHighlightRow.spacing = 12

        matchHighlightSummaryLabel.font = .systemFont(ofSize: 12)
        matchHighlightSummaryLabel.textColor = .secondaryLabelColor

        let frecencySeparator = NSBox()
        frecencySeparator.boxType = .separator

        let frecencyIntroLabel = makeSecondaryLabel("Snippets you expand most often move to the top of the panel that appears after you type \u{201C}\\\u{201D}. Typing a full keyword always wins over usage, and pinned snippets always stay on top. Usage stays on this Mac \u{2014} it is never included in exports or share links.")

        frecencyCheckbox.target = self
        frecencyCheckbox.action = #selector(handleFrecencyChanged(_:))

        let frecencyRow = NSStackView(views: [frecencyCheckbox, NSView()])
        frecencyRow.orientation = .horizontal
        frecencyRow.alignment = .centerY

        selectionMemoryCheckbox.target = self
        selectionMemoryCheckbox.action = #selector(handleSelectionMemoryChanged(_:))

        let selectionMemoryRow = NSStackView(views: [selectionMemoryCheckbox, NSView()])
        selectionMemoryRow.orientation = .horizontal
        selectionMemoryRow.alignment = .centerY

        frecencyStatusLabel.font = .systemFont(ofSize: 12)
        frecencyStatusLabel.textColor = .secondaryLabelColor

        resetUsageButton.target = self
        resetUsageButton.action = #selector(resetUsageData)
        LiquidGlassDesign.configureActionButton(resetUsageButton, symbolName: "arrow.counterclockwise")

        let resetUsageRow = NSStackView(views: [resetUsageButton, NSView()])
        resetUsageRow.orientation = .horizontal
        resetUsageRow.alignment = .centerY

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
        stack.addArrangedSubview(hotkeySeparator)
        stack.addArrangedSubview(hotkeyIntroLabel)
        stack.addArrangedSubview(globalHotkeyRow)
        stack.addArrangedSubview(globalHotkeyStatusLabel)
        stack.addArrangedSubview(themeSeparator)
        stack.addArrangedSubview(themeIntroLabel)
        stack.addArrangedSubview(paleThemeRow)
        stack.addArrangedSubview(matchHighlightIntroLabel)
        stack.addArrangedSubview(matchHighlightRow)
        stack.addArrangedSubview(matchHighlightSummaryLabel)
        stack.addArrangedSubview(frecencySeparator)
        stack.addArrangedSubview(frecencyIntroLabel)
        stack.addArrangedSubview(frecencyRow)
        stack.addArrangedSubview(selectionMemoryRow)
        stack.addArrangedSubview(frecencyStatusLabel)
        stack.addArrangedSubview(resetUsageRow)
        stack.addArrangedSubview(cliSeparator)
        stack.addArrangedSubview(cliIntroLabel)
        stack.addArrangedSubview(cliRow)
        stack.addArrangedSubview(cliStatusLabel)

        behaviorRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        selectionSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        promptSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        hotkeySeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        hotkeyIntroLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        globalHotkeyStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        themeSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        themeIntroLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        matchHighlightIntroLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        matchHighlightRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        matchHighlightSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        frecencySeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        frecencyIntroLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        frecencyStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliIntroLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cliStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        configureQuitBehaviorPopup()
        configureMatchHighlightPopup()
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
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        selectQuitBehavior(appDelegate.quitBehaviorPreference)
        selectionSummaryLabel.stringValue = appDelegate.quitBehaviorPreferenceDescription

        if appDelegate.hasRememberedQuitBehavior {
            promptSummaryLabel.stringValue = "A remembered Cmd+Q preference is active. Choose \u{201C}Ask Every Time\u{201D} or use the reset button if you want the dialog back."
        } else {
            promptSummaryLabel.stringValue = "Snippets will show the Cmd+Q choice dialog until you select a remembered behavior."
        }

        resetButton.isEnabled = appDelegate.hasRememberedQuitBehavior
        applyMatchHighlightControls()
        updateGlobalHotkeyControls()
        applyFrecencyControls()
        applyThemeColors()
        updateCLIStatus()
    }

    private func updateGlobalHotkeyControls() {
        let manager = GlobalHotkeyManager.shared
        // Opening Settings is the natural moment to retry a registration that
        // lost the shortcut to another app at launch.
        manager.syncRegistration()

        globalHotkeyCheckbox.state = manager.isEnabled ? .on : .off
        ThemeManager.applyToggleAppearance(to: globalHotkeyCheckbox)

        if !manager.isEnabled {
            globalHotkeyStatusLabel.stringValue = "\(GlobalHotkeyManager.displayString) is off. Open Snippets from the Dock or the menu bar item."
        } else if manager.registrationFailed {
            globalHotkeyStatusLabel.stringValue = "macOS wouldn't register \(GlobalHotkeyManager.displayString) — another app is already using it. Quit that app and reopen Settings to try again."
        } else {
            globalHotkeyStatusLabel.stringValue = "\(GlobalHotkeyManager.displayString) works from any app, even while Snippets is hidden in the menu bar."
        }
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

    @objc private func handleExternalPaleThemeChange() {
        applyThemeColors()
    }

    @objc private func handlePaleThemeChanged(_ sender: NSButton) {
        ThemeManager.isPaleTheme = sender.state == .on
    }

    @objc private func handleExternalGlobalHotkeyChange() {
        updateGlobalHotkeyControls()
    }

    @objc private func handleGlobalHotkeyChanged(_ sender: NSButton) {
        GlobalHotkeyManager.shared.isEnabled = sender.state == .on
        updateGlobalHotkeyControls()
    }

    private func applyThemeColors() {
        paleThemeCheckbox.state = ThemeManager.isPaleTheme ? .on : .off
        ThemeManager.applyToggleAppearance(to: paleThemeCheckbox)
        ThemeManager.applyToggleAppearance(to: globalHotkeyCheckbox)
        ThemeManager.applyToggleAppearance(to: frecencyCheckbox)
        ThemeManager.applyToggleAppearance(to: selectionMemoryCheckbox)
    }

    private func applyFrecencyControls() {
        guard let usageStore = (NSApp.delegate as? AppDelegate)?.usageStore else { return }

        frecencyCheckbox.state = usageStore.isRankingEnabled ? .on : .off
        selectionMemoryCheckbox.state = usageStore.isSelectionMemoryEnabled ? .on : .off
        // Selection memory refines the ranking; without ranking it has nothing
        // to refine.
        selectionMemoryCheckbox.isEnabled = usageStore.isRankingEnabled && !usageStore.isReadOnly
        ThemeManager.applyToggleAppearance(to: frecencyCheckbox)
        ThemeManager.applyToggleAppearance(to: selectionMemoryCheckbox)

        let tracked = usageStore.trackedSnippetCount
        if usageStore.isReadOnly {
            frecencyStatusLabel.stringValue = "Usage data was written by a newer version of Snippets. Ranking is paused and nothing is being saved."
        } else if tracked == 0 {
            frecencyStatusLabel.stringValue = "No usage recorded yet."
        } else if let top = usageStore.mostUsedSummary {
            frecencyStatusLabel.stringValue = "Tracking \(tracked) snippet\(tracked == 1 ? "" : "s") \u{2014} \(usageStore.storageFootprintDescription). Most used: \(top.name) (\(top.count) use\(top.count == 1 ? "" : "s"))."
        } else {
            frecencyStatusLabel.stringValue = "Tracking \(tracked) snippet\(tracked == 1 ? "" : "s") \u{2014} \(usageStore.storageFootprintDescription)."
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
        // Switching this off deletes the table rather than merely stopping
        // collection: a guard in `record` alone would leave the stored prefixes
        // on disk forever, and the merge would bring them back.
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
        alert.informativeText = "Suggestions go back to pinned-then-newest-first order until you start using snippets again. Your snippets are not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Usage Data")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        usageStore.eraseAll()
        applyFrecencyControls()
        frecencyStatusLabel.stringValue = "Usage data reset."
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

        for item in matchHighlightPopup.itemArray where (item.representedObject as? String) == style.rawValue {
            matchHighlightPopup.select(item)
            break
        }

        matchHighlightSummaryLabel.stringValue = style.summary
    }

    @objc private func handleMatchHighlightChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let style = MatchHighlightStyle(rawValue: rawValue)
        else { return }

        MatchHighlightPreference.style = style
        applyMatchHighlightControls()
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
            alert.messageText = "Turn off iCloud Sync first"
            alert.informativeText = "\(SecureSnippetStore.Failure.forgetRequiresSyncOff)"
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = app.secureStore.isVaultShared
            ? "Remove \(count) secure snippet(s) from this Mac?"
            : "Permanently delete \(count) secure snippet(s)?"
        // A synchronizable Keychain item cannot be deleted locally: its deletion would
        // reach every Mac. The store therefore preserves the shared key and identity and
        // removes only this Mac's vault. Device-only builds keep the original permanent
        // deletion semantics.
        alert.informativeText = app.secureStore.isVaultShared
            ? "This removes the encrypted snippets from this Mac only. Their shared key "
                + "and copies on your other Macs stay intact. Re-enabling iCloud Sync "
                + "will bring them back to this Mac."
            : "This deletes the encrypted snippets and the key that opens them. "
                + "There is no undo, and no export or backup of this app contains their text."
        alert.addButton(withTitle: app.secureStore.isVaultShared ? "Remove" : "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try app.secureStore.forgetEverything()
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
        return box
    }
}

/// The opt-in switch for iCloud sync, and an honest account of what it does.
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
        checkboxWithTitle: "Sync snippets with iCloud", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)
    private let clearHaltButton = NSButton(title: "Resume After Review", target: nil, action: nil)
    private let secondMacLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView

        let title = NSTextField(labelWithString: "iCloud Sync")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let intro = makeSecondaryLabel(
            "Keeps your snippets on every Mac signed in to this iCloud account. "
            + "Every snippet is encrypted on this Mac before it leaves, so Apple stores only "
            + "ciphertext \u{2014} names, keywords and tags included. The key is kept in your "
            + "iCloud Keychain, which is how your other Macs can read what this one sends.")

        enableCheckbox.target = self
        enableCheckbox.action = #selector(handleEnabledChanged(_:))

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        syncNowButton.target = self
        syncNowButton.action = #selector(syncNow)
        LiquidGlassDesign.configureActionButton(syncNowButton, symbolName: "arrow.triangle.2.circlepath")

        clearHaltButton.target = self
        clearHaltButton.action = #selector(clearHalt)
        clearHaltButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [syncNowButton, clearHaltButton, NSView()])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // Usage data is the one thing that must never travel, and README already promises
        // it. Saying so here is cheaper than a support question.
        let limits = makeTertiaryLabel(
            "How often you use each snippet stays on this Mac and never syncs. "
            + "Snippets does not use push notifications for sync, so a change made on another "
            + "Mac can take up to two minutes to appear.")

        secondMacLabel.font = .systemFont(ofSize: 12)
        secondMacLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(enableCheckbox)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(buttonRow)
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
        coordinator.onStateChange = { [weak self] _ in self?.reloadFromStorage() }
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
        statusLabel.stringValue = coordinator.statusDescription

        // Shown whenever sync is on, not only when an engine exists: a start that failed
        // on the keychain leaves no engine and no poll timer, and this button is what
        // retries it. Hiding it there was offering "relaunch the app" as the only cure.
        syncNowButton.isHidden = !SyncCoordinator.isEnabled
        clearHaltButton.isHidden = !coordinator.state.isHalted

        secondMacLabel.stringValue = secondMacAdvice()
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
    }

    @objc private func syncNow() {
        Self.coordinator?.syncNow()
        reloadFromStorage()
    }

    @objc private func clearHalt() {
        Self.coordinator?.clearHaltAfterUserReview()
        reloadFromStorage()
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
