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

        let tagFilterKeys = activeTagFilterKeys
        let didTagFilterChange = lastAppliedTagFilterKeys != tagFilterKeys
        lastAppliedTagFilterKeys = tagFilterKeys

        let sorted = store.snippetsSortedForDisplay()
        let searchMatches: [Snippet]
        if query.isEmpty {
            searchMatches = sorted
        } else {
            searchMatches = sorted.filter { snippet in
                snippet.displayName.lowercased().contains(query)
                    || snippet.normalizedKeyword.lowercased().contains(query)
                    || snippet.content.lowercased().contains(query)
                    || snippet.tags.contains { $0.lowercased().contains(query) }
            }
        }

        var newSnippets = searchMatches
        if !tagFilterKeys.isEmpty {
            newSnippets = newSnippets.filter { snippet in
                tagFilterKeys.allSatisfy { snippet.hasTag(withKey: $0) }
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
            // Likewise when the snippet open in the editor drops out because
            // its own tags changed (the user cleared the tag the filter is on)
            // rather than because the filter itself changed. That is editing,
            // not a request for a different list, so it stays open — otherwise
            // deleting a tag rips the snippet out from under the caret.
            let keepSnippetDroppedByOwnTags = !didTagFilterChange
                && !tagFilterKeys.isEmpty
                && editingSnippetID == selectedSnippetID
                && searchMatches.contains { $0.id == selectedSnippetID }
            if !keepEditingHiddenSnippet && !keepSnippetDroppedByOwnTags {
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
                cellView.configure(with: visibleSnippets[row], isSecure: store.isSecure(visibleSnippets[row].id))
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

    /// Canonical, display-cased tags behind the currently active filter keys.
    func activeTagFilterTags() -> [String] {
        guard !activeTagFilterKeys.isEmpty else { return [] }
        return store.allTags().filter { activeTagFilterKeys.contains(SnippetTagging.filterKey(for: $0)) }
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
        // Skip mid-token: every keystroke writes the unfinished text to the
        // store as a tag, so a live rebuild would flash chips for "w", "wo",
        // "wor". `refreshTagFilterBar()` publishes the tag the moment the token
        // is actually committed, and controlTextDidEndEditing catches the rest.
        // (Both sides can be nil — e.g. at viewDidLoad — which must NOT skip.)
        if let editor = tagsField.currentEditor(), view.window?.firstResponder === editor {
            return
        }

        refreshTagFilterBar()
    }

    /// Rebuilds the sidebar filter chips from the store, bypassing the
    /// skip-while-typing guard above. Safe to call redundantly: the bar no-ops
    /// when the items and active keys are unchanged.
    func refreshTagFilterBar() {
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
        // Must run after `setEditorEnabled(true)`, which unconditionally makes the text
        // view editable — a locked secret has to end up read-only regardless.
        applySecureStateToEditor(for: snippet)
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

        if store.isSecure(snippet.id) {
            commitSecureEdit(snippet)
        } else {
            store.update(snippet)
        }
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
        refreshTagFilterBar()
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
        // Fold like the expansion engine (case + diacritics) so e.g.
        // "cafe" vs "café" is flagged — both stop expanding.
        let keyword = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
        guard snippet.isEnabled, !keyword.isEmpty else {
            keywordWarningLabel.isHidden = true
            return
        }

        let conflicting = store.enabledSnippetsSorted().filter { other in
            guard other.id != snippet.id else { return false }
            let otherKeyword = SnippetTagging.filterKey(for: other.normalizedKeyword)
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


// MARK: - Editing a secure snippet

extension ViewController {

    /// Whether the selected record's text is currently readable.
    var isSecureContentRevealed: Bool {
        guard let id = editingSnippetID, store.isSecure(id) else { return true }
        return (NSApp.delegate as? AppDelegate)?.vaultSession.state.isUnlocked ?? false
    }

    /// Writes an edit of a secure record back to the vault rather than to `snippets.json`.
    ///
    /// Metadata always goes through; **content only when the vault is unlocked**. That
    /// asymmetry is the whole point: while locked, the text view is showing a placeholder
    /// rather than the snippet, so saving it would overwrite the secret with the word
    /// that stands in for it. Renaming or retagging a locked record is still allowed,
    /// because that never needs the key.
    func commitSecureEdit(_ snippet: Snippet) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let secureStore = app.secureStore

        do {
            try secureStore.updateMetadata(
                id: snippet.id,
                name: snippet.name,
                keyword: snippet.keyword,
                tags: snippet.tags,
                isEnabled: snippet.isEnabled)

            if app.vaultSession.state.isUnlocked,
               snippet.content != secureContentPlaceholder,
               (try? secureStore.content(for: snippet.id)) != snippet.content {
                try secureStore.setContent(snippet.content, for: snippet.id)
            }
        } catch {
            importExportMessage = "Could not save the secure snippet: \(error)"
        }
    }

    /// Stands in for the text while the vault is locked.
    ///
    /// Deliberately a sentence rather than dots: a row of bullets in an editable text
    /// view reads as content the user could overwrite, and someone would.
    var secureContentPlaceholder: String {
        "\u{1F512} Locked \u{2014} unlock to reveal this snippet\u{2019}s text."
    }

    /// Swaps the editor between the real text and the placeholder.
    ///
    /// Called from `applySnippetToEditor` and whenever the vault locks or unlocks, so a
    /// lock timeout does not leave a secret sitting visible on screen.
    func applySecureStateToEditor(for snippet: Snippet) {
        guard store.isSecure(snippet.id), let app = NSApp.delegate as? AppDelegate else { return }

        let wasApplying = isApplyingSnippetToEditor
        isApplyingSnippetToEditor = true
        defer { isApplyingSnippetToEditor = wasApplying }

        if app.vaultSession.state.isUnlocked, let text = try? app.secureStore.content(for: snippet.id) {
            snippetTextView.string = text
            snippetTextView.isEditable = true
            updatePreview(withTemplate: text)
        } else {
            snippetTextView.string = secureContentPlaceholder
            snippetTextView.isEditable = false
            // The preview renders placeholders like {clipboard}; feeding it the real
            // text of a locked snippet would display exactly what the lock is hiding.
            updatePreview(withTemplate: "")
        }
    }

    /// Unlocks and shows the selected secure snippet.
    @objc func revealSelectedSecureSnippet() {
        guard let snippet = selectedSnippet,
              store.isSecure(snippet.id),
              let app = NSApp.delegate as? AppDelegate else { return }
        do {
            try app.vaultSession.unlock(reason: "Reveal \u{201C}\(snippet.displayName)\u{201D}")
            applySecureStateToEditor(for: snippet)
        } catch {
            importExportMessage = "Could not unlock: \(error)"
        }
    }
}
