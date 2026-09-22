// Opt-in Chrome smoke test: an isolated temporary profile, synthetic DOM only, no Snippets data.
// Uses the shipping transaction and clipboard lease; verifies the DOM/input-event model, not AXValue.
import AppKit
import ApplicationServices
@testable import SnippetsCore

@MainActor
private final class BrowserConnection {
    let socket: URLSessionWebSocketTask
    private var sequence = 0
    init(url: URL) { socket = URLSession.shared.webSocketTask(with: url); socket.resume() }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        sequence += 1
        let id = sequence
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let bytes: Data
            switch message {
            case .data(let data): bytes = data
            case .string(let text): bytes = Data(text.utf8)
            @unknown default: throw Failure.browser
            }
            let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
            guard response["id"] as? Int == id else { continue }
            guard response["error"] == nil else { throw Failure.browser }
            return response["result"] as? [String: Any] ?? [:]
        }
    }

    func evaluate(_ expression: String) async throws -> Any? {
        let result = try await call("Runtime.evaluate", ["expression": expression, "returnByValue": true])
        guard result["exceptionDetails"] == nil else { throw Failure.browser }
        return (result["result"] as? [String: Any])?["value"]
    }
}

private enum Failure: String, Error { case browser, preflight, acquisition, transaction, model, restoration }

private func quoted(_ string: String) -> String {
    let json = try! JSONSerialization.data(withJSONObject: [string])
    return String(decoding: json, as: UTF8.self).dropFirst().dropLast().description
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.1)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func range(_ element: AXUIElement) -> NSRange? {
    guard let value = attribute(element, "AXSelectedTextRange"),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return NSRange(location: range.location, length: range.length)
}

private func setRange(_ range: NSRange, on element: AXUIElement) -> Bool {
    var range = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &range) else { return false }
    AXUIElementSetMessagingTimeout(element, 0.1)
    return AXUIElementSetAttributeValue(element, "AXSelectedTextRange" as CFString, value) == .success
}

private func text(_ range: NSRange, in element: AXUIElement) -> String? {
    var range = CFRange(location: range.location, length: range.length)
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    AXUIElementSetMessagingTimeout(element, 0.1)
    guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString,
                                                     parameter, &value) == .success else { return nil }
    return value as? String
}

@main
private struct Main {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            print("Requires Accessibility and post-event access for the invoking terminal."); exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let previous = NSWorkspace.shared.frontmostApplication
        let browser = Process()
        browser.executableURL = URL(fileURLWithPath: CommandLine.arguments[2])
        browser.arguments = ["--user-data-dir=\(directory.path)/chrome", "--remote-debugging-port=0",
            "--no-first-run", "--no-default-browser-check", "--disable-sync", "--disable-background-networking",
            "--disable-component-update", "--force-renderer-accessibility", "about:blank"]
        browser.standardOutput = FileHandle.nullDevice
        browser.standardError = FileHandle.nullDevice
        do {
            try browser.run()
            defer {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier {
                    previous?.activate()
                }
                if browser.isRunning { browser.terminate() }
            }
            let portFile = directory.appendingPathComponent("chrome/DevToolsActivePort")
            var port: Int?
            for _ in 0..<100 {
                port = (try? String(contentsOf: portFile, encoding: .utf8))?.split(separator: "\n").first.flatMap { Int($0) }
                if port != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let port else { throw Failure.browser }
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!)
            guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let target = targets.first(where: { $0["type"] as? String == "page" }),
                  let address = target["webSocketDebuggerUrl"] as? String,
                  let url = URL(string: address) else { throw Failure.browser }
            let connection = BrowserConnection(url: url)
            defer { connection.socket.cancel(with: .goingAway, reason: nil) }
            _ = try await connection.evaluate("""
                document.title='Snippets synthetic selection fixture';
                document.body.innerHTML='<h1>Synthetic Snippets paste test</h1><input id="field"><textarea id="area"></textarea><div id="edit" contenteditable="true"></div><input id="other" value="untouched">';
                """)
            _ = try await connection.call("Page.bringToFront")
            NSRunningApplication(processIdentifier: browser.processIdentifier)?.activate()
            let app = AXUIElementCreateApplication(browser.processIdentifier)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

            for (index, field) in ["field", "area", "edit", "field", "field"].enumerated() {
                _ = try await connection.call("Page.bringToFront")
                NSRunningApplication(processIdentifier: browser.processIdentifier)?.activate()
                let prefix = index == 3 ? "😀 before " : ""
                let suffix = index == 3 ? " selected" : ""
                let trigger = "\\fixture"
                let initial = prefix + trigger + suffix + " after"
                let replacement = "Synthetic-тест-😀"
                let caret = (prefix + trigger).utf16.count
                let end = caret + suffix.utf16.count
                let abort = index == 4
                _ = try await connection.evaluate("""
                    window.target=document.getElementById('\(field)'); window.model=\(quoted(initial)); window.inputEvents=0;
                    if(target.isContentEditable) target.textContent=window.model; else target.value=window.model;
                    target.oninput=()=>{window.model=target.isContentEditable?target.textContent:target.value; window.inputEvents++};
                    target.focus();
                    if(target.isContentEditable) {let r=document.createRange(); r.setStart(target.firstChild,\(caret)); r.setEnd(target.firstChild,\(end)); getSelection().removeAllRanges(); getSelection().addRange(r)}
                    else target.setSelectionRange(\(caret),\(end));
                    """)
                // A freshly launched disposable Chrome profile needs to publish its first AX tree.
                // This startup wait is outside the transaction under test.
                var readyElement: AXUIElement?
                for _ in 0..<50 {
                    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    if let focused = attribute(app, "AXFocusedUIElement"), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                        let candidate = focused as! AXUIElement
                        if range(candidate) == NSRange(location: caret, length: suffix.utf16.count) {
                            readyElement = candidate
                            break
                        }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let element = readyElement else {
                    let domReady = try await connection.evaluate("document.activeElement===target") as? Bool == true
                    let focused = attribute(app, "AXFocusedUIElement")
                    print("FAIL case \(index): initial focused field not ready; DOM focus=\(domReady), AX focus available=\(focused != nil), frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier)")
                    throw Failure.preflight
                }
                guard let original = range(element), original == NSRange(location: caret, length: suffix.utf16.count)
                else { print("FAIL case \(index): initial range"); throw Failure.preflight }
                guard let before = text(NSRange(location: 0, length: caret), in: element),
                      let selected = original.length == 0 ? "" : text(original, in: element)
                else { print("FAIL case \(index): initial range text"); throw Failure.preflight }
                guard let proof = VerifiedTriggerSelection.make(
                        deletion: .confirmed(.init(query: "fixture", triggerLength: trigger.count)),
                        textBeforeCaret: before, originalSelection: original, selectedText: selected)
                else { print("FAIL case \(index): initial proof"); throw Failure.preflight }
                let acquisition = TemporaryPasteboardLease.begin(text: replacement, pasteboard: NSPasteboard.general)
                guard case .acquired(let lease) = acquisition else {
                    if case .recoveryPending(let pending) = acquisition { _ = pending.restoreWithRetries() }
                    throw Failure.acquisition
                }
                defer { if !lease.restoreWithRetries() { print("FAIL clipboard restoration pending") } }
                func contextMatches() -> Bool {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier
                        && attribute(app, "AXFocusedUIElement").map { CFEqual($0, element) } == true
                }
                func observe() -> TriggerSelectionObservation {
                    proof.observation(range: range(element), text: text(proof.replacementRange, in: element))
                }
                var selectionRequested = false
                let report = await SelectionPasteTransaction.run(
                    contextIsValid: { contextMatches() && lease.isOwned && !(abort && selectionRequested) },
                    observeSelection: observe,
                    selectTrigger: { selectionRequested = true; return setRange(proof.replacementRange, on: element) },
                    captureBaseline: { _ = range(element) },
                    postPaste: {
                        let source = CGEventSource(stateID: .privateState)!
                        for (key, down, flags) in [(55, true, CGEventFlags()), (9, true, .maskCommand),
                                                   (9, false, .maskCommand), (55, false, CGEventFlags())] {
                            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)!
                            event.flags = flags
                            event.setIntegerValueField(.eventSourceUserData, value: SnippetSyntheticEvent.tag)
                            event.postToPid(browser.processIdentifier)
                        }
                    }, wait: { try? await Task.sleep(for: $0) })
                if abort {
                    guard report.result == .contextChanged else { throw Failure.transaction }
                    let restored = await SelectionPasteTransaction.restore(contextIsValid: contextMatches,
                        observeSelection: observe, restoreOriginal: { setRange(original, on: element) },
                        wait: { try? await Task.sleep(for: $0) })
                    guard restored == .restored else { throw Failure.restoration }
                } else if report.result != .posted {
                    print("FAIL phase=\(report.progress.phase.rawValue) observation=\(report.progress.observation.rawValue)")
                    print("Context valid=\(contextMatches()) clipboard owned=\(lease.isOwned)")
                    throw Failure.transaction
                }
                let expected = abort ? initial : prefix + replacement + " after"
                var matched = false
                for _ in 0..<60 {
                    matched = try await connection.evaluate("""
                        window.model===\(quoted(expected)) && (target.isContentEditable?target.textContent:target.value)===\(quoted(expected)) &&
                        document.getElementById('other').value==='untouched' && window.inputEvents===\(abort ? 0 : 1)
                        """) as? Bool == true
                    if matched { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard matched, !abort || range(element) == original else { throw Failure.model }
                guard lease.restoreWithRetries() else { throw Failure.restoration }
                print("PASS Chrome case \(index): model, input events, untouched field; selection polls=\(report.progress.polls)")
            }
        } catch {
            // Only our own closed test errors; no clipboard, page contents or process identities.
            print("FAIL browser fixture: \((error as? Failure)?.rawValue ?? "transport")")
            exit(1)
        }
    }
}
