import AppKit
import Carbon.HIToolbox

extension ViewController {
    func installKeyboardMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handleKeyEvent(event)
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let lowerCharacters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == UInt16(kVK_Escape) {
            if !actionOverlayView.isHidden {
                closeActionPanel()
            } else {
                view.window?.makeFirstResponder(tableView)
            }
            return nil
        }

        if flags == [.command] && lowerCharacters == "k" {
            toggleActionPanel()
            return nil
        }

        if flags == [.command] && lowerCharacters == "f" {
            view.window?.makeFirstResponder(searchField)
            return nil
        }

        if flags == [.command] && lowerCharacters == "n" {
            createSnippet(nil)
            return nil
        }

        if flags == [.command] && event.keyCode == UInt16(kVK_Delete) && isListContext {
            deleteSelectedSnippet(nil)
            return nil
        }

        if flags == [.command, .shift] && lowerCharacters == "i" {
            runImport(nil)
            return nil
        }

        if flags == [.command, .shift] && lowerCharacters == "e" {
            runExport(nil)
            return nil
        }

        if flags == [.command] && lowerCharacters == "e" {
            editSelectedSnippet()
            return nil
        }

        if flags == [.command] && isReturnKey(event) {
            pasteSelectedSnippet()
            return nil
        }

        if flags == [.command] && lowerCharacters == "d" {
            duplicateSelectedSnippet()
            return nil
        }

        if flags == [.command] && lowerCharacters == "." {
            togglePinnedSelectedSnippet()
            return nil
        }

        if flags == [.control] && lowerCharacters == "n" && isListContext {
            selectAdjacentSnippet(direction: .down)
            return nil
        }

        if flags == [.control] && lowerCharacters == "p" && isListContext {
            selectAdjacentSnippet(direction: .up)
            return nil
        }

        if flags.isEmpty && isReturnKey(event) && isListContext {
            copySelectedSnippet()
            return nil
        }

        return event
    }

    var isListContext: Bool {
        guard let firstResponder = view.window?.firstResponder else { return true }

        if firstResponder === tableView || firstResponder === tableView.enclosingScrollView {
            return true
        }

        if firstResponder === searchField.currentEditor() || firstResponder === searchField {
            return true
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
