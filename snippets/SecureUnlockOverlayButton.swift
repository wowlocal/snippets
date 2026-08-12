import AppKit

/// The transparent, full-surface click target shown over a locked secure
/// snippet. A normal borderless `NSButton` inherits no useful cursor rect, so
/// the text editor underneath can leave its I-beam active even though clicking
/// this surface unlocks the vault.
///
/// Keep the cursor state on the control that owns the action. Disabled overlay
/// messages are informational and therefore retain the normal arrow, while a
/// hidden overlay installs no rect and leaves the ordinary editor untouched.
final class SecureUnlockOverlayButton: NSButton {
    /// Kept as a closed predicate so state transitions and cursor-rect rebuilds
    /// cannot disagree about whether this is currently an unlock affordance.
    var usesPointingHandCursor: Bool {
        isEnabled && !isHiddenOrHasHiddenAncestor && window != nil
    }

    override var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            invalidateOwnCursorRects()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHiddenOrHasHiddenAncestor, window != nil else { return }
        addCursorRect(bounds, cursor: usesPointingHandCursor ? .pointingHand : .arrow)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        guard oldSize != frame.size else { return }
        invalidateOwnCursorRects()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let oldOrigin = frame.origin
        super.setFrameOrigin(newOrigin)
        guard oldOrigin != frame.origin else { return }
        invalidateOwnCursorRects()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Remove a registered rect from the old window before `window` changes.
        invalidateOwnCursorRects()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateOwnCursorRects()
    }

    override func viewDidHide() {
        super.viewDidHide()
        invalidateOwnCursorRects()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        invalidateOwnCursorRects()
    }

    private func invalidateOwnCursorRects() {
        window?.invalidateCursorRects(for: self)
    }
}
