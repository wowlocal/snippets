// Synthetic host for embedded browsers that report only container focus and
// acknowledge AX setters without applying them. No library, vault or network.
import AppKit
import ApplicationServices

@MainActor private final class ContainerFocusApplication: NSApplication {
    var focusContainer: NSView?
    override var accessibilityFocusedUIElement: Any? {
        focusContainer ?? super.accessibilityFocusedUIElement
    }
}

@MainActor private final class NoOpAXPassword: NSSecureTextField {
    var valueWrites = 0
    override func isAccessibilityFocused() -> Bool { false }
    override func setAccessibilityFocused(_ focused: Bool) {}
    override func setAccessibilityValue(_ value: Any?) { valueWrites += 1 }
}

private func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.2)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

@MainActor private func drive(_ sample: String, control: Bool) -> Bool {
    _ = NSApplication.shared
    guard let parent = NSRunningApplication(processIdentifier: getppid()),
          parent.executableURL?.resolvingSymlinksInPath()
            == URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    else { return false }
    let app = AXUIElementCreateApplication(getppid())
    guard let windows = read(app, "AXWindows") as? [AXUIElement], windows.count == 1,
          read(windows[0], "AXTitle") as? String == "Snippets synthetic broken AX host"
    else { return false }
    _ = parent.activate()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getppid(),
          let focused = read(app, "AXFocusedUIElement"), CFGetTypeID(focused) == AXUIElementGetTypeID(),
          read(focused as! AXUIElement, "AXRole") as? String == "AXWebArea"
    else { return false }
    var pending = [windows[0]]
    var field: AXUIElement?
    for _ in 0..<100 {
        guard let candidate = pending.popLast() else { break }
        if read(candidate, "AXSubrole") as? String == "AXSecureTextField" { field = candidate; break }
        pending += read(candidate, "AXChildren") as? [AXUIElement] ?? []
    }
    guard let field, (read(field, "AXFocused") as? NSNumber)?.boolValue == false else { return false }
    if control {
        // A separate test case proves that the host really reproduces the no-op.
        return AXUIElementSetAttributeValue(field, "AXValue" as CFString, sample as CFString) == .success
    }
    let strategy = SecurePasteDeliveryPolicy.strategy(targetIsSecureTextField: true,
        valueIsSettable: true, targetIsInsideWebArea: true, targetHasEligibleWebTextRole: true,
        webRangeReplacementIsAvailable: false, webPasswordFocus: .explicitFieldWithContainerFocus)
    guard strategy == .clickThenTypeSecureUnicode else { return false }
    guard let input = SecurePasteDirectInputPolicy.makeEvents(text: sample, eventTag: 123) else {
        return SecurePasteDirectInputPolicy.validation(of: sample) == .containsControlCharacter
    }
    guard let position = read(field, "AXPosition"), let size = read(field, "AXSize"),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return false }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return false }
    point.x += dimensions.width - 8
    point.y += dimensions.height / 2
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.2)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
          let hit, CFEqual(hit, field),
          let windowPosition = read(windows[0], "AXPosition"), let windowSize = read(windows[0], "AXSize")
    else { return false }
    var origin = CGPoint.zero
    var windowDimensions = CGSize.zero
    guard AXValueGetValue(windowPosition as! AXValue, .cgPoint, &origin),
          AXValueGetValue(windowSize as! AXValue, .cgSize, &windowDimensions),
          let clickTarget = { () -> SecurePasteDirectInputPolicy.ClickTarget? in
              for _ in 0..<4 {
                  if let target = SecurePasteDirectInputPolicy.visibleClickTarget(at: .init(accessibility: point),
                      targetPID: getppid(), expectedWindowFrame: CGRect(origin: origin, size: windowDimensions)) { return target }
                  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
              }
              return nil
          }(),
          let click = SecurePasteDirectInputPolicy.makeClickEvents(target: clickTarget, eventTag: 123)
    else { return false }
    click.mouseDown.post(tap: .cghidEventTap)
    click.mouseUp.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    // The important regression: real keyboard focus is now in the password, but
    // the host still exposes only AXWebArea and false AXFocused.
    guard let after = read(app, "AXFocusedUIElement"), CFEqual(after, focused),
          (read(field, "AXFocused") as? NSNumber)?.boolValue == false,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == getppid()
    else { return false }
    input.keyDown.postToPid(getppid())
    input.keyUp.postToPid(getppid())
    Thread.sleep(forTimeInterval: 0.25)
    return true
}

@MainActor private final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let password = NoOpAXPassword(frame: NSRect(x: 40, y: 130, width: 400, height: 30))
    let other = NSTextField(frame: NSRect(x: 40, y: 70, width: 400, height: 30))

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 500, height: 240),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Snippets synthetic broken AX host"
        let root = NSView(frame: window.contentView!.bounds)
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXWebArea"))
        root.addSubview(password)
        root.addSubview(other)
        root.setAccessibilityChildren([password, other])
        window.contentView = root
        (NSApp as! ContainerFocusApplication).focusContainer = root
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            for (index, sample) in ["probe", "synthetic-😀", String(repeating: "тест-", count: 32), "no\nsubmit"].enumerated() {
                password.stringValue = ""
                other.stringValue = ""
                password.valueWrites = 0
                // Without the shipping click, typing would reach this bystander.
                window.makeFirstResponder(other)
                try? await Task.sleep(for: .milliseconds(200))
                let driver = Process()
                driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                driver.arguments = ["--driver", sample, index == 0 ? "control" : "input"]
                do { try driver.run() } catch { exit(1) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while driver.isRunning && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if driver.isRunning { driver.terminate(); exit(1) }
                try? await Task.sleep(for: .milliseconds(100))
                let expected = index == 0 || index == 3 ? "" : sample
                guard driver.terminationStatus == 0, password.stringValue == expected,
                      other.stringValue.isEmpty, password.valueWrites == (index == 0 ? 1 : 0)
                else { print("FAIL broken AX case \(index)"); exit(1) }
                print("PASS broken AX case \(index): real input, unchanged bystander, no fallback")
            }
            NSApp.terminate(nil)
        }
    }
}

@main private struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--driver" {
            exit(drive(CommandLine.arguments[2], control: CommandLine.arguments[3] == "control") ? 0 : 1)
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { exit(2) }
        let app = ContainerFocusApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = Fixture()
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }
}
