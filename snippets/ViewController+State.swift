import AppKit

private enum TagFilterDefaults {
    static let activeKeysKey = "snippetsActiveTagFilterKeys"
}

private enum ListUpdateAnimation {
    static let maxAnimatedChanges = 40
}

extension ViewController {
    func updatePermissionBanner() {
        if engine.accessibilityGranted {
            permissionBannerContainer.isHidden = true
            permissionBannerDivider.isHidden = true
        } else {
            permissionBannerContainer.isHidden = false
            permissionBannerDivider.isHidden = false
            permissionIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            permissionIconView.contentTintColor = ThemeManager.alertColor
            permissionTitleLabel.stringValue = "Permissions Required"
            permissionTitleLabel.textColor = ThemeManager.alertColor
            permissionButtonsStack.isHidden = false
            permissionStatusLabel.stringValue = engine.statusText
        }
    }

    func reloadVisibleSnippets(keepSelection: Bool) {
        if editorListReloadWorkItem != nil {
            cancelEditorListReload()
        }

        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        pruneStaleTagFilters()
        updateTagFilterBar()

        let sorted = store.snippetsSortedForDisplay()
        var newSnippets: [Snippet]
        if query.isEmpty {
            newSnippets = sorted
        } else {
            newSnippets = sorted.filter { snippet in
                snippet.displayName.lowercased().contains(query)
                    || snippet.normalizedKeyword.lowercased().contains(query)
                    || snippet.content.lowercased().contains(query)
                    || snippet.tags.contains { $0.lowercased().contains(query) }
            }
        }

        if !activeTagFilterKeys.isEmpty {
            newSnippets = newSnippets.filter { snippet in
                activeTagFilterKeys.allSatisfy { snippet.hasTag(withKey: $0) }
            }
        }

        if !keepSelection {
            selectedSnippetID = newSnippets.first?.id
        } else if let selectedSnippetID, !newSnippets.contains(where: { $0.id == selectedSnippetID }) {
            // If the user is live-editing the selected snippet and it merely
            // fell out of the current filter/search (e.g. rename-while-
            // searching), keep the editor bound to it instead of yanking the
            // selection to another snippet mid-typing.
            let keepEditingHiddenSnippet = isEditingDetails
                && editingSnippetID == selectedSnippetID
                && store.snippet(id: selectedSnippetID) != nil
            if !keepEditingHiddenSnippet {
                self.selectedSnippetID = newSnippets.first?.id
            }
        }

        let oldIDs = visibleSnippets.map(\.id)
        let newIDs = newSnippets.map(\.id)
        visibleSnippets = newSnippets

        if oldIDs == newIDs {
            reconfigureVisibleRows()
        } else {
            applyAnimatedListUpdate(oldIDs: oldIDs, newIDs: newIDs)
        }

        updateListEmptyState(query: query)
        syncTableSelectionWithSelectedSnippet()
        deleteButton.isEnabled = selectedSnippetID != nil
        updateSearchSuggestionOverlay()
    }

    private func reconfigureVisibleRows() {
        for row in 0..<visibleSnippets.count {
            if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SnippetRowCellView {
                cellView.configure(with: visibleSnippets[row])
            }
        }
    }

    /// Applies filtered/search list changes with a fade so rows don't pop in
    /// and out abruptly. Falls back to a plain reload for large changes.
    private func applyAnimatedListUpdate(oldIDs: [UUID], newIDs: [UUID]) {
        // Suppress selection delegate callbacks for the whole update
        // (including the reloadData fallback): removing the selected row
        // fires tableViewSelectionDidChange synchronously mid-batch.
        isApplyingListUpdate = true
        defer { isApplyingListUpdate = false }

        let diff = newIDs.difference(from: oldIDs)
        guard !oldIDs.isEmpty, diff.count <= ListUpdateAnimation.maxAnimatedChanges, view.window != nil else {
            tableView.reloadData()
            return
        }

        tableView.beginUpdates()
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                tableView.removeRows(at: IndexSet(integer: offset), withAnimation: .effectFade)
            case .insert(let offset, _, _):
                tableView.insertRows(at: IndexSet(integer: offset), withAnimation: .effectFade)
            }
        }
        tableView.endUpdates()
        reconfigureVisibleRows()
    }

    private func updateListEmptyState(query: String) {
        guard visibleSnippets.isEmpty else {
            listEmptyStateView.isHidden = true
            return
        }

        let isSearching = !query.isEmpty
        let isFiltering = !activeTagFilterKeys.isEmpty
        let iconName: String
        let message: String

        if store.snippets.isEmpty {
            iconName = "square.dashed"
            message = "No snippets yet.\nPress ⌘N to create one."
        } else if isSearching && isFiltering {
            iconName = "magnifyingglass"
            message = "No results for “\(searchField.stringValue)”\nwith the selected tags."
        } else if isSearching {
            iconName = "magnifyingglass"
            message = "No results for “\(searchField.stringValue)”."
        } else if isFiltering {
            iconName = "tag"
            message = "No snippets match\nthe selected tags."
        } else {
            listEmptyStateView.isHidden = true
            return
        }

        listEmptyStateIconView.image = LiquidGlassDesign.symbol(iconName, pointSize: 24, weight: .regular)
        listEmptyStateLabel.stringValue = message
        listEmptyStateClearButton.isHidden = !isFiltering
        listEmptyStateView.isHidden = false
    }

    func toggleTagFilter(_ tag: String) {
        let key = SnippetTagging.filterKey(for: tag)
        if activeTagFilterKeys.contains(key) {
            activeTagFilterKeys.remove(key)
        } else {
            activeTagFilterKeys.insert(key)
        }
        persistTagFilters()

        reloadVisibleSnippets(keepSelection: true)
        if !isEditingDetails {
            applySelectedSnippetToEditor()
        }
    }

    func clearTagFilters() {
        guard !activeTagFilterKeys.isEmpty else { return }
        activeTagFilterKeys.removeAll()
        persistTagFilters()

        reloadVisibleSnippets(keepSelection: true)
        if !isEditingDetails {
            applySelectedSnippetToEditor()
        }
    }

    func loadPersistedTagFilters() {
        let saved = UserDefaults.standard.stringArray(forKey: TagFilterDefaults.activeKeysKey) ?? []
        activeTagFilterKeys = Set(saved)
    }

    private func persistTagFilters() {
        UserDefaults.standard.set(Array(activeTagFilterKeys).sorted(), forKey: TagFilterDefaults.activeKeysKey)
    }

    private func pruneStaleTagFilters() {
        guard !activeTagFilterKeys.isEmpty else { return }
        // Live editing transiently rewrites the edited snippet's tags (e.g.
        // tags = [] while a token is being retyped); pruning during the
        // debounced reload would permanently drop and persist an active
        // filter the user is about to restore. The controlTextDidEndEditing
        // reload prunes once editing is done.
        guard !isEditingDetails else { return }
        let existingKeys = Set(store.allTags().map { SnippetTagging.filterKey(for: $0) })
        let pruned = activeTagFilterKeys.intersection(existingKeys)
        if pruned != activeTagFilterKeys {
            activeTagFilterKeys = pruned
            persistTagFilters()
        }
    }

    private func updateTagFilterBar() {
        // Skip while the user is typing tags so the bar doesn't churn with
        // partial tokens; controlTextDidEndEditing refreshes it afterwards.
        // (Both sides can be nil — e.g. at viewDidLoad — which must NOT skip.)
        if let editor = tagsField.currentEditor(), view.window?.firstResponder === editor {
            return
        }

        let items = store.tagUsage().map { TagFilterBarView.Item(tag: $0.tag, count: $0.count) }
        tagFilterBar.isHidden = items.isEmpty
        tagFilterBar.update(items: items, activeKeys: activeTagFilterKeys)
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
            editingSnippetID = nil
            if !nameField.stringValue.isEmpty {
                nameField.stringValue = ""
            }
            if !snippetTextView.string.isEmpty {
                snippetTextView.string = ""
            }
            if !keywordField.stringValue.isEmpty {
                keywordField.stringValue = ""
            }
            if !tagsFromEditor().isEmpty {
                tagsField.objectValue = [String]()
            }
            if enabledCheckbox.state != .off {
                enabledCheckbox.state = .off
            }
            keywordWarningLabel.isHidden = true
            updatePreview(withTemplate: "")
            setEditorEnabled(false)
            updateSuggestedTagsRow()
            isApplyingSnippetToEditor = false
            return
        }

        applySnippetToEditor(snippet)
    }

    func applySnippetToEditor(_ snippet: Snippet) {
        isApplyingSnippetToEditor = true
        editingSnippetID = snippet.id
        if nameField.stringValue != snippet.name {
            nameField.stringValue = snippet.name
        }
        if snippetTextView.string != snippet.content {
            snippetTextView.string = snippet.content
        }
        if keywordField.stringValue != snippet.normalizedKeyword {
            keywordField.stringValue = snippet.normalizedKeyword
        }
        if tagsFromEditor() != snippet.tags {
            tagsField.objectValue = snippet.tags
        }
        let targetEnabledState: NSControl.StateValue = snippet.isEnabled ? .on : .off
        if enabledCheckbox.state != targetEnabledState {
            enabledCheckbox.state = targetEnabledState
        }
        updatePreview(withTemplate: snippet.content)
        updateKeywordWarning(for: snippet)
        setEditorEnabled(true)
        updateSuggestedTagsRow()
        isApplyingSnippetToEditor = false
    }

    func setEditorEnabled(_ enabled: Bool) {
        nameField.isEnabled = enabled
        snippetTextView.isEditable = enabled
        keywordField.isEnabled = enabled
        tagsField.isEnabled = enabled
        enabledCheckbox.isEnabled = enabled
    }

    var selectedSnippet: Snippet? {
        guard let selectedSnippetID else { return nil }
        return store.snippet(id: selectedSnippetID)
    }

    var editingSnippet: Snippet? {
        guard let editingSnippetID else { return nil }
        return store.snippet(id: editingSnippetID)
    }

    func activeCommandSnippetID() -> UUID? {
        let preferredID = isEditingDetails ? editingSnippetID : selectedSnippetID
        guard let preferredID, store.snippet(id: preferredID) != nil else { return nil }
        return preferredID
    }

    func commitActiveEditorState(endingEditing: Bool) {
        guard isEditingDetails else { return }
        updateSelectedSnippetFromEditor()
        store.commitEditTransaction()

        guard endingEditing else { return }
        view.window?.makeFirstResponder(tableView)
    }

    func updateSelectedSnippetFromEditor() {
        guard !isApplyingSnippetToEditor, var snippet = editingSnippet else { return }

        snippet.name = nameField.stringValue
        snippet.content = snippetTextView.string

        snippet.keyword = sanitizedKeywordFromEditor()
        snippet.tags = tagsFromEditor()

        snippet.isEnabled = enabledCheckbox.state == .on

        store.update(snippet)
        updatePreview(withTemplate: snippet.content)
        updateKeywordWarning(for: snippet)
        updateSuggestedTagsRow()
    }

    func tagsFromEditor() -> [String] {
        let tokens = (tagsField.objectValue as? [Any]) ?? []
        return SnippetTagging.normalizedTags(tokens.compactMap { $0 as? String })
    }

    /// Rebuilds the one-click "+ tag" suggestions under the tags field:
    /// existing tags not yet on the edited snippet, most-used first.
    func updateSuggestedTagsRow() {
        let suggestions: [String]
        if editingSnippetID != nil, tagsField.isEnabled {
            let currentKeys = Set(tagsFromEditor().map { SnippetTagging.filterKey(for: $0) })
            suggestions = store.tagUsage()
                .filter { !currentKeys.contains(SnippetTagging.filterKey(for: $0.tag)) }
                .sorted { $0.count > $1.count }
                .prefix(8)
                .map(\.tag)
        } else {
            suggestions = []
        }

        guard suggestions != renderedSuggestedTags else { return }
        renderedSuggestedTags = suggestions

        let chips = suggestions.map { tag -> TagChipView in
            let chip = TagChipView(fontSize: 11)
            chip.configure(text: "+ \(tag)", color: TagColorPalette.color(for: tag), style: .tinted)
            chip.toolTip = "Add tag “\(tag)”"
            chip.setAccessibility(label: "Add tag \(tag)", isButton: true)
            chip.onClick = { [weak self] in
                self?.addSuggestedTagToEditor(tag)
            }
            return chip
        }
        editorSuggestedTagsFlow.setChips(chips)
        editorSuggestedTagsFlow.isHidden = chips.isEmpty
    }

    private func addSuggestedTagToEditor(_ tag: String) {
        guard editingSnippet != nil else { return }
        tagsField.objectValue = SnippetTagging.normalizedTags(tagsFromEditor() + [tag])
        updateSelectedSnippetFromEditor()
        reloadVisibleSnippets(keepSelection: true)
    }

    private func sanitizedKeywordFromEditor() -> String {
        let rawKeyword = keywordField.stringValue
        let sanitizedKeyword = Snippet.sanitizedKeyword(rawKeyword)
        guard sanitizedKeyword != rawKeyword else { return sanitizedKeyword }

        if let editor = keywordField.currentEditor() {
            let selectedRange = editor.selectedRange
            let sanitizedLength = (sanitizedKeyword as NSString).length
            editor.string = sanitizedKeyword
            editor.selectedRange = NSRange(
                location: min(selectedRange.location, sanitizedLength),
                length: min(selectedRange.length, max(0, sanitizedLength - min(selectedRange.location, sanitizedLength)))
            )
        } else {
            keywordField.stringValue = sanitizedKeyword
        }

        return sanitizedKeyword
    }

    func updateKeywordWarning(for snippet: Snippet) {
        let keyword = snippet.normalizedKeyword.lowercased()
        guard snippet.isEnabled, !keyword.isEmpty else {
            keywordWarningLabel.isHidden = true
            return
        }

        let conflicting = store.enabledSnippetsSorted().filter { other in
            guard other.id != snippet.id else { return false }
            let otherKeyword = other.normalizedKeyword.lowercased()
            return otherKeyword.hasPrefix(keyword) || keyword.hasPrefix(otherKeyword)
        }

        if let first = conflicting.first {
            keywordWarningLabel.stringValue = "Overlaps with \\\(first.normalizedKeyword) — won't auto-expand"
            keywordWarningLabel.isHidden = false
        } else {
            keywordWarningLabel.isHidden = true
        }
    }

    func updatePreview(withTemplate template: String) {
        let rendered = PlaceholderResolver.resolveForPreview(template: template)
        let hasDynamicContent = !template.isEmpty
            && PlaceholderResolver.containsResolvablePlaceholder(in: template)
        previewSeparator.isHidden = !hasDynamicContent
        previewSectionStack.isHidden = !hasDynamicContent
        previewValueField.stringValue = rendered
    }

    var isEditingDetails: Bool {
        guard let firstResponder = view.window?.firstResponder else { return false }
        if firstResponder === snippetTextView {
            return true
        }
        if firstResponder === nameField.currentEditor()
            || firstResponder === keywordField.currentEditor()
            || firstResponder === tagsField.currentEditor() {
            return true
        }
        return false
    }
}
