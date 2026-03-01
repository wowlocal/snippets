import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

private enum MainWindowAutosave {
    static let frameName = NSWindow.FrameAutosaveName("SnippetsMainWindowFrame")
}

@MainActor
final class ViewController: NSViewController {
    lazy var store: SnippetStore = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.store
        }
        return SnippetStore()
    }()

    lazy var engine: SnippetExpansionEngine = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.expansionEngine
        }
        return SnippetExpansionEngine(store: store)
    }()

    var localKeyMonitor: Any?

    var visibleSnippets: [Snippet] = []
    var selectedSnippetID: UUID?
    var isApplyingSnippetToEditor = false

    var importExportMessage: String? {
        didSet {
            importExportMessageLabel.stringValue = importExportMessage ?? ""
        }
    }

    let permissionBannerContainer = NSView()
    let permissionBannerDivider = NSBox()
    let permissionIconView = NSImageView()
    let permissionTitleLabel = NSTextField(labelWithString: "")
    let permissionStatusLabel = NSTextField(labelWithString: "")
    let permissionButtonsStack = NSStackView()

    let searchField = NSSearchField()
    let tableView = NSTableView()
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let importExportMessageLabel = NSTextField(labelWithString: "")

    let nameField = NSTextField(string: "")
    let snippetTextView = NSTextView()
    let keywordField = NSTextField(string: "")
    let keywordPrefixLabel = NSTextField(labelWithString: "\\")
    let keywordWarningLabel = NSTextField(labelWithString: "")
    let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let previewValueField = NSTextField(wrappingLabelWithString: "")
    let previewSectionStack = NSStackView()
    let mainSplitView = NSSplitView()

    let actionOverlayView = ActionOverlayView()
    let actionPanelView = NSVisualEffectView()
    var hasConfiguredWindowFrameAutosave = false
    var hasRestoredSplitViewDivider = false

    override func viewDidLoad() {
        super.viewDidLoad()

        buildUI()
        bindState()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCreateNewNotification),
            name: .snippetsCreateNew,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleActionsNotification),
            name: .snippetsToggleActions,
            object: nil
        )

        engine.startIfNeeded()
        reloadVisibleSnippets(keepSelection: false)
        if let firstID = visibleSnippets.first?.id {
            selectSnippet(id: firstID, focusEditorName: false)
        } else {
            applySelectedSnippetToEditor()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if let window = view.window {
            window.title = "Snippets"
            window.minSize = NSSize(width: 620, height: 500)

            if !hasConfiguredWindowFrameAutosave {
                hasConfiguredWindowFrameAutosave = true
                let restoredFromAutosave = window.setFrameAutosaveName(MainWindowAutosave.frameName)
                if !restoredFromAutosave {
                    window.center()
                }
            }
        }

        installKeyboardMonitorIfNeeded()

        if tableView.selectedRow == -1, !visibleSnippets.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        view.window?.makeFirstResponder(tableView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        restoreMainSplitViewDividerIfNeeded()
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func bindState() {
        store.onChange = { [weak self] in
            guard let self else { return }
            reloadVisibleSnippets(keepSelection: true)
            if !isEditingDetails {
                applySelectedSnippetToEditor()
            }
        }

        engine.onStateChange = { [weak self] in
            guard let self else { return }
            updatePermissionBanner()
            permissionStatusLabel.stringValue = engine.statusText
        }
    }
}
