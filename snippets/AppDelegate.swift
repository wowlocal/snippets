import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SnippetStore()
    lazy var expansionEngine = SnippetExpansionEngine(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        expansionEngine.startIfNeeded()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
