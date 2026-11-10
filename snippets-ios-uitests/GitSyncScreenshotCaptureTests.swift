import Foundation
import XCTest

/// Temporary: captures the Git settings flow for a UX review. Runs only when
/// SNIPPETS_GIT_SHOTS_URL is set by the capture script.
final class GitSyncScreenshotCaptureTests: XCTestCase {
    @MainActor
    func testCaptureGitSettingsFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["SNIPPETS_GIT_SHOTS_URL"], let token = environment["SNIPPETS_GIT_SHOTS_TOKEN"] else {
            throw XCTSkip("capture only")
        }
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        let isPhone = app.buttons["phone-new-snippet"].waitForExistence(timeout: 10)
        if isPhone {
            app.buttons["phone-new-snippet"].tap()
            let content = app.textViews["snippet-content"]
            XCTAssertTrue(content.waitForExistence(timeout: 5))
            content.tap()
            content.typeText("Kind regards,\nMichael")
            let name = app.textFields["snippet-name"]
            name.tap()
            name.typeText("Signature")
            app.navigationBars.buttons["Snippets"].tap()
        }
        shot(app, "01-library")
        openGitRepository(in: app, phone: isPhone)
        shot(app, "02-git-empty")

        let field = app.textFields["git-repository-url"]
        field.tap()
        field.typeText("git@github.com:you/snippets-library.git")
        _ = app.cells["git-ssh-public-key"].waitForExistence(timeout: 5)
        shot(app, "03-git-ssh-address")
        app.swipeUp()
        shot(app, "04-git-ssh-key-section")
        app.swipeDown()

        field.tap()
        if field.buttons["Clear text"].exists { field.buttons["Clear text"].tap() }
        field.typeText(url)
        let username = app.textFields["git-username"]
        username.tap()
        username.typeText("tester")
        let secret = app.secureTextFields["git-token"]
        secret.tap()
        secret.typeText(token)
        shot(app, "05-git-https-filled")
        app.cells["git-connect"].tap()

        let create = app.alerts["Create a Snippets Library Here?"]
        if create.waitForExistence(timeout: 30) {
            shot(app, "06-create-choice")
            create.buttons["Create Plain-Text Library"].tap()
        }
        if app.staticTexts["git-recovery-code-text"].waitForExistence(timeout: 30) {
            shot(app, "07-recovery-code")
            app.buttons["git-recovery-copy"].tap()
            shot(app, "07b-recovery-code-copied")
            app.buttons["git-recovery-done"].tap()
        }
        let switchAlert = app.alerts.matching(NSPredicate(
            format: "label BEGINSWITH 'Start Syncing with Git' OR label BEGINSWITH 'Switch Sync to Git'")).firstMatch
        if switchAlert.waitForExistence(timeout: 10) {
            shot(app, "08-switch-confirm")
            switchAlert.buttons["Switch and Sync"].tap()
        }
        _ = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'On. Last synced'"))
            .firstMatch.waitForExistence(timeout: 60)
        shot(app, "10-sync-pane-after")
        let provider = app.cells["sync-provider"]
        if provider.waitForExistence(timeout: 5) {
            provider.tap()
            shot(app, "11-provider-menu")
            let git = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Git Repository'")).firstMatch
            if git.waitForExistence(timeout: 5) {
                git.tap()
                _ = app.cells["git-connected"].waitForExistence(timeout: 5)
                shot(app, "12-git-connected")
                app.swipeUp()
                shot(app, "13-git-connected-actions")
            }
        }
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openGitRepository(in app: XCUIApplication, phone: Bool) {
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
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let provider = app.cells["sync-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        shot(app, "01b-sync-pane")
        provider.tap()
        shot(app, "01c-provider-menu")
        let git = app.buttons["Git Repository…"].firstMatch
        XCTAssertTrue(git.waitForExistence(timeout: 5))
        git.tap()
        XCTAssertTrue(app.textFields["git-repository-url"].waitForExistence(timeout: 5))
    }
}
