// Called only by scripts/test-secure-paste-chromium.mjs against its disposable
// Chromium profile and local fixture. Never reads password values or selections.
import AppKit
import ApplicationServices

@main
private struct Main {
    @MainActor static func main() {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 5,
              let pid = Int32(CommandLine.arguments[1]),
              let app = NSRunningApplication(processIdentifier: pid),
              app.executableURL?.lastPathComponent == "Google Chrome",
              AXIsProcessTrusted() else { exit(2) }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let mode = CommandLine.arguments[3]
        let sample = CommandLine.arguments[4] == "long"
            ? String(repeating: "synthetic-", count: 16) : "synthetic-😀"
        let application = AXUIElementCreateApplication(pid)
        func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            let budget = AXMessagingBudget()
            var value: CFTypeRef?
            guard budget.copyAttributeValue(of: element, attribute: name as CFString,
                                            into: &value) == .success else { return nil }
            return value
        }
        func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
            guard let value = read(source, name), CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            return (value as! AXUIElement)
        }
        guard let windows = read(application, "AXWindows") as? [AXUIElement],
              windows.count == 1, let window = windows.first,
              read(window, "AXTitle") as? String == "Snippets synthetic Chromium input"
        else { exit(3) }
        var field: AXUIElement?
        for _ in 0..<30 {
            var pending = [window]
            for _ in 0..<200 {
                guard let candidate = pending.popLast() else { break }
                if read(candidate, "AXSubrole") as? String == "AXSecureTextField" {
                    field = candidate
                    break
                }
                pending += read(candidate, "AXChildren") as? [AXUIElement] ?? []
            }
            if field != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let field else { exit(4) }
        var root: AXUIElement? = field
        for _ in 0..<16 {
            guard let current = root else { break }
            if read(current, "AXRole") as? String == "AXWebArea" { break }
            root = element(current, "AXParent")
        }
        guard let root, read(root, "AXRole") as? String == "AXWebArea",
              let url = read(root, "AXURL") as? URL,
              url.resolvingSymlinksInPath() == fixtureURL.resolvingSymlinksInPath() else { exit(5) }
        _ = app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { exit(15) }

        func validate() -> SecurePasteTargetResolver.Validation {
            let budget = AXMessagingBudget()
            return SecurePasteTargetResolver.validation(
            field: field, root: root, window: window, wasSecure: true,
            explicit: mode != "no-explicit", canContinue: { budget.canContinue },
            metadata: { candidate in
                .init(isTextControl: read(candidate, "AXRole") as? String == "AXTextField",
                      isFocused: (read(candidate, "AXFocused") as? NSNumber)?.boolValue == true,
                      isEnabled: (read(candidate, "AXEnabled") as? NSNumber)?.boolValue == true,
                      isSecure: read(candidate, "AXSubrole") as? String == "AXSecureTextField")
            }, currentFocus: { element(application, "AXFocusedUIElement") },
            currentWindow: { element($0, "AXWindow") }, windowIsUnchanged: { true },
            parent: { element($0, "AXParent") }, hitTest: {
                guard let position = read(field, "AXPosition"), let size = read(field, "AXSize"),
                      CFGetTypeID(position) == AXValueGetTypeID(),
                      CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
                var point = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                      AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(application,
                    Float(point.x + dimensions.width / 4), Float(point.y + dimensions.height / 2),
                    &hit) == .success else { return nil }
                return hit
            })
        }
        let validation = validate()
        if mode == "bystander" || mode == "no-explicit" {
            guard validation == (mode == "bystander" ? .focusChanged : .fieldFocusPending)
            else { exit(6) }
            return
        }
        guard validation == .valid else { exit(7) }
        let focused = element(application, "AXFocusedUIElement")
        let exactFocus = focused.map { CFEqual($0, field) } ?? false
        guard mode == "focused" ? exactFocus : focused.map({ CFEqual($0, root) }) == true
        else { exit(8) }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field, "AXValue" as CFString, &writable) == .success
        else { exit(9) }
        let strategy = SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: true, valueIsSettable: writable.boolValue,
            targetIsInsideWebArea: true, targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: false,
            webPasswordFocus: exactFocus ? .confirmedField : .explicitFieldWithContainerFocus)
        switch strategy {
        case .clickThenTypeSecureUnicode:
            guard !exactFocus, CGPreflightPostEventAccess(),
                  let position = read(field, "AXPosition"), let size = read(field, "AXSize"),
                  let windowPosition = read(window, "AXPosition"), let windowSize = read(window, "AXSize") else { exit(10) }
            var point = CGPoint.zero, origin = CGPoint.zero
            var dimensions = CGSize.zero, windowDimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                  AXValueGetValue(windowPosition as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(windowSize as! AXValue, .cgSize, &windowDimensions) else { exit(10) }
            point.x += dimensions.width / 4
            point.y += dimensions.height / 2
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  let hit, CFEqual(hit, field),
                  let clickTarget = SecurePasteDirectInputPolicy.visibleClickTarget(at: .init(accessibility: point),
                    targetPID: pid, expectedWindowFrame: CGRect(origin: origin, size: windowDimensions)),
                  let click = SecurePasteDirectInputPolicy.makeClickEvents(target: clickTarget, eventTag: 123)
            else { exit(10) }
            let clickedAt = ContinuousClock.now
            click.mouseDown.post(tap: .cghidEventTap)
            click.mouseUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.05)
            let afterClick = validate()
            if mode == "redirect" {
                guard afterClick == .focusChanged else { exit(11) }
                return
            }
            guard afterClick == .valid, SecurePasteDirectInputPolicy.clickIsFresh(issuedAt: clickedAt),
                  let input = SecurePasteDirectInputPolicy.makeEvents(text: sample, eventTag: 123)
            else { exit(11) }
            input.keyDown.postToPid(pid)
            input.keyUp.postToPid(pid)
        case .typeSecureUnicode:
            guard exactFocus, CGPreflightPostEventAccess(),
                  let events = SecurePasteDirectInputPolicy.makeEvents(text: sample, eventTag: 123)
            else { exit(12) }
            events.keyDown.postToPid(pid)
            events.keyUp.postToPid(pid)
        default: exit(13)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
}
