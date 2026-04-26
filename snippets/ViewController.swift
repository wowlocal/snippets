import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

private enum MainWindowAutosave {
    static let frameName = NSWindow.FrameAutosaveName("SnippetsMainWindowFrame")
    static let relaxedMinimumContentSize = NSSize(width: 1, height: 1)
}

private enum ActionStatusMessage {
    static let displayDuration: TimeInterval = 4
    static let fadeDuration: TimeInterval = 0.25
}

private enum ClipboardPreviewRefresh {
    static let interval: TimeInterval = 0.5
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
    private var importExportMessageDismissWorkItem: DispatchWorkItem?
    var clipboardPreviewTimer: Timer?
    var observedPasteboardChangeCount = NSPasteboard.general.changeCount

    var importExportMessage: String? {
        didSet {
            updateImportExportMessageLabel(from: oldValue, to: importExportMessage)
        }
    }

    let permissionBannerContainer = NSView()
    let permissionBannerDivider = NSBox()
    let permissionIconView = NSImageView()
    let permissionTitleLabel = NSTextField(labelWithString: "")
    let permissionStatusLabel = NSTextField(labelWithString: "")
    let permissionButtonsStack = NSStackView()

    let searchField = NSSearchField()
    let tableView = SnippetListTableView()
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let importExportMessageLabel = NSTextField(labelWithString: "")

    let nameField = NSTextField(string: "")
    let snippetTextView = NSTextView()
    let keywordField = NSTextField(string: "")
    let keywordPrefixLabel = NSTextField(labelWithString: "\\")
    let keywordWarningLabel = NSTextField(labelWithString: "")
    let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let previewValueField = NSTextField(wrappingLabelWithString: "")
    let previewSeparator = NSBox()
    let previewSectionStack = NSStackView()
    let mainSplitViewController = NSSplitViewController()
    var mainSplitView: NSSplitView { mainSplitViewController.splitView }
    var mainSidebarSplitItem: NSSplitViewItem?
    var mainContentSplitItem: NSSplitViewItem?

    let actionOverlayView = ActionOverlayView()
    let actionPanelView = NSView()
    let actionShortcutStack = NSStackView()
    let actionPanelTipLabel = NSTextField(labelWithString: "")
    var actionShortcutRows: [(view: ActionShortcutRow, isEssential: Bool)] = []
    let searchSuggestionOverlayView = SearchSuggestionOverlayView()
    var searchSuggestionLeadingConstraint: NSLayoutConstraint?
    var searchSuggestionTopConstraint: NSLayoutConstraint?
    var searchSuggestionWidthConstraint: NSLayoutConstraint?
    var searchSuggestionHeightConstraint: NSLayoutConstraint?
    var searchSuggestionClickMonitor: Any?
    var hasConfiguredWindowFrameAutosave = false
    var hasConfiguredMainWindowToolbar = false
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePaleThemeChanged),
            name: .snippetsPaleThemeChanged,
            object: nil
        )

        engine.startIfNeeded()
        startClipboardPreviewRefreshTimerIfNeeded()
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
            configureMainWindowChrome(window)
            relaxWindowResizeLimits(window)

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

        requestFirstResponder(tableView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let window = view.window {
            relaxWindowResizeLimits(window)
        }
        restoreMainSplitViewDividerIfNeeded()
        updateSnippetTextViewWrappingWidth()
        updateSearchSuggestionOverlayLayout()
    }

    deinit {
        importExportMessageDismissWorkItem?.cancel()
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let searchSuggestionClickMonitor {
            NSEvent.removeMonitor(searchSuggestionClickMonitor)
        }
        clipboardPreviewTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func bindState() {
        store.onChange = { [weak self] source in
            guard let self else { return }
            reloadVisibleSnippets(keepSelection: true)
            if source == .external || !isEditingDetails {
                applySelectedSnippetToEditor()
            }
        }

        engine.onStateChange = { [weak self] in
            guard let self else { return }
            updatePermissionBanner()
            permissionStatusLabel.stringValue = engine.statusText
            if shouldPresentEngineStatusMessage(engine.statusText) {
                importExportMessage = engine.statusText
            }
        }
    }

    private func startClipboardPreviewRefreshTimerIfNeeded() {
        guard clipboardPreviewTimer == nil else { return }

        observedPasteboardChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: ClipboardPreviewRefresh.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshClipboardDependentPreviewIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardPreviewTimer = timer
    }

    private func refreshClipboardDependentPreviewIfNeeded() {
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        guard pasteboardChangeCount != observedPasteboardChangeCount else { return }

        observedPasteboardChangeCount = pasteboardChangeCount
        let template = snippetTextView.string
        guard PlaceholderResolver.containsClipboardPlaceholder(in: template) else { return }

        updatePreview(withTemplate: template)
    }

    private func relaxWindowResizeLimits(_ window: NSWindow) {
        window.contentMinSize = MainWindowAutosave.relaxedMinimumContentSize
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: MainWindowAutosave.relaxedMinimumContentSize)
        ).size
    }

    private func updateImportExportMessageLabel(from oldValue: String?, to newValue: String?) {
        importExportMessageDismissWorkItem?.cancel()
        importExportMessageDismissWorkItem = nil

        guard let newValue, !newValue.isEmpty else {
            importExportMessageLabel.stringValue = ""
            importExportMessageLabel.alphaValue = 1
            return
        }

        importExportMessageLabel.stringValue = newValue
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            importExportMessageLabel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.importExportMessage == newValue else { return }
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = ActionStatusMessage.fadeDuration
                    self.importExportMessageLabel.animator().alphaValue = 0
                }
                guard self.importExportMessage == newValue else { return }
                self.importExportMessageDismissWorkItem = nil
                self.importExportMessage = nil
            }
        }

        importExportMessageDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ActionStatusMessage.displayDuration,
            execute: workItem
        )
    }

    private func shouldPresentEngineStatusMessage(_ message: String) -> Bool {
        message.hasPrefix("Copied ")
            || message.hasPrefix("Pasted ")
            || message.hasPrefix("Expanded ")
    }

    @objc private func handlePaleThemeChanged() {
        applyThemeColors()
        tableView.reloadData()
    }

    func applyThemeColors() {
        ThemeManager.applyToggleAppearance(to: enabledCheckbox)
        keywordWarningLabel.textColor = ThemeManager.alertColor
        updatePermissionBanner()

        if let window = view.window, hasConfiguredMainWindowToolbar {
            hasConfiguredMainWindowToolbar = false
            window.toolbar = nil
            configureMainWindowChrome(window)
        }
    }
}
