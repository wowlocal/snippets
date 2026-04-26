import AppKit
import ServiceManagement
import UniformTypeIdentifiers

private extension NSUserInterfaceItemIdentifier {
    static let snippetsMoreMenu = NSUserInterfaceItemIdentifier("SnippetsMoreMenu")
}

extension ViewController: NSMenuDelegate, NSMenuItemValidation {
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

    @objc func toggleSidebarAnimated(_ sender: Any?) {
        guard let sidebarItem = mainSidebarSplitItem else { return }
        let willCollapse = !sidebarItem.isCollapsed
        let shouldMoveFocusAfterCollapse = willCollapse && shouldMoveFocusAfterCollapsingSidebar()
        storeSidebarCollapsedState(isCollapsed: willCollapse)
        hideSearchSuggestionOverlay()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed.toggle()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.view.layoutSubtreeIfNeeded()
                self?.storeSidebarCollapsedState(isCollapsed: willCollapse)
                self?.restoreMainSplitViewDividerIfNeeded()
                self?.updateSnippetTextViewWrappingWidth()
                self?.hideSearchSuggestionOverlay()
                if shouldMoveFocusAfterCollapse {
                    self?.focusEditorAfterCollapsingSidebar()
                }
            }
        }
    }

    private func shouldMoveFocusAfterCollapsingSidebar() -> Bool {
        if isSearchFieldActive {
            return true
        }

        guard let firstResponder = view.window?.firstResponder else {
            return true
        }

        return firstResponder === tableView
            || firstResponder === tableView.enclosingScrollView
            || firstResponder === tableView.currentEditor()
    }

    private func focusEditorAfterCollapsingSidebar() {
        guard let window = view.window else { return }

        let target: NSResponder = selectedSnippetID == nil ? view : snippetTextView
        window.makeFirstResponder(target)
        hideSearchSuggestionOverlay()
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
        updateActionPanelShortcutVisibility(showAll: currentModifierFlags.contains(.option))
        requestFirstResponder(tableView)
    }

    func closeActionPanel() {
        actionOverlayView.isHidden = true
        updateActionPanelShortcutVisibility(showAll: false)
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
        let menu = makeMoreMenu()
        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.identifier = .snippetsMoreMenu
        menu.delegate = self
        populateMoreMenu(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == .snippetsMoreMenu else { return }
        populateMoreMenu(menu)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copySelectedSnippetShareLink) {
            return selectedSnippet != nil
        }

        if menuItem.action == #selector(toggleLaunchAtLogin) {
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            return true
        }

        if menuItem.action == #selector(resetQuitChoice(_:)) {
            return (NSApp.delegate as? AppDelegate)?.hasRememberedQuitBehavior == true
        }

        return true
    }

    private func populateMoreMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let importItem = LiquidGlassDesign.menuItem(
            title: "Import...",
            symbolName: "square.and.arrow.down",
            action: #selector(runImport),
            target: self
        )
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.keyEquivalent = "I"

        let exportItem = LiquidGlassDesign.menuItem(
            title: "Export...",
            symbolName: "square.and.arrow.up",
            action: #selector(runExport),
            target: self
        )
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.keyEquivalent = "E"

        let shareItem = LiquidGlassDesign.menuItem(
            title: "Copy Share Link",
            symbolName: "link",
            action: #selector(copySelectedSnippetShareLink),
            target: self
        )
        shareItem.keyEquivalentModifierMask = [.command, .shift]
        shareItem.keyEquivalent = "C"
        shareItem.isEnabled = selectedSnippet != nil

        let shortcutsItem = LiquidGlassDesign.menuItem(
            title: "Keyboard Shortcuts",
            symbolName: "keyboard",
            action: #selector(toggleActionPanel),
            target: self
        )
        shortcutsItem.keyEquivalentModifierMask = [.command]
        shortcutsItem.keyEquivalent = "k"

        menu.addItem(importItem)
        menu.addItem(exportItem)
        menu.addItem(shareItem)
        menu.addItem(shortcutsItem)
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        LiquidGlassDesign.applyMenuSymbol("power", to: loginItem)
        menu.addItem(loginItem)
        if (NSApp.delegate as? AppDelegate)?.hasRememberedQuitBehavior == true {
            menu.addItem(.separator())
            let resetQuitItem = LiquidGlassDesign.menuItem(
                title: "Reset Remembered Cmd+Q Choice",
                symbolName: "arrow.uturn.backward",
                action: #selector(resetQuitChoice),
                target: self
            )
            menu.addItem(resetQuitItem)
        }
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

        let snippet = store.addSnippet()
        reloadVisibleSnippets(keepSelection: true)
        selectSnippet(id: snippet.id, focusEditorName: true)
        importExportMessage = "Created snippet."
    }

    @objc func deleteSelectedSnippet(_ sender: Any?) {
        guard let selectedSnippetID else { return }
        let deletedSnippetName = selectedSnippet?.displayName ?? "snippet"
        store.delete(snippetID: selectedSnippetID)
        reloadVisibleSnippets(keepSelection: true)
        applySelectedSnippetToEditor()
        closeActionPanel()
        importExportMessage = "Deleted \(deletedSnippetName)."
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

    func toggleEnabledSelectedSnippet() {
        guard let selectedSnippetID else { return }
        store.toggleEnabled(snippetID: selectedSnippetID)

        let isEnabled = store.snippet(id: selectedSnippetID)?.isEnabled == true
        importExportMessage = isEnabled ? "Enabled snippet." : "Disabled snippet."

        applySelectedSnippetToEditor()
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

    @objc func copySelectedSnippetShareLink() {
        guard let selectedSnippet else { return }

        do {
            let url = try SnippetDeepLink.url(for: selectedSnippet)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
            importExportMessage = "Copied share link for \(selectedSnippet.displayName)."
            closeActionPanel()
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc func runImport(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a snippets JSON file to import."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var options = SnippetStore.ImportOptions()

        if store.detectsRaycastExclamationKeywords(in: url) {
            let alert = NSAlert()
            alert.messageText = "Preserve \"!\" in Keywords?"
            alert.informativeText = "Some Raycast snippets use \"!\" as part of the keyword (for example \"!email\"). Keep it when importing? Leading backslashes are removed automatically."
            alert.addButton(withTitle: "Preserve \"!\"")
            alert.addButton(withTitle: "Remove \"!\"")
            let response = alert.runModal()
            options.preserveExclamationPrefix = (response == .alertFirstButtonReturn)
        }

        do {
            let count = try store.importSnippets(from: url, options: options)
            importExportMessage = "Imported \(count) snippet(s) from \(url.lastPathComponent)."
            reloadVisibleSnippets(keepSelection: true)
            if selectedSnippetID == nil, let id = visibleSnippets.first?.id {
                selectSnippet(id: id, focusEditorName: false)
            }
            requestFirstResponder(tableView)
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

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                importExportMessage = "Launch at Login disabled."
            } else {
                try service.register()
                importExportMessage = "Launch at Login enabled."
            }
        } catch {
            importExportMessage = "Couldn't update Launch at Login."
            NSLog("Launch at login toggle failed: \(error)")
        }
    }

    @objc func resetQuitChoice(_ sender: Any?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.resetQuitBehaviorPreference(sender)
        importExportMessage = "Remembered Cmd+Q choice reset. You will be asked next time."
    }

    func performUndo() {
        guard store.undo() else { return }
        reloadVisibleSnippets(keepSelection: true)
        applySelectedSnippetToEditor()
        closeActionPanel()
        importExportMessage = "Undid last change."
    }

    func performRedo() {
        guard store.redo() else { return }
        reloadVisibleSnippets(keepSelection: true)
        applySelectedSnippetToEditor()
        closeActionPanel()
        importExportMessage = "Redid last change."
    }
}
