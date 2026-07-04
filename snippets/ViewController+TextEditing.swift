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

    func textDidBeginEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === snippetTextView else { return }
        store.beginEditTransaction()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === snippetTextView else { return }
        store.commitEditTransaction()
    }
}
