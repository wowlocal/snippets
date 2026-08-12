import UIKit
import XCTest
@testable import Snippets

@MainActor
final class SecureSnippetRevealTests: XCTestCase {
    func testAuthenticationStartsProtectedEditableRevealSession() throws {
        var policy = SecureSnippetRevealPolicy()
        policy.bindSecure(
            rendererIsHealthy: true,
            appAndSceneAreActive: true,
            sceneCaptureIsInactive: true)

        let token = try XCTUnwrap(policy.beginAuthentication())
        XCTAssertTrue(policy.authenticationSucceeded(token: token))
        XCTAssertEqual(policy.state, .authenticatedRedacted)
        XCTAssertFalse(policy.permitsTextMutation)

        XCTAssertEqual(policy.beginAuthenticatedReveal(), .reveal)
        XCTAssertTrue(policy.beginPlaintextPresentation())
        XCTAssertEqual(policy.state, .presentingPlaintext)
        XCTAssertFalse(policy.permitsTextMutation)
        XCTAssertTrue(policy.confirmProtectedPlaintext())
        XCTAssertEqual(policy.state, .protectedPlaintext)
        XCTAssertTrue(policy.permitsTextMutation)

        XCTAssertEqual(policy.cancelReveal(), .redact)
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
        XCTAssertEqual(policy.beginAuthenticatedReveal(), .none)
    }

    func testTransientBiometricDeactivationPreservesOnlyRedactedAuthentication() throws {
        var policy = SecureSnippetRevealPolicy()
        policy.bindSecure(
            rendererIsHealthy: true,
            appAndSceneAreActive: true,
            sceneCaptureIsInactive: true)
        let token = try XCTUnwrap(policy.beginAuthentication())

        XCTAssertEqual(policy.setAppAndSceneAreActive(false), .none)
        XCTAssertEqual(policy.state, .authenticating)
        XCTAssertTrue(policy.authenticationSucceeded(token: token))
        XCTAssertEqual(policy.state, .authenticatedRedacted)
        XCTAssertEqual(policy.beginAuthenticatedReveal(), .none)
        XCTAssertFalse(policy.permitsTextMutation)

        XCTAssertEqual(policy.setAppAndSceneAreActive(true), .none)
        XCTAssertEqual(policy.beginAuthenticatedReveal(), .reveal)
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
        XCTAssertEqual(capturedPolicy.beginAuthenticatedReveal(), .none)
    }

    func testFocusLossWhilePresentationIsPendingForcesRedaction() throws {
        var policy = SecureSnippetRevealPolicy()
        policy.bindSecure(
            rendererIsHealthy: true,
            appAndSceneAreActive: true,
            sceneCaptureIsInactive: true)
        let token = try XCTUnwrap(policy.beginAuthentication())
        XCTAssertTrue(policy.authenticationSucceeded(token: token))
        XCTAssertEqual(policy.beginAuthenticatedReveal(), .reveal)
        XCTAssertTrue(policy.beginPlaintextPresentation())
        XCTAssertEqual(policy.state, .presentingPlaintext)
        XCTAssertFalse(policy.permitsTextMutation)

        XCTAssertEqual(policy.cancelReveal(), .redact)
        XCTAssertEqual(policy.state, .authenticatedRedacted)
        XCTAssertFalse(policy.confirmProtectedPlaintext())
        XCTAssertFalse(policy.permitsTextMutation)
    }

    func testSecureTextMutationIsGatedByProtectedPlaintextSessionAuthorization() {
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
        textView.setSecureRevealSessionAuthorized(true)
        XCTAssertTrue(textView.displaySecurePlaintext("body"))
        textView.insertText(" blocked")
        XCTAssertEqual(textView.text, "body")

        textView.setSecureEditingAuthorized(true)
        textView.selectedRange = NSRange(location: 4, length: 0)
        textView.insertText("!")
        textView.insertAttributedText(NSAttributedString(string: "?"))
        XCTAssertEqual(textView.text, "body!?")

        textView.selectedRange = NSRange(location: 4, length: 2)
        textView.delete(nil)
        XCTAssertEqual(
            textView.text,
            "body",
            "the edit-menu Delete action must mutate through UITextInput without forwarding an unsupported selector")

        textView.setSecureEditingAuthorized(false)
        textView.deleteBackward()
        textView.paste(nil)
        textView.paste(itemProviders: [itemProvider])
        textView.captureTextFromCamera(nil)
        XCTAssertEqual(textView.text, "body")
    }

    func testTransparentSecureEditorRemainsTouchHitTestable() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let textView = makeTextView()
        host.addSubview(textView)
        textView.setSceneCaptureStateForTesting(.inactive)
        textView.setSecureForegroundActiveForTesting(true)
        XCTAssertTrue(textView.bindSecureRedacted())
        XCTAssertTrue(textView.nativePlaintextLayerSuppressedForInspection)

        XCTAssertTrue(
            host.hitTest(CGPoint(x: 100, y: 80), with: nil) === textView,
            "protected AV rendering must not remove the UITextView from touch hit-testing")
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
        XCTAssertEqual(policy.beginAuthenticatedReveal(), .reveal)
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
