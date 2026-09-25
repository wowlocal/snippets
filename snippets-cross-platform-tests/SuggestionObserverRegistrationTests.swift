import XCTest

#if os(macOS)
import ApplicationServices
@testable import Snippets_Debug

@MainActor
final class SuggestionObserverRegistrationTests: XCTestCase {
    nonisolated private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testSlowRegistrationAndRemovalLeaveMainActorResponsive() async {
        let entered = expectation(description: "registration entered worker")
        let completed = expectation(description: "registration completed")
        let removalEntered = expectation(description: "removal entered worker")
        let removed = expectation(description: "cleanup finished")
        let releaseAdd = DispatchSemaphore(value: 0)
        let releaseRemove = DispatchSemaphore(value: 0)
        defer { releaseAdd.signal(); releaseRemove.signal() }
        let registration = SuggestionObserverRegistration(count: 1, register: { _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            XCTAssertEqual(releaseAdd.wait(timeout: .now() + 5), .success)
            return .success
        }, unregister: { _ in
            XCTAssertFalse(Thread.isMainThread)
            removalEntered.fulfill()
            XCTAssertEqual(releaseRemove.wait(timeout: .now() + 5), .success)
            removed.fulfill()
        })
        registration.start { outcome in
            XCTAssertTrue(outcome.registeredAny)
            XCTAssertNil(outcome.lastFailure)
            completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: 3)
        // Reaching this actor while the worker is held is the responsiveness check.
        releaseAdd.signal()
        await fulfillment(of: [completed], timeout: 3)
        registration.cancel()
        await fulfillment(of: [removalEntered], timeout: 3)
        releaseRemove.signal()
        await fulfillment(of: [removed], timeout: 3)
    }

    func testCancellationDuringIPCStopsRemainingRegistrationsAndCleansLateSuccess() async {
        let entered = expectation(description: "first IPC started")
        let completed = expectation(description: "cancelled setup completed")
        let cleaned = expectation(description: "late success removed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = Calls()
        let registration = SuggestionObserverRegistration(count: 10, register: { index in
            calls.record("add \(index)")
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return .success
        }, unregister: { index in
            calls.record("remove \(index)")
            cleaned.fulfill()
        })
        registration.start { _ in completed.fulfill() }
        await fulfillment(of: [entered], timeout: 3)
        registration.cancel()
        registration.cancel() // teardown must be idempotent
        release.signal()
        await fulfillment(of: [completed, cleaned], timeout: 3)
        XCTAssertEqual(calls.snapshot, ["add 0", "remove 0"])
    }

    func testPartialCapabilityFailureRetainsSuccessfulSubscriptionsForCleanup() async {
        let completed = expectation(description: "setup completed")
        let cleaned = expectation(description: "successful subscriptions removed")
        cleaned.expectedFulfillmentCount = 2
        let calls = Calls()
        let registration = SuggestionObserverRegistration(count: 3, register: { index in
            if index == 0 { return .success }
            if index == 1 { return .notificationAlreadyRegistered }
            return .notificationUnsupported
        }, unregister: { index in
            calls.record("remove \(index)")
            cleaned.fulfill()
        })
        registration.start { outcome in
            XCTAssertTrue(outcome.registeredAny)
            XCTAssertEqual(outcome.lastFailure?.index, 2)
            XCTAssertEqual(outcome.lastFailure?.error, .notificationUnsupported)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
        registration.cancel()
        await fulfillment(of: [cleaned], timeout: 3)
        XCTAssertEqual(calls.snapshot, ["remove 0", "remove 1"])
    }

    func testCancellationBeforeStartDoesNotRegister() async {
        let unexpected = expectation(description: "no registration after cancellation")
        unexpected.isInverted = true
        let registration = SuggestionObserverRegistration(count: 1, register: { _ in
            unexpected.fulfill()
            return .success
        }, unregister: { _ in unexpected.fulfill() })
        registration.cancel()
        registration.start { _ in unexpected.fulfill() }
        await fulfillment(of: [unexpected], timeout: 0.05)
    }
}
#endif
