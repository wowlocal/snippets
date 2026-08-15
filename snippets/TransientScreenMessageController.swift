import AppKit

enum ClipboardCopyFeedback {
    static let copied = "Copied to the clipboard"
    static let secureSnippetBlocked =
        "Copy blocked. Secure snippets can\u{2019}t be copied. The clipboard was not changed."
    static let failed = "Couldn\u{2019}t copy the snippet to the clipboard."
}

/// A short-lived, non-activating HUD for actions that begin outside the main app
/// window. It never takes key status or intercepts a click, so the application the
/// user was working in keeps its focus while the result is shown.
@MainActor
final class TransientScreenMessageController {
    enum Kind {
        case confirmation
        case failure

        var displayDuration: TimeInterval {
            switch self {
            case .confirmation: 3
            case .failure: 6
            }
        }

        var accessibilityPriority: NSAccessibilityPriorityLevel {
            switch self {
            case .confirmation: .medium
            case .failure: .high
            }
        }
    }

    private static let horizontalPadding: CGFloat = 18
    private static let verticalPadding: CGFloat = 10
    private static let maximumTextWidth: CGFloat = 520
    private static let minimumPanelWidth: CGFloat = 180
    private static let screenMargin: CGFloat = 20
    private static let bottomOffset: CGFloat = 28
    private static let fadeDuration: TimeInterval = 0.25

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var dismissWorkItem: DispatchWorkItem?
    private var presentationGeneration = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let messageContent = NSView()
        messageContent.translatesAutoresizingMaskIntoConstraints = false
        messageContent.addSubview(label)

        let surface = LiquidGlassDesign.makeFloatingPanelSurface(
            containing: messageContent,
            cornerRadius: LiquidGlassDesign.Metrics.controlCornerRadius,
            fallbackMaterial: .popover
        )

        let panelContent = panel.contentView!
        panelContent.wantsLayer = true
        panelContent.layer?.cornerRadius = LiquidGlassDesign.Metrics.controlCornerRadius
        panelContent.layer?.cornerCurve = .continuous
        panelContent.layer?.masksToBounds = true
        panelContent.addSubview(surface)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: messageContent.leadingAnchor,
                constant: Self.horizontalPadding
            ),
            label.trailingAnchor.constraint(
                equalTo: messageContent.trailingAnchor,
                constant: -Self.horizontalPadding
            ),
            label.topAnchor.constraint(
                equalTo: messageContent.topAnchor,
                constant: Self.verticalPadding
            ),
            label.bottomAnchor.constraint(
                equalTo: messageContent.bottomAnchor,
                constant: -Self.verticalPadding
            ),
            surface.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor),
            surface.topAnchor.constraint(equalTo: panelContent.topAnchor),
            surface.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor),
        ])
    }

    func show(_ message: String, kind: Kind) {
        presentationGeneration += 1
        let generation = presentationGeneration
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        // The picker was the most recent key window, so `main` normally resolves to
        // the display where it appeared. The pointer is the fallback for hosts that
        // provide no focused element and therefore no screen-space anchor.
        guard let screen = NSScreen.main ?? screenContainingMouse() ?? NSScreen.screens.first,
              let font = label.font else { return }

        label.stringValue = message
        label.setAccessibilityLabel(message)

        let availablePanelWidth = max(
            Self.minimumPanelWidth,
            screen.visibleFrame.width - (Self.screenMargin * 2)
        )
        let maximumTextWidth = max(
            80,
            min(
                Self.maximumTextWidth,
                availablePanelWidth - (Self.horizontalPadding * 2)
            )
        )
        label.preferredMaxLayoutWidth = maximumTextWidth

        let measuredText = (message as NSString).boundingRect(
            with: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let panelWidth = min(
            availablePanelWidth,
            max(
                Self.minimumPanelWidth,
                ceil(measuredText.width) + (Self.horizontalPadding * 2)
            )
        )
        let panelHeight = max(
            40,
            ceil(measuredText.height) + (Self.verticalPadding * 2)
        )
        panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - (panelWidth / 2),
            y: visibleFrame.minY + Self.bottomOffset
        )
        panel.setFrameOrigin(origin)
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 0
        }

        // `orderFrontRegardless()` can temporarily unhide the application. Preserve
        // Cmd-H state and leave only this non-hideable HUD visible for its short life.
        let applicationWasHidden = NSApp.isHidden
        panel.orderFrontRegardless()
        if applicationWasHidden {
            NSApp.hide(nil)
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        NSAccessibility.post(
            element: label,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: kind.accessibilityPriority.rawValue,
            ]
        )

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeDuration
                    self.panel.animator().alphaValue = 0
                }
                guard self.presentationGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.dismissWorkItem = nil
            }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + kind.displayDuration,
            execute: workItem
        )
    }

    func dismiss() {
        presentationGeneration += 1
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 0
        }
        panel.orderOut(nil)
    }

    private func screenContainingMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first {
            $0.frame.insetBy(dx: -1, dy: -1).contains(point)
        }
    }
}
