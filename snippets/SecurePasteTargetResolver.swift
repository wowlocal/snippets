import AppKit

/// Metadata-only traversal used only by explicit Secure Paste. A failed or truncated
/// search is never evidence that a candidate is the only focused field.
@MainActor
enum SecurePasteTargetResolver {
    enum Validation: String, CaseIterable {
        case valid
        case budgetExhausted = "budget_exhausted"
        case fieldUnavailable = "field_unavailable"
        case fieldDisabled = "field_disabled"
        case fieldTypeChanged = "field_type_changed"
        case windowChanged = "window_changed"
        case ancestryChanged = "ancestry_changed"
        case focusUnavailable = "focus_unavailable"
        case focusChanged = "focus_changed"
        case fieldFocusPending = "field_focus_pending"
        case hitTargetChanged = "hit_target_changed"
        case applicationNotFrontmost = "application_not_frontmost"
        case keyboardOwnerPending = "keyboard_owner_pending"
        case secureInputPending = "secure_input_pending"
        case cancelled

        var canRetryHandoff: Bool {
            switch self {
            case .valid, .budgetExhausted, .focusUnavailable, .fieldFocusPending,
                 .applicationNotFrontmost, .keyboardOwnerPending, .secureInputPending: true
            default: false
            }
        }
    }
    struct Metadata {
        let isTextControl: Bool
        let isFocused: Bool
        let isEnabled: Bool
        var isSecure: Bool = false
    }

    enum Resolution<Node> {
        case focused(Node)
        case noTextField
        case ambiguous
        case unavailable
    }

    static func focusedDescendant<Node: Equatable>(
        of root: Node,
        maximumNodes: Int = 128,
        maximumDepth: Int = 16,
        canContinue: () -> Bool,
        metadata: (Node) -> Metadata?,
        children: (Node) -> [Node]?
    ) -> Resolution<Node> {
        var pending = [(root, 0)]
        var visited: [Node] = []
        var focused: Node?
        var sawTextControl = false
        while let (node, depth) = pending.popLast() {
            guard canContinue(), visited.count < maximumNodes,
                  !visited.contains(node), let info = metadata(node)
            else { return .unavailable }
            visited.append(node)
            if node != root, info.isTextControl {
                sawTextControl = true
                if info.isFocused && info.isEnabled {
                    guard focused == nil else { return .ambiguous }
                    focused = node
                }
                // Text controls are leaves for targeting, even if they expose
                // decoration or text children. Never read any text attributes.
                continue
            }
            guard let descendants = children(node) else { return .unavailable }
            guard descendants.isEmpty || depth < maximumDepth,
                  descendants.count <= maximumNodes - visited.count - pending.count
            else { return .unavailable }
            pending.append(contentsOf: descendants.map { ($0, depth + 1) })
        }
        guard canContinue() else { return .unavailable }
        return focused.map { .focused($0) } ?? (sawTextControl ? .ambiguous : .noTextField)
    }

    static func belongs<Node: Equatable>(
        _ node: Node, to root: Node,
        maximumDepth: Int = 16,
        parent: (Node) -> Node?
    ) -> Bool {
        var current = node
        var visited: [Node] = []
        for depth in 0...maximumDepth {
            if current == root { return true }
            guard depth < maximumDepth, !visited.contains(current), let next = parent(current)
            else { return false }
            visited.append(current)
            current = next
        }
        return false
    }

    /// Re-run against fresh metadata after every asynchronous handoff and before
    /// writing. An explicit hit is authority for this object, not another field
    /// that happens to occupy its old position after navigation.
    static func validation<Node: Equatable>(
        field: Node, root: Node, window: Node, wasSecure: Bool,
        explicit: Bool,
        canContinue: () -> Bool,
        metadata: (Node) -> Metadata?,
        currentFocus: () -> Node?,
        currentWindow: (Node) -> Node?,
        windowIsUnchanged: () -> Bool,
        parent: (Node) -> Node?,
        hitTest: () -> Node?
    ) -> Validation {
        func failure(_ reason: Validation) -> Validation {
            canContinue() ? reason : .budgetExhausted
        }
        guard canContinue() else { return .budgetExhausted }
        guard field != root, let info = metadata(field) else { return failure(.fieldUnavailable) }
        guard info.isTextControl, info.isSecure == wasSecure else { return failure(.fieldTypeChanged) }
        guard info.isEnabled else { return failure(.fieldDisabled) }
        guard currentWindow(field) == window, windowIsUnchanged() else { return failure(.windowChanged) }
        guard belongs(field, to: root, parent: parent) else { return failure(.ancestryChanged) }
        guard let focus = currentFocus() else { return failure(.focusUnavailable) }
        guard focus == root || focus == field else { return failure(.focusChanged) }
        if explicit {
            guard let hit = hitTest(), belongs(hit, to: field, parent: parent)
            else { return failure(.hitTargetChanged) }
        } else if !info.isFocused {
            return failure(.fieldFocusPending)
        }
        return canContinue() ? .valid : .budgetExhausted
    }
}

/// Shares bounded focus recovery between native fields, container targets, and
/// authenticated expansions. No plaintext-bearing operation belongs in this loop.
@MainActor
enum SecurePasteFocusHandoff {
    enum Mode: CaseIterable {
        case withoutAuthentication
        case afterAuthentication
    }

    struct Report {
        let validation: SecurePasteTargetResolver.Validation
        let firstTransient: SecurePasteTargetResolver.Validation?
        let attempts: Int
        let consecutiveConfirmations: Int
    }

    // Probe immediately, then retry quickly while the picker or authentication UI
    // returns keyboard ownership. Keep the previous 1.64-second total sleep budget
    // for slow hosts; a successful sample always gets its next check after 25 ms.
    private static let confirmationDelay: Duration = .milliseconds(25)
    private static let retryDelays: [Duration] = [
        .zero, .milliseconds(25), .milliseconds(25), .milliseconds(50),
        .milliseconds(100), .milliseconds(160), .milliseconds(280),
        .milliseconds(500), .milliseconds(500),
    ]

    static func run(
        mode: Mode,
        sleep: (Duration) async -> Void,
        attempt: () -> SecurePasteTargetResolver.Validation
    ) async -> Report {
        var consecutive = 0
        var firstTransient: SecurePasteTargetResolver.Validation?
        var last: SecurePasteTargetResolver.Validation = .focusUnavailable
        for (index, retryDelay) in retryDelays.enumerated() {
            let delay = consecutive > 0 ? confirmationDelay : retryDelay
            // Even sleeping for zero would introduce an unnecessary task handoff.
            if delay > .zero { await sleep(delay) }
            guard !Task.isCancelled else {
                return Report(validation: .cancelled, firstTransient: firstTransient, attempts: index,
                              consecutiveConfirmations: consecutive)
            }
            last = attempt()
            consecutive = SecurePasteAuthenticationHandoffPolicy.updatedConsecutiveFocusConfirmations(
                current: consecutive, targetIsFrontmost: last == .valid, focusWasReasserted: last == .valid)
            guard last.canRetryHandoff else {
                return Report(validation: last, firstTransient: firstTransient, attempts: index + 1,
                              consecutiveConfirmations: consecutive)
            }
            if last == .valid {
                if mode == .withoutAuthentication
                    || SecurePasteAuthenticationHandoffPolicy.focusIsStable(consecutiveConfirmations: consecutive) {
                    return Report(validation: .valid, firstTransient: firstTransient, attempts: index + 1,
                                  consecutiveConfirmations: consecutive)
                }
            } else {
                firstTransient = firstTransient ?? last
            }
        }
        // An incomplete confirmation sequence cannot authorize delivery at timeout.
        return Report(validation: last == .valid ? .focusUnavailable : last,
                      firstTransient: firstTransient, attempts: retryDelays.count,
                      consecutiveConfirmations: consecutive)
    }

    /// Container identity must still be valid before attempting an AX focus write.
    /// Structural changes abort; only transient focus/AX availability may settle.
    static func runForContainer(
        mode: Mode,
        sleep: (Duration) async -> Void,
        observe: () -> SecurePasteTargetResolver.Validation,
        restoreFocus: () -> Void
    ) async -> Report {
        var firstTransient: SecurePasteTargetResolver.Validation?
        let report = await run(mode: mode, sleep: sleep) {
            let validation = observe()
            if validation != .valid && validation.canRetryHandoff {
                firstTransient = firstTransient ?? validation
            }
            if validation == .valid && mode == .withoutAuthentication { return .valid }
            if validation == .valid || validation == .fieldFocusPending {
                restoreFocus()
                let restored = observe()
                if restored != .valid && restored.canRetryHandoff {
                    firstTransient = firstTransient ?? restored
                }
                return restored
            }
            return validation
        }
        return Report(validation: report.validation, firstTransient: firstTransient, attempts: report.attempts,
                      consecutiveConfirmations: report.consecutiveConfirmations)
    }
}

/// An explicit choice authorizes an AX-addressed write, never blind keyboard input.
/// The window stays non-key so it does not steal the host's keyboard focus.
@MainActor
final class SecurePasteFieldSelectionController {
    private var panel: NSPanel?
    private var activationObserver: NSObjectProtocol?
    private var expiration: DispatchWorkItem?
    private var onDismiss: (() -> Void)?
    private var generation = 0
    var isVisible: Bool { panel != nil }

    func cancel() {
        generation += 1
        expiration?.cancel()
        expiration = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let view = panel?.contentView as? SecurePasteFieldSelectionView {
            view.cancelPreview()
            view.previewField = nil
            view.onClick = nil
            view.onCancel = nil
        }
        panel?.orderOut(nil)
        panel = nil
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    func show(frame: NSRect, targetPID: pid_t,
              previewField: @escaping (CGPoint) -> NSRect? = { _ in nil },
              onDismiss: @escaping () -> Void = {}, onSelection: @escaping (CGPoint) -> Void) {
        cancel()
        let generation = generation
        self.onDismiss = onDismiss
        let panel = FieldSelectionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        let view = SecurePasteFieldSelectionView(frame: NSRect(origin: .zero, size: frame.size))
        view.previewField = previewField
        view.onCancel = { [weak self] in
            guard let self, self.generation == generation else { return }
            self.cancel()
        }
        view.onClick = { [weak self] point in
            guard let self, self.generation == generation, self.isVisible else { return }
            self.cancel()
            onSelection(point)
        }
        panel.contentView = view
        self.panel = panel
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication, app.processIdentifier != targetPID else { return }
            MainActor.assumeIsolated { self?.cancel() }
        }
        let expiration = DispatchWorkItem { [weak self] in self?.cancel() }
        self.expiration = expiration
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: expiration)
        panel.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        view.updatePreview(at: panel.mouseLocationOutsideOfEventStream)
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: "Secure Paste. Snippets can’t confirm the active field. Move over a text field to highlight it, then click to choose it. Drag the instruction card if it covers a field. Command backslash cancels.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

@MainActor
private final class FieldSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The highlight is a disposable preview, never authority for insertion. The click
/// callback always performs a fresh capture, even when a preview is visible.
@MainActor
final class SecurePasteFieldSelectionView: NSView {
    var onClick: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var previewField: ((CGPoint) -> NSRect?)?
    private(set) var highlightedField: NSRect?
    private let instruction = FieldSelectionInstructionView(frame: .zero)
    private var instructionOrigin: NSPoint?
    private var hoverWork: DispatchWorkItem?
    private var hoverGeneration = 0
    private var pointerTracking: NSTrackingArea?
    var instructionFrame: NSRect { instruction.frame }

    override init(frame: NSRect) {
        super.init(frame: frame)
        instruction.onCancel = { [weak self] in self?.onCancel?() }
        instruction.onDrag = { [weak self] delta in
            guard let self else { return }
            self.cancelPreview()
            self.instructionOrigin = NSPoint(x: self.instruction.frame.minX + delta.x,
                                              y: self.instruction.frame.minY + delta.y)
            self.needsLayout = true
        }
        addSubview(instruction)
        setAccessibilityLabel("Select the destination field for Secure Paste")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = instruction.preferredSize(width: min(332, max(0, bounds.width - 32)))
        let proposed = instructionOrigin ?? NSPoint(x: (bounds.width - size.width) / 2, y: 16)
        instruction.frame = NSRect(
            x: min(max(8, proposed.x), max(8, bounds.width - size.width - 8)),
            y: min(max(8, proposed.y), max(8, bounds.height - size.height - 8)),
            width: size.width, height: size.height)
        window?.invalidateCursorRects(for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if instruction.frame.contains(point) { return super.hitTest(point) }
        return self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        addCursorRect(instruction.frame, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        updatePreview(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { cancelPreview() }

    func cancelPreview() {
        hoverGeneration += 1
        hoverWork?.cancel()
        hoverWork = nil
        highlightedField = nil
        needsDisplay = true
    }

    func updatePreview(at localPoint: NSPoint) {
        let previousHighlight = highlightedField
        cancelPreview()
        guard bounds.contains(localPoint), !instruction.frame.contains(localPoint),
              let point = accessibilityPoint(localPoint) else { return }
        // Avoid flicker while moving inside the same field; the next probe still
        // replaces this hint and a click never uses it as targeting evidence.
        highlightedField = previousHighlight.flatMap { $0.contains(localPoint) ? $0 : nil }
        let generation = hoverGeneration
        // Coalesce mouse movement before sending bounded metadata-only AX requests.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverGeneration == generation else { return }
            self.hoverWork = nil
            self.highlightedField = nil
            self.needsDisplay = true
            guard let frame = self.previewField?(point),
                  self.hoverGeneration == generation,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0,
                  self.bounds.contains(frame), frame.contains(localPoint) else { return }
            self.highlightedField = frame
            self.needsDisplay = true
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Keep the form readable. The outer outline identifies the target window;
        // only the text control under the pointer receives a strong highlight.
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                                   xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
        outline.lineWidth = 2
        outline.stroke()
        if let highlightedField {
            let field = NSBezierPath(roundedRect: highlightedField.insetBy(dx: -3, dy: -3),
                                     xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setStroke()
            field.lineWidth = 8
            field.stroke()
            NSColor.controlAccentColor.setStroke()
            field.lineWidth = 2
            field.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        // Neither the instruction card nor a stale hover preview authorizes a hit
        // on the host beneath it. Only this fresh click is sent to the resolver.
        guard bounds.contains(localPoint), !instruction.frame.contains(localPoint),
              let point = accessibilityPoint(localPoint) else { return }
        cancelPreview()
        onClick?(point)
    }

    private func accessibilityPoint(_ localPoint: NSPoint) -> CGPoint? {
        guard let window, let primaryScreen = NSScreen.screens.first else { return nil }
        let point = window.convertPoint(toScreen: convert(localPoint, to: nil))
        return CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }
}

@MainActor
private final class FieldSelectionInstructionView: NSVisualEffectView {
    var onCancel: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    private var dragPoint: NSPoint?
    private let heading = NSTextField(labelWithString: "Secure Paste")
    private let shortcut = NSTextField(labelWithString: "⌘\\")
    private let title = NSTextField(wrappingLabelWithString: "Click the field to paste into")
    private let detail = NSTextField(wrappingLabelWithString: "Snippets can’t confirm the active field.")
    private let cancelButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        toolTip = "Drag this card to move it away from a field."
        heading.font = .systemFont(ofSize: 11, weight: .medium)
        heading.textColor = .labelColor
        shortcut.font = .systemFont(ofSize: 11)
        shortcut.textColor = .labelColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .labelColor
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel Secure Paste")
        cancelButton.imagePosition = .imageOnly
        cancelButton.isBordered = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection)
        cancelButton.setAccessibilityLabel("Cancel Secure Paste")
        cancelButton.toolTip = "Cancel Secure Paste (⌘\\)"
        for view in [heading, shortcut, title, detail, cancelButton] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func preferredSize(width: CGFloat) -> NSSize {
        NSSize(width: width, height: 12 + 16 + 8
            + textHeight(title, width: width) + 4 + textHeight(detail, width: width) + 12)
    }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: max(1, width - 24), height: 1_000)).height ?? 18)
    }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 12, y: bounds.height - 28, width: bounds.width - 88, height: 16)
        shortcut.frame = NSRect(x: bounds.width - 63, y: bounds.height - 28, width: 26, height: 16)
        cancelButton.frame = NSRect(x: bounds.width - 34, y: bounds.height - 32, width: 24, height: 24)
        let titleHeight = textHeight(title, width: bounds.width)
        title.frame = NSRect(x: 12, y: bounds.height - 36 - titleHeight,
                            width: bounds.width - 24, height: titleHeight)
        detail.frame = NSRect(x: 12, y: 12, width: bounds.width - 24,
                             height: textHeight(detail, width: bounds.width))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSView hit testing receives a point in the superview's coordinates.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return cancelButton.frame.contains(local) ? cancelButton : self
    }

    override func resetCursorRects() { addCursorRect(cancelButton.frame, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) { dragPoint = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let previous = dragPoint else { return }
        dragPoint = event.locationInWindow
        onDrag?(NSPoint(x: event.locationInWindow.x - previous.x,
                       y: event.locationInWindow.y - previous.y))
    }
    override func mouseUp(with event: NSEvent) { dragPoint = nil }
    @objc private func cancelSelection() { onCancel?() }
}
