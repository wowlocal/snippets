import Foundation
import CoreGraphics

/// Pure state and geometry rules for the macOS secure-content renderer.
///
/// The renderer itself lives at the AppKit boundary. Keeping the ordering rules here
/// makes the security-critical transitions testable without creating a window or an
/// AVFoundation decoder in the test process.
nonisolated struct SecureCapturePresentationPolicy: Equatable {
    enum Phase: Equatable {
        /// AppKit owns drawing. Plain snippets use only this phase.
        case ordinary
        /// AppKit drawing is suppressed and an opaque protected frame is displayed.
        case protectedRedaction
        /// AppKit drawing is suppressed and the protected layer may display plaintext.
        case protectedPlaintext
        /// Rendering failed. AppKit stays suppressed and the protected layer is hidden.
        case failedClosed
    }

    private(set) var phase: Phase = .ordinary

    var suppressesUnprotectedDrawing: Bool { phase != .ordinary }

    var permitsPlaintextInTextStorage: Bool {
        phase == .protectedRedaction || phase == .protectedPlaintext
    }

    var rendersPlaintextPixels: Bool { phase == .protectedPlaintext }

    var keepsProtectedLayerVisible: Bool {
        phase == .protectedRedaction || phase == .protectedPlaintext
    }

    mutating func arm() {
        phase = .protectedRedaction
    }

    mutating func setPlaintextPixelsVisible(_ visible: Bool) {
        guard permitsPlaintextInTextStorage else { return }
        phase = visible ? .protectedPlaintext : .protectedRedaction
    }

    mutating func failClosed() {
        phase = .failedClosed
    }

    /// The caller must clear NSTextStorage before invoking this transition. The
    /// policy deliberately cannot verify that AppKit-side fact, so the renderer API
    /// names that precondition explicitly and asserts it at the boundary.
    mutating func resetAfterPlaintextWasCleared() {
        phase = .ordinary
    }

    /// Models the security-sensitive rebind ordering used by the AppKit boundary.
    /// A new ordinary body may be assigned only after old secure storage was cleared
    /// and ordinary drawing was restored.
    static func ordinaryRebindSteps() -> [RebindStep] {
        [.suppressDrawing, .clearOldText, .removeProtectedPresentation, .assignOrdinaryText]
    }

    enum RebindStep: Equatable {
        case suppressDrawing
        case clearOldText
        case removeProtectedPresentation
        case assignOrdinaryText
    }
}

nonisolated struct SecureCaptureFrameGeometry {
    static let maximumPixelDimension = 16_384
    static let maximumPixelCount = 16_777_216

    let viewport: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let backingScale: CGFloat

    static func make(
        viewport rawViewport: CGRect,
        backingScale rawBackingScale: CGFloat,
        maximumPixelDimension: Int = maximumPixelDimension,
        maximumPixelCount: Int = maximumPixelCount
    ) -> SecureCaptureFrameGeometry? {
        let rawWidth = rawViewport.size.width
        let rawHeight = rawViewport.size.height
        let viewport = CGRect(
            x: rawWidth >= 0 ? rawViewport.origin.x : rawViewport.origin.x + rawWidth,
            y: rawHeight >= 0 ? rawViewport.origin.y : rawViewport.origin.y + rawHeight,
            width: abs(rawWidth),
            height: abs(rawHeight)
        )
        guard viewport.origin.x.isFinite,
              viewport.origin.y.isFinite,
              viewport.width.isFinite,
              viewport.height.isFinite,
              viewport.width > 0,
              viewport.height > 0,
              rawBackingScale.isFinite,
              rawBackingScale > 0,
              maximumPixelDimension > 0,
              maximumPixelCount > 0 else { return nil }

        let pixelWidthValue = ceil(viewport.width * rawBackingScale)
        let pixelHeightValue = ceil(viewport.height * rawBackingScale)
        guard pixelWidthValue.isFinite,
              pixelHeightValue.isFinite,
              pixelWidthValue >= 1,
              pixelHeightValue >= 1,
              pixelWidthValue <= CGFloat(maximumPixelDimension),
              pixelHeightValue <= CGFloat(maximumPixelDimension) else { return nil }

        let pixelWidth = Int(pixelWidthValue)
        let pixelHeight = Int(pixelHeightValue)
        let (pixelCount, overflowed) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflowed, pixelCount <= maximumPixelCount else { return nil }

        return SecureCaptureFrameGeometry(
            viewport: viewport,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            backingScale: rawBackingScale
        )
    }
}
