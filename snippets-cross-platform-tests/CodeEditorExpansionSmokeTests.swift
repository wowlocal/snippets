#if os(macOS)
import AppKit
import XCTest
@testable import Snippets_Debug

@MainActor
final class CodeEditorExpansionSmokeTests: XCTestCase {
    private enum Editor {
        case zed, accessibleZed, cursor, accessibleCursor, cursorTab
        var isCursor: Bool { self == .cursor || self == .accessibleCursor || self == .cursorTab }
    }

    func testZedEditorAndFind() async throws { try await exercise(.zed) }
    func testZedExperimentalAccessibility() async throws { try await exercise(.accessibleZed) }
    func testCursorEditorAndFind() async throws { try await exercise(.cursor) }

    func testCursorTabInEditorAndReturnInFind() async throws { try await exercise(.cursorTab) }
    func testCursorWithScreenReaderSupport() async throws { try await exercise(.accessibleCursor) }

    private func exercise(_ editor: Editor) async throws {
        try DesktopExpansionFixture.requireAccess()
        let name = editor.isCursor ? "Cursor" : "Zed"
        let application = URL(fileURLWithPath: "/Applications/\(name).app")
        guard let id = Bundle(url: application)?.bundleIdentifier else { throw XCTSkip("\(name) unavailable") }
        // Electron names IPC sockets relative to the profile. macOS caps the
        // full Unix socket path at 104 bytes, even in an XCTest temp directory.
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("snippets-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let document = dir.appendingPathComponent("Snippets-\(UUID().uuidString).txt")
        let prefix = "prefix 🐝 "
        let initial = prefix + (editor.isCursor ? "" : "\\fixtur")
        let replacement = "verified café"
        try initial.write(to: document, atomically: true, encoding: .utf8)
        let profile = dir.appendingPathComponent("profile")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.environment = ["XDG_CONFIG_HOME": dir.appendingPathComponent("config").path]
        if !editor.isCursor {
            let settings = profile.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
            try #"{"autosave":{"after_delay":{"milliseconds":150}},"vim_mode":false,"ensure_final_newline_on_save":false,"remove_trailing_whitespace_on_save":false}"#
                .write(to: settings.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            if editor == .accessibleZed { config.environment["ZED_EXPERIMENTAL_A11Y"] = "1" }
            // Zed accepts a one-based file:line:column. Its editor has no AX caret setter.
            config.arguments = ["--user-data-dir", profile.path, document.path + ":1:100"]
        } else {
            let settings = profile.appendingPathComponent("User")
            try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
            let accessibility = editor == .accessibleCursor ? "on" : "auto"
            try #"{"editor.accessibilitySupport":"\#(accessibility)","files.autoSave":"afterDelay","files.autoSaveDelay":150,"workbench.startupEditor":"none","window.restoreWindows":"none","update.mode":"none"}"#
                .write(to: settings.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            config.arguments = ["--user-data-dir=\(profile.path)", "--extensions-dir=\(dir.path)/extensions",
                                "--disable-extensions", "--new-window", document.path]
        }
        let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier))
        let previous = NSWorkspace.shared.frontmostApplication
        let instance = try await NSWorkspace.shared.openApplication(at: application, configuration: config)
        try XCTSkipIf(existing.contains(instance.processIdentifier), "Editor reused an existing process")
        let app = AXUIElementCreateApplication(instance.processIdentifier)
        let attr = DesktopExpansionFixture.attribute
        func ownedWindow() -> Bool {
            guard let w = attr(app, "AXFocusedWindow"), CFGetTypeID(w) == AXUIElementGetTypeID() else { return false }
            return (attr(w as! AXUIElement, "AXTitle") as? String)?.contains(document.deletingPathExtension().lastPathComponent) == true
        }
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], _ text: String? = nil) throws {
            guard ownedWindow(), NSWorkspace.shared.frontmostApplication?.processIdentifier == instance.processIdentifier
            else { throw ProbeError("Fixture window lost focus") }
            let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
            for down in [true, false] {
                let e = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down))
                e.flags = flags
                if let text {
                    let units = Array(text.utf16)
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                }
                e.postToPid(instance.processIdentifier)
            }
        }
        func typeTrigger(_ engine: SnippetExpansionEngine, acceptanceKey: CGKeyCode? = nil) async throws {
            let codes: [CGKeyCode] = [42, 3, 34, 7, 17, 32, 15, 14]
            for (code, char) in zip(codes, acceptanceKey == nil ? "\\fixture" : "\\fi") {
                guard ownedWindow(), instance.isActive else { throw ProbeError("Lost the fixture while typing") }
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
                event.flags = []
                let units = Array(String(char).utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                if SnippetExpansionEngine.eventTapCallback(type: .keyDown, event: event,
                    refcon: Unmanaged.passUnretained(engine.callbackContext).toOpaque()) != nil {
                    try key(code, [], String(char))
                }
                try await Task.sleep(for: .milliseconds(45))
            }
            if let acceptanceKey {
                try await Task.sleep(for: .milliseconds(150))
                guard ownedWindow(), instance.isActive else { throw ProbeError("Lost the fixture before accepting the suggestion") }
                for down in [true, false] {
                    let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: acceptanceKey, keyDown: down))
                    key.flags = []
                    XCTAssertNil(SnippetExpansionEngine.eventTapCallback(type: down ? .keyDown : .keyUp, event: key,
                        refcon: Unmanaged.passUnretained(engine.callbackContext).toOpaque()))
                }
            }
        }
        func waitFor(_ label: String, _ predicate: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while ContinuousClock.now < deadline {
                if try predicate() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ProbeError(label)
        }
        func savedText() throws -> String {
            let text = try String(contentsOf: document, encoding: .utf8)
            return text.hasSuffix("\n") ? String(text.dropLast()) : text
        }
        func closeEditor() async {
            let restoreFocus = instance.isActive
            await DesktopExpansionFixture.closeOwnedInstance(instance)
            if restoreFocus { previous?.activate() }
        }
        do {
            try await waitFor("Editor did not open the fixture document") {
                let windows = attr(app, "AXWindows") as? [AXUIElement] ?? []
                guard let window = windows.first(where: {
                    (attr($0, "AXTitle") as? String)?.contains(document.lastPathComponent) == true
                }) else { return false }
                if !instance.isActive || !ownedWindow() {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    DesktopExpansionFixture.activate(instance, app: app)
                }
                return ownedWindow() && instance.isActive
            }
            if !editor.isCursor {
                // A fresh Zed profile opens the worktree trust prompt after the document.
                // Control-Command-S is Zed’s “Stay in Restricted Mode” shortcut.
                try await Task.sleep(for: .milliseconds(700))
                try key(1, [.maskControl, .maskCommand])
                try await Task.sleep(for: .milliseconds(200))
            }
            if editor.isCursor {
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                try await waitFor("Cursor editor did not publish a text control") {
                    guard ownedWindow(), let e = attr(app, "AXFocusedUIElement"), CFGetTypeID(e) == AXUIElementGetTypeID() else { return false }
                    return attr(e as! AXUIElement, "AXRole") as? String == "AXTextArea"
                }
            }
            try await DesktopExpansionFixture.withEngine(in: dir, replacement: replacement, keyword: "fixture") { engine in
                engine.expansionVerboseDiagnosticsEnabled = { true }
                try await waitFor("Could not focus the scratch document") {
                    if ownedWindow() && !instance.isActive { DesktopExpansionFixture.activate(instance, app: app) }
                    return ownedWindow() && instance.isActive
                }
                if editor.isCursor {
                    try key(124, .maskCommand)
                    try await Task.sleep(for: .milliseconds(120))
                    try await typeTrigger(engine, acceptanceKey: editor == .cursorTab ? 48 : nil)
                } else {
                    // The trigger prefix is in the fixture; the exact match consumes its final key.
                    try await DesktopExpansionFixture.expand(query: "fixture", using: engine)
                }
                try await waitFor("The document model did not save the exact expansion") {
                    try savedText() == prefix + replacement
                }
                if !editor.isCursor {
                    try await waitFor("The opaque editor did not finish its paste") {
                        engine.statusText.contains("could not be confirmed")
                    }
                    XCTAssertTrue(ownedWindow() && instance.isActive)
                }
                let nativePaste: (() throws -> Void)? = editor.isCursor ? nil : { try key(9, .maskCommand) }
                try await self.pasteFixtureHistory(" 🌻", using: engine, pasteAfterCopy: nativePaste) {
                    try await waitFor("Clipboard history did not reach the document") {
                        try savedText() == prefix + replacement + " 🌻"
                    }
                }
                try key(3, .maskCommand)
                try await Task.sleep(for: .milliseconds(250))
                try key(0, .maskCommand)
                try await Task.sleep(for: .milliseconds(100))
                try await typeTrigger(engine, acceptanceKey: editor == .cursorTab ? 36 : nil)
                try await Task.sleep(for: .milliseconds(1600))
                if editor.isCursor {
                    try await waitFor("Find query did not contain the expansion") {
                        guard let e = attr(app, "AXFocusedUIElement"), CFGetTypeID(e) == AXUIElementGetTypeID() else { return false }
                        return attr(e as! AXUIElement, "AXValue") as? String == replacement
                    }
                } else {
                    XCTAssertNil(engine.captureClipboardHistoryTarget())
                    // GPUI does not expose Find's value. Ask the control itself for
                    // its selection, then restore only the copy that we observed.
                    let board = NSPasteboard.general
                    let snapshot = PasteboardSnapshot(reading: board)
                    let original = try XCTUnwrap(snapshot.makeItems())
                    try key(0, .maskCommand)
                    try await Task.sleep(for: .milliseconds(80))
                    guard board.changeCount == snapshot.changeCount else { throw ProbeError("Clipboard changed before Find verification") }
                    try key(8, .maskCommand)
                    try await waitFor("Zed Find did not select the exact expanded query") {
                        board.changeCount != snapshot.changeCount && board.string(forType: .string) == replacement
                    }
                    let observed = board.changeCount
                    if board.string(forType: .string) == replacement && board.changeCount == observed {
                        board.clearContents()
                        if !original.isEmpty { XCTAssertTrue(board.writeObjects(original)) }
                    }
                }
            }
        } catch {
            await closeEditor()
            throw error
        }
        await closeEditor()
    }

    private struct ProbeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif
