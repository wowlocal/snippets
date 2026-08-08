import XCTest

final class SnippetsIPadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmptyOnboardingCreatesAndSearchesSnippet() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Your snippet library is empty"].waitForExistence(timeout: 5))
        app.buttons["empty-create"].tap()

        let content = app.textViews["snippet-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        content.tap()
        content.typeText("Hello from the iPad app")

        let name = app.textFields["snippet-name"]
        name.tap()
        name.typeText("iPad Greeting")

        let search = app.searchFields["snippet-search"]
        search.tap()
        search.typeText("Greeting")
        XCTAssertTrue(app.staticTexts["iPad Greeting"].waitForExistence(timeout: 3))
    }
}
