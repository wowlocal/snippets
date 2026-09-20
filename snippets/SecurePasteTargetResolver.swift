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

/// Runs the shipping container handoff with injectable observations/sleeps. Only
/// transient focus/AX availability may settle; structural changes abort the attempt.
/// No plaintext-bearing operation belongs in this loop.
@MainActor
enum SecurePasteContainerHandoff {
    struct Report {
        let validation: SecurePasteTargetResolver.Validation
        let firstTransient: SecurePasteTargetResolver.Validation?
        let attempts: Int
    }

    static func run(
        sleep: (Duration) async -> Void,
        observe: () -> SecurePasteTargetResolver.Validation,
        restoreFocus: () -> Void
    ) async -> Report {
        var consecutive = 0
        var firstTransient: SecurePasteTargetResolver.Validation?
        var last: SecurePasteTargetResolver.Validation = .focusUnavailable
        let delays: [Duration] = [.milliseconds(80), .milliseconds(100), .milliseconds(160),
                                  .milliseconds(300), .milliseconds(500), .milliseconds(500)]
        for (index, delay) in delays.enumerated() {
            await sleep(delay)
            guard !Task.isCancelled else {
                return Report(validation: .cancelled, firstTransient: firstTransient, attempts: index + 1)
            }
            last = observe()
            if last == .valid || last == .fieldFocusPending {
                if last == .fieldFocusPending { firstTransient = firstTransient ?? last }
                restoreFocus()
                last = observe()
            }
            guard last.canRetryHandoff else {
                return Report(validation: last, firstTransient: firstTransient, attempts: index + 1)
            }
            if last == .valid {
                consecutive += 1
                if consecutive == 2 {
                    return Report(validation: .valid, firstTransient: firstTransient, attempts: index + 1)
                }
            } else {
                consecutive = 0
                firstTransient = firstTransient ?? last
            }
        }
        // One last valid sample is insufficient: stable handoff requires two.
        return Report(validation: last == .valid ? .focusUnavailable : last,
                      firstTransient: firstTransient, attempts: delays.count)
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
        panel?.orderOut(nil)
        panel = nil
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    func show(frame: NSRect, targetPID: pid_t,
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
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        let view = FieldSelectionView(frame: NSRect(origin: .zero, size: frame.size))
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
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: "Click the destination field for Secure Paste. Command backslash cancels.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

@MainActor
private final class FieldSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FieldSelectionView: NSView {
    var onClick: ((CGPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(wrappingLabelWithString:
            "Click the destination field\n⌘\\ cancels Secure Paste")
        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .black.withAlphaComponent(0.85)
        label.drawsBackground = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        setAccessibilityLabel("Select the destination field for Secure Paste")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, let primaryScreen = NSScreen.screens.first else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        // Instruction pixels obscure the host; clicking them cannot establish
        // user intent for a control hidden underneath the banner.
        guard !subviews.contains(where: { $0.frame.contains(localPoint) }) else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        onClick?(CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y))
    }
}
