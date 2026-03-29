import AppKit

final class InvisibleDividerSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 6 }

    override func drawDivider(in rect: NSRect) {
        let handleWidth: CGFloat = 4
        let handleHeight: CGFloat = 36
        let handleRect = NSRect(
            x: rect.midX - handleWidth / 2,
            y: rect.midY - handleHeight / 2,
            width: handleWidth,
            height: handleHeight
        )
        let path = NSBezierPath(roundedRect: handleRect, xRadius: handleWidth / 2, yRadius: handleWidth / 2)
        NSColor.white.withAlphaComponent(0.15).setFill()
        path.fill()
    }
}
