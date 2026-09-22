import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class FloatingPanelAppearanceTests: XCTestCase {
    func testPickerSurfaceFollowsInheritedThemeAndActualKeyState() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Liquid Glass requires macOS 26") }
        try XCTSkipIf(LiquidGlassDesign.prefersHighContrastHighlight,
            "System accessibility settings intentionally suppress the decorative wash")
        let previousAppearance = NSApp.appearance
        let previousLegacy = LiquidGlassDesign.forcesLegacyAppearance
        LiquidGlassDesign.forcesLegacyAppearance = false
        defer {
            NSApp.appearance = previousAppearance
            LiquidGlassDesign.forcesLegacyAppearance = previousLegacy
        }
        let panel = makePanel(normalizesKeyAppearance: true)
        defer { panel.close() }
        let content = try XCTUnwrap(descendants(of: try XCTUnwrap(panel.contentView))
            .first { $0.accessibilityIdentifier() == "floatingPanelContent" })
        XCTAssertNil(panel.appearance)
        XCTAssertNil(content.appearance)
        XCTAssertNil(content.layer?.backgroundColor)

        NSApp.appearance = NSAppearance(named: .aqua)
        panel.orderFrontRegardless()
        panel.makeKey()
        XCTAssertTrue(panel.isKeyWindow)
        panel.contentView?.layoutSubtreeIfNeeded()
        let light = try color(of: content)
        XCTAssertLessThan(light.redComponent, 0.1)
        XCTAssertGreaterThan(light.alphaComponent, 0)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        let dark = try color(of: content)
        XCTAssertGreaterThan(dark.redComponent, 0.9)
        XCTAssertGreaterThan(dark.alphaComponent, 0)

        panel.resignKey()
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertNil(content.layer?.backgroundColor,
            "Returning focus to the destination app must restore the inactive panel surface")
    }

    func testLegacyPanelKeepsSystemMaterialWithoutGlassCompensation() throws {
        let previousLegacy = LiquidGlassDesign.forcesLegacyAppearance
        LiquidGlassDesign.forcesLegacyAppearance = true
        defer { LiquidGlassDesign.forcesLegacyAppearance = previousLegacy }
        let panel = makePanel(normalizesKeyAppearance: true)
        defer { panel.close() }
        panel.orderFrontRegardless()
        panel.makeKey()
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let material = try XCTUnwrap(views.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        let content = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "floatingPanelContent" })
        XCTAssertNil(content.layer?.backgroundColor)
    }

    private func makePanel(normalizesKeyAppearance: Bool) -> NSPanel {
        let panel = AppearanceTestPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let root = panel.contentView!
        let surface = LiquidGlassDesign.makeFloatingPanelSurface(containing: NSView(),
            normalizesKeyAppearance: normalizesKeyAppearance)
        root.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return panel
    }

    private func color(of view: NSView) throws -> NSColor {
        let color = try XCTUnwrap(view.layer?.backgroundColor)
        return try XCTUnwrap(NSColor(cgColor: color)?.usingColorSpace(.deviceRGB))
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
