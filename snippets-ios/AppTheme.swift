import UIKit

enum AppTheme {
    static let tint = UIColor.systemIndigo
    static let pin = UIColor.systemYellow
    static let enabled = UIColor.systemGreen
    static let warning = UIColor.systemOrange
    static let disabled = UIColor.secondaryLabel
    static let selectedRow = UIColor { traits in
        if traits.accessibilityContrast == .high {
            return UIColor.systemIndigo.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.34 : 0.26)
        }
        return traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.14)
            : UIColor.systemIndigo.withAlphaComponent(0.13)
    }
    static let selectedRowBorder = UIColor { traits in
        if traits.accessibilityContrast == .high { return UIColor.systemIndigo }
        return UIColor.separator.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.20 : 0.18)
    }
    static let hoveredRow = UIColor { traits in
        (traits.userInterfaceStyle == .dark ? UIColor.white : UIColor.black).withAlphaComponent(0.055)
    }
    static let editorSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
    }
    static let previewSurface = UIColor.secondaryLabel.withAlphaComponent(0.075)

    private static let tagBaseColors: [UIColor] = [
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
        let base = tagBaseColors[Int(fnv1aHash(key) % UInt64(tagBaseColors.count))]
        return mutedTagColor(base)
    }

    static func tagFillColor(for tag: String, selected: Bool = false) -> UIColor {
        UIColor { traits in
            tagColor(for: tag)
                .resolvedColor(with: traits)
                .withAlphaComponent(selected ? 0.92 : 0.13)
        }
    }

    static func contrastingTextColor(on background: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = background.resolvedColor(with: traits)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return .label
            }
            let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
            return luminance > 0.55 ? UIColor.black.withAlphaComponent(0.85) : .white
        }
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

    private static func mutedTagColor(_ base: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = base.resolvedColor(with: traits)
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            guard resolved.getHue(
                &hue,
                saturation: &saturation,
                brightness: &brightness,
                alpha: &alpha
            ) else {
                return resolved
            }
            if traits.userInterfaceStyle == .dark {
                return UIColor(
                    hue: hue,
                    saturation: saturation * 0.5,
                    brightness: min(brightness, 0.92),
                    alpha: alpha
                )
            }
            return UIColor(
                hue: hue,
                saturation: saturation * 0.65,
                brightness: brightness * 0.72,
                alpha: alpha
            )
        }
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
