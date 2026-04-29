import AppKit
import QuartzCore

enum LiquidGlassDesign {
    enum Metrics {
        static let controlCornerRadius: CGFloat = 10
        static let panelCornerRadius: CGFloat = 18
        static let contentCornerRadius: CGFloat = 12
        static let rowCornerRadius: CGFloat = 12
        static let hairlineWidth: CGFloat = 1
    }

    static var usesNativeGlass: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    static var primaryTintColor: NSColor? {
        ThemeManager.isPaleTheme ? nil : .controlAccentColor
    }

    static var subtleTintColor: NSColor? {
        ThemeManager.isPaleTheme
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.14)
            : NSColor.controlAccentColor.withAlphaComponent(0.18)
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
        maskLayer.frame = bounds

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
