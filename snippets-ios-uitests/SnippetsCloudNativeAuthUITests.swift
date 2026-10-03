import Foundation
import XCTest

/// Run only against an explicitly configured local test stack and a disposable app.
/// Ordinary UI smoke runs skip this networked integration test. Use a disposable
/// simulator and an ad hoc signed app: real Keychain access needs the simulator's
/// Mach-O application-identifier/keychain entitlements, unlike in-memory unit tests.
/// Set SNIPPETS_NATIVE_AUTH_E2E=1 in the test runner environment.
///
/// The test creates a disposable account, reads its generated key from the save
/// screen into memory only, and then signs in with that key through Change Account.
/// The key is never written to a fixture, file, or log by this test.
final class SnippetsCloudNativeAuthUITests: XCTestCase {
    @MainActor
    func testNativeAccountKeyCreatesAccountAndSignsInWithoutBrowserOrSyncingLibrary() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SNIPPETS_NATIVE_AUTH_E2E"] == "1",
            "Native auth integration requires the opt-in disposable test environment.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-native-cloud-auth"]
        app.launch()

        openSnippetsCloudAccount(in: app)
        let signIn = app.cells.containing(.staticText, identifier: "Create account or sign in").firstMatch
        try require(signIn, timeout: 5, message: "Cloud account sign-in action must be available")
        signIn.tap()

        let create = app.buttons["cloudSignInCreateAccount"]
        try require(create, timeout: 5, message: "The native choice must open before networking")
        XCTAssertTrue(app.buttons["cloudSignInUseAccountKey"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        app.buttons["cloudSignInCancel"].tap()
        XCTAssertFalse(create.exists)
        XCTAssertEqual(app.alerts.count, 0, "Cancelling before any request must not show a failure")

        // A locally mistyped key is rejected inline and never sent.
        signIn.tap()
        XCTAssertTrue(app.buttons["cloudSignInUseAccountKey"].waitForExistence(timeout: 5))
        app.buttons["cloudSignInUseAccountKey"].tap()
        let keyField = app.textFields["cloudSignInAccountKey"]
        try require(keyField, timeout: 5, message: "Sign In with Account Key must show one key field")
        keyField.tap()
        // ADR 0006 test vector with a wrong check symbol.
        keyField.typeText("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ8")
        app.buttons["cloudSignInSubmit"].tap()
        let error = app.staticTexts["cloudSignInError"]
        try require(error, timeout: 5, message: "A local typo must show an inline error")
        XCTAssertEqual(error.label, "This isn’t a valid account key. Check it for typos.")
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["cloudSignInBack"].tap()

        // Create a disposable account. The key is shown once for saving.
        try require(create, timeout: 5, message: "Back must return to the account choice")
        create.tap()
        let keyValue = app.textViews["cloudAccountKeyValue"]
        try require(keyValue, timeout: 30, message: "Account creation must show Save Your Account Key")
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertFalse(app.buttons["cloudSignInCancel"].exists,
            "Only the explicit acknowledgement may leave the save screen")
        let displayedKey = try XCTUnwrap(keyValue.value as? String)
        XCTAssertEqual(displayedKey.count, 34, "The display form is seven groups of four")
        app.buttons["cloudAccountKeySaved"].tap()

        let switchConfirmation = app.alerts["Switch Sync to Snippets Cloud?"]
        try require(switchConfirmation, timeout: 30,
            message: "Account creation and encrypted library setup must ask before switching sync")
        switchConfirmation.buttons["Cancel"].tap()

        // Sign in to the same account with the saved key. The account page refreshes
        // after sign-in and now shows the short Account ID instead of sign-in actions.
        let accountID = app.staticTexts.matching(NSPredicate(
            format: "label MATCHES %@", "Account ID [0-9A-F]{4}-[0-9A-F]{4}")).firstMatch
        try require(accountID, timeout: 10, message: "A signed-in account shows its short Account ID")
        let changeAccount = app.cells.containing(.staticText, identifier: "Change account").firstMatch
        try require(changeAccount, timeout: 10, message: "A signed-in account must offer Change account")
        XCTAssertTrue(app.cells.containing(.staticText, identifier: "Show account key").firstMatch.exists)
        changeAccount.tap()
        let chooseAnother = app.alerts.buttons["Choose Another Account"]
        try require(chooseAnother, timeout: 5, message: "Change account must confirm first")
        chooseAnother.tap()
        try require(app.buttons["cloudSignInUseAccountKey"], timeout: 5,
            message: "Change account must open the native choice")
        app.buttons["cloudSignInUseAccountKey"].tap()
        try require(keyField, timeout: 5, message: "Sign In with Account Key must show the key field")
        keyField.tap()
        keyField.typeText(displayedKey.lowercased())
        app.buttons["cloudSignInSubmit"].tap()

        try require(app.alerts["Switch Sync to Snippets Cloud?"], timeout: 30,
            message: "Signing in with the saved key must reconnect the same library")
        XCTAssertEqual(app.webViews.count, 0)
        app.alerts["Switch Sync to Snippets Cloud?"].buttons["Cancel"].tap()
        XCTAssertFalse(keyField.exists)
        // Deliberately leave iCloud as the provider. This test verifies auth and
        // bootstrap; it must not upload any library as part of signing in.
    }

    @MainActor
    private func openSnippetsCloudAccount(in app: XCUIApplication) {
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
        XCTAssertTrue(cloud.waitForExistence(timeout: 5), "Native cloud provider must be available")
        cloud.tap()
    }

    @MainActor
    private func require(_ element: XCUIElement, timeout: TimeInterval, message: String) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail(message)
            throw Failure.missingElement
        }
    }

    private enum Failure: Error { case missingElement }
}
