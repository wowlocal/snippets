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
        textView.text = "blocked-programmatic"
        XCTAssertEqual(textView.text, "")

        textView.setSecurePlaintextAcceptanceAuthorized(true)
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
