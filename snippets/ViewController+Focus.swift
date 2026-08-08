import AppKit

extension ViewController {
    func requestFirstResponder(_ responder: NSResponder?) {
        guard let responder else { return }

        // Defer responder changes to the next run-loop tick to avoid doing
        // synchronous focus handoffs while AppKit is processing input events.
        DispatchQueue.main.async { [weak self, weak responder] in
            guard let self,
                  let responder,
                  let window = self.view.window else { return }

            if window.firstResponder === responder {
                return
            }

            if let textField = responder as? NSTextField,
               window.firstResponder === textField.currentEditor() {
                return
            }

            // Never hand focus to something nobody can see. Shift-Tab out of the
            // content box aims at the snippet list, which is inside the sidebar —
            // so with the sidebar away the caret vanished and keystrokes went to
            // an invisible table. Reachable by ⌘B before, and by simply narrowing
            // the window now.
            if let view = responder as? NSView, view.isHiddenOrHasHiddenAncestor {
                return
            }

            window.makeFirstResponder(responder)
        }
    }
}
