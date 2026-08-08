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
            permissionIconView.setAccessibilityLabel("Permissions required")
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
        let actions: Set<ListEmptyStateAction>

        if store.snippets.isEmpty {
            // No teaching sentence here, because this screen cannot be a first
            // run: `SnippetStore.load()` seeds the starter snippet when there is
            // no file, so an empty library only happens to someone who deleted
            // everything — who already knows how expansion works. Three buttons
            // below already say what to do next. (If the starter snippet is ever
            // removed from `load()`, this becomes a genuine first-run screen and
            // the explanation should come back.)
            iconName = "square.dashed"
            message = "No snippets yet."
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
            updateNameFieldPlaceholder()
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
        updateNameFieldPlaceholder()
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
        return store.snippetForDisplay(id: selectedSnippetID)
    }

    var editingSnippet: Snippet? {
        guard let editingSnippetID else { return nil }
        return store.snippetForDisplay(id: editingSnippetID)
    }

    /// The row a command should act on, secure or not.
    ///
    /// This used to require `store.snippet`, i.e. plaintext only — so Delete, Pin,
    /// Enable, Reset Usage and the tag menu all returned early for a secure row while
    /// their buttons and menu items stayed enabled. Nothing happened and nothing was
    /// said. Commands that genuinely cannot apply to a secure record now refuse out
    /// loud; see `refuseSecureCommand`.
    func activeCommandSnippetID() -> UUID? {
        let preferredID = isEditingDetails ? editingSnippetID : selectedSnippetID
        guard let preferredID, store.snippetForDisplay(id: preferredID) != nil else { return nil }
        return preferredID
    }

    /// Says no, visibly, for the commands that would need the plaintext.
    ///
    /// Duplicating or copying a secret means making a second copy of it — on the
    /// clipboard, or as a new record — which is the opposite of what the vault is for.
    /// Returns true when the command was refused and the caller should stop.
    func refuseSecureCommand(_ id: UUID?, _ what: String) -> Bool {
        guard let id, store.isSecure(id) else { return false }
        importExportMessage = "Secure snippets can\u{2019}t be \(what). Type \\ and pick it from the list to use it."
        closeActionPanel()
        return true
    }

    /// Routes a metadata change to whichever store owns the record.
    @discardableResult
    func applySecureMetadataToggle(_ id: UUID, pinned: Bool? = nil, enabled: Bool? = nil) -> Bool {
        guard store.isSecure(id), let app = NSApp.delegate as? AppDelegate,
              let record = app.secureStore.record(id) else { return false }
        try? app.secureStore.updateMetadata(
            id: id,
            isEnabled: enabled.map { _ in !record.isEnabled },
            isPinned: pinned.map { _ in !record.isPinned })
        return true
    }

    func commitActiveEditorState(endingEditing: Bool) {
        guard isEditingDetails else { return }
        updateSelectedSnippetFromEditor()
        // `updateSelectedSnippetFromEditor` may have queued a secure write; anything
        // reading the vault after this must see it.
        flushPendingSecureEdit()
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

        if store.isSecure(snippet.id) {
            commitSecureEdit(snippet)
        } else {
            store.update(snippet)
        }
        updatePreview(withTemplate: snippet.content)
        updateKeywordStatus(for: snippet)
        updateNameFieldPlaceholder()
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

    /// Name's placeholder is the title the sidebar row would use if the field
    /// stays empty — the actual first line of the content, not a sentence about
    /// it. "Optional — first line is used if blank" was the longest string in the
    /// form (212pt in a field that was 182pt wide on the window this app used to
    /// open at) and a rule the user learns once; showing the value states the
    /// same rule in zero words and is not fiction, because `displayName` really
    /// does fall back to `contentFirstLine`.
    ///
    /// Reassigned on every keystroke in the content view, hence the equality
    /// guard: it is a placeholder on a fixed-height single-line field, so nothing
    /// reflows, but there is no reason to redraw it for an unchanged string.
    func updateNameFieldPlaceholder() {
        let firstLine = snippetTextView.string
            .prefix(while: { !$0.isNewline })
            .trimmingCharacters(in: .whitespaces)

        let placeholder: String
        if firstLine.isEmpty {
            placeholder = EditorCopy.namePlaceholderFallback
        } else if firstLine.count > EditorCopy.namePlaceholderCharacterLimit {
            placeholder = String(firstLine.prefix(EditorCopy.namePlaceholderCharacterLimit)) + "…"
        } else {
            placeholder = firstLine
        }

        guard nameField.placeholderString != placeholder else { return }
        nameField.placeholderString = placeholder
    }

    func tagsFromEditor() -> [String] {
        let tokens = (tagsField.objectValue as? [Any]) ?? []
        return SnippetTagging.normalizedTags(tokens.compactMap { $0 as? String })
    }

    /// Rebuilds the one-click "+ tag" suggestions under the tags field:
    /// existing tags not yet on the edited snippet, most-used first.
    ///
    /// Only while the snippet has no tags at all. Offered on any snippet missing
    /// any library tag — which for anyone with tags is essentially always — this
    /// was up to eight coloured pills permanently parked under the field, and the
    /// token field already completes "w" to "work" on its own. Gated on empty it
    /// obeys the same rule as the keyword chips above it: chips are a starting
    /// point when the field has nothing, and get out of the way once it does.
    func updateSuggestedTagsRow() {
        let suggestions: [String]
        if editingSnippetID != nil, tagsField.isEnabled, tagsFromEditor().isEmpty {
            // No "minus this snippet's tags" filter any more: the guard above is
            // that this snippet has none, so every library tag is a candidate.
            suggestions = store.tagUsage()
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

    /// The one line under Keyword. It never hides — the slot keeps its height so
    /// the form cannot reflow while someone is typing — and it speaks only when
    /// something is wrong or missing, because the keyword is the only field that
    /// decides whether a snippet fires and nothing else on screen reports it.
    ///
    /// Silence therefore means "this works", and means only that. It used to be
    /// ambiguous, because a snippet with no keyword at all was silent too; that
    /// case now says so, which is what earns the working case its silence back.
    /// "Type \sig in any app." was the app's whole mechanic restated on every
    /// correctly configured snippet forever.
    ///
    /// Every sentence here is written to survive being cut off. The label is one
    /// line pinned to the editor's width, which is 182pt on a default first-run
    /// window — about five words — and `displayName` alone can be 51 characters,
    /// so no wording fits at every width. What each sentence can do is put the
    /// verdict first and the name of the other snippet last, so the ellipsis eats
    /// the detail rather than the meaning; the tooltip carries the whole line.
    func updateKeywordStatus(for snippet: Snippet?) {
        guard let snippet else {
            setKeywordStatus("")
            return
        }

        // Fold like the expansion engine (case + diacritics) so e.g.
        // "cafe" vs "café" is flagged — both stop expanding.
        let keyword = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
        let trigger = "\\\(snippet.normalizedKeyword)"

        guard !keyword.isEmpty else {
            // The most common broken snippet in the library, and the one the old
            // warning was careful to say nothing about.
            setKeywordStatus("Add a keyword to expand this.")
            return
        }
        guard snippet.isEnabled else {
            // A disabled snippet is invisible to the engine, so it neither fires
            // nor blocks anyone; reporting conflicts here would be a lie.
            setKeywordStatus("Disabled — \(trigger) won't expand.")
            return
        }
        // Transcribed from SnippetExpansionEngine.unambiguousExactMatch: the
        // trigger deletion is counted in graphemes, so a keyword containing one
        // built from several scalars is refused outright.
        guard !snippet.normalizedKeyword.contains(where: { $0.unicodeScalars.count > 1 }) else {
            setKeywordStatus("\(trigger) needs letters, digits or -.")
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
        // Both stores. `enabledSnippetsSorted()` is plaintext-only by design — it feeds
        // auto-expansion — so checking conflicts against it alone let a plaintext snippet
        // silently claim a keyword a secure record already owns, leaving two live rows
        // matching the same trigger with no warning anywhere.
        let candidates = store.enabledSnippetsSorted()
            + (store.secureProvider?.secureShellsForDisplay().filter(\.isEnabled) ?? [])
        for other in candidates where other.id != snippet.id {
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
            setKeywordStatus("\(trigger) is taken, neither expands: \(duplicate.displayName)")
        } else if let blockedBy {
            // This snippet's own failure outranks the damage it does elsewhere:
            // the line sits under this snippet's keyword, and naming only the
            // other victim would read as "this one is fine". The line recomputes
            // on every keystroke, so `blocks` surfaces the moment this is fixed.
            //
            // The longer keyword trails the name because it is the one part a
            // user can reconstruct — something starting with this keyword is in
            // the library — so it is the right thing to lose first.
            setKeywordStatus(
                "\(trigger) won't expand, blocked by \(blockedBy.displayName) (\\\(blockedBy.normalizedKeyword))"
            )
        } else if let blocks {
            setKeywordStatus("This stops \\\(blocks.normalizedKeyword) expanding: \(blocks.displayName)")
        } else {
            // Nothing to report. The slot keeps its 15pt height, so this is a
            // blank line and not a collapsed row.
            setKeywordStatus("")
        }
    }

    /// The verdict rides on the keyword field itself rather than a line of prose
    /// beneath it. Every sentence here describes a state most snippets are never
    /// in, and a permanent row for them left a gap under every keyword that
    /// already worked.
    private func setKeywordStatus(_ text: String) {
        keywordField.toolTip = text.isEmpty ? nil : text
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
        // Hides the whole section, label included — no separator above it any
        // more, because with the token hint gone it was a horizontal rule no
        // other section had, fencing a section already fenced by being
        // conditional, by its own label, and by the 16pt gap below it.
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
    /// Debounced, exactly like the plaintext path.
    ///
    /// This runs from `textDidChange`, so it fires on every keystroke. Writing straight
    /// through meant a locked, fsync'd vault write per character — and, because a vault
    /// write publishes a library change, the editor was also rebuilt under the caret on
    /// every character, sending it to the end of the line mid-word. `SnippetStore` has
    /// debounced for exactly this reason since long before secure snippets existed.
    func commitSecureEdit(_ snippet: Snippet) {
        pendingSecureEdit = snippet
        secureEditWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushPendingSecureEdit() }
        }
        secureEditWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes any pending secure edit immediately.
    ///
    /// Must run before anything reads the vault from disk — committing the editor,
    /// promoting, demoting, quitting — or that reader sees the pre-edit record.
    func flushPendingSecureEdit() {
        secureEditWorkItem?.cancel()
        secureEditWorkItem = nil
        guard let snippet = pendingSecureEdit else { return }
        pendingSecureEdit = nil

        guard let app = NSApp.delegate as? AppDelegate else { return }
        let secureStore = app.secureStore

        do {
            // Only when something actually moved. Typing in the body changes no
            // metadata, and an unconditional write there was most of the storm.
            if let record = secureStore.record(snippet.id),
               record.name != snippet.name
                   || record.keyword != snippet.normalizedKeyword
                   || record.tags != snippet.tags
                   || record.isEnabled != snippet.isEnabled {
                try secureStore.updateMetadata(
                    id: snippet.id,
                    name: snippet.name,
                    keyword: snippet.keyword,
                    tags: snippet.tags,
                    isEnabled: snippet.isEnabled)
            }

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
