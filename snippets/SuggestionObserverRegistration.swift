import ApplicationServices
import Foundation

/// AXObserverAdd/RemoveNotification are synchronous IPC too. A Task on MainActor
/// only moves that stall out of the current callback; it still blocks the next key.
/// Keep registration and teardown on one worker, with cancellation between messages.
nonisolated final class SuggestionObserverRegistration: @unchecked Sendable {
    struct Outcome: Sendable {
        let registeredAny: Bool
        let lastFailure: (index: Int, error: AXError)?
    }

    private static let queue = DispatchQueue(
        label: "com.khm.snippets.suggestion-observer", qos: .userInitiated)
    private let count: Int
    private let register: @Sendable (Int) -> AXError
    private let unregister: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    // Accessed only on queue. Closures retain the AX objects until cleanup finishes.
    private var registeredIndices: [Int] = []

    init(count: Int,
         register: @escaping @Sendable (Int) -> AXError,
         unregister: @escaping @Sendable (Int) -> Void) {
        self.count = count
        self.register = register
        self.unregister = unregister
    }

    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        lock.lock()
        guard !started, !cancelled else { lock.unlock(); return }
        started = true
        // Enqueue under the lock so cancel cannot enqueue cleanup ahead of setup.
        Self.queue.async { [self] in
            var lastFailure: (index: Int, error: AXError)?
            for index in 0..<count {
                guard !isCancelled else { break }
                let result = register(index)
                if result == .success || result == .notificationAlreadyRegistered {
                    registeredIndices.append(index)
                } else {
                    lastFailure = (index, result)
                }
            }
            completion(Outcome(registeredAny: !registeredIndices.isEmpty,
                               lastFailure: lastFailure))
        }
        lock.unlock()
    }

    /// Call after detaching the source from the main run loop. No host IPC here.
    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        Self.queue.async { [self] in
            for index in registeredIndices { unregister(index) }
            registeredIndices.removeAll()
        }
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Immutable handles transferred to the registration worker. Their run-loop source
/// is attached/detached only on MainActor; the worker owns all notification changes.
nonisolated struct SuggestionObserverHandles: @unchecked Sendable {
    let observer: AXObserver
    let elements: [AXUIElement]
    let refcon: UnsafeMutableRawPointer

    func register(_ index: Int) -> AXError {
        AXObserverAddNotification(observer, elements[index / 2], notification(index), refcon)
    }

    func unregister(_ index: Int) {
        _ = AXObserverRemoveNotification(observer, elements[index / 2], notification(index))
    }

    private func notification(_ index: Int) -> CFString {
        (index.isMultiple(of: 2) ? kAXValueChangedNotification : kAXSelectedTextChangedNotification) as CFString
    }
}
