import AppKit

/// Colors shared by `EditorInputSurface` and the secure-capture renderer, which must
/// paint a protected frame with exactly the fill of the surface behind the editor.
///
/// This lives apart from `LiquidGlassDesign.swift` so the CorePackage
/// `SnippetsSecureEditor` target can compile the shipping renderer without pulling in
/// the rest of the app's design layer. Explicitly main-actor isolated so the app (default
/// MainActor) and the package (no default isolation) build the same declaration.
@MainActor
enum EditorInputPalette {
    /// Resolves at drawing time, so appearance changes are picked up without caching.
    static var backgroundColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.21, alpha: 1) : NSColor(white: 1, alpha: 1)
        }
    }
}
