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
        let row = tableView.selectedRow
        guard row >= 0, row < visibleSnippets.count else {
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
        selectedSnippetID = nextSelectionID

        if didChangeSelection || !isEditingDetails {
            applySelectedSnippetToEditor()
        }

        deleteButton.isEnabled = true
    }

    func makeSnippetContextMenu(for row: Int) -> NSMenu? {
        guard visibleSnippets.indices.contains(row) else { return nil }

        let snippet = visibleSnippets[row]
        let menu = NSMenu(title: snippet.displayName)
        let items: [NSMenuItem] = [
            contextMenuItem(title: "Copy Snippet", action: #selector(copySelectedSnippetFromContextMenu(_:))),
            contextMenuItem(title: "Paste Snippet", action: #selector(pasteSelectedSnippetFromContextMenu(_:))),
            contextMenuItem(title: "Copy Share Link", action: #selector(copySelectedSnippetShareLink)),
            .separator(),
            contextMenuItem(title: "Duplicate Snippet", action: #selector(duplicateSelectedSnippetFromContextMenu(_:))),
            contextMenuItem(
                title: snippet.isPinned ? "Unpin Snippet" : "Pin Snippet",
                action: #selector(togglePinnedSelectedSnippetFromContextMenu(_:))
            ),
            .separator(),
            contextMenuItem(title: "Delete Snippet", action: #selector(deleteSelectedSnippet(_:)))
        ]

        items.forEach(menu.addItem)
        return menu
    }

    private func contextMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
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

    @objc private func togglePinnedSelectedSnippetFromContextMenu(_ sender: Any?) {
        togglePinnedSelectedSnippet()
    }
}
