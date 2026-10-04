// Run through scripts/test-secure-paste-cold-web-focus.sh. This GUI integration fixture
// has no library, vault, network or clipboard access, and it never posts input. The
// child reads only its own fixture parent's focus metadata, never a value or title.
import AppKit
import ApplicationServices
import WebKit

private struct Case {
    enum Host {
        case web(html: String, expectsSecureField: Bool)
        /// A window whose first responder is the window itself.
        case windowWithoutFocusedControl
        case noWindow
        /// A host with its own accessibility answers that never publishes a focused element.
        case permanentlyUnpublishedFocus
    }

    let name: String
    let host: Host
}

private func page(_ field: String, rows: Int = 0) -> String {
    let filler = (0..<rows).map {
        "<div><span>Synthetic row \($0)</span><a href='#\($0)'>link</a><button>button</button><p>text</p></div>"
    }.joined()
    return """
    <!doctype html><meta charset='utf-8'>
    <p>Synthetic page. No form submission or network.</p>
    \(field)
    <div>\(filler)</div>
    """
}

// Each web case opens a new window with a new WKWebView, because each new web view starts
// with an unpublished accessibility tree even after an earlier one in this process woke.
// The last two cases have no web field and must not wait at all.
private let cases: [Case] = [
    .init(name: "login-sized page",
          host: .web(html: page("<input id='email' autofocus>"), expectsSecureField: false)),
    .init(name: "second web view",
          host: .web(html: page("<input id='password' type='password' autofocus>"), expectsSecureField: true)),
    // About 24,000 elements: measured to publish roughly 160 ms after the first message.
    .init(name: "large page",
          host: .web(html: page("<input id='email' autofocus>", rows: 6_000), expectsSecureField: false)),
    .init(name: "window without a focused control", host: .windowWithoutFocusedControl),
    .init(name: "application without a window", host: .noWindow),
    .init(name: "host that never publishes focus", host: .permanentlyUnpublishedFocus),
]

/// Stands in for a non-AppKit accessibility implementation: it owns keyboard focus but
/// answers no value for the focused element, permanently.
private final class UnpublishedFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var accessibilityFocusedUIElement: Any? { nil }
}

@MainActor
private func runDriver(case fixtureCase: Case) -> Bool {
    _ = NSApplication.shared
    let parentPID = getppid()
    // Read only the fixture that launched this process.
    guard let parent = NSRunningApplication(processIdentifier: parentPID),
          parent.executableURL?.standardizedFileURL
            == URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
          AXIsProcessTrusted() else { return false }
    _ = parent.activate()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == parentPID else {
        print("FAIL \(fixtureCase.name): fixture is not frontmost")
        return false
    }

    let budget = AXMessagingBudget()
    let application = AXUIElementCreateApplication(parentPID)
    func read(_ element: AXUIElement, _ name: String) -> (element: AXUIElement?, error: AXError) {
        var value: CFTypeRef?
        let result = budget.copyAttributeValue(of: element, attribute: name as CFString, into: &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return (nil, result == .success ? .failure : result) }
        return ((value as! AXUIElement), .success)
    }
    func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard budget.copyAttributeValue(of: element, attribute: name as CFString, into: &value) == .success
        else { return nil }
        return value as? String
    }

    let startedAt = ContinuousClock.now
    let first = read(application, kAXFocusedUIElementAttribute)
    // The behavior before the fix: one immediate retry, then "no text field".
    let immediate = first.element == nil ? read(application, kAXFocusedUIElementAttribute) : first
    var focused = immediate.element
    var waitedReads = 0
    var neverPublished = false
    if focused == nil {
        guard immediate.error == .noValue else {
            print("FAIL \(fixtureCase.name): focus read failed with AX error \(immediate.error.rawValue)")
            return false
        }
        let report = LazyAccessibilityFocus.wait(
            hasFocusedWindow: { read(application, kAXFocusedWindowAttribute).element != nil },
            pause: { budget.pause(for: $0) }
        ) { () -> LazyAccessibilityFocus.Read<AXUIElement> in
            let focus = read(application, kAXFocusedUIElementAttribute)
            guard let element = focus.element else {
                return focus.error == .noValue ? .unpublished : .failed(focus.error)
            }
            return .focused(element)
        }
        focused = report.element
        waitedReads = report.attempts
        neverPublished = report.neverPublished
    }
    let elapsed = startedAt.duration(to: .now)
    let duration = "\(elapsed.formatted(.units(allowed: [.milliseconds])))"

    if case .permanentlyUnpublishedFocus = fixtureCase.host {
        // One complete wait must fit in the capture budget, or the caller could never
        // learn to skip this host and would pay the wait on every Secure Paste.
        guard focused == nil, neverPublished, budget.canContinue else {
            print("FAIL \(fixtureCase.name): complete wait not observed after \(waitedReads) reads (\(duration))")
            return false
        }
        print("PASS \(fixtureCase.name): \(waitedReads) waited reads, marked as never publishing (\(duration))")
        return true
    }
    guard case .web(_, let expectsSecureField) = fixtureCase.host else {
        // No web field exists, so capture must fall through to Copy without polling.
        let isTextField = focused.map { string($0, kAXRoleAttribute) == kAXTextFieldRole as String } ?? false
        guard waitedReads == 0, !isTextField, elapsed < .milliseconds(50) else {
            print("FAIL \(fixtureCase.name): waited \(waitedReads) reads (\(duration))")
            return false
        }
        print("PASS \(fixtureCase.name): first read \(first.error.rawValue), no wait (\(duration))")
        return true
    }
    guard let focused,
          string(focused, kAXRoleAttribute) == kAXTextFieldRole as String,
          (string(focused, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String) == expectsSecureField
    else {
        print("FAIL \(fixtureCase.name): no focused \(expectsSecureField ? "password" : "text") field "
              + "after \(waitedReads) waited reads (\(duration))")
        return false
    }
    let detail = first.element == nil
        ? "first read \(first.error.rawValue), immediate retry \(immediate.error.rawValue), "
          + "published after \(waitedReads) waited reads"
        : "focus was already published; lazy path not exercised"
    print("PASS \(fixtureCase.name): \(detail) (\(duration))")
    return true
}

@MainActor
private final class Fixture: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var loaded: CheckedContinuation<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            for (index, fixtureCase) in cases.enumerated() {
                guard await run(index: index, fixtureCase: fixtureCase) else { exit(1) }
            }
            NSApp.terminate(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    private func run(index: Int, fixtureCase: Case) async -> Bool {
        window?.orderOut(nil)
        window = nil
        switch fixtureCase.host {
        case .noWindow:
            break
        case .permanentlyUnpublishedFocus:
            let window = makeWindow(index: index)
            let view = UnpublishedFocusView(frame: window.contentView!.bounds)
            window.contentView!.addSubview(view)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            self.window = window
        case .windowWithoutFocusedControl:
            let window = makeWindow(index: index)
            window.contentView!.addSubview(NSImageView(frame: NSRect(x: 40, y: 40, width: 120, height: 120)))
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
            self.window = window
        case .web(let html, _):
            let window = makeWindow(index: index)
            let web = WKWebView(frame: window.contentView!.bounds)
            web.navigationDelegate = self
            window.contentView!.addSubview(web)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(web)
            self.window = window
            await withCheckedContinuation { continuation in
                loaded = continuation
                web.loadHTMLString(html, baseURL: nil)
            }
        }
        // A user opens the page and then presses the shortcut; let layout settle first.
        try? await Task.sleep(for: .milliseconds(500))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--driver", String(index)]
        do { try child.run() } catch { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while child.isRunning {
            guard ContinuousClock.now < deadline else { child.terminate(); return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return child.terminationStatus == 0
    }

    private func makeWindow(index: Int) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200 + index * 30, y: 200, width: 600, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Snippets synthetic cold web focus fixture"
        window.isReleasedWhenClosed = false
        return window
    }
}

@main
private struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--driver",
           let index = Int(CommandLine.arguments[2]), cases.indices.contains(index) {
            exit(runDriver(case: cases[index]) ? 0 : 1)
        }
        guard AXIsProcessTrusted() else {
            print("This opt-in GUI test requires Accessibility permission for the invoking terminal.")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = Fixture()
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }
}
