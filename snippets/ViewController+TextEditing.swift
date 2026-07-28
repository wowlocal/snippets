import AppKit

extension ViewController: NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSTokenFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field == searchField {
            reloadVisibleSnippets(keepSelection: true)
            if selectedSnippetID == nil, let firstID = visibleSnippets.first?.id {
                selectSnippet(id: firstID, focusEditorName: false)
            }
            updateSearchSuggestionOverlay()
            return
        }

        if field == nameField || field == keywordField || field == tagsField {
            updateSelectedSnippetFromEditor()
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === snippetTextView else { return }
        updateSelectedSnippetFromEditor()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field == searchField {
            updateSearchSuggestionOverlay()
            DispatchQueue.main.async { [weak self] in
                self?.updateSearchSuggestionOverlay()
            }
        } else if field == nameField || field == keywordField || field == tagsField {
            store.beginEditTransaction()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field == searchField {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !searchSuggestionOverlayView.containsFirstResponder(in: view.window) {
                    hideSearchSuggestionOverlay()
                }
            }
        } else if field == nameField || field == keywordField || field == tagsField {
            if field == tagsField {
                // The trailing token is only finalized when editing ends, so
                // re-read the field before committing the transaction.
                updateSelectedSnippetFromEditor()
            }
            store.commitEditTransaction()
            if field == tagsField {
                reloadVisibleSnippets(keepSelection: true)
            }
        }
    }

    func tokenField(
        _ tokenField: NSTokenField,
        completionsForSubstring substring: String,
        indexOfToken tokenIndex: Int,
        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
    ) -> [Any]? {
        let key = SnippetTagging.filterKey(for: substring)
        guard !key.isEmpty else { return [] }

        let editorTagKeys = Set(tagsFromEditor().map { SnippetTagging.filterKey(for: $0) })
        return store.allTags().filter { tag in
            let tagKey = SnippetTagging.filterKey(for: tag)
            return tagKey.hasPrefix(key) && !editorTagKeys.contains(tagKey)
        }
    }

    func tokenField(
        _ tokenField: NSTokenField,
        shouldAdd tokens: [Any],
        at index: Int
    ) -> [Any] {
        SnippetTagging.normalizedTags(tokens.compactMap { $0 as? String })
    }

    // MARK: - Editor key loop

    /// Explicit tab order for the editor: Name → Keyword → Tags → Snippet, and
    /// back again with Shift-Tab. AppKit's automatic key view loop is recomputed
    /// whenever the suggested-tag chips or the filter bar rebuild their
    /// subviews, which kept dropping the multi-line snippet view out of the
    /// loop, so the hops are wired by hand instead.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let forward = tabDirection(for: commandSelector),
              let next = editorNeighbor(of: control, forward: forward) else { return false }

        requestFirstResponder(next)
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === snippetTextView,
              let forward = tabDirection(for: commandSelector) else { return false }

        // ⌥⇥ still inserts a literal tab (insertTabIgnoringFieldEditor:).
        requestFirstResponder(forward ? nameField : tagsField)
        return true
    }

    private func tabDirection(for commandSelector: Selector) -> Bool? {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)): return true
        case #selector(NSResponder.insertBacktab(_:)): return false
        default: return nil
        }
    }

    private func editorNeighbor(of control: NSControl, forward: Bool) -> NSResponder? {
        if control === nameField {
            return forward ? keywordField : snippetTextView
        }
        if control === keywordField {
            return forward ? tagsField : nameField
        }
        if control === tagsField {
            return forward ? snippetTextView : keywordField
        }
        return nil
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === snippetTextView else { return }
        store.beginEditTransaction()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === snippetTextView else { return }
        store.commitEditTransaction()
    }
}
