import Foundation
import Testing
@testable import SnippetsCore

@Suite("Secure capture presentation policy")
struct SecureCapturePresentationPolicyTests {
    @Test("Plaintext pixels are impossible before protection is armed")
    func plaintextRequiresArming() {
        var policy = SecureCapturePresentationPolicy()

        policy.setPlaintextPixelsVisible(true)

        #expect(policy.phase == .ordinary)
        #expect(!policy.suppressesUnprotectedDrawing)
        #expect(!policy.permitsPlaintextInTextStorage)
        #expect(!policy.rendersPlaintextPixels)
    }

    @Test("Arming starts with protected redaction")
    func armStartsRedacted() {
        var policy = SecureCapturePresentationPolicy()

        policy.arm()

        #expect(policy.phase == .protectedRedaction)
        #expect(policy.suppressesUnprotectedDrawing)
        #expect(policy.permitsPlaintextInTextStorage)
        #expect(policy.keepsProtectedLayerVisible)
        #expect(!policy.rendersPlaintextPixels)
    }

    @Test("Pixel visibility is independent from the armed lifetime")
    func pixelVisibilityCanToggle() {
        var policy = SecureCapturePresentationPolicy()
        policy.arm()

        policy.setPlaintextPixelsVisible(true)
        #expect(policy.phase == .protectedPlaintext)
        #expect(policy.suppressesUnprotectedDrawing)
        #expect(policy.rendersPlaintextPixels)

        policy.setPlaintextPixelsVisible(false)
        #expect(policy.phase == .protectedRedaction)
        #expect(policy.suppressesUnprotectedDrawing)
        #expect(policy.keepsProtectedLayerVisible)
        #expect(!policy.rendersPlaintextPixels)
    }

    @Test("Failure never falls back to AppKit drawing")
    func failureIsClosed() {
        var policy = SecureCapturePresentationPolicy()
        policy.arm()
        policy.setPlaintextPixelsVisible(true)

        policy.failClosed()

        #expect(policy.phase == .failedClosed)
        #expect(policy.suppressesUnprotectedDrawing)
        #expect(!policy.permitsPlaintextInTextStorage)
        #expect(!policy.keepsProtectedLayerVisible)
        #expect(!policy.rendersPlaintextPixels)

        policy.setPlaintextPixelsVisible(true)
        #expect(policy.phase == .failedClosed)
    }

    @Test("Only explicit post-clear reset restores ordinary drawing")
    func resetAfterClear() {
        var policy = SecureCapturePresentationPolicy()
        policy.arm()
        policy.failClosed()

        policy.resetAfterPlaintextWasCleared()

        #expect(policy.phase == .ordinary)
        #expect(!policy.suppressesUnprotectedDrawing)
    }

    @Test("Ordinary rebind assigns its body only after secure teardown")
    func ordinaryRebindOrdering() {
        #expect(SecureCapturePresentationPolicy.ordinaryRebindSteps() == [
            .suppressDrawing,
            .clearOldText,
            .removeProtectedPresentation,
            .assignOrdinaryText,
        ])
    }

    @Test("Viewport dimensions round outward at Retina scale")
    func retinaGeometry() throws {
        let geometry = try #require(SecureCaptureFrameGeometry.make(
            viewport: CGRect(x: 12.25, y: 44.5, width: 320.25, height: 118.1),
            backingScale: 2
        ))

        #expect(geometry.viewport.origin.x == 12.25)
        #expect(geometry.viewport.origin.y == 44.5)
        #expect(geometry.viewport.width == 320.25)
        #expect(geometry.viewport.height == 118.1)
        #expect(geometry.pixelWidth == 641)
        #expect(geometry.pixelHeight == 237)
        #expect(geometry.backingScale == 2)
    }

    @Test("Negative viewport sizes are standardized")
    func standardizedGeometry() throws {
        let geometry = try #require(SecureCaptureFrameGeometry.make(
            viewport: CGRect(x: 10, y: 20, width: -4, height: -6),
            backingScale: 1
        ))

        #expect(geometry.viewport.origin.x == 6)
        #expect(geometry.viewport.origin.y == 14)
        #expect(geometry.viewport.width == 4)
        #expect(geometry.viewport.height == 6)
        #expect(geometry.pixelWidth == 4)
        #expect(geometry.pixelHeight == 6)
    }

    @Test(arguments: [
        (CGRect.zero, CGFloat(2)),
        (CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), CGFloat(2)),
        (CGRect(x: 0, y: 0, width: 10, height: 10), CGFloat.zero),
        (CGRect(x: 0, y: 0, width: 10, height: 10), CGFloat.nan),
    ])
    func invalidGeometryIsRejected(viewport: CGRect, scale: CGFloat) {
        #expect(SecureCaptureFrameGeometry.make(
            viewport: viewport,
            backingScale: scale
        ) == nil)
    }

    @Test("Oversized allocations fail closed")
    func allocationLimits() {
        #expect(SecureCaptureFrameGeometry.make(
            viewport: CGRect(x: 0, y: 0, width: 5_000, height: 5_000),
            backingScale: 2
        ) == nil)

        #expect(SecureCaptureFrameGeometry.make(
            viewport: CGRect(x: 0, y: 0, width: 100, height: 100),
            backingScale: 1,
            maximumPixelDimension: 1_000,
            maximumPixelCount: 9_999
        ) == nil)
    }
}
