import UIKit
import XCTest
@testable import Snippets

@MainActor
final class CloudAccountKeySignInViewControllerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// ADR 0006 test vector; a fixture only, never a real account key.
    private let fixtureKey = SnippetsCloudAccountKey(canonical: "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7")!

    func testChoiceScreenAppearsWithoutAnyNetworkRequest() {
        var requests = 0
        let controller = CloudAccountKeySignInViewController(
            createAccount: { requests += 1; throw SnippetsCloudAccountKeySignInFailure.unavailable },
            signIn: { _ in requests += 1 },
            completed: { _ in XCTFail("Opening the sheet must not complete it") })
        controller.loadViewIfNeeded()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(controller.step, .choose)
        XCTAssertTrue(controller.keyField.isHidden)
        XCTAssertTrue(controller.keyDisplay.isHidden)
        XCTAssertTrue(controller.primaryButton.isEnabled)
        XCTAssertEqual(controller.primaryButton.title(for: .normal), "Create Account")
        XCTAssertEqual(controller.primaryButton.accessibilityIdentifier, "cloudSignInCreateAccount")
        XCTAssertEqual(controller.secondaryButton.title(for: .normal), "Sign In with Account Key")
        XCTAssertEqual(controller.secondaryButton.accessibilityIdentifier, "cloudSignInUseAccountKey")
    }

    func testCreateAccountShowsKeyOnceAndFinishesOnlyAfterAcknowledgement() async {
        var requests = 0
        var createContinuation: CheckedContinuation<SnippetsCloudAccountKey, Error>?
        var copied: [String] = []
        var completions = 0
        let controller = CloudAccountKeySignInViewController(
            createAccount: {
                requests += 1
                return try await withCheckedThrowingContinuation { createContinuation = $0 }
            },
            signIn: { _ in XCTFail("Create must not send a key") },
            copyKey: { copied.append($0.displayForm) },
            now: { self.start },
            completed: { result in
                if case .failure = result { XCTFail("Acknowledgement should complete setup") }
                completions += 1
            })
        controller.loadViewIfNeeded()
        controller.submit()
        controller.submit()
        await Task.yield()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(controller.isBusy)
        XCTAssertFalse(controller.primaryButton.isEnabled)
        createContinuation?.resume(returning: fixtureKey)
        await settle { controller.step == .saveKey }
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.keyDisplay.isHidden)
        XCTAssertEqual(controller.keyDisplay.keyTextView.text, "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7")
        XCTAssertFalse(controller.keyDisplay.keyTextView.isEditable)
        XCTAssertTrue(controller.keyDisplay.keyTextView.isSelectable)
        XCTAssertEqual(controller.primaryButton.title(for: .normal), "I’ve Saved It")
        XCTAssertTrue(controller.secondaryButton.isHidden)
        XCTAssertEqual(completions, 0, "Showing the key must not continue setup")

        // Cancel is unavailable while the key is on screen.
        controller.cancel()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(controller.step, .saveKey)

        controller.keyDisplay.copyKey()
        controller.keyDisplay.keyTextView.copy(nil)
        XCTAssertEqual(copied, ["7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7", "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7"])
        XCTAssertFalse(controller.keyDisplay.copiedLabel.isHidden)

        controller.submit()
        controller.submit()
        XCTAssertEqual(completions, 1)
        XCTAssertNil(controller.keyDisplay.keyTextView.text.nilIfEmpty, "The key is cleared when the sheet finishes")
    }

    func testSecretTextViewOffersOnlyCopyAndSelection() {
        let view = CloudSecretTextView()
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(NSSelectorFromString("_share:"), withSender: nil))
        XCTAssertFalse(view.canPerformAction(NSSelectorFromString("_define:"), withSender: nil))
        XCTAssertEqual(view.textDragInteraction?.isEnabled, false)
    }

    func testAccountKeyClipboardFollowsRecoveryKitRules() throws {
        let options = CloudSecretPasteboard.options(now: start)
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        XCTAssertEqual(options[.expirationDate] as? Date, start.addingTimeInterval(120))
        let pasteboard = try XCTUnwrap(UIPasteboard.withUniqueName())
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        CloudSecretPasteboard.copy(fixtureKey.displayForm, to: pasteboard, now: Date())
        XCTAssertEqual(pasteboard.string, "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7")
    }

    func testSignInRejectsTyposLocallyAndSendsOnlyAfterValidation() async {
        var submitted: [String] = []
        var completions = 0
        let controller = CloudAccountKeySignInViewController(
            createAccount: { XCTFail("Sign-in must not create an account"); throw CancellationError() },
            signIn: { submitted.append($0) },
            now: { self.start },
            automaticallyFocusInput: false,
            completed: { result in
                if case .failure = result { XCTFail("A valid key should complete sign-in") }
                completions += 1
            })
        controller.loadViewIfNeeded()
        controller.secondaryAction()
        XCTAssertEqual(controller.step, .signIn)
        XCTAssertFalse(controller.keyField.isHidden)
        XCTAssertFalse(controller.primaryButton.isEnabled, "An empty field cannot submit")
        XCTAssertEqual(controller.keyField.autocorrectionType, .no)
        XCTAssertEqual(controller.keyField.spellCheckingType, .no)
        XCTAssertEqual(controller.keyField.textContentType, .password)

        controller.keyField.text = "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ8"
        controller.refresh()
        XCTAssertTrue(controller.primaryButton.isEnabled)
        controller.submit()
        await Task.yield()
        XCTAssertTrue(submitted.isEmpty, "A locally invalid key is never sent")
        XCTAssertFalse(controller.errorLabel.isHidden)
        XCTAssertEqual(controller.errorLabel.text, "This isn’t a valid account key. Check it for typos.")

        controller.keyField.text = " 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-iaq7 "
        controller.refresh()
        controller.submit()
        controller.submit()
        await settle { completions == 1 }
        XCTAssertEqual(submitted, [" 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-iaq7 "])
        XCTAssertNil(controller.keyField.text?.nilIfEmpty, "The typed key is cleared on completion")
    }

    func testServerRejectionStaysOnKeyEntryAndAllowsRetry() async {
        var attempts = 0
        let controller = CloudAccountKeySignInViewController(
            createAccount: { throw CancellationError() },
            signIn: { _ in
                attempts += 1
                throw SnippetsCloudAccountKeySignInFailure.accountKeyNotAccepted
            },
            now: { self.start }, automaticallyFocusInput: false,
            completed: { _ in XCTFail("A rejected key must not finish") })
        controller.loadViewIfNeeded()
        controller.secondaryAction()
        controller.keyField.text = fixtureKey.displayForm
        controller.refresh()
        controller.submit()
        await settle { attempts == 1 && !controller.isBusy }
        XCTAssertEqual(controller.step, .signIn)
        XCTAssertEqual(controller.errorLabel.text, "That account key wasn’t accepted. Check it and try again.")
        XCTAssertTrue(controller.primaryButton.isEnabled)
        controller.secondaryAction()
        XCTAssertEqual(controller.step, .choose)
        XCTAssertEqual(controller.keyField.text, "")
    }

    func testServerRateLimitHonorsRetryDelay() async {
        var current = start
        let controller = CloudAccountKeySignInViewController(
            createAccount: { throw SnippetsCloudAccountKeySignInFailure.rateLimited(45) },
            signIn: { _ in XCTFail("No key was entered") },
            now: { current }, completed: { _ in })
        controller.loadViewIfNeeded()
        controller.submit()
        await settle { !controller.isBusy }
        XCTAssertEqual(controller.step, .choose)
        XCTAssertFalse(controller.errorLabel.isHidden)
        XCTAssertEqual(controller.errorLabel.text, "Please wait before trying again.")
        XCTAssertFalse(controller.primaryButton.isEnabled)
        current = start.addingTimeInterval(46)
        controller.refresh()
        XCTAssertTrue(controller.primaryButton.isEnabled)
    }

    func testCancelIgnoresInFlightCreationAndCompletesOnce() async {
        var createContinuation: CheckedContinuation<SnippetsCloudAccountKey, Error>?
        var completions = 0
        let controller = CloudAccountKeySignInViewController(
            createAccount: { try await withCheckedThrowingContinuation { createContinuation = $0 } },
            signIn: { _ in XCTFail("Cancelled flow cannot sign in") }, now: { self.start },
            completed: { result in
                completions += 1
                guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
                XCTAssertTrue(error is CancellationError)
            })
        controller.loadViewIfNeeded()
        controller.submit()
        await Task.yield()
        controller.cancel()
        controller.cancel()
        createContinuation?.resume(returning: fixtureKey)
        await Task.yield()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(controller.step, .choose)
        XCTAssertNil(controller.keyDisplay.key)
    }

    func testCancelIgnoresALateSignInSuccess() async {
        var signInContinuation: CheckedContinuation<Void, Error>?
        var completions = 0
        let controller = CloudAccountKeySignInViewController(
            createAccount: { throw CancellationError() },
            signIn: { _ in try await withCheckedThrowingContinuation { signInContinuation = $0 } },
            now: { self.start }, automaticallyFocusInput: false, completed: { result in
                completions += 1
                guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
                XCTAssertTrue(error is CancellationError)
            })
        controller.loadViewIfNeeded()
        controller.secondaryAction()
        controller.keyField.text = fixtureKey.canonical
        controller.refresh()
        controller.submit()
        await Task.yield()
        controller.cancel()
        signInContinuation?.resume(returning: ())
        await Task.yield()
        XCTAssertEqual(completions, 1)
    }

    // MARK: ADR 0007 Sign In with Another Device

    private func devicePresentation() throws -> SnippetsCloudDeviceSignInPresentation {
        let draft = LibraryKeyBootstrap.PairingDraft()
        let request = try LibraryKeyBootstrap.DeviceSignInRequest(
            serverURL: XCTUnwrap(URL(string: "https://sync.example.test")), requestID: UUID(),
            nonce: draft.nonce, recipientPublicKey: draft.recipientPublicKey,
            expiresAtEpochSeconds: Int64(start.timeIntervalSince1970) + 600,
            nowEpochSeconds: Int64(start.timeIntervalSince1970))
        return .init(qrPayload: try request.qrPayload(), confirmationCode: request.confirmationCode,
            expiresAt: start.addingTimeInterval(600))
    }

    func testAnotherDeviceIsOfferedOnlyAfterDiscoveryConfirmsIt() async {
        var probes = 0
        for available in [false, true] {
            let controller = CloudAccountKeySignInViewController(
                createAccount: { XCTFail("No account is created"); throw CancellationError() },
                signIn: { _ in XCTFail("No key is sent") },
                deviceSignIn: .init(
                    isAvailable: { probes += 1; return available },
                    begin: { XCTFail("Opening the sheet must not open a request"); throw CancellationError() },
                    waitForApproval: { _ in }, discard: {}),
                now: { self.start }, completed: { _ in XCTFail("The sheet stays open") })
            controller.loadViewIfNeeded()
            XCTAssertTrue(controller.deviceButton.isHidden, "Hidden until discovery answers")
            controller.probeDeviceSignInAvailability()
            await settle { controller.deviceSignInAvailable == available && probes > 0 }
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(controller.deviceButton.isHidden, !available)
            probes = 0
        }
    }

    func testAnotherDeviceShowsQRCodeAndCountdownThenFinishesOnApproval() async throws {
        let presentation = try devicePresentation()
        var approval: CheckedContinuation<Void, Error>?
        var waitedUntil: Date?
        var completions = 0
        let controller = CloudAccountKeySignInViewController(
            createAccount: { XCTFail("No account is created"); throw CancellationError() },
            signIn: { _ in XCTFail("No key is sent") },
            deviceSignIn: .init(
                isAvailable: { true },
                begin: { presentation },
                waitForApproval: { expiresAt in
                    waitedUntil = expiresAt
                    try await withCheckedThrowingContinuation { approval = $0 }
                },
                discard: { XCTFail("An approved request is not discarded by the sheet") }),
            now: { self.start.addingTimeInterval(65) },
            completed: { result in
                if case .failure = result { XCTFail("Approval completes sign-in") }
                completions += 1
            })
        controller.loadViewIfNeeded()
        controller.probeDeviceSignInAvailability()
        await settle { controller.deviceSignInAvailable }
        controller.startDeviceSignIn()
        await settle { controller.step == .deviceSignIn && approval != nil }
        XCTAssertEqual(waitedUntil, presentation.expiresAt)
        XCTAssertNotNil(controller.deviceQRView.image)
        XCTAssertFalse(controller.deviceQRView.isHidden)
        XCTAssertEqual(controller.deviceCodeLabel.text, "Confirmation code: \(presentation.confirmationCode)")
        XCTAssertEqual(controller.deviceStatusLabel.text, "Waiting for approval… 08:55")
        XCTAssertTrue(controller.primaryButton.isHidden)
        XCTAssertFalse(controller.copyRequestButton.isHidden)
        XCTAssertEqual(controller.secondaryButton.title(for: .normal), "Back")
        approval?.resume()
        await settle { completions == 1 }
        XCTAssertEqual(completions, 1)
    }

    func testBackOrAFinalClaimAnswerDiscardsTheRequestAndReturnsToTheChoice() async throws {
        let presentation = try devicePresentation()
        var discards = 0
        var failWait: CheckedContinuation<Void, Error>?
        let controller = CloudAccountKeySignInViewController(
            createAccount: { XCTFail("No account is created"); throw CancellationError() },
            signIn: { _ in XCTFail("No key is sent") },
            deviceSignIn: .init(
                isAvailable: { true },
                begin: { presentation },
                waitForApproval: { _ in try await withCheckedThrowingContinuation { failWait = $0 } },
                discard: { discards += 1 }),
            now: { self.start }, completed: { _ in XCTFail("The sheet stays open") })
        controller.loadViewIfNeeded()
        controller.probeDeviceSignInAvailability()
        await settle { controller.deviceSignInAvailable }
        controller.startDeviceSignIn()
        await settle { controller.step == .deviceSignIn && failWait != nil }
        controller.secondaryAction()
        XCTAssertEqual(controller.step, .choose)
        XCTAssertEqual(discards, 1)
        XCTAssertNil(controller.devicePresentation)
        failWait?.resume(throwing: CancellationError())
        failWait = nil

        controller.startDeviceSignIn()
        await settle { controller.step == .deviceSignIn && failWait != nil }
        failWait?.resume(throwing: SnippetsCloudAccountKeySignInFailure.deviceSignInExpired)
        await settle { controller.step == .choose }
        XCTAssertEqual(controller.errorLabel.text, "This sign-in request expired. Start again to show a new code.")
        XCTAssertEqual(discards, 2)
        XCTAssertFalse(controller.deviceButton.isHidden)
    }

    func testRevealScreenShowsSelectableDisplayForm() {
        let controller = CloudAccountKeyRevealViewController(key: fixtureKey)
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.keyDisplay.keyTextView.text, "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7")
        XCTAssertTrue(controller.keyDisplay.keyTextView.isSelectable)
        XCTAssertEqual(controller.keyDisplay.keyTextView.accessibilityIdentifier, "cloudAccountKeyValue")
        XCTAssertEqual(controller.title, "Account Key")
    }

    func testNativeScreensAtLargeTextSizesOnPhoneAndIPad() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 390, height: 844), CGSize(width: 480, height: 650)] {
            let key = fixtureKey
            let controller = CloudAccountKeySignInViewController(
                createAccount: { key }, signIn: { _ in },
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
            XCTAssertGreaterThan(controller.primaryButton.bounds.width, 0)
            attach(window, name: "Account choice \(Int(size.width))pt large text")
            controller.secondaryAction()
            window.layoutIfNeeded()
            XCTAssertGreaterThan(controller.keyField.bounds.width, 0)
            XCTAssertLessThanOrEqual(controller.keyField.bounds.width, size.width)
            attach(window, name: "Account key entry \(Int(size.width))pt large text")
            controller.secondaryAction()
            controller.submit()
            await settle { controller.step == .saveKey }
            window.layoutIfNeeded()
            XCTAssertGreaterThan(controller.keyDisplay.keyTextView.bounds.width, 0)
            XCTAssertLessThanOrEqual(controller.keyDisplay.keyTextView.bounds.width, size.width)
            attach(window, name: "Save account key \(Int(size.width))pt large text")
            controller.acknowledgeSavedKey()
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

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
