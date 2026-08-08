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
                && store.snippetForDisplay(id: selectedSnippetID) != nil
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
        let isSecure = store.isSecure(snippet.id)
        secureLockToggle.state = isSecure ? .on : .off
        secureLockToggle.contentTintColor = isSecure ? .controlAccentColor : .secondaryLabelColor
        secureLockToggle.toolTip = isSecure
            ? "Make this an ordinary snippet again (\u{2303}\u{2318}L)."
            : "Encrypt this snippet (\u{2303}\u{2318}L). It will stop expanding on its own \u{2014} "
                + "you\u{2019}ll pick it from the \\ list instead."
        secureDemoteStrip.isHidden = true

        if isSecure {
            applySecureStateToEditor(for: snippet)
        } else {
            // Otherwise the overlay from a previously selected secure snippet would sit
            // over this one, and the caption would describe the wrong record.
            clearSecureEditorChrome()
        }
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
        return store.snippetForDisplay(id: selectedSnippetID)
    }

    var editingSnippet: Snippet? {
        guard let editingSnippetID else { return nil }
        return store.snippetForDisplay(id: editingSnippetID)
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

            // The latch, not a string comparison: content is written back only if this
            // editor is currently displaying the real decrypted text for this exact
            // record.
            if secureContentEditableForID == snippet.id,
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

    /// Swaps the editor between the real text and the placeholder.
    ///
    /// Called from `applySnippetToEditor` and whenever the vault locks or unlocks, so a
    /// lock timeout does not leave a secret sitting visible on screen.
    func applySecureStateToEditor(for snippet: Snippet) {
        guard store.isSecure(snippet.id), let app = NSApp.delegate as? AppDelegate else { return }

        let wasApplying = isApplyingSnippetToEditor
        isApplyingSnippetToEditor = true
        defer { isApplyingSnippetToEditor = wasApplying }

        secureCaptionLabel.stringValue =
            "Encrypted on this Mac. Won\u{2019}t expand when you type its keyword \u{2014} type \\, "
            + "pick it from the list, and confirm with Touch ID. Never in exports, share links, or "
            + "snippets.json. Its name, keyword and tags stay readable so Snippets can find it while locked."
        secureCaptionLabel.isHidden = !secureDemoteStrip.isHidden

        func mask(_ message: String, action: String? = nil) {
            secureContentEditableForID = nil
            snippetTextView.string = ""
            snippetTextView.isEditable = false
            secureLockOverlayLabel.stringValue = message
            secureLockOverlayButton.isEnabled = action != nil
            secureLockOverlay.isHidden = false
            // The preview renders placeholders like {clipboard}; feeding it the real
            // text of a locked snippet would display exactly what the lock is hiding.
            updatePreview(withTemplate: "")
        }

        if app.secureStore.isUnreadable {
            mask("Snippets can\u{2019}t read your vault file, so it has been left completely untouched.")
            return
        }
        if case .noKey = app.vaultSession.state {
            mask("This snippet\u{2019}s key isn\u{2019}t on this Mac, so its text can\u{2019}t be read here. "
                 + "Its name and keyword still work.")
            return
        }
        // Masked whenever Snippets is not the frontmost app. This costs nothing — the
        // key's lifetime is untouched, and it comes straight back on activation — but it
        // means a revealed secret is not sitting on screen behind a screen share, or
        // visible over a shoulder while the user works in another window.
        guard NSApp.isActive else {
            mask("Hidden while Snippets is in the background.")
            return
        }
        guard app.vaultSession.state.isUnlocked,
              let text = try? app.secureStore.content(for: snippet.id) else {
            mask("Locked. Click to unlock with Touch ID or your login password.", action: "unlock")
            return
        }

        snippetTextView.string = text
        snippetTextView.isEditable = true
        secureLockOverlay.isHidden = true
        secureContentEditableForID = snippet.id
        updatePreview(withTemplate: text)
    }

    /// Clears the secure chrome for an ordinary snippet. Without this the overlay from a
    /// previously selected secure snippet would stay over the next one.
    func clearSecureEditorChrome() {
        secureContentEditableForID = nil
        secureLockOverlay.isHidden = true
        secureCaptionLabel.isHidden = true
        secureDemoteStrip.isHidden = true
    }

    /// The whole content area is the button. Clicking where the text should be is what
    /// people try first, so it is what unlocks.
    @objc func unlockFromEditorOverlay() {
        guard let snippet = selectedSnippet,
              store.isSecure(snippet.id),
              let app = NSApp.delegate as? AppDelegate else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await app.vaultSession.unlock(
                    reason: "Show \u{201C}\(snippet.displayName)\u{201D}")
                // Authentication suspends the main actor; the selection may have moved.
                guard self.selectedSnippet?.id == snippet.id else { return }
                self.applySecureStateToEditor(for: snippet)
                self.view.window?.makeFirstResponder(self.snippetTextView)
                self.snippetTextView.setSelectedRange(
                    NSRange(location: self.snippetTextView.string.count, length: 0))
            } catch VaultSession.Failure.authentication {
                // Cancelling is an ordinary answer, not an error worth announcing.
            } catch {
                self.importExportMessage = "Couldn\u{2019}t unlock: \(error)"
            }
        }
    }

    /// Unlocks and shows the selected secure snippet.
}
