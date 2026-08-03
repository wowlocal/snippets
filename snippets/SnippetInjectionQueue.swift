import Foundation

/// Serializes text injection. Ordering used to be a side effect of blocking the main thread; once
/// the delivery path awaits, two expansions can otherwise interleave halfway through each other's
/// backspaces.
@MainActor
final class SnippetInjectionQueue {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tail: (id: UUID, task: Task<Void, Never>)?
    private var automaticTaskID: UUID?

    func enqueue(
        isAutomatic: Bool,
        operation: @escaping @MainActor () async -> Void
    ) {
        let id = UUID()
        let predecessor = tail?.task
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer { self.finish(id: id) }
            // The operation always runs and checks cancellation itself: skipping it here would strand
            // whatever bookkeeping the caller paired with this unit.
            await operation()
        }
        tasks[id] = task
        tail = (id, task)
        if isAutomatic { automaticTaskID = id }
    }

    func cancelAutomatic() {
        guard let automaticTaskID else { return }
        tasks[automaticTaskID]?.cancel()
        self.automaticTaskID = nil
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        tail = nil
        automaticTaskID = nil
    }

    private func finish(id: UUID) {
        tasks.removeValue(forKey: id)
        if automaticTaskID == id { automaticTaskID = nil }
        if tail?.id == id { tail = nil }
    }
}
