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

    #if DEBUG
    /// Renders every surface and control the way a machine without Liquid Glass
    /// would, so the pre-26 fallback can be looked at without a pre-26 machine.
    ///
    /// Turn it on with the launch argument `-ForceLegacyAppearance YES` — the
    /// argument domain, because a `defaults write` from a shell never reaches a
    /// running app — or flip it from the debugger before the panel is built.
    ///
    /// It is not a pixel-accurate simulation: an `NSVisualEffectView` on macOS 26
    /// still uses macOS 26's recipe for its material, so what this shows is the
    /// arrangement, the geometry and the colour choices, not the exact backdrop a
    /// macOS 15 machine would blur.
    static var forcesLegacyAppearance = UserDefaults.standard.bool(forKey: "ForceLegacyAppearance")
    #else
    static var forcesLegacyAppearance: Bool { false }
    #endif

    /// The floating panel keeps one shape on both paths. The pre-26 difference is a
    /// material, not a design language, and a 320pt completion list is nowhere near
    /// the ~200pt, 22pt-per-row menu whose small radius is the native pre-26 idiom.
    /// The in-window action panel already ships this radius on every OS version, so
    /// matching it keeps the app speaking one shape rather than two.
    static var effectivePanelCornerRadius: CGFloat {
        Metrics.panelCornerRadius
    }

    static var rowHighlightCornerRadius: CGFloat {
        Metrics.rowCornerRadius
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
        // No floor on either inset: each drawing site sizes its own gutter — the list
        // 5/1, the search overlay 8/3, the suggestion panel one concentric with its
        // surface corner — and a floor here could only discard it.
        bounds.insetBy(dx: horizontalInset, dy: verticalInset)
    }

    static func rowHighlightFillColor(isSelected: Bool, isDark: Bool) -> NSColor {
        if prefersHighContrastHighlight {
            // Still translucent on purpose: the labels keep `labelColor`, so an
            // opaque accent fill would leave the selected row unreadable.
            return isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.34 : 0.24)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        }

        if isSelected {
            // Neutral in dark mode rather than an accent wash. The tables run
            // `selectionHighlightStyle = .none` and force `isEmphasized` off, so what
            // this app implements is AppKit's *unemphasized* selection, and that one
            // is a grey. The hairline below carries most of the row's identity
            // anyway: against the row background it is worth ΔL* 16.7 where this fill
            // is worth 10.9.
            return isDark
                ? NSColor.white.withAlphaComponent(0.13)
                : NSColor.controlAccentColor.withAlphaComponent(0.11)
        }

        return isDark
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.black.withAlphaComponent(0.035)
    }

    /// Never nil. The pill's edge does more for the selected state than its fill —
    /// against the row background the edge is worth ΔL* 16.7 to the fill's 10.9 — and
    /// it is the one cue hover never gets, so a selected row stays legible by its
    /// outline even where the fill washes out against a lighter backdrop.
    static func rowHighlightStrokeColor(isDark: Bool) -> NSColor {
        if prefersHighContrastHighlight {
            return .controlAccentColor
        }

        return NSColor.separatorColor.withAlphaComponent(isDark ? 0.20 : 0.16)
    }

    static func makeTransientSurface(
        containing content: NSView,
        cornerRadius: CGFloat = Metrics.panelCornerRadius,
        fallbackMaterial: NSVisualEffectView.Material = .popover,
        tintColor: NSColor? = NSColor.controlAccentColor.withAlphaComponent(0.18),
        clearGlass: Bool = false
    ) -> NSView {
        if #available(macOS 26.0, *), !forcesLegacyAppearance {
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
    ///   has nothing to sample inside a transparent, borderless panel, and it draws
    ///   its own rim, because unlike glass it has no edge of its own and a borderless
    ///   panel over another application never gets the window server's menu rim;
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

        if #available(macOS 26.0, *), !forcesLegacyAppearance {
            let glassView = NSGlassEffectView()
            glassView.translatesAutoresizingMaskIntoConstraints = false
            glassView.cornerRadius = cornerRadius
            glassView.style = .regular
            glassView.contentView = clipper
            pin(clipper, to: glassView)
            return glassView
        }

        let effectView = FloatingPanelSurfaceView()
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
        if #available(macOS 26.0, *), !forcesLegacyAppearance {
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
        if #available(macOS 26.0, *), !forcesLegacyAppearance {
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

        if #available(macOS 26.0, *), !forcesLegacyAppearance {
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

        if #available(macOS 26.0, *), !forcesLegacyAppearance {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
    }

    static func configurePrimaryToolbarItem(_ item: NSToolbarItem) {
        item.isBordered = true
        item.visibilityPriority = .high

        if #available(macOS 26.0, *), !forcesLegacyAppearance {
            item.style = .prominent
            item.backgroundTintColor = .controlAccentColor
        }
    }

    static func configureSecondaryToolbarItem(_ item: NSToolbarItem) {
        item.isBordered = true
        item.visibilityPriority = .standard

        if #available(macOS 26.0, *), !forcesLegacyAppearance {
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

/// Layer-backed row highlight shared by the library, search overlay, and floating
/// suggestion panel.
///
/// Drawing the selected edge with `NSBezierPath.stroke()` leaves the one-point
/// stroke centred on the path. On the pre-Liquid-Glass AppKit renderer its outer
/// half is rasterized independently from the translucent fill, which makes a
/// small rounded corner look visibly stepped. `CALayer` draws its border inside
/// the bounds and gives both the fill and edge one continuous-corner mask.
final class RowHighlightView: NSView {
    private(set) var isSelected = false
    private(set) var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = LiquidGlassDesign.rowHighlightCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    func update(isSelected: Bool, isHovering: Bool) {
        guard self.isSelected != isSelected || self.isHovering != isHovering else { return }
        self.isSelected = isSelected
        self.isHovering = isHovering
        applyStyle()
    }

    private func applyStyle() {
        let isVisible = isSelected || isHovering
        isHidden = !isVisible
        guard isVisible else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fillColor = LiquidGlassDesign.rowHighlightFillColor(
            isSelected: isSelected,
            isDark: isDark
        )
        layer?.backgroundColor = resolvedCGColor(fillColor)

        if isSelected {
            let strokeColor = LiquidGlassDesign.rowHighlightStrokeColor(isDark: isDark)
            layer?.borderWidth = LiquidGlassDesign.Metrics.hairlineWidth
            layer?.borderColor = resolvedCGColor(strokeColor)
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }

    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }
}

/// The pre-26 surface of the floating suggestion panel.
///
/// Exists only to own the rim. Over a light host application an `NSVisualEffectView`
/// simply stops at its bounds with nothing marking where the panel ends, and unlike
/// `NSGlassEffectView` it draws no edge for us.
///
/// The rim goes on the layer rather than into `draw(_:)` so it follows the same
/// continuous corner as the mask — `NSBezierPath(roundedRect:xRadius:yRadius:)` is a
/// circular corner and would diverge from it. That in turn means the colour has to be
/// resolved by hand: a dynamic system colour turned into a `CGColor` outside a drawing
/// pass yields the vibrancy *source* value, and inside a visual effect view that is
/// inverted — near-black in dark mode, near-white in light.
private final class FloatingPanelSurfaceView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRim()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRim()
    }

    private func updateRim() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderWidth = LiquidGlassDesign.Metrics.hairlineWidth
        layer?.borderColor = NSColor(white: isDark ? 1 : 0, alpha: 0.18).cgColor
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
