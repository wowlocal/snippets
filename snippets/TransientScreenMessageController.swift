import AppKit

struct TransientScreenMessage {
    let title: String
    let detail: String?
    let accessibilityText: String
    let keepsTitleOnSingleLine: Bool

    init(
        title: String,
        detail: String? = nil,
        accessibilityText: String? = nil,
        keepsTitleOnSingleLine: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.accessibilityText = accessibilityText ?? [title, detail]
            .compactMap { $0 }
            .joined(separator: ", ")
        self.keepsTitleOnSingleLine = keepsTitleOnSingleLine
    }
}

enum ClipboardCopyFeedback {
    static let secureSnippetBlocked =
        "Copy blocked. Secure snippets can\u{2019}t be copied. The clipboard was not changed."
    static let failed = "Couldn\u{2019}t copy the snippet to the clipboard."

    static func copied(_ snippet: Snippet) -> TransientScreenMessage {
        let name = boundedMetadata(snippet.name, maximumCharacters: 80)
        let keyword = boundedMetadata(snippet.normalizedKeyword, maximumCharacters: 48)
        let trigger = keyword.isEmpty ? "" : "\\\(keyword)"
        let title = name.isEmpty ? "Copied snippet" : "Copied \u{201C}\(name)\u{201D}"
        let detail = trigger.isEmpty ? nil : trigger
        let accessibilityText = detail.map { "\(title). Keyword \($0)" } ?? title

        return TransientScreenMessage(
            title: title,
            detail: detail,
            accessibilityText: accessibilityText,
            keepsTitleOnSingleLine: true
        )
    }

    /// Synced metadata can predate today's single-line editor constraints. Keep a
    /// malformed or unusually long value from turning a confirmation into a large
    /// sheet while preserving enough of it to identify the selected row.
    private static func boundedMetadata(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "\u{2026}"
    }
}

enum SecurePasteFeedback {
    static let attemptedAmbiguous =
        "Secure Paste may have inserted the snippet. Check the original field before trying again."

    static let blockedUnsafeControlCharacters = TransientScreenMessage(
        title: "Secure Paste blocked this snippet.",
        detail: "Line breaks and control characters are blocked\nbecause they can trigger terminal actions."
    )
}

/// Covers the HUD surface so its first click is consumed locally and dismisses it.
/// Returning this view from `hitTest` keeps labels and glass decoration from swallowing
/// the click. The containing panel remains nonactivating, so the original app keeps focus.
@MainActor
private final class TransientScreenMessageDismissView: NSView {
    var onDismiss: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

/// A short-lived, non-activating HUD for actions that begin outside the main app
/// window. It never takes key status; clicking the HUD consumes only that click and
/// dismisses the message while the application underneath keeps focus.
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

    private static let horizontalPadding: CGFloat = 24
    private static let verticalPadding: CGFloat = 10
    private static let detailSpacing: CGFloat = 3
    private static let maximumTextWidth: CGFloat = 520
    private static let maximumSingleLineTextWidth: CGFloat = 680
    private static let textMeasurementAllowance: CGFloat = 8
    private static let minimumPanelWidth: CGFloat = 180
    private static let screenMargin: CGFloat = 20
    private static let bottomOffset: CGFloat = 28
    private static let fadeDuration: TimeInterval = 0.25

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
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
        panel.ignoresMouseEvents = false
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

        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.isSelectable = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageStack = NSStackView(views: [label, detailLabel])
        messageStack.orientation = .vertical
        messageStack.alignment = .centerX
        messageStack.distribution = .gravityAreas
        messageStack.spacing = Self.detailSpacing
        messageStack.detachesHiddenViews = true
        messageStack.translatesAutoresizingMaskIntoConstraints = false

        let messageContent = NSView()
        messageContent.translatesAutoresizingMaskIntoConstraints = false
        messageContent.addSubview(messageStack)

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

        let dismissView = TransientScreenMessageDismissView()
        dismissView.translatesAutoresizingMaskIntoConstraints = false
        dismissView.setAccessibilityElement(false)
        dismissView.onDismiss = { [weak self] in
            self?.dismiss()
        }
        panelContent.addSubview(dismissView)

        NSLayoutConstraint.activate([
            messageStack.leadingAnchor.constraint(
                equalTo: messageContent.leadingAnchor,
                constant: Self.horizontalPadding
            ),
            messageStack.trailingAnchor.constraint(
                equalTo: messageContent.trailingAnchor,
                constant: -Self.horizontalPadding
            ),
            messageStack.topAnchor.constraint(
                equalTo: messageContent.topAnchor,
                constant: Self.verticalPadding
            ),
            messageStack.bottomAnchor.constraint(
                equalTo: messageContent.bottomAnchor,
                constant: -Self.verticalPadding
            ),
            label.widthAnchor.constraint(lessThanOrEqualTo: messageStack.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: messageStack.widthAnchor),
            surface.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor),
            surface.topAnchor.constraint(equalTo: panelContent.topAnchor),
            surface.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor),
            dismissView.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor),
            dismissView.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor),
            dismissView.topAnchor.constraint(equalTo: panelContent.topAnchor),
            dismissView.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor),
        ])
    }

    func show(_ message: String, kind: Kind) {
        show(TransientScreenMessage(title: message), kind: kind)
    }

    func show(_ message: TransientScreenMessage, kind: Kind) {
        presentationGeneration += 1
        let generation = presentationGeneration
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        // The picker was the most recent key window, so `main` normally resolves to
        // the display where it appeared. The pointer is the fallback for hosts that
        // provide no focused element and therefore no screen-space anchor.
        guard let screen = NSScreen.main ?? screenContainingMouse() ?? NSScreen.screens.first,
              let font = label.font,
              let detailFont = detailLabel.font else { return }

        label.stringValue = message.title
        label.setAccessibilityLabel(message.title)
        label.lineBreakMode = message.keepsTitleOnSingleLine ? .byTruncatingTail : .byWordWrapping
        label.maximumNumberOfLines = message.keepsTitleOnSingleLine ? 1 : 0
        detailLabel.stringValue = message.detail ?? ""
        detailLabel.isHidden = message.detail == nil
        detailLabel.setAccessibilityLabel(message.detail)

        let availablePanelWidth = max(
            Self.minimumPanelWidth,
            screen.visibleFrame.width - (Self.screenMargin * 2)
        )
        let maximumTextWidth = max(
            80,
            min(
                message.keepsTitleOnSingleLine
                    ? Self.maximumSingleLineTextWidth
                    : Self.maximumTextWidth,
                availablePanelWidth - (Self.horizontalPadding * 2)
            )
        )
        let idealTitleBounds: NSRect
        if message.keepsTitleOnSingleLine {
            idealTitleBounds = NSRect(
                origin: .zero,
                size: (message.title as NSString).size(withAttributes: [.font: font])
            )
        } else {
            idealTitleBounds = (message.title as NSString).boundingRect(
                with: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
        }
        let idealDetailBounds = message.detail.map {
            ($0 as NSString).boundingRect(
                with: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: detailFont]
            )
        } ?? .zero
        let panelWidth = min(
            availablePanelWidth,
            max(
                Self.minimumPanelWidth,
                ceil(max(idealTitleBounds.width, idealDetailBounds.width))
                    + (Self.horizontalPadding * 2) + Self.textMeasurementAllowance
            )
        )
        // Measure wrapping messages again at their actual width so a second line gets
        // real height. Copy confirmations stay on one line and truncate only when their
        // full title cannot fit within the screen-safe maximum width.
        let actualTextWidth = max(1, panelWidth - (Self.horizontalPadding * 2))
        label.preferredMaxLayoutWidth = actualTextWidth
        let laidOutTitleBounds: NSRect
        if message.keepsTitleOnSingleLine {
            laidOutTitleBounds = idealTitleBounds
        } else {
            laidOutTitleBounds = (message.title as NSString).boundingRect(
                with: NSSize(width: actualTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
        }
        detailLabel.preferredMaxLayoutWidth = actualTextWidth
        let detailHeight = message.detail == nil ? 0 : ceil(idealDetailBounds.height)
        let detailSpacing = message.detail == nil ? 0 : Self.detailSpacing
        let panelHeight = max(
            40,
            ceil(laidOutTitleBounds.height) + detailSpacing + detailHeight
                + (Self.verticalPadding * 2)
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
                .announcement: message.accessibilityText,
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
