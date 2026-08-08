import AppKit

enum MainLayoutMetrics {
    static let sidebarMinWidth: CGFloat = 260
    static let sidebarMaxWidth: CGFloat = 520
    static let sidebarPreferredFraction: CGFloat = 0.28
    static let editorMinWidth: CGFloat = 230
    static let editorHorizontalPadding: CGFloat = 24
    static let previewMaxHeight: CGFloat = 150
    /// AppKit's own responsive-sidebar mechanism, deliberately disarmed — see
    /// `buildUI` for why the app runs the rule itself instead.
    static let minimumInlineSidebarWidth: CGFloat = 0
    static let splitViewDividerPositionDefaultsKey = "SnippetsMainSplitDividerPosition"
    static let sidebarCollapsedDefaultsKey = "SnippetsMainSidebarCollapsed"

    /// Window content width below which the sidebar takes itself out of the way.
    ///
    /// The sidebar is 268pt at its narrowest (260pt pane plus the 8pt Liquid
    /// Glass inset), the editor pane is the rest, and the form inside it is 48pt
    /// narrower again. At 680 that leaves a 40-column content box in the 14pt
    /// monospaced font — and the box wraps `.byCharWrapping`, so below that it
    /// stops breaking at spaces and starts breaking inside URLs and
    /// `{placeholders}`. Under 680 the sidebar costs more than it gives.
    static let sidebarAutoCollapseWidth: CGFloat = 680

    /// …and the width at which it comes back. 140pt above the collapse width, not
    /// equal to it: a single threshold flips on hand-wobble — measured 34 times
    /// over 200 samples of ±6pt jitter versus once with this band. The rule reads
    /// the *window's* width, never the editor's, so the band only has to absorb
    /// input jitter rather than the 268pt step collapsing puts through the
    /// editor.
    static let sidebarAutoExpandWidth: CGFloat = 820

    /// Enough that the editor can never be laid out at zero height. Without it,
    /// dragging the window small enough reaches a state where the split view,
    /// both panes and the editor's scroll view are all 0pt tall and only the
    /// permission banner is on screen.
    static let splitViewMinimumHeight: CGFloat = 120
}

/// The editor's vertical give. The content box is the only view in the form with
/// a scroller of its own, so it is the only one that can lose height for free —
/// these numbers make it the view that yields, and make it yield first.
enum EditorVerticalMetrics {
    /// Four lines of the 14pt monospaced font: `defaultLineHeight` measures 17.0
    /// for it and `textContainerInset` is 8pt top and bottom, so 4 * 17 + 16 = 84.
    /// Three lines is 67 and one is 33; four is the smallest box in which a
    /// paragraph still has a shape and the caret has a line above and below it.
    /// The cost is exactly linear — every point here is a point of minimum window
    /// height — so 67 would buy 17pt of window and 50 would buy 34.
    static let contentBoxMinimumHeight: CGFloat = 84

    /// What the box asks for when there is room. Optional, so it is the first
    /// thing in the whole editor that the layout gives up.
    static let contentBoxPreferredHeight: CGFloat = 220
    static let contentBoxPreferredPriority = NSLayoutConstraint.Priority(200)

    /// Strictly below `windowSizeStayPut`, and that is the whole trick.
    ///
    /// The constraint this carries is `document height == viewport height`, whose
    /// `<=` half reads "the viewport must be at least as tall as the form" — and
    /// at or above 500 the layout engine happily satisfies that by *growing the
    /// window*. Measured: asking a 300pt window for this at 700, 510 and 500 got
    /// back 479, 479 and 373; at 490 and below the window stayed exactly where it
    /// was put. 20 under keeps clear of all three of AppKit's window-drag
    /// priorities (490 / 500 / 510) rather than tying with the lowest.
    ///
    /// Anyone tempted to raise this "so it works better" will silently break
    /// window resizing instead: there is no constraint log for it, just a window
    /// that will not get small.
    static let editorFitsViewportPriority = NSLayoutConstraint.Priority(
        rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 20
    )

    /// Above `editorFitsViewportPriority`, so the preview keeps its lines.
    ///
    /// It used to be `.defaultLow`, which is below the viewport pull, so between
    /// roughly 560 and 640pt of window height the form took its next 100pt out of
    /// the preview while the box sat parked on its floor. The preview is a
    /// wrapping label with no scroller of its own, so those lines were not
    /// scrolled out of reach, they were gone — and showing what will actually be
    /// pasted is the preview's entire job. It is still bounded by
    /// `previewMaxHeight` and its own 8-line cap; past that the outer scroller
    /// takes over, which is recoverable.
    static let previewKeepsItsLinesPriority = NSLayoutConstraint.Priority.defaultHigh
}

private struct ActionShortcutDescriptor {
    let title: String
    let shortcut: String
    let isEssential: Bool
}

/// An action the list's empty state can offer. The raw values are view tags, so
/// none of them may be 0 — that is every untagged view in the stack.
enum ListEmptyStateAction: Int {
    case newSnippet = 1
    case newFromClipboard = 2
    case importSnippets = 3
}

private enum ActionPanelContent {
    static let shortcuts: [ActionShortcutDescriptor] = [
        // The mechanic the whole app exists for led this list nowhere: a user
        // could read every row and still not know a snippet is typed, not clicked.
        ActionShortcutDescriptor(title: "Expand a Snippet", shortcut: "\\keyword", isEssential: true),
        // Beside it, because the two typed-syntax rows belong together. This is
        // where the placeholder vocabulary is written down now that the list of
        // tokens no longer sits permanently under the content box; the tokens
        // themselves are offered by completion the moment a `{` is typed.
        ActionShortcutDescriptor(title: "Insert a Placeholder", shortcut: "{", isEssential: true),
        ActionShortcutDescriptor(title: "Copy Snippet", shortcut: "↩", isEssential: true),
        ActionShortcutDescriptor(title: "Paste Snippet", shortcut: "⌘↩", isEssential: true),
        ActionShortcutDescriptor(title: "Search", shortcut: "⌘F", isEssential: true),
        ActionShortcutDescriptor(title: "Toggle Sidebar", shortcut: "⌘B", isEssential: true),
        ActionShortcutDescriptor(title: "Create New Snippet", shortcut: "⌘N", isEssential: true),
        // Beside ⌘N, where the File menu also puts it: this panel is where the
        // app's shortcuts are written down, and a list that promises all of them
        // and omits the clipboard capture reads as "there isn't one".
        ActionShortcutDescriptor(title: "New from Clipboard", shortcut: "⇧⌘N", isEssential: true),
        ActionShortcutDescriptor(title: "Edit Snippet", shortcut: "⌘E", isEssential: true),
        ActionShortcutDescriptor(title: "Delete Snippet", shortcut: "⌘⌫", isEssential: true),
        ActionShortcutDescriptor(title: "Copy Share Link", shortcut: "⇧⌘C", isEssential: false),
        ActionShortcutDescriptor(title: "Duplicate Snippet", shortcut: "⌘D", isEssential: false),
        ActionShortcutDescriptor(title: "Enable / Disable", shortcut: "⌘/", isEssential: true),
        ActionShortcutDescriptor(title: "Pin / Unpin", shortcut: "⌘.", isEssential: true),
        ActionShortcutDescriptor(title: "Import", shortcut: "⇧⌘I", isEssential: false),
        ActionShortcutDescriptor(title: "Export", shortcut: "⇧⌘E", isEssential: false),
        ActionShortcutDescriptor(title: "Toggle Shortcuts", shortcut: "⌘K", isEssential: false),
        ActionShortcutDescriptor(title: "Next Snippet", shortcut: "⌃N", isEssential: false),
        ActionShortcutDescriptor(title: "Previous Snippet", shortcut: "⌃P", isEssential: false),
        // Escape is the only way out of the panel, so it cannot be one of the
        // rows you have to already know about Option to discover.
        ActionShortcutDescriptor(title: "Dismiss Panel", shortcut: "esc", isEssential: true)
    ]

    // "Esc dismisses." is already a row in the list below, and it is `isEssential`
    // so it is in the compact list too — the tip line was saying it twice on one
    // screen. ⌥ rather than "Option" because every other glyph here is a glyph.
    static let compactTip = "Hold ⌥ for all shortcuts."
    static let expandedTip = "Release ⌥ for essentials."
}

/// Editor strings that more than one file has to agree on.
enum EditorCopy {
    /// What Name says when there is no content to show the sidebar title from.
    static let namePlaceholderFallback = "Optional"
    static let namePlaceholderCharacterLimit = 60
}

extension ViewController {
    func configureEditorSurface(_ view: NSView, backgroundColor: NSColor) {
        LiquidGlassDesign.configureEditorSurface(view, backgroundColor: backgroundColor)
    }

    func buildUI() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        view = rootView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.distribution = .fill
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(rootStack)

        let banner = buildPermissionBanner()
        rootStack.addArrangedSubview(banner)

        permissionBannerDivider.boxType = .separator
        rootStack.addArrangedSubview(permissionBannerDivider)

        configureMainSplitViewController()
        addChild(mainSplitViewController)

        let splitView = mainSplitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // Low compression resistance is what lets the editor give height back, but
        // it has no floor of its own, so a small enough window laid the whole
        // split view out at zero and left only the permission banner on screen.
        splitView.heightAnchor
            .constraint(greaterThanOrEqualToConstant: MainLayoutMetrics.splitViewMinimumHeight)
            .isActive = true
        rootStack.addArrangedSubview(splitView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMainSplitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: mainSplitView
        )

        [banner, permissionBannerDivider, splitView].forEach {
            $0.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }
        banner.setContentHuggingPriority(.required, for: .vertical)
        permissionBannerDivider.setContentHuggingPriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: rootView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        buildSearchSuggestionOverlay(in: rootView)
        buildActionOverlay(in: rootView)
    }

    func configureMainSplitViewController() {
        guard mainSplitViewController.splitViewItems.isEmpty else { return }

        let managedSplitView = NSSplitView()
        managedSplitView.isVertical = true
        managedSplitView.dividerStyle = .thin
        // Deliberately no `autosaveName`. NSSplitView's autosave records the
        // collapsed flag as well as the divider, and it re-applies it on the next
        // window open *after* the assignment below — so it, not the app, decided
        // what the sidebar did. Worse, an automatic collapse landed in that store
        // and came back looking exactly like something the user had chosen: leave
        // the window narrow once, close it, and the sidebar was pinned hidden at
        // every width, in that launch and every one after. The app persists both
        // pieces itself, under its own keys, so there is nothing here to keep and
        // one fewer source of truth to disagree with.

        mainSplitViewController.splitView = managedSplitView
        // AppKit's own responsive-sidebar mechanism, disarmed. It never fired for
        // a programmatic resize at any threshold tried, and what it promises is
        // worse than useless here: it keeps its "I collapsed this" bit private,
        // so an AppKit collapse is indistinguishable from ⌘B, and its documented
        // auto-uncollapse would undo a deliberate collapse on every re-widen.
        // `evaluateAutomaticSidebarCollapse` runs the rule instead, where the two
        // are kept apart. 0 so the two can never race on `isCollapsed`.
        mainSplitViewController.minimumThicknessForInlineSidebars = MainLayoutMetrics.minimumInlineSidebarWidth

        let sidebarController = NSViewController()
        sidebarController.view = buildSidebar()

        let editorController = NSViewController()
        editorController.view = buildEditor()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = MainLayoutMetrics.sidebarMinWidth
        sidebarItem.maximumThickness = MainLayoutMetrics.sidebarMaxWidth
        sidebarItem.preferredThicknessFraction = MainLayoutMetrics.sidebarPreferredFraction
        sidebarItem.canCollapse = true

        if #available(macOS 11.0, *) {
            sidebarItem.allowsFullHeightLayout = true
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let contentItem = NSSplitViewItem(viewController: editorController)
        contentItem.minimumThickness = MainLayoutMetrics.editorMinWidth
        contentItem.holdingPriority = .defaultLow

        if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
            contentItem.automaticallyAdjustsSafeAreaInsets = true
        }

        mainSplitViewController.addSplitViewItem(sidebarItem)
        mainSplitViewController.addSplitViewItem(contentItem)

        mainSidebarSplitItem = sidebarItem
        mainContentSplitItem = contentItem
        // The app's own key, unconditionally, and after `addSplitViewItem`. With
        // the autosave gone this really is the only thing that decides the
        // starting state; the width rule runs later, in `viewDidAppear`, once the
        // restored frame is known.
        sidebarItem.isCollapsed = userWantsSidebarCollapsed
    }

    @objc
    func handleMainSplitViewDidResize(_ notification: Notification) {
        guard mainSplitView.subviews.count >= 2 else { return }

        updateSnippetTextViewWrappingWidth()
        if isSearchSuggestionOverlayVisible {
            updateSearchSuggestionOverlay()
        }
        // Only a collapse the user performed — ⌘B, or dragging the divider off
        // the edge — is a preference. An automatic one is a fact about the window
        // they happen to be dragging, and persisting it would make one narrow
        // window a permanent decision no later wide window undoes.
        if !isApplyingAutomaticSidebarCollapse, !isSidebarAutoCollapsed {
            storeSidebarCollapsedState(isCollapsed: isSidebarCollapsed)
        }

        guard !isSidebarCollapsed else { return }
        guard let position = currentSidebarThickness() else { return }

        UserDefaults.standard.set(Double(position), forKey: MainLayoutMetrics.splitViewDividerPositionDefaultsKey)
    }

    /// The sidebar wrapper's width, i.e. the divider position.
    ///
    /// Found by ancestry, not by index. This used to read `subviews[0]`, which is
    /// the *editor* wrapper on both appearance paths — on the glass path it is
    /// full-bleed, so the app stored the window's width as the sidebar's, and
    /// `clampedSidebarWidth` capped it at the 520pt maximum on the way back in.
    /// Drag the sidebar to 300, get 520 next launch. The split view's subview
    /// array is several entries of mostly private decoration on macOS 26 and its
    /// order is not API.
    func currentSidebarThickness() -> CGFloat? {
        guard let sidebarView = mainSidebarSplitItem?.viewController.view else { return nil }
        guard let wrapper = mainSplitView.subviews.first(where: { sidebarView.isDescendant(of: $0) })
        else { return nil }

        let width = wrapper.frame.width
        guard width.isFinite, width > 0 else { return nil }
        return width
    }

    func restoreMainSplitViewDividerIfNeeded() {
        guard !hasRestoredSplitViewDivider else { return }
        guard mainSplitView.subviews.count >= 2 else { return }
        guard !isSidebarCollapsed else { return }

        let storedPosition = UserDefaults.standard.double(forKey: MainLayoutMetrics.splitViewDividerPositionDefaultsKey)
        guard storedPosition > 0 else {
            hasRestoredSplitViewDivider = true
            return
        }

        let proposedMaximum = mainSplitView.bounds.width - mainSplitView.dividerThickness
        guard proposedMaximum > 0 else { return }

        // Wait for a layout pass where the stored width actually fits, and only
        // then restore — once, for good. The first `viewDidLayout` runs while the
        // split view is still at its storyboard width, where a 320pt sidebar
        // clamps to 269; marking it done there meant the clamped value got
        // written back over the stored one and the sidebar reset to its minimum
        // on every launch. Deferring is safe in a way that retrying is not: this
        // returns without touching the divider, so it can never fight a drag,
        // and it stops the moment the window is wide enough.
        guard proposedMaximum - MainLayoutMetrics.editorMinWidth >= CGFloat(storedPosition) else { return }

        let clampedPosition = clampedSidebarWidth(in: mainSplitView, proposedWidth: CGFloat(storedPosition))
        mainSplitView.setPosition(clampedPosition, ofDividerAt: 0)

        hasRestoredSplitViewDivider = true
    }

    /// Idempotent, because this runs on every split-view resize notification and
    /// "how many times did the app record a decision the user did not make?" is
    /// only answerable if a no-op write is not one of them.
    func storeSidebarCollapsedState(isCollapsed: Bool) {
        let key = MainLayoutMetrics.sidebarCollapsedDefaultsKey
        guard UserDefaults.standard.bool(forKey: key) != isCollapsed else { return }
        UserDefaults.standard.set(isCollapsed, forKey: key)
    }

    /// What the user last asked for, as opposed to what is on screen right now.
    var userWantsSidebarCollapsed: Bool {
        UserDefaults.standard.bool(forKey: MainLayoutMetrics.sidebarCollapsedDefaultsKey)
    }

    func updateSnippetTextViewWrappingWidth() {
        guard let scrollView = snippetTextView.enclosingScrollView else { return }

        let availableWidth = scrollView.contentView.bounds.width
        guard availableWidth.isFinite, availableWidth > 0 else { return }
        guard abs(snippetTextView.frame.width - availableWidth) > 0.5 else { return }

        let availableHeight = max(snippetTextView.frame.height, scrollView.contentView.bounds.height)
        snippetTextView.setFrameSize(NSSize(width: availableWidth, height: availableHeight))

        if let textContainer = snippetTextView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
            let fullRange = NSRange(location: 0, length: snippetTextView.string.utf16.count)
            snippetTextView.layoutManager?.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            snippetTextView.layoutManager?.ensureLayout(for: textContainer)
        }
    }

    func clampedSidebarWidth(in splitView: NSSplitView, proposedWidth: CGFloat) -> CGFloat {
        let availableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
        let minimumSidebarWidth = min(MainLayoutMetrics.sidebarMinWidth, availableWidth)
        let maximumSidebarWidth = max(
            minimumSidebarWidth,
            min(MainLayoutMetrics.sidebarMaxWidth, availableWidth - MainLayoutMetrics.editorMinWidth)
        )
        return min(max(proposedWidth, minimumSidebarWidth), maximumSidebarWidth)
    }

    func buildPermissionBanner() -> NSView {
        let container = permissionBannerContainer
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        permissionIconView.imageScaling = .scaleProportionallyDown
        permissionIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        permissionIconView.translatesAutoresizingMaskIntoConstraints = false
        permissionIconView.widthAnchor.constraint(equalToConstant: 16).isActive = true

        permissionStatusLabel.font = .systemFont(ofSize: 13)
        permissionStatusLabel.textColor = .secondaryLabelColor
        // Two lines rather than one truncated one. This sentence is the only
        // explanation of why expansion is not working, and at a narrow window a
        // single line cut it down to about three words.
        permissionStatusLabel.lineBreakMode = .byWordWrapping
        permissionStatusLabel.usesSingleLineMode = false
        permissionStatusLabel.maximumNumberOfLines = 2
        // This sentence set the whole window's minimum width — and it did it even
        // with the banner hidden, because the banner is pinned to the root
        // stack's width whether or not `detachesHiddenViews` has taken it out of
        // the arrangement. At required resistance no window could be narrower
        // than the sentence, which is wider than the width the sidebar is
        // supposed to step aside at, so the rule would have been unreachable.
        permissionStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // No "Refresh": that button existed only because nothing else re-checked
        // the grant, which made the user do the app's polling by hand. The app
        // now re-checks whenever it comes forward, which is exactly the moment
        // someone returns from System Settings. And a bare noun is not a button
        // title — "Open Accessibility Settings" says what the click does.
        let requestButton = NSButton(title: "Request Permission", target: self, action: #selector(requestPermission))
        let accessibilityButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))

        permissionButtonsStack.orientation = .horizontal
        permissionButtonsStack.spacing = 8
        [requestButton, accessibilityButton].forEach {
            $0.controlSize = .small
            if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
                $0.bezelStyle = .glass
            } else {
                $0.bezelStyle = .rounded
            }
            permissionButtonsStack.addArrangedSubview($0)
        }

        // Icon and sentence, no title. "Permissions Required" in bold alert
        // colour was immediately followed by a sentence saying the same thing at
        // greater length, and the triangle already carries the severity.
        let leadingStatusStack = NSStackView(views: [permissionIconView, permissionStatusLabel])
        leadingStatusStack.orientation = .horizontal
        leadingStatusStack.spacing = 8
        leadingStatusStack.alignment = .centerY

        stack.addArrangedSubview(leadingStatusStack)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(permissionButtonsStack)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let surface = LiquidGlassDesign.makeTransientSurface(
            containing: contentView,
            cornerRadius: 0,
            fallbackMaterial: .contentBackground,
            tintColor: NSColor.systemOrange.withAlphaComponent(0.08)
        )
        container.addSubview(surface)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        return container
    }

    private func buildListEmptyState(in listContainer: NSView) {
        listEmptyStateIconView.imageScaling = .scaleProportionallyDown
        listEmptyStateIconView.contentTintColor = .tertiaryLabelColor
        listEmptyStateIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)

        listEmptyStateLabel.font = .systemFont(ofSize: 12)
        listEmptyStateLabel.textColor = .secondaryLabelColor
        listEmptyStateLabel.alignment = .center

        listEmptyStateClearButton.target = self
        listEmptyStateClearButton.action = #selector(clearTagFiltersFromEmptyState)
        listEmptyStateClearButton.controlSize = .small
        if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
            listEmptyStateClearButton.bezelStyle = .glass
        } else {
            listEmptyStateClearButton.bezelStyle = .rounded
        }

        listEmptyStateView.orientation = .vertical
        listEmptyStateView.spacing = 8
        listEmptyStateView.alignment = .centerX
        listEmptyStateView.translatesAutoresizingMaskIntoConstraints = false
        listEmptyStateView.isHidden = true
        listEmptyStateView.addArrangedSubview(listEmptyStateIconView)
        listEmptyStateView.addArrangedSubview(listEmptyStateLabel)
        for button in makeListEmptyStateActionButtons() {
            listEmptyStateView.addArrangedSubview(button)
            // One column of matching buttons: the sidebar is 260pt at its
            // narrowest, where "New from Clipboard" alone fills the row.
            button.widthAnchor.constraint(equalTo: listEmptyStateView.widthAnchor).isActive = true
        }
        listEmptyStateView.addArrangedSubview(listEmptyStateClearButton)
        listEmptyStateView.setCustomSpacing(12, after: listEmptyStateLabel)

        listContainer.addSubview(listEmptyStateView)

        NSLayoutConstraint.activate([
            listEmptyStateView.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            listEmptyStateView.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor, constant: -24),
            listEmptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: listContainer.leadingAnchor, constant: 12),
            listEmptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: listContainer.trailingAnchor, constant: -12)
        ])
    }

    private func makeListEmptyStateActionButtons() -> [NSButton] {
        [
            makeListEmptyStateActionButton(
                title: "New Snippet",
                action: #selector(createSnippet(_:)),
                tag: .newSnippet
            ),
            makeListEmptyStateActionButton(
                title: "New from Clipboard",
                action: #selector(createSnippetFromClipboard(_:)),
                tag: .newFromClipboard
            ),
            // Import is the shortest path from "no snippets" to a full library,
            // and it lived three levels deep in Menu ▸ More ▸ Import…
            makeListEmptyStateActionButton(
                title: "Import…",
                action: #selector(runImport(_:)),
                tag: .importSnippets
            )
        ]
    }

    private func makeListEmptyStateActionButton(
        title: String,
        action: Selector,
        tag: ListEmptyStateAction
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.tag = tag.rawValue
        button.controlSize = .small
        if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
        return button
    }

    /// Shows exactly `actions` in the empty state. The buttons are found by tag
    /// rather than held: a hidden arranged subview is detached from the stack's
    /// `subviews`, so `viewWithTag` would stop seeing one the moment it is hidden.
    func showListEmptyStateActions(_ actions: Set<ListEmptyStateAction>) {
        for view in listEmptyStateView.arrangedSubviews {
            guard let action = ListEmptyStateAction(rawValue: view.tag) else { continue }
            view.isHidden = !actions.contains(action)
        }
    }

    @objc private func clearTagFiltersFromEmptyState() {
        clearTagFilters()
    }

    func buildSidebar() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.distribution = .fill
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        tableScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tableScrollView.borderType = .noBorder
        tableScrollView.drawsBackground = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.scrollerStyle = .overlay

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SnippetColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.focusRingType = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.contextMenuProvider = { [weak self] row in
            self?.makeSnippetContextMenu(for: row)
        }

        tableScrollView.documentView = tableView

        tagFilterBar.isHidden = true
        tagFilterBar.onToggleTag = { [weak self] tag in
            self?.toggleTagFilter(tag)
        }
        tagFilterBar.onClearFilters = { [weak self] in
            self?.clearTagFilters()
        }

        let listContainer = LiquidGlassDesign.makeScrollFadeContainer(containing: tableScrollView)
        listContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        listContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        buildListEmptyState(in: listContainer)

        let preferredSidebarTableHeight = listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        preferredSidebarTableHeight.priority = .defaultLow
        preferredSidebarTableHeight.isActive = true

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedSnippet)
        deleteButton.image = LiquidGlassDesign.symbol("trash", pointSize: 13)
        deleteButton.imagePosition = .imageLeading
        if #available(macOS 26.0, *), !LiquidGlassDesign.forcesLegacyAppearance {
            deleteButton.bezelStyle = .glass
        } else {
            deleteButton.bezelStyle = .rounded
        }

        let footerTopRow = NSStackView(views: [deleteButton, NSView(), importExportMessageLabel])
        footerTopRow.orientation = .horizontal
        footerTopRow.spacing = 6
        footerTopRow.alignment = .centerY
        footerTopRow.setContentHuggingPriority(.required, for: .vertical)
        footerTopRow.setContentCompressionResistancePriority(.required, for: .vertical)

        importExportMessageLabel.font = .systemFont(ofSize: 12)
        importExportMessageLabel.textColor = .secondaryLabelColor
        importExportMessageLabel.alignment = .right
        importExportMessageLabel.lineBreakMode = .byTruncatingTail
        importExportMessageLabel.maximumNumberOfLines = 1
        importExportMessageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rootStack.addArrangedSubview(tagFilterBar)
        rootStack.addArrangedSubview(listContainer)
        rootStack.addArrangedSubview(footerTopRow)

        tagFilterBar.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        rootStack.setCustomSpacing(8, after: listContainer)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        let surface = LiquidGlassDesign.makeSidebarSurface(containing: contentView)
        container.addSubview(surface)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])

        return container
    }

    func buildEditor() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        let stack = editorStack
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        nameField.delegate = self
        // A demonstration rather than a sentence: with the field empty this
        // greys out the exact title the sidebar row will use, which is the rule
        // "first line is used if blank" shown instead of described.
        // `updateNameFieldPlaceholder` keeps it in step with the content.
        nameField.placeholderString = EditorCopy.namePlaceholderFallback
        nameField.controlSize = .large

        let snippetLabel = NSTextField(labelWithString: "Snippet")
        snippetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.alignment = .left

        // The lock lives on the section header, beside the word "Snippet", because that
        // is the thing it applies to. Reaching it through a menu was two clicks and a
        // modal for a state that is really just a property of the snippet.
        secureLockToggle.bezelStyle = .accessoryBarAction
        secureLockToggle.isBordered = false
        secureLockToggle.setButtonType(.toggle)
        secureLockToggle.imagePosition = .imageOnly
        secureLockToggle.image = NSImage(systemSymbolName: "lock", accessibilityDescription: "Make secure")
        secureLockToggle.alternateImage = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")
        secureLockToggle.contentTintColor = .secondaryLabelColor
        secureLockToggle.target = self
        secureLockToggle.action = #selector(toggleSelectedSnippetSecurity)
        secureLockToggle.keyEquivalent = "l"
        secureLockToggle.keyEquivalentModifierMask = [.control, .command]

        let snippetHeaderRow = NSStackView(views: [snippetLabel, NSView(), secureLockToggle])
        snippetHeaderRow.orientation = .horizontal
        snippetHeaderRow.alignment = .centerY
        snippetHeaderRow.spacing = 6

        secureCaptionLabel.font = .systemFont(ofSize: 11)
        secureCaptionLabel.textColor = .tertiaryLabelColor
        secureCaptionLabel.isHidden = true

        secureDemoteLabel.font = .systemFont(ofSize: 12)
        secureDemoteLabel.textColor = .labelColor
        let demoteConfirm = NSButton(
            title: "Make Ordinary", target: self, action: #selector(confirmDemoteSelectedSnippet))
        demoteConfirm.bezelStyle = NSButton.BezelStyle.rounded
        demoteConfirm.hasDestructiveAction = true
        let demoteCancel = NSButton(
            title: "Cancel", target: self, action: #selector(cancelDemoteConfirmation))
        demoteCancel.bezelStyle = NSButton.BezelStyle.rounded
        demoteCancel.keyEquivalent = "\u{1b}"
        secureDemoteStrip.orientation = .horizontal
        secureDemoteStrip.alignment = .centerY
        secureDemoteStrip.spacing = 8
        secureDemoteStrip.setViews([secureDemoteLabel, NSView(), demoteCancel, demoteConfirm], in: .leading)
        secureDemoteStrip.isHidden = true

        let snippetContainer = NSView()
        snippetContainer.translatesAutoresizingMaskIntoConstraints = false
        configureEditorSurface(snippetContainer, backgroundColor: .textBackgroundColor)

        let snippetScrollView = NSScrollView()
        snippetScrollView.translatesAutoresizingMaskIntoConstraints = false
        snippetScrollView.hasVerticalScroller = true
        snippetScrollView.hasHorizontalScroller = false
        snippetScrollView.borderType = .noBorder
        snippetScrollView.drawsBackground = false
        snippetScrollView.scrollerStyle = .overlay

        snippetTextView.delegate = self
        // "…the text this snippet expands to" was the app's whole mechanic
        // restated in its most prominent spot on every new snippet forever, and
        // three wrapped lines of grey at a narrow width. The "Snippet" label
        // beside the box already names the field.
        snippetTextView.emptyStatePrompt = "Paste or type"
        snippetTextView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        snippetTextView.textColor = .textColor
        snippetTextView.drawsBackground = false
        snippetTextView.isRichText = false
        snippetTextView.isAutomaticQuoteSubstitutionEnabled = false
        snippetTextView.isAutomaticTextReplacementEnabled = false
        snippetTextView.isAutomaticDataDetectionEnabled = false
        snippetTextView.allowsUndo = true
        snippetTextView.isHorizontallyResizable = false
        snippetTextView.autoresizingMask = [.width]
        // Zero, not 220. `minSize` is NSTextView's own floor and Auto Layout
        // cannot see it, so leaving it at 220 would not stop the box shrinking —
        // it would only put a 220pt document inside an 84pt viewport the first
        // time anything called `sizeToFit()`, i.e. an inner scroller over 136pt
        // of nothing.
        snippetTextView.minSize = NSSize(width: 0, height: 0)
        snippetTextView.isVerticallyResizable = true
        snippetTextView.textContainerInset = NSSize(width: 8, height: 8)
        snippetTextView.textContainer?.widthTracksTextView = true
        snippetTextView.textContainer?.lineBreakMode = .byCharWrapping
        snippetTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        snippetScrollView.documentView = snippetTextView
        snippetContainer.addSubview(snippetScrollView)

        // Above the scroll view, filling the container. A full-bleed transparent button
        // sits behind the label so a click anywhere on the area unlocks — matching what
        // people instinctively do, which is click where the text should be.
        secureLockOverlay.translatesAutoresizingMaskIntoConstraints = false
        secureLockOverlay.wantsLayer = true
        secureLockOverlay.isHidden = true

        secureLockOverlayButton.title = ""
        secureLockOverlayButton.isBordered = false
        secureLockOverlayButton.bezelStyle = .shadowlessSquare
        secureLockOverlayButton.target = self
        secureLockOverlayButton.action = #selector(unlockFromEditorOverlay)
        secureLockOverlayButton.translatesAutoresizingMaskIntoConstraints = false
        // The box sizes the overlay, never the other way round — and a button
        // stretched across a container that has no intrinsic size of its own does
        // the opposite by default. Its hugging of 250 reads "no taller than one
        // button", which outranks both the box's preferred 220 (priority 200) and
        // the box's own hugging of 1, so the box sat on its 84pt floor at every
        // window height: measured 84 at a 430pt window and 84 at a 1000pt one,
        // against 132 and 686 for the same window before this overlay existed.
        // Hidden changes nothing — `isHidden` takes a view out of the *stack*, not
        // out of Auto Layout, so this held for ordinary snippets too.
        secureLockOverlayButton.setContentHuggingPriority(.init(1), for: .vertical)
        secureLockOverlayButton.setContentHuggingPriority(.init(1), for: .horizontal)
        secureLockOverlayButton.setContentCompressionResistancePriority(.init(1), for: .vertical)
        secureLockOverlayButton.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        secureLockOverlayLabel.font = .systemFont(ofSize: 13)
        secureLockOverlayLabel.textColor = .secondaryLabelColor
        secureLockOverlayLabel.alignment = .center
        secureLockOverlayLabel.translatesAutoresizingMaskIntoConstraints = false

        secureLockOverlay.addSubview(secureLockOverlayButton)
        secureLockOverlay.addSubview(secureLockOverlayLabel)
        snippetContainer.addSubview(secureLockOverlay)

        NSLayoutConstraint.activate([
            secureLockOverlay.leadingAnchor.constraint(equalTo: snippetContainer.leadingAnchor),
            secureLockOverlay.trailingAnchor.constraint(equalTo: snippetContainer.trailingAnchor),
            secureLockOverlay.topAnchor.constraint(equalTo: snippetContainer.topAnchor),
            secureLockOverlay.bottomAnchor.constraint(equalTo: snippetContainer.bottomAnchor),
            secureLockOverlayButton.leadingAnchor.constraint(equalTo: secureLockOverlay.leadingAnchor),
            secureLockOverlayButton.trailingAnchor.constraint(equalTo: secureLockOverlay.trailingAnchor),
            secureLockOverlayButton.topAnchor.constraint(equalTo: secureLockOverlay.topAnchor),
            secureLockOverlayButton.bottomAnchor.constraint(equalTo: secureLockOverlay.bottomAnchor),
            secureLockOverlayLabel.centerYAnchor.constraint(equalTo: secureLockOverlay.centerYAnchor),
            secureLockOverlayLabel.leadingAnchor.constraint(
                equalTo: secureLockOverlay.leadingAnchor, constant: 20),
            secureLockOverlayLabel.trailingAnchor.constraint(
                equalTo: secureLockOverlay.trailingAnchor, constant: -20),
        ])

        // Two floors, not one. The hard floor is what the box may never go below
        // at any window size; the preferred floor is what it asks for when there
        // is room, and is the first thing in the whole editor that the layout
        // gives up. A single required 220 is why Keyword sat on the window's
        // bottom edge and Name, Tags and Enabled went under the fold: the box
        // kept every point it had and the form's overflow went to the outer
        // scroller instead.
        snippetContainer.heightAnchor
            .constraint(greaterThanOrEqualToConstant: EditorVerticalMetrics.contentBoxMinimumHeight)
            .isActive = true

        let preferredContentBoxHeight = snippetContainer.heightAnchor
            .constraint(greaterThanOrEqualToConstant: EditorVerticalMetrics.contentBoxPreferredHeight)
        preferredContentBoxHeight.priority = EditorVerticalMetrics.contentBoxPreferredPriority
        preferredContentBoxHeight.isActive = true

        // The box is both the grower and the yielder: it takes the slack in a
        // tall window and gives it back first in a short one. It has no intrinsic
        // size, so these two state the intent rather than carry it — the explicit
        // constraints above and the viewport pull in `buildEditor` are the
        // mechanism.
        snippetContainer.setContentHuggingPriority(.init(1), for: .vertical)
        snippetContainer.setContentCompressionResistancePriority(.init(1), for: .vertical)

        NSLayoutConstraint.activate([
            snippetScrollView.leadingAnchor.constraint(equalTo: snippetContainer.leadingAnchor),
            snippetScrollView.trailingAnchor.constraint(equalTo: snippetContainer.trailingAnchor),
            snippetScrollView.topAnchor.constraint(equalTo: snippetContainer.topAnchor),
            snippetScrollView.bottomAnchor.constraint(equalTo: snippetContainer.bottomAnchor)
        ])

        keywordPrefixLabel.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        keywordPrefixLabel.textColor = .tertiaryLabelColor
        keywordPrefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        keywordPrefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        keywordField.delegate = self
        keywordField.placeholderString = "sig"
        keywordField.controlSize = .large

        // A keyword that cannot expand — empty, duplicated, or in a prefix
        // collision — says so through the field's own tooltip rather than a line
        // of prose under it. The sentence was permanent furniture for a state
        // most snippets are never in, and reserving its row left a gap under
        // every keyword that was perfectly fine.

        // This row does come and go — it exists only
        // while there is no keyword — so it collapses out of the stack rather
        // than reserving a gap under every snippet that already works.
        editorSuggestedKeywordsFlow.collapsedRowLimit = 1
        editorSuggestedKeywordsFlow.isHidden = true

        tagsField.delegate = self
        tagsField.placeholderString = "work, email"
        tagsField.controlSize = .large
        tagsField.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        tagsField.completionDelay = 0.2

        // Without a row limit the editor's chips cannot collapse, so eight
        // suggestions wrap to four rows at the narrow end and push Enabled off
        // screen on every new snippet. The filter bar has always had this.
        editorSuggestedTagsFlow.collapsedRowLimit = 1
        editorSuggestedTagsFlow.isHidden = true

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledStateChanged)
        enabledCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        let previewContainer = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        configureEditorSurface(previewContainer, backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08))

        previewValueField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        previewValueField.lineBreakMode = .byCharWrapping
        previewValueField.maximumNumberOfLines = 8
        previewValueField.allowsDefaultTighteningForTruncation = false
        previewValueField.translatesAutoresizingMaskIntoConstraints = false
        previewValueField.setContentCompressionResistancePriority(
            EditorVerticalMetrics.previewKeepsItsLinesPriority,
            for: .vertical
        )

        previewContainer.addSubview(previewValueField)

        NSLayoutConstraint.activate([
            previewValueField.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 10),
            previewValueField.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            previewValueField.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            previewValueField.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8)
        ])

        previewSectionStack.isHidden = true

        let keywordRow = NSStackView(views: [keywordPrefixLabel, keywordField])
        keywordRow.orientation = .horizontal
        keywordRow.spacing = 2
        keywordRow.alignment = .firstBaseline

        // Content leads: it is the only field a snippet cannot do without, and
        // the keyword follows because it is the only one that makes it fire.
        // Name, tags and the enabled toggle are all optional, so they sink.
        //
        // Keyword, Name, Tags must stay in this order: `editorNeighbor` in
        // ViewController+TextEditing.swift is a hand-wired tab loop that walks
        // exactly this sequence.
        // The lock is part of the Snippet header, so this section supplies its
        // own header row rather than asking EditorFormSection to make a label.
        let snippetSection = EditorFormSection(
            title: nil,
            fields: [
                snippetHeaderRow,
                snippetContainer,
                secureCaptionLabel,
                secureDemoteStrip,
            ],
            fieldSpacing: 8
        )
        snippetSection.fieldColumn.setCustomSpacing(10, after: snippetHeaderRow)
        // Reuses the stack the controller already holds, so `updatePreview` goes
        // on hiding one view and now collapses the label with it.
        let previewSection = EditorFormSection(
            title: "Preview",
            fields: [previewContainer],
            row: previewSectionStack
        )
        let keywordSection = EditorFormSection(
            title: "Keyword",
            fields: [keywordRow, editorSuggestedKeywordsFlow],
            fieldSpacing: 6
        )
        let nameSection = EditorFormSection(title: "Name", fields: [nameField])
        let tagsSection = EditorFormSection(
            title: "Tags",
            fields: [tagsField, editorSuggestedTagsFlow],
            fieldSpacing: 6
        )
        // No label of its own — the checkbox states a property rather than
        // filling a field, and its own title already says which.
        let enabledSection = EditorFormSection(
            title: nil,
            fields: [enabledCheckbox],
            pinsFieldWidths: false
        )

        editorSections = [
            snippetSection, previewSection, keywordSection,
            nameSection, tagsSection, enabledSection
        ]

        contentView.addSubview(stack)
        container.addSubview(scrollView)

        for section in editorSections {
            stack.addArrangedSubview(section.row)
            section.row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        previewContainer.heightAnchor.constraint(lessThanOrEqualToConstant: MainLayoutMetrics.previewMaxHeight).isActive = true
        let preferredEditorWidth = stack.widthAnchor.constraint(
            equalTo: contentView.widthAnchor,
            constant: -(MainLayoutMetrics.editorHorizontalPadding * 2)
        )
        preferredEditorWidth.isActive = true

        // The preview is a section that comes and goes, so it needs a wider gap
        // below it than the sections that are always there — otherwise its
        // arrival and departure shifts Keyword by the same amount as any other
        // row and it reads as part of the same block.
        stack.setCustomSpacing(16, after: previewSectionStack)

        // The active half of the vertical fix, and the half that is not obvious.
        // `contentView.height >= clipView.height` below only ever pushes the
        // document *up* — it is what lets the box grow into a tall window, and it
        // is also why lowering the box's floor on its own changes nothing at all:
        // nothing in this layout asked the form to fit its viewport, so an
        // optional floor is simply satisfied and the document grows instead.
        // This is the opposite pull: prefer a form that fits. It outranks the
        // box's preferred height, so the box compresses; every field's and
        // label's compression resistance outranks it, so none of them ever does;
        // and it is below `windowSizeStayPut`, so it can never resize the window
        // to get its way. When the form genuinely will not fit with the box on
        // its floor this constraint breaks — silently, which is what optional
        // means — and the outer scroller takes over as it always did.
        let editorFitsViewport = contentView.heightAnchor
            .constraint(equalTo: scrollView.contentView.heightAnchor)
        editorFitsViewport.priority = EditorVerticalMetrics.editorFitsViewportPriority
        editorFitsViewport.isActive = true

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // Greater-than, not equal. Pinning the document view's bottom to the
            // clip view's bottom forced them to the same height, so the editor
            // could never be taller than its viewport and therefore never
            // scrolled: measured at a 300pt window, the document, the clip and
            // the scroll view all reported 546pt and the scroller stayed hidden,
            // i.e. the bottom of the form was pushed off the window with nothing
            // offering it back. As an inequality the document still fills a tall
            // window — which is what lets the content box grow — and grows past a
            // short one, where the scroller appears. Measured after: document 564
            // against a 300pt clip, scrollable.
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MainLayoutMetrics.editorHorizontalPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -MainLayoutMetrics.editorHorizontalPadding),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        return container
    }

    func buildActionOverlay(in rootView: NSView) {
        actionOverlayView.translatesAutoresizingMaskIntoConstraints = false
        actionOverlayView.wantsLayer = true
        actionOverlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.07).cgColor
        actionOverlayView.isHidden = true
        actionOverlayView.onBackgroundClick = { [weak self] in
            self?.closeActionPanel()
        }

        actionPanelView.translatesAutoresizingMaskIntoConstraints = false

        // Not "Keyboard Shortcuts": the first two rows are `\keyword` and `{`,
        // which are typed syntax rather than keyboard shortcuts.
        let actionTitle = NSTextField(labelWithString: "Shortcuts")
        actionTitle.font = .actionPanelRoundedSystemFont(ofSize: 18, weight: .semibold)
        actionTitle.alignment = .center

        actionShortcutStack.orientation = .vertical
        actionShortcutStack.spacing = 2
        actionShortcutStack.translatesAutoresizingMaskIntoConstraints = false
        actionShortcutRows = ActionPanelContent.shortcuts.map { descriptor in
            let row = ActionShortcutRow(title: descriptor.title, shortcut: descriptor.shortcut)
            actionShortcutStack.addArrangedSubview(row)
            return (view: row, isEssential: descriptor.isEssential)
        }

        actionPanelTipLabel.font = .systemFont(ofSize: 11, weight: .medium)
        actionPanelTipLabel.textColor = .tertiaryLabelColor
        actionPanelTipLabel.alignment = .center

        let actionStack = NSStackView(views: [actionTitle, actionShortcutStack, actionPanelTipLabel])
        actionStack.orientation = .vertical
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        actionStack.setCustomSpacing(10, after: actionTitle)
        actionStack.setCustomSpacing(10, after: actionShortcutStack)

        [actionTitle, actionPanelTipLabel].forEach {
            $0.widthAnchor.constraint(equalTo: actionStack.widthAnchor).isActive = true
        }

        updateActionPanelShortcutVisibility(showAll: false)

        let panelContentView = NSView()
        panelContentView.translatesAutoresizingMaskIntoConstraints = false
        panelContentView.addSubview(actionStack)

        let actionSurface = LiquidGlassDesign.makeTransientSurface(
            containing: panelContentView,
            cornerRadius: LiquidGlassDesign.Metrics.panelCornerRadius,
            fallbackMaterial: .popover,
			tintColor: NSColor.darkGray.withAlphaComponent(0.1)
        )

        actionPanelView.addSubview(actionSurface)
        actionOverlayView.addSubview(actionPanelView)
        rootView.addSubview(actionOverlayView)

        let preferredActionPanelWidth = actionPanelView.widthAnchor.constraint(equalToConstant: 340)
        preferredActionPanelWidth.priority = .defaultHigh
        preferredActionPanelWidth.isActive = true

        NSLayoutConstraint.activate([
            actionOverlayView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            actionOverlayView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            actionOverlayView.topAnchor.constraint(equalTo: rootView.topAnchor),
            actionOverlayView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            actionPanelView.centerXAnchor.constraint(equalTo: actionOverlayView.centerXAnchor),
            actionPanelView.centerYAnchor.constraint(equalTo: actionOverlayView.centerYAnchor),
            actionPanelView.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            actionPanelView.leadingAnchor.constraint(greaterThanOrEqualTo: actionOverlayView.leadingAnchor, constant: 20),
            actionPanelView.trailingAnchor.constraint(lessThanOrEqualTo: actionOverlayView.trailingAnchor, constant: -20),

            actionSurface.leadingAnchor.constraint(equalTo: actionPanelView.leadingAnchor),
            actionSurface.trailingAnchor.constraint(equalTo: actionPanelView.trailingAnchor),
            actionSurface.topAnchor.constraint(equalTo: actionPanelView.topAnchor),
            actionSurface.bottomAnchor.constraint(equalTo: actionPanelView.bottomAnchor),

            actionStack.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor, constant: 16),
            actionStack.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -16),
            actionStack.topAnchor.constraint(equalTo: panelContentView.topAnchor, constant: 18),
            actionStack.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor, constant: -14)
        ])
    }

    func updateActionPanelShortcutVisibility(showAll: Bool) {
        for shortcutRow in actionShortcutRows {
            shortcutRow.view.isHidden = !showAll && !shortcutRow.isEssential
        }

        actionPanelTipLabel.stringValue = showAll ? ActionPanelContent.expandedTip : ActionPanelContent.compactTip
    }
}
