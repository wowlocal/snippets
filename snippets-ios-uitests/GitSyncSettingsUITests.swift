import Foundation
import XCTest

/// Drives Settings → Sync → Git Repository on iPhone against a disposable loopback
/// repository served by `scripts/git-http-test-server.py`. Opt-in: ordinary UI smoke
/// runs skip it. `scripts/test-git-sync-integration.sh` passes the coordinates through
/// `TEST_RUNNER_SNIPPETS_GIT_UI_E2E_*`, then reads the copied recovery code from the
/// simulator pasteboard and has a fresh macOS installation join the same library. The
/// code it reads is the one Replace Keys showed last, so that join also proves the
/// replaced library opens with its new code.
///
/// `--ui-testing-reset` keeps the Git key and token in memory and permits loopback
/// HTTP for this launch only.
final class GitSyncSettingsUITests: XCTestCase {
    static let snippetName = "Git UI Greeting"
    static let snippetContent = "Hello from the Git settings UI 4c9e"

    @MainActor
    func testConnectingAnEmptyRepositoryCreatesTheLibrarySwitchesSyncAndReplacesItsKeys() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["SNIPPETS_GIT_UI_E2E_URL"],
              let username = environment["SNIPPETS_GIT_UI_E2E_USERNAME"],
              let token = environment["SNIPPETS_GIT_UI_E2E_TOKEN"] else {
            throw XCTSkip("Git UI integration runs only from scripts/test-git-sync-integration.sh")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Replacing the keys unlocks the library's vault; the simulator has no passcode
        // to do that with.
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-authentication-succeeds"]
        app.launch()

        // One snippet, so Switch and Sync has something to upload.
        let create = app.buttons["phone-new-snippet"]
        try XCTSkipUnless(create.waitForExistence(timeout: 10), "This test covers the iPhone root controller")
        create.tap()
        let content = app.textViews["snippet-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        content.tap()
        content.typeText(Self.snippetContent)
        let name = app.textFields["snippet-name"]
        name.tap()
        name.typeText(Self.snippetName)
        app.navigationBars.buttons["Snippets"].tap()
        XCTAssertTrue(app.staticTexts[Self.snippetName].waitForExistence(timeout: 5))

        openGitRepository(in: app)
        fill(app.textFields["git-repository-url"], with: url)
        let branch = app.textFields["git-branch"]
        XCTAssertEqual(branch.value as? String, "main")
        fill(app.textFields["git-username"], with: username)
        fill(app.secureTextFields["git-token"], with: token)
        app.cells["git-connect"].tap()

        let createAlert = app.alerts["Create a Snippets Library Here?"]
        XCTAssertTrue(createAlert.waitForExistence(timeout: 30), "an empty repository must offer to create a library")
        XCTAssertTrue(createAlert.buttons["Plain Text Instead…"].exists, "plain text is a separate question")
        createAlert.buttons["Create Library"].tap()

        let codeText = app.staticTexts["git-recovery-code-text"]
        XCTAssertTrue(codeText.waitForExistence(timeout: 30), "the recovery code sheet must appear")
        XCTAssertNotNil(
            codeText.label.range(of: #"^[0-9A-Z]{4}(-[0-9A-Z]{1,4}){6}$"#, options: .regularExpression),
            "the recovery code must be shown")
        let firstCode = codeText.label
        // Copy hands the code to the driving script through the simulator pasteboard.
        app.buttons["git-recovery-copy"].tap()
        XCTAssertTrue(app.staticTexts["git-recovery-copied"].waitForExistence(timeout: 5), "copying is confirmed")
        XCTAssertTrue(codeText.exists, "copying keeps the code on screen")
        app.buttons["git-recovery-done"].tap()

        // Sync starts off in a reset installation, so the confirmation offers to start it.
        let switchAlert = app.alerts.matching(NSPredicate(
            format: "label BEGINSWITH 'Start Syncing with Git' OR label BEGINSWITH 'Switch Sync to Git'")).firstMatch
        XCTAssertTrue(switchAlert.waitForExistence(timeout: 10), "connecting must hand off to Switch and Sync")
        XCTAssertFalse(switchAlert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '1 snippets'")).firstMatch.exists, "one snippet is singular")
        switchAlert.buttons["Switch and Sync"].tap()

        let provider = app.cells["sync-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        XCTAssertTrue(provider.staticTexts.allElementsBoundByIndex.contains { $0.label.hasPrefix("Git · ") })
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'On. Last synced'")).firstMatch.waitForExistence(timeout: 60),
            "the first Git sync must complete")

        // Replace Keys is offered once Git is syncing the library. It says what it
        // costs, then shows a different code.
        provider.tap()
        // The provider in use is marked instead of ending in an ellipsis.
        let git = app.buttons["Git Repository ✓"].firstMatch
        XCTAssertTrue(git.waitForExistence(timeout: 5))
        git.tap()
        let replaceKeys = app.cells["git-replace-keys"]
        XCTAssertTrue(replaceKeys.waitForExistence(timeout: 10), "an active library offers Replace Keys")
        replaceKeys.tap()
        let replaceAlert = app.alerts["Replace This Library’s Keys?"]
        XCTAssertTrue(replaceAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(replaceAlert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'history'")).firstMatch.exists,
            "the confirmation says the old versions stay readable in the history")
        replaceAlert.buttons["Replace Keys"].tap()

        XCTAssertTrue(codeText.waitForExistence(timeout: 60), "the new recovery code must be shown")
        let newCode = codeText.label
        XCTAssertNotNil(newCode.range(of: #"^[0-9A-Z]{4}(-[0-9A-Z]{1,4}){6}$"#, options: .regularExpression))
        XCTAssertNotEqual(newCode, firstCode, "replacing the keys makes a new code")
        app.buttons["git-recovery-copy"].tap()
        XCTAssertTrue(app.staticTexts["git-recovery-copied"].waitForExistence(timeout: 5), "copying is confirmed")
        app.buttons["git-recovery-done"].tap()
        // The result is the section's footer, right under the actions; a footer is not
        // always exposed as static text.
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Keys replaced.'")).firstMatch.waitForExistence(timeout: 60),
            "the screen says the keys were replaced")
        XCTAssertFalse(app.alerts.firstMatch.exists, "replacing the keys reports no error")
    }

    /// One edit that turns an SSH address into a GitHub HTTPS one removes the key section
    /// and adds the token link together; the table must take both without crashing.
    @MainActor
    func testOneEditFromSSHToGitHubKeepsTheScreen() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        try XCTSkipUnless(
            app.buttons["phone-new-snippet"].waitForExistence(timeout: 10), "This test covers the iPhone root controller")
        openGitRepository(in: app)
        let url = app.textFields["git-repository-url"]
        url.tap()
        // "github.com:" reads as an SSH address; deleting the colon makes it GitHub HTTPS.
        url.typeText("github.com:")
        XCTAssertTrue(app.cells["git-ssh-public-key"].waitForExistence(timeout: 5))
        url.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(app.cells["git-create-token"].waitForExistence(timeout: 5), "the token link appears")
        XCTAssertTrue(app.secureTextFields["git-token"].exists)
        XCTAssertFalse(app.cells["git-ssh-public-key"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// An SSH address replaces the user name and token rows with this device's public
    /// key, and typing back to HTTPS restores them, without the address field losing
    /// focus on the way. Needs no server.
    @MainActor
    func testAnSSHAddressShowsThisDevicesKeyInsteadOfTheTokenFields() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        try XCTSkipUnless(
            app.buttons["phone-new-snippet"].waitForExistence(timeout: 10), "This test covers the iPhone root controller")
        openGitRepository(in: app)
        XCTAssertTrue(app.secureTextFields["git-token"].exists)

        let url = app.textFields["git-repository-url"]
        fill(url, with: "git@example.invalid:me/library.git")
        let key = app.cells["git-ssh-public-key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertTrue(key.staticTexts.allElementsBoundByIndex.contains { $0.label.hasPrefix("ecdsa-sha2-nistp256 ") })
        XCTAssertTrue(app.cells["git-ssh-copy-key"].exists)
        XCTAssertFalse(app.secureTextFields["git-token"].exists)
        XCTAssertFalse(app.textFields["git-username"].exists)

        // Still the focused field: keep typing, then erase back to an HTTPS address,
        // crossing the SSH/HTTPS boundary several times on the way.
        url.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        url.typeText("https://example.invalid/me/library")
        XCTAssertEqual(url.value as? String, "https://example.invalid/me/library")
        XCTAssertTrue(app.secureTextFields["git-token"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["git-username"].exists)
        XCTAssertFalse(app.cells["git-ssh-public-key"].exists)
    }

    @MainActor
    private func openGitRepository(in app: XCUIApplication) {
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let search = app.searchFields["settings-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("git")
        let result = app.cells["settings-search-cloudProvider"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), "searching for git must find the provider setting")
        result.tap()
        let provider = app.cells["sync-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
        let git = app.buttons["Git Repository…"].firstMatch
        XCTAssertTrue(git.waitForExistence(timeout: 5))
        git.tap()
        XCTAssertTrue(app.textFields["git-repository-url"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func fill(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }
}
