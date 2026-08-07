import AppKit

final class SnippetListTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }

        if selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        window?.makeFirstResponder(self)
        return contextMenuProvider?(row)
    }
}

extension ViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleSnippets.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SnippetTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleSnippets.indices.contains(row) else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("SnippetRowCell")
        let snippet = visibleSnippets[row]

        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SnippetRowCellView) ?? {
            let view = SnippetRowCellView()
            view.identifier = identifier
            return view
        }()

        cell.configure(with: snippet)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Mid-batch callbacks see intermediate row indexes against the final
        // visibleSnippets array; ignore them. reloadVisibleSnippets restores
        // the selection via syncTableSelectionWithSelectedSnippet afterwards.
        guard !isApplyingListUpdate else { return }

        let row = tableView.selectedRow
        guard row >= 0, row < visibleSnippets.count else {
            // The selected snippet still exists but the active search / tag
            // filter hides it — e.g. it was created while a filter was on, or
            // the user just deleted the tag that kept it in the list. Its row
            // is gone, but the editor must stay bound to it so it remains
            // editable instead of being blanked and disabled.
            if let selectedSnippetID,
               store.snippet(id: selectedSnippetID) != nil,
               !visibleSnippets.contains(where: { $0.id == selectedSnippetID }) {
                deleteButton.isEnabled = true
                return
            }

            let hadSelection = selectedSnippetID != nil
            selectedSnippetID = nil
            if hadSelection {
                applySelectedSnippetToEditor()
            }

            deleteButton.isEnabled = false
            return
        }

        let nextSelectionID = visibleSnippets[row].id
        let didChangeSelection = nextSelectionID != selectedSnippetID
        let outgoingSnippetID = selectedSnippetID
        selectedSnippetID = nextSelectionID

        if didChangeSelection || !isEditingDetails {
            applySelectedSnippetToEditor()
        }

        deleteButton.isEnabled = true

        // Moving to another row is the editor's other real exit, and like Escape
        // it commits nothing, so a ⌘N nobody typed into does not survive it.
        if didChangeSelection {
            discardBlankDraftAfterLeaving(outgoingSnippetID)
        }
    }

    /// Text dropped anywhere on the list becomes a snippet. Registering `.string`
    /// alone is what makes the list a target at all, and it costs nothing if the
    /// gesture is never discovered — nothing else drags into this table.
    func configureSnippetDropTarget() {
        tableView.registerForDraggedTypes([.string])
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard droppedSnippetContent(from: info) != nil else { return [] }

        // Row -1 with `.on` targets the whole table: the drop creates a snippet
        // rather than landing between two rows, and the list is sorted anyway, so
        // an insertion point would promise an ordering the drop cannot honour.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let content = droppedSnippetContent(from: info) else { return false }
        createSnippet(seededContent: content, seededName: nil)
        return true
    }

    private func droppedSnippetContent(from info: NSDraggingInfo) -> String? {
        guard let content = info.draggingPasteboard.string(forType: .string),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return content
    }

    func makeSnippetContextMenu(for row: Int) -> NSMenu? {
        guard visibleSnippets.indices.contains(row) else { return nil }

        let snippet = visibleSnippets[row]
        let menu = NSMenu(title: snippet.displayName)
        var items: [NSMenuItem] = [
            contextMenuItem(title: "Copy Snippet", symbolName: "doc.on.doc", action: #selector(copySelectedSnippetFromContextMenu(_:))),
            contextMenuItem(title: "Paste Snippet", symbolName: "arrow.down.doc", action: #selector(pasteSelectedSnippetFromContextMenu(_:))),
            contextMenuItem(title: "Copy Share Link", symbolName: "link", action: #selector(copySelectedSnippetShareLink)),
            .separator(),
            contextMenuItem(title: "Duplicate Snippet", symbolName: "plus.square.on.square", action: #selector(duplicateSelectedSnippetFromContextMenu(_:))),
            contextMenuItem(
                title: snippet.isEnabled ? "Disable Snippet" : "Enable Snippet",
                symbolName: snippet.isEnabled ? "pause.circle" : "play.circle",
                action: #selector(toggleEnabledSelectedSnippetFromContextMenu(_:))
            ),
            contextMenuItem(
                title: snippet.isPinned ? "Unpin Snippet" : "Pin Snippet",
                symbolName: snippet.isPinned ? "pin.slash" : "pin",
                action: #selector(togglePinnedSelectedSnippetFromContextMenu(_:))
            ),
            tagsContextMenuItem(for: snippet),
            .separator(),
            contextMenuItem(title: "Delete Snippet", symbolName: "trash", action: #selector(deleteSelectedSnippet(_:)))
        ]

        // The title is the disclosure: the user learns the count and gets the
        // fix in one gesture. Hidden entirely at zero, like the Pin and Enable
        // items swap rather than show a no-op.
        if let count = usageStore.usageCount(for: snippet.id), count > 0,
           let pinIndex = items.firstIndex(where: {
               $0.action == #selector(togglePinnedSelectedSnippetFromContextMenu(_:))
           }) {
            items.insert(
                contextMenuItem(
                    title: "Reset Usage (\(count) use\(count == 1 ? "" : "s"))",
                    symbolName: "arrow.counterclockwise",
                    action: #selector(resetUsageForSelectedSnippetFromContextMenu(_:))
                ),
                at: pinIndex + 1
            )
        }

        items.forEach(menu.addItem)
        return menu
    }

    private func tagsContextMenuItem(for snippet: Snippet) -> NSMenuItem {
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        LiquidGlassDesign.applyMenuSymbol("tag", to: item)

        let submenu = NSMenu(title: "Tags")
        let allTags = store.allTags()

        if allTags.isEmpty {
            let placeholder = NSMenuItem(title: "No Tags Yet", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            let hint = NSMenuItem(title: "Add tags in the editor's Tags field", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            submenu.addItem(hint)
        } else {
            for tag in allTags {
                let tagItem = NSMenuItem(
                    title: tag,
                    action: #selector(toggleTagFromContextMenu(_:)),
                    keyEquivalent: ""
                )
                tagItem.target = self
                tagItem.representedObject = tag
                tagItem.state = snippet.hasTag(withKey: SnippetTagging.filterKey(for: tag)) ? .on : .off
                tagItem.image = TagColorPalette.swatchImage(for: tag)
                submenu.addItem(tagItem)
            }
        }

        item.submenu = submenu
        return item
    }

    @objc private func toggleTagFromContextMenu(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }

        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID else { return }
        store.toggleTag(tag, snippetID: targetSnippetID)

        reloadVisibleSnippets(keepSelection: true)
        if let snippet = store.snippet(id: targetSnippetID) {
            applySnippetToEditor(snippet)
        }
    }

    private func contextMenuItem(title: String, symbolName: String, action: Selector) -> NSMenuItem {
        LiquidGlassDesign.menuItem(title: title, symbolName: symbolName, action: action, target: self)
    }

    @objc private func copySelectedSnippetFromContextMenu(_ sender: Any?) {
        copySelectedSnippet()
    }

    @objc private func pasteSelectedSnippetFromContextMenu(_ sender: Any?) {
        pasteSelectedSnippet()
    }

    @objc private func duplicateSelectedSnippetFromContextMenu(_ sender: Any?) {
        duplicateSelectedSnippet()
    }

    @objc private func toggleEnabledSelectedSnippetFromContextMenu(_ sender: Any?) {
        toggleEnabledSelectedSnippet()
    }

    @objc private func togglePinnedSelectedSnippetFromContextMenu(_ sender: Any?) {
        togglePinnedSelectedSnippet()
    }

    @objc private func resetUsageForSelectedSnippetFromContextMenu(_ sender: Any?) {
        resetUsageForSelectedSnippet()
    }
}
