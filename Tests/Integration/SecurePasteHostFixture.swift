// Run through scripts/test-secure-paste-host.sh. This GUI integration fixture has
// no library, vault, network or clipboard access. The child can address only its
// own fixture parent, and every string below is synthetic.
import AppKit
import ApplicationServices
import WebKit

private let fixtureTitle = "Snippets synthetic secure input fixture"

private struct Sample {
    let text: String
    let initial: String
    let selection: NSRange
    let expected: String
    var movesFocus = false
    var refusesContent: Bool { SecurePasteDirectInputPolicy.validation(of: text) != .allowed }
}

private let samples: [Sample] = [
    .init(text: "Synthetic-😀", initial: "", selection: NSRange(location: 0, length: 0), expected: "Synthetic-😀"),
    .init(text: "тест-🔐", initial: "left-OLD-right", selection: NSRange(location: 5, length: 3), expected: "left-тест-🔐-right"),
    .init(text: String(repeating: "synthetic-", count: 16), initial: "", selection: NSRange(location: 0, length: 0), expected: String(repeating: "synthetic-", count: 16)),
    .init(text: "no\nsubmit", initial: "unchanged", selection: NSRange(location: 0, length: 9), expected: "unchanged"),
    .init(text: "do-not-send", initial: "unchanged", selection: NSRange(location: 0, length: 9), expected: "unchanged", movesFocus: true),
]

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.25)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func secureField(in root: AXUIElement) -> AXUIElement? {
    var pending = [root]
    for _ in 0..<200 {
        guard !pending.isEmpty else { break }
        let element = pending.removeFirst()
        if attribute(element, "AXSubrole") as? String == "AXSecureTextField" { return element }
        pending += attribute(element, "AXChildren") as? [AXUIElement] ?? []
    }
    return nil
}

private func runDriver(sample: Sample, web: Bool) -> Bool {
    // Initialize AppKit before consulting NSWorkspace's foreground application.
    _ = NSApplication.shared
    let parentPID = getppid()
    // Do not turn this test helper into a general-purpose password injector.
    guard let parent = NSRunningApplication(processIdentifier: parentPID),
          parent.executableURL?.standardizedFileURL == URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
          CGPreflightPostEventAccess(), AXIsProcessTrusted() else { return false }
    let app = AXUIElementCreateApplication(parentPID)
    guard let windows = attribute(app, "AXWindows") as? [AXUIElement],
          windows.contains(where: { attribute($0, "AXTitle") as? String == fixtureTitle }) else { return false }
    _ = parent.activate()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    var field: AXUIElement?
    for _ in 0..<40 {
        field = secureField(in: app)
        if field != nil { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let field else { return false }
    let strategy = SecurePasteDeliveryPolicy.strategy(targetIsSecureTextField: true,
        valueIsSettable: true, targetIsInsideWebArea: web, targetHasEligibleWebTextRole: true,
        webRangeReplacementIsAvailable: true, webPasswordFocus: .confirmedField)
    let focused = attribute(app, "AXFocusedUIElement")
    let exactFocus = focused.map { CFEqual($0, field) } ?? false
    if sample.movesFocus { return !exactFocus }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == parentPID,
          exactFocus else { return false }
    if strategy == .typeSecureUnicode && sample.refusesContent {
        return SecurePasteDirectInputPolicy.makeEvents(text: sample.text, eventTag: 123) == nil
    }
    switch strategy {
    case .replaceSecureValue:
        guard !web else { return false } // Fails against the old password policy.
        return AXUIElementSetAttributeValue(field, "AXValue" as CFString, sample.text as CFString) == .success
    case .typeSecureUnicode:
        guard web, SecurePasteDeliveryPolicy.permitsDirectInput(isSecureWebField: true,
            hasContainerBinding: false, exactFieldHasKeyboardFocus: exactFocus),
              let events = SecurePasteDirectInputPolicy.makeEvents(text: sample.text, eventTag: 123) else { return false }
        events.keyDown.postToPid(parentPID)
        events.keyUp.postToPid(parentPID)
        // Keep the source process alive until WindowServer has delivered its queued
        // events. The shipping app remains alive; an immediately exiting test client
        // can drop events and gives a misleading failure.
        Thread.sleep(forTimeInterval: 0.25)
        return true
    default: return false
    }
}

@MainActor
private final class Fixture: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private let webMode: Bool
    private var window: NSWindow!
    private var web: WKWebView!
    private var password: NSSecureTextField!
    private var other: NSTextField!

    init(web: Bool) { webMode = web }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = fixtureTitle
        if webMode {
            web = WKWebView(frame: window.contentView!.bounds)
            web.navigationDelegate = self
            window.contentView!.addSubview(web)
        } else {
            password = NSSecureTextField(frame: NSRect(x: 40, y: 140, width: 400, height: 30))
            other = NSTextField(frame: NSRect(x: 40, y: 80, width: 400, height: 30))
            window.contentView!.addSubview(password)
            window.contentView!.addSubview(other)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if webMode {
            web.loadHTMLString("""
            <!doctype html><meta charset='utf-8'>
            <p>Synthetic input only. No form submission or network.</p>
            <label>Password <input id='password' type='password'></label>
            <label>Other <input id='other'></label>
            <script>
            window.model = ''; window.inputEvents = 0;
            password.addEventListener('input', () => {
                window.model = password.value; window.inputEvents++;
            });
            </script>
            """, baseURL: nil)
        } else { runTests() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { runTests() }

    private func jsString(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    private func runTests() {
        Task { @MainActor in
            for (index, sample) in samples.enumerated() {
                // Native whole-value assignment is not keyboard input; its existing
                // content semantics are unchanged. Control rejection belongs to the
                // new web keyboard route and is tested there.
                if !webMode && sample.refusesContent { continue }
                do {
                    if webMode {
                        _ = try await web.evaluateJavaScript("""
                        password.value=\(jsString(sample.initial)); other.value='';
                        window.model=password.value; window.inputEvents=0;
                        password.focus(); password.setSelectionRange(\(sample.selection.location), \(NSMaxRange(sample.selection)));
                        \(sample.movesFocus ? "other.focus();" : "")
                        """)
                    } else {
                        password.stringValue = sample.initial; other.stringValue = ""
                        window.makeFirstResponder(sample.movesFocus ? other : password)
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                    child.arguments = ["--driver", String(index), webMode ? "web" : "native"]
                    try child.run()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                    while child.isRunning {
                        guard ContinuousClock.now < deadline else {
                            child.terminate()
                            throw FixtureError.driver
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard child.terminationStatus == 0 else { throw FixtureError.driver }
                    try await Task.sleep(for: .milliseconds(300))
                    let expected = webMode || sample.refusesContent || sample.movesFocus ? sample.expected : sample.text
                    let matches: Bool
                    if webMode {
                        matches = try await web.evaluateJavaScript("""
                        password.value===\(jsString(expected)) && window.model===\(jsString(expected)) &&
                        other.value==='' && window.inputEvents===\(sample.refusesContent || sample.movesFocus ? 0 : 1)
                        """) as? Bool == true
                    } else { matches = password.stringValue == expected && other.stringValue.isEmpty }
                    guard matches else { throw FixtureError.model }
                    print("PASS \(webMode ? "web" : "native") case \(index): real model and unrelated field checked")
                } catch {
                    print("FAIL \(webMode ? "web" : "native") case \(index)")
                    exit(1)
                }
            }
            NSApp.terminate(nil)
        }
    }
    private enum FixtureError: Error { case driver, model }
}

@main
private struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--driver",
           let index = Int(CommandLine.arguments[2]), samples.indices.contains(index) {
            exit(runDriver(sample: samples[index], web: CommandLine.arguments[3] == "web") ? 0 : 1)
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            print("This opt-in GUI test requires Accessibility permission for the invoking terminal.")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = Fixture(web: CommandLine.arguments.contains("--web"))
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }
}
