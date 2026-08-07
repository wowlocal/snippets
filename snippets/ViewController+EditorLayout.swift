import AppKit

extension ViewController {
    /// Re-decides the editor's shape from the editor pane's current width.
    ///
    /// Safe to call as often as anything wants to: everything downstream of the
    /// mode compare is skipped when the mode has not changed, which is 99 calls
    /// in 100 during a divider drag. That is why there is no debounce — a timer
    /// would only put lag between the divider and the form, and would need
    /// cancelling on close.
    func updateEditorLayoutMode() {
        guard let pane = editorPaneContainer else { return }

        // The pane's safe-area width, because that is what the editor scroll
        // view is pinned to (`buildEditor` pins it to the same guide), and
        // because it is the one value upstream of the scroll view — so a
        // scroller appearing as a result of the flip cannot feed back into the
        // decision that caused it.
        let guideWidth = pane.safeAreaLayoutGuide.frame.width
        let paneWidth = guideWidth > 1 ? guideWidth : pane.bounds.width
        guard paneWidth.isFinite, paneWidth > 1 else { return }

        applyEditorLayout(editorLayoutMode(forPaneWidth: paneWidth))
    }

    private func editorLayoutMode(forPaneWidth width: CGFloat) -> EditorLayoutMode {
        // Separate enter and exit thresholds. Parked inside the band the mode
        // depends on which side it was approached from, which is the point of
        // hysteresis: without it, a divider resting on the threshold flips the
        // whole form on every pixel of travel.
        switch currentEditorLayoutMode {
        case .stacked:
            return width >= MainLayoutMetrics.editorWideLayoutEnterWidth ? .wide : .stacked
        case .wide:
            return width < MainLayoutMetrics.editorWideLayoutExitWidth ? .stacked : .wide
        }
    }

    func applyEditorLayout(_ mode: EditorLayoutMode) {
        guard !editorSections.isEmpty else { return }
        guard mode != currentEditorLayoutMode || !hasAppliedEditorLayout else { return }

        // Set first, then touch constraints: the constraint churn lays out,
        // which can post the very frame notification that called in here, and
        // this makes that re-entry a Bool compare that returns immediately.
        currentEditorLayoutMode = mode
        hasAppliedEditorLayout = true

        for section in editorSections {
            section.applyLayout(mode)
        }

        // Nothing is re-parented by a flip — each section owns the same two
        // children for its whole life — so there is no first-responder or tab
        // loop to repair here, and no reason to defer the flip while a field
        // editor is installed. The content text view's manual wrapping width is
        // the one thing that does not follow from constraints alone.
        updateSnippetTextViewWrappingWidth()
    }

    @objc
    func handleEditorPaneFrameChanged(_ notification: Notification) {
        updateEditorLayoutMode()
    }
}
