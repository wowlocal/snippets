import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

private enum MainWindowAutosave {
    static let frameName = NSWindow.FrameAutosaveName("SnippetsMainWindowFrame")
    /// Keep the width free for the adaptive sidebar rule, but stop vertical
    /// resizing at the editor's measured no-scroll floor. This is a *frame*
    /// height: the window converts it to content height after accounting for its
    /// toolbar and titlebar, which currently take about 72pt.
    static let minimumContentWidth: CGFloat = 1
    static let minimumFrameHeight: CGFloat = 430
    /// First run only. The sidebar takes 0.28 of this and the editor the rest,
    /// which puts the editor pane at ~700pt — well into its wide shape, and wide
    /// enough that no string in the form is cut.
    static let preferredFirstRunContentSize = NSSize(width: 1000, height: 660)
}

private enum ActionStatusMessage {
    static let displayDuration: TimeInterval = 4
    static let fadeDuration: TimeInterval = 0.25
}

private enum ClipboardPreviewRefresh {
    static let interval: TimeInterval = 0.5
}

private enum EditorListReload {
    static let delay: TimeInterval = 0.12
}

/// Passes every click straight through to what is underneath. The status
/// message floats over the editor for four seconds at a time, and a surface that
/// eats a click on the Enabled checkbox for being in the way is worse than the
/// silence it is there to fix.
private final class StatusMessageOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class ViewController: NSViewController {
    lazy var store: SnippetStore = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.store
        }
        return SnippetStore()
    }()

    lazy var usageStore: SnippetUsageStore = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.usageStore
        }
        return SnippetUsageStore()
    }()

    lazy var engine: SnippetExpansionEngine = {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.expansionEngine
        }
        return SnippetExpansionEngine(store: store, usage: usageStore)
    }()

    var localKeyMonitor: Any?

    var visibleSnippets: [Snippet] = []
    var selectedSnippetID: UUID?
    var editingSnippetID: UUID?
    var isApplyingSnippetToEditor = false
    /// True while the table is applying a batched diff / reloadData inside
    /// `reloadVisibleSnippets`. Selection delegate callbacks fired mid-update
    /// see intermediate row indexes against the final `visibleSnippets` array,
    /// so they are ignored; `syncTableSelectionWithSelectedSnippet()` restores
    /// the correct row once the update is done.
    var isApplyingListUpdate = false
    var activeTagFilterKeys: Set<String> = []
    /// Tag filter keys applied by the previous `reloadVisibleSnippets` pass, so
    /// it can tell "the open snippet lost the tag that kept it in the list"
    /// (keep it open and editable) from "the user picked a different filter"
    /// (follow the new list).
    var lastAppliedTagFilterKeys: Set<String>?
    var renderedSuggestedTags: [String] = []
    var renderedSuggestedKeywords: [String] = []
    /// Folded keywords of every enabled snippet, so a keyword chip can be tested
    /// against the whole library with a set walk instead of filtering and
    /// sorting it again on every keystroke. Only a store change can move it.
    var enabledKeywordKeys: Set<String> = []
    private var importExportMessageDismissWorkItem: DispatchWorkItem?
    /// Bumped on every status message change so an in-flight dismiss task can
    /// detect it is stale. Text equality is not enough: re-showing the same
    /// message during its fade would pass the old task's guard and get
    /// dismissed almost immediately.
    private var importExportMessageGeneration = 0
    var editorListReloadWorkItem: DispatchWorkItem?
    var clipboardPreviewTimer: Timer?
    var observedPasteboardChangeCount = NSPasteboard.general.changeCount

    var importExportMessage: String? {
        didSet {
            updateImportExportMessageLabel(from: oldValue, to: importExportMessage)
        }
    }

    /// The same sentence, over the editor, for when the sidebar footer that
    /// normally carries it is not on screen. Built here rather than into the
    /// editor stack because it must not reserve a row: it appears for four
    /// seconds at a time and the editor is a stack view whose layout is not to
    /// reflow while someone is typing in it.
    private let statusMessageOverlayLabel = NSTextField(labelWithString: "")
    private var statusMessageOverlayView: NSView?

    let permissionBannerContainer = NSView()
    let permissionBannerDivider = NSBox()
    let permissionIconView = NSImageView()
    let permissionStatusLabel = NSTextField(labelWithString: "")
    let permissionButtonsStack = NSStackView()

    let searchField = NSSearchField()
    let searchIndex = SnippetSearchIndex()
    lazy var searchPipeline = SnippetSearchPipeline(index: searchIndex)
    let tableView = SnippetListTableView()
    let tagFilterBar = TagFilterBarView()
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let importExportMessageLabel = NSTextField(labelWithString: "")
    let listEmptyStateView = NSStackView()
    let listEmptyStateIconView = NSImageView()
    let listEmptyStateLabel = NSTextField(wrappingLabelWithString: "")
    let listEmptyStateClearButton = NSButton(title: "Clear Filters", target: nil, action: nil)

    let nameField = NSTextField(string: "")
    let snippetTextView = SnippetContentTextView()

    // MARK: - Secure snippet editor chrome
    //
    // These three replace a menu item, a confirmation alert, and a second menu item.
    // Marking a snippet secure and reading a locked one are the two things a user does
    // most often, so both are one click, in the editor, where the snippet already is.

    /// One click to encrypt a snippet, or to begin making it ordinary again.
    let secureLockToggle = NSButton()
    /// Permanently visible for a secure snippet. This is the text that used to be a
    /// first-run modal — the consequences are worth stating, but not worth a dialog the
    /// user dismisses once and can never see again.
    let secureCaptionLabel = NSTextField(wrappingLabelWithString: "")
    /// Covers the content area while a secure snippet is not readable. The whole area is
    /// the click target, because "click where the text should be" is the gesture people
    /// already try.
    let secureLockOverlay = NSView()
    let secureLockOverlayLabel = NSTextField(wrappingLabelWithString: "")
    let secureLockOverlayButton = NSButton()
    /// Which secure snippet's real text is on screen right now. This identity latch,
    /// rather than placeholder text, gates whether editor content may be written back.
    var secureContentEditableForID: UUID?

    /// The debounce for secure content edits, mirroring `SnippetStore`'s own.
    var pendingSecureEdit: Snippet?
    var secureEditWorkItem: DispatchWorkItem?

    /// A private undo manager for the content editor.
    ///
    /// By default an `NSTextView` uses the *window's* undo manager, which the name,
    /// keyword and tag fields share — and which nothing ever resets. One long-lived text
    /// view is rebound to every snippet in turn, so its undo stack accumulated edits
    /// across records: revealing a secret, editing it, selecting an ordinary snippet and
    /// pressing ⌘Z pasted the secret's plaintext into that snippet, and the next commit
    /// wrote it to snippets.json. On an emptied storage — the masked state — the same
    /// undo raised `NSRangeException` and killed the process with the vault open.
    ///
    /// Owning the manager keeps that history out of the rest of the window, and lets it
    /// be cleared on every rebind without discarding the other fields' undo.
    let snippetContentUndoManager = UndoManager()
    /// Inline replacement for the demote confirmation alert.
    let secureDemoteStrip = NSStackView()
    let secureDemoteLabel = NSTextField(wrappingLabelWithString: "")
    let keywordField = NSTextField(string: "")
    let tagsField = NSTokenField(string: "")
    let editorSuggestedTagsFlow = TagFlowView()
    let editorSuggestedKeywordsFlow = TagFlowView()
    let keywordPrefixLabel = NSTextField(labelWithString: "\\")
    let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let previewValueField = NSTextField(wrappingLabelWithString: "")
    let previewSectionStack = NSStackView()

    let editorStack = NSStackView()
    /// The editor form, one object per labelled section, in arranged order.
    /// Keyword, Name and Tags must stay in that relative order — the hand-wired
    /// tab loop in `editorNeighbor` walks it.
    var editorSections: [EditorFormSection] = []

    let mainSplitViewController = NSSplitViewController()
    var mainSplitView: NSSplitView { mainSplitViewController.splitView }
    var mainSidebarSplitItem: NSSplitViewItem?
    var mainContentSplitItem: NSSplitViewItem?

    /// The sidebar is hidden because the *window* is narrow, not because anyone
    /// asked for it. Never persisted: it is recomputed from the restored window
    /// width at launch, so a narrow window opens collapsed, a wide one does not,
    /// and nothing is written either way.
    var isSidebarAutoCollapsed = false
    /// The user pressed ⌘B to *show* the sidebar at a width where the rule would
    /// immediately hide it again. Stands the rule down until the window is back
    /// in the wide regime, where automatic behaviour is unsurprising again.
    var isAutomaticSidebarCollapseSuppressed = false
    /// True while an automatic collapse or expand is being laid out, so
    /// `handleMainSplitViewDidResize` can tell the app's own doing from the
    /// user's and persist only theirs.
    var isApplyingAutomaticSidebarCollapse = false

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
    var hasObservedWindowResize = false
    var hasPrewarmedSidebarCollapse = false
    private var hasObservedWindowWillClose = false

    override func viewDidLoad() {
        super.viewDidLoad()

        buildUI()
        buildStatusMessageOverlay()
        bindState()
        configureSnippetDropTarget()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleActionsNotification),
            name: .snippetsToggleActions,
            object: nil
        )
        // Quitting does not have to close the window, so `viewWillDisappear` is
        // not guaranteed to run: ⌘N, type nothing, ⌘Q has to leave snippets.json
        // as it was, and this is the last point at which that is still possible.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        // The permission banner used to carry a Refresh button because nothing
        // re-checked the grant: `refreshAccessibilityStatus` ran at startup and
        // nowhere else. Granting access means leaving for System Settings and
        // coming back, so coming back is the moment to look again — and the
        // banner then removes itself instead of waiting to be told.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        engine.startIfNeeded()
        startClipboardPreviewRefreshTimerIfNeeded()
        loadPersistedTagFilters()
        reloadVisibleSnippets(keepSelection: false)
        if let firstID = visibleSnippets.first?.id {
            selectSnippet(id: firstID, focus: nil)
        } else {
            applySelectedSnippetToEditor()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if let window = view.window {
            configureMainWindowChrome(window)
            applyMainWindowResizeLimits(window)

            if !hasConfiguredWindowFrameAutosave {
                hasConfiguredWindowFrameAutosave = true
                let restoredFromAutosave = window.setFrameAutosaveName(MainWindowAutosave.frameName)
                if !restoredFromAutosave {
                    // Only when there is nothing stored, so an existing user's
                    // window is left exactly where they put it.
                    //
                    // The storyboard's 480×270 is upstream of nearly every
                    // truncation this app had: the split view's own minimums
                    // force it out to ~491pt, which puts the editor at its 230pt
                    // floor and the form at 182pt, and 270pt of height against a
                    // 500pt form means a new user's first screen is a fragment.
                    // At this size the form is in its wide shape from the start
                    // and every string in it fits.
                    window.setContentSize(defaultMainWindowContentSize(on: window.screen))
                    window.center()
                }
            }

            if !hasObservedWindowWillClose {
                hasObservedWindowWillClose = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleWindowWillClose),
                    name: NSWindow.willCloseNotification,
                    object: window
                )
            }

            observeWindowResizeForAdaptiveSidebar(window)
            // Once, here, after the autosaved frame has been restored above — the
            // width rule has to see the window the user actually gets.
            view.layoutSubtreeIfNeeded()
            // Ahead of the rule's first run, so neither this launch's evaluation
            // nor the user's first drag pays for it.
            prewarmSidebarCollapseMachinery()
            evaluateAutomaticSidebarCollapse()
        }

        installKeyboardMonitorIfNeeded()

        if tableView.selectedRow == -1, !visibleSnippets.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        requestFirstResponder(tableView)
    }

    /// Closing the window is the only way out of it that means the user is done
    /// with what was open.
    ///
    /// `viewWillDisappear` looks like the place for this and is not: AppKit sends
    /// it for every trip off screen, so ⌘H, ⌘M, the yellow button and this app's
    /// own ⌘\ round trip each took back the snippet the user had just made and
    /// left the editor bound to an unrelated one on the way back in. Nothing
    /// inside that callback tells the four apart — the window still reports
    /// `isVisible` for all of them, close included — while this notification is
    /// posted on a close and on nothing else.
    @objc private func handleWindowWillClose() {
        discardOpenBlankDraft()
    }

    @objc private func handleApplicationWillTerminate() {
        discardOpenBlankDraft()
    }

    @objc private func handleApplicationDidBecomeActive() {
        guard !engine.accessibilityGranted else { return }
        engine.refreshAccessibilityStatus(prompt: false)
    }

    /// 1000×660 wants a 1152pt-class display to centre comfortably, so it is
    /// clamped to whatever the screen actually has rather than opening off the
    /// edge of a small laptop.
    private func defaultMainWindowContentSize(on screen: NSScreen?) -> NSSize {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            return MainWindowAutosave.preferredFirstRunContentSize
        }
        return NSSize(
            width: min(MainWindowAutosave.preferredFirstRunContentSize.width, visible.width - 80),
            height: min(MainWindowAutosave.preferredFirstRunContentSize.height, visible.height - 80)
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let window = view.window {
            applyMainWindowResizeLimits(window)
        }
        restoreMainSplitViewDividerIfNeeded()

        updateSnippetTextViewWrappingWidth()
        updateSearchSuggestionOverlayLayout()
    }

    deinit {
        importExportMessageDismissWorkItem?.cancel()
        editorListReloadWorkItem?.cancel()
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
        rebuildEnabledKeywordKeys()
        store.onChange = { [weak self] source in
            guard let self else { return }
            // Ahead of the early return below: a local edit while the editor has
            // focus is precisely when a keyword moves, and the suggestion chips
            // are filtered against this on that same keystroke.
            rebuildEnabledKeywordKeys()
            if source == .local && isEditingDetails {
                scheduleEditorListReload()
                return
            }

            cancelEditorListReload()
            reloadVisibleSnippets(keepSelection: true)
            if source == .external || !isEditingDetails {
                applySelectedSnippetToEditor()
            }
        }

        // Masking follows the frontmost app. This never touches the key's lifetime —
        // VaultSession deliberately does NOT lock on resign-active, because this app is
        // backgrounded exactly when a snippet is being used — it only stops a revealed
        // secret sitting on screen behind a screen share or over a shoulder.
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let snippet = self.selectedSnippet,
                          self.store.isSecure(snippet.id) else { return }
                    self.applySecureStateToEditor(for: snippet)
                }
            }
        }

        if let app = NSApp.delegate as? AppDelegate {
            NotificationCenter.default.addObserver(
                forName: .snippetsVaultWillLock,
                object: app.vaultSession,
                queue: .main
            ) { [weak self] _ in
                // VaultSession deliberately posts this synchronously while its key is
                // still resident. Flush the editor's trailing debounce now; waiting for
                // the state-change notification below would first destroy the key and
                // then mask the only remaining copy of the newest text.
                MainActor.assumeIsolated { self?.flushPendingSecureEdit() }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .snippetsVaultStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let snippet = self.selectedSnippet else { return }
                // Re-applies in both directions. Locking must pull a revealed secret off
                // the screen — a five-minute timeout that leaves the text sitting in the
                // editor would make the whole session window decorative.
                self.applySecureStateToEditor(for: snippet)
                self.reloadVisibleSnippets(keepSelection: true)
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

    private func rebuildEnabledKeywordKeys() {
        enabledKeywordKeys = Set(
            store.snippets.lazy
                .filter(\.isEnabled)
                .map { SnippetTagging.filterKey(for: $0.normalizedKeyword) }
                .filter { !$0.isEmpty }
        )
    }

    func scheduleEditorListReload() {
        editorListReloadWorkItem?.cancel()
        // A previous query may be scanning the pre-keystroke library. It must not
        // repaint the list while this newer edit is waiting for its coalesced refresh.
        searchPipeline.cancelPending()

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editorListReloadWorkItem = nil
                if SnippetSearchSnapshot.normalizedQuery(self.searchField.stringValue).isEmpty {
                    self.reloadVisibleSnippets(keepSelection: true)
                } else {
                    self.reloadVisibleSnippetsForSearch()
                }
            }
        }
        editorListReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + EditorListReload.delay, execute: workItem)
    }

    func cancelEditorListReload() {
        editorListReloadWorkItem?.cancel()
        editorListReloadWorkItem = nil
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
        let isSecure = snippetTextView.isSecureContentMode
            || editingSnippetID.map(store.isSecure) == true
        guard !isSecure else {
            // Do not even submit the secure body to placeholder inspection.
            // `updatePreview` also refuses it, independently, for every caller.
            updatePreview(withTemplate: "")
            return
        }
        let template = snippetTextView.string
        guard PlaceholderResolver.containsClipboardPlaceholder(in: template) else { return }

        updatePreview(withTemplate: template)
    }

    private func applyMainWindowResizeLimits(_ window: NSWindow) {
        let decorationHeight = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: NSSize(width: MainWindowAutosave.minimumContentWidth, height: 0)
            )
        ).height
        let minimumContentSize = NSSize(
            width: MainWindowAutosave.minimumContentWidth,
            height: max(1, MainWindowAutosave.minimumFrameHeight - decorationHeight)
        )

        window.contentMinSize = minimumContentSize
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size
    }

    private func buildStatusMessageOverlay() {
        statusMessageOverlayLabel.font = .systemFont(ofSize: 12)
        statusMessageOverlayLabel.textColor = .labelColor
        statusMessageOverlayLabel.alignment = .center
        statusMessageOverlayLabel.lineBreakMode = .byTruncatingTail
        statusMessageOverlayLabel.maximumNumberOfLines = 1
        statusMessageOverlayLabel.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusMessageOverlayLabel)

        let surface = LiquidGlassDesign.makeTransientSurface(
            containing: contentView,
            cornerRadius: LiquidGlassDesign.Metrics.controlCornerRadius,
            fallbackMaterial: .popover
        )

        let container = StatusMessageOverlayView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        container.alphaValue = 0
        container.addSubview(surface)
        view.addSubview(container)
        statusMessageOverlayView = container

        NSLayoutConstraint.activate([
            statusMessageOverlayLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            statusMessageOverlayLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            statusMessageOverlayLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            statusMessageOverlayLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),

            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])
    }

    /// `importExportMessageLabel` is the only surface this app has for a status
    /// message and it sits in the sidebar footer, which ⌘B removes from the
    /// window outright. Everything routed through here was therefore invisible
    /// with the sidebar collapsed — including the one sentence ⇧⌘N exists to say
    /// when the clipboard holds no text, which left a command the user explicitly
    /// invoked with no observable effect at all.
    private func presentStatusMessageOverlay(_ message: String?) {
        guard let statusMessageOverlayView else { return }

        guard let message, !message.isEmpty, isSidebarCollapsed else {
            statusMessageOverlayView.isHidden = true
            statusMessageOverlayView.alphaValue = 0
            return
        }

        statusMessageOverlayLabel.stringValue = message
        statusMessageOverlayView.isHidden = false
        // Through the animator, like the label below: a message re-shown during
        // the previous one's fade has an animation in flight, and assigning
        // `alphaValue` directly would be overwritten by it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            statusMessageOverlayView.animator().alphaValue = 1
        }
    }

    /// The sidebar moved out from under a message that is already on screen.
    /// `presentStatusMessageOverlay` chooses between the sidebar footer and the
    /// overlay at the moment a message is *set*, so a collapse or expand under a
    /// live message has to ask it again.
    func refreshStatusMessagePresentation() {
        presentStatusMessageOverlay(importExportMessage)
    }

    private func updateImportExportMessageLabel(from oldValue: String?, to newValue: String?) {
        importExportMessageGeneration += 1
        let generation = importExportMessageGeneration
        importExportMessageDismissWorkItem?.cancel()
        importExportMessageDismissWorkItem = nil

        presentStatusMessageOverlay(newValue)

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
                guard let self, self.importExportMessageGeneration == generation else { return }
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = ActionStatusMessage.fadeDuration
                    self.importExportMessageLabel.animator().alphaValue = 0
                    self.statusMessageOverlayView?.animator().alphaValue = 0
                }
                guard self.importExportMessageGeneration == generation else { return }
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

}
