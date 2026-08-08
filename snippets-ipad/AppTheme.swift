import UIKit

enum AppTheme {
    static let tint = UIColor.systemIndigo
    static let pin = UIColor.systemYellow
    static let enabled = UIColor.systemGreen
    static let warning = UIColor.systemOrange
    static let selectedRow = UIColor.systemIndigo.withAlphaComponent(0.12)

    static func glassView(tintColor: UIColor? = nil) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = tintColor ?? UIColor.systemIndigo.withAlphaComponent(0.10)
        return UIVisualEffectView(effect: effect)
    }
}
