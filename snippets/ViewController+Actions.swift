import AppKit
import ServiceManagement
import UniformTypeIdentifiers

private extension NSUserInterfaceItemIdentifier {
    static let snippetsMoreMenu = NSUserInterfaceItemIdentifier("SnippetsMoreMenu")
}

private enum SeededName {
    /// Matches the cap `Snippet.contentFirstLine` uses for a derived name.
    static let maxLength = 50
}

/// The one pasteboard read behind ⇧⌘N, the Services handler and the status-bar
/// item's live title, so the three can never disagree about what "the clipboard"
/// currently holds.
enum ClipboardCapture {
    /// Nil rather than "" for whitespace-only content: a snippet made of blanks
    /// draws an empty row and expands to nothing, which reads as a broken app.
    static var text: String? {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// One short line. What lands on the clipboard is routinely a paragraph, and
    /// a menu item is a single line that NSMenu will happily draw at the full
    /// width of the screen, so the newlines have to go before the truncation.
    static func menuPreview(of text: String) -> String {
        let maxCharacters = 30
        let singleLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard singleLine.count > maxCharacters else { return singleLine }
        let endIndex = singleLine.index(singleLine.startIndex, offsetBy: maxCharacters)
        return String(singleLine[..<endIndex]) + "…"
    }
}

extension ViewController: NSMenuDelegate, NSMenuItemValidation {
    func selectSnippet(id: UUID, focus: EditorFocusTarget?) {
        let outgoingSnippetID = selectedSnippetID
        selectedSnippetID = id
        // Selecting from code never reaches `tableViewSelectionDidChange` with an
        // outgoing ID to look at — the assignment above is what that callback
        // compares against — so a blank draft left behind by a deep link, a
        // search suggestion or a duplicate is taken back out here instead.
        if outgoingSnippetID != id {
            discardBlankDraftAfterLeaving(outgoingSnippetID)
        }
        syncTableSelectionWithSelectedSnippet()
        applySelectedSnippetToEditor()
        restoreEditorFocus(focus)
    }

    /// Discards a still-blank ⌘N draft the user has just left.
    ///
    /// A runloop turn late on purpose. `requestFirstResponder` hands focus off
    /// asynchronously and a token field only finalizes its trailing tag when
    /// editing actually ends, so acting now could take away a snippet the user is
    /// still mid-word in; and the table's own selection notification is no place
    /// to remove one of its rows. By the time this runs, everything typed has
    /// reached the store — and the store checks again, because a draft that is no
    /// longer blank is no longer a draft.
    func discardBlankDraftAfterLeaving(_ snippetID: UUID?) {
        guard let snippetID, store.blankDraftSnippet?.id == snippetID else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, store.blankDraftSnippet?.id == snippetID else { return }
            store.discardBlankDraft(id: snippetID)
        }
    }

    /// Hands focus over, and takes back the blank draft behind it when that
    /// leaves the editor.
    ///
    /// There is no funnel every exit passes through — Escape, ⌘F and Shift-Tab
    /// off the content box each go straight to `requestFirstResponder` and commit
    /// nothing on the way — so leaving them to say so one at a time is how the
    /// Shift-Tab exit shipped without saying it. Routing the hops through here
    /// instead means the next one anybody adds cannot forget, and the hops that
    /// land on another editor field pass through unchanged: the draft is only
    /// abandoned when the whole editor is.
    func moveFocus(to responder: NSResponder) {
        let abandonedSnippetID = isEditorField(responder) ? nil : selectedSnippetID
        requestFirstResponder(responder)
        discardBlankDraftAfterLeaving(abandonedSnippetID)
    }

    private func isEditorField(_ responder: NSResponder) -> Bool {
        responder === snippetTextView
            || responder === keywordField
            || responder === nameField
            || responder === tagsField
            || responder === enabledCheckbox
    }

    /// The window is going away or the app is quitting, so whichever draft is
    /// open is abandoned by definition and the selection is beside the point.
    ///
    /// Synchronous, unlike the above: termination has no next runloop turn, and
    /// the discard writes to disk immediately. Ending editing first is what
    /// finalizes a half-typed tag token — the one thing a blank draft can be
    /// holding that the store has not been told about yet.
    func discardOpenBlankDraft() {
        guard store.blankDraftSnippet != nil else { return }
        commitActiveEditorState(endingEditing: true)

        guard let draftID = store.blankDraftSnippet?.id else { return }
        store.discardBlankDraft(id: draftID)
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
        // ⌘B is the user taking the wheel, so the width rule no longer owns this
        // sidebar's state either way. Asking for it *back* at a width the rule
        // would immediately hide it at also stands the rule down, until the
        // window is wide again — otherwise the sidebar would vanish again in the
        // same breath. (Showing it usually widens the window past the expand
        // width on its own, which clears the suppression immediately; that is
        // fine, the end state is the same. It matters when the window has no room
        // to grow.)
        isSidebarAutoCollapsed = false
        if !willCollapse, adaptiveSidebarReferenceWidth < MainLayoutMetrics.sidebarAutoExpandWidth {
            isAutomaticSidebarCollapseSuppressed = true
        }
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

    @objc func requestPermission() {
        engine.requestAccessibilityPermission()
    }

    @objc func openAccessibilitySettings() {
        engine.openAccessibilitySettings()
    }

    @objc func showMoreMenu(_ sender: NSButton) {
        let menu = makeMoreMenu()
        let menuVerticalGap: CGFloat = 8
        let location = NSPoint(x: 0, y: sender.bounds.height + menuVerticalGap)
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

    @objc func handleToggleActionsNotification() {
        toggleActionPanel()
    }

    @objc func createSnippet(_ sender: Any?) {
        createSnippet(seededContent: nil, seededName: nil)
    }

    /// Deliberately a no-op with a status line rather than an empty snippet: the
    /// user asked to save something specific, and creating a blank draft instead
    /// looks like the clipboard was captured when it was not.
    @objc func createSnippetFromClipboard(_ sender: Any?) {
        guard let text = ClipboardCapture.text else {
            importExportMessage = "Clipboard has no text to save."
            return
        }

        createSnippet(seededContent: text, seededName: nil)
    }

    func createSnippet(seededContent: String?, seededName: String?) {
        commitActiveEditorState(endingEditing: true)

        // Read the query before clearing it: the search field is the only place
        // the user has already said what the missing snippet is called.
        let queryName = nameSeedFromSearchQuery()
        if !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchField.stringValue = ""
        }

        // Adopt the active tag filters so the snippet lands inside the list the
        // user is looking at instead of being created invisible.
        let inheritedTags = activeTagFilterTags()
        // A caller that already knows the name outranks the search query.
        let name = seededName.flatMap { $0.isEmpty ? nil : $0 } ?? queryName

        // ⌘N with an untouched one already open is the same request twice rather
        // than a request for a second blank row — the one on screen is exactly
        // what this would create. Anything seeded is a different request, and
        // then the untouched draft goes instead of lingering beside the real
        // snippet the user came here to make.
        if let draft = store.blankDraftSnippet {
            if seededContent == nil, name == nil, inheritedTags.isEmpty {
                reloadVisibleSnippets(keepSelection: true)
                selectSnippet(id: draft.id, focus: .content)
                importExportMessage = "Already editing a new snippet."
                return
            }

            store.discardBlankDraft(id: draft.id)
        }

        let snippet = store.addSnippet(name: name ?? "", content: seededContent ?? "", tags: inheritedTags)

        reloadVisibleSnippets(keepSelection: true)
        // With nothing seeded the content box is where the snippet begins;
        // once text arrives the keyword is the only thing still stopping it
        // from working.
        selectSnippet(id: snippet.id, focus: seededContent == nil ? .content : .keyword)

        // Name the snippet in the status line: it is now the fourth field down
        // and can sit below the fold, so a silently adopted search query would
        // otherwise be invisible.
        let subject = name.map { "“\($0)”" } ?? "snippet"
        importExportMessage = inheritedTags.isEmpty
            ? "Created \(subject)."
            : "Created \(subject) tagged \(inheritedTags.joined(separator: ", "))."
    }

    /// The search query, when it can plausibly be a name rather than a filter.
    ///
    /// Only when it matched nothing: a query that is still narrowing a visible
    /// list is being used as a filter, and adopting it would put a name on a
    /// snippet the user never described. A query that found nothing is the
    /// opposite — it is the thing that does not exist yet, which is why ⌘N was
    /// pressed. A leading backslash is dropped because that is how this app
    /// writes keywords, so "\sig" is someone hunting a keyword, not a name.
    private func nameSeedFromSearchQuery() -> String? {
        guard visibleSnippets.isEmpty else { return nil }

        var query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while query.hasPrefix("\\") {
            query.removeFirst()
            query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Past the length a name is ever displayed at, this is someone
        // searching for a phrase inside snippet bodies.
        guard !query.isEmpty, query.count <= SeededName.maxLength else { return nil }
        return query
    }

    @objc func deleteSelectedSnippet(_ sender: Any?) {
        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID,
              let targetSnippet = store.snippet(id: targetSnippetID) else { return }
        let deletedSnippetName = targetSnippet.displayName
        store.delete(snippetID: targetSnippetID)
        reloadVisibleSnippets(keepSelection: true)
        applySelectedSnippetToEditor()
        closeActionPanel()
        importExportMessage = "Deleted \(deletedSnippetName)."
    }

    func editSelectedSnippet() {
        guard selectedSnippet != nil else { return }
        closeActionPanel()
        // The content box, not the name field: with the editor content-first the
        // name is the fourth field down, so "Edit Snippet" was dropping the caret
        // past everything the user is likely to have opened it to change.
        requestFirstResponder(snippetTextView)
    }

    func duplicateSelectedSnippet() {
        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID,
              let duplicate = store.duplicate(snippetID: targetSnippetID) else { return }

        if duplicate.isEnabled || duplicate.normalizedKeyword.isEmpty {
            importExportMessage = "Duplicated \(duplicate.displayName)."
        } else {
            importExportMessage = "Duplicated \(duplicate.displayName) and disabled the copy to avoid a duplicate keyword."
        }
        reloadVisibleSnippets(keepSelection: true)
        // The copy carries the source's keyword verbatim and was disabled for
        // exactly that reason, so the keyword is the one field that must change.
        selectSnippet(id: duplicate.id, focus: .keyword)
        closeActionPanel()
    }

    func togglePinnedSelectedSnippet() {
        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID else { return }
        store.togglePinned(snippetID: targetSnippetID)

        let isPinned = store.snippet(id: targetSnippetID)?.isPinned == true
        importExportMessage = isPinned ? "Pinned snippet." : "Unpinned snippet."

        reloadVisibleSnippets(keepSelection: true)
        if let snippet = store.snippet(id: targetSnippetID) {
            applySnippetToEditor(snippet)
        }
        closeActionPanel()
    }

    func resetUsageForSelectedSnippet() {
        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID else { return }
        let name = store.snippet(id: targetSnippetID)?.displayName
        usageStore.forget(snippetID: targetSnippetID)

        importExportMessage = name.map { "Reset usage history for \($0)." } ?? "Reset usage history."

        reloadVisibleSnippets(keepSelection: true)
        closeActionPanel()
    }

    func toggleEnabledSelectedSnippet() {
        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID else { return }
        store.toggleEnabled(snippetID: targetSnippetID)

        let isEnabled = store.snippet(id: targetSnippetID)?.isEnabled == true
        importExportMessage = isEnabled ? "Enabled snippet." : "Disabled snippet."

        if let snippet = store.snippet(id: targetSnippetID) {
            applySnippetToEditor(snippet)
        }
        closeActionPanel()
    }

    func copySelectedSnippet() {
        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID,
              let snippet = store.snippet(id: targetSnippetID) else { return }
        engine.copySnippetToClipboard(snippet)
        importExportMessage = "Copied \(snippet.displayName) to clipboard."
    }

    func pasteSelectedSnippet() {
        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID,
              let snippet = store.snippet(id: targetSnippetID) else { return }
        engine.pasteSnippetIntoFrontmostApp(snippet)
        importExportMessage = "Pasting \(snippet.displayName)."
    }

    @objc func copySelectedSnippetShareLink() {
        let targetSnippetID = activeCommandSnippetID()
        commitActiveEditorState(endingEditing: true)

        guard let targetSnippetID,
              let snippet = store.snippet(id: targetSnippetID) else { return }

        do {
            let url = try SnippetDeepLink.url(for: snippet)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
            importExportMessage = "Copied share link for \(snippet.displayName)."
            closeActionPanel()
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc func runImport(_ sender: Any?) {
        commitActiveEditorState(endingEditing: true)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a snippets JSON file to import."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        performImport(from: url)
    }

    /// Everything after a file has been chosen, so a route that already holds a
    /// URL does not have to reopen the open panel to reach the Raycast
    /// migration — today the app's strongest import path is only reachable from
    /// one menu three levels deep.
    func performImport(from url: URL) {
        commitActiveEditorState(endingEditing: true)

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
                selectSnippet(id: id, focus: nil)
            }
            requestFirstResponder(tableView)
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc func runExport(_ sender: Any?) {
        commitActiveEditorState(endingEditing: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "snippets-export.json"
        panel.message = "Choose where to save your snippets export."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // A ⌘N draft nobody typed into is not a snippet anyone meant to export,
        // and abandoning it any other way leaves nothing behind. Discard after
        // the panel commits, so cancelling the export does not delete the draft.
        discardOpenBlankDraft()

        do {
            let count = try store.exportSnippets(to: url)
            importExportMessage = "Exported \(count) snippet(s) to \(url.lastPathComponent)."
            requestFirstResponder(tableView)
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc func enabledStateChanged() {
        store.beginEditTransaction()
        updateSelectedSnippetFromEditor()
        store.commitEditTransaction()
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
