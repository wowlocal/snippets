#if os(macOS)
import AppKit
import XCTest
@testable import Snippets_Debug

@MainActor
enum DesktopExpansionFixture {
    static func requireAccess() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SNIPPETS_BROWSER_SMOKE"] == "1",
                          "Run scripts/test-browser-expansion.sh in an unlocked desktop session")
        try XCTSkipUnless(AXIsProcessTrusted(), "The Snippets test host needs Accessibility access")
    }

    static func withEngine(in directory: URL, replacement: String, keyword: String = "fixture",
                           run: (SnippetExpansionEngine) async throws -> Void) async throws {
        let key = SnippetStorageLocations.rootOverrideEnvironmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, directory.appendingPathComponent("library").path, 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        let store = SnippetStore(configuration: .iOS)
        var snippet = try store.addSnippet(name: "Fixture", content: replacement)
        snippet.keyword = keyword
        XCTAssertTrue(store.update(snippet))
        let engine = SnippetExpansionEngine(store: store, usage: SnippetUsageStore())
        engine.startIfNeeded()
        try await run(engine)
    }

    // The original trigger is already in the editor. Feed the matching keystrokes only
    // to this engine so other installed expanders don't also act on the test document.
    static func expand(query: String, using engine: SnippetExpansionEngine) async throws {
        func keyDown(_ key: CGKeyCode, _ text: String) throws -> Bool {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            return SnippetExpansionEngine.eventTapCallback(type: .keyDown, event: event,
                refcon: Unmanaged.passUnretained(engine.callbackContext).toOpaque()) == nil
        }
        _ = try keyDown(42, "\\")
        for character in query { _ = try keyDown(3, String(character)) }
        if query != "fixture" {
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(try keyDown(48, "\t"))
        }
    }

    nonisolated private static let fixtureEventTag: Int64 = 0x53504E5454455354

    static func typeKeys(_ text: String, to editor: NSRunningApplication, interval: Duration = .milliseconds(40),
                         stillFocused: () -> Bool) async throws {
        // PID-addressed events bypass the session tap. Exercise the real session
        // path, and consume our tagged keystrokes if the OS routes them elsewhere.
        let keyboard = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        let filter = try XCTUnwrap(CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: keyboard, callback: { _, _, event, context in
                if event.getIntegerValueField(.eventSourceUserData) == DesktopExpansionFixture.fixtureEventTag,
                   event.getIntegerValueField(.eventTargetUnixProcessID) != Int64(Int(bitPattern: context)) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: UnsafeMutableRawPointer(bitPattern: Int(editor.processIdentifier))))
        let source = CFMachPortCreateRunLoopSource(nil, filter, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        defer {
            CFMachPortInvalidate(filter)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let keyCodes: [Character: CGKeyCode] = ["\t": 48, "\\": 42, "z": 6, "q": 12, "f": 3,
            "i": 34, "x": 7, "t": 17, "u": 32, "r": 15, "e": 14]
        for character in text {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == editor.processIdentifier,
                  stillFocused()
            else { return XCTFail("Editor lost focus while typing the trigger") }
            guard CGEvent.tapIsEnabled(tap: filter) else { return XCTFail("Fixture input filter disabled") }
            let code = try XCTUnwrap(keyCodes[character])
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
                key.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                key.setIntegerValueField(.eventSourceUserData, value: Self.fixtureEventTag)
                key.post(tap: .cgSessionEventTap)
            }
            try await Task.sleep(for: interval)
        }
    }

    // LaunchServices may have put the test process or another fixture frontmost.
    // Call this only after verifying the focused window belongs to the current case.
    static func activate(_ instance: NSRunningApplication, app: AXUIElement) {
        NSApp.yieldActivation(to: instance)
        instance.activate()
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = attribute(app, "AXFocusedWindow"), CFGetTypeID(window) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(window as! AXUIElement, kAXRaiseAction as CFString)
        }
    }

    // Call only for a fresh process that the fixture launched and owns.
    static func closeOwnedInstance(_ instance: NSRunningApplication) async {
        let pid = instance.processIdentifier
        func exited() -> Bool {
            instance.isTerminated || (pid > 0 && kill(pid, 0) == -1 && errno == ESRCH)
        }
        func waitForExit() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !exited(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            return exited()
        }
        instance.terminate()
        if await waitForExit() { return }
        instance.forceTerminate()
        if await waitForExit() { return }
        // LaunchServices can accept the quit request without stopping an Electron
        // process. Recheck the PID and launch identity before using the kernel.
        if let current = NSRunningApplication(processIdentifier: pid),
           let launchDate = instance.launchDate, current.launchDate == launchDate,
           current.executableURL == instance.executableURL, current == instance {
            _ = kill(pid, SIGKILL)
        }
        let didExit = await waitForExit()
        XCTAssertTrue(didExit, "Disposable test application did not exit")
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

@MainActor
extension XCTestCase {
    func pasteFixtureHistory(_ text: String, using engine: SnippetExpansionEngine,
                            pasteAfterCopy: (() throws -> Void)? = nil,
                            verify: () async throws -> Void) async throws {
        let target = engine.captureClipboardHistoryTarget()
        guard (target == nil) == (pasteAfterCopy != nil) else {
            return XCTFail("Unexpected Clipboard History destination")
        }
        let board = NSPasteboard.general
        let suite = "BrowserHistoryFixture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: ClipboardHistoryService.enabledPreferenceKey)
        let entry = ClipboardHistoryEntry(text: text)
        let service = ClipboardHistoryService(defaults: defaults, storage: PanelTestStorage(entries: [entry]),
            pasteboardProvider: { PanelTestPasteboard() }, frontmostBundleID: { nil }, schedulesTimer: false)
        defer { service.setEnabled(false); defaults.removePersistentDomain(forName: suite) }
        await service.waitForPendingPersistence()
        let panel = ClipboardHistoryPanelController(service: service)
        defer { panel.dismiss() }
        let snapshot = PasteboardSnapshot(reading: board)
        let original = try XCTUnwrap(snapshot.makeItems())
        var generation: Int?
        defer {
            if let generation, board.changeCount == generation {
                board.clearContents()
                if !original.isEmpty { XCTAssertTrue(board.writeObjects(original)) }
            }
        }
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        engine.setClipboardHistoryPickerActive(true)
        let dispatched = expectation(description: "picker dispatch")
        panel.show(canPaste: target != nil, onPaste: { item in
            guard let target, board.changeCount == snapshot.changeCount else {
                XCTFail("Clipboard changed during fixture setup")
                dispatched.fulfill()
                return
            }
            engine.pasteClipboardHistoryText(item.text, to: target) { message in
                if board.types?.contains(ClipboardHistoryPasteTransaction.internalType) == true,
                   board.string(forType: .string) == entry.text { generation = board.changeCount }
                XCTAssertNil(message)
                dispatched.fulfill()
            }
        }, onCopy: { item in
            defer { dispatched.fulfill() }
            guard pasteAfterCopy != nil, board.changeCount == snapshot.changeCount,
                  engine.copyClipboardHistoryText(item.text) else { return XCTFail("Could not copy the selected fixture entry") }
            generation = board.changeCount
        }, onCreateSnippet: { _ in XCTFail("Unexpected create") },
        onDismiss: { _ in engine.setClipboardHistoryPickerActive(false) })
        let window = try XCTUnwrap(NSApp.windows.first { !initialWindows.contains($0.windowNumber) && $0.isVisible })
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        await fulfillment(of: [dispatched], timeout: 3)
        if let pasteAfterCopy {
            guard let generation, board.changeCount == generation else { return XCTFail("Clipboard changed before native paste") }
            try pasteAfterCopy()
        }
        try await verify()
    }
}
#endif
