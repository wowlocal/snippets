import CoreVideo
import IOSurface
import UIKit
import XCTest
@testable import Snippets

@MainActor
final class SecureCaptureRendererTests: XCTestCase {
    func testGeometryRoundsOutwardAndRejectsOversizedBuffers() throws {
        let geometry = try XCTUnwrap(SecureSnippetCaptureFrameGeometry.make(
            viewport: CGRect(x: 0.25, y: 1.5, width: 320.25, height: 118.1),
            displayScale: 2
        ))

        XCTAssertEqual(geometry.viewport, CGRect(x: 0.25, y: 1.5, width: 320.25, height: 118.1))
        XCTAssertEqual(geometry.pixelWidth, 641)
        XCTAssertEqual(geometry.pixelHeight, 237)
        XCTAssertEqual(geometry.displayScale, 2)
        XCTAssertNil(SecureSnippetCaptureFrameGeometry.make(
            viewport: CGRect(x: 0, y: 0, width: 5_000, height: 5_000),
            displayScale: 2
        ))
    }

    func testSecureArmProtectsBeforePlaintextAndRasterUsesIOSurface() throws {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)

        XCTAssertTrue(textView.bindSecureRedacted())
        XCTAssertEqual(textView.secureCapturePhase, .protectedRedaction)
        XCTAssertTrue(textView.nativePlaintextLayerSuppressedForInspection)
        XCTAssertTrue(textView.secureCaptureProtectionEnabledForInspection)
        XCTAssertTrue(textView.secureCaptureLayerAttachedForInspection)
        XCTAssertFalse(textView.secureCapturePreventsDisplaySleepForInspection)

        textView.setSecurePlaintextAcceptanceAuthorized(true)
        XCTAssertTrue(textView.displaySecurePlaintext("upright secure raster"))
        XCTAssertEqual(textView.secureCapturePhase, .protectedPlaintext)
        let frame = try XCTUnwrap(textView.renderSecureFrameForInspection(plaintext: true))
        XCTAssertNotNil(CVPixelBufferGetIOSurface(frame.pixelBuffer))
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), frame.geometry.pixelWidth)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), frame.geometry.pixelHeight)
        XCTAssertTrue(pixelBufferContainsNonBackgroundPixels(frame.pixelBuffer))
    }

    func testOrdinaryRebindClearsProtectedPresentationBeforeRestoringUIKit() {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())
        textView.setSecurePlaintextAcceptanceAuthorized(true)
        XCTAssertTrue(textView.displaySecurePlaintext("old secure body"))

        textView.bindOrdinaryText("ordinary body")

        XCTAssertEqual(textView.secureCapturePhase, .ordinary)
        XCTAssertFalse(textView.isSecureContentMode)
        XCTAssertFalse(textView.nativePlaintextLayerSuppressedForInspection)
        XCTAssertTrue(textView.secureCaptureSurfaceView.isHidden)
        XCTAssertEqual(textView.text, "ordinary body")
    }

    func testActiveAndUnspecifiedSceneCaptureRedactAndReturnCapturedPlaintext() {
        for state in [UISceneCaptureState.active, .unspecified] {
            let textView = makeTextView()
            textView.setSceneCaptureStateForTesting(.inactive)
            XCTAssertTrue(textView.bindSecureRedacted())
            let sentinel = "secure-\(state.rawValue)"
            textView.setSecurePlaintextAcceptanceAuthorized(true)
            XCTAssertTrue(textView.displaySecurePlaintext(sentinel))

            var callback: (String?, SecureSnippetForcedRedactionReason)?
            textView.onSecureCaptureForcedRedaction = { plaintext, reason in
                callback = (plaintext, reason)
            }
            textView.setSceneCaptureStateForTesting(state)

            XCTAssertEqual(textView.secureCapturePhase, .protectedRedaction)
            XCTAssertEqual(textView.text, "")
            XCTAssertEqual(callback?.0, sentinel)
            XCTAssertEqual(callback?.1, .sceneCapture)
            XCTAssertTrue(textView.nativePlaintextLayerSuppressedForInspection)
        }
    }

    private func makeTextView() -> SecureSnippetTextView {
        let textView = SecureSnippetTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        textView.setSecureForegroundActiveForTesting(true)
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.backgroundColor = .clear
        textView.secureCaptureBackgroundColor = .black
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.secureCaptureSurfaceView.frame = textView.bounds
        textView.layoutIfNeeded()
        return textView
    }

    private func pixelBufferContainsNonBackgroundPixels(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self)
        else { return false }

        let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        var index = 0
        while index + 3 < byteCount {
            if bytes[index] != 0 || bytes[index + 1] != 0 || bytes[index + 2] != 0 {
                return true
            }
            index += 4
        }
        return false
    }
}
