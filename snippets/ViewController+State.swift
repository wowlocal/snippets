import AppKit

extension ViewController {
    func updatePermissionBanner() {
        if engine.accessibilityGranted {
            permissionBannerContainer.isHidden = true
            permissionBannerDivider.isHidden = true
        } else {
            permissionBannerContainer.isHidden = false
            permissionBannerDivider.isHidden = false
            permissionIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            permissionIconView.contentTintColor = .systemOrange
            permissionTitleLabel.stringValue = "Permissions Required"
            permissionTitleLabel.textColor = .systemOrange
            permissionButtonsStack.isHidden = false
            permissionStatusLabel.stringValue = engine.statusText
        }
    }

    func reloadVisibleSnippets(keepSelection: Bool) {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let sorted = store.snippetsSortedForDisplay()
        if query.isEmpty {
            visibleSnippets = sorted
        } else {
            visibleSnippets = sorted.filter { snippet in
                snippet.displayName.lowercased().contains(query)
                    || snippet.normalizedKeyword.lowercased().contains(query)
                    || snippet.content.lowercased().contains(query)
            }
        }

        if !keepSelection {
            selectedSnippetID = visibleSnippets.first?.id
        } else if let selectedSnippetID, !visibleSnippets.contains(where: { $0.id == selectedSnippetID }) {
            self.selectedSnippetID = visibleSnippets.first?.id
        }

        tableView.reloadData()
        syncTableSelectionWithSelectedSnippet()
        updateActionPanelPinLabel()
        deleteButton.isEnabled = selectedSnippetID != nil
    }

    func syncTableSelectionWithSelectedSnippet() {
        guard let selectedSnippetID,
              let row = visibleSnippets.firstIndex(where: { $0.id == selectedSnippetID }) else {
            if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
            return
        }

        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    func applySelectedSnippetToEditor() {
        guard let snippet = selectedSnippet else {
            isApplyingSnippetToEditor = true
            nameField.stringValue = ""
            snippetTextView.string = ""
            keywordField.stringValue = ""
            enabledCheckbox.state = .off
            updatePreview(withTemplate: "")
            setEditorEnabled(false)
            isApplyingSnippetToEditor = false
            return
        }

        isApplyingSnippetToEditor = true
        nameField.stringValue = snippet.name
        snippetTextView.string = snippet.content
        keywordField.stringValue = snippet.normalizedKeyword
        enabledCheckbox.state = snippet.isEnabled ? .on : .off
        updatePreview(withTemplate: snippet.content)
        setEditorEnabled(true)
        isApplyingSnippetToEditor = false
    }

    func setEditorEnabled(_ enabled: Bool) {
        nameField.isEnabled = enabled
        snippetTextView.isEditable = enabled
        keywordField.isEnabled = enabled
        enabledCheckbox.isEnabled = enabled
    }

    var selectedSnippet: Snippet? {
        guard let selectedSnippetID else { return nil }
        return store.snippet(id: selectedSnippetID)
    }

    func updateSelectedSnippetFromEditor() {
        guard !isApplyingSnippetToEditor, var snippet = selectedSnippet else { return }

        snippet.name = nameField.stringValue
        snippet.content = snippetTextView.string

        let sanitizedKeyword = keywordField.stringValue.replacingOccurrences(of: " ", with: "")
        if sanitizedKeyword != keywordField.stringValue {
            keywordField.stringValue = sanitizedKeyword
        }
        snippet.keyword = sanitizedKeyword

        snippet.isEnabled = enabledCheckbox.state == .on

        store.update(snippet)
        updatePreview(withTemplate: snippet.content)
    }

    func updatePreview(withTemplate template: String) {
        let rendered = PlaceholderResolver.resolve(template: template)
        let hasDynamicContent = !template.isEmpty && rendered != template
        previewSectionStack.isHidden = !hasDynamicContent
        previewValueField.stringValue = rendered
    }

    var isEditingDetails: Bool {
        guard let firstResponder = view.window?.firstResponder else { return false }
        if firstResponder === snippetTextView {
            return true
        }
        if firstResponder === nameField.currentEditor() || firstResponder === keywordField.currentEditor() {
            return true
        }
        return false
    }
}
