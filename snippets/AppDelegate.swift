import Cocoa
import ServiceManagement
import Sparkle

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, SPUUpdaterDelegate {
    private enum QuitBehavior: String {
        case ask
        case hide
        case quit
    }

    private enum QuitDecision {
        case hide
        case quit
        case cancel
    }

    let store = SnippetStore()
    lazy var expansionEngine = SnippetExpansionEngine(store: store)
    private lazy var settingsWindowController = SettingsWindowController()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )

    private let quitBehaviorDefaultsKey = "quitBehaviorPreference"
    private var statusItem: NSStatusItem!
    private var shouldTerminateForReal = false
    private var pendingUpdateInstallHandler: (() -> Void)?
    private var pendingUpdateVersion: String?
    private var isApplyingPendingUpdate = false
    private var userInitiatedUpdateCheck = false
    private var clearUpdateStatusWorkItem: DispatchWorkItem?
    private weak var appMenuCheckForUpdatesItem: NSMenuItem?
    private weak var appMenuUpdateStatusItem: NSMenuItem?
    private weak var appMenuRestartToUpdateItem: NSMenuItem?
    private var appMenuUpdateStatusView: UpdateProgressMenuItemView?

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private var systemIsTerminating: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)
        else { return false }
        let code = reason.enumCodeValue
        return code == kAEShutDown || code == kAERestart || code == kAEReallyLogOut
    }

    /// Sparkle sends a quit event when it needs to replace the app bundle.
    private var updaterIsTerminating: Bool {
        updaterController.updater.sessionInProgress
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        expansionEngine.startIfNeeded()
        configureAppMenuItems()
        setupStatusItem()
        updaterController.updater.automaticallyDownloadsUpdates = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChromiumBundleIDsChanged),
            name: .snippetsChromiumBundleIDsChanged,
            object: nil
        )

        if launchedAsLoginItem {
            hideToBackground()
        }

        #if !DEBUG
        updaterController.updater.checkForUpdatesInBackground()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushPendingWrites()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shouldTerminateForReal || systemIsTerminating || updaterIsTerminating {
            return .terminateNow
        }

        switch currentQuitBehavior {
        case .hide:
            hideToBackground()
            return .terminateCancel
        case .quit:
            return .terminateNow
        case .ask:
            switch promptForQuitDecision() {
            case .hide:
                hideToBackground()
                return .terminateCancel
            case .quit:
                return .terminateNow
            case .cancel:
                return .terminateCancel
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @IBAction func newDocument(_ sender: Any?) {
        NotificationCenter.default.post(name: .snippetsCreateNew, object: nil)
    }

    @IBAction func toggleLaunchAtLogin(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
    }

    @IBAction func openSettings(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        settingsWindowController.showSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleChromiumBundleIDsChanged() {
        expansionEngine.chromiumBundleIDSettingsDidChange()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin(_:)) {
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            return true
        }
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updaterController.updater.canCheckForUpdates && !isApplyingPendingUpdate
        }
        if menuItem.action == #selector(installPendingUpdateAndRestart(_:)) {
            return pendingUpdateInstallHandler != nil && !isApplyingPendingUpdate
        }
        return true
    }

    // MARK: - Status Bar Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.cursor.typefill", accessibilityDescription: "Snippets")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Snippets", action: #selector(openFromStatusBar), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snippets", action: #selector(quitCompletely(_:)), keyEquivalent: ""))
        statusItem.menu = menu
    }

    private func configureAppMenuItems() {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }

        if let settingsItem = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
            settingsItem.title = "Settings…"
            settingsItem.target = self
            settingsItem.action = #selector(openSettings(_:))
        }

        if appMenu.items.contains(where: { $0.action == #selector(checkForUpdates(_:)) }) {
            appMenuCheckForUpdatesItem = appMenu.items.first(where: { $0.action == #selector(checkForUpdates(_:)) })
            appMenuUpdateStatusItem = appMenu.items.first(where: { $0.tag == 981_001 })
            appMenuRestartToUpdateItem = appMenu.items.first(where: { $0.action == #selector(installPendingUpdateAndRestart(_:)) })
            refreshAppMenuUpdateState()
            return
        }

        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = self

        let updateStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        updateStatusItem.tag = 981_001
        updateStatusItem.isEnabled = false
        updateStatusItem.isHidden = true
        let updateStatusView = UpdateProgressMenuItemView(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        updateStatusItem.view = updateStatusView

        let restartToUpdateItem = NSMenuItem(title: "Restart to Apply Update", action: #selector(installPendingUpdateAndRestart(_:)), keyEquivalent: "")
        restartToUpdateItem.target = self
        restartToUpdateItem.isHidden = true

        let insertionIndex: Int
        if let settingsIndex = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }),
           let separatorAfterSettings = appMenu.items[(settingsIndex + 1)...].firstIndex(where: { $0.isSeparatorItem }) {
            insertionIndex = separatorAfterSettings
        } else if let firstSeparator = appMenu.items.firstIndex(where: { $0.isSeparatorItem }) {
            insertionIndex = firstSeparator + 1
        } else {
            insertionIndex = appMenu.items.count
        }

        appMenu.insertItem(checkForUpdatesItem, at: insertionIndex)
        appMenu.insertItem(updateStatusItem, at: insertionIndex + 1)
        appMenu.insertItem(restartToUpdateItem, at: insertionIndex + 2)

        appMenuCheckForUpdatesItem = checkForUpdatesItem
        appMenuUpdateStatusItem = updateStatusItem
        appMenuRestartToUpdateItem = restartToUpdateItem
        appMenuUpdateStatusView = updateStatusView
        refreshAppMenuUpdateState()
    }

    @objc private func openFromStatusBar() {
        showMainWindow()
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        if pendingUpdateInstallHandler != nil {
            setUpdateStatus("Update \(pendingUpdateVersion ?? "") is ready. Use \"Restart to Apply Update\".", showProgress: false, autoClearAfter: nil)
            return
        }

        userInitiatedUpdateCheck = true
        setUpdateStatus("Checking for updates…", showProgress: true, autoClearAfter: nil)
        updaterController.updater.checkForUpdatesInBackground()
    }

    @IBAction func installPendingUpdateAndRestart(_ sender: Any?) {
        guard let installHandler = pendingUpdateInstallHandler, !isApplyingPendingUpdate else { return }
        isApplyingPendingUpdate = true
        setUpdateStatus("Applying update and restarting…", showProgress: true, autoClearAfter: nil)
        refreshAppMenuUpdateState()
        shouldTerminateForReal = true
        installHandler()
    }

    @IBAction func quitCompletely(_ sender: Any?) {
        shouldTerminateForReal = true
        NSApp.terminate(sender)
    }

    // MARK: - Quit Behavior

    var hasRememberedQuitBehavior: Bool {
        UserDefaults.standard.string(forKey: quitBehaviorDefaultsKey) != nil
    }

    @IBAction func resetQuitBehaviorPreference(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: quitBehaviorDefaultsKey)
    }

    private var currentQuitBehavior: QuitBehavior {
        let storedValue = UserDefaults.standard.string(forKey: quitBehaviorDefaultsKey)
        return QuitBehavior(rawValue: storedValue ?? QuitBehavior.ask.rawValue) ?? .ask
    }

    private func setQuitBehavior(_ behavior: QuitBehavior) {
        UserDefaults.standard.set(behavior.rawValue, forKey: quitBehaviorDefaultsKey)
    }

    private func promptForQuitDecision() -> QuitDecision {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "What should Cmd+Q do?"
        alert.informativeText = "Hide removes Snippets from the Dock and keeps it running in the menu bar. Quit completely stops Snippets."
        alert.alertStyle = .informational
        let hideButton = alert.addButton(withTitle: "Hide (Keep Running)")
        alert.addButton(withTitle: "Quit Completely")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        hideButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember choice"

        let response = alert.runModal()
        let shouldRemember = alert.suppressionButton?.state == .on

        switch response {
        case .alertFirstButtonReturn:
            if shouldRemember {
                setQuitBehavior(.hide)
            }
            return .hide
        case .alertSecondButtonReturn:
            if shouldRemember {
                setQuitBehavior(.quit)
            }
            return .quit
        default:
            return .cancel
        }
    }

    // MARK: - Activation Policy Switching

    private func hideToBackground() {
        for window in NSApp.windows {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)

        if let window = NSApp.windows.first(where: { $0.contentViewController is ViewController }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)
            if let wc = storyboard.instantiateInitialController() as? NSWindowController {
                wc.showWindow(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Update UI State

    private func refreshAppMenuUpdateState() {
        appMenuCheckForUpdatesItem?.isEnabled = updaterController.updater.canCheckForUpdates && !isApplyingPendingUpdate

        if let version = pendingUpdateVersion, !version.isEmpty {
            appMenuRestartToUpdateItem?.title = "Restart to Apply Update \(version)"
        } else {
            appMenuRestartToUpdateItem?.title = "Restart to Apply Update"
        }

        appMenuRestartToUpdateItem?.isHidden = pendingUpdateInstallHandler == nil
        appMenuRestartToUpdateItem?.isEnabled = pendingUpdateInstallHandler != nil && !isApplyingPendingUpdate
    }

    private func setUpdateStatus(_ message: String?, showProgress: Bool, autoClearAfter: TimeInterval?) {
        clearUpdateStatusWorkItem?.cancel()
        clearUpdateStatusWorkItem = nil

        if let message, !message.isEmpty {
            appMenuUpdateStatusItem?.title = message
            appMenuUpdateStatusView?.update(message: message, showProgress: showProgress)
            appMenuUpdateStatusItem?.isHidden = false
            if let autoClearAfter {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.appMenuUpdateStatusView?.update(message: "", showProgress: false)
                    self?.appMenuUpdateStatusItem?.isHidden = true
                }
                clearUpdateStatusWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + autoClearAfter, execute: workItem)
            }
        } else {
            appMenuUpdateStatusView?.update(message: "", showProgress: false)
            appMenuUpdateStatusItem?.isHidden = true
        }

        refreshAppMenuUpdateState()
    }

    private func updateVersionString(from item: SUAppcastItem) -> String {
        let displayVersionString = item.displayVersionString
        if !displayVersionString.isEmpty {
            return displayVersionString
        }
        return item.versionString
    }

    // MARK: - Sparkle Delegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = updateVersionString(from: item)
        setUpdateStatus("Update \(version) found. Downloading…", showProgress: true, autoClearAfter: nil)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let version = updateVersionString(from: item)
        setUpdateStatus("Downloading update \(version)…", showProgress: true, autoClearAfter: nil)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let version = updateVersionString(from: item)
        setUpdateStatus("Downloaded update \(version). Preparing…", showProgress: true, autoClearAfter: nil)
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        let version = updateVersionString(from: item)
        setUpdateStatus("Prepared update \(version). Finalizing…", showProgress: true, autoClearAfter: nil)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        setUpdateStatus("Update download failed: \(error.localizedDescription)", showProgress: false, autoClearAfter: 8)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        setUpdateStatus("Update download canceled.", showProgress: false, autoClearAfter: 5)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingUpdateInstallHandler = immediateInstallHandler
        pendingUpdateVersion = updateVersionString(from: item)
        isApplyingPendingUpdate = false
        setUpdateStatus("Update \(pendingUpdateVersion ?? "") is ready. Choose \"Restart to Apply Update\".", showProgress: false, autoClearAfter: nil)
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard userInitiatedUpdateCheck else { return }
        setUpdateStatus("You're up to date.", showProgress: false, autoClearAfter: 4)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isApplyingPendingUpdate = false
        let nsError = error as NSError

        // Sparkle may report "no update available" through abort callback.
        // Treat this as a success state for user-initiated checks.
        if nsError.code == 1001 {
            if userInitiatedUpdateCheck {
                setUpdateStatus("You're up to date.", showProgress: false, autoClearAfter: 4)
            }
            refreshAppMenuUpdateState()
            return
        }

        // User canceled the install authorization prompt.
        if nsError.code == 4007 {
            refreshAppMenuUpdateState()
            return
        }

        setUpdateStatus("Update check failed: \(error.localizedDescription)", showProgress: false, autoClearAfter: 8)
        refreshAppMenuUpdateState()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        userInitiatedUpdateCheck = false
        if pendingUpdateInstallHandler == nil && error == nil {
            refreshAppMenuUpdateState()
        }
    }
}

private final class UpdateProgressMenuItemView: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusLabel)
        addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            progressIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            progressIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            progressIndicator.heightAnchor.constraint(equalToConstant: 10),
            progressIndicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(message: String, showProgress: Bool) {
        statusLabel.stringValue = message
        if showProgress {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }
}
