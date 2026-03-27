import AppKit
import ServiceManagement
import UniformTypeIdentifiers

extension ViewController {
    func showWarningAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func selectSnippet(id: UUID, focusEditorName: Bool) {
        selectedSnippetID = id
        syncTableSelectionWithSelectedSnippet()
        applySelectedSnippetToEditor()

        if focusEditorName {
            requestFirstResponder(nameField)
        }
    }

    func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Import / Export Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func importMessage(for result: SnippetStore.ImportResult, fileName: String) -> String {
        var parts: [String] = []

        if result.importedCount > 0 {
            parts.append("Imported \(result.importedCount) snippet(s)")
        }

        if !result.duplicateNames.isEmpty {
            parts.append("Skipped \(result.duplicateNames.count) duplicate(s)")
        }

        if parts.isEmpty {
            return "No snippets were imported from \(fileName)."
        }

        return parts.joined(separator: ", ") + " from \(fileName)."
    }

    func duplicateWarningMessage(for names: [String]) -> String {
        let visibleNames = names.prefix(3).map { "\"\($0)\"" }
        let remainderCount = names.count - visibleNames.count
        let listedNames = visibleNames.joined(separator: ", ")

        if names.count == 1, let first = names.first {
            return "The snippet is already there named \"\(first)\". It was skipped."
        }

        if remainderCount > 0 {
            return "These snippets are already there: \(listedNames), and \(remainderCount) more. They were skipped."
        }

        return "These snippets are already there: \(listedNames). They were skipped."
    }

    @objc func toggleActionPanel() {
        if actionOverlayView.isHidden {
            openActionPanel()
        } else {
            closeActionPanel()
        }
    }

    func openActionPanel() {
        actionOverlayView.isHidden = false
        requestFirstResponder(tableView)
    }

    func closeActionPanel() {
        actionOverlayView.isHidden = true
        requestFirstResponder(tableView)
    }

    @objc func refreshPermissions() {
        engine.refreshAccessibilityStatus(prompt: false)
    }

    @objc func requestPermission() {
        engine.requestAccessibilityPermission()
    }

    @objc func openAccessibilitySettings() {
        engine.openAccessibilitySettings()
    }

    @objc func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let importItem = NSMenuItem(title: "Import...", action: #selector(runImport), keyEquivalent: "I")
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.target = self
        let exportItem = NSMenuItem(title: "Export...", action: #selector(runExport), keyEquivalent: "E")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.target = self
        menu.addItem(importItem)
        menu.addItem(exportItem)
        menu.addItem(.separator())
        let newGroupItem = NSMenuItem(title: "New Group...", action: #selector(createGroupFromMenu), keyEquivalent: "")
        newGroupItem.target = self
        menu.addItem(newGroupItem)
        if let groupID = selectedGroupFilter.groupID, let group = store.group(id: groupID) {
            let renameItem = NSMenuItem(title: "Rename Current Group...", action: #selector(renameCurrentGroup), keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)
            let deleteItem = NSMenuItem(title: "Delete Current Group...", action: #selector(deleteCurrentGroup), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
            deleteItem.toolTip = "Delete \(group.displayName)"
        }
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        if (NSApp.delegate as? AppDelegate)?.hasRememberedQuitBehavior == true {
            menu.addItem(.separator())
            let resetQuitItem = NSMenuItem(title: "Forget Cmd+Q Choice", action: #selector(resetQuitChoice), keyEquivalent: "")
            resetQuitItem.target = self
            menu.addItem(resetQuitItem)
        }
        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc func handleCreateNewNotification() {
        createSnippet(nil)
    }

    @objc func handleToggleActionsNotification() {
        toggleActionPanel()
    }

    @objc func createSnippet(_ sender: Any?) {
        if !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchField.stringValue = ""
        }

        let snippet = store.addSnippet(defaultGroupID: selectedGroupFilter.groupID)
        importExportMessage = nil
        reloadVisibleSnippets(keepSelection: true)
        selectSnippet(id: snippet.id, focusEditorName: true)
    }

    @objc func deleteSelectedSnippet(_ sender: Any?) {
        guard let selectedSnippetID else { return }
        store.delete(snippetID: selectedSnippetID)
        reloadVisibleSnippets(keepSelection: true)
        applySelectedSnippetToEditor()
        closeActionPanel()
    }

    func editSelectedSnippet() {
        guard selectedSnippet != nil else { return }
        closeActionPanel()
        requestFirstResponder(nameField)
    }

    func duplicateSelectedSnippet() {
        guard let selectedSnippetID,
              let duplicate = store.duplicate(snippetID: selectedSnippetID) else { return }

        importExportMessage = "Duplicated \(duplicate.displayName)."
        reloadVisibleSnippets(keepSelection: true)
        selectSnippet(id: duplicate.id, focusEditorName: true)
        closeActionPanel()
    }

    func togglePinnedSelectedSnippet() {
        guard let selectedSnippetID else { return }
        store.togglePinned(snippetID: selectedSnippetID)

        let isPinned = store.snippet(id: selectedSnippetID)?.isPinned == true
        importExportMessage = isPinned ? "Pinned snippet." : "Unpinned snippet."

        reloadVisibleSnippets(keepSelection: true)
        closeActionPanel()
    }

    func copySelectedSnippet() {
        guard let selectedSnippet else { return }
        engine.copySnippetToClipboard(selectedSnippet)
        importExportMessage = "Copied \(selectedSnippet.displayName) to clipboard."
    }

    func pasteSelectedSnippet() {
        guard let selectedSnippet else { return }
        engine.pasteSnippetIntoFrontmostApp(selectedSnippet)
        importExportMessage = "Pasting \(selectedSnippet.displayName)."
    }

    @objc func runImport(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a snippets JSON file to import."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try store.importSnippets(from: url)
            importExportMessage = importMessage(for: result, fileName: url.lastPathComponent)
            reloadVisibleSnippets(keepSelection: true)
            if selectedSnippetID == nil, let id = visibleSnippets.first?.id {
                selectSnippet(id: id, focusEditorName: false)
            }
            requestFirstResponder(tableView)

            if !result.duplicateNames.isEmpty {
                showWarningAlert(
                    title: "Some snippets already exist",
                    message: duplicateWarningMessage(for: result.duplicateNames)
                )
            }
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc func runExport(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "snippets-export.json"
        panel.message = "Choose where to save your snippets export."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let count = try store.exportSnippets(to: url)
            importExportMessage = "Exported \(count) snippet(s) to \(url.lastPathComponent)."
            requestFirstResponder(tableView)
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc func enabledStateChanged() {
        updateSelectedSnippetFromEditor()
    }

    @objc func handleGroupFilterButton(_ sender: GroupFilterButton) {
        selectGroupFilter(sender.filter)
        requestFirstResponder(tableView)
    }

    @objc func groupPopUpSelectionChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingGroupPopUp else { return }
        guard let selectedSnippetID, let representedObject = sender.selectedItem?.representedObject as? String else {
            rebuildGroupPopUpMenu()
            return
        }

        if representedObject == GroupPopUpItemKind.newGroup {
            promptToCreateGroup(assignToSelectedSnippet: true)
            return
        }

        let groupID = representedObject == GroupPopUpItemKind.ungrouped ? nil : UUID(uuidString: representedObject)
        adjustSelectedGroupFilterForSnippetGroupChange(to: groupID)
        store.assignGroup(snippetID: selectedSnippetID, groupID: groupID)

        if let groupName = store.groupName(for: groupID) {
            importExportMessage = "Moved snippet to \(groupName)."
        } else {
            importExportMessage = "Moved snippet to Ungrouped."
        }
    }

    @objc func createGroupFromMenu() {
        promptToCreateGroup(assignToSelectedSnippet: false)
    }

    @objc func renameCurrentGroup() {
        guard let groupID = selectedGroupFilter.groupID, let group = store.group(id: groupID) else { return }

        promptForGroupName(
            title: "Rename Group",
            message: "Enter a new name for \(group.displayName).",
            defaultValue: group.displayName,
            confirmTitle: "Rename"
        ) { [weak self] name in
            guard let self else { return }
            guard let name else { return }

            do {
                let renamed = try self.store.renameGroup(groupID: groupID, to: name)
                self.importExportMessage = "Renamed group to \(renamed.displayName)."
            } catch {
                self.showWarningAlert(title: "Group Not Renamed", message: error.localizedDescription)
            }
        }
    }

    @objc func deleteCurrentGroup() {
        guard let groupID = selectedGroupFilter.groupID, let group = store.group(id: groupID) else { return }

        let memberCount = store.snippets.filter { $0.groupID == groupID }.count
        let alert = NSAlert()
        alert.messageText = "Delete \(group.displayName)?"
        alert.informativeText = memberCount == 1
            ? "The snippet in this group will be moved to Ungrouped."
            : "\(memberCount) snippets in this group will be moved to Ungrouped."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Group")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.selectedGroupFilter = .ungrouped
            self.refreshGroupControls()
            self.store.deleteGroup(groupID: groupID)
            self.importExportMessage = "Deleted \(group.displayName)."
        }

        if let window = view.window ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
    }

    @objc func resetQuitChoice(_ sender: Any?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.resetQuitBehaviorPreference(sender)
        importExportMessage = "Cmd+Q choice reset. You will be asked next time."
    }

    func promptToCreateGroup(assignToSelectedSnippet: Bool) {
        promptForGroupName(
            title: "New Group",
            message: "Enter a name for the new group.",
            defaultValue: "",
            confirmTitle: "Create"
        ) { [weak self] name in
            guard let self else { return }
            guard let name else {
                self.rebuildGroupPopUpMenu()
                return
            }

            do {
                let result = try self.store.createOrFindGroup(named: name)

                if assignToSelectedSnippet, let selectedSnippetID = self.selectedSnippetID {
                    self.adjustSelectedGroupFilterForSnippetGroupChange(to: result.group.id)
                    self.store.assignGroup(snippetID: selectedSnippetID, groupID: result.group.id)
                    self.importExportMessage = result.created
                        ? "Created \(result.group.displayName) and assigned the snippet."
                        : "Assigned the snippet to \(result.group.displayName)."
                } else {
                    self.selectGroupFilter(.group(result.group.id), shouldTouchGroup: false)
                    self.importExportMessage = result.created
                        ? "Created group \(result.group.displayName)."
                        : "Selected group \(result.group.displayName)."
                }
            } catch {
                self.rebuildGroupPopUpMenu()
                self.showWarningAlert(title: "Group Not Created", message: error.localizedDescription)
            }
        }
    }

    func promptForGroupName(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String,
        completion: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: defaultValue)
        field.placeholderString = "Group name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field

        let responseHandler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                completion(field.stringValue)
            } else {
                completion(nil)
            }
        }

        if let window = view.window ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                responseHandler(response)
            }
        } else {
            responseHandler(alert.runModal())
        }
    }
}
