import XCTest

final class SnippetsIPadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmptyOnboardingCreatesAndSearchesSnippet() throws {
        _ = createGreetingSnippetAndFocusSearch()
    }

    func testCommandReturnCopiesSelectedSnippetWhileSearchIsFocused() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The iOS Simulator does not dispatch synthesized modifier keys through UIKeyCommand")
        #else
        let (app, search) = createGreetingSnippetAndFocusSearch()

        search.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["Copied “iPad Greeting”."].waitForExistence(timeout: 3),
            "⌘Return should copy the selected snippet even while Search owns focus"
        )
        #endif
    }

    func testEscapeKeepsSearchQueryWhileMovingFocusToSnippetList() {
        let (_, search) = createGreetingSnippetAndFocusSearch()

        search.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(search.value as? String, "Greeting")
    }

    func testShortcutPanelShowsMacStyleOptionHint() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-show-shortcuts"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["shortcut-panel-tip"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.staticTexts["shortcut-panel-tip"].label,
            "Hold ⌥ for all shortcuts."
        )
    }

    private func createGreetingSnippetAndFocusSearch() -> (XCUIApplication, XCUIElement) {
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
        return (app, search)
    }
}
