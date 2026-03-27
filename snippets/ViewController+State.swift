import AppKit

enum GroupPopUpItemKind {
    static let ungrouped = "__ungrouped__"
    static let newGroup = "__new_group__"
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
            permissionIconView.contentTintColor = .systemOrange
            permissionTitleLabel.stringValue = "Permissions Required"
            permissionTitleLabel.textColor = .systemOrange
            permissionButtonsStack.isHidden = false
            permissionStatusLabel.stringValue = engine.statusText
        }
    }

    func refreshGroupControls() {
        updateSearchPlaceholder()
        updateGroupFilterButtons()
        rebuildGroupPopUpMenu()
    }

    func updateSearchPlaceholder() {
        switch selectedGroupFilter {
        case .all:
            searchField.placeholderString = "Search snippets"
        case .ungrouped:
            searchField.placeholderString = "Search Ungrouped"
        case let .group(groupID):
            let groupName = store.group(id: groupID)?.displayName ?? "Group"
            searchField.placeholderString = "Search \(groupName)"
        }
    }

    func sanitizeSelectedGroupFilterIfNeeded() {
        guard let groupID = selectedGroupFilter.groupID, store.group(id: groupID) == nil else { return }
        selectedGroupFilter = .all
    }

    func updateGroupFilterButtons() {
        groupFilterStackView.arrangedSubviews.forEach { subview in
            groupFilterStackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let filters: [SnippetGroupFilter] = [.all, .ungrouped] + store.groupsSortedForDisplay().map { .group($0.id) }

        for filter in filters {
            let button = GroupFilterButton(frame: .zero)
            button.title = title(for: filter)
            button.filter = filter
            button.state = filter == selectedGroupFilter ? .on : .off
            button.target = self
            button.action = #selector(handleGroupFilterButton(_:))
            groupFilterStackView.addArrangedSubview(button)
        }

        groupFilterStackView.layoutSubtreeIfNeeded()
        let fittingSize = groupFilterStackView.fittingSize
        groupFilterStackView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(fittingSize.width, groupFilterScrollView.contentSize.width),
            height: max(28, fittingSize.height)
        )
    }

    func rebuildGroupPopUpMenu() {
        let selectedGroupID = selectedSnippet?.groupID

        isUpdatingGroupPopUp = true
        groupPopUpButton.removeAllItems()

        groupPopUpButton.addItem(withTitle: "Ungrouped")
        groupPopUpButton.lastItem?.representedObject = GroupPopUpItemKind.ungrouped

        let groups = store.groupsSortedForDisplay()
        if !groups.isEmpty {
            groupPopUpButton.menu?.addItem(.separator())
            for group in groups {
                groupPopUpButton.addItem(withTitle: group.displayName)
                groupPopUpButton.lastItem?.representedObject = group.id.uuidString
            }
        }

        groupPopUpButton.menu?.addItem(.separator())
        groupPopUpButton.addItem(withTitle: "New Group…")
        groupPopUpButton.lastItem?.representedObject = GroupPopUpItemKind.newGroup

        if let selectedGroupID {
            selectGroupPopUpItem(groupID: selectedGroupID)
        } else {
            selectGroupPopUpItem(groupID: nil)
        }

        groupPopUpButton.isEnabled = selectedSnippet != nil
        isUpdatingGroupPopUp = false
    }

    func selectGroupPopUpItem(groupID: UUID?) {
        let targetValue = groupID?.uuidString ?? GroupPopUpItemKind.ungrouped
        if let item = groupPopUpButton.itemArray.first(where: { ($0.representedObject as? String) == targetValue }) {
            groupPopUpButton.select(item)
            return
        }

        groupPopUpButton.selectItem(at: 0)
    }

    func title(for filter: SnippetGroupFilter) -> String {
        switch filter {
        case .all:
            return "All"
        case .ungrouped:
            return "Ungrouped"
        case let .group(groupID):
            return store.group(id: groupID)?.displayName ?? "Ungrouped"
        }
    }

    func selectGroupFilter(_ filter: SnippetGroupFilter, shouldTouchGroup: Bool = true) {
        let didChange = selectedGroupFilter != filter
        selectedGroupFilter = filter

        if let groupID = filter.groupID, shouldTouchGroup {
            store.touchGroup(groupID: groupID)
        } else {
            refreshGroupControls()
            if didChange {
                reloadVisibleSnippets(keepSelection: true)
                if selectedSnippetID == nil {
                    applySelectedSnippetToEditor()
                }
            }
        }
    }

    func adjustSelectedGroupFilterForSnippetGroupChange(to groupID: UUID?) {
        switch selectedGroupFilter {
        case .all:
            return
        case .ungrouped:
            if groupID != nil {
                selectedGroupFilter = groupFilter(for: groupID)
                refreshGroupControls()
            }
        case let .group(currentGroupID):
            if currentGroupID != groupID {
                selectedGroupFilter = groupFilter(for: groupID)
                refreshGroupControls()
            }
        }
    }

    func groupFilter(for groupID: UUID?) -> SnippetGroupFilter {
        guard let groupID else { return .ungrouped }
        return .group(groupID)
    }

    func reloadVisibleSnippets(keepSelection: Bool) {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let scoped = store.snippetsSortedForDisplay().filter { snippet in
            snippetMatchesCurrentGroupFilter(snippet)
        }

        if query.isEmpty {
            visibleSnippets = scoped
        } else {
            visibleSnippets = scoped.filter { snippet in
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
        deleteButton.isEnabled = selectedSnippetID != nil

        if selectedSnippetID == nil {
            applySelectedSnippetToEditor()
        }
    }

    func snippetMatchesCurrentGroupFilter(_ snippet: Snippet) -> Bool {
        switch selectedGroupFilter {
        case .all:
            return true
        case .ungrouped:
            return snippet.groupID == nil
        case let .group(groupID):
            return snippet.groupID == groupID
        }
    }

    var shouldShowGroupLabelsInList: Bool {
        selectedGroupFilter == .all
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
            if !nameField.stringValue.isEmpty {
                nameField.stringValue = ""
            }
            if !snippetTextView.string.isEmpty {
                snippetTextView.string = ""
            }
            if !keywordField.stringValue.isEmpty {
                keywordField.stringValue = ""
            }
            if enabledCheckbox.state != .off {
                enabledCheckbox.state = .off
            }
            rebuildGroupPopUpMenu()
            updatePreview(withTemplate: "")
            setEditorEnabled(false)
            isApplyingSnippetToEditor = false
            return
        }

        isApplyingSnippetToEditor = true
        if nameField.stringValue != snippet.name {
            nameField.stringValue = snippet.name
        }
        if snippetTextView.string != snippet.content {
            snippetTextView.string = snippet.content
        }
        if keywordField.stringValue != snippet.normalizedKeyword {
            keywordField.stringValue = snippet.normalizedKeyword
        }
        let targetEnabledState: NSControl.StateValue = snippet.isEnabled ? .on : .off
        if enabledCheckbox.state != targetEnabledState {
            enabledCheckbox.state = targetEnabledState
        }
        rebuildGroupPopUpMenu()
        updatePreview(withTemplate: snippet.content)
        updateKeywordWarning(for: snippet)
        setEditorEnabled(true)
        isApplyingSnippetToEditor = false
    }

    func setEditorEnabled(_ enabled: Bool) {
        nameField.isEnabled = enabled
        snippetTextView.isEditable = enabled
        groupPopUpButton.isEnabled = enabled && selectedSnippet != nil
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

        let sanitizedKeyword = keywordField.stringValue.replacingOccurrences(of: " ", with: "-")
        if sanitizedKeyword != keywordField.stringValue {
            keywordField.stringValue = sanitizedKeyword
        }
        snippet.keyword = sanitizedKeyword

        snippet.isEnabled = enabledCheckbox.state == .on

        store.update(snippet)
        updatePreview(withTemplate: snippet.content)
        updateKeywordWarning(for: snippet)
    }

    func updateKeywordWarning(for snippet: Snippet) {
        let keyword = snippet.normalizedKeyword.lowercased()
        guard !keyword.isEmpty else {
            keywordWarningLabel.isHidden = true
            return
        }

        let conflicting = store.enabledSnippetsSorted().filter { other in
            guard other.id != snippet.id else { return false }
            let otherKeyword = other.normalizedKeyword.lowercased()
            return otherKeyword.hasPrefix(keyword) || keyword.hasPrefix(otherKeyword)
        }

        if let first = conflicting.first {
            keywordWarningLabel.stringValue = "Overlaps with \\\(first.normalizedKeyword) - won't auto-expand"
            keywordWarningLabel.isHidden = false
        } else {
            keywordWarningLabel.isHidden = true
        }
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
        if firstResponder === groupPopUpButton {
            return true
        }
        if firstResponder === nameField.currentEditor() || firstResponder === keywordField.currentEditor() {
            return true
        }
        return false
    }
}
