import Foundation
import XCTest

/// Run only against an explicitly configured local test stack and a disposable app.
/// Ordinary UI smoke runs skip this networked integration test. Use a disposable
/// simulator and an ad hoc signed app: real Keychain access needs the simulator's
/// Mach-O application-identifier/keychain entitlements, unlike in-memory unit tests.
/// Set SNIPPETS_NATIVE_AUTH_E2E=1 in the test runner environment; the mailbox must
/// be the host's local Mailpit instance (SNIPPETS_NATIVE_AUTH_MAILBOX).
final class SnippetsCloudNativeAuthUITests: XCTestCase {
    @MainActor
    func testNativeEmailCodeConnectsAccountWithoutBrowserOrSyncingLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SNIPPETS_NATIVE_AUTH_E2E"] == "1",
            "Native auth integration requires the opt-in disposable test environment.")
        let mailbox = try XCTUnwrap(URL(string: environment["SNIPPETS_NATIVE_AUTH_MAILBOX"] ?? "http://127.0.0.1:8027"))
        try XCTSkipUnless(["127.0.0.1", "localhost"].contains(mailbox.host ?? ""),
            "The integration test reads codes only from a local test mailbox.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-native-cloud-auth"]
        app.launch()
        let email = "native-ui-\(UUID().uuidString.lowercased())@example.test"

        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let search = app.searchFields["settings-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("cloud provider")
        let syncResult = app.cells["settings-search-cloudProvider"]
        XCTAssertTrue(syncResult.waitForExistence(timeout: 5))
        syncResult.tap()
        let provider = app.cells.containing(.staticText, identifier: "Cloud Provider").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
        let cloud = app.buttons["Snippets Cloud…"].firstMatch
        try require(cloud, timeout: 5, message: "Native cloud provider must be available")
        cloud.tap()
        let signIn = app.cells.containing(.staticText, identifier: "Sign in to Snippets Cloud").firstMatch
        try require(signIn, timeout: 5, message: "Cloud account sign-in action must be available")
        signIn.tap()

        let emailField = app.textFields["cloudSignInEmail"]
        try require(emailField, timeout: 5, message: "The native form must open before networking")
        XCTAssertEqual(app.webViews.count, 0)
        app.buttons["cloudSignInCancel"].tap()
        XCTAssertFalse(emailField.exists)
        XCTAssertEqual(app.alerts.count, 0, "Cancelling before email entry must not show a failure")
        signIn.tap()
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText(email)
        let submit = app.buttons["cloudSignInSubmit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let codeField = app.textFields["cloudSignInCode"]
        try require(codeField, timeout: 30, message: "Code delivery must open the native code field")
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertFalse(app.buttons["cloudSignInResend"].isEnabled)
        let code = try await verificationCode(to: email, mailbox: mailbox)
        codeField.tap()
        codeField.typeText(code == "000000" ? "000001" : "000000")
        submit.tap()
        let error = app.staticTexts["cloudSignInError"]
        try require(error, timeout: 30, message: "An incorrect code must show a native inline error")
        XCTAssertTrue(codeField.exists)
        XCTAssertEqual(app.alerts.count, 0)
        codeField.tap()
        codeField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + code)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        let switchConfirmation = app.alerts["Switch Sync to Snippets Cloud?"]
        try require(switchConfirmation, timeout: 30,
            message: "Verified sign-in and encrypted library setup must ask before switching sync")
        XCTAssertEqual(app.webViews.count, 0)
        switchConfirmation.buttons["Cancel"].tap()
        XCTAssertFalse(app.textFields["cloudSignInCode"].exists)
        // Deliberately leave iCloud as the provider. This test verifies auth and
        // bootstrap; it must not upload any library as part of signing in.
    }

    @MainActor
    private func require(_ element: XCUIElement, timeout: TimeInterval, message: String) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail(message)
            throw Failure.missingElement
        }
    }

    private func verificationCode(to email: String, mailbox: URL) async throws -> String {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let (data, response) = try await URLSession.shared.data(from: mailbox.appending(path: "api/v1/messages"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.mailboxUnavailable }
            let messages = try JSONDecoder().decode(MessageList.self, from: data)
            if let message = messages.messages.first(where: { $0.To.contains { $0.Address.lowercased() == email } }) {
                let (body, response) = try await URLSession.shared.data(from: mailbox.appending(path: "api/v1/message/\(message.ID)"))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.mailboxUnavailable }
                let text = try JSONDecoder().decode(Message.self, from: body).Text
                if let range = text.range(of: #"(?<![0-9])[0-9]{6}(?![0-9])"#, options: .regularExpression) {
                    return String(text[range])
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure.codeNotDelivered
    }

    private enum Failure: Error { case mailboxUnavailable, codeNotDelivered, missingElement }
    private struct MessageList: Decodable { let messages: [Summary] }
    private struct Summary: Decodable { let ID: String; let To: [Address] }
    private struct Address: Decodable { let Address: String }
    private struct Message: Decodable { let Text: String }
}
