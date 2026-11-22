#if os(macOS)
import AppKit
import XCTest
@testable import Snippets_Debug

@MainActor
final class DocumentEditorExpansionSmokeTests: XCTestCase {

    func testAutomaticExpansionInPlainDocumentAfterIdleTapRecovery() async throws {
        try await exercise(.plainText)
    }

    func testTabExpansionInStyledDocument() async throws {
        try await exercise(.styledText)
    }

    func testExpansionInsideScriptEditorComment() async throws {
        try await exercise(.compiledScript)
    }

    func testExpansionInUnicodeAppleScriptSourceFile() async throws {
        try await exercise(.unicodeScript)
    }

    func testUnicodeExpansionInInitiallyASCIIScriptFile() async throws {
        try await exercise(.asciiScript)
    }

    private enum Document { case plainText, styledText, compiledScript, unicodeScript, asciiScript }

    private func exercise(_ kind: Document) async throws {
        let rich = kind == .styledText
        let idleRecovery = kind == .plainText
        let script = kind == .compiledScript || kind == .unicodeScript || kind == .asciiScript
        try DesktopExpansionFixture.requireAccess()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let query = idleRecovery ? "zqzfixtureqz" : "fi"
        let prefix = script ? (kind == .asciiScript ? "-- Prefix " : "-- 🐝 Пример ") : "Header 🧑🏽‍💻\nPrefix "
        let suffix = " tail"
        let trigger = "\\" + query
        let replacement = script ? "слово ✨" : "café\nВторая строка ✨"
        let initial = prefix + (idleRecovery ? "" : trigger) + suffix
        let fileExtension: String
        switch kind {
        case .compiledScript: fileExtension = "scpt"
        case .unicodeScript, .asciiScript: fileExtension = "applescript"
        case .styledText: fileExtension = "rtf"
        case .plainText: fileExtension = "txt"
        }
        let document = directory.appendingPathComponent("Snippets-\(UUID().uuidString).\(fileExtension)")
        func appleScriptTool(_ executable: String, _ arguments: [String]) throws -> String {
            let tool = Process()
            tool.executableURL = URL(fileURLWithPath: executable)
            tool.arguments = arguments
            let output = Pipe()
            tool.standardOutput = output
            try tool.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            tool.waitUntilExit()
            XCTAssertEqual(tool.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self)
        }
        if kind == .compiledScript {
            _ = try appleScriptTool("/usr/bin/osacompile", ["-o", document.path, "-e", initial])
        } else if rich {
            let text = NSMutableAttributedString(string: initial)
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 19),
                              range: NSRange(location: 0, length: prefix.utf16.count))
            let data = try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
            try data.write(to: document)
        } else {
            try initial.write(to: document, atomically: true, encoding: .utf8)
        }

        let previousApp = NSWorkspace.shared.frontmostApplication
        let identifier = script ? "com.apple.ScriptEditor2" : "com.apple.TextEdit"
        let application = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier))
        let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let editor = try await NSWorkspace.shared.open([document], withApplicationAt: application, configuration: configuration)
        try XCTSkipIf(existing.contains(editor.processIdentifier), "Editor reused an existing process")
        defer { previousApp?.activate() }
        func verifyDocument() async throws {

            let app = AXUIElementCreateApplication(editor.processIdentifier)
            let attribute = DesktopExpansionFixture.attribute
            var field: AXUIElement?
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var foundDocument = false
            var observedRole: String?
            var observedLength: Int?
            while ContinuousClock.now < deadline {
                let windows = attribute(app, "AXWindows") as? [AXUIElement] ?? []
                if let window = windows.first(where: {
                    (attribute($0, "AXTitle") as? String)?.contains(document.deletingPathExtension().lastPathComponent) == true
                }) {
                    foundDocument = true
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != editor.processIdentifier {
                        DesktopExpansionFixture.activate(editor, app: app)
                    }
                    if let current = attribute(app, "AXFocusedWindow"), CFGetTypeID(current) == AXUIElementGetTypeID(),
                       CFEqual(current, window), let focus = attribute(app, "AXFocusedUIElement"),
                       CFGetTypeID(focus) == AXUIElementGetTypeID() {
                        let candidate = focus as! AXUIElement
                        observedRole = attribute(candidate, "AXRole") as? String
                        let value = attribute(candidate, "AXValue") as? String
                        observedLength = value?.utf16.count
                        if value == initial, NSWorkspace.shared.frontmostApplication?.processIdentifier == editor.processIdentifier {
                            field = candidate
                            break
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let element = try XCTUnwrap(field, "Document open \(foundDocument), role \(observedRole ?? "unavailable"), count \(observedLength ?? -1), expected \(initial.utf16.count), active \(editor.isActive)")
            var caret = CFRange(location: (prefix + (idleRecovery ? "" : trigger)).utf16.count, length: 0)
            let position = try XCTUnwrap(AXValueCreate(.cfRange, &caret))
            XCTAssertEqual(AXUIElementSetAttributeValue(element, "AXSelectedTextRange" as CFString, position), .success)
            try await DesktopExpansionFixture.withEngine(in: directory, replacement: replacement, keyword: idleRecovery ? query : "fixture") { engine in
                if idleRecovery {
                    let original = try XCTUnwrap(engine.eventTap)
                    CFMachPortInvalidate(original)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(16))
                    while engine.eventTap === original, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let recovered = try XCTUnwrap(engine.eventTap)
                    XCTAssertFalse(recovered === original)
                    XCTAssertTrue(CGEvent.tapIsEnabled(tap: recovered))
                    try await DesktopExpansionFixture.typeKeys(trigger, to: editor) {
                        guard let focused = attribute(app, "AXFocusedUIElement") else { return false }
                        return CFEqual(focused, element)
                    }
                } else {
                    try await DesktopExpansionFixture.expand(query: query, using: engine)
                }
                let end = ContinuousClock.now.advanced(by: .seconds(3))
                while engine.statusText != "Expanded Fixture.", ContinuousClock.now < end {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(engine.statusText, "Expanded Fixture.")
                XCTAssertEqual(attribute(element, "AXValue") as? String, prefix + replacement + suffix)
                let range = try XCTUnwrap(attribute(element, "AXSelectedTextRange"))
                var result = CFRange()
                XCTAssertTrue(AXValueGetValue(range as! AXValue, .cfRange, &result))
                XCTAssertEqual(result.location, (prefix + replacement).utf16.count)
                XCTAssertEqual(result.length, 0)
                // Save only our own document. This also observes the document model,
                // which can differ from the value its Accessibility adapter reports.
                guard let focused = attribute(app, "AXFocusedUIElement"), CFEqual(focused, element),
                      let window = attribute(app, "AXFocusedWindow"), CFGetTypeID(window) == AXUIElementGetTypeID(),
                      (attribute(window as! AXUIElement, "AXTitle") as? String)?.contains(document.deletingPathExtension().lastPathComponent) == true
                else { return XCTFail("Editor changed documents before saving") }
                for down in [true, false] {
                    let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: down))
                    key.flags = .maskCommand
                    key.postToPid(editor.processIdentifier)
                }
                let expected = prefix + replacement + suffix
                var saved: NSAttributedString?
                let saveDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                repeat {
                    if kind == .compiledScript {
                        let source = try appleScriptTool("/usr/bin/osadecompile", [document.path])
                        saved = NSAttributedString(string: source.hasSuffix("\n") ? String(source.dropLast()) : source)
                    } else if rich {
                        saved = NSAttributedString(rtf: try Data(contentsOf: document), documentAttributes: nil)
                    } else {
                        // Script Editor can change a plain source file's encoding on Save.
                        var encoding = String.Encoding.utf8
                        let text = try String(contentsOf: document, usedEncoding: &encoding)
                        saved = NSAttributedString(string: text)
                    }
                    if saved?.string == expected { break }
                    try await Task.sleep(for: .milliseconds(50))
                } while ContinuousClock.now < saveDeadline
                XCTAssertEqual(saved?.string, expected)
                if rich {
                    let font = try XCTUnwrap(saved?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                    XCTAssertEqual(font.pointSize, 19)
                    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
                }
            }
        }
        do {
            try await verifyDocument()
        } catch {
            await DesktopExpansionFixture.closeOwnedInstance(editor)
            throw error
        }
        await DesktopExpansionFixture.closeOwnedInstance(editor)
    }
}
#endif
