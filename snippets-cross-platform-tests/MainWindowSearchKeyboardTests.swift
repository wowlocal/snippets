import XCTest

#if os(macOS)
import AppKit
import Carbon.HIToolbox
@testable import Snippets_Debug

@MainActor
final class MainWindowSearchKeyboardTests: XCTestCase {
    func testCommandFActivatesCompactToolbarSearch() throws {
        try checkSearchActivation(width: 380, sidebarCollapsed: true)
    }

    func testCommandFActivatesExpandedToolbarSearch() throws {
        try checkSearchActivation(width: 1000, sidebarCollapsed: false)
    }

    private func checkSearchActivation(width: CGFloat, sidebarCollapsed: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnippetsSearchKeyboard-\(UUID().uuidString)", isDirectory: true)
        let key = SnippetStorageLocations.rootOverrideEnvironmentKey
        let previousRoot = ProcessInfo.processInfo.environment[key]
        setenv(key, root.path, 1)
        defer {
            if let previousRoot { setenv(key, previousRoot, 1) } else { unsetenv(key) }
            try? FileManager.default.removeItem(at: root)
        }

        try autoreleasepool {
            let store = SnippetStore(configuration: .iOS)
            let snippet = try store.addSnippet(name: "Search fixture", content: "Fixture content")
            let usage = SnippetUsageStore()
            let controller = ViewController()
            controller.store = store
            controller.usageStore = usage
            controller.engine = SnippetExpansionEngine(store: store, usage: usage)
            controller.buildUI()
            controller.hasRestoredSplitViewDivider = true
            controller.permissionBannerContainer.isHidden = true
            controller.permissionBannerDivider.isHidden = true
            controller.mainSidebarSplitItem?.isCollapsed = sidebarCollapsed
            controller.reloadVisibleSnippets(keepSelection: false)
            controller.selectSnippet(id: snippet.id, focus: nil)

            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = controller.view
            controller.configureMainWindowChrome(window)
            defer {
                window.contentView = nil
                window.close()
            }
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(NSSize(width: width, height: 720))
            settle()
            let previousPolicy = NSApp.activationPolicy()
            defer { NSApp.setActivationPolicy(previousPolicy) }
            NSApp.setActivationPolicy(.regular)
            NSApp.unhide(nil)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            settle()
            if sidebarCollapsed && (!NSApp.isActive || !window.isKeyWindow) {
                throw XCTSkip("AppKit requires an active key window to expand compact toolbar search")
            }
            XCTAssertTrue(window.makeFirstResponder(controller.snippetTextView))
            XCTAssertFalse(controller.isSearchFieldActive)
            if sidebarCollapsed {
                XCTAssertTrue(controller.searchField.isHiddenOrHasHiddenAncestor,
                    "The narrow window must exercise the collapsed search icon")
            }

            let commandF = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "f", charactersIgnoringModifiers: "f",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_F)))
            XCTAssertNil(controller.handleKeyEvent(commandF))
            settle()
            XCTAssertFalse(controller.searchField.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(controller.isSearchFieldActive)
            XCTAssertEqual(controller.isSearchSuggestionOverlayVisible, sidebarCollapsed)

            controller.searchField.stringValue = "Search fixture"
            controller.controlTextDidChange(Notification(
                name: NSControl.textDidChangeNotification, object: controller.searchField))
            XCTAssertNil(controller.handleKeyEvent(commandF))
            settle()
            XCTAssertTrue(controller.isSearchFieldActive)
            XCTAssertEqual(controller.searchField.stringValue, "Search fixture")
        }
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
}
#endif
