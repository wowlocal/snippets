import AppKit

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
            selectedSnippetID = nil
            applySelectedSnippetToEditor()
    
            deleteButton.isEnabled = false
            return
        }

        selectedSnippetID = visibleSnippets[row].id
        applySelectedSnippetToEditor()

        deleteButton.isEnabled = true
    }
}
