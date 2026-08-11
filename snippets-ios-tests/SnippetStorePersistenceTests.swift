import Foundation
import XCTest

@testable import Snippets

@MainActor
final class SnippetStorePersistenceTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetStorePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testDebouncedWriteLeavesHeavyOperationOffMainActor() throws {
        let original = snippet(name: "Original", content: "old")
        try seed([original])

        let gate = PersistenceGate()
        defer { gate.release() }
        let worker = SnippetPersistenceWorker(
            label: "test.persistence.off-main",
            hooks: .init(willPerform: { _ in gate.blockFirst() })
        )
        let store = makeStore(worker: worker)
        var updated = try XCTUnwrap(store.snippet(id: original.id))
        updated.content = "new"
        store.update(updated)

        XCTAssertTrue(waitUntil { gate.hasStarted })
        XCTAssertEqual(gate.firstOperationWasOnMainThread, false)
        XCTAssertTrue(Thread.isMainThread, "The debounce callback must return while its worker is gated")
        XCTAssertEqual(try diskLibrary().first?.content, "old")

        gate.release()
        XCTAssertTrue(waitUntil {
            (try? self.diskLibrary().first?.content) == "new"
        })
    }

    func testFlushDrainsInFlightWriteAndPreservesNewerEditForeignEditAndDelete() throws {
        let instant = Date(timeIntervalSince1970: 10_000)
        let first = snippet(name: "First", content: "base", date: instant)
        let second = snippet(name: "Second", content: "base", date: instant)
        let deleted = snippet(name: "Delete me", content: "base", date: instant)
        try seed([first, second, deleted])

        let gate = PersistenceGate(releaseWhenWaited: true)
        defer { gate.release() }
        let worker = SnippetPersistenceWorker(
            label: "test.persistence.flush-race",
            hooks: .init(
                willPerform: { _ in gate.blockFirst() },
                willWaitForResult: { gate.releaseFromSynchronousWait() }
            )
        )
        let store = makeStore(worker: worker)

        var requestEdit = try XCTUnwrap(store.snippet(id: first.id))
        requestEdit.content = "request snapshot"
        store.update(requestEdit)
        XCTAssertTrue(waitUntil { gate.hasStarted })

        var newestEdit = try XCTUnwrap(store.snippet(id: first.id))
        newestEdit.content = "newest local"
        store.update(newestEdit)

        var foreignEdit = second
        foreignEdit.name = "Second from CLI"
        foreignEdit.updatedAt = instant.addingTimeInterval(20)
        // The foreign side intentionally leaves `first` unchanged and omits `deleted`.
        // The in-lock merge must retain the newer local edit, take this edit, and honor
        // the deletion whose ancestor proves that it was deliberate.
        try SnippetLibraryCodec.encode([first, foreignEdit])
            .write(to: SnippetStorageLocations.snippetsFileURL, options: .atomic)

        store.flushPendingWrites()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))

        let disk = try diskLibrary()
        XCTAssertEqual(disk.first(where: { $0.id == first.id })?.content, "newest local")
        XCTAssertEqual(disk.first(where: { $0.id == second.id })?.name, "Second from CLI")
        XCTAssertFalse(disk.contains(where: { $0.id == deleted.id }))
        XCTAssertEqual(store.snippet(id: first.id)?.content, "newest local")
        XCTAssertEqual(store.snippet(id: second.id)?.name, "Second from CLI")
        XCTAssertNil(store.snippet(id: deleted.id))
    }

    func testImmediateWriteDrainsGatedOperationWithoutDeadlockOrDoubleApplication() throws {
        let original = snippet(name: "Original", content: "base")
        let foreign = snippet(name: "From CLI", content: "foreign")
        try seed([original])

        let gate = PersistenceGate(releaseWhenWaited: true)
        defer { gate.release() }
        let worker = SnippetPersistenceWorker(
            label: "test.persistence.immediate-drain",
            hooks: .init(
                willPerform: { _ in gate.blockFirst() },
                willWaitForResult: { gate.releaseFromSynchronousWait() }
            )
        )
        let store = makeStore(worker: worker)
        var externalNotifications = 0
        store.onChange = { source in
            if source == .external { externalNotifications += 1 }
        }

        var edited = try XCTUnwrap(store.snippet(id: original.id))
        edited.content = "edited"
        store.update(edited)
        XCTAssertTrue(waitUntil { gate.hasStarted })
        try SnippetLibraryCodec.encode([original, foreign])
            .write(to: SnippetStorageLocations.snippetsFileURL, options: .atomic)

        // `togglePinned` is an immediate-write call site. Its synchronous drain hook
        // releases the worker, proving neither side waits for MainActor completion.
        store.togglePinned(snippetID: original.id)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let disk = try diskLibrary()
        XCTAssertEqual(disk.first(where: { $0.id == original.id })?.content, "edited")
        XCTAssertEqual(disk.first(where: { $0.id == original.id })?.isPinned, true)
        XCTAssertTrue(disk.contains(where: { $0.id == foreign.id }))
        XCTAssertEqual(
            externalNotifications,
            1,
            "The queued callback must not apply a synchronously drained result twice"
        )
    }

    func testExternalCompletionCallbackEditRemainsDirtyAndReachesDisk() throws {
        let original = snippet(name: "Original", content: "base")
        let foreign = snippet(name: "From CLI", content: "foreign")
        try seed([original])

        let gate = PersistenceGate()
        defer { gate.release() }
        let requests = LockedValue<[SnippetPersistenceRequest]>([])
        let worker = SnippetPersistenceWorker(
            label: "test.persistence.reentrant-callback",
            hooks: .init(
                willPerform: { request in
                    requests.withValue { $0.append(request) }
                    gate.blockFirst()
                }
            )
        )
        let store = makeStore(worker: worker)
        var didEditFromCallback = false
        store.onChange = { source in
            guard source == .external, !didEditFromCallback else { return }
            didEditFromCallback = true
            var callbackEdit = store.snippet(id: original.id)!
            callbackEdit.name = "Edited from callback"
            store.update(callbackEdit)
        }

        var firstEdit = try XCTUnwrap(store.snippet(id: original.id))
        firstEdit.content = "first edit"
        store.update(firstEdit)
        XCTAssertTrue(waitUntil { gate.hasStarted })
        try SnippetLibraryCodec.encode([original, foreign])
            .write(to: SnippetStorageLocations.snippetsFileURL, options: .atomic)

        gate.release()
        XCTAssertTrue(waitUntil { didEditFromCallback })
        XCTAssertTrue(
            waitUntil { requests.value.count >= 2 },
            "A synchronous observer edit must remain dirty after its publishing write completes"
        )
        XCTAssertTrue(waitUntil {
            guard let disk = try? self.diskLibrary() else { return false }
            return disk.first(where: { $0.id == original.id })?.name == "Edited from callback"
                && disk.first(where: { $0.id == original.id })?.content == "first edit"
                && disk.contains(where: { $0.id == foreign.id })
        })
    }

    func testStaleCompletionCannotReplaceNewerDiskCacheObservation() throws {
        let original = snippet(name: "Original", content: "base")
        try seed([original])

        let afterWriteGate = PersistenceGate()
        defer { afterWriteGate.release() }
        let requests = LockedValue<[SnippetPersistenceRequest]>([])
        let worker = SnippetPersistenceWorker(
            label: "test.persistence.stale-completion",
            hooks: .init(
                willPerform: { request in requests.withValue { $0.append(request) } },
                didPerform: { _, _ in afterWriteGate.blockFirst() }
            )
        )
        let store = makeStore(worker: worker)
        var local = try XCTUnwrap(store.snippet(id: original.id))
        local.content = "local"
        store.update(local)
        XCTAssertTrue(waitUntil { afterWriteGate.hasStarted })

        var externallyObserved = try XCTUnwrap(try diskLibrary().first)
        externallyObserved.name = "Observed after worker write"
        externallyObserved.updatedAt = original.updatedAt.addingTimeInterval(30)
        let externallyObservedData = try SnippetLibraryCodec.encode([externallyObserved])
        try externallyObservedData.write(
            to: SnippetStorageLocations.snippetsFileURL,
            options: .atomic
        )
        XCTAssertTrue(store.reloadAfterExternalWrite())

        afterWriteGate.release()
        XCTAssertTrue(waitUntil { requests.value.count >= 2 })
        let secondRequest = requests.value[1]
        XCTAssertEqual(
            secondRequest.expectedDigest,
            SnippetLibraryCodec.digest(of: externallyObservedData),
            "The older completion must not replace bytes observed after its write"
        )

        store.flushPendingWrites()
        let disk = try diskLibrary()
        XCTAssertEqual(disk.first?.name, "Observed after worker write")
        XCTAssertEqual(disk.first?.content, "local")
    }

    func testBusyFailureRetriesAndEventuallyPersists() throws {
        let original = snippet(name: "Original", content: "base")
        try seed([original])

        let attempts = LockedValue(0)
        let worker = SnippetPersistenceWorker(
            label: "test.persistence.busy-retry",
            hooks: .init(overrideResult: { _ in
                let attempt = attempts.withValue { value -> Int in
                    value += 1
                    return value
                }
                return attempt == 1 ? .failure(.busy) : nil
            })
        )
        let store = makeStore(worker: worker)
        var updated = try XCTUnwrap(store.snippet(id: original.id))
        updated.content = "after retry"
        store.update(updated)

        XCTAssertTrue(waitUntil {
            (try? self.diskLibrary().first?.content) == "after retry"
        })
        XCTAssertGreaterThanOrEqual(attempts.value, 2)
        XCTAssertEqual(store.writeHealth, .healthy)
    }

    func testFlushFallsBackToRecoveryFileAfterThreeBusyAttempts() throws {
        let original = snippet(name: "Original", content: "base")
        try seed([original])

        let attempts = LockedValue(0)
        let worker = SnippetPersistenceWorker(
            label: "test.persistence.recovery",
            hooks: .init(overrideResult: { _ in
                attempts.withValue { $0 += 1 }
                return .failure(.busy)
            })
        )
        let store = makeStore(worker: worker, persistDelay: 60)
        var updated = try XCTUnwrap(store.snippet(id: original.id))
        updated.content = "recover me"
        store.update(updated)

        store.flushPendingWrites()

        XCTAssertEqual(attempts.value, 3)
        XCTAssertEqual(try diskLibrary().first?.content, "base")
        let backupNames = try FileManager.default.contentsOfDirectory(
            atPath: SnippetStorageLocations.backupsFolderURL.path
        )
        let recoveryName = try XCTUnwrap(backupNames.first(where: { $0.hasPrefix("unsaved-") }))
        let recoveryURL = SnippetStorageLocations.backupsFolderURL
            .appendingPathComponent(recoveryName, isDirectory: false)
        let recovered = try SnippetLibraryCodec.decode(Data(contentsOf: recoveryURL))
        XCTAssertEqual(recovered.first?.content, "recover me")
    }

    private func makeStore(
        worker: SnippetPersistenceWorker,
        persistDelay: TimeInterval = 0
    ) -> SnippetStore {
        SnippetStore(
            configuration: .iOS,
            persistenceWorker: worker,
            persistDelay: persistDelay,
            persistenceRetryBaseDelay: 0
        )
    }

    private func seed(_ snippets: [Snippet]) throws {
        try SnippetLibraryCodec.encode(snippets)
            .write(to: SnippetStorageLocations.snippetsFileURL, options: .atomic)
    }

    private func diskLibrary() throws -> [Snippet] {
        try SnippetLibraryCodec.decode(Data(contentsOf: SnippetStorageLocations.snippetsFileURL))
    }

    private func snippet(
        name: String,
        content: String,
        date: Date = Date(timeIntervalSince1970: 1_000)
    ) -> Snippet {
        Snippet(
            name: name,
            keyword: "",
            content: content,
            createdAt: date,
            updatedAt: date
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }
}

private nonisolated final class PersistenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var didClaimFirst = false
    private var started = false
    private var wasOnMainThread: Bool?
    private let releaseWhenWaited: Bool

    init(releaseWhenWaited: Bool = false) {
        self.releaseWhenWaited = releaseWhenWaited
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var firstOperationWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return wasOnMainThread
    }

    func blockFirst() {
        lock.lock()
        guard !didClaimFirst else {
            lock.unlock()
            return
        }
        didClaimFirst = true
        started = true
        wasOnMainThread = Thread.isMainThread
        lock.unlock()
        releaseSemaphore.wait()
    }

    func releaseFromSynchronousWait() {
        guard releaseWhenWaited else { return }
        release()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private nonisolated final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
