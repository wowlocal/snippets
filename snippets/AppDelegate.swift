import Cocoa
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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

    private let quitBehaviorDefaultsKey = "quitBehaviorPreference"
    private var statusItem: NSStatusItem!
    private var shouldTerminateForReal = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        expansionEngine.startIfNeeded()
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushPendingWrites()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shouldTerminateForReal {
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin(_:)) {
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            return true
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

    @objc private func openFromStatusBar() {
        showMainWindow()
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
        let alert = NSAlert()
        alert.messageText = "What should Cmd+Q do?"
        alert.informativeText = "Hide removes Snippets from the Dock and keeps it running in the menu bar. Quit completely stops Snippets."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Hide (Keep Running)")
        alert.addButton(withTitle: "Quit Completely")
        alert.addButton(withTitle: "Cancel")
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
}
