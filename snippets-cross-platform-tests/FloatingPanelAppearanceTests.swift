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

        NSApp.appearance = NSAppearance(named: .aqua)
        panel.orderFrontRegardless()
        panel.makeKey()
        XCTAssertTrue(panel.isKeyWindow)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertNil(glass.tintColor, "System glass must control its own backdrop adaptation")
        try assertBackdropVeil(content, isDark: false)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertNil(glass.tintColor)
        try assertBackdropVeil(content, isDark: true)

        panel.resignKey()
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertNil(glass.tintColor)
        try assertBackdropVeil(content, isDark: true)
        NSApp.appearance = NSAppearance(named: .aqua)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua,
            "System theme changes must also update a panel without keyboard focus")
        try assertBackdropVeil(content, isDark: false)
    }

    func testLegacyPanelKeepsBehindWindowMaterialAndAdaptiveVeil() throws {
        let previousAppearance = NSApp.appearance
        let previousLegacy = LiquidGlassDesign.forcesLegacyAppearance
        LiquidGlassDesign.forcesLegacyAppearance = true
        defer {
            NSApp.appearance = previousAppearance
            LiquidGlassDesign.forcesLegacyAppearance = previousLegacy
        }
        let panel = makePanel()
        defer { panel.close() }
        panel.orderFrontRegardless()
        panel.makeKey()
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let material = try XCTUnwrap(views.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        let content = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "floatingPanelContent" })
        for isDark in [true, false] {
            NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            panel.contentView?.layoutSubtreeIfNeeded()
            try assertBackdropVeil(content, isDark: isDark)
        }
    }

    private func assertBackdropVeil(
        _ content: NSView,
        isDark: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cgColor = try XCTUnwrap(content.layer?.backgroundColor, file: file, line: line)
        let color = try XCTUnwrap(NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB), file: file, line: line)
        XCTAssertEqual(color.redComponent, isDark ? 0 : 1, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.greenComponent, color.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.blueComponent, color.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertGreaterThan(color.alphaComponent, 0, file: file, line: line)
        XCTAssertLessThan(color.alphaComponent, 1, "The veil must preserve translucency", file: file, line: line)
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
