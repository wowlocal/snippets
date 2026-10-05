import XCTest

#if os(macOS)
import AppKit
import Carbon.HIToolbox
@testable import Snippets_Debug

@MainActor
final class MainWindowEditorKeyboardTests: XCTestCase {
    func testControlNAndPWalkTheListWhenItHasFocus() throws {
        try withMainWindow { controller, window in
            XCTAssertTrue(window.makeFirstResponder(controller.tableView))

            XCTAssertNil(controller.handleKeyEvent(try key(.controlN, in: window)))
            XCTAssertEqual(controller.tableView.selectedRow, 1)

            XCTAssertNil(controller.handleKeyEvent(try key(.controlP, in: window)))
            XCTAssertEqual(controller.tableView.selectedRow, 0)
        }
    }

    func testEditorFieldsKeepControlNPAndReturn() throws {
        try withMainWindow { controller, window in
            let editors: [(String, NSResponder)] = [
                ("body", controller.snippetTextView),
                ("keyword", controller.keywordField),
                ("name", controller.nameField),
                ("tags", controller.tagsField),
            ]
            for (label, editor) in editors {
                XCTAssertTrue(window.makeFirstResponder(editor), label)
                for chord in [Key.controlN, .controlP, .return] {
                    let event = try key(chord, in: window)
                    XCTAssertTrue(controller.handleKeyEvent(event) === event,
                        "\(chord) in the \(label) editor must reach the text system")
                }
                XCTAssertEqual(controller.tableView.selectedRow, 0,
                    "^N/^P in the \(label) editor must not switch snippets")
            }
        }
    }

    func testControlNAndPMoveTheBodyCaretBetweenLines() throws {
        try withMainWindow { controller, window in
            let body = controller.snippetTextView
            XCTAssertTrue(window.makeFirstResponder(body))
            body.setSelectedRange(NSRange(location: 0, length: 0))

            let down = try key(.controlN, in: window)
            XCTAssertTrue(controller.handleKeyEvent(down) === down)
            window.sendEvent(down)
            XCTAssertEqual(body.selectedRange().location, secondLineStart, "^N moves to the next line")

            let up = try key(.controlP, in: window)
            XCTAssertTrue(controller.handleKeyEvent(up) === up)
            window.sendEvent(up)
            XCTAssertEqual(body.selectedRange().location, 0, "^P moves to the previous line")
            XCTAssertEqual(controller.tableView.selectedRow, 0)
        }
    }

    /// Typed on the Russian layout and dispatched through the application, so both
    /// the launch-time layout translation and the window's own monitor take part.
    func testCyrillicControlNAndPMoveTheBodyCaretBetweenLines() throws {
        guard ControlChordLayoutTranslation.currentLatinLayout(keyCode: UInt16(kVK_ANSI_N), modifiers: []) == "n",
              ControlChordLayoutTranslation.currentLatinLayout(keyCode: UInt16(kVK_ANSI_P), modifiers: []) == "p"
        else { throw XCTSkip("Needs a Latin layout with N and P on the QWERTY keys to predict ^N and ^P") }

        try withMainWindow { controller, window in
            let body = controller.snippetTextView
            XCTAssertTrue(window.makeFirstResponder(body))
            body.setSelectedRange(NSRange(location: 0, length: 0))

            NSApp.sendEvent(try russianChord(.controlN, in: window))
            XCTAssertEqual(body.selectedRange().location, secondLineStart, "^т moves to the next line")

            NSApp.sendEvent(try russianChord(.controlP, in: window))
            XCTAssertEqual(body.selectedRange().location, 0, "^з moves to the previous line")
            XCTAssertEqual(body.string, twoLines, "The chords must not type anything")
            XCTAssertEqual(controller.tableView.selectedRow, 0, "The editor's chords must not switch snippets")
        }
    }

    func testCyrillicControlNAndPWalkTheListWhenItHasFocus() throws {
        try withMainWindow { controller, window in
            XCTAssertTrue(window.makeFirstResponder(controller.tableView))

            NSApp.sendEvent(try russianChord(.controlN, in: window))
            XCTAssertEqual(controller.tableView.selectedRow, 1)

            NSApp.sendEvent(try russianChord(.controlP, in: window))
            XCTAssertEqual(controller.tableView.selectedRow, 0)
        }
    }

    func testEscapeFromTheEditorOpensSearchSuggestionsWhenTheSidebarIsCollapsed() throws {
        try withMainWindow(sidebarCollapsed: true) { controller, window in
            XCTAssertTrue(controller.isSidebarCollapsed)
            XCTAssertTrue(window.makeFirstResponder(controller.snippetTextView))
            let editing = try XCTUnwrap(controller.selectedSnippetID)

            XCTAssertNil(controller.handleKeyEvent(try key(.escape, in: window)))
            settle()
            if !controller.isSearchFieldActive && controller.searchField.isHiddenOrHasHiddenAncestor {
                throw XCTSkip("AppKit requires an active key window to expand compact toolbar search")
            }
            XCTAssertTrue(controller.isSearchFieldActive)
            XCTAssertTrue(controller.isSearchSuggestionOverlayVisible)

            XCTAssertNil(controller.handleKeyEvent(try key(.controlN, in: window)))
            let next = try XCTUnwrap(controller.selectedSnippetID)
            XCTAssertNotEqual(next, editing, "^N picks the next suggestion")
            XCTAssertNil(controller.handleKeyEvent(try key(.controlP, in: window)))
            XCTAssertEqual(controller.selectedSnippetID, editing, "^P picks the previous one")
            XCTAssertNil(controller.handleKeyEvent(try key(.controlN, in: window)))

            XCTAssertNil(controller.handleKeyEvent(try key(.return, in: window)))
            settle()
            XCTAssertFalse(controller.isSearchSuggestionOverlayVisible)
            XCTAssertTrue(window.firstResponder === controller.snippetTextView, "Return edits the pick")
            XCTAssertEqual(controller.selectedSnippetID, next)

            XCTAssertNil(controller.handleKeyEvent(try key(.escape, in: window)))
            settle()
            XCTAssertTrue(controller.isSearchFieldActive)
            XCTAssertTrue(controller.isSearchSuggestionOverlayVisible)

            XCTAssertNil(controller.handleKeyEvent(try key(.escape, in: window)))
            settle()
            XCTAssertFalse(controller.isSearchSuggestionOverlayVisible)
            XCTAssertTrue(window.firstResponder === controller.snippetTextView,
                "Escape from search goes back to the editor")
        }
    }

    // MARK: - Fixture

    private let twoLines = "first line\nsecond line"
    private var secondLineStart: Int { ("first line\n" as NSString).length }

    private enum Key: CustomStringConvertible {
        case controlN, controlP, `return`, escape

        var description: String {
            switch self {
            case .controlN: "^N"
            case .controlP: "^P"
            case .return: "Return"
            case .escape: "Escape"
            }
        }

        var keyCode: Int {
            switch self {
            case .controlN: kVK_ANSI_N
            case .controlP: kVK_ANSI_P
            case .return: kVK_Return
            case .escape: kVK_Escape
            }
        }
    }

    private func key(_ key: Key, in window: NSWindow) throws -> NSEvent {
        let (characters, unmodified, modifiers): (String, String, NSEvent.ModifierFlags) = switch key {
        case .controlN: ("\u{0E}", "n", .control)
        case .controlP: ("\u{10}", "p", .control)
        case .return: ("\r", "\r", [])
        case .escape: ("\u{1B}", "\u{1B}", [])
        }
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: unmodified,
            isARepeat: false, keyCode: UInt16(key.keyCode)))
    }

    /// The chord exactly as the Russian layout reports it: ^т and ^з, untranslated.
    private func russianChord(_ key: Key, in window: NSWindow) throws -> NSEvent {
        let russian = try RussianControlChord.source("com.apple.keylayout.Russian")
        let code = UInt16(key.keyCode)
        return try RussianControlChord.key(code: code,
            characters: try XCTUnwrap(ControlChordLayoutTranslation.characters(
                in: russian, keyCode: code, modifiers: .control)),
            unmodified: try XCTUnwrap(ControlChordLayoutTranslation.characters(
                in: russian, keyCode: code, modifiers: [])),
            window: window)
    }

    private func withMainWindow(
        sidebarCollapsed: Bool = false,
        _ body: (ViewController, NSWindow) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnippetsEditorKeyboard-\(UUID().uuidString)", isDirectory: true)
        let key = SnippetStorageLocations.rootOverrideEnvironmentKey
        let previousRoot = ProcessInfo.processInfo.environment[key]
        setenv(key, root.path, 1)
        // Collapsing the sidebar persists itself; keep the Debug app's own choice.
        let sidebarKey = MainLayoutMetrics.sidebarCollapsedDefaultsKey
        let previousSidebar = UserDefaults.standard.object(forKey: sidebarKey)
        defer {
            if let previousRoot { setenv(key, previousRoot, 1) } else { unsetenv(key) }
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.set(previousSidebar, forKey: sidebarKey)
        }

        try autoreleasepool {
            let store = SnippetStore(configuration: .iOS)
            for name in ["First fixture", "Second fixture", "Third fixture"] {
                _ = try store.addSnippet(name: name, content: twoLines)
            }
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
            // The top row, so ^N has somewhere to go.
            controller.selectSnippet(id: try XCTUnwrap(controller.visibleSnippets.first).id, focus: nil)

            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = controller.view
            controller.configureMainWindowChrome(window)
            // The monitor the app installs when the window appears, for the tests
            // that dispatch through NSApp; it is removed when the controller goes.
            controller.installKeyboardMonitorIfNeeded()
            defer {
                window.contentView = nil
                window.close()
            }
            // AppKit dispatches keys only to a window that can take them; the test
            // host is not activated, so no other application loses focus.
            window.makeKeyAndOrderFront(nil)
            settle()

            XCTAssertEqual(controller.tableView.selectedRow, 0)
            XCTAssertEqual(controller.snippetTextView.string, twoLines)
            try body(controller, window)
        }
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
}
#endif
