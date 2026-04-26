import AppKit

extension ViewController: NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
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

        if field == nameField || field == keywordField {
            updateSelectedSnippetFromEditor()
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === snippetTextView else { return }
        updateSelectedSnippetFromEditor()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as? NSTextField == searchField else { return }
        updateSearchSuggestionOverlay()
        DispatchQueue.main.async { [weak self] in
            self?.updateSearchSuggestionOverlay()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField == searchField else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !searchSuggestionOverlayView.containsFirstResponder(in: view.window) {
                hideSearchSuggestionOverlay()
            }
        }
    }
}
