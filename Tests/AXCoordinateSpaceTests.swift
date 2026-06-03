import AppKit

private func assertEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String, tolerance: CGFloat = 0.0001) {
    if abs(actual - expected) > tolerance {
        fputs("FAIL: \(message) — expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum AXCoordinateSpaceTests {
    static func main() {
        // Regression: v1.3.41 used NSScreen.main.height while converting AX top-left
        // coordinates. On macOS, NSScreen.main can be the active external display, while
        // AX global coordinates are still flipped against the menu-bar/primary screen.
        let primary = AXScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let external = AXScreenGeometry(
            frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        let activeExternalMainHeight: CGFloat = 1080

        let primaryHeight = AXCoordinateSpace.primaryScreenHeight(
            from: [primary, external],
            fallbackMainHeight: activeExternalMainHeight
        )
        assertEqual(primaryHeight, 900, "AX conversion should use menu-bar/primary screen height, not active external screen height")

        let axCaretRect = CGRect(x: 2000, y: 400, width: 8, height: 20)
        let converted = AXCoordinateSpace.convertAXTopLeftRect(
            axCaretRect,
            on: external,
            primaryScreenHeight: primaryHeight
        )

        assertEqual(converted.origin.x, 2000, "AX conversion preserves global X")
        assertEqual(converted.origin.y, 480, "AX top-left Y converts to AppKit Y using primary screen height")

        print("AXCoordinateSpaceTests passed")
    }
}
