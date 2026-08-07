import AppKit
import QuartzCore

enum LiquidGlassDesign {
    enum Metrics {
        static let controlCornerRadius: CGFloat = 10
        static let panelCornerRadius: CGFloat = 18
        static let contentCornerRadius: CGFloat = 12
        static let rowCornerRadius: CGFloat = 12
        static let hairlineWidth: CGFloat = 1
        /// Inset that makes a `rowCornerRadius` pill concentric inside a
        /// `panelCornerRadius` surface: both corner arcs end up sharing a centre,
        /// so the gap around the pill is uniform on every side.
        static let concentricRowInset: CGFloat = panelCornerRadius - rowCornerRadius
    }

    static var usesNativeGlass: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// Glass draws a wider squircle than the pre-26 material did; keeping the old
    /// radius on the fallback path avoids an unrelated visual change there.
    static var effectivePanelCornerRadius: CGFloat {
        usesNativeGlass ? Metrics.panelCornerRadius : 8
    }

    static var primaryTintColor: NSColor? {
        ThemeManager.isPaleTheme ? nil : .controlAccentColor
    }

    static var subtleTintColor: NSColor? {
        ThemeManager.isPaleTheme
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.14)
            : NSColor.controlAccentColor.withAlphaComponent(0.18)
    }

    static var rowHighlightCornerRadius: CGFloat {
        usesNativeGlass ? Metrics.rowCornerRadius : 8
    }

    /// Increase Contrast forcibly turns off translucency on macOS 26, flattening the
    /// glass — and the few-percent wash below then reads as almost nothing. The
    /// suggestion panel has no other selection cue, and picking the wrong row types
    /// the wrong snippet into someone else's document, so strengthen the pill.
    static var prefersHighContrastHighlight: Bool {
        let workspace = NSWorkspace.shared
        return workspace.accessibilityDisplayShouldIncreaseContrast
            || workspace.accessibilityDisplayShouldReduceTransparency
    }

    static func rowHighlightRect(
        in bounds: NSRect,
        horizontalInset: CGFloat,
        verticalInset: CGFloat
    ) -> NSRect {
        if usesNativeGlass {
            return bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        }

        return bounds.insetBy(
            dx: max(horizontalInset, 10),
            dy: max(verticalInset, 7)
        )
    }

    static func rowHighlightFillColor(isSelected: Bool, isDark: Bool) -> NSColor {
        if prefersHighContrastHighlight {
            // Still translucent on purpose: the labels keep `labelColor`, so an
            // opaque accent fill would leave the selected row unreadable.
            return isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.34 : 0.24)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        }

        if usesNativeGlass {
            if isSelected {
                return isDark
                    ? NSColor.white.withAlphaComponent(0.13)
                    : NSColor.controlAccentColor.withAlphaComponent(0.11)
            }

            return isDark
                ? NSColor.white.withAlphaComponent(0.055)
                : NSColor.black.withAlphaComponent(0.035)
        }

        if isSelected {
            return NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.20 : 0.12)
        }

        return isDark
            ? NSColor.white.withAlphaComponent(0.035)
            : NSColor.black.withAlphaComponent(0.025)
    }

    static func rowHighlightStrokeColor(isDark: Bool) -> NSColor? {
        if prefersHighContrastHighlight {
            return .controlAccentColor
        }

        guard usesNativeGlass else { return nil }
        return NSColor.separatorColor.withAlphaComponent(isDark ? 0.20 : 0.16)
    }

    static func makeTransientSurface(
        containing content: NSView,
        cornerRadius: CGFloat = Metrics.panelCornerRadius,
        fallbackMaterial: NSVisualEffectView.Material = .popover,
        tintColor: NSColor? = subtleTintColor,
        clearGlass: Bool = false
    ) -> NSView {
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.translatesAutoresizingMaskIntoConstraints = false
            glassView.cornerRadius = cornerRadius
            glassView.tintColor = tintColor
            glassView.style = clearGlass ? .clear : .regular
            glassView.contentView = content
            pin(content, to: glassView)
            return glassView
        }

        let effectView = NSVisualEffectView()
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = fallbackMaterial
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        configureRoundedLayer(
            effectView,
            cornerRadius: cornerRadius,
            borderColor: NSColor.separatorColor.withAlphaComponent(0.14),
            backgroundColor: nil
        )
        effectView.addSubview(content)
        pin(content, to: effectView)
        return effectView
    }

    /// Surface for a window-filling, free-floating panel that renders over *other*
    /// applications — the suggestion popup.
    ///
    /// Deliberately separate from `makeTransientSurface`, which is for surfaces that
    /// live inside one of our own windows:
    ///
    /// * the pre-26 fallback blends `.behindWindow`, because a `.withinWindow` blur
    ///   has nothing to sample inside a transparent, borderless panel;
    /// * the content is wrapped in a clipping container, because `NSGlassEffectView`
    ///   masks its own material but *not* its `contentView` — without this the
    ///   square corners of the scroll view punch straight through the rounded glass.
    ///
    /// The returned view is Auto Layout driven and has no size of its own: the
    /// caller must pin it to the panel's content view.
    static func makeFloatingPanelSurface(
        containing content: NSView,
        cornerRadius: CGFloat = effectivePanelCornerRadius,
        fallbackMaterial: NSVisualEffectView.Material = .menu
    ) -> NSView {
        let clipper = NSView()
        clipper.translatesAutoresizingMaskIntoConstraints = false
        clipper.wantsLayer = true
        clipper.layer?.cornerRadius = cornerRadius
        // Continuous, not circular: the glass shape is a squircle, and a circular
        // mask visibly diverges from it around the 45° point.
        clipper.layer?.cornerCurve = .continuous
        clipper.layer?.masksToBounds = true
        pin(content, to: clipper)

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.translatesAutoresizingMaskIntoConstraints = false
            glassView.cornerRadius = cornerRadius
            glassView.style = .regular
            glassView.contentView = clipper
            pin(clipper, to: glassView)
            return glassView
        }

        let effectView = NSVisualEffectView()
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = fallbackMaterial
        // The panel window is transparent and floats over other apps, so the
        // backdrop this has to blur is not inside our own window.
        effectView.blendingMode = .behindWindow
        // Our app is never frontmost while the panel is up.
        effectView.state = .active
        configureRoundedLayer(effectView, cornerRadius: cornerRadius, borderColor: nil)
        effectView.layer?.cornerCurve = .continuous
        effectView.addSubview(clipper)
        pin(clipper, to: effectView)
        return effectView
    }

    static func makeGlassContainer(containing content: NSView, spacing: CGFloat = 8) -> NSView {
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.spacing = spacing
            container.contentView = content
            pin(content, to: container)
            return container
        }

        return content
    }

    static func makeSidebarSurface(containing content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            return content
        }

        let effectView = NSVisualEffectView()
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.addSubview(content)
        pin(content, to: effectView)
        return effectView
    }

    static func makeScrollFadeContainer(containing scrollView: NSScrollView) -> NSView {
        let container = ScrollFadeMaskContainerView(scrollView: scrollView)
        container.addSubview(scrollView)
        pin(scrollView, to: container)
        return container
    }

    static func configureRoundedLayer(
        _ view: NSView,
        cornerRadius: CGFloat,
        borderColor: NSColor? = NSColor.separatorColor.withAlphaComponent(0.18),
        backgroundColor: NSColor? = nil
    ) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.borderWidth = borderColor == nil ? 0 : Metrics.hairlineWidth
        view.layer?.borderColor = borderColor?.cgColor
        view.layer?.backgroundColor = backgroundColor?.cgColor
        view.layer?.masksToBounds = true
    }

    static func configureEditorSurface(_ view: NSView, backgroundColor: NSColor) {
        configureRoundedLayer(
            view,
            cornerRadius: Metrics.contentCornerRadius,
            borderColor: NSColor.separatorColor.withAlphaComponent(0.20),
            backgroundColor: backgroundColor
        )
    }

    static func configureToolbarIconButton(_ button: NSButton, bordered: Bool = true) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.controlSize = .regular
        button.isBordered = bordered
        button.imagePosition = .imageOnly
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
    }

    static func configureActionButton(_ button: NSButton, symbolName: String? = nil) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.controlSize = .regular
        if let symbolName {
            button.image = symbol(symbolName, pointSize: 13, weight: .regular)
            button.imagePosition = .imageLeading
        }

        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
    }

    static func configurePrimaryToolbarItem(_ item: NSToolbarItem) {
        item.isBordered = true
        item.visibilityPriority = .high

        if #available(macOS 26.0, *) {
            item.style = .prominent
            item.backgroundTintColor = primaryTintColor
        }
    }

    static func configureSecondaryToolbarItem(_ item: NSToolbarItem) {
        item.isBordered = true
        item.visibilityPriority = .standard

        if #available(macOS 26.0, *) {
            item.style = .plain
        }
    }

    static func symbol(_ name: String, pointSize: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }

    static func menuItem(title: String, symbolName: String, action: Selector, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = symbol(symbolName, pointSize: 13, weight: .regular)
        return item
    }

    static func applyMenuSymbol(_ symbolName: String, to item: NSMenuItem) {
        item.image = symbol(symbolName, pointSize: 13, weight: .regular)
    }

    private static func pin(_ content: NSView, to container: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        if content.superview == nil {
            container.addSubview(content)
        }

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

private final class ScrollFadeMaskContainerView: NSView {
    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private let maskLayer = CAGradientLayer()
    private let topFadeHeight: CGFloat = 26
    private let bottomFadeHeight: CGFloat = 20

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        maskLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "colors": NSNull(),
            "locations": NSNull()
        ]
        layer?.mask = maskLayer
        observeScrollView(scrollView)
        updateMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMask()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMask()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateMask()
    }

    override func layout() {
        super.layout()
        updateMask()
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    private func observeScrollView(_ scrollView: NSScrollView) {
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateMask()
        }
    }

    private func updateMask() {
        guard let scrollView, let documentView = scrollView.documentView else {
            applyMask(topIntensity: 0, bottomIntensity: 0)
            return
        }

        let visibleBounds = scrollView.contentView.bounds
        let documentBounds = documentView.bounds
        guard documentBounds.height > visibleBounds.height + 1 else {
            applyMask(topIntensity: 0, bottomIntensity: 0)
            return
        }

        let topHiddenDistance = documentView.isFlipped
            ? visibleBounds.minY - documentBounds.minY
            : documentBounds.maxY - visibleBounds.maxY
        let bottomHiddenDistance = documentView.isFlipped
            ? documentBounds.maxY - visibleBounds.maxY
            : visibleBounds.minY - documentBounds.minY

        applyMask(
            topIntensity: min(max(topHiddenDistance / topFadeHeight, 0), 1),
            bottomIntensity: min(max(bottomHiddenDistance / bottomFadeHeight, 0), 1)
        )
    }

    private func applyMask(topIntensity: CGFloat, bottomIntensity: CGFloat) {
        let height = max(bounds.height, 1)
        let topFade = min(topFadeHeight / height, 0.45)
        let bottomFade = min(bottomFadeHeight / height, 0.45)
        let opaque = NSColor.black.withAlphaComponent(1).cgColor
        let topEdge = NSColor.black.withAlphaComponent(1 - topIntensity).cgColor
        let bottomEdge = NSColor.black.withAlphaComponent(1 - bottomIntensity).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.startPoint = CGPoint(x: 0.5, y: 0)
        maskLayer.endPoint = CGPoint(x: 0.5, y: 1)
        maskLayer.colors = [bottomEdge, opaque, opaque, topEdge]
        maskLayer.locations = [
            0,
            NSNumber(value: Double(bottomFade)),
            NSNumber(value: Double(max(bottomFade, 1 - topFade))),
            1
        ]
        CATransaction.commit()
    }
}
