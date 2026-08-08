import AppKit

/// The sidebar gets out of the way when the window is too narrow to carry it and
/// a usable editor at the same time, and comes back when it is wide again —
/// without ever overruling ⌘B.
///
/// Three pieces of state, only one of them persisted:
///
/// - `userWantsSidebarCollapsed` — the stored preference, written by ⌘B and by
///   dragging the divider off the edge, and by nothing else.
/// - `isSidebarAutoCollapsed` — the sidebar is hidden because of the width. In
///   memory only; recomputed at launch from the restored window, which is both
///   simpler and right: a narrow window opens collapsed, a wide one does not,
///   and nothing is written either way.
/// - `isAutomaticSidebarCollapseSuppressed` — the user asked for the sidebar back
///   at a narrow width, so the rule stands down until they are wide again.
///
/// The rule reads the *window's* width. Reading the editor's would be a feedback
/// loop: collapsing moves the editor by 268pt instantly, so it would oscillate
/// across any threshold. Collapsing does not move the window at all.
///
/// Automatic transitions are deliberately not animated. AppKit does not offer a
/// way to cancel an in-flight `isCollapsed` animation, so a quick reversal can
/// let the older animation write its stale end state last. A direct assignment
/// makes every resize notification settle synchronously. The user's explicit
/// ⌘B transition remains animated in `toggleSidebarAnimated`.
extension ViewController {
    func observeWindowResizeForAdaptiveSidebar(_ window: NSWindow) {
        guard !hasObservedWindowResize else { return }
        hasObservedWindowResize = true

        // The window's notification, not the split view's: on a 1000 -> 600
        // resize `NSSplitView.didResizeSubviewsNotification` fires twice, and on
        // the first firing the window still reads its old width — a rule
        // evaluated there against the window width silently never fires.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleWindowDidResizeForSidebar),
            name: NSWindow.didResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidEndLiveResize),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    @objc func handleWindowDidEndLiveResize() {
        // A drag that ended inside the band, or that outran the notifications,
        // settles here against the width the window actually finished at.
        evaluateAutomaticSidebarCollapse()
    }

    @objc func handleWindowDidResizeForSidebar() {
        evaluateAutomaticSidebarCollapse()
    }

    /// The width the rule is keyed off: the window's, not the split view's.
    ///
    /// The split view's bounds lag a resize by a layout pass, so a rule keyed off
    /// them reads the width the window just *left* — which made the first window
    /// open collapsed at 1000pt (the split view had not laid out yet) and made a
    /// widen arriving at the tail of a collapse animation see the old narrow
    /// width and decline to reverse it. The window's content rect is correct the
    /// instant the notification fires, and it is what the whole design says this
    /// reads: collapsing moves the editor 268pt in a step but does not move the
    /// window at all, so only the window's width is free of feedback.
    var adaptiveSidebarReferenceWidth: CGFloat {
        if let windowWidth = view.window?.contentLayoutRect.width, windowWidth.isFinite, windowWidth > 0 {
            return windowWidth
        }
        let splitWidth = mainSplitView.bounds.width
        return splitWidth.isFinite && splitWidth > 0 ? splitWidth : 0
    }

    func evaluateAutomaticSidebarCollapse() {
        guard let sidebarItem = mainSidebarSplitItem else { return }

        let width = adaptiveSidebarReferenceWidth
        guard width > 0 else { return }

        // ⌘B wins at every width. Nothing below this line runs while the user's
        // own answer is "hidden".
        guard !userWantsSidebarCollapsed else {
            isSidebarAutoCollapsed = false
            return
        }

        if width >= MainLayoutMetrics.sidebarAutoExpandWidth {
            isAutomaticSidebarCollapseSuppressed = false

            guard isSidebarAutoCollapsed else { return }
            // Only give up ownership if a transition actually happens.
            if applyAutomaticSidebarCollapse(false, on: sidebarItem) {
                isSidebarAutoCollapsed = false
            }
            return
        }

        guard width < MainLayoutMetrics.sidebarAutoCollapseWidth else { return }
        guard !isSidebarAutoCollapsed, !isAutomaticSidebarCollapseSuppressed else { return }
        // Already hidden by hand — by a divider dragged off the edge, say. Taking
        // ownership of that would mean re-showing it at the expand width on the
        // user's behalf, which is a decision they did not ask for.
        guard !sidebarItem.isCollapsed else { return }

        if applyAutomaticSidebarCollapse(true, on: sidebarItem) {
            isSidebarAutoCollapsed = true
        }
    }

    /// Returns whether the state actually changed. The caller keys
    /// `isSidebarAutoCollapsed` off it, so ownership can never be handed over for
    /// a move that did not happen. This path must stay synchronous: animating
    /// `isCollapsed` allows an older, uncancellable animation to overwrite a
    /// newer answer after a quick threshold reversal.
    @discardableResult
    private func applyAutomaticSidebarCollapse(
        _ collapsed: Bool,
        on sidebarItem: NSSplitViewItem
    ) -> Bool {
        guard sidebarItem.isCollapsed != collapsed else { return false }

        // Focus is touched only when the collapse would otherwise destroy it.
        // AppKit does not relocate a first responder inside a collapsing sidebar,
        // it drops it on the window — but doing what ⌘B does is too much: this is
        // not a user action, and moving the caret because someone dragged a
        // window edge is a non-sequitur. The search field is a toolbar item, not
        // a sidebar view, so it survives and must not be stolen from.
        let shouldRescueFocus = collapsed && isFirstResponderInsideSidebar(sidebarItem)

        isApplyingAutomaticSidebarCollapse = true
        sidebarItem.isCollapsed = collapsed
        view.layoutSubtreeIfNeeded()
        isApplyingAutomaticSidebarCollapse = false

        restoreMainSplitViewDividerIfNeeded()
        // The editor's width moves by 268pt, and this maintains the text view's
        // wrapping width by hand.
        updateSnippetTextViewWrappingWidth()
        // Not `hideSearchSuggestionOverlay`, which is what ⌘B calls.
        // `shouldShowSearchSuggestionOverlay` requires a collapsed sidebar, so
        // collapsing is precisely when the overlay should appear.
        updateSearchSuggestionOverlay()
        // The status message lives in the sidebar footer while the sidebar is
        // there and in an overlay while it is not, and it picks which at the
        // moment the message is set.
        refreshStatusMessagePresentation()
        if shouldRescueFocus {
            focusEditorAfterSidebarWentAway()
        }
        return true
    }

    private func isFirstResponderInsideSidebar(_ sidebarItem: NSSplitViewItem) -> Bool {
        guard let responderView = view.window?.firstResponder as? NSView else { return false }
        let sidebarView = sidebarItem.viewController.view

        if responderView.isDescendant(of: sidebarView) { return true }
        // A field editor can be reparented out of the field it edits; the field
        // is its delegate either way.
        if let textView = responderView as? NSTextView,
           let delegateView = textView.delegate as? NSView {
            return delegateView.isDescendant(of: sidebarView)
        }
        return false
    }

    /// Deliberately not `focusEditorAfterCollapsingSidebar`, which ⌘B uses: that
    /// one also hides the search-suggestion overlay, and an automatic collapse is
    /// exactly when the overlay should be appearing.
    private func focusEditorAfterSidebarWentAway() {
        guard let window = view.window else { return }
        let target: NSResponder = selectedSnippetID == nil ? view : snippetTextView
        window.makeFirstResponder(target)
    }
}
