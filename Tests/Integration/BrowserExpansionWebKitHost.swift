// Disposable Safari-engine host for scripts/test-browser-expansion.sh.
import AppKit
import WebKit

@main
@MainActor
private final class WebKitHost: NSObject, NSApplicationDelegate {
    private let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 560, height: 240),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private var titleObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        window.contentView = web
        titleObservation = web.observe(\.title, options: [.new]) { _, change in
            MainActor.assumeIsolated { self.window.title = change.newValue.flatMap { $0 } ?? "Fixture" }
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        NSApp.activate(ignoringOtherApps: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        web.loadFileURL(fixture, allowingReadAccessTo: fixture)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = WebKitHost()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
