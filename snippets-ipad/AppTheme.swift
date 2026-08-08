import UIKit

enum AppTheme {
    static let tint = UIColor.systemIndigo
    static let pin = UIColor.systemYellow
    static let enabled = UIColor.systemGreen
    static let warning = UIColor.systemOrange
    static let disabled = UIColor.secondaryLabel
    static let selectedRow = UIColor { traits in
        UIColor.systemIndigo.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.26 : 0.14)
    }
    static let hoveredRow = UIColor.secondaryLabel.withAlphaComponent(0.07)
    static let editorSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
    }
    static let previewSurface = UIColor.secondaryLabel.withAlphaComponent(0.075)

    private static let tagColors: [UIColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemMint,
        .systemTeal,
        .systemCyan,
        .systemBlue,
        .systemIndigo,
        .systemPurple,
        .systemPink,
        .systemBrown,
    ]

    static func tagColor(for tag: String) -> UIColor {
        let key = SnippetTagging.filterKey(for: tag)
        return tagColors[Int(fnv1aHash(key) % UInt64(tagColors.count))]
    }

    static func tagFillColor(for tag: String, selected: Bool = false) -> UIColor {
        tagColor(for: tag).withAlphaComponent(selected ? 0.9 : 0.13)
    }

    static func scaledFont(
        size: CGFloat,
        weight: UIFont.Weight = .regular,
        textStyle: UIFont.TextStyle = .body,
        monospaced: Bool = false
    ) -> UIFont {
        let base = monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }

    static func configureNavigationBar(_ navigationBar: UINavigationBar) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [
            .font: scaledFont(size: 15, weight: .semibold, textStyle: .headline),
        ]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
    }

    static func configureSurface(
        _ view: UIView,
        cornerRadius: CGFloat = 10,
        backgroundColor: UIColor = editorSurface
    ) {
        view.backgroundColor = backgroundColor
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1 / max(view.traitCollection.displayScale, 1)
        view.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        view.clipsToBounds = true
    }

    static func glassView(tintColor: UIColor? = nil) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = tintColor ?? UIColor.clear
        return UIVisualEffectView(effect: effect)
    }

    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
