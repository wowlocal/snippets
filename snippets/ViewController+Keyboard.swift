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

        if flags == [.command] && lowerCharacters == "n" {
            createSnippet(nil)
            return nil
        }

        if flags == [.command] && event.keyCode == UInt16(kVK_Delete) {
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

        if !actionOverlayView.isHidden {
            if flags == [.command] && isReturnKey(event) {
                pasteSelectedSnippet()
                closeActionPanel()
                return nil
            }
            if flags == [.command] && lowerCharacters == "e" {
                editSelectedSnippet()
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
            return event
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
}
