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
        let actions: Set<ListEmptyStateAction>

        if store.snippets.isEmpty {
            // An empty library is the one screen with room to say what the app
            // is: nothing else here ever mentions that a snippet is typed rather
            // than clicked. "Press ⌘N" answered a question nobody had yet.
            iconName = "square.dashed"
            message = "No snippets yet.\nType \\ followed by a keyword in any app to paste a snippet."
            actions = [.newSnippet, .newFromClipboard, .importSnippets]
        } else if isSearching && isFiltering {
            iconName = "magnifyingglass"
            message = "No results for “\(searchField.stringValue)”\nwith the selected tags."
            actions = [.newSnippet]
        } else if isSearching {
            // A search that found nothing is the app's own evidence that the
            // thing does not exist yet, and `createSnippet` seeds the name from
            // exactly that query.
            iconName = "magnifyingglass"
            message = "No results for “\(searchField.stringValue)”."
            actions = [.newSnippet]
        } else if isFiltering {
            iconName = "tag"
            message = "No snippets match\nthe selected tags."
            actions = []
        } else {
            listEmptyStateView.isHidden = true
            return
        }

        listEmptyStateIconView.image = LiquidGlassDesign.symbol(iconName, pointSize: 24, weight: .regular)
        listEmptyStateLabel.stringValue = message
        showListEmptyStateActions(actions)
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
            updateKeywordStatus(for: nil)
            updatePreview(withTemplate: "")
            setEditorEnabled(false)
            updateSuggestedTagsRow()
            updateSuggestedKeywordsRow(for: nil)
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
        updateKeywordStatus(for: snippet)
        setEditorEnabled(true)
        updateSuggestedTagsRow()
        updateSuggestedKeywordsRow(for: snippet)
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
        let previousTags = snippet.tags

        snippet.name = nameField.stringValue
        snippet.content = snippetTextView.string

        snippet.keyword = sanitizedKeywordFromEditor()
        snippet.tags = tagsFromEditor()

        snippet.isEnabled = enabledCheckbox.state == .on

        store.update(snippet)
        updatePreview(withTemplate: snippet.content)
        updateKeywordStatus(for: snippet)
        // Cheap while a keyword exists — it stops at the first guard — and the
        // name and the content it derives from are both edited here.
        updateSuggestedKeywordsRow(for: snippet)
        // The chips are the library's tags minus this snippet's, and this update
        // is the only thing that touched the library, so nothing can have moved
        // unless these tags did. Deciding that here rather than inside the row
        // keeps `store.tagUsage()` — a walk over every snippet's every tag plus a
        // localized sort — off every keystroke in Name, Keyword and Snippet.
        if snippet.tags != previousTags {
            updateSuggestedTagsRow()
        }
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

        // A space at the very end is a word the user has not finished typing,
        // not stray input: rewriting the field there swallows it, so "my sig"
        // can never reach "my-sig" — the field goes straight from "my" to "mys".
        // Interior spaces are still joined on the spot, and the stored keyword is
        // sanitized either way.
        var withoutTrailingWhitespace = rawKeyword
        while let last = withoutTrailingWhitespace.last, last.isWhitespace {
            withoutTrailingWhitespace.removeLast()
        }
        guard withoutTrailingWhitespace != sanitizedKeyword else { return sanitizedKeyword }

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

    /// The one line under Keyword. It never hides and it always says whether
    /// this snippet will actually fire, because the keyword is the only field
    /// that decides that and nothing else on screen reports it. Empty text is
    /// reserved for "no snippet selected" — there is nothing to be true about.
    func updateKeywordStatus(for snippet: Snippet?) {
        guard let snippet else {
            setKeywordStatus("", isFailure: false)
            return
        }

        // Fold like the expansion engine (case + diacritics) so e.g.
        // "cafe" vs "café" is flagged — both stop expanding.
        let keyword = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
        let trigger = "\\\(snippet.normalizedKeyword)"

        guard !keyword.isEmpty else {
            // The most common broken snippet in the library, and the one the old
            // warning was careful to say nothing about.
            setKeywordStatus("Add a keyword — this won't expand yet.", isFailure: false)
            return
        }
        guard snippet.isEnabled else {
            // A disabled snippet is invisible to the engine, so it neither fires
            // nor blocks anyone; reporting conflicts here would be a lie.
            setKeywordStatus("Disabled — \(trigger) won't expand until you turn it on.", isFailure: false)
            return
        }
        // Transcribed from SnippetExpansionEngine.unambiguousExactMatch: the
        // trigger deletion is counted in graphemes, so a keyword containing one
        // built from several scalars is refused outright.
        guard !snippet.normalizedKeyword.contains(where: { $0.unicodeScalars.count > 1 }) else {
            setKeywordStatus("\(trigger) won't auto-expand — use letters, digits or -.", isFailure: true)
            return
        }

        // Also from unambiguousExactMatch, via the `KeywordRelation` the keyword
        // chips choose with: the two sides of the prefix relation are two
        // different failures on two different snippets and both have to be
        // computed. Sharing the rule is what stops a chip from ever offering a
        // keyword this line would then call broken.
        var duplicate: Snippet?
        var blockedBy: Snippet?
        var blocks: Snippet?
        for other in store.enabledSnippetsSorted() where other.id != snippet.id {
            switch KeywordRelation.between(keyword, SnippetTagging.filterKey(for: other.normalizedKeyword)) {
            case .duplicate:
                duplicate = duplicate ?? other
            case .blockedByLonger:
                blockedBy = blockedBy ?? other
            case .blocksShorter:
                blocks = blocks ?? other
            case .unrelated:
                break
            }
        }

        if let duplicate {
            setKeywordStatus("\(trigger) is already used by \(duplicate.displayName) — neither expands.", isFailure: true)
        } else if let blockedBy {
            // This snippet's own failure outranks the damage it does elsewhere:
            // the line sits under this snippet's keyword, and naming only the
            // other victim would read as "this one is fine". The line recomputes
            // on every keystroke, so `blocks` surfaces the moment this is fixed.
            setKeywordStatus(
                "\(trigger) won't auto-expand — \(blockedBy.displayName) uses the longer \\\(blockedBy.normalizedKeyword).",
                isFailure: true
            )
        } else if let blocks {
            setKeywordStatus("This stops \(blocks.displayName) (\\\(blocks.normalizedKeyword)) from auto-expanding.", isFailure: true)
        } else {
            // Silence used to mean this, and silence is also what a keyword-less
            // snippet got, so it meant nothing.
            setKeywordStatus("Type \(trigger) in any app.", isFailure: false)
        }
    }

    private func setKeywordStatus(_ text: String, isFailure: Bool) {
        keywordWarningLabel.stringValue = text
        keywordWarningLabel.textColor = isFailure ? ThemeManager.alertColor : .secondaryLabelColor
        // The row is one line high, so the sentence truncates at narrow editor
        // widths; the tooltip is the rest of it.
        keywordWarningLabel.toolTip = text.isEmpty ? nil : text
    }

    /// The clickable candidates under the status line, offered only while the
    /// keyword is empty — the one state in which the line above has nothing to
    /// report and the snippet cannot fire. Anything offered here is a keyword
    /// that line would immediately call valid: the collision test runs in *both*
    /// prefix directions, so a chip can neither be swallowed by a longer keyword
    /// nor stop a shorter one that already works.
    func updateSuggestedKeywordsRow(for snippet: Snippet?) {
        let suggestions = suggestedKeywords(for: snippet)

        guard suggestions != renderedSuggestedKeywords else { return }
        renderedSuggestedKeywords = suggestions

        let chips = suggestions.map { keyword -> TagChipView in
            let chip = TagChipView(fontSize: 11)
            chip.configure(text: "\\\(keyword)", color: .controlAccentColor, style: .tinted)
            chip.toolTip = "Use \\\(keyword) as this snippet's keyword"
            chip.setAccessibility(label: "Use keyword \(keyword)", isButton: true)
            chip.onClick = { [weak self] in
                self?.applySuggestedKeyword(keyword)
            }
            return chip
        }
        editorSuggestedKeywordsFlow.setChips(chips)
        editorSuggestedKeywordsFlow.isHidden = chips.isEmpty
    }

    private func suggestedKeywords(for snippet: Snippet?) -> [String] {
        guard let snippet, keywordField.isEnabled, snippet.normalizedKeyword.isEmpty else { return [] }

        let candidates = KeywordSuggestions.candidates(
            name: snippet.name,
            contentFirstLine: snippet.contentFirstLine
        )
        // The snippet being edited has no keyword of its own here, so it cannot
        // be the collision it is measured against. Three candidates are a
        // choice; a fourth is a list to read, and this is meant to be faster
        // than typing three characters.
        return Array(
            candidates
                .filter { candidate in
                    enabledKeywordKeys.allSatisfy { KeywordRelation.between(candidate, $0) == .unrelated }
                }
                .prefix(3)
        )
    }

    private func applySuggestedKeyword(_ keyword: String) {
        guard editingSnippet != nil, keywordField.isEnabled else { return }

        // Write through the field rather than the store: a chip is a shortcut
        // for typing, so it has to land where typing lands, or the status line
        // and the stored snippet stop agreeing about what the keyword is.
        // The cell is written first because `stringValue` is what the commit
        // below reads, and a field editor filled in on its own posts nothing
        // back — then the editor is matched to it, since the chip never becomes
        // first responder and the caret is still sitting in the field.
        keywordField.stringValue = keyword
        if let editor = keywordField.currentEditor() {
            if editor.string != keyword {
                editor.string = keyword
            }
            editor.selectedRange = NSRange(location: (keyword as NSString).length, length: 0)
        }
        updateSelectedSnippetFromEditor()
        reloadVisibleSnippets(keepSelection: true)
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
