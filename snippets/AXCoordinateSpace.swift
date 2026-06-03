import AppKit

/// Screen geometry snapshot used to keep AX/AppKit coordinate conversion
/// deterministic and testable without depending on live NSScreen state.
struct AXScreenGeometry {
    let frame: NSRect
    let visibleFrame: NSRect

    init(frame: NSRect, visibleFrame: NSRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
    }

    init(_ screen: NSScreen) {
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
    }
}

enum AXCoordinateSpace {
    /// AX top-left coordinates are flipped against the menu-bar/primary screen,
    /// not necessarily `NSScreen.main` (which can be the active external display).
    static func primaryScreenHeight(
        from screens: [AXScreenGeometry],
        fallbackMainHeight: CGFloat = 0
    ) -> CGFloat {
        screens.first?.frame.height ?? fallbackMainHeight
    }

    static func axTopLeftFrame(
        for screen: AXScreenGeometry,
        primaryScreenHeight: CGFloat
    ) -> NSRect {
        NSRect(
            x: screen.frame.minX,
            y: primaryScreenHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    static func convertAXTopLeftRect(
        _ rect: CGRect,
        on screen: AXScreenGeometry,
        primaryScreenHeight: CGFloat
    ) -> NSRect {
        let screenAXFrame = axTopLeftFrame(for: screen, primaryScreenHeight: primaryScreenHeight)
        let yInScreen = rect.origin.y - screenAXFrame.minY
        let flippedY = screen.frame.maxY - yInScreen - rect.size.height
        return NSRect(x: rect.origin.x, y: flippedY, width: rect.size.width, height: rect.size.height)
    }

    static func convertScreenLocalAXTopLeftRect(
        _ rect: CGRect,
        on screen: AXScreenGeometry
    ) -> NSRect {
        let flippedY = screen.frame.maxY - rect.origin.y - rect.size.height
        return NSRect(
            x: screen.frame.minX + rect.origin.x,
            y: flippedY,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}
