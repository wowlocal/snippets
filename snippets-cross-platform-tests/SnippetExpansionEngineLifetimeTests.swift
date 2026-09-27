import XCTest

#if os(macOS)
import AppKit
import ApplicationServices
@testable import Snippets_Debug

@MainActor
final class SnippetExpansionEngineLifetimeTests: XCTestCase {
    nonisolated private final class EngineOwner: @unchecked Sendable {
        // Initialized before dispatch, then accessed only by the release worker.
        private var engine: SnippetExpansionEngine?

        init(_ engine: SnippetExpansionEngine) { self.engine = engine }
        func release() { engine = nil }
    }

    private var root: URL!
    private var previousRoot: String?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnippetsEngineLifetime-\(UUID().uuidString)", isDirectory: true)
        previousRoot = ProcessInfo.processInfo.environment[SnippetStorageLocations.rootOverrideEnvironmentKey]
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
    }

    override func tearDown() {
        let key = SnippetStorageLocations.rootOverrideEnvironmentKey
        if let previousRoot { setenv(key, previousRoot, 1) } else { unsetenv(key) }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testDeallocationInvalidatesEventTapRetainedByRunLoop() throws {
        let store = SnippetStore(configuration: .iOS)
        let usage = SnippetUsageStore()
        var engine: SnippetExpansionEngine? = SnippetExpansionEngine(store: store, usage: usage)
        weak let releasedEngine = engine
        engine?.startIfNeeded()
        let tap = engine?.eventTap
        if let tap { XCTAssertTrue(CFMachPortIsValid(tap)) }

        engine = nil
        XCTAssertNil(releasedEngine, "Input monitors must not keep the engine alive")
        guard let tap else {
            throw XCTSkip("Creating an event tap requires Accessibility access")
        }
        XCTAssertFalse(CFMachPortIsValid(tap), "A surviving tap must not call the released engine")
    }

    func testCallbacksBetweenBackgroundLastReleaseAndIsolatedCleanupAreInert() async throws {
        let store = SnippetStore(configuration: .iOS)
        let usage = SnippetUsageStore()
        var engine: SnippetExpansionEngine? = SnippetExpansionEngine(store: store, usage: usage)
        weak let releasedEngine = engine
        weak let releasedContext = engine?.callbackContext
        let owner = EngineOwner(try XCTUnwrap(engine))
        let workerReleased = DispatchSemaphore(value: 0)
        engine = nil

        DispatchQueue.global().async {
            owner.release()
            workerReleased.signal()
        }
        // Hold MainActor until the worker performs the last release. The isolated
        // destructor cannot run yet, reproducing the queued-callback gap exactly.
        guard workerReleased.wait(timeout: .now() + 3) == .success else {
            XCTFail("The worker did not perform its last release before the deadline")
            return
        }
        XCTAssertNil(releasedEngine)
        guard releasedEngine == nil else { return }
        try withExtendedLifetime(try XCTUnwrap(
            releasedContext, "Deferred cleanup must still own the raw refcon")) { context in
            XCTAssertNil(context.engine)
            guard context.engine == nil else { return }
            let refcon = Unmanaged.passUnretained(context).toOpaque()
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
            for type: CGEventType in [.keyDown, .keyUp, .tapDisabledByTimeout, .tapDisabledByUserInput] {
                let forwarded = try XCTUnwrap(SnippetExpansionEngine.eventTapCallback(
                    type: type, event: event, refcon: refcon)).takeUnretainedValue()
                XCTAssertTrue(forwarded === event)
            }
            SnippetExpansionEngine.suggestionAccessibilityCallback(
                notification: kAXValueChangedNotification as CFString, refcon: refcon)
            SnippetExpansionEngine.suggestionAccessibilityCallback(
                notification: kAXSelectedTextChangedNotification as CFString, refcon: refcon)
        }
        try await waitForContextRelease { releasedContext == nil }
        XCTAssertNil(releasedContext, "The weak context must not form an engine retain cycle")
    }

    private func waitForContextRelease(_ isReleased: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !isReleased(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAXHandlesRetainContextThroughLateRegistrationAndCancellationCleanup() async throws {
        let entered = expectation(description: "registration entered worker")
        let completed = expectation(description: "late registration completed")
        let removalEntered = expectation(description: "removal entered worker")
        let removed = expectation(description: "cleanup finished")
        let releaseAdd = DispatchSemaphore(value: 0)
        let releaseRemove = DispatchSemaphore(value: 0)
        defer { releaseAdd.signal(); releaseRemove.signal() }

        var observer: AXObserver?
        let result = AXObserverCreate(getpid(), { _, _, _, _ in }, &observer)
        XCTAssertEqual(result, .success)
        let actualObserver = try XCTUnwrap(observer)
        var context: SnippetExpansionCallbackContext? = SnippetExpansionCallbackContext()
        weak let releasedContext = context
        var handles: SuggestionObserverHandles? = SuggestionObserverHandles(
            observer: actualObserver, elements: [], callbackContext: try XCTUnwrap(context))
        var registration: SuggestionObserverRegistration? = SuggestionObserverRegistration(
            count: 1, register: { [handles = handles!] _ in
                withExtendedLifetime(handles) {
                    entered.fulfill()
                    XCTAssertEqual(releaseAdd.wait(timeout: .now() + 5), .success)
                    return .success
                }
            }, unregister: { [handles = handles!] _ in
                withExtendedLifetime(handles) {
                    removalEntered.fulfill()
                    XCTAssertEqual(releaseRemove.wait(timeout: .now() + 5), .success)
                    removed.fulfill()
                }
            })
        handles = nil
        context = nil
        registration?.start { _ in completed.fulfill() }
        await fulfillment(of: [entered], timeout: 3)
        registration?.cancel()
        registration = nil
        XCTAssertNotNil(releasedContext, "In-flight AX IPC must still own its raw refcon")
        releaseAdd.signal()
        await fulfillment(of: [completed, removalEntered], timeout: 3)
        XCTAssertNotNil(releasedContext, "Cancellation removals must retain the context too")
        releaseRemove.signal()
        // Fence the same worker: fulfillment inside unregister precedes its return
        // and the release of the cancelled registration's handle-owning closures.
        let workerDrained = expectation(description: "worker released cancelled registration")
        let fence = SuggestionObserverRegistration(count: 0, register: { _ in .success }, unregister: { _ in })
        fence.start { _ in workerDrained.fulfill() }
        await fulfillment(of: [removed, workerDrained], timeout: 3)
        XCTAssertNil(releasedContext)
    }
}
#endif
