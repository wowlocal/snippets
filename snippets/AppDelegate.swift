import Cocoa
import ServiceManagement
#if !NO_SPARKLE
import Sparkle
#endif

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    enum QuitBehaviorPreference: String, CaseIterable {
        case ask
        case hide
        case quit

        var menuTitle: String {
            switch self {
            case .ask:
                return "Ask Every Time"
            case .hide:
                return "Hide to Menu Bar"
            case .quit:
                return "Quit Completely"
            }
        }

        var settingsDescription: String {
            switch self {
            case .ask:
                return "Snippets will ask what to do each time you press Cmd+Q."
            case .hide:
                return "Cmd+Q will hide Snippets to the menu bar and keep it running."
            case .quit:
                return "Cmd+Q will quit Snippets completely without asking."
            }
        }
    }

    private enum QuitDecision {
        case hide
        case quit
        case cancel
    }

    let store = SnippetStore()
    lazy var expansionEngine = SnippetExpansionEngine(store: store)
    private lazy var settingsWindowController = SettingsWindowController()
    #if !NO_SPARKLE
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )
    #endif

    private let quitBehaviorDefaultsKey = "quitBehaviorPreference"
    private var statusItem: NSStatusItem!
    private var shouldTerminateForReal = false
    #if !NO_SPARKLE
    private var pendingUpdateInstallHandler: (() -> Void)?
    private var pendingUpdateVersion: String?
    private var isApplyingPendingUpdate = false
    private var userInitiatedUpdateCheck = false
    private var clearUpdateStatusWorkItem: DispatchWorkItem?
    private weak var appMenuCheckForUpdatesItem: NSMenuItem?
    private weak var appMenuUpdateStatusItem: NSMenuItem?
    private weak var appMenuRestartToUpdateItem: NSMenuItem?
    private var appMenuUpdateStatusView: UpdateProgressMenuItemView?
    private var updateAccessoryControllers: [ObjectIdentifier: UpdateReadyAccessoryController] = [:]
    #endif
    #if DEBUG && !NO_SPARKLE
    private var debugShowUpdatePill = false
    private let debugPillVersion = "DEBUG"
    #endif

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

    #if !NO_SPARKLE
    /// Sparkle sends a quit event when it needs to replace the app bundle.
    private var updaterIsTerminating: Bool {
        updaterController.updater.sessionInProgress
    }
    #else
    private var updaterIsTerminating: Bool { false }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        expansionEngine.startIfNeeded()
        configureAppMenuItems()
        #if DEBUG && !NO_SPARKLE
        configureDebugMenu()
        #endif
        setupStatusItem()
        #if !NO_SPARKLE
        updaterController.updater.automaticallyDownloadsUpdates = true
        #endif
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChromiumBundleIDsChanged),
            name: .snippetsChromiumBundleIDsChanged,
            object: nil
        )
        #if !NO_SPARKLE
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeMain),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        #endif

        if launchedAsLoginItem {
            hideToBackground()
        }

        #if !DEBUG && !NO_SPARKLE
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

        switch quitBehaviorPreference {
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

    func application(_ application: NSApplication, open urls: [URL]) {
        let deepLinks = urls.filter { SnippetDeepLink.canHandle($0) }
        guard !deepLinks.isEmpty else { return }

        for url in deepLinks {
            handleSnippetDeepLink(url)
        }
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
        #if !NO_SPARKLE
        refreshWindowUpdateAccessories()
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleChromiumBundleIDsChanged() {
        expansionEngine.chromiumBundleIDSettingsDidChange()
    }

    #if !NO_SPARKLE
    @objc private func handleWindowDidBecomeMain(_ notification: Notification) {
        refreshWindowUpdateAccessories()
    }

    @objc private func handleWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let windowID = ObjectIdentifier(window)
        guard let controller = updateAccessoryControllers.removeValue(forKey: windowID) else { return }
        removeUpdateAccessoryController(controller, from: window)
    }
    #endif

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin(_:)) {
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            return true
        }
        if menuItem.action == #selector(resetQuitBehaviorPreference(_:)) {
            let hasRemembered = hasRememberedQuitBehavior
            menuItem.isHidden = !hasRemembered
            return hasRemembered
        }
        #if !NO_SPARKLE
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updaterController.updater.canCheckForUpdates && !isApplyingPendingUpdate
        }
        if menuItem.action == #selector(installPendingUpdateAndRestart(_:)) {
            return pendingUpdateInstallHandler != nil && !isApplyingPendingUpdate
        }
        #endif
        #if DEBUG && !NO_SPARKLE
        if menuItem.action == #selector(toggleDebugUpdatePill(_:)) {
            menuItem.state = debugShowUpdatePill ? .on : .off
            return true
        }
        #endif
        return true
    }

    // MARK: - Status Bar Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.cursor.typefill", accessibilityDescription: "Snippets")
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Snippets", action: #selector(openFromStatusBar), keyEquivalent: "")
        openItem.target = self
        let resetQuitBehaviorItem = NSMenuItem(
            title: "Reset Remembered Cmd+Q Choice",
            action: #selector(resetQuitBehaviorPreference(_:)),
            keyEquivalent: ""
        )
        resetQuitBehaviorItem.target = self
        let quitItem = NSMenuItem(title: "Quit Snippets", action: #selector(quitCompletely(_:)), keyEquivalent: "")
        quitItem.target = self

        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(resetQuitBehaviorItem)
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    #if DEBUG && !NO_SPARKLE
    private func configureDebugMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if mainMenu.items.contains(where: { $0.title == "Debug" }) {
            return
        }

        let debugMenuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let debugMenu = NSMenu(title: "Debug")

        let showUpdatePillItem = NSMenuItem(
            title: "Show Update Pill",
            action: #selector(toggleDebugUpdatePill(_:)),
            keyEquivalent: ""
        )
        showUpdatePillItem.target = self
        debugMenu.addItem(showUpdatePillItem)
        debugMenuItem.submenu = debugMenu

        if let helpMenuIndex = mainMenu.items.firstIndex(where: { $0.title == "Help" }) {
            mainMenu.insertItem(debugMenuItem, at: helpMenuIndex)
        } else {
            mainMenu.addItem(debugMenuItem)
        }
    }
    #endif

    private func configureAppMenuItems() {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }

        if let settingsItem = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
            settingsItem.title = "Settings…"
            settingsItem.target = self
            settingsItem.action = #selector(openSettings(_:))
        }

        if appMenu.items.contains(where: { $0.action == #selector(resetQuitBehaviorPreference(_:)) }) == false {
            let resetQuitBehaviorItem = NSMenuItem(
                title: "Reset Remembered Cmd+Q Choice",
                action: #selector(resetQuitBehaviorPreference(_:)),
                keyEquivalent: ""
            )
            resetQuitBehaviorItem.target = self

            if let settingsIndex = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                appMenu.insertItem(resetQuitBehaviorItem, at: settingsIndex + 1)
            } else {
                appMenu.insertItem(resetQuitBehaviorItem, at: 0)
            }
        }

        #if !NO_SPARKLE
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
        #endif
    }

    @objc private func openFromStatusBar() {
        showMainWindow()
    }

    #if DEBUG && !NO_SPARKLE
    @objc private func toggleDebugUpdatePill(_ sender: Any?) {
        debugShowUpdatePill.toggle()
        if debugShowUpdatePill {
            showMainWindow()
            setUpdateStatus("Debug: showing update pill preview.", showProgress: false, autoClearAfter: 2.5)
        } else if pendingUpdateInstallHandler == nil {
            setUpdateStatus(nil, showProgress: false, autoClearAfter: nil)
        }
        refreshAppMenuUpdateState()
    }

    @objc private func applyDebugUpdatePill(_ sender: Any?) {
        setUpdateStatus("Debug: restart action tapped (preview only).", showProgress: false, autoClearAfter: 3)
    }
    #endif

    #if !NO_SPARKLE
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
    #endif

    @IBAction func quitCompletely(_ sender: Any?) {
        shouldTerminateForReal = true
        NSApp.terminate(sender)
    }

    // MARK: - Quit Behavior

    var hasRememberedQuitBehavior: Bool {
        UserDefaults.standard.string(forKey: quitBehaviorDefaultsKey) != nil
    }

    var rememberedQuitBehaviorDescription: String? {
        guard hasRememberedQuitBehavior else { return nil }

        switch quitBehaviorPreference {
        case .ask:
            return nil
        case .hide:
            return "Cmd+Q currently hides Snippets and keeps it running in the menu bar."
        case .quit:
            return "Cmd+Q currently quits Snippets completely."
        }
    }

    var quitBehaviorPreference: QuitBehaviorPreference {
        let storedValue = UserDefaults.standard.string(forKey: quitBehaviorDefaultsKey)
        return QuitBehaviorPreference(rawValue: storedValue ?? QuitBehaviorPreference.ask.rawValue) ?? .ask
    }

    var quitBehaviorPreferenceDescription: String {
        quitBehaviorPreference.settingsDescription
    }

    func updateQuitBehaviorPreference(_ preference: QuitBehaviorPreference) {
        switch preference {
        case .ask:
            UserDefaults.standard.removeObject(forKey: quitBehaviorDefaultsKey)
        case .hide, .quit:
            UserDefaults.standard.set(preference.rawValue, forKey: quitBehaviorDefaultsKey)
        }

        NotificationCenter.default.post(name: .snippetsQuitBehaviorChanged, object: nil)
    }

    @IBAction func resetQuitBehaviorPreference(_ sender: Any?) {
        guard hasRememberedQuitBehavior else { return }
        updateQuitBehaviorPreference(.ask)
    }

    private func promptForQuitDecision() -> QuitDecision {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "What should Cmd+Q do?"
        alert.informativeText = "Hide removes Snippets from the Dock and keeps it running in the menu bar. Quit completely stops Snippets. You can reset a remembered choice later in Settings."
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
                updateQuitBehaviorPreference(.hide)
            }
            return .hide
        case .alertSecondButtonReturn:
            if shouldRemember {
                updateQuitBehaviorPreference(.quit)
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

    @discardableResult
    private func showMainWindow() -> ViewController? {
        NSApp.setActivationPolicy(.regular)

        let window: NSWindow?
        if let window = NSApp.windows.first(where: { $0.contentViewController is ViewController }) {
            window.makeKeyAndOrderFront(nil)
            #if !NO_SPARKLE
            refreshWindowUpdateAccessories()
            #endif
            NSApp.activate(ignoringOtherApps: true)
            return window.contentViewController as? ViewController
        } else {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)
            if let wc = storyboard.instantiateInitialController() as? NSWindowController {
                wc.showWindow(nil)
                window = wc.window
            } else {
                window = nil
            }
        }
        #if !NO_SPARKLE
        refreshWindowUpdateAccessories()
        #endif
        NSApp.activate(ignoringOtherApps: true)
        return window?.contentViewController as? ViewController
    }

    private func handleSnippetDeepLink(_ url: URL) {
        let viewController = showMainWindow()

        do {
            let snippet = try SnippetDeepLink.snippet(from: url)

            guard confirmImportOfSharedSnippet(snippet) else { return }

            let importedSnippet = try store.importSharedSnippet(snippet)
            if let viewController {
                let hasActiveSearch = !viewController.searchField.stringValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                if hasActiveSearch {
                    viewController.searchField.stringValue = ""
                    viewController.reloadVisibleSnippets(keepSelection: true)
                }
                viewController.selectSnippet(id: importedSnippet.id, focusEditorName: false)
                viewController.importExportMessage = "Imported shared snippet \(importedSnippet.displayName)."
                viewController.requestFirstResponder(viewController.tableView)
            }
        } catch {
            showDeepLinkAlert(
                title: "Shared Link Failed",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func confirmImportOfSharedSnippet(_ snippet: Snippet) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Import Shared Snippet?"
        alert.informativeText = sharedSnippetSummary(snippet)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func sharedSnippetSummary(_ snippet: Snippet) -> String {
        let keyword = snippet.normalizedKeyword.isEmpty ? "No keyword" : "\\\(snippet.normalizedKeyword)"
        let content = snippet.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = content.isEmpty ? "(empty content)" : truncatedSharedSnippetPreview(content)

        return """
        Name: \(snippet.displayName)
        Keyword: \(keyword)

        Preview:
        \(preview)
        """
    }

    private func truncatedSharedSnippetPreview(_ content: String) -> String {
        let maxCharacters = 280
        guard content.count > maxCharacters else { return content }
        let endIndex = content.index(content.startIndex, offsetBy: maxCharacters)
        return String(content[..<endIndex]) + "…"
    }

    private func showDeepLinkAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Update UI State

    #if !NO_SPARKLE
    private func refreshAppMenuUpdateState() {
        appMenuCheckForUpdatesItem?.isEnabled = updaterController.updater.canCheckForUpdates && !isApplyingPendingUpdate

        if let version = pendingUpdateVersion, !version.isEmpty {
            appMenuRestartToUpdateItem?.title = "Restart to Apply Update \(version)"
        } else {
            appMenuRestartToUpdateItem?.title = "Restart to Apply Update"
        }

        appMenuRestartToUpdateItem?.isHidden = pendingUpdateInstallHandler == nil
        appMenuRestartToUpdateItem?.isEnabled = pendingUpdateInstallHandler != nil && !isApplyingPendingUpdate
        refreshWindowUpdateAccessories()
    }

    private func refreshWindowUpdateAccessories() {
        #if DEBUG
        let showingDebugPreviewPill = debugShowUpdatePill && pendingUpdateInstallHandler == nil && !isApplyingPendingUpdate
        #else
        let showingDebugPreviewPill = false
        #endif
        let shouldShowAccessory = pendingUpdateInstallHandler != nil || isApplyingPendingUpdate || showingDebugPreviewPill
        let candidateWindows = updateAccessoryCandidateWindows()
        let candidateWindowIDs = Set(candidateWindows.map { ObjectIdentifier($0) })

        if !shouldShowAccessory {
            for (windowID, controller) in updateAccessoryControllers {
                if let window = NSApp.windows.first(where: { ObjectIdentifier($0) == windowID }) {
                    removeUpdateAccessoryController(controller, from: window)
                }
            }
            updateAccessoryControllers.removeAll()
            return
        }

        let staleWindowIDs = Array(updateAccessoryControllers.keys).filter { !candidateWindowIDs.contains($0) }
        for windowID in staleWindowIDs {
            if let controller = updateAccessoryControllers.removeValue(forKey: windowID),
               let window = NSApp.windows.first(where: { ObjectIdentifier($0) == windowID }) {
                removeUpdateAccessoryController(controller, from: window)
            }
        }

        for window in candidateWindows {
            let windowID = ObjectIdentifier(window)
            let controller: UpdateReadyAccessoryController
            if let existing = updateAccessoryControllers[windowID] {
                controller = existing
            } else {
                let accessoryController = UpdateReadyAccessoryController()
                accessoryController.layoutAttribute = .right
                window.addTitlebarAccessoryViewController(accessoryController)
                updateAccessoryControllers[windowID] = accessoryController
                controller = accessoryController
            }

            let pillVersion: String?
            if let pendingUpdateVersion, !pendingUpdateVersion.isEmpty {
                pillVersion = pendingUpdateVersion
            } else {
                #if DEBUG
                if showingDebugPreviewPill {
                    pillVersion = debugPillVersion
                } else {
                    pillVersion = nil
                }
                #else
                pillVersion = nil
                #endif
            }

            let pillAction: Selector
            if pendingUpdateInstallHandler != nil || isApplyingPendingUpdate {
                pillAction = #selector(installPendingUpdateAndRestart(_:))
            } else {
                #if DEBUG
                pillAction = #selector(applyDebugUpdatePill(_:))
                #else
                pillAction = #selector(installPendingUpdateAndRestart(_:))
                #endif
            }

            controller.configure(
                version: pillVersion,
                isApplying: isApplyingPendingUpdate,
                target: self,
                action: pillAction
            )
        }
    }

    private func updateAccessoryCandidateWindows() -> [NSWindow] {
        let settingsWindow = settingsWindowController.window
        return NSApp.windows.filter { window in
            window.canBecomeMain
                && !window.isMiniaturized
                && (window.contentViewController is ViewController || window === settingsWindow)
        }
    }

    private func removeUpdateAccessoryController(_ controller: UpdateReadyAccessoryController, from window: NSWindow) {
        guard let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === controller }) else {
            return
        }
        window.removeTitlebarAccessoryViewController(at: index)
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

    #endif
}

// MARK: - Sparkle Delegate

#if !NO_SPARKLE
extension AppDelegate: SPUUpdaterDelegate {
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
#endif

#if !NO_SPARKLE
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
#endif
