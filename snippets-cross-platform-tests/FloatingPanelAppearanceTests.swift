import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class FloatingPanelAppearanceTests: XCTestCase {
    func testPickerSurfaceFollowsInheritedThemeWithoutDependingOnKeyboardFocus() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Liquid Glass requires macOS 26") }
        let previousAppearance = NSApp.appearance
        let previousLegacy = LiquidGlassDesign.forcesLegacyAppearance
        LiquidGlassDesign.forcesLegacyAppearance = false
        defer {
            NSApp.appearance = previousAppearance
            LiquidGlassDesign.forcesLegacyAppearance = previousLegacy
        }
        let panel = makePanel()
        defer { panel.close() }
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let glass = try XCTUnwrap(views.compactMap { $0 as? NSGlassEffectView }.first)
        let content = try XCTUnwrap(views
            .first { $0.accessibilityIdentifier() == "floatingPanelContent" })
        XCTAssertNil(panel.appearance)
        XCTAssertNil(glass.appearance)
        XCTAssertNil(content.appearance)
        XCTAssertEqual(glass.style, .regular)
        XCTAssertNil(content.layer?.backgroundColor,
            "The clipping view must not cover the native glass material with a painted background")

        NSApp.appearance = NSAppearance(named: .aqua)
        panel.orderFrontRegardless()
        panel.makeKey()
        XCTAssertTrue(panel.isKeyWindow)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertNil(glass.tintColor, "System glass must control its own backdrop adaptation")
        XCTAssertNil(content.layer?.backgroundColor)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertNil(glass.tintColor)
        XCTAssertNil(content.layer?.backgroundColor)

        panel.resignKey()
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertNil(glass.tintColor)
        NSApp.appearance = NSAppearance(named: .aqua)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua,
            "System theme changes must also update a panel without keyboard focus")
        XCTAssertNil(content.layer?.backgroundColor)
    }

    func testLegacyPanelKeepsSystemMaterialWithoutPickerTint() throws {
        let previousLegacy = LiquidGlassDesign.forcesLegacyAppearance
        LiquidGlassDesign.forcesLegacyAppearance = true
        defer { LiquidGlassDesign.forcesLegacyAppearance = previousLegacy }
        let panel = makePanel()
        defer { panel.close() }
        panel.orderFrontRegardless()
        panel.makeKey()
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let material = try XCTUnwrap(views.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        let content = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "floatingPanelContent" })
        XCTAssertNil(content.layer?.backgroundColor)
    }

    private func makePanel() -> NSPanel {
        let panel = AppearanceTestPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let root = panel.contentView!
        let surface = LiquidGlassDesign.makeFloatingPanelSurface(containing: NSView())
        root.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return panel
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

private final class AppearanceTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
