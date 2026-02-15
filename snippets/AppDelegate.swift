import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SnippetStore()
    lazy var expansionEngine = SnippetExpansionEngine(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        expansionEngine.startIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushPendingWrites()
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

    private func showMainWindow() {
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
