import Cocoa
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let store = SnippetStore()
    lazy var expansionEngine = SnippetExpansionEngine(store: store)

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
        // "Fake quit": hide windows and switch to background
        hideToBackground()
        return .terminateCancel
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
        menu.addItem(NSMenuItem(title: "Quit Snippets", action: #selector(quitForReal), keyEquivalent: ""))
        statusItem.menu = menu
    }

    @objc private func openFromStatusBar() {
        showMainWindow()
    }

    @objc private func quitForReal() {
        shouldTerminateForReal = true
        NSApp.terminate(nil)
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
