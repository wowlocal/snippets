import UIKit

enum AppTheme {
    static let defaultsKey = "snippetsPaleThemeEnabled"
    static let changed = Notification.Name("com.khm.snippets.iPadThemeChanged")

    static var isPale: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var tint: UIColor { isPale ? .secondaryLabel : .systemIndigo }
    static var pin: UIColor { isPale ? .secondaryLabel : .systemYellow }
    static var enabled: UIColor { isPale ? .secondaryLabel : .systemGreen }
    static var warning: UIColor { isPale ? .secondaryLabel : .systemOrange }

    static var selectedRow: UIColor {
        isPale
            ? UIColor.secondaryLabel.withAlphaComponent(0.10)
            : UIColor.systemIndigo.withAlphaComponent(0.12)
    }

    static func glassView(tintColor: UIColor? = nil) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = tintColor ?? (isPale ? nil : UIColor.systemIndigo.withAlphaComponent(0.10))
        return UIVisualEffectView(effect: effect)
    }
}
