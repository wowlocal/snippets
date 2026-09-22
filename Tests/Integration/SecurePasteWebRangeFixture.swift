// Run with bash scripts/test-secure-paste-web-range.sh from an AX-authorized terminal.
// Uses the shipping range planner and exact UTF-16 comparison, but not the full engine.
// A separate sender addresses only its own synthetic WKWebView parent. No clipboard,
// library, vault, browser profile, network requests, or production diagnostics are used.
import AppKit
import ApplicationServices
import WebKit

private let fixtureTitle = "Snippets synthetic web range fixture"
private let prefix = "before "
private let suffix = " after"
private let initial = prefix + "OLD" + suffix

private struct Sample {
    let name: String
    let text: String
    let singleLineExpected: String
    let multiLineExpected: String
    var mutation: Mutation = .none
}

private enum Mutation: String {
    case none, truncate, removeLine, rewrite
    var script: String {
        switch self {
        case .none: return ""
        case .truncate: return "target.value=target.value.replace('two','tw');"
        case .removeLine: return "target.value=target.value.replace('two','');"
        case .rewrite: return "target.value=target.value.replace('one','XXX');"
        }
    }
    func apply(to text: String) -> String {
        switch self {
        case .none: return text
        case .truncate: return text.replacingOccurrences(of: "two", with: "tw")
        case .removeLine: return text.replacingOccurrences(of: "two", with: "")
        case .rewrite: return text.replacingOccurrences(of: "one", with: "XXX")
        }
    }
}

private let samples: [Sample] = [
    .init(name: "plain", text: "Synthetic-😀", singleLineExpected: "Synthetic-😀", multiLineExpected: "Synthetic-😀"),
    .init(name: "LF", text: "one\ntwo", singleLineExpected: "one two", multiLineExpected: "one\ntwo"),
    .init(name: "CRLF", text: "one\r\ntwo", singleLineExpected: "one two", multiLineExpected: "one\ntwo"),
    .init(name: "CR", text: "one\rtwo", singleLineExpected: "one two", multiLineExpected: "one\ntwo"),
    .init(name: "trailing-LF", text: "one\ntwo\n", singleLineExpected: "one two", multiLineExpected: "one\ntwo\n"),
    .init(name: "blank-line", text: "one\n\ntwo", singleLineExpected: "one  two", multiLineExpected: "one\n\ntwo"),
    .init(name: "large", text: String(repeating: "one\r\ntwo\n", count: 2048) + "END",
          singleLineExpected: String(repeating: "one two ", count: 2048) + "END",
          multiLineExpected: String(repeating: "one\ntwo\n", count: 2048) + "END"),
    .init(name: "reject-truncation", text: "one\ntwo", singleLineExpected: "one two", multiLineExpected: "one\ntwo", mutation: .truncate),
    .init(name: "reject-lost-line", text: "one\ntwo", singleLineExpected: "one two", multiLineExpected: "one\ntwo", mutation: .removeLine),
    .init(name: "reject-rewrite", text: "one\ntwo", singleLineExpected: "one two", multiLineExpected: "one\ntwo", mutation: .rewrite),
]
private let fields = ["text", "search", "textarea"]

private struct Observation: Codable {
    let countMatches: Bool
    let rangeMatches: Bool
    let count: Int?
    var strictConfirmation: Bool { countMatches && rangeMatches }
}

private struct Report: Codable {
    let axError: Int32
    let expectedCount: Int
    let immediate: Observation
    let settled: Observation
    let legacyConfirmed: Bool
    let deliveryMilliseconds: Double
    let caretWritten: Bool
}

private func benchmarkPlanning() {
    let snapshot = SecurePasteWebReplacementPolicy.snapshot(
        fieldUTF16Count: 0, selectionLocation: 0, selectionLength: 0, selectedText: "")!
    for (limit, iterations) in [(1_000, 1_000), (20_000, 100), (1_000_000, 10)] {
        let text = String(repeating: "one\r\ntwo\n", count: limit / 9)
        let started = ContinuousClock.now
        var checksum = 0
        for _ in 0..<iterations {
            for mode in [SecurePasteWebReplacementPolicy.LineEndings.webKitSingleLine, .webKitMultiline] {
                checksum += SecurePasteWebReplacementPolicy.plan(
                    replacing: snapshot, with: text, lineEndings: mode)!.expectedFieldUTF16Count
            }
        }
        let elapsed = started.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        print(String(format: "PERF planner input_utf16=%d average_ms=%.3f iterations=%d checksum=%d",
            text.utf16.count, milliseconds / Double(iterations * 2), iterations * 2, checksum))
    }
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.1)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func range(_ element: AXUIElement) -> CFRange? {
    guard let value = attribute(element, "AXSelectedTextRange"),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range
}

private func string(_ range: CFRange, in element: AXUIElement) -> String? {
    var range = range
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    AXUIElementSetMessagingTimeout(element, 0.1)
    guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString,
        parameter, &value) == .success else { return nil }
    return value as? String
}

@MainActor
private func runDriver(sample: Sample) -> Report? {
    let parentPID = getppid()
    guard AXIsProcessTrusted(),
          let parent = NSRunningApplication(processIdentifier: parentPID),
          parent.executableURL?.standardizedFileURL == URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    else { return nil }
    let app = AXUIElementCreateApplication(parentPID)
    guard let windows = attribute(app, "AXWindows") as? [AXUIElement],
          windows.contains(where: { attribute($0, "AXTitle") as? String == fixtureTitle }) else { return nil }
    var ready: AXUIElement?
    for _ in 0..<40 {
        if let focused = attribute(app, "AXFocusedUIElement"),
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let candidate = focused as! AXUIElement
            if let selection = range(candidate),
               selection.location == prefix.utf16.count, selection.length == 3,
               attribute(candidate, "AXNumberOfCharacters") as? Int == initial.utf16.count {
                ready = candidate
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    let deliveryStarted = ContinuousClock.now
    guard let field = ready, let selection = range(field),
          let selected = string(selection, in: field),
          let snapshot = SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: initial.utf16.count, selectionLocation: selection.location,
            selectionLength: selection.length, selectedText: selected),
          let legacyPlan = SecurePasteWebReplacementPolicy.plan(replacing: snapshot, with: sample.text)
    else { return nil }
    // This process is explicitly built around WKWebView. Supply Safari's host identity
    // to the shipping classifier, with the real control's AX role (not the HTML case name).
    // The fixture does not test Safari's bundle discovery or the complete app engine.
    let lineEndings = SecurePasteWebReplacementPolicy.lineEndings(bundleIdentifier: "com.apple.Safari",
        role: attribute(field, "AXRole") as? String)
    guard let plan = SecurePasteWebReplacementPolicy.plan(
        replacing: snapshot, with: sample.text, lineEndings: lineEndings) else { return nil }
    var advertised: CFArray?
    guard AXUIElementCopyParameterizedAttributeNames(field, &advertised) == .success,
          let names = advertised as? [String],
          SecurePasteDeliveryPolicy.supportsWebRangeReplacement(advertisedParameterizedAttributes: Set(names)),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == parentPID,
          attribute(app, "AXFocusedUIElement").map({ CFEqual($0, field) }) == true else { return nil }

    var replacementRange = CFRange(location: plan.replacementLocation, length: plan.replacementLength)
    guard let rangeValue = AXValueCreate(.cfRange, &replacementRange) else { return nil }
    let parameters: NSDictionary = ["AXReplacementRange": rangeValue, "AXReplacementText": sample.text]
    // Exactly one plaintext-bearing operation per case. Never retry after a readback mismatch.
    let budget = AXMessagingBudget()
    var operationResult: CFTypeRef?
    let result = budget.copyParameterizedAttributeValue(of: field,
        attribute: "AXReplaceRangeWithText" as CFString, parameter: parameters, into: &operationResult)
    func observe(_ plan: SecurePasteWebReplacementPolicy.Plan) -> Observation {
        let count = attribute(field, "AXNumberOfCharacters") as? Int
        let inserted = string(CFRange(location: plan.replacementLocation, length: plan.replacementUTF16Count), in: field)
        return Observation(countMatches: count == plan.expectedFieldUTF16Count,
            rangeMatches: SecurePasteWebReplacementPolicy.confirms(plan,
                fieldUTF16Count: count, insertedText: inserted),
            count: count)
    }
    let immediate = observe(plan)
    var caretWritten = false
    if immediate.strictConfirmation {
        var caret = CFRange(location: plan.caretLocation, length: 0)
        if let value = AXValueCreate(.cfRange, &caret) {
            caretWritten = budget.setAttributeValue(of: field,
                attribute: "AXSelectedTextRange" as CFString, value: value) == .success
        }
    }
    let elapsed = deliveryStarted.duration(to: .now).components
    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    // Diagnostic-only legacy comparison and settled read; excluded from delivery timing.
    let legacyConfirmed = observe(legacyPlan).strictConfirmation
    Thread.sleep(forTimeInterval: 0.5)
    return Report(axError: result.rawValue, expectedCount: plan.expectedFieldUTF16Count,
        immediate: immediate, settled: observe(plan), legacyConfirmed: legacyConfirmed,
        deliveryMilliseconds: milliseconds, caretWritten: caretWritten)
}

@MainActor
private final class Fixture: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var didRun = false
    private var activeDriver: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 340),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = fixtureTitle
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        web.navigationDelegate = self
        window.contentView!.addSubview(web)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.loadHTMLString("""
            <!doctype html><meta charset='utf-8'>
            <meta http-equiv='Content-Security-Policy' content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
            <p>Synthetic multiline paste test. No network, clipboard or user data.</p>
            <label>Text <input id='text' type='text'></label><br>
            <label>Search <input id='search' type='search'></label><br>
            <label>Textarea <textarea id='textarea'></textarea></label><br>
            <input id='other' value='untouched'>
            """, baseURL: nil)
        // A broken AX/web process must not strand the fixture on screen indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.finish(code: 2) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didRun else { return }
        didRun = true
        Task { await runTests() }
    }

    private func quoted(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    private func runTests() async {
        var failures = 0
        var durations: [Double] = []
        print("ENV macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) WebKit=\(Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")
        for field in fields {
            for (index, sample) in samples.enumerated() {
                do {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    _ = try await web.evaluateJavaScript("""
                        window.target=document.getElementById(\(quoted(field)));
                        target.value=\(quoted(initial)); window.model=target.value; window.inputEvents=0;
                        target.oninput=()=>{\(sample.mutation.script) window.model=target.value; window.inputEvents++};
                        target.focus(); target.setSelectionRange(\(prefix.utf16.count), \(prefix.utf16.count + 3));
                        """)
                    try await Task.sleep(for: .milliseconds(100))
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                    child.arguments = ["--driver", String(index)]
                    let output = Pipe()
                    child.standardOutput = output
                    try child.run()
                    activeDriver = child
                    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                    while child.isRunning {
                        guard ContinuousClock.now < deadline else {
                            child.terminate()
                            throw ProbeError.driver
                        }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    activeDriver = nil
                    guard child.terminationStatus == 0 else { throw ProbeError.driver }
                    let report = try JSONDecoder().decode(Report.self, from: output.fileHandleForReading.readDataToEndOfFile())
                    let expectedBody = field == "textarea" ? sample.multiLineExpected : sample.singleLineExpected
                    let expected = sample.mutation.apply(to: prefix + expectedBody + suffix)
                    let raw = prefix + sample.text + suffix
                    let facts = try await web.evaluateJavaScript("""
                        ({expected:target.value===\(quoted(expected)), raw:target.value===\(quoted(raw)),
                          model:window.model===target.value, events:window.inputEvents,
                          untouched:document.getElementById('other').value==='untouched',
                          caret:target.selectionStart===\(prefix.utf16.count + expectedBody.utf16.count)
                            && target.selectionEnd===target.selectionStart})
                        """) as? [String: Any] ?? [:]
                    let domMatches = facts["expected"] as? Bool == true
                    let modelMatches = facts["model"] as? Bool == true
                    let inputEvents = facts["events"] as? Int ?? -1
                    let untouched = facts["untouched"] as? Bool == true
                    let shouldConfirm = sample.mutation == .none
                    let legacyShouldConfirm = shouldConfirm
                        && SecurePasteWebReplacementPolicy.utf16ContentsMatch(expectedBody, sample.text)
                    let passed = report.axError == 0 && domMatches && modelMatches && inputEvents == 1 && untouched
                        && report.settled.count == expected.utf16.count
                        && report.immediate.strictConfirmation == shouldConfirm
                        && report.settled.strictConfirmation == shouldConfirm
                        && report.legacyConfirmed == legacyShouldConfirm
                        && report.caretWritten == shouldConfirm
                        && (!shouldConfirm || facts["caret"] as? Bool == true)
                    durations.append(report.deliveryMilliseconds)
                    if !passed { failures += 1 }
                    print("\(passed ? "PASS" : "FAIL") \(field)/\(sample.name): AX=\(report.axError) DOM=\(domMatches) model=\(modelMatches) events=\(inputEvents) immediate=\(report.immediate.strictConfirmation) settled=\(report.settled.strictConfirmation) legacy=\(report.legacyConfirmed) caret=\(report.caretWritten) count=\(report.settled.count ?? -1)/\(report.expectedCount) ms=\(String(format: "%.2f", report.deliveryMilliseconds))")
                } catch {
                    failures += 1
                    print("FAIL \(field)/\(sample.name): fixture preflight, driver, or DOM read unavailable")
                }
            }
        }
        print("RESULT cases=\(fields.count * samples.count) failures=\(failures)")
        if !durations.isEmpty {
            durations.sort()
            print(String(format: "PERF delivery ms: min=%.2f median=%.2f max=%.2f (excludes diagnostic 500ms wait)",
                durations[0], durations[durations.count / 2], durations[durations.count - 1]))
        }
        finish(code: failures == 0 ? 0 : 1)
    }

    private func finish(code: Int32) {
        if let activeDriver, activeDriver.isRunning { activeDriver.terminate() }
        window?.orderOut(nil)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate()
        }
        exit(code)
    }
    private enum ProbeError: Error { case driver }
}

@main
private struct Main {
    @MainActor static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--benchmark"] {
            benchmarkPlanning()
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--driver",
           let index = Int(CommandLine.arguments[2]), samples.indices.contains(index) {
            guard let report = runDriver(sample: samples[index]),
                  let data = try? JSONEncoder().encode(report) else { exit(2) }
            FileHandle.standardOutput.write(data)
            return
        }
        guard AXIsProcessTrusted() else {
            print("Requires Accessibility permission for the invoking terminal.")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = Fixture()
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }
}
