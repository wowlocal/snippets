import Cocoa
import SwiftUI

final class ViewController: NSViewController {
    private lazy var store: SnippetStore = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.store
        }
        return SnippetStore()
    }()

    private lazy var engine: SnippetExpansionEngine = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.expansionEngine
        }
        return SnippetExpansionEngine(store: store)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = SnippetsRootView(store: store, engine: engine)
        view = NSHostingView(rootView: rootView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        view.window?.title = "Snippets"
        view.window?.minSize = NSSize(width: 980, height: 640)
    }
}
