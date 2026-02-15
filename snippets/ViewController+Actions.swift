import AppKit
import ServiceManagement
import UniformTypeIdentifiers

extension ViewController {
    func selectSnippet(id: UUID, focusEditorName: Bool) {
        selectedSnippetID = id
        syncTableSelectionWithSelectedSnippet()
        applySelectedSnippetToEditor()

        if focusEditorName {
            view.window?.makeFirstResponder(nameField)
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

    func toggleActionPanel() {
        if actionOverlayView.isHidden {
            openActionPanel()
        } else {
            closeActionPanel()
        }
    }

    func openActionPanel() {
        actionOverlayView.isHidden = false
        view.window?.makeFirstResponder(tableView)
    }

    func closeActionPanel() {
        actionOverlayView.isHidden = true
        view.window?.makeFirstResponder(tableView)
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
        let exportItem = NSMenuItem(title: "Export...", action: #selector(runExport), keyEquivalent: "E")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(importItem)
        menu.addItem(exportItem)
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
        let snippet = store.addSnippet()
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
        view.window?.makeFirstResponder(nameField)
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
            let count = try store.importSnippets(from: url)
            importExportMessage = "Imported \(count) snippet(s) from \(url.lastPathComponent)."
            reloadVisibleSnippets(keepSelection: true)
            if selectedSnippetID == nil, let id = visibleSnippets.first?.id {
                selectSnippet(id: id, focusEditorName: false)
            }
            view.window?.makeFirstResponder(tableView)
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
            view.window?.makeFirstResponder(tableView)
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc func enabledStateChanged() {
        updateSelectedSnippetFromEditor()
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
        launchAtLoginCheckbox.state = service.status == .enabled ? .on : .off
    }
}
