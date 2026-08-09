import XCTest

final class SnippetsIOSUITests: XCTestCase {
    private struct CreatedFlow {
        let app: XCUIApplication
        let search: XCUIElement
        let isPhone: Bool
        let snippetName: String
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmptyOnboardingCreatesAndSearchesSnippet() throws {
        _ = try createGreetingSnippetAndFocusSearch()
    }

    func testPhoneLibraryUsesTouchToolbarAndTapToCopy() throws {
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()

        let create = app.buttons["phone-empty-create"]
        try XCTSkipUnless(
            create.waitForExistence(timeout: 3),
            "This smoke test covers the iPhone root controller"
        )
        XCTAssertTrue(app.buttons["phone-connect-icloud"].exists)
        XCTAssertTrue(app.buttons["phone-tag-filter"].exists)
        XCTAssertTrue(app.buttons["phone-new-snippet"].exists)
        XCTAssertTrue(app.searchFields["phone-snippet-search"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        XCTAssertTrue(create.isHittable)
        create.tap()
        let content = app.textViews["snippet-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 3))
        content.tap()
        content.typeText("Hello from iPhone")
        let name = app.textFields["snippet-name"]
        name.tap()
        name.typeText("iPhone Greeting")

        XCTAssertTrue(app.segmentedControls.buttons["Content"].exists)
        app.segmentedControls.buttons["Details"].tap()
        XCTAssertTrue(app.textFields["snippet-keyword"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.switches["snippet-enabled"].exists)

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.textFields["snippet-keyword"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["Snippets"].tap()
        XCTAssertTrue(app.staticTexts["iPhone Greeting"].waitForExistence(timeout: 3))
        app.staticTexts["iPhone Greeting"].tap()
        XCTAssertTrue(
            app.staticTexts["Copied “iPhone Greeting”."].waitForExistence(timeout: 3)
        )
    }

    func testCommandReturnCopiesSelectedSnippetWhileSearchIsFocused() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The iOS Simulator does not dispatch synthesized modifier keys through UIKeyCommand")
        #else
        let flow = try createGreetingSnippetAndFocusSearch()
        try XCTSkipIf(flow.isPhone, "Hardware keyboard parity belongs to the iPad interface")

        flow.search.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            flow.app.staticTexts["Copied “iPad Greeting”."].waitForExistence(timeout: 3),
            "⌘Return should copy the selected snippet even while Search owns focus"
        )
        #endif
    }

    func testEscapeKeepsSearchQueryWhileMovingFocusToSnippetList() throws {
        let flow = try createGreetingSnippetAndFocusSearch()
        try XCTSkipIf(flow.isPhone, "Escape search focus is an iPad keyboard interaction")

        flow.search.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(flow.search.value as? String, "Greeting")
    }

    func testShortcutPanelShowsMacStyleOptionHint() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-show-shortcuts"]
        app.launch()

        try XCTSkipIf(
            app.buttons["phone-empty-create"].waitForExistence(timeout: 2),
            "The touch-first iPhone interface intentionally has no shortcut panel"
        )

        XCTAssertTrue(
            app.staticTexts["shortcut-panel-tip"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.staticTexts["shortcut-panel-tip"].label,
            "Hold ⌥ for all shortcuts."
        )
    }

    private func createGreetingSnippetAndFocusSearch() throws -> CreatedFlow {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()

        let phoneCreate = app.buttons["phone-empty-create"]
        let isPhone = phoneCreate.waitForExistence(timeout: 2)
        if isPhone {
            phoneCreate.tap()
        } else {
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
            XCTAssertTrue(app.staticTexts["Your snippet library is empty"].waitForExistence(timeout: 5))
            app.buttons["empty-create"].tap()
        }

        let content = app.textViews["snippet-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        content.tap()
        content.typeText(isPhone ? "Hello from the iPhone app" : "Hello from the iPad app")

        let name = app.textFields["snippet-name"]
        name.tap()
        let snippetName = isPhone ? "iPhone Greeting" : "iPad Greeting"
        name.typeText(snippetName)

        if isPhone {
            app.navigationBars.buttons["Snippets"].tap()
        }

        let search = app.searchFields[isPhone ? "phone-snippet-search" : "snippet-search"]
        search.tap()
        search.typeText("Greeting")
        XCTAssertTrue(app.staticTexts[snippetName].waitForExistence(timeout: 3))
        return CreatedFlow(app: app, search: search, isPhone: isPhone, snippetName: snippetName)
    }
}
