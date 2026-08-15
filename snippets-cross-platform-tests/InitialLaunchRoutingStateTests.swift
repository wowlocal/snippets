import XCTest

@testable import Snippets_Debug

final class InitialLaunchRoutingStateTests: XCTestCase {
    func testUnroutedNonDefaultLaunchFallsBackToMainWindow() {
        var state = InitialLaunchRoutingState()

        state.begin(isDefaultLaunch: false)

        XCTAssertTrue(state.isWaitingForRoutedAction)
        XCTAssertTrue(state.shouldShowMainWindowAfterTimeout())
        XCTAssertFalse(state.isWaitingForRoutedAction)
        XCTAssertFalse(state.shouldShowMainWindowAfterTimeout())
    }

    func testColdServiceCallbackConsumesForegroundFallback() {
        var state = InitialLaunchRoutingState()

        state.begin(isDefaultLaunch: false)

        XCTAssertTrue(state.consumeRoutedAction())
        XCTAssertFalse(state.shouldShowMainWindowAfterTimeout())
    }

    func testDefaultLaunchNeverWaitsForRoutedAction() {
        var state = InitialLaunchRoutingState()

        state.begin(isDefaultLaunch: true)

        XCTAssertFalse(state.isWaitingForRoutedAction)
        XCTAssertFalse(state.shouldShowMainWindowAfterTimeout())
    }
}
