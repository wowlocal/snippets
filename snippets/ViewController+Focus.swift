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

            window.makeFirstResponder(responder)
        }
    }
}
