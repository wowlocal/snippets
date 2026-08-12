import UIKit
import XCTest
@testable import Snippets

@MainActor
final class SecureSnippetRevealTests: XCTestCase {
    func testAuthenticationEndsRedactedAndRequiresFreshContinuousSource() throws {
        var policy = SecureSnippetRevealPolicy()
        policy.bindSecure(
            rendererIsHealthy: true,
            appAndSceneAreActive: true,
            sceneCaptureIsInactive: true)

        let token = try XCTUnwrap(policy.beginAuthentication())
        XCTAssertEqual(policy.begin(source: .touchHold), .none)
        XCTAssertTrue(policy.authenticationSucceeded(token: token))
        XCTAssertEqual(policy.state, .authenticatedRedacted)
        XCTAssertFalse(policy.hasContinuousRevealSource)
        XCTAssertFalse(policy.permitsTextMutation)

        XCTAssertEqual(policy.begin(source: .touchHold), .reveal)
        XCTAssertTrue(policy.beginPlaintextPresentation())
        XCTAssertEqual(policy.state, .presentingPlaintext)
        XCTAssertFalse(policy.permitsTextMutation)
        XCTAssertTrue(policy.confirmProtectedPlaintext())
        XCTAssertEqual(policy.state, .protectedPlaintext)
        XCTAssertTrue(policy.permitsTextMutation)

        XCTAssertEqual(policy.end(source: .touchHold), .redact)
        XCTAssertEqual(policy.state, .authenticatedRedacted)
        XCTAssertFalse(policy.permitsTextMutation)
    }

    func testStaleAuthenticationCannotCrossRebind() throws {
        var policy = SecureSnippetRevealPolicy()
        policy.bindSecure(
            rendererIsHealthy: true,
            appAndSceneAreActive: true,
            sceneCaptureIsInactive: true)
        let staleToken = try XCTUnwrap(policy.beginAuthentication())

        policy.bindSecure(
            rendererIsHealthy: true,
            appAndSceneAreActive: true,
            sceneCaptureIsInactive: true)

        XCTAssertFalse(policy.authenticationSucceeded(token: staleToken))
        XCTAssertEqual(policy.state, .locked)
        XCTAssertEqual(policy.begin(source: .touchHold), .none)
    }

    func testInactiveAppAndSceneCaptureImmediatelyRedactAndGateMutation() throws {
        var inactivePolicy = try makeRevealedPolicy()
        XCTAssertEqual(inactivePolicy.setAppAndSceneAreActive(false), .redact)
        XCTAssertEqual(inactivePolicy.state, .authenticatedRedacted)
        XCTAssertFalse(inactivePolicy.permitsTextMutation)

        var capturedPolicy = try makeRevealedPolicy()
        XCTAssertEqual(capturedPolicy.setSceneCaptureIsInactive(false), .redact)
        XCTAssertEqual(capturedPolicy.state, .authenticatedRedacted)
        XCTAssertTrue(capturedPolicy.isCaptureBlocked)
        XCTAssertFalse(capturedPolicy.permitsTextMutation)
        XCTAssertEqual(capturedPolicy.begin(source: .touchHold), .none)
    }

    func testMultipleContinuousSourcesRequireLastSourceToEnd() throws {
        var policy = try makeRevealedPolicy()
        XCTAssertEqual(policy.begin(source: .hover), .none)
        XCTAssertEqual(policy.end(source: .touchHold), .none)
        XCTAssertTrue(policy.permitsTextMutation)
        XCTAssertEqual(policy.end(source: .hover), .redact)
        XCTAssertFalse(policy.permitsTextMutation)
    }

    func testReleaseWhilePresentationIsPendingForcesRedaction() throws {
        var policy = SecureSnippetRevealPolicy()
        policy.bindSecure(
            rendererIsHealthy: true,
            appAndSceneAreActive: true,
            sceneCaptureIsInactive: true)
        let token = try XCTUnwrap(policy.beginAuthentication())
        XCTAssertTrue(policy.authenticationSucceeded(token: token))
        XCTAssertEqual(policy.begin(source: .touchHold), .reveal)
        XCTAssertTrue(policy.beginPlaintextPresentation())
        XCTAssertEqual(policy.state, .presentingPlaintext)
        XCTAssertFalse(policy.permitsTextMutation)

        XCTAssertEqual(policy.end(source: .touchHold), .redact)
        XCTAssertEqual(policy.state, .authenticatedRedacted)
        XCTAssertFalse(policy.confirmProtectedPlaintext())
        XCTAssertFalse(policy.permitsTextMutation)
    }

    func testHoverCancellationAndOutsideMovementAlwaysEnd() {
        XCTAssertEqual(
            SecureSnippetHoverIntent.resolve(gestureState: .began, locationIsInside: true),
            .begin)
        XCTAssertEqual(
            SecureSnippetHoverIntent.resolve(gestureState: .changed, locationIsInside: false),
            .end)
        XCTAssertEqual(
            SecureSnippetHoverIntent.resolve(gestureState: .cancelled, locationIsInside: true),
            .end)
        XCTAssertEqual(
            SecureSnippetHoverIntent.resolve(gestureState: .failed, locationIsInside: true),
            .end)
    }

    func testHoldControlEndsOnCancelAndDragExit() {
        let overlay = SecureSnippetRevealOverlayView()
        overlay.presentation = .authenticatedRedacted
        var events: [Bool] = []
        overlay.onHoldChanged = { events.append($0) }

        overlay.holdButton.sendActions(for: .touchDown)
        overlay.holdButton.sendActions(for: .touchCancel)
        overlay.holdButton.sendActions(for: .touchDown)
        overlay.holdButton.sendActions(for: .touchDragExit)

        XCTAssertEqual(events, [true, false, true, false])
    }

    func testSecureTextMutationIsGatedByProtectedPlaintextAndContinuousAuthorization() {
        let textView = makeTextView()
        textView.setSceneCaptureStateForTesting(.inactive)
        textView.setSecureForegroundActiveForTesting(true)
        XCTAssertTrue(textView.bindSecureRedacted())

        textView.insertText("blocked")
        textView.insertText(
            "blocked-alternative",
            alternatives: ["blocked"],
            style: .none)
        textView.insertAttributedText(NSAttributedString(string: "blocked-attributed"))
        textView.setMarkedText("blocked-ime", selectedRange: NSRange(location: 0, length: 0))
        textView.setAttributedMarkedText(
            NSAttributedString(string: "blocked-attributed-ime"),
            selectedRange: NSRange(location: 0, length: 0))
        let itemProvider = NSItemProvider(object: "blocked-provider" as NSString)
        XCTAssertFalse(textView.canPaste([itemProvider]))
        textView.paste(itemProviders: [itemProvider])
        textView.captureTextFromCamera(nil)
        let dictationPlaceholder = textView.insertDictationResultPlaceholder
        XCTAssertEqual(
            textView.frame(forDictationResultPlaceholder: dictationPlaceholder),
            .zero)
        textView.removeDictationResultPlaceholder(
            dictationPlaceholder,
            willInsertResult: true)
        textView.text = "blocked-programmatic"
        XCTAssertEqual(textView.text, "")

        textView.setSecurePlaintextAcceptanceAuthorized(true)
        textView.setSecureContinuousRevealAuthorized(true)
        XCTAssertTrue(textView.displaySecurePlaintext("body"))
        textView.insertText(" blocked")
        XCTAssertEqual(textView.text, "body")

        textView.setSecureEditingAuthorized(true)
        textView.selectedRange = NSRange(location: 4, length: 0)
        textView.insertText("!")
        textView.insertAttributedText(NSAttributedString(string: "?"))
        XCTAssertEqual(textView.text, "body!?")

        textView.setSecureEditingAuthorized(false)
        textView.deleteBackward()
        textView.paste(nil)
        textView.paste(itemProviders: [itemProvider])
        textView.captureTextFromCamera(nil)
        XCTAssertEqual(textView.text, "body!?")
    }

    func testOrdinaryTextMutationRemainsUnaffected() {
        let textView = makeTextView()
        textView.bindOrdinaryText("body")
        textView.selectedRange = NSRange(location: 4, length: 0)
        textView.insertText("!")
        XCTAssertEqual(textView.text, "body!")
        XCTAssertTrue(textView.permitsSecureTextMutation)
    }

    func testParkingViewPassesTouchesThroughOutsideHoldControl() {
        let parkingView = SecureHoldParkingView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let button = UIButton(frame: CGRect(x: 60, y: 520, width: 200, height: 52))
        parkingView.addSubview(button)
        parkingView.holdControl = button

        XCTAssertNil(parkingView.hitTest(CGPoint(x: 30, y: 200), with: nil))
        XCTAssertFalse(parkingView.point(inside: CGPoint(x: 30, y: 200), with: nil))
        XCTAssertTrue(parkingView.point(inside: CGPoint(x: 100, y: 540), with: nil))
        XCTAssertTrue(parkingView.hitTest(CGPoint(x: 100, y: 540), with: nil) === button)
    }

    func testRepeatedParkingReusesOneHoldConstraintSet() {
        let overlay = SecureSnippetRevealOverlayView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let parkingView = SecureHoldParkingView(frame: overlay.bounds)
        let expectedConstraintCount = overlay.activeHoldButtonConstraintCountForInspection
        XCTAssertGreaterThan(expectedConstraintCount, 0)

        for _ in 0..<3 {
            overlay.detachHoldButtonForParking()
            parkingView.addSubview(overlay.holdButton)
            parkingView.holdControl = overlay.holdButton
            XCTAssertEqual(overlay.activeHoldButtonConstraintCountForInspection, 0)

            parkingView.holdControl = nil
            overlay.reattachHoldButtonFromParking()
            XCTAssertEqual(
                overlay.activeHoldButtonConstraintCountForInspection,
                expectedConstraintCount)
            XCTAssertTrue(overlay.holdButton.superview === overlay)
        }
    }

    func testDetachedAndInactiveTextViewsRejectSecurePlaintext() {
        let detached = makeTextView()
        detached.setSceneCaptureStateForTesting(.inactive)
        XCTAssertTrue(detached.bindSecureRedacted())
        detached.setSecurePlaintextAcceptanceAuthorized(true)
        XCTAssertFalse(detached.canAcceptSecurePlaintext)
        XCTAssertFalse(detached.displaySecurePlaintext("detached sentinel"))
        XCTAssertEqual(detached.text, "")

        let inactive = makeTextView()
        inactive.setSceneCaptureStateForTesting(.inactive)
        inactive.setSecureForegroundActiveForTesting(false)
        XCTAssertTrue(inactive.bindSecureRedacted())
        inactive.setSecurePlaintextAcceptanceAuthorized(true)
        XCTAssertFalse(inactive.canAcceptSecurePlaintext)
        XCTAssertFalse(inactive.displaySecurePlaintext("inactive sentinel"))
        XCTAssertEqual(inactive.text, "")
    }

    private func makeRevealedPolicy() throws -> SecureSnippetRevealPolicy {
        var policy = SecureSnippetRevealPolicy()
        policy.bindSecure(
            rendererIsHealthy: true,
            appAndSceneAreActive: true,
            sceneCaptureIsInactive: true)
        let token = try XCTUnwrap(policy.beginAuthentication())
        XCTAssertTrue(policy.authenticationSucceeded(token: token))
        XCTAssertEqual(policy.begin(source: .touchHold), .reveal)
        XCTAssertTrue(policy.beginPlaintextPresentation())
        XCTAssertTrue(policy.confirmProtectedPlaintext())
        return policy
    }

    private func makeTextView() -> SecureSnippetTextView {
        let textView = SecureSnippetTextView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.secureCaptureBackgroundColor = .black
        textView.secureCaptureSurfaceView.frame = textView.bounds
        textView.layoutIfNeeded()
        return textView
    }
}
