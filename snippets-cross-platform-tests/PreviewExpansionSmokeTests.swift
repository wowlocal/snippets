#if os(macOS)
import AppKit
import XCTest
@testable import Snippets_Debug

@MainActor
final class PreviewExpansionSmokeTests: XCTestCase {
    func testFindFieldExpandsAndPastesOverASelection() async throws {
        try DesktopExpansionFixture.requireAccess()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "Snippets-\(UUID().uuidString)"
        let document = directory.appendingPathComponent(name + ".pdf")
        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        page.string = "find a fixture phrase"
        try page.dataWithPDF(inside: page.bounds).write(to: document)
        let previousApp = NSWorkspace.shared.frontmostApplication
        let id = "com.apple.Preview"
        let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier))
        let url = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let instance = try await NSWorkspace.shared.open([document], withApplicationAt: url, configuration: configuration)
        try XCTSkipIf(existing.contains(instance.processIdentifier), "Preview reused an existing process")
        let app = AXUIElementCreateApplication(instance.processIdentifier)
        let attribute = DesktopExpansionFixture.attribute
        func focused() -> AXUIElement? {
            guard let field = attribute(app, "AXFocusedUIElement"), CFGetTypeID(field) == AXUIElementGetTypeID() else { return nil }
            return (field as! AXUIElement)
        }
        func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(4))
            while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(40)) }
            guard condition() else { throw NSError(domain: "Preview fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: description]) }
        }
        do {
            try await waitUntil("Synthetic PDF never became the focused window") {
                guard let w = attribute(app, "AXFocusedWindow"), CFGetTypeID(w) == AXUIElementGetTypeID(),
                      (attribute(w as! AXUIElement, "AXTitle") as? String)?.contains(name) == true else { return false }
                if !instance.isActive { DesktopExpansionFixture.activate(instance, app: app) }
                return instance.isActive
            }
            for down in [true, false] {
                let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: down))
                key.flags = .maskCommand
                key.postToPid(instance.processIdentifier)
            }
            try await waitUntil("Preview never focused its search field") {
                guard let field = focused() else { return false }
                return attribute(field, "AXSubrole") as? String == "AXSearchField"
            }
            let field = try XCTUnwrap(focused())
            let initial = "find \\fi tail"
            XCTAssertEqual(AXUIElementSetAttributeValue(field, "AXValue" as CFString, initial as CFString), .success)
            func select(_ location: Int, _ length: Int) throws {
                var range = CFRange(location: location, length: length)
                let v = try XCTUnwrap(AXValueCreate(.cfRange, &range))
                XCTAssertEqual(AXUIElementSetAttributeValue(field, "AXSelectedTextRange" as CFString, v), .success)
            }
            try select(8, 0)
            try await DesktopExpansionFixture.withEngine(in: directory, replacement: "a fixture phrase") { engine in
                try await DesktopExpansionFixture.expand(query: "fi", using: engine)
                try await waitUntil("Find query did not expand") {
                    attribute(field, "AXValue") as? String == "find a fixture phrase tail"
                }
                try select(7, 7)
                try await self.pasteFixtureHistory("café 🌻", using: engine) {
                    try await waitUntil("Clipboard history did not replace the selected word") {
                        attribute(field, "AXValue") as? String == "find a café 🌻 phrase tail"
                    }
                }
            }
        } catch {
            await DesktopExpansionFixture.closeOwnedInstance(instance)
            previousApp?.activate()
            throw error
        }
        await DesktopExpansionFixture.closeOwnedInstance(instance)
        previousApp?.activate()
    }
}
#endif
