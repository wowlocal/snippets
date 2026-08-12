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

        let create = app.buttons["phone-new-snippet"]
        try XCTSkipUnless(
            create.waitForExistence(timeout: 3),
            "This smoke test covers the iPhone root controller"
        )
        XCTAssertTrue(app.buttons["phone-connect-icloud"].exists)
        XCTAssertFalse(app.buttons["phone-empty-create"].exists)
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

    func testReturnCopiesSelectedSnippetFromList() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The iOS Simulator does not dispatch synthesized keys through the hardware-key press pipeline")
        #else
        let flow = try createGreetingSnippetAndFocusSearch()
        try XCTSkipIf(flow.isPhone, "Hardware keyboard parity belongs to the iPad interface")

        flow.search.typeKey(.escape, modifierFlags: [])
        flow.app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            flow.app.staticTexts["Copied “iPad Greeting”."].waitForExistence(timeout: 3),
            "Return should copy the selected snippet when the list owns focus"
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
            app.buttons["phone-new-snippet"].waitForExistence(timeout: 2),
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

    func testIPadMoreMenuOffersICloudSync() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()

        try XCTSkipIf(
            app.buttons["phone-new-snippet"].waitForExistence(timeout: 2),
            "The iPhone Library has its own iCloud action"
        )

        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(
            app.buttons[
                "Connect iCloud, Off. Your snippets stay on this device."
            ].waitForExistence(timeout: 3)
        )
    }

    /// Captures deterministic, real-device-size App Store screenshots when explicitly
    /// requested by the release workflow. Ordinary verification runs skip this test so
    /// adding marketing assets does not make the smoke suite slower or stateful.
    func testCaptureAppStoreScreenshots() throws {
        let captureWasRequested =
            ProcessInfo.processInfo.environment["SNIPPETS_CAPTURE_APPSTORE_SCREENSHOTS"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--capture-app-store-screenshots")
        try XCTSkipUnless(
            captureWasRequested,
            "Request the dedicated App Store screenshot workflow to retain screenshots."
        )

        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-reset",
            "--ui-testing-authentication-succeeds",
        ]
        app.launch()

        let isPhone = app.buttons["phone-new-snippet"].waitForExistence(timeout: 3)
        if isPhone {
            try capturePhoneAppStoreScreenshots(in: app)
        } else {
            try capturePadAppStoreScreenshots(in: app)
        }
    }

    private func createGreetingSnippetAndFocusSearch() throws -> CreatedFlow {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()

        let phoneCreate = app.buttons["phone-new-snippet"]
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

    private func capturePhoneAppStoreScreenshots(in app: XCUIApplication) throws {
        let samples = [
            (
                name: "Email signature",
                content: "Best,\nAlex\nProduct Designer",
                keyword: "sig",
                tags: "work,email,"
            ),
            (
                name: "Meeting notes",
                content: "Meeting notes for {date:yyyy-MM-dd}\n\nAgenda:\n- Decisions\n- Next steps",
                keyword: "meet",
                tags: "work,notes,"
            ),
            (
                name: "Quick reply",
                content: "Thanks for reaching out. I will take a look and get back to you shortly.",
                keyword: "reply",
                tags: "email,support,"
            ),
        ]

        for (index, sample) in samples.enumerated() {
            if index == 0 {
                app.buttons["phone-new-snippet"].tap()
            } else {
                XCTAssertTrue(app.buttons["phone-new-snippet"].waitForExistence(timeout: 3))
                app.buttons["phone-new-snippet"].tap()
            }

            try populateEditor(
                in: app,
                name: sample.name,
                content: sample.content,
                keyword: sample.keyword,
                tags: sample.tags,
                usesPhoneModes: true
            )

            if index == 0 {
                app.segmentedControls.buttons["Content"].tap()
                XCTAssertTrue(app.otherElements["phone-editor-content-pane"].waitForExistence(timeout: 2))
                retainScreenshot(named: "iphone-02-editor")

                app.segmentedControls.buttons["Details"].tap()
                XCTAssertTrue(app.otherElements["phone-editor-details-pane"].waitForExistence(timeout: 2))
                try makePhoneSnippetSecure(in: app)
                retainScreenshot(named: "iphone-03-secure")
            }

            app.navigationBars.buttons["Snippets"].tap()
            XCTAssertTrue(app.staticTexts[sample.name].waitForExistence(timeout: 3))
        }

        dismissKeyboard(in: app)
        XCTAssertTrue(app.staticTexts["Email signature"].exists)
        XCTAssertTrue(app.staticTexts["Meeting notes"].exists)
        XCTAssertTrue(app.staticTexts["Quick reply"].exists)
        retainScreenshot(named: "iphone-01-library")
    }

    private func capturePadAppStoreScreenshots(in app: XCUIApplication) throws {
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["empty-create"].waitForExistence(timeout: 5))

        let samples = [
            (
                name: "Email signature",
                content: "Best,\nAlex\nProduct Designer",
                keyword: "sig",
                tags: "work,email,"
            ),
            (
                name: "Meeting notes",
                content: "Meeting notes for {date:yyyy-MM-dd}\n\nAgenda:\n- Decisions\n- Next steps",
                keyword: "meet",
                tags: "work,notes,"
            ),
            (
                name: "Quick reply",
                content: "Thanks for reaching out. I will take a look and get back to you shortly.",
                keyword: "reply",
                tags: "email,support,"
            ),
        ]

        for (index, sample) in samples.enumerated() {
            if index == 0 {
                app.buttons["empty-create"].tap()
            } else {
                app.buttons["new-snippet"].tap()
                XCTAssertTrue(app.buttons["New Snippet"].waitForExistence(timeout: 2))
                app.buttons["New Snippet"].tap()
            }

            try populateEditor(
                in: app,
                name: sample.name,
                content: sample.content,
                keyword: sample.keyword,
                tags: sample.tags,
                usesPhoneModes: false
            )
        }

        dismissKeyboard(in: app)
        XCTAssertTrue(app.staticTexts["Email signature"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Meeting notes"].exists)
        XCTAssertTrue(app.staticTexts["Quick reply"].exists)
        app.swipeDown()
        app.swipeDown()
        retainScreenshot(named: "ipad-01-library-and-editor")

        let meetingNotes = app.staticTexts["Meeting notes"].firstMatch
        meetingNotes.tap()
        XCTAssertTrue(app.staticTexts["snippet-preview"].waitForExistence(timeout: 3))
        app.swipeDown()
        retainScreenshot(named: "ipad-02-placeholder-preview")

        let more = app.buttons["More"].firstMatch
        if more.exists {
            more.tap()
            let shortcuts = app.buttons["Keyboard Shortcuts"]
            if shortcuts.waitForExistence(timeout: 2) {
                shortcuts.tap()
                XCTAssertTrue(app.otherElements["shortcut-panel"].waitForExistence(timeout: 3))
                retainScreenshot(named: "ipad-03-keyboard-shortcuts")
            }
        }
    }

    private func populateEditor(
        in app: XCUIApplication,
        name: String,
        content: String,
        keyword: String,
        tags: String,
        usesPhoneModes: Bool
    ) throws {
        let body = app.textViews["snippet-content"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap()
        body.typeText(content)

        let nameField = app.textFields["snippet-name"]
        nameField.tap()
        nameField.typeText(name)

        if usesPhoneModes {
            app.segmentedControls.buttons["Details"].tap()
            XCTAssertTrue(app.otherElements["phone-editor-details-pane"].waitForExistence(timeout: 2))
        } else {
            nameField.swipeUp()
        }

        let keywordField = app.textFields["snippet-keyword"]
        XCTAssertTrue(keywordField.waitForExistence(timeout: 3))
        keywordField.tap()
        keywordField.typeText(keyword)

        let tagsField = app.textFields["tags-input"]
        XCTAssertTrue(tagsField.waitForExistence(timeout: 3))
        tagsField.tap()
        tagsField.typeText(tags)
    }

    private func dismissKeyboard(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let hide = keyboard.buttons["Hide keyboard"]
        if hide.exists {
            hide.tap()
        } else {
            app.swipeDown()
        }
    }

    private func makePhoneSnippetSecure(in app: XCUIApplication) throws {
        let secureSwitch = app.switches["snippet-secure"]
        XCTAssertTrue(secureSwitch.waitForExistence(timeout: 3))
        secureSwitch.tap()

        let saveRecoveryKey = app.alerts.buttons["I’ve Saved It"]
        if saveRecoveryKey.waitForExistence(timeout: 2) {
            saveRecoveryKey.tap()
        }
        try waitForSwitch(secureSwitch, toEqual: "1")
        dismissKeyboard(in: app)
    }

    private func waitForSwitch(_ element: XCUIElement, toEqual value: String) throws {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed)
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
