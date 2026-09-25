import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class ClipboardHistoryMenuTrackingTests: XCTestCase {
    func testEscapeClosesNativeActionsMenuBeforeDismissingPicker() async throws {
        let suite = "ClipboardHistoryMenuTrackingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: ClipboardHistoryService.enabledPreferenceKey)
        let pasteboard = MenuTrackingPasteboard()
        let service = ClipboardHistoryService(defaults: defaults,
            storage: MenuTrackingStorage(), pasteboardProvider: { pasteboard },
            frontmostBundleID: { nil }, schedulesTimer: false)
        await service.waitForPendingPersistence()
        defer {
            service.setEnabled(false)
            defaults.removePersistentDomain(forName: suite)
        }

        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        // Intentionally use the default presenter: this enters NSMenu's real
        // tracking loop instead of the injected presenter used by unit tests.
        let controller = ClipboardHistoryPanelController(service: service)
        defer { controller.dismiss() }
        var dismissals: [Bool] = []
        controller.show(canPaste: true,
            onPaste: { _ in XCTFail("Cancelling the menu must not paste") },
            onCopy: { _ in XCTFail("Cancelling the menu must not copy") },
            onCreateSnippet: { _ in XCTFail("Cancelling the menu must not create a snippet") },
            onDismiss: { dismissals.append($0) })
        let window = try XCTUnwrap(NSApp.windows.first {
            !initialWindows.contains($0.windowNumber) && $0.isVisible
        })
        let search = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "menu fixture"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        await waitForClipboardSearch(controller)
        XCTAssertTrue(window.isKeyWindow)

        let probe = NativeMenuEscapeProbe(window: window)
        defer { probe.stop() }
        probe.start()
        window.sendEvent(try key(code: 40, characters: "k", modifiers: .command, window: window))

        XCTAssertTrue(probe.beganTracking, "The actual native actions menu must open")
        XCTAssertTrue(probe.endedTracking, "Escape must leave the native menu tracking loop")
        XCTAssertFalse(probe.usedWatchdog, "The local Escape event must close the menu without fallback cancellation")

        // Let the controller's deferred key-status reconciliation run before
        // asserting that cancellation restored the search panel's keyboard focus.
        let reconciled = expectation(description: "Menu focus reconciled")
        DispatchQueue.main.async { reconciled.fulfill() }
        await fulfillment(of: [reconciled], timeout: 1)
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertEqual(search.stringValue, "menu fixture")
        XCTAssertTrue(dismissals.isEmpty)

        window.sendEvent(try key(code: 53, characters: "\u{1b}", modifiers: [], window: window))
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(dismissals, [true], "Only the second Escape should dismiss the picker")
    }

    private func key(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                     window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class NativeMenuEscapeProbe {
    private let window: NSWindow
    private var observers: [NSObjectProtocol] = []
    private var timers: [Timer] = []
    private weak var trackedMenu: NSMenu?
    private(set) var beganTracking = false
    private(set) var endedTracking = false
    private(set) var usedWatchdog = false

    init(window: NSWindow) { self.window = window }

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: nil) { [weak self] notification in
                MainActor.assumeIsolated { self?.menuBegan(notification) }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
            object: nil, queue: nil) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu,
                          menu === self.trackedMenu else { return }
                    self.endedTracking = true
                    self.timers.forEach { $0.invalidate() }
                }
            })
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        trackedMenu?.cancelTrackingWithoutAnimation()
    }

    private func menuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              menu.title == "Clipboard History Actions", !beganTracking else { return }
        beganTracking = true
        trackedMenu = menu
        let escape = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.endedTracking,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                        isARepeat: false, keyCode: 53) else { return }
                // This is the test host's private AppKit queue, never a global
                // CGEvent or a keystroke sent to the user's frontmost app.
                NSApp.postEvent(event, atStart: true)
            }
        }
        let watchdog = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.endedTracking else { return }
                self.usedWatchdog = true
                self.trackedMenu?.cancelTrackingWithoutAnimation()
            }
        }
        timers = [escape, watchdog]
        for timer in timers { RunLoop.main.add(timer, forMode: .eventTracking) }
    }
}

@MainActor
private final class MenuTrackingPasteboard: ClipboardHistoryPasteboardReading {
    var changeCount: Int { 0 }
    var typeNames: [String] { [] }
    func readText() -> String? { nil }
}

nonisolated private struct MenuTrackingStorage: ClipboardHistoryPersisting {
    var directoryExists: Bool { true }
    func prepareDirectory() throws {}
    func load() throws -> [ClipboardHistoryEntry] { [ClipboardHistoryEntry(text: "Native menu fixture")] }
    func save(_ entries: [ClipboardHistoryEntry]) throws {}
    func clear() throws {}
}
#endif
