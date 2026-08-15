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
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)

        authorizePresentation(in: textView)
        var presentedCount = 0
        textView.onSecurePlaintextPresented = {
            presentedCount += 1
            textView.setSecureEditingAuthorized(true)
        }
        var flushCompletion: (() -> Void)?
        textView.setSecureCaptureFlushCompletionOverrideForTesting { completion in
            flushCompletion = completion
        }
        XCTAssertTrue(textView.displaySecurePlaintext("upright secure raster"))
        XCTAssertEqual(textView.secureCapturePhase, .protectedPlaintext)
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertNotNil(textView.secureCapturePendingGenerationForInspection)
        textView.insertText(" blocked-before-frame")
        XCTAssertEqual(textView.text, "upright secure raster")
        flushCompletion?()
        XCTAssertEqual(presentedCount, 1)
        XCTAssertFalse(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertNil(textView.secureCapturePendingGenerationForInspection)
        let frame = try XCTUnwrap(textView.renderSecureFrameForInspection(plaintext: true))
        XCTAssertNotNil(CVPixelBufferGetIOSurface(frame.pixelBuffer))
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), frame.geometry.pixelWidth)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), frame.geometry.pixelHeight)
        XCTAssertTrue(pixelBufferContainsNonBackgroundPixels(frame.pixelBuffer))
    }

    func testTrailingLineBreakMarkersAreCountableWithoutChangingContent() throws {
        let textView = makeTextView()
        textView.bindOrdinaryText("word\n\n")

        XCTAssertEqual(textView.trailingLineBreakMarkerRangesForInspection, [
            NSRange(location: 4, length: 1),
            NSRange(location: 5, length: 1),
        ])
        let markerRects = textView.trailingLineBreakMarkerRectsForInspection
        XCTAssertEqual(markerRects.count, 2)
        XCTAssertGreaterThan(
            try XCTUnwrap(markerRects.last).minY,
            try XCTUnwrap(markerRects.first).minY
        )
        XCTAssertEqual(textView.text, "word\n\n")

        textView.bindOrdinaryText("word\ninside")
        XCTAssertTrue(textView.trailingLineBreakMarkerRangesForInspection.isEmpty)

        textView.bindOrdinaryText("word\r\n")
        XCTAssertEqual(textView.trailingLineBreakMarkerRangesForInspection, [
            NSRange(location: 4, length: 2),
        ])

        textView.bindOrdinaryText("👩🏽‍💻\n")
        XCTAssertEqual(textView.trailingLineBreakMarkerRectsForInspection.count, 1)
    }

    func testProtectedRasterDrawsMarkerForOtherwiseInvisibleTrailingBreak() throws {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())
        authorizePresentation(in: textView)
        XCTAssertTrue(textView.displaySecurePlaintext("\n"))

        let frame = try XCTUnwrap(textView.renderSecureFrameForInspection(plaintext: true))
        XCTAssertTrue(pixelBufferContainsNonBackgroundPixels(frame.pixelBuffer))
        XCTAssertEqual(textView.text, "\n")
    }

    func testOrdinaryRebindClearsProtectedPresentationBeforeRestoringUIKit() {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())
        authorizePresentation(in: textView)
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
            authorizePresentation(in: textView)
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
            XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
            XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)
        }
    }

    func testStalePlaintextFlushCompletionCannotUndoSynchronousRedaction() throws {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())

        var staleCompletion: (() -> Void)?
        textView.setSecureCaptureFlushCompletionOverrideForTesting { completion in
            staleCompletion = completion
        }
        authorizePresentation(in: textView)
        XCTAssertTrue(textView.displaySecurePlaintext("must never return"))
        let pendingGeneration = try XCTUnwrap(
            textView.secureCapturePendingGenerationForInspection
        )
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)

        textView.redactAndClearSecurePlaintext()

        XCTAssertGreaterThan(textView.secureCaptureFrameGenerationForInspection, pendingGeneration)
        XCTAssertNil(textView.secureCapturePendingGenerationForInspection)
        XCTAssertEqual(textView.text, "")
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)

        staleCompletion?()

        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)
        XCTAssertNil(textView.secureCapturePendingGenerationForInspection)
    }

    func testNonForegroundPresentationIsRejectedWithoutShowingAVLayer() {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())
        textView.setForegroundPresentationAllowedForTesting(false)
        authorizePresentation(in: textView)

        XCTAssertFalse(textView.displaySecurePlaintext("background secret"))

        XCTAssertEqual(textView.secureCapturePhase, .protectedRedaction)
        XCTAssertEqual(textView.text, "")
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)
    }

    func testCurrentCompletionRejectedByLifecycleGateClearsPlaintextAndNotifiesOwner() {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())
        authorizePresentation(in: textView)

        var completion: (() -> Void)?
        textView.setSecureCaptureFlushCompletionOverrideForTesting { completion = $0 }
        XCTAssertTrue(textView.displaySecurePlaintext("background transition secret"))

        var callback: (String?, SecureSnippetForcedRedactionReason)?
        textView.onSecureCaptureForcedRedaction = { callback = ($0, $1) }
        textView.setForegroundPresentationAllowedForTesting(false)
        completion?()

        XCTAssertEqual(callback?.0, "background transition secret")
        XCTAssertEqual(callback?.1, .presentationRevoked)
        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(textView.secureCapturePhase, .protectedRedaction)
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)
    }

    func testCurrentCompletionWithUnhealthyRendererFailsClosedAndClearsPlaintext() {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())
        authorizePresentation(in: textView)

        var completion: (() -> Void)?
        textView.setSecureCaptureFlushCompletionOverrideForTesting { completion = $0 }
        XCTAssertTrue(textView.displaySecurePlaintext("renderer failure secret"))

        var callback: (String?, SecureSnippetForcedRedactionReason)?
        textView.onSecureCaptureForcedRedaction = { callback = ($0, $1) }
        textView.setSecureCaptureRendererFailedForTesting(true)
        completion?()

        XCTAssertEqual(callback?.0, "renderer failure secret")
        XCTAssertEqual(callback?.1, .rendererFailure)
        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(textView.secureCapturePhase, .failedClosed)
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)
    }

    func testSubsequentProtectedRedrawReplacesVisibleFrameWithoutBlanking() {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())
        authorizePresentation(in: textView)

        var completions: [() -> Void] = []
        textView.setSecureCaptureFlushCompletionOverrideForTesting { completions.append($0) }
        var presentedCount = 0
        textView.onSecurePlaintextPresented = { presentedCount += 1 }
        XCTAssertTrue(textView.displaySecurePlaintext("refresh secret"))
        XCTAssertEqual(completions.count, 1)
        completions.removeFirst()()
        XCTAssertEqual(presentedCount, 1)
        XCTAssertFalse(textView.secureCaptureDisplayLayerHiddenForInspection)

        textView.invalidateSecureCaptureRenderer()

        XCTAssertTrue(
            completions.isEmpty,
            "a protected-to-protected redraw must not enter the initial flush path")
        XCTAssertEqual(presentedCount, 2)
        XCTAssertEqual(textView.text, "refresh secret")
        XCTAssertEqual(textView.secureCapturePhase, .protectedPlaintext)
        XCTAssertFalse(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertNil(textView.secureCapturePendingGenerationForInspection)
    }

    func testDecodeFailedRendererCannotReportHealthyWhenRearmed() {
        let textView = makeTextView()
        textView.text = "stale body"
        textView.setSecureCaptureRendererFailedForTesting(true)

        XCTAssertFalse(textView.bindSecureRedacted())

        XCTAssertEqual(textView.secureCapturePhase, .failedClosed)
        XCTAssertEqual(textView.text, "")
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)
    }

    func testFailedRendererCanBeReplacedWithRedactedSurfaceForFreshReveal() {
        let textView = makeTextView()
        textView.text = "stale body"
        textView.setSecureCaptureRendererFailedForTesting(true)
        XCTAssertFalse(textView.bindSecureRedacted())
        textView.setSecureCaptureRendererFailedForTesting(false)

        XCTAssertTrue(textView.recoverSecureRedactionAfterRendererFailure())

        XCTAssertEqual(textView.secureCapturePhase, .protectedRedaction)
        XCTAssertEqual(textView.text, "")
        XCTAssertTrue(textView.isSecureContentMode)
        XCTAssertTrue(textView.nativePlaintextLayerSuppressedForInspection)
        XCTAssertTrue(textView.secureCaptureProtectionEnabledForInspection)
        XCTAssertTrue(textView.secureCaptureLayerAttachedForInspection)
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)
        XCTAssertFalse(textView.permitsSecureTextMutation)
    }

    func testLatentRendererFailureIsRecoveredBeforePlaintextEntersStorage() {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(textView.bindSecureRedacted())
        authorizePresentation(in: textView)
        textView.setSecureCaptureRendererFailedForTesting(true)

        XCTAssertEqual(textView.prepareSecurePlaintextPresentation(), .recoveredRenderer)

        XCTAssertEqual(textView.secureCapturePhase, .protectedRedaction)
        XCTAssertEqual(textView.text, "")
        XCTAssertTrue(textView.nativePlaintextLayerSuppressedForInspection)
        XCTAssertTrue(textView.secureCaptureProtectionEnabledForInspection)
        XCTAssertTrue(textView.secureCaptureLayerAttachedForInspection)
        XCTAssertTrue(textView.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(textView.secureCaptureFallbackVisibleForInspection)
        XCTAssertTrue(textView.canAcceptSecurePlaintext)
    }

    private func makeTextView() -> SecureSnippetTextView {
        let textView = SecureSnippetTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        textView.setSecureForegroundActiveForTesting(true)
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.secureCaptureBackgroundColor = .black
        textView.setForegroundPresentationAllowedForTesting(true)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.secureCaptureSurfaceView.frame = textView.bounds
        textView.layoutIfNeeded()
        return textView
    }

    private func authorizePresentation(in textView: SecureSnippetTextView) {
        textView.setSecurePlaintextAcceptanceAuthorized(true)
        textView.setSecureRevealSessionAuthorized(true)
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
