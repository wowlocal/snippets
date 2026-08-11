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

        let connect = app.buttons["phone-connect-icloud"]
        try XCTSkipUnless(
            connect.waitForExistence(timeout: 3),
            "This regression covers the touch-first iPhone Library"
        )
        XCTAssertTrue(app.staticTexts["phone-empty-title"].exists)
        XCTAssertFalse(app.buttons["phone-empty-create"].exists)

        for _ in 0..<5 where !connect.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(connect.isHittable, "The iCloud action must remain reachable by scrolling")
        XCTAssertGreaterThan(connect.frame.width, 140)
        XCTAssertLessThan(connect.frame.width, 300)
        XCTAssertTrue(app.buttons["phone-tag-filter"].exists)
        XCTAssertTrue(app.buttons["phone-new-snippet"].exists)
        XCTAssertTrue(app.searchFields["phone-snippet-search"].exists)
    }
}
