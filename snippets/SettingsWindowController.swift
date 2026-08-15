import AppKit
import AuthenticationServices
import CoreImage
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import UniformTypeIdentifiers
import Vision

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
    private let diagnosticsViewController = DiagnosticsSettingsViewController()

    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = false

        addTab(title: "General", symbolName: "gearshape", viewController: generalViewController)
        addTab(title: "Secure", symbolName: "lock", viewController: vaultViewController)
        // After Secure, because sync depends on it: the sealing key is the vault's.
        addTab(title: "Sync", symbolName: "arrow.triangle.2.circlepath", viewController: syncViewController)
        addTab(title: "Browsers", symbolName: "globe", viewController: browsersViewController)
        addTab(title: "Diagnostics", symbolName: "waveform.path.ecg", viewController: diagnosticsViewController)
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
        diagnosticsViewController.reloadFromStorage()
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

        let hotkeyIntroLabel = makeSecondaryLabel("Press \(GlobalHotkeyManager.securePasteDisplayString) to search all snippets: with a text or password field focused, it inserts without using the clipboard; with no text field focused, it copies an ordinary snippet instead. Press \(GlobalHotkeyManager.displayString) to show, hide, or launch Snippets. Secure snippets authenticate on every insertion and are never copied. Both shortcuts keep the same actions in Secure Input. Turn this off to leave the shortcuts to other apps.")

        globalHotkeyCheckbox.target = self
        globalHotkeyCheckbox.action = #selector(handleGlobalHotkeyChanged(_:))

        let globalHotkeyRow = NSStackView(views: [globalHotkeyCheckbox, NSView()])
        globalHotkeyRow.orientation = .horizontal
        globalHotkeyRow.alignment = .centerY

        globalHotkeyStatusLabel.font = .systemFont(ofSize: 12)
        globalHotkeyStatusLabel.textColor = .secondaryLabelColor

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
        updateCLIStatus()
    }

    private func updateGlobalHotkeyControls() {
        let manager = GlobalHotkeyManager.shared
        // Opening Settings is the natural moment to retry a registration that
        // lost the shortcut to another app at launch.
        manager.syncRegistration()

        globalHotkeyCheckbox.state = manager.isEnabled ? .on : .off
        if !manager.isEnabled {
            globalHotkeyStatusLabel.stringValue = "Global shortcuts are off. Open Snippets from the Dock or the menu bar item."
        } else if manager.isActive && manager.isSecurePasteActive {
            globalHotkeyStatusLabel.stringValue = "Both shortcuts are ready. Secure Paste requires Accessibility access."
        } else if manager.isActive {
            globalHotkeyStatusLabel.stringValue = "\(GlobalHotkeyManager.displayString) works, but macOS wouldn't register \(GlobalHotkeyManager.securePasteDisplayString) — another app is probably using it."
        } else if manager.isSecurePasteActive {
            globalHotkeyStatusLabel.stringValue = "\(GlobalHotkeyManager.securePasteDisplayString) works, but macOS wouldn't register \(GlobalHotkeyManager.displayString) — another app is probably using it."
        } else {
            globalHotkeyStatusLabel.stringValue = "macOS wouldn't register either shortcut. Quit the conflicting app and reopen Settings to try again."
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

    @objc private func handleExternalGlobalHotkeyChange() {
        updateGlobalHotkeyControls()
    }

    @objc private func handleGlobalHotkeyChanged(_ sender: NSButton) {
        GlobalHotkeyManager.shared.isEnabled = sender.state == .on
        updateGlobalHotkeyControls()
    }

    private func applyFrecencyControls() {
        guard let usageStore = (NSApp.delegate as? AppDelegate)?.usageStore else { return }

        frecencyCheckbox.state = usageStore.isRankingEnabled ? .on : .off
        selectionMemoryCheckbox.state = usageStore.isSelectionMemoryEnabled ? .on : .off
        // Selection memory refines the ranking; without ranking it has nothing
        // to refine.
        selectionMemoryCheckbox.isEnabled = usageStore.isRankingEnabled && !usageStore.isReadOnly
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
    private let clearHaltButton = NSButton(title: "Resume After Review", target: nil, action: nil)
    private let secondMacLabel = NSTextField(wrappingLabelWithString: "")
    private var presentedRecoveryAlert: NSAlert?
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
        configureCloudButton.action = #selector(configureSnippetsCloud)
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
            + "Use Sync Now if a change from another device has not appeared yet.")

        secondMacLabel.font = .systemFont(ofSize: 12)
        secondMacLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(providerRow)
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
        let selection = backendSelection
        if let item = providerPopup.itemArray.first(where: {
            ($0.representedObject as? String) == selection.provider.rawValue
        }) {
            providerPopup.select(item)
        }
        configureCloudButton.isHidden = !selection.snippetsCloudEnabled
            || selection.provider != .snippetsCloud
        statusLabel.stringValue = coordinator.statusDescription

        // Shown whenever sync is on, not only when an engine exists: a start that failed
        // on the keychain leaves no engine and no poll timer, and this button is what
        // retries it. Hiding it there was offering "relaunch the app" as the only cure.
        syncNowButton.isHidden = !SyncCoordinator.isEnabled
        if case .halted(let reason, _) = coordinator.state {
            clearHaltButton.isHidden = !reason.isUserRecoverable
        } else {
            clearHaltButton.isHidden = true
        }

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
    }

    @objc private func handleProviderChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let provider = SyncBackendSelectionStore.Provider(rawValue: rawValue) else { return }
        switch provider {
        case .iCloud:
            backendSelection.selectICloud()
            Self.coordinator?.reloadProviderSelection()
            reloadFromStorage()
        case .snippetsCloud:
            guard backendSelection.snippetsCloudEnabled else { return }
            configureSnippetsCloud()
        }
    }

    @objc private func configureSnippetsCloud() {
        let selection = backendSelection
        guard selection.snippetsCloudEnabled else { return }
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

    private func signInToSnippetsCloud(
        _ serverURL: URL,
        selection: SyncBackendSelectionStore
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await cloudBootstrap.signIn(
                    serverURL: serverURL,
                    presentationContext: self)
                try presentCloudState(state)
            } catch {
                showCloudError("Couldn’t Sign In to Snippets Cloud", error: error)
            }
            reloadFromStorage()
        }
    }

    private func presentCloudState(_ state: SnippetsCloudAccountBootstrap.State) throws {
        switch state {
        case .signedOut:
            configureSnippetsCloud()
        case .ready:
            Self.coordinator?.reloadProviderSelection()
            Self.coordinator?.syncNow()
            reloadFromStorage()
            presentCloudReadyMenu()
        case .needsTrustedDeviceOrRecovery:
            presentCloudUnlockMenu()
        case .waitingForApproval(let payload, let code):
            presentPairingQR(payload: payload, confirmationCode: code)
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
        alert.addButton(withTitle: "Use Nearby Device")
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

    private func presentCloudReadyMenu() {
        let alert = NSAlert()
        alert.messageText = "Snippets Cloud Is Ready"
        alert.informativeText = "No Snippets password or required email. This Mac has its own login session and a device-only copy of the encrypted library key."
        alert.addButton(withTitle: "Add Another Device")
        alert.addButton(withTitle: "Replace Recovery Kit")
        alert.addButton(withTitle: "Sign Out on This Mac")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            promptForPairingInvitation()
        case .alertSecondButtonReturn:
            runCloudTask("Couldn’t Replace Recovery Kit") { [weak self] in
                guard let self else { return }
                try self.presentCloudState(
                    try await self.cloudBootstrap.prepareRecoveryReplacement())
            }
        case .alertThirdButtonReturn:
            confirmCloudSignOut()
        default:
            break
        }
    }

    private func presentPairingQR(payload: String, confirmationCode: String) {
        let alert = cloudQRAlert(
            title: "Add This Mac",
            message: "Scan this one-time QR on a device that already has the library. Compare the code on both devices. It expires in about five minutes.",
            payload: payload,
            displayedCode: confirmationCode,
            warning: "The QR contains only a nonce and this Mac’s ephemeral public key — never the library key.")
        alert.addButton(withTitle: "Check Approval")
        alert.addButton(withTitle: "Cancel Pairing")
        if alert.runModal() == .alertFirstButtonReturn {
            runCloudTask("Pairing Isn’t Ready") { [weak self] in
                guard let self else { return }
                try self.presentCloudState(try await self.cloudBootstrap.checkPairing())
            }
        } else {
            runCloudTask("Couldn’t Cancel Pairing") { [weak self] in
                try await self?.cloudBootstrap.cancelPairing()
            }
        }
    }

    private func presentRecoveryKit(payload: String, longCode: String) {
        let alert = cloudQRAlert(
            title: "Save Your Recovery Kit",
            message: "Keep this QR or long code offline. It is the only fallback if every approved device is lost.",
            payload: payload,
            displayedCode: longCode,
            warning: "If you lose this kit and every approved device, old encrypted snippets are permanently unrecoverable — including by Snippets Cloud.")
        alert.addButton(withTitle: "I Saved It")
        alert.addButton(withTitle: "Reveal Again Later")
        presentedRecoveryAlert = alert
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(relockRecoveryPresentation),
            name: NSApplication.didResignActiveNotification,
            object: nil)
        defer {
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didResignActiveNotification,
                object: nil)
            presentedRecoveryAlert = nil
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try cloudBootstrap.acknowledgeRecoveryKitSaved()
            Self.coordinator?.reloadProviderSelection()
            Self.coordinator?.syncNow()
        } catch {
            showCloudError("Couldn’t Finish Setup", error: error)
        }
        reloadFromStorage()
    }

    @objc private func relockRecoveryPresentation() {
        guard let alert = presentedRecoveryAlert,
              NSApp.modalWindow === alert.window else { return }
        // Remove recovery material before AppKit snapshots inactive windows. The
        // durable encrypted presentation remains pending for a fresh biometric reveal.
        alert.window.orderOut(nil)
        NSApp.abortModal()
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
        promptForCloudPayload(
            title: "Recovery Kit",
            message: "Enter the long recovery code, paste the recovery QR payload, or read a saved QR image.",
            actionTitle: "Restore",
            supportsImage: true
        ) { [weak self] value in
            self?.runCloudTask("Couldn’t Restore Library") {
                guard let self else { return }
                try self.presentCloudState(
                    try await self.cloudBootstrap.restore(recoveryCodeOrQR: value))
            }
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
                presentationContext: self))
        }
    }

    private func confirmCloudSignOut() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sign Out on This Mac?"
        alert.informativeText = "This removes this Mac’s login credential and device-only library key. Cloud ciphertext is not deleted. You will need another approved device or the recovery kit to reconnect."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runCloudTask("Couldn’t Sign Out") { [weak self] in
            guard let self else { return }
            try await self.cloudBootstrap.signOutThisDevice()
            Self.coordinator?.reloadProviderSelection()
            self.reloadFromStorage()
        }
    }

    private func cloudQRAlert(
        title: String,
        message: String,
        payload: String,
        displayedCode: String,
        warning: String
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        if let image = cloudQRCode(payload) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 260),
                view.heightAnchor.constraint(equalToConstant: 260),
            ])
            stack.addArrangedSubview(view)
        }
        let code = NSTextField(wrappingLabelWithString: displayedCode)
        code.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        code.alignment = .center
        code.maximumNumberOfLines = 4
        code.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(code)
        let caution = NSTextField(wrappingLabelWithString: warning)
        caution.textColor = .systemRed
        caution.alignment = .center
        caution.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(caution)
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
        alert.accessoryView = stack
        return alert
    }

    private func cloudQRCode(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 260, height: 260))
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
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
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

extension SyncSettingsViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        _ = session
        return view.window!
    }
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
            + "operation counts, error families and numeric codes, and secure-snippet "
            + "keywords. When expansion verbose logging is enabled, they can also include "
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
        expansionVerboseRow.widthAnchor.constraint(equalToConstant: 620).isActive = true
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
        deleteButton.bezelStyle = .rounded

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
