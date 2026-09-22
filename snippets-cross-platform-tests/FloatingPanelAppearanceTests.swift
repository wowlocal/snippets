import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class FloatingPanelAppearanceTests: XCTestCase {
    func testPickerSurfaceFollowsInheritedThemeWithoutDependingOnKeyboardFocus() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Liquid Glass requires macOS 26") }
        try XCTSkipIf(LiquidGlassDesign.prefersHighContrastHighlight,
            "System accessibility settings intentionally use their own material treatment")
        let previousAppearance = NSApp.appearance
        let previousLegacy = LiquidGlassDesign.forcesLegacyAppearance
        LiquidGlassDesign.forcesLegacyAppearance = false
        defer {
            NSApp.appearance = previousAppearance
            LiquidGlassDesign.forcesLegacyAppearance = previousLegacy
        }
        let panel = makePanel(usesPickerAppearance: true)
        defer { panel.close() }
        let content = try XCTUnwrap(descendants(of: try XCTUnwrap(panel.contentView))
            .first { $0.accessibilityIdentifier() == "floatingPanelContent" })
        XCTAssertNil(panel.appearance)
        XCTAssertNil(content.appearance)
        XCTAssertNotNil(content.layer?.backgroundColor)

        NSApp.appearance = NSAppearance(named: .aqua)
        panel.orderFrontRegardless()
        panel.makeKey()
        XCTAssertTrue(panel.isKeyWindow)
        panel.contentView?.layoutSubtreeIfNeeded()
        let light = try color(of: content)
        XCTAssertGreaterThan(light.redComponent, 0.8)
        XCTAssertGreaterThanOrEqual(light.alphaComponent, 0.65)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        let dark = try color(of: content)
        XCTAssertLessThan(dark.redComponent, 0.3)
        XCTAssertGreaterThanOrEqual(dark.alphaComponent, 0.65)

        panel.resignKey()
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(try color(of: content), dark,
            "Inline suggestions must keep the same theme base as keyboard-enabled pickers")
    }

    func testLegacyPanelKeepsSystemMaterialWithoutPickerTint() throws {
        let previousLegacy = LiquidGlassDesign.forcesLegacyAppearance
        LiquidGlassDesign.forcesLegacyAppearance = true
        defer { LiquidGlassDesign.forcesLegacyAppearance = previousLegacy }
        let panel = makePanel(usesPickerAppearance: true)
        defer { panel.close() }
        panel.orderFrontRegardless()
        panel.makeKey()
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let material = try XCTUnwrap(views.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        let content = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "floatingPanelContent" })
        XCTAssertNil(content.layer?.backgroundColor)
    }

    private func makePanel(usesPickerAppearance: Bool) -> NSPanel {
        let panel = AppearanceTestPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let root = panel.contentView!
        let surface = LiquidGlassDesign.makeFloatingPanelSurface(containing: NSView(),
            usesPickerAppearance: usesPickerAppearance)
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
