import UIKit
import XCTest
@testable import Snippets

@MainActor
final class CloudEmailSignInViewControllerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmailScreenAppearsWithoutAnyNetworkRequest() {
        var requests = 0
        let controller = CloudEmailSignInViewController(
            sendCode: { _ in requests += 1; throw SnippetsCloudEmailSignInFailure.unavailable },
            verifyCode: { _ in XCTFail("Opening the sheet must not verify anything") },
            completed: { _ in XCTFail("Opening the sheet must not complete it") })
        controller.loadViewIfNeeded()
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(controller.emailField.isHidden)
        XCTAssertTrue(controller.codeField.isHidden)
        XCTAssertFalse(controller.primaryButton.isEnabled)
        XCTAssertEqual(controller.emailField.keyboardType, .emailAddress)
        XCTAssertEqual(controller.emailField.textContentType, .emailAddress)
        XCTAssertEqual(controller.codeField.textContentType, .oneTimeCode)
    }

    func testDuplicateSubmitIsDisabledAndCodePasteUsesNativeField() async {
        var requests = 0
        var sendContinuation: CheckedContinuation<SnippetsCloudEmailChallenge, Error>?
        var verifiedCode: String?
        var completions = 0
        let controller = CloudEmailSignInViewController(
            sendCode: { _ in
                requests += 1
                return try await withCheckedThrowingContinuation { sendContinuation = $0 }
            }, verifyCode: { verifiedCode = $0 }, now: { self.start },
            completed: { result in
                if case .failure = result { XCTFail("Valid code should complete sign-in") }
                completions += 1
            })
        controller.loadViewIfNeeded()
        controller.emailField.text = "tester@example.test"
        controller.refresh()
        controller.submit()
        controller.submit()
        await Task.yield()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(controller.isBusy)
        XCTAssertFalse(controller.primaryButton.isEnabled)
        sendContinuation?.resume(returning: challenge())
        await settle { controller.challenge != nil }
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.emailField.isHidden)
        XCTAssertFalse(controller.codeField.isHidden)
        XCTAssertFalse(controller.resendButton.isEnabled)
        XCTAssertFalse(controller.textField(controller.codeField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "123 456"))
        XCTAssertEqual(controller.codeField.text, "123456")
        XCTAssertTrue(controller.primaryButton.isEnabled)
        controller.submit()
        controller.submit()
        await settle { completions == 1 }
        XCTAssertEqual(verifiedCode, "123456")
        XCTAssertEqual(completions, 1)
    }

    func testCancelIgnoresAnInFlightSendResponseAndCompletesOnce() async {
        var sendContinuation: CheckedContinuation<SnippetsCloudEmailChallenge, Error>?
        var completions = 0
        let controller = CloudEmailSignInViewController(
            sendCode: { _ in try await withCheckedThrowingContinuation { sendContinuation = $0 } },
            verifyCode: { _ in XCTFail("Cancelled flow cannot verify") }, now: { self.start },
            completed: { result in
                completions += 1
                guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
                XCTAssertTrue(error is CancellationError)
            })
        controller.loadViewIfNeeded()
        controller.emailField.text = "tester@example.test"
        controller.refresh()
        controller.submit()
        await Task.yield()
        controller.cancel()
        controller.cancel()
        sendContinuation?.resume(returning: challenge())
        await Task.yield()
        XCTAssertEqual(completions, 1)
        XCTAssertNil(controller.challenge)
    }

    func testExpiredCodeRequiresResendAndEditEmailReturnsToEmailEntry() async {
        var current = start
        var requestedEmails: [String] = []
        let challenge = challenge()
        let controller = CloudEmailSignInViewController(
            sendCode: { email in requestedEmails.append(email); return challenge },
            verifyCode: { _ in XCTFail("Expired code cannot be submitted") }, now: { current }, completed: { _ in })
        controller.loadViewIfNeeded()
        controller.emailField.text = "tester@example.test"
        controller.refresh()
        controller.submit()
        await settle { controller.challenge != nil }
        current = start.addingTimeInterval(601)
        controller.codeField.text = "123456"
        controller.refresh()
        XCTAssertFalse(controller.primaryButton.isEnabled)
        XCTAssertTrue(controller.resendButton.isEnabled)
        controller.submit()
        controller.editEmail()
        XCTAssertNil(controller.challenge)
        XCTAssertFalse(controller.emailField.isHidden)
        XCTAssertEqual(controller.codeField.text, "")
        controller.emailField.text = "other@example.test"
        controller.refresh()
        controller.submit()
        await settle { requestedEmails.count == 2 }
        XCTAssertEqual(requestedEmails, ["tester@example.test", "other@example.test"])
    }

    func testServerRateLimitKeepsEmailAndHonorsRetryDelay() async {
        var current = start
        let controller = CloudEmailSignInViewController(
            sendCode: { _ in throw SnippetsCloudEmailSignInFailure.rateLimited(45) },
            verifyCode: { _ in XCTFail("No challenge was sent") }, now: { current }, completed: { _ in })
        controller.loadViewIfNeeded()
        controller.emailField.text = "tester@example.test"
        controller.refresh()
        controller.submit()
        await settle { !controller.isBusy }
        XCTAssertNil(controller.challenge)
        XCTAssertEqual(controller.emailField.text, "tester@example.test")
        XCTAssertFalse(controller.errorLabel.isHidden)
        XCTAssertFalse(controller.primaryButton.isEnabled)
        current = start.addingTimeInterval(46)
        controller.refresh()
        XCTAssertTrue(controller.primaryButton.isEnabled)
    }

    func testInvalidCodeStaysOnCodeScreenAndAllowsRetry() async {
        let challenge = challenge()
        var verificationCount = 0
        let controller = CloudEmailSignInViewController(
            sendCode: { _ in challenge },
            verifyCode: { _ in
                verificationCount += 1
                throw SnippetsCloudEmailSignInFailure.invalidCode
            }, now: { self.start }, completed: { _ in XCTFail("Invalid code must not finish") })
        controller.loadViewIfNeeded()
        controller.emailField.text = "tester@example.test"
        controller.refresh()
        controller.submit()
        await settle { controller.challenge != nil }
        controller.codeField.text = "123456"
        controller.refresh()
        controller.submit()
        await settle { !controller.isBusy }
        XCTAssertEqual(verificationCount, 1)
        XCTAssertNotNil(controller.challenge)
        XCTAssertFalse(controller.errorLabel.isHidden)
        XCTAssertTrue(controller.primaryButton.isEnabled)
        XCTAssertTrue(controller.editEmailButton.isEnabled)
    }

    func testServerExpiredCodeRequiresAReplacementEvenWhenLocalExpiryIsLater() async {
        let challenge = challenge()
        let controller = CloudEmailSignInViewController(
            sendCode: { _ in challenge },
            verifyCode: { _ in throw SnippetsCloudEmailSignInFailure.codeExpired },
            now: { self.start }, completed: { _ in XCTFail("Expired code cannot finish sign-in") })
        controller.loadViewIfNeeded()
        controller.emailField.text = "tester@example.test"
        controller.refresh()
        controller.submit()
        await settle { controller.challenge != nil }
        controller.codeField.text = "123456"
        controller.refresh()
        controller.submit()
        await settle { !controller.isBusy }
        XCTAssertFalse(controller.primaryButton.isEnabled)
        XCTAssertFalse(controller.errorLabel.isHidden)
        XCTAssertTrue(controller.editEmailButton.isEnabled)
    }

    func testCancelIgnoresALateVerificationSuccess() async {
        let challenge = challenge()
        var verifyContinuation: CheckedContinuation<Void, Error>?
        var completions = 0
        let controller = CloudEmailSignInViewController(
            sendCode: { _ in challenge },
            verifyCode: { _ in try await withCheckedThrowingContinuation { verifyContinuation = $0 } },
            now: { self.start }, completed: { result in
                completions += 1
                guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
                XCTAssertTrue(error is CancellationError)
            })
        controller.loadViewIfNeeded()
        controller.emailField.text = "tester@example.test"
        controller.refresh()
        controller.submit()
        await settle { controller.challenge != nil }
        controller.codeField.text = "123456"
        controller.refresh()
        controller.submit()
        await Task.yield()
        controller.cancel()
        verifyContinuation?.resume(returning: ())
        await Task.yield()
        XCTAssertEqual(completions, 1)
    }

    func testNativeScreensAtLargeTextSizesOnPhoneAndIPad() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 390, height: 844), CGSize(width: 480, height: 650)] {
            let challenge = challenge()
            let controller = CloudEmailSignInViewController(
                sendCode: { _ in challenge }, verifyCode: { _ in },
                now: { self.start }, automaticallyFocusInput: false, completed: { _ in })
            let navigation = UINavigationController(rootViewController: controller)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = navigation
            window.isHidden = false
            navigation.loadViewIfNeeded()
            navigation.view.frame = window.bounds
            controller.loadViewIfNeeded()
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            window.layoutIfNeeded()
            XCTAssertGreaterThan(controller.emailField.bounds.width, 0)
            attach(window, name: "Native email \(Int(size.width))pt large text")
            controller.emailField.text = "tester@example.test"
            controller.refresh()
            controller.submit()
            await settle { controller.challenge != nil }
            window.layoutIfNeeded()
            XCTAssertGreaterThan(controller.codeField.bounds.width, 0)
            XCTAssertLessThanOrEqual(controller.codeField.bounds.width, size.width)
            attach(window, name: "Native code \(Int(size.width))pt large text")
            controller.cancel()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func challenge() -> SnippetsCloudEmailChallenge {
        SnippetsCloudEmailChallenge(email: "tester@example.test",
            expiresAt: start.addingTimeInterval(600),
            resendAvailableAt: start.addingTimeInterval(60), codeLength: 6)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }
}
