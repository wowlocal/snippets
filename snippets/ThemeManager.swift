import AppKit

enum ThemeManager {
    static let defaultsKey = "snippetsPaleThemeEnabled"

    static var isPaleTheme: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .snippetsPaleThemeChanged, object: nil)
        }
    }

    static var snippetDotColor: NSColor {
        isPaleTheme ? .secondaryLabelColor : .systemGreen
    }

    static var pinColor: NSColor {
        isPaleTheme ? .secondaryLabelColor : .systemYellow
    }

    static var newButtonBezelColor: NSColor? {
        isPaleTheme ? nil : .systemBlue
    }

    static var alertColor: NSColor {
        isPaleTheme ? .secondaryLabelColor : .systemOrange
    }

    static func applyToggleAppearance(to button: NSButton) {
        button.wantsLayer = true

        guard isPaleTheme, let filter = CIFilter(name: "CIColorControls") else {
            button.layer?.filters = nil
            return
        }

        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        button.layer?.filters = [filter]
    }
}
