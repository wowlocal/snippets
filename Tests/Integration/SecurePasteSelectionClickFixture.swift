// Opt-in WindowServer regression test. Uses only a disposable synthetic window:
// no Snippets installation, library, clipboard, authentication, or form submission.
import AppKit
import ApplicationServices

@MainActor
private final class SelectionHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class SelectionHostView: NSView {
    var clicks = 0
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
}

@MainActor
private final class SelectionClickFixture: NSObject, NSApplicationDelegate {
    private let controller = SecurePasteFieldSelectionController()
    private var host: NSWindow!

    private enum Scenario: CaseIterable {
        case unhighlightedInterior, highlightedInterior, cancelButton
    }
    private enum FixtureError: Error { case unavailable, focusChanged, routing }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                guard let screen = NSScreen.screens.first,
                      screen.visibleFrame.width >= 365, screen.visibleFrame.height >= 529
                else { throw FixtureError.unavailable }
                let frame = NSRect(x: screen.visibleFrame.midX - 182.5,
                                   y: screen.visibleFrame.midY - 264.5, width: 365, height: 529)
                host = SelectionHostWindow(contentRect: frame, styleMask: [.borderless],
                                           backing: .buffered, defer: false)
                host.isReleasedWhenClosed = false
                let base = SelectionHostView(frame: NSRect(origin: .zero, size: frame.size))
                host.contentView = base
                host.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(300))

                for scenario in Scenario.allCases {
                    base.clicks = 0
                    var selections = 0
                    var dismissals = 0
                    let field = NSRect(x: 30, y: 250, width: 300, height: 40)
                    controller.show(frame: frame, targetPID: ProcessInfo.processInfo.processIdentifier,
                        previewField: { _ in scenario == .highlightedInterior ? field : nil },
                        onDismiss: { dismissals += 1 }, onSelection: { _ in selections += 1 })
                    guard let panel = NSApp.windows.first(where: {
                        $0.isVisible && $0.contentView is SecurePasteFieldSelectionView
                    }), let view = panel.contentView as? SecurePasteFieldSelectionView
                    else { throw FixtureError.unavailable }
                    try await Task.sleep(for: .milliseconds(200))
                    let localPoint = scenario == .cancelButton
                        ? NSPoint(x: view.instructionFrame.maxX - 22, y: view.instructionFrame.maxY - 20)
                        : NSPoint(x: field.midX, y: field.midY)
                    let point = CGPoint(x: frame.minX + localPoint.x,
                                        y: screen.frame.maxY - (frame.minY + localPoint.y))
                    try requireFixtureAt(point)
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(200))
                    if scenario == .highlightedInterior, view.highlightedField != field {
                        throw FixtureError.routing
                    }
                    try requireFixtureAt(point)
                    guard controller.isVisible, !panel.isKeyWindow else { throw FixtureError.focusChanged }
                    // Post through WindowServer, not NSView.mouseDown or NSWindow.sendEvent:
                    // fully transparent pixels can bypass both AppKit entry points.
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(200))
                    guard selections == (scenario == .cancelButton ? 0 : 1),
                          dismissals == 1, base.clicks == 0, !controller.isVisible,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier
                            == ProcessInfo.processInfo.processIdentifier
                    else {
                        print("FAIL routing counts: selections=\(selections), dismissals=\(dismissals), hostClicks=\(base.clicks)")
                        throw FixtureError.routing
                    }
                    print("PASS selection overlay case \(scenario): click consumed, host untouched")
                }
                host.close()
                NSApp.terminate(nil)
            } catch {
                controller.cancel()
                host?.close()
                // Closed local failure vocabulary; never print arbitrary error text.
                print("FAIL selection overlay WindowServer routing or fixture readiness")
                exit(1)
            }
        }
    }

    /// Never inject a global click if another app has taken focus or covers this point.
    private func requireFixtureAt(_ point: CGPoint) throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID
        else { throw FixtureError.focusChanged }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var hit: AXUIElement?
        var hitPID: pid_t = 0
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit, AXUIElementGetPid(hit, &hitPID) == .success, hitPID == ownPID
        else { throw FixtureError.focusChanged }
    }
}

@main
private struct Main {
    @MainActor static func main() {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            print("This opt-in GUI test requires Accessibility access for the invoking terminal.")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = SelectionClickFixture()
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }
}
