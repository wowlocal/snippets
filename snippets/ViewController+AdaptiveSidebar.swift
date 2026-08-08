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
            selector: #selector(handleWindowWillStartLiveResize),
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidEndLiveResize),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    @objc func handleWindowWillStartLiveResize() {
        isWindowInLiveResize = true
    }

    @objc func handleWindowDidEndLiveResize() {
        isWindowInLiveResize = false
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

    func evaluateAutomaticSidebarCollapse(animated: Bool? = nil) {
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
            // Only give up ownership if a transition actually starts. Clearing it
            // first meant a widen that arrived before the collapse had committed
            // found nothing to reverse, cleared the flag anyway, and left a
            // sidebar that was collapsed and that nothing was allowed to reopen.
            if applyAutomaticSidebarCollapse(false, on: sidebarItem, animated: animated) {
                isSidebarAutoCollapsed = false
            }
            return
        }

        guard width < MainLayoutMetrics.sidebarAutoCollapseWidth else { return }
        guard !isSidebarAutoCollapsed, !isAutomaticSidebarCollapseSuppressed else { return }
        // Already hidden by hand — by a divider dragged off the edge, say. Taking
        // ownership of that would mean re-showing it at the expand width on the
        // user's behalf, which is a decision they did not ask for.
        guard !currentSidebarCollapseTarget(sidebarItem) else { return }

        if applyAutomaticSidebarCollapse(true, on: sidebarItem, animated: animated) {
            isSidebarAutoCollapsed = true
        }
    }

    /// Where the sidebar is *going*, not where it is.
    ///
    /// `NSSplitViewItem.isCollapsed` still reads the old value while an animation
    /// is in flight, so asking it mid-transition says "already false" and makes a
    /// reversal a no-op — which is how widening the window 240ms into a collapse
    /// used to leave the sidebar hidden at a wide window, permanently.
    private func currentSidebarCollapseTarget(_ sidebarItem: NSSplitViewItem) -> Bool {
        sidebarTransitionTarget ?? sidebarItem.isCollapsed
    }

    /// Returns whether a transition was actually started. The caller keys
    /// `isSidebarAutoCollapsed` off it, so ownership can never be handed over for
    /// a move that did not happen.
    @discardableResult
    private func applyAutomaticSidebarCollapse(
        _ collapsed: Bool,
        on sidebarItem: NSSplitViewItem,
        animated: Bool?
    ) -> Bool {
        guard currentSidebarCollapseTarget(sidebarItem) != collapsed else { return false }

        // Focus is touched only when the collapse would otherwise destroy it.
        // AppKit does not relocate a first responder inside a collapsing sidebar,
        // it drops it on the window — but doing what ⌘B does is too much: this is
        // not a user action, and moving the caret because someone dragged a
        // window edge is a non-sequitur. The search field is a toolbar item, not
        // a sidebar view, so it survives and must not be stolen from.
        let shouldRescueFocus = collapsed && isFirstResponderInsideSidebar(sidebarItem)

        // During a real drag, no animation: a 268pt pane sliding against a resize
        // already in flight is the worst version of this, and a hard cut reads as
        // the sidebar being pushed off the edge, which is what is happening.
        let shouldAnimate = animated ?? !(isWindowInLiveResize || view.window?.inLiveResize == true)

        sidebarTransitionTarget = collapsed
        sidebarTransitionGeneration &+= 1
        let generation = sidebarTransitionGeneration
        isApplyingAutomaticSidebarCollapse = true

        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // A newer transition overtook this one — it owns the end state and
            // the flags now. Without this, the completion of a collapse that was
            // reversed mid-flight would land after the reversal and undo it.
            guard sidebarTransitionGeneration == generation else { return }

            sidebarTransitionTarget = nil
            isApplyingAutomaticSidebarCollapse = false
            view.layoutSubtreeIfNeeded()
            restoreMainSplitViewDividerIfNeeded()
            // After the transition settles, never at its start: the editor's
            // width moves by 268pt and this maintains the text view's wrapping
            // width by hand.
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
            // The window may have kept moving while this ran. Cheap: everything
            // below the first guard is skipped when the answer has not changed.
            evaluateAutomaticSidebarCollapse()
        }

        guard shouldAnimate else {
            sidebarItem.isCollapsed = collapsed
            finish()
            return true
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed = collapsed
        } completionHandler: {
            Task { @MainActor in finish() }
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
