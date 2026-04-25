import AppKit
import Carbon.HIToolbox

extension ViewController {
    func installKeyboardMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                return handleKeyEvent(event)
            case .flagsChanged:
                handleModifierFlagsChanged(event)
                return event
            default:
                return event
            }
        }
    }

    func handleModifierFlagsChanged(_ event: NSEvent) {
        guard !actionOverlayView.isHidden else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateActionPanelShortcutVisibility(showAll: flags.contains(.option))
    }

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Let modal alerts/sheets consume keyboard events (Enter/Escape/etc).
        if NSApp.modalWindow != nil {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.keyCode  // Physical key position — layout-independent

        if key == UInt16(kVK_Escape) {
            if !actionOverlayView.isHidden {
                closeActionPanel()
            } else if isSearchSuggestionOverlayVisible {
                hideSearchSuggestionOverlay()
            } else {
                requestFirstResponder(tableView)
            }
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_Z) && !isSearchFieldActive && !isEditingDetails {
            performUndo()
            return nil
        }

        if flags == [.command, .shift] && key == UInt16(kVK_ANSI_Z) && !isSearchFieldActive && !isEditingDetails {
            performRedo()
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_B) {
            toggleSidebarAnimated(nil)
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_F) {
            requestFirstResponder(searchField)
            updateSearchSuggestionOverlay()
            return nil
        }

        if isSearchFieldActive && handleSearchSuggestionKeyEvent(event) {
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_K) {
            toggleActionPanel()
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_N) {
            createSnippet(nil)
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_Delete) && isListContext {
            deleteSelectedSnippet(nil)
            return nil
        }

        if flags == [.command, .shift] && key == UInt16(kVK_ANSI_I) {
            runImport(nil)
            return nil
        }

        if flags == [.command, .shift] && key == UInt16(kVK_ANSI_E) {
            runExport(nil)
            return nil
        }

        if flags == [.command, .shift] && key == UInt16(kVK_ANSI_C) && isListContext {
            copySelectedSnippetShareLink()
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_E) {
            editSelectedSnippet()
            return nil
        }

        if flags == [.command] && isReturnKey(event) {
            pasteSelectedSnippet()
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_D) {
            duplicateSelectedSnippet()
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_Slash) {
            toggleEnabledSelectedSnippet()
            return nil
        }

        if flags == [.command] && key == UInt16(kVK_ANSI_Period) {
            togglePinnedSelectedSnippet()
            return nil
        }

        if isSearchFieldActive {
            return event
        }

        if flags == [.control] && key == UInt16(kVK_ANSI_N) && isListContext {
            selectAdjacentSnippet(direction: .down)
            return nil
        }

        if flags == [.control] && key == UInt16(kVK_ANSI_P) && isListContext {
            selectAdjacentSnippet(direction: .up)
            return nil
        }

        if flags.isEmpty && isReturnKey(event) && isListContext {
            copySelectedSnippet()
            return nil
        }

        return event
    }

    var isSearchFieldActive: Bool {
        guard let firstResponder = view.window?.firstResponder else { return false }
        return firstResponder === searchField.currentEditor() || firstResponder === searchField
    }

    var currentModifierFlags: NSEvent.ModifierFlags {
        let event = view.window?.currentEvent ?? NSApp.currentEvent
        return event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
    }

    var isListContext: Bool {
        guard let firstResponder = view.window?.firstResponder else { return true }

        if firstResponder === tableView || firstResponder === tableView.enclosingScrollView {
            return true
        }

        if isSearchFieldActive {
            return false
        }

        if firstResponder === snippetTextView {
            return false
        }

        if firstResponder === nameField.currentEditor() || firstResponder === keywordField.currentEditor() {
            return false
        }

        return true
    }

    func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
    }

    enum TableDirection { case up, down }

    func selectAdjacentSnippet(direction: TableDirection) {
        guard !visibleSnippets.isEmpty else { return }
        let current = tableView.selectedRow
        let next: Int
        switch direction {
        case .down:
            next = current < visibleSnippets.count - 1 ? current + 1 : current
        case .up:
            next = current > 0 ? current - 1 : 0
        }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}
