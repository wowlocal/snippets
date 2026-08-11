import AppKit

extension ViewController: NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSTokenFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field == searchField {
            reloadVisibleSnippetsForSearch()
            updateSearchSuggestionOverlay()
            return
        }

        if field == nameField || field == keywordField || field == tagsField {
            updateSelectedSnippetFromEditor()
        }
    }

    /// The content editor gets its own undo manager — see `snippetContentUndoManager`.
    func undoManager(for view: NSTextView) -> UndoManager? {
        view === snippetTextView ? snippetContentUndoManager : nil
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === snippetTextView else { return }
        updateSelectedSnippetFromEditor()
    }

    /// The placeholder vocabulary, offered where it is used. `{` in the content
    /// editor calls `complete(nil)` and this answers it; `rangeForUserCompletion`
    /// on the text view is what makes `charRange` start at the brace, so the
    /// chosen token replaces it rather than landing beside it.
    func textView(
        _ textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
        guard textView === snippetTextView else { return words }

        let text = textView.string as NSString
        guard charRange.location + charRange.length <= text.length else { return words }
        let partial = text.substring(with: charRange)
        guard partial.hasPrefix("{") else { return words }

        let matches = PlaceholderResolver.completionTokens.filter { $0.hasPrefix(partial) }
        // Preselected, so Return takes the obvious one and Escape backs out.
        index?.pointee = matches.isEmpty ? -1 : 0
        return matches
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
                // Force it: the field editor is still installed and still the
                // window's first responder at this point, so the reload above
                // takes the skip-while-typing path and leaves the bar stale.
                refreshTagFilterBar()
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
        // A token is committed here — by the tokenizing comma, a picked
        // completion, or a paste. The tokens aren't in the field yet, so publish
        // them to the sidebar filter bar on the next tick, once the field (and
        // therefore the store) has them. Without this the new tag stays
        // invisible until focus leaves the field. (Trailing text typed without
        // a comma is not tokenized through here — controlTextDidEndEditing
        // picks that up instead.)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateSelectedSnippetFromEditor()
            refreshTagFilterBar()
        }

        return SnippetTagging.normalizedTags(tokens.compactMap { $0 as? String })
    }

    // MARK: - Editor key loop

    /// Explicit tab order for the editor: Snippet → Keyword → Name → Tags, and
    /// back again with Shift-Tab. AppKit's automatic key view loop is recomputed
    /// whenever the suggested-tag chips or the filter bar rebuild their
    /// subviews, which kept dropping the multi-line snippet view out of the
    /// loop, so the hops are wired by hand instead.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let forward = tabDirection(for: commandSelector),
              let next = editorNeighbor(of: control, forward: forward) else { return false }

        moveFocus(to: next)
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === snippetTextView,
              let forward = tabDirection(for: commandSelector),
              let next = editorNeighbor(of: textView, forward: forward) else { return false }

        // ⌥⇥ still inserts a literal tab (insertTabIgnoringFieldEditor:).
        // Backwards this hop leaves the editor for the list, which is the same
        // abandonment Escape is, so it goes through the same helper.
        moveFocus(to: next)
        return true
    }

    private func tabDirection(for commandSelector: Selector) -> Bool? {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)): return true
        case #selector(NSResponder.insertBacktab(_:)): return false
        default: return nil
        }
    }

    private func editorNeighbor(of responder: NSResponder, forward: Bool) -> NSResponder? {
        if responder === snippetTextView {
            // Shift-Tab out of the first field leaves the editor for the list,
            // the same exit Escape takes. Without it the loop is closed and
            // Escape is the only way out of it.
            return forward ? keywordField : tableView
        }
        if responder === keywordField {
            return forward ? nameField : snippetTextView
        }
        if responder === nameField {
            return forward ? tagsField : keywordField
        }
        if responder === tagsField {
            return forward ? snippetTextView : nameField
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
