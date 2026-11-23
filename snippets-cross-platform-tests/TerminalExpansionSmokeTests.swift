#if os(macOS)
import AppKit
import XCTest
@testable import Snippets_Debug

/// Opt-in GUI test: `scripts/test-terminal-expansion.sh`.
///
/// Ghostty's surface is an `AXTextArea` whose caret can never be read, so every expansion here
/// is authorized by the local key count alone. A disposable Ghostty runs bash's readline, which
/// writes each finished line to a file; that file is the only evidence the test accepts.
@MainActor
final class TerminalExpansionSmokeTests: XCTestCase {
    private struct Key {
        let code: CGKeyCode
        let text: String
        var flags: CGEventFlags = []

        static let backspace = Key(code: 51, text: "\u{7F}")
        static let shiftBackspace = Key(code: 51, text: "\u{7F}", flags: .maskShift)
        static let controlH = Key(code: 4, text: "\u{8}", flags: .maskControl)
        static let controlW = Key(code: 13, text: "\u{17}", flags: .maskControl)
        static let controlA = Key(code: 0, text: "\u{1}", flags: .maskControl)
        static let upArrow = Key(code: 126, text: "\u{F700}", flags: [.maskNumericPad, .maskSecondaryFn])
        static let tab = Key(code: 48, text: "\t")
        static let returnKey = Key(code: 36, text: "\r")

        static func typing(_ text: String) throws -> [Key] {
            let codes: [Character: CGKeyCode] = ["\\": 42, "z": 6, "q": 12, "f": 3, "i": 34, "x": 7,
                                                 "y": 16, "a": 0, "b": 11, " ": 49]
            return try text.map { Key(code: try XCTUnwrap(codes[$0]), text: String($0)) }
        }
    }

    private struct ProbeError: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    func testGhosttyCountsPlainBackspaceAndEndsTheSessionOnOtherHostEdits() async throws {
        try DesktopExpansionFixture.requireAccess()
        let application = URL(fileURLWithPath: "/Applications/Ghostty.app")
        guard let id = Bundle(url: application)?.bundleIdentifier else { throw XCTSkip("Ghostty unavailable") }
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("snippets-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("lines.txt")
        let script = dir.appendingPathComponent("read-lines.sh")
        // readline with no user bindings: Backspace and Ctrl+H delete one character, Ctrl+W
        // deletes back to whitespace, Ctrl+A moves to the start of the line.
        try """
            export INPUTRC=/dev/null
            : > "$1.ready"
            while IFS= read -e -r line; do printf '%s\\n' "$line" >> "$1"; done

            """.write(to: script, atomically: true, encoding: .utf8)

        // NSWorkspace would hand Ghostty this test host's environment (DYLD and XCTest variables,
        // another app's bundle identifier), and Ghostty then ignores `command` and starts the
        // user's login shell. `open` launches it with the session's own environment instead.
        // The user's Ghostty configuration, windows and key bindings stay out of the fixture.
        let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier))
        let previous = NSWorkspace.shared.frontmostApplication
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.environment = ["PATH": "/usr/bin:/bin"]
        open.arguments = ["-n", "-a", application.path, "--args",
                          "--config-default-files=false", "--window-save-state=never",
                          "--confirm-close-surface=false", "--quit-after-last-window-closed=true",
                          "--command=/bin/bash \(script.path) \(output.path)"]
        try open.run()
        var launched: NSRunningApplication?
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while launched == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            launched = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first { !existing.contains($0.processIdentifier) }
        }
        let instance = try XCTUnwrap(launched, "Ghostty did not start")

        var failure: Error?
        do {
            try await exercise(instance, output: output, library: dir)
        } catch {
            failure = error
        }
        await DesktopExpansionFixture.closeOwnedInstance(instance)
        previous?.activate()
        if let failure { throw failure }
    }

    private func exercise(_ instance: NSRunningApplication, output: URL, library: URL) async throws {
        let pid = instance.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        let attr = DesktopExpansionFixture.attribute
        func terminalFocused() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let focused = attr(app, "AXFocusedUIElement"), CFGetTypeID(focused) == AXUIElementGetTypeID()
            else { return false }
            return attr(focused as! AXUIElement, "AXRole") as? String == "AXTextArea"
        }
        func waitFor(_ label: String, seconds: Int = 10, _ predicate: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while ContinuousClock.now < deadline {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ProbeError("Timed out waiting for \(label)")
        }
        func lines() -> [String] {
            ((try? String(contentsOf: output, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast().map(String.init)
        }

        /// Roles and counts only: enough to tell a dialog or a lost focus from a missing line.
        func hostState() -> String {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            let focused = attr(app, "AXFocusedUIElement").flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? attr($0 as! AXUIElement, "AXRole") as? String : nil
            }
            let window = attr(app, "AXFocusedWindow").flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
            }
            let children = window.flatMap { attr($0, "AXChildren") as? [AXUIElement] } ?? []
            let roles = children.compactMap { attr($0, "AXRole") as? String }.joined(separator: ",")
            // The fixture owns this terminal, so its screen holds only what the test typed.
            let screen = attr(app, "AXFocusedUIElement").flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? attr($0 as! AXUIElement, "AXValue") as? String : nil
            }.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)) }
            return "Ghostty frontmost=\(frontmost), focus=\(focused ?? "none"), window children=[\(roles)], lines=\(lines().count), screen=\(screen.map { "\"\($0)\"" } ?? "unreadable")"
        }

        // Nothing is typed until the fixture's own line reader owns this terminal: keys sent to
        // any other shell would run there as commands. Activating Ghostty before its first
        // window exists makes it open an ordinary shell window instead, so wait first.
        let ready = URL(fileURLWithPath: output.path + ".ready")
        do {
            try await waitFor("the line reader") { FileManager.default.fileExists(atPath: ready.path) }
        } catch {
            throw ProbeError("The line reader did not start; \(hostState())")
        }
        if !terminalFocused() { DesktopExpansionFixture.activate(instance, app: app) }
        try await waitFor("Ghostty's terminal surface") { terminalFocused() }
        try await Task.sleep(for: .milliseconds(300))

        try await DesktopExpansionFixture.withEngine(in: library, replacement: "EXPANDED", keyword: "zqfix") { @MainActor engine in
            let refcon = Unmanaged.passUnretained(engine.callbackContext).toOpaque()

            /// The engine sees each key first, as its session tap would. Ghostty receives only what
            /// the engine lets through, addressed to its PID so no other expander reacts to it.
            @MainActor @discardableResult
            func press(_ key: Key) async throws -> Bool {
                guard terminalFocused() else { throw ProbeError("Ghostty lost focus") }
                var suppressedKeyDown = false
                for down in [true, false] {
                    func event(_ source: CGEventSource?) throws -> CGEvent {
                        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down))
                        event.flags = key.flags
                        let units = Array(key.text.utf16)
                        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                        return event
                    }
                    let suppressed = SnippetExpansionEngine.eventTapCallback(
                        type: down ? .keyDown : .keyUp, event: try event(nil), refcon: refcon) == nil
                    if down { suppressedKeyDown = suppressed }
                    if !suppressed {
                        try event(XCTUnwrap(CGEventSource(stateID: .privateState))).postToPid(pid)
                    }
                }
                // Lets the engine's next-run-loop Accessibility read and the host's edit both land.
                try await Task.sleep(for: .milliseconds(70))
                return suppressedKeyDown
            }

            /// Types the keys, gives a possible expansion time to delete and insert, then ends the
            /// line and returns what readline recorded.
            @MainActor func line(_ label: String, _ keys: [Key]) async throws -> String {
                let recorded = lines().count
                for key in keys { try await press(key) }
                try await Task.sleep(for: .milliseconds(1200))
                let returnWasSwallowed = try await press(.returnKey)
                XCTAssertFalse(returnWasSwallowed, "\(label): a session left open swallowed Return")
                do {
                    try await waitFor("the line for \(label)", seconds: 5) { lines().count > recorded }
                } catch {
                    throw ProbeError("No line for \(label); \(hostState())")
                }
                return try XCTUnwrap(lines().last)
            }

            @MainActor func expect(_ expected: String, _ label: String, _ keys: [Key]) async throws {
                let recorded = try await line(label, keys)
                XCTAssertEqual(recorded, expected, label)
            }
            let typed = Key.typing

            try await expect("EXPANDED", "whole keyword", try typed("\\zqfix"))
            try await expect("EXPANDED", "Backspace, then the rest",
                             try typed("\\zqf") + [.backspace] + typed("fix"))
            try await expect("EXPANDED", "Ctrl+H, then the rest",
                             try typed("\\zqf") + [.controlH] + typed("fix"))
            try await expect("EXPANDED", "Backspace down to the trigger, then the keyword",
                             try typed("\\zq") + [.backspace, .backspace] + typed("zqfix"))

            // Tab accepts the remaining query after a Backspace.
            let recorded = lines().count
            for key in try typed("\\zqf") + [.backspace] { try await press(key) }
            try await Task.sleep(for: .milliseconds(300))
            let tabWasSwallowed = try await press(.tab)
            XCTAssertTrue(tabWasSwallowed, "Tab must accept the suggestion, not reach the shell")
            try await Task.sleep(for: .milliseconds(1200))
            try await press(.returnKey)
            try await waitFor("the line for Backspace, then Tab", seconds: 5) { lines().count > recorded }
            XCTAssertEqual(lines().last, "EXPANDED")

            // Edits the count cannot follow end the session: nothing expands against a stale
            // count, Return is not swallowed, and a new trigger starts cleanly.
            try await expect("ab EXPANDED", "Ctrl+W, then a new trigger",
                             try typed("ab \\zqf") + [.controlW] + typed("\\zqfix"))
            try await expect("ix\\zqf", "Ctrl+A moves the caret",
                             try typed("\\zqf") + [.controlA] + typed("ix"))
            try await expect("\\zqfix", "Up with nothing to select",
                             try typed("\\zqfy") + [.upArrow, .backspace] + typed("ix"))
            try await expect("zqfix", "Backspace past the trigger",
                             try typed("\\z") + [.backspace, .backspace] + typed("zqfix"))
            let shifted = try await line("Shift+Backspace", try typed("\\zqf") + [.shiftBackspace] + typed("fix"))
            XCTAssertFalse(shifted.contains("EXPANDED"), "a modified Backspace is not counted")
        }
    }
}
#endif
