import XCTest

final class PhoneLibraryAccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPhoneEmptyStateActionsRemainReachableAtCurrentDynamicTypeSize() throws {
        addUIInterruptionMonitor(withDescription: "Pending system open confirmation") { alert in
            guard alert.buttons["Cancel"].exists else { return false }
            alert.buttons["Cancel"].tap()
            return true
        }

        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        // Gives XCTest a normal interaction with which to invoke interruption monitors
        // if a simulator retained a system confirmation from an earlier deep-link test.
        app.tap()

        let create = app.buttons["phone-empty-create"]
        try XCTSkipUnless(
            create.waitForExistence(timeout: 3),
            "This regression covers the touch-first iPhone Library"
        )
        XCTAssertTrue(app.staticTexts["phone-empty-title"].exists)

        for _ in 0..<5 where !create.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(create.isHittable, "Empty-state actions must remain reachable by scrolling")
        XCTAssertGreaterThan(create.frame.width, 180)
        XCTAssertTrue(app.buttons["phone-tag-filter"].exists)
        XCTAssertTrue(app.buttons["phone-new-snippet"].exists)
        XCTAssertTrue(app.searchFields["phone-snippet-search"].exists)
    }
}
