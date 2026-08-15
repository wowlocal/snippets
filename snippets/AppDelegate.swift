import Cocoa
import ServiceManagement
#if !NO_SPARKLE
import Sparkle
#endif

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
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

    private enum SecurePasteDestination {
        case textField(SnippetExpansionEngine.SecurePasteTarget)
        case clipboard

        var textFieldTarget: SnippetExpansionEngine.SecurePasteTarget? {
            guard case .textField(let target) = self else { return nil }
            return target
        }
    }

    // Declaration order is load-bearing: diagnostics creates `Diagnostics/` and
    // `Tmp/` first, then the usage store creates `Usage/`, and only then does
    // `SnippetStore.init()` install its support-folder DispatchSource. Creating
    // either directory after the monitor went up would look like a library edit.
    let diagnostics = DiagnosticsService.shared
    let usageStore = SnippetUsageStore()
    let store = SnippetStore()
    /// AppKit ignores per-view protected-content attributes unless the process
    /// first opts into the application-wide contract. Kept as a separate,
    /// injectable object so the fail-closed path is deterministic in tests.
    let secureContentAccessibilityProtection = SecureContentAccessibilityProtection()
    /// Constructed eagerly but does nothing until a vault exists: with no key it settles
    /// into `.noKey` without ever touching the keychain, so there is no prompt and no
    /// cost for the vast majority of users who never create a secure snippet.
    let vaultSession = VaultSession()
    lazy var secureStore = SecureSnippetStore(session: vaultSession, deviceID: store.deviceID)
    /// Answers `snippets-cli`. Started unconditionally: `status` has to work whether or
    /// not a vault exists, and the socket is how the CLI discovers the app is running.
    private lazy var controlServer = ControlServer(session: vaultSession, secureStore: secureStore)

    /// Presents both stores to the sync engine as one library.
    ///
    /// Constructed eagerly, unlike the engine: it is cheap, it holds no resources, and
    /// having it here means the translation between the stores and the wire format is
    /// exercised by the app's own object graph rather than only by tests.
    lazy var syncLibrary = SnippetLibraryBridge(store: store, secureStore: secureStore)
    lazy var backendSelection = SyncBackendSelectionStore()

    /// Owns whether sync runs, and runs it. Opt-in: constructing this costs nothing and
    /// starts nothing.
    ///
    /// The engine inside it is deliberately not constructed with a placeholder transport.
    /// A `SyncEngine` that exists but talks to nothing would still run its loop, write a
    /// base file, and report states — all describing a synchronisation that is not
    /// happening. Absent is the honest representation of "sync is off", and it is what
    /// `SyncState.Backend.none` means.
    lazy var syncCoordinator = SyncCoordinator(
        library: syncLibrary,
        keys: SyncKeyStore(
            keychain: KeychainSecretStore(),
            cloudKeys: backendSelection.cloudKeys,
            usesSnippetsCloud: { [unowned self] in
                self.backendSelection.provider == .snippetsCloud
            }),
        device: store.deviceID,
        backendSelection: backendSelection)

    /// The engine, when one is running. Read by the settings pane; `nil` whenever the
    /// user has not opted in, or the keychain would not supply a wire key.
    var syncEngine: SyncEngine? { syncCoordinator.engine }
    lazy var expansionEngine: SnippetExpansionEngine = {
        let engine = SnippetExpansionEngine(store: store, usage: usageStore)
        let diagnostics = diagnostics
        engine.expansionVerboseDiagnosticsEnabled = {
            diagnostics.expansionVerboseLogging.isEnabled
        }
        // Keep key ownership outside the typing engine. Every explicit secure
        // suggestion gets its own user-presence decision, one record is decrypted into
        // a wipeable lease, and VaultSession drops the key before this closure returns.
        let session = vaultSession
        let secureStore = secureStore
        engine.secureSnippetContentResolver = { snippet, reason in
            try await session.withOneUseAuthentication(reason: reason) {
                var plaintext = try secureStore.contentData(for: snippet.id)
                return SecurePlaintextLease(consuming: &plaintext)
            }
        }
        return engine
    }()
    private lazy var transientScreenMessageController = TransientScreenMessageController()
    private var settingsWindowController: SettingsWindowController?
    #if !NO_SPARKLE
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private let quitBehaviorDefaultsKey = "quitBehaviorPreference"
    private var statusItem: NSStatusItem!
    private weak var statusMenuOpenItem: NSMenuItem?
    private weak var statusMenuSecurePasteItem: NSMenuItem?
    private weak var statusMenuClipboardItem: NSMenuItem?
    private var hotkeyPromotedFromAccessory = false
    /// Captured as the status menu opens, before its menu window can disturb the
    /// password field that was focused in the frontmost app.
    private var statusMenuSecurePasteDestination: SecurePasteDestination?
    private var securePasteDestination: SecurePasteDestination?
    private var securePasteTask: Task<Void, Never>?
    /// AppKit marks a launch performed on behalf of a Service as non-default.
    /// Consume that fact in the first routed launch action so Command-Backslash
    /// can stay a background picker without changing later Service requests.
    private var initialNonDefaultLaunchActionPending = false
    /// A cold Secure Paste Service launch can also deliver a normal reopen event.
    /// Keep that event from resurrecting the storyboard window behind the picker.
    private var suppressMainWindowForColdServicePicker = false
    private var postLaunchServicesWorkItem: DispatchWorkItem?
    private var postLaunchServicesStarted = false
    private var shouldTerminateForReal = false
    private var terminationReplyPending = false
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit orders the storyboard's initial window only after launch finishes.
        // Keep it transparent until did-finish tells us whether this is a normal
        // launch or a Service launch; otherwise the Service callback can only hide
        // the window after its first frame has already reached the screen.
        NSApp.windows
            .first(where: { $0.contentViewController is ViewController })?
            .alphaValue = 0

        // This must precede storyboard-driven editor population. If AppKit
        // refuses the protected-content contract, secure metadata remains
        // usable but the editor will refuse to decrypt and reveal the body.
        // Do not log the body (or include it in an error) on this path.
        secureContentAccessibilityProtection.registerApplication()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `swift test` runs unsigned, so it can only ever exercise the login-keychain
        // tier. The data-protection tier — the one that carries the vault key to other
        // Macs through iCloud Keychain — needs the app's real entitlements, which means
        // it can only be exercised from inside the signed app. This is that hook.
        if CommandLine.arguments.contains("--keychain-selftest") {
            KeychainSelfCheck.run()
            NSApp.terminate(nil)
            return
        }
        #endif

        // This documented launch flag is false for Service launches (and other
        // explicitly routed launches). The matching Service/deep-link callback
        // below consumes it once, so it cannot affect a later shortcut.
        let isDefaultLaunch =
            notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        initialNonDefaultLaunchActionPending = !isDefaultLaunch

        // Consulted only when the usage file hits its record cap, so that a
        // forced eviction drops UUIDs of deleted snippets before live ones.
        usageStore.liveSnippetIDs = { [weak store] in
            Set((store?.snippets ?? []).map(\.id))
        }
        usageStore.snippetDisplayName = { [weak store] id in
            store?.snippet(id: id)?.displayName
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(flushUsageData),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(flushUsageDataBeforeSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        // The plaintext store shows secure records in the list, counts their tags, and
        // enforces keyword uniqueness against them — but can never reach their content.
        store.secureProvider = secureStore
        secureStore.onChange = { [weak self] in
            guard let self else { return }
            // A vault change alters the merged display list, so the same channel a
            // library change uses has to fire, or the list silently goes stale.
            self.store.onChange?(.init(source: .external))
            // Sync does not need the vault to run, but creating or adopting one changes
            // what there is to sync. Without this, records that appeared in the vault a
            // moment ago would wait for a later scheduler wake.
            self.syncCoordinator.libraryStructureChanged()
        }

        // Finish any secure-snippet move that a crash interrupted. Runs before the
        // expansion engine starts, so the keyword matcher never sees the duplicate a
        // half-finished promote leaves behind.
        secureStore.reconcileInterruptedMove()

        // A storyboard can load ViewController (and therefore its initial list) before
        // applicationDidFinishLaunching attaches the secure provider above. Reconcile
        // is intentionally silent when there is no interrupted move, so publish the
        // completed attachment explicitly; otherwise existing secure shells remain
        // invisible until some unrelated library change forces another reload.
        store.onChange?(.init(source: .external))

        if launchedAsLoginItem {
            initialNonDefaultLaunchActionPending = false
            hideToBackground()
        } else if isDefaultLaunch {
            showMainWindow()
        }
        schedulePostLaunchServices()

        // A Service request can arrive immediately after its provider is set,
        // including before this method returns. Register once the stores are fully
        // attached and background startup is scheduled so a cold Command-Backslash
        // launch can suppress the storyboard window before its first routed event.
        NSApp.servicesProvider = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            // Non-default also covers restored-state and file launches. A pending
            // Service is delivered as soon as the provider above is registered;
            // expire the candidate afterward so an unrelated later Service cannot
            // be mistaken for the launch request.
            self?.initialNonDefaultLaunchActionPending = false
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Diagnostics.record(.lifecycle(.becameActive))
        guard postLaunchServicesStarted else { return }
        _ = syncCoordinator.syncNow(trigger: .becameActive)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.record(.lifecycle(.willTerminate))
        // First: give the user's clipboard back before writing anything of our own. A snippet
        // borrowed for a paste would otherwise outlive the process.
        // Before anything else: remove the socket, so a CLI invocation racing our exit
        // gets "not running" rather than a connection that dies mid-request.
        // Before the library flush: a queued secure edit exists only in the editor, and
        // the process is about to end.
        (NSApp.windows.compactMap { $0.contentViewController as? ViewController }.first)?
            .flushPendingSecureEdit()
        postLaunchServicesWorkItem?.cancel()
        postLaunchServicesWorkItem = nil
        if postLaunchServicesStarted {
            controlServer.stop()
            _ = expansionEngine.prepareForTermination()
        }
        // Synchronous on purpose: this method returns and the process dies long
        // before an async write would run, so an async flush here writes nothing.
        usageStore.flush(synchronously: true)
        store.flushPendingWrites()
        Diagnostics.flush()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Work that does not contribute pixels to the main window starts just after the
    /// first frame. The small bound keeps the status item, hotkeys, CLI socket, sync and
    /// updater effectively immediate to a person while removing their keychain, event
    /// tap, LaunchServices and window-server setup from AppKit's launch transaction.
    private func schedulePostLaunchServices() {
        let item = DispatchWorkItem { [weak self] in
            self?.startPostLaunchServices()
        }
        postLaunchServicesWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func startPostLaunchServices() {
        guard !postLaunchServicesStarted else { return }
        postLaunchServicesWorkItem = nil
        postLaunchServicesStarted = true

        // Plaintext edits and external writers such as `snippets-cli` share one trailing
        // outbound-sync debounce. No editing is possible before the first frame.
        store.syncDelegate = syncCoordinator
        controlServer.start()
        syncCoordinator.startIfEnabled()
        expansionEngine.startIfNeeded()
        configureAppMenuItems()
        configureFileMenuItems()
        #if DEBUG && !NO_SPARKLE
        configureDebugMenu()
        #endif
        setupStatusItem()
        setupGlobalHotkey()
        setupServicesProvider()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChromiumBundleIDsChanged),
            name: .snippetsChromiumBundleIDsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGlobalHotkeyChanged),
            name: .snippetsGlobalHotkeyChanged,
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
        let updater = ensureUpdaterController()
        updater.updater.automaticallyDownloadsUpdates = true
        #if !DEBUG
        updater.updater.checkForUpdatesInBackground()
        #endif
        #endif
    }

    /// Expanding a snippet means some other app is frontmost, so resigning
    /// active catches nearly every pending write without waiting out the
    /// debounce.
    @objc private func flushUsageData() {
        usageStore.flush()
    }

    @objc private func flushUsageDataBeforeSleep() {
        // Sleeping with a borrowed clipboard would hold it for hours instead of milliseconds.
        Diagnostics.record(.lifecycle(.willSleep))
        expansionEngine.releaseBorrowedPasteboard()
        usageStore.flush(synchronously: true)
        Diagnostics.flush()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Note: Sparkle's `sessionInProgress` is intentionally NOT consulted here.
        // It is true during background appcast checks and automatic downloads, not
        // just when Sparkle relaunches to install. The legit install relaunch is
        // covered by `shouldTerminateForReal`, set before invoking the install handler.
        if shouldTerminateForReal || systemIsTerminating {
            return terminationReplyAfterRestoringClipboard(sender)
        }

        switch quitBehaviorPreference {
        case .hide:
            hideToBackground()
            return .terminateCancel
        case .quit:
            return terminationReplyAfterRestoringClipboard(sender)
        case .ask:
            switch promptForQuitDecision() {
            case .hide:
                hideToBackground()
                return .terminateCancel
            case .quit:
                return terminationReplyAfterRestoringClipboard(sender)
            case .cancel:
                return .terminateCancel
            }
        }
    }

    /// A retained recovery lease may be the only remaining copy of the user's pre-expansion
    /// clipboard. Keep the app's run loop alive for its bounded retries; if they still cannot write,
    /// cancel Quit instead of destroying that snapshot with the process.
    private func terminationReplyAfterRestoringClipboard(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        // A LocalAuthentication request may outlive the panel that started it. Cancellation
        // makes the engine wipe any returned lease before termination is allowed to continue.
        securePasteTask?.cancel()
        if securePasteDestination != nil {
            expansionEngine.dismissSecurePastePicker()
        }
        securePasteDestination = nil
        statusMenuSecurePasteDestination = nil

        let ready = expansionEngine.prepareForTermination { [weak self] canTerminate in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            self.terminationReplyPending = false
            if !canTerminate {
                self.expansionEngine.cancelTerminationPreparation()
            }
            sender.reply(toApplicationShouldTerminate: canTerminate)
        }
        guard !ready else {
            terminationReplyPending = false
            return .terminateNow
        }

        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if initialNonDefaultLaunchActionPending || suppressMainWindowForColdServicePicker {
            return false
        }
        if !flag {
            showMainWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        initialNonDefaultLaunchActionPending = false
        let deepLinks = urls.filter { SnippetDeepLink.canHandle($0) }
        guard !deepLinks.isEmpty else { return }

        for url in deepLinks {
            handleSnippetDeepLink(url)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // Routed through `showMainWindow()` rather than a notification because
    // `applicationShouldTerminateAfterLastWindowClosed` is false: with the window closed there is
    // no ViewController listening, so ⌘N used to do nothing at all.
    @IBAction func newDocument(_ sender: Any?) {
        showMainWindow()?.createSnippet(sender)
    }

    @IBAction func newSnippetFromClipboard(_ sender: Any?) {
        showMainWindow()?.createSnippetFromClipboard(sender)
    }

    /// The Help item used to call `showHelp:`, and this bundle has no
    /// `CFBundleHelpBookName` and ships no help book, so the only thing it could
    /// ever produce was the system "Help isn't available" alert. The ⌘K panel is
    /// where this app's shortcuts are actually written down.
    @IBAction func showSnippetsHelp(_ sender: Any?) {
        showMainWindow()
        NotificationCenter.default.post(name: .snippetsToggleActions, object: nil)
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
            Diagnostics.record(.storageFailure(
                area: .launchAtLogin,
                operation: .register,
                failure: DiagnosticFailure(error),
                attempt: nil))
        }
    }

    @IBAction func openSettings(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        let controller = settingsWindowController ?? SettingsWindowController()
        settingsWindowController = controller
        controller.showSettings()
        #if !NO_SPARKLE
        refreshWindowUpdateAccessories()
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func importSnippets(_ sender: Any?) {
        showMainWindow()?.runImport(sender)
    }

    @IBAction func exportSnippets(_ sender: Any?) {
        showMainWindow()?.runExport(sender)
    }

    @IBAction func exportEncryptedBackup(_ sender: Any?) {
        showMainWindow()?.runEncryptedBackupExport(sender)
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
        if menuItem.action == #selector(newSnippetFromClipboard(_:)) {
            // Only the status-bar copy, whose entire title is a clipboard
            // preview: with nothing to preview it has nothing to offer. The File
            // item stays enabled so ⇧⌘N can say why nothing happened rather than
            // going silently dead.
            return menuItem !== statusMenuClipboardItem || ClipboardCapture.text != nil
        }
        if menuItem.action == #selector(resetQuitBehaviorPreference(_:)) {
            let hasRemembered = hasRememberedQuitBehavior
            menuItem.isHidden = !hasRemembered
            return hasRemembered
        }
        #if !NO_SPARKLE
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return ensureUpdaterController().updater.canCheckForUpdates
                && !isApplyingPendingUpdate
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

    // MARK: - Services

    private func setupServicesProvider() {
        NSApp.servicesProvider = self
        removeObsoleteServiceShortcuts()
        syncOpenServiceShortcut()
        // The Services cache is keyed off the bundle's own NSServices, and a
        // build that has never lived in /Applications is not scanned on its own.
        // This is what gives the entry a chance to appear without a login cycle.
        NSUpdateDynamicServices()
    }

    /// Build 87 tried to bind Services through global menu-item preferences.
    /// Those entries do not become shortcuts in an already-running frontmost
    /// application, so remove only the exact values Snippets wrote.
    private func removeObsoleteServiceShortcuts() {
        let preference = "NSUserKeyEquivalents" as CFString
        let application = kCFPreferencesAnyApplication
        let user = kCFPreferencesCurrentUser
        let host = kCFPreferencesAnyHost

        var keyEquivalents = CFPreferencesCopyValue(preference, application, user, host)
            as? [String: Any] ?? [:]
        let obsoleteShortcuts = [
            "Open Snippets App": "@\\",
            "Secure Paste with Snippets…": "~\\",
        ]

        var changed = false
        for (title, keyEquivalent) in obsoleteShortcuts
        where keyEquivalents[title] as? String == keyEquivalent {
            keyEquivalents.removeValue(forKey: title)
            changed = true
        }

        if changed {
            CFPreferencesSetValue(
                preference,
                keyEquivalents as CFDictionary,
                application,
                user,
                host
            )
            _ = CFPreferencesSynchronize(application, user, host)
        }
        removeLegacySecurePasteServiceShortcut()
    }

    /// Build 86 wrote an Option shortcut into the private `pbs` domain. Remove
    /// only that exact app-owned entry; all other Services preferences stay put.
    private func removeLegacySecurePasteServiceShortcut() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let preferencesDomain = "pbs" as CFString
        let statusesPreference = "NSServicesStatus" as CFString
        let serviceIdentifier = "\(bundleIdentifier) - Secure Paste… - securePasteFromService"

        var statuses = CFPreferencesCopyAppValue(statusesPreference, preferencesDomain)
            as? [String: Any] ?? [:]
        guard statuses.removeValue(forKey: serviceIdentifier) != nil else { return }
        CFPreferencesSetAppValue(statusesPreference, statuses as CFDictionary, preferencesDomain)
        _ = CFPreferencesAppSynchronize(preferencesDomain)
    }

    /// `NSServices.NSKeyEquivalent` can encode Command and Shift, but not Option.
    /// Store the open action where System Settings keeps user-assigned Services
    /// shortcuts so Command-Option-Backslash can also launch a stopped app.
    private func syncOpenServiceShortcut() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let preferencesDomain = "pbs" as CFString
        let statusesPreference = "NSServicesStatus" as CFString
        let serviceIdentifier = "\(bundleIdentifier) - Open Snippets - openSnippetsFromService"
        let keyEquivalent = "@~\\"

        var statuses = CFPreferencesCopyAppValue(statusesPreference, preferencesDomain)
            as? [String: Any] ?? [:]
        var serviceStatus = statuses[serviceIdentifier] as? [String: Any] ?? [:]

        if GlobalHotkeyManager.shared.isEnabled {
            guard serviceStatus["key_equivalent"] as? String != keyEquivalent else { return }
            serviceStatus["key_equivalent"] = keyEquivalent
            statuses[serviceIdentifier] = serviceStatus
            CFPreferencesSetAppValue(
                "ServicesShortcutsPresent" as CFString,
                kCFBooleanTrue,
                preferencesDomain
            )
        } else {
            guard serviceStatus["key_equivalent"] as? String == keyEquivalent else { return }
            serviceStatus.removeValue(forKey: "key_equivalent")
            if serviceStatus.isEmpty {
                statuses.removeValue(forKey: serviceIdentifier)
            } else {
                statuses[serviceIdentifier] = serviceStatus
            }
        }

        CFPreferencesSetAppValue(statusesPreference, statuses as CFDictionary, preferencesDomain)
        _ = CFPreferencesAppSynchronize(preferencesDomain)
    }

    /// Declared in every Info plist as `NSMessage = makeSnippetFromSelection`.
    /// The selection arrives as content and not as a name: it is the text the
    /// snippet has to expand to, and naming a snippet after its own body is what
    /// `displayName`'s first-line fallback already does for free.
    @objc func makeSnippetFromSelection(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        initialNonDefaultLaunchActionPending = false
        guard let selection = pboard.string(forType: .string),
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "Select some text to make a snippet from it." as NSString
            return
        }

        showMainWindow()?.createSnippet(seededContent: selection, seededName: nil)
    }

    /// Command-Option-Backslash normally arrives through Carbon. The frontmost
    /// application's matching Services item preserves the same action when
    /// Secure Event Input prevents cross-process keyboard delivery.
    @objc func openSnippetsFromService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        initialNonDefaultLaunchActionPending = false
        guard GlobalHotkeyManager.shared.isEnabled else { return }
        // Let the source application finish its synchronous Services command
        // before Snippets activates and makes its main window key.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.openFromGlobalHotkey()
        }
    }

    /// Command-Backslash normally arrives through Carbon. The frontmost
    /// application's matching Services item preserves Secure Paste when Secure
    /// Event Input prevents cross-process keyboard delivery.
    @objc func securePasteFromService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let isColdServiceLaunch = initialNonDefaultLaunchActionPending
        initialNonDefaultLaunchActionPending = false
        guard GlobalHotkeyManager.shared.isEnabled else { return }
        if expansionEngine.securePastePickerIsVisible {
            expansionEngine.cancelSecurePastePicker(returnFocus: true)
            return
        }
        guard securePasteTask == nil else {
            error.pointee = "Secure Paste is already in progress." as NSString
            return
        }
        guard let destination = captureSecurePasteDestination() else {
            error.pointee = expansionEngine.accessibilityGranted
                ? "Secure Paste is unavailable right now." as NSString
                : "Secure Paste needs Accessibility access." as NSString
            if !expansionEngine.accessibilityGranted {
                expansionEngine.requestAccessibilityPermission()
            }
            return
        }

        if isColdServiceLaunch {
            prepareForColdServicePicker()
        }

        // A Services key equivalent is dispatched synchronously by the source
        // app. Giving Safari one run-loop turn was not sufficient: after our
        // panel became key, Safari finished the service command, reclaimed key
        // status, and `windowDidResignKey` immediately dismissed the picker.
        // Capture the destination above, then wait for that hand-off to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if isColdServiceLaunch {
                // Window restoration and the open-application event may finish
                // after the Service callback. Reassert the background state at
                // the same boundary where the picker is presented.
                guard self.suppressMainWindowForColdServicePicker else { return }
                self.prepareForColdServicePicker()
            }
            self.beginSecurePaste(for: destination)
        }
    }

    // MARK: - Status Bar Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Fall back through known-good symbols; never leave the button blank,
            // since this is the only re-entry point after hiding to the menu bar.
            let symbolCandidates = ["text.cursor", "character.cursor.ibeam"]
            let image = symbolCandidates.lazy
                .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Snippets") }
                .first
            if let image {
                button.image = image
            } else {
                button.title = "S"
            }
            button.toolTip = "Snippets"
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Snippets", action: #selector(openFromStatusBar), keyEquivalent: "")
        openItem.target = self
        LiquidGlassDesign.applyMenuSymbol("macwindow", to: openItem)
        // `setupGlobalHotkey()` runs next and fills in the ⌥⌘\ hint.
        statusMenuOpenItem = openItem
        let securePasteItem = NSMenuItem(
            title: "Secure Paste…",
            action: #selector(securePasteFromStatusBar(_:)),
            keyEquivalent: ""
        )
        securePasteItem.target = self
        LiquidGlassDesign.applyMenuSymbol("lock.open", to: securePasteItem)
        statusMenuSecurePasteItem = securePasteItem
        let clipboardItem = NSMenuItem(
            title: "",
            action: #selector(newSnippetFromClipboard(_:)),
            keyEquivalent: ""
        )
        clipboardItem.target = self
        LiquidGlassDesign.applyMenuSymbol("doc.on.clipboard", to: clipboardItem)
        // `menuWillOpen` fills the title in: it carries a preview of what the
        // clipboard holds right now, which is only knowable at open time.
        statusMenuClipboardItem = clipboardItem
        let resetQuitBehaviorItem = NSMenuItem(
            title: "Reset Remembered Cmd+Q Choice",
            action: #selector(resetQuitBehaviorPreference(_:)),
            keyEquivalent: ""
        )
        resetQuitBehaviorItem.target = self
        LiquidGlassDesign.applyMenuSymbol("arrow.uturn.backward", to: resetQuitBehaviorItem)
        let quitItem = NSMenuItem(title: "Quit Snippets", action: #selector(quitCompletely(_:)), keyEquivalent: "")
        quitItem.target = self
        LiquidGlassDesign.applyMenuSymbol("power", to: quitItem)

        menu.delegate = self
        menu.addItem(openItem)
        menu.addItem(securePasteItem)
        menu.addItem(clipboardItem)
        menu.addItem(.separator())
        menu.addItem(resetQuitBehaviorItem)
        menu.addItem(quitItem)
        refreshStatusMenuClipboardItem()
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        // Secure Event Input can suppress every keyboard observer, including a
        // registered global hotkey. Mouse tracking still works, so capture the
        // destination before this menu becomes the only reliable entry point.
        if securePasteTask == nil,
           securePasteDestination == nil,
           NSWorkspace.shared.frontmostApplication?.processIdentifier
                != ProcessInfo.processInfo.processIdentifier {
            statusMenuSecurePasteDestination = captureSecurePasteDestination()
        } else {
            statusMenuSecurePasteDestination = nil
        }
        refreshStatusMenuClipboardItem()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        // Menu actions are delivered before this deferred cleanup. A dismissed
        // menu must not retain an AX target until its next opening.
        DispatchQueue.main.async { [weak self] in
            self?.statusMenuSecurePasteDestination = nil
        }
    }

    /// The point of the item is that you can see what it would save before you
    /// pick it — the menu bar is the one surface reachable while the text you
    /// just copied is still on screen in another app.
    private func refreshStatusMenuClipboardItem() {
        guard let clipboardItem = statusMenuClipboardItem else { return }

        guard let preview = ClipboardCapture.text.map(ClipboardCapture.menuPreview(of:)), !preview.isEmpty else {
            clipboardItem.title = "New from Clipboard"
            return
        }

        clipboardItem.title = "New from Clipboard — “\(preview)”"
    }

    // MARK: - Global Shortcut

    private func setupGlobalHotkey() {
        let manager = GlobalHotkeyManager.shared
        manager.onTrigger = { [weak self] in
            self?.toggleFromGlobalHotkey()
        }
        manager.onSecurePasteTrigger = { [weak self] in
            self?.toggleSecurePasteFromGlobalHotkey()
        }
        manager.syncRegistration()
        refreshGlobalHotkeyMenuHint()
    }

    private func captureSecurePasteDestination() -> SecurePasteDestination? {
        switch expansionEngine.captureSecurePasteTarget() {
        case .target(let target):
            return .textField(target)
        case .noTextField:
            return .clipboard
        case .accessibilityRequired, .unavailable:
            return nil
        }
    }

    private func toggleSecurePasteFromGlobalHotkey() {
        if expansionEngine.securePastePickerIsVisible {
            expansionEngine.cancelSecurePastePicker(returnFocus: true)
            return
        }
        guard securePasteTask == nil else {
            NSSound.beep()
            return
        }
        guard let destination = captureSecurePasteDestination() else {
            NSSound.beep()
            if !expansionEngine.accessibilityGranted {
                expansionEngine.requestAccessibilityPermission()
                openFromGlobalHotkey()
            }
            return
        }

        beginSecurePaste(for: destination)
    }

    @objc private func securePasteFromStatusBar(_ sender: Any?) {
        if expansionEngine.securePastePickerIsVisible {
            expansionEngine.cancelSecurePastePicker(returnFocus: true)
            return
        }
        guard securePasteTask == nil else {
            NSSound.beep()
            return
        }

        let destination = statusMenuSecurePasteDestination ?? captureSecurePasteDestination()
        statusMenuSecurePasteDestination = nil
        guard let destination else {
            NSSound.beep()
            if !expansionEngine.accessibilityGranted {
                expansionEngine.requestAccessibilityPermission()
                openFromGlobalHotkey()
            }
            return
        }

        // Let menu tracking release its temporary key window before asking the
        // non-activating suggestion panel to become key for search input.
        DispatchQueue.main.async { [weak self] in
            self?.beginSecurePaste(for: destination)
        }
    }

    private func beginSecurePaste(for destination: SecurePasteDestination) {
        securePasteDestination = destination
        let didShow = expansionEngine.showSecurePastePicker(
            for: destination.textFieldTarget,
            onSelect: { [weak self] snippet in
                self?.securePasteSnippetSelected(snippet)
            },
            onCancel: { [weak self] shouldReturnFocus in
                self?.securePasteCancelled(shouldReturnFocus: shouldReturnFocus)
            }
        )
        guard didShow else {
            securePasteDestination = nil
            suppressMainWindowForColdServicePicker = false
            NSSound.beep()
            return
        }
    }

    private func securePasteSnippetSelected(_ snippet: Snippet) {
        suppressMainWindowForColdServicePicker = false
        guard let destination = securePasteDestination else { return }
        securePasteDestination = nil

        switch destination {
        case .textField(let target):
            securePasteTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let inserted = await self.expansionEngine.pasteSnippetUsingSecurePaste(
                    snippet,
                    to: target
                )
                if !inserted, !Task.isCancelled {
                    await self.expansionEngine.returnFocusAfterCancellingSecurePaste(target)
                    NSSound.beep()
                }
                self.securePasteTask = nil
            }
        case .clipboard:
            switch expansionEngine.copySnippetToClipboard(snippet) {
            case .copied:
                transientScreenMessageController.show(
                    ClipboardCopyFeedback.copied(snippet),
                    kind: .confirmation
                )
            case .secureSnippetBlocked:
                NSSound.beep()
                transientScreenMessageController.show(
                    ClipboardCopyFeedback.secureSnippetBlocked,
                    kind: .failure
                )
            case .failed:
                NSSound.beep()
                transientScreenMessageController.show(
                    ClipboardCopyFeedback.failed,
                    kind: .failure
                )
            }
        }
    }

    private func securePasteCancelled(shouldReturnFocus: Bool) {
        suppressMainWindowForColdServicePicker = false
        guard let destination = securePasteDestination else { return }
        securePasteDestination = nil
        guard shouldReturnFocus,
              case .textField(let target) = destination else { return }

        securePasteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.expansionEngine.returnFocusAfterCancellingSecurePaste(target)
            self.securePasteTask = nil
        }
    }

    private func toggleFromGlobalHotkey() {
        if securePasteDestination != nil {
            expansionEngine.cancelSecurePastePicker(returnFocus: true)
            return
        }
        if isShowingMainWindow {
            hideFromGlobalHotkey()
        } else {
            openFromGlobalHotkey()
        }
    }

    /// Frontmost with the snippet list actually on screen. A miniaturized or
    /// ordered-out window reads as hidden, so the shortcut reopens it instead
    /// of hiding an app the user cannot see.
    private var isShowingMainWindow: Bool {
        guard NSApp.isActive else { return false }
        return NSApp.windows.contains { $0.contentViewController is ViewController && $0.isVisible }
    }

    private func openFromGlobalHotkey() {
        suppressMainWindowForColdServicePicker = false
        // Coming from the menu bar means the Dock icon is being added just for
        // this visit; remember that so hiding can put it back the way it was.
        hotkeyPromotedFromAccessory = NSApp.activationPolicy() == .accessory
        // The shortcut is the way back in from anywhere, so it also has to
        // recover from Cmd+H — `showMainWindow()` alone leaves a hidden app
        // hidden.
        NSApp.unhide(nil)
        showMainWindow()
    }

    private func hideFromGlobalHotkey() {
        if hotkeyPromotedFromAccessory {
            hotkeyPromotedFromAccessory = false
            hideToBackground()
        } else {
            NSApp.hide(nil)
        }
    }

    @objc private func handleGlobalHotkeyChanged() {
        syncOpenServiceShortcut()
        refreshGlobalHotkeyMenuHint()
    }

    /// The menu bar is the only always-visible surface for the shortcuts, so it
    /// advertises each combination only while its Carbon registration is live.
    private func refreshGlobalHotkeyMenuHint() {
        let manager = GlobalHotkeyManager.shared
        let showsOpenShortcut = manager.isEnabled && manager.isActive
        statusMenuOpenItem?.keyEquivalent = showsOpenShortcut ? "\\" : ""
        statusMenuOpenItem?.keyEquivalentModifierMask = showsOpenShortcut
            ? [.command, .option]
            : []

        let showsSecurePasteShortcut = manager.isEnabled && manager.isSecurePasteActive
        statusMenuSecurePasteItem?.keyEquivalent = showsSecurePasteShortcut ? "\\" : ""
        statusMenuSecurePasteItem?.keyEquivalentModifierMask = showsSecurePasteShortcut
            ? [.command]
            : []
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

    private func configureFileMenuItems() {
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else { return }
        if fileMenu.items.contains(where: { $0.action == #selector(importSnippets(_:)) })
            || fileMenu.items.contains(where: { $0.action == #selector(exportSnippets(_:)) })
            || fileMenu.items.contains(where: { $0.action == #selector(exportEncryptedBackup(_:)) }) {
            return
        }

        let importItem = NSMenuItem(
            title: "Import Snippets…",
            action: #selector(importSnippets(_:)),
            keyEquivalent: "I"
        )
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.target = self
        LiquidGlassDesign.applyMenuSymbol("square.and.arrow.down", to: importItem)

        let exportItem = NSMenuItem(
            title: "Export for Sharing…",
            action: #selector(exportSnippets(_:)),
            keyEquivalent: "E"
        )
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.target = self
        LiquidGlassDesign.applyMenuSymbol("square.and.arrow.up", to: exportItem)

        let backupItem = NSMenuItem(
            title: "Export Encrypted Backup…",
            action: #selector(exportEncryptedBackup(_:)),
            keyEquivalent: ""
        )
        backupItem.target = self
        LiquidGlassDesign.applyMenuSymbol("lock.doc", to: backupItem)

        // Anchored on Close, and carrying its own separators. This used to point
        // at the first separator in the menu, and when the dead document commands
        // went so did both separators — the `?? count` fallback then appended
        // Import and Export below Close, five items in one undifferentiated
        // block. Close is an item this menu means to have; a separator is only
        // ever a consequence of the items around it.
        let closeIndex = fileMenu.items.firstIndex { $0.action == #selector(NSWindow.performClose(_:)) }
        let insertionIndex = closeIndex ?? fileMenu.items.count
        if closeIndex != nil {
            fileMenu.insertItem(.separator(), at: insertionIndex)
        }
        fileMenu.insertItem(backupItem, at: insertionIndex)
        fileMenu.insertItem(exportItem, at: insertionIndex)
        fileMenu.insertItem(importItem, at: insertionIndex)
        if insertionIndex > 0 {
            fileMenu.insertItem(.separator(), at: insertionIndex)
        }
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
        ensureUpdaterController().updater.checkForUpdatesInBackground()
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
        if securePasteDestination != nil {
            expansionEngine.cancelSecurePastePicker(returnFocus: true)
        }
        for window in NSApp.windows {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// A Service-launched process starts with the regular activation policy and
    /// AppKit may restore its storyboard window even though Command-Backslash is
    /// an overlay-only action. Move the process to the same menu-bar background
    /// state used by login launch before the non-activating picker is shown.
    private func prepareForColdServicePicker() {
        suppressMainWindowForColdServicePicker = true
        for window in NSApp.windows {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
        // Let SuggestionPanelController use its hidden-application presentation:
        // the picker is exempted from hiding while every ordinary app window stays out.
        NSApp.hide(nil)
    }

    @discardableResult
    private func showMainWindow() -> ViewController? {
        suppressMainWindowForColdServicePicker = false
        NSApp.setActivationPolicy(.regular)

        let window: NSWindow?
        if let window = NSApp.windows.first(where: { $0.contentViewController is ViewController }) {
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            #if !NO_SPARKLE
            refreshWindowUpdateAccessories()
            #endif
            NSApp.activate(ignoringOtherApps: true)
            return window.contentViewController as? ViewController
        } else {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)
            if let wc = storyboard.instantiateInitialController() as? NSWindowController {
                wc.window?.alphaValue = 1
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

            if SnippetDeepLink.isCreationLink(url) {
                createSnippetFromDeepLink(snippet, in: viewController)
                return
            }

            guard confirmImportOfSharedSnippet(snippet) else { return }

            let importedSnippet = try store.importSharedSnippet(snippet)
            if let viewController {
                clearActiveSearch(in: viewController)
                viewController.selectSnippet(id: importedSnippet.id, focus: nil)
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

    /// `snippets://new` adds a snippet. It never replaces one.
    ///
    /// The share host merges on keyword equality and rewrites the whole row it
    /// lands on, which is right for a link this app wrote — that one carries a
    /// complete record — and wrong for a link anybody can put on a web page,
    /// where every field the URL omits arrives empty. Routed through that merge,
    /// `?keyword=sig&content=…` took the name, the tags and the pin off whatever
    /// snippet already answered to `\sig`, and switched it back on if the user
    /// had deliberately switched it off. A host called "new" creates.
    private func createSnippetFromDeepLink(_ snippet: Snippet, in viewController: ViewController?) {
        guard confirmCreationOfLinkedSnippet(snippet) else { return }

        // Before `addSnippet`, which tracks one blank draft at a time: an
        // untouched ⌘N row still open here would lose its tracking and stay in
        // the library forever. This is what `createSnippet` does with a seed.
        if let draft = store.blankDraftSnippet {
            store.discardBlankDraft(id: draft.id)
        }

        var created = store.addSnippet(name: snippet.name, content: snippet.content, tags: snippet.tags)
        if !snippet.normalizedKeyword.isEmpty {
            created.keyword = snippet.normalizedKeyword
            // The keyword arrives in a second call because `addSnippet` does not
            // take one, and `update` writes on the editor's typing debounce —
            // which is wrong for a discrete action. Every other one is on disk
            // before it returns, and so is this.
            store.update(created)
            store.flushPendingWrites()
        }

        guard let viewController else { return }
        clearActiveSearch(in: viewController)
        // Reloaded again even when there was no search to clear: `store.onChange`
        // defers the list reload while the editor has focus, and the new row has
        // to be in the table before the selection below can land on it.
        viewController.reloadVisibleSnippets(keepSelection: true)
        // The keyword lands focused because it is the field a hand-written link
        // most often leaves out or collides with, and the status line under it is
        // the one place that says whether this snippet will ever fire.
        viewController.selectSnippet(id: created.id, focus: .keyword)
        viewController.importExportMessage = "Created \(created.displayName) from a link."
    }

    /// A link that adds is still a link any web page can navigate to, and the
    /// engine has no terminator, so a short enabled keyword arriving unannounced
    /// fires by accident. The modal stays for the creation host too.
    private func confirmCreationOfLinkedSnippet(_ snippet: Snippet) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Create Snippet From Link?"

        if let notice = linkedSnippetKeywordNotice(snippet) {
            alert.informativeText = """
            \(sharedSnippetSummary(snippet))

            \(notice.text)
            """
            alert.alertStyle = notice.isFailure ? .warning : .informational
        } else {
            alert.informativeText = sharedSnippetSummary(snippet)
            alert.alertStyle = .informational
        }

        alert.addButton(withTitle: "Create Snippet")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What this keyword will do to the library, decided with the `KeywordRelation`
    /// the editor's status line and the keyword chips already share, so the alert
    /// cannot promise something the line under the field then contradicts.
    ///
    /// A colliding keyword is a legal state and nothing here resolves it — silently
    /// dropping or renaming it would be its own trap. It is said out loud instead,
    /// and the snippet opens with the keyword field focused.
    private func linkedSnippetKeywordNotice(_ snippet: Snippet) -> (text: String, isFailure: Bool)? {
        let incomingKey = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
        guard !incomingKey.isEmpty else {
            return ("This link carries no keyword, so the new snippet will not expand until you give it one.", false)
        }

        let trigger = "\\\(snippet.normalizedKeyword)"
        var duplicate: Snippet?
        var blockedBy: Snippet?
        var blocks: Snippet?
        for other in store.enabledSnippetsSorted() {
            switch KeywordRelation.between(incomingKey, SnippetTagging.filterKey(for: other.normalizedKeyword)) {
            case .duplicate:
                duplicate = duplicate ?? other
            case .blockedByLonger:
                blockedBy = blockedBy ?? other
            case .blocksShorter:
                blocks = blocks ?? other
            case .unrelated:
                break
            }
        }

        if let duplicate {
            return (
                "\(trigger) is already used by \(duplicate.displayName) — create this and neither will expand. \(duplicate.displayName) is kept as it is; nothing is replaced.",
                true
            )
        }
        if let blockedBy {
            return (
                "\(trigger) won't auto-expand — \(blockedBy.displayName) uses the longer \\\(blockedBy.normalizedKeyword).",
                true
            )
        }
        if let blocks {
            return ("This will stop \(blocks.displayName) (\\\(blocks.normalizedKeyword)) from auto-expanding.", true)
        }
        return nil
    }

    /// A snippet arriving from a link lands outside whatever the list is
    /// filtered to, so the filter goes rather than the new row being invisible.
    private func clearActiveSearch(in viewController: ViewController) {
        let hasActiveSearch = !viewController.searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard hasActiveSearch else { return }

        viewController.searchField.stringValue = ""
        viewController.reloadVisibleSnippets(keepSelection: true)
    }

    private func confirmImportOfSharedSnippet(_ snippet: Snippet) -> Bool {
        let alert = NSAlert()

        if let replaced = existingSnippetReplacedByImport(of: snippet) {
            // The store's import merge keys on keyword equality: importing a shared
            // snippet whose keyword matches an existing one silently overwrites it.
            // Make that explicit so a crafted share link can't swap trusted expansion
            // content behind a benign-looking import dialog.
            alert.messageText = "Replace Existing Snippet?"
            alert.informativeText = """
            Warning: You already have a snippet named "\(replaced.displayName)" with the keyword \\\(replaced.normalizedKeyword). Importing this shared snippet will REPLACE it, permanently overwriting its current content.

            \(sharedSnippetSummary(snippet))
            """
            alert.alertStyle = .warning
            let replaceButton = alert.addButton(withTitle: "Replace \"\(replaced.displayName)\"")
            replaceButton.hasDestructiveAction = true
        } else {
            alert.messageText = "Import Shared Snippet?"
            alert.informativeText = sharedSnippetSummary(snippet)
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Import")
        }

        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Existing snippet that the store's keyword-keyed import merge would replace.
    private func existingSnippetReplacedByImport(of snippet: Snippet) -> Snippet? {
        let incomingKeyword = snippet.normalizedKeyword
        guard !incomingKeyword.isEmpty else { return nil }

        let incomingKey = SnippetTagging.filterKey(for: incomingKeyword)
        return store.snippets.first { existing in
            let existingKeyword = existing.normalizedKeyword
            return !existingKeyword.isEmpty && SnippetTagging.filterKey(for: existingKeyword) == incomingKey
        }
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
    private func ensureUpdaterController() -> SPUStandardUpdaterController {
        if let updaterController { return updaterController }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        return controller
    }

    private func refreshAppMenuUpdateState() {
        appMenuCheckForUpdatesItem?.isEnabled =
            (updaterController?.updater.canCheckForUpdates ?? false)
            && !isApplyingPendingUpdate

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
        let settingsWindow = settingsWindowController?.window
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
    #if DEBUG
    // A Debug build advertises the shipping app's CFBundleVersion from a bundle
    // the shipping deltas can never patch — different executable name, no
    // top-level CodeResources — and Sparkle matches deltas on CFBundleVersion
    // alone. So a background check here can only ever download an update that
    // fails to install. Refuse before the appcast is even fetched.
    // Info-Debug.plist already withholds the feed; this is the backstop that
    // outlives a plist mistake or an INFOPLIST_FILE refactor.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // "Check for Updates…" also routes through `checkForUpdatesInBackground()`,
        // so gate on the flag it sets rather than on the check type alone.
        guard updateCheck == .updatesInBackground, !userInitiatedUpdateCheck else { return }
        throw NSError(
            domain: "com.khm.snippets.debug",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Background update checks are disabled in Debug builds."
            ]
        )
    }
    #endif

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
        // The update session is over; a canceled/failed install must not leave
        // Cmd+Q latched to quit-for-real for the rest of the session.
        shouldTerminateForReal = false
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

        // User canceled the install authorization prompt. Clear the
        // "Applying update and restarting…" status/spinner.
        if nsError.code == 4007 {
            setUpdateStatus("Update installation canceled.", showProgress: false, autoClearAfter: 5)
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
