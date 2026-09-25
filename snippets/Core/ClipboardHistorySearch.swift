import Foundation

/// Worker-owned, bounded plaintext projection. Never serialized. Original entries
/// remain authoritative for copy/paste; only the matching copy is normalized.
nonisolated struct ClipboardHistorySearchIndex {
    private struct Prepared {
        let text: String
        let field: PreparedSubstringSearch.Field
        let cost: Int
    }
    private var source: [ClipboardHistoryEntry] = []
    private var prepared: [UUID: Prepared] = [:]
    private let maximumBytes: Int
    private(set) var preparedEntryCount = 0
    private(set) var estimatedBytes = 0

    init(maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func results(_ query: String, in entries: [ClipboardHistoryEntry]) -> [ClipboardHistoryEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return entries }
        if source != entries {
            var next: [UUID: Prepared] = [:]
            var bytes = 0
            for entry in entries {
                let value: Prepared
                if let cached = prepared[entry.id], cached.text == entry.text {
                    value = cached
                } else {
                    let folded = Self.fold(entry.text)
                    value = Prepared(text: entry.text, field: .init(folded), cost: folded.utf8.count + 192)
                    preparedEntryCount += 1
                }
                let cost = value.cost
                if cost <= maximumBytes - bytes {
                    next[entry.id] = value
                    bytes += cost
                }
            }
            source = entries
            prepared = next
            estimatedBytes = bytes
        }
        let foldedTerms = terms.map { PreparedSubstringSearch.Query(Self.fold($0)) }
        return entries.filter { entry in
            if let cached = prepared[entry.id] {
                return foldedTerms.allSatisfy { cached.field.contains($0) }
            }
            // Oversized fields retain the existing semantics with no extra cache.
            return terms.allSatisfy {
                entry.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// At most one active and one pending request. New keystrokes replace the pending
/// request; both worker and UI validate generations before publishing results.
nonisolated final class ClipboardHistorySearchPipeline: @unchecked Sendable {
    struct Response: Sendable {
        let generation: UInt64
        let entries: [ClipboardHistoryEntry]
    }
    private struct Request {
        let generation: UInt64
        let query: String
        let entries: [ClipboardHistoryEntry]
        let completion: @Sendable (Response) -> Void
    }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending: Request?
    private var scheduled = false
    // Access only on queue.
    private var index = ClipboardHistorySearchIndex()

    init(queue: DispatchQueue = DispatchQueue(label: "com.khm.snippets.clipboard-search", qos: .userInitiated)) {
        self.queue = queue
    }

    @discardableResult
    func submit(query: String, entries: [ClipboardHistoryEntry],
                completion: @escaping @Sendable (Response) -> Void) -> UInt64 {
        lock.lock()
        generation &+= 1
        let next = generation
        pending = Request(generation: next, query: query, entries: entries, completion: completion)
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule { queue.async { [self] in drain() } }
        return next
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }

    func cancel(clearCache: Bool = false) {
        lock.lock()
        generation &+= 1
        pending = nil
        lock.unlock()
        if clearCache { queue.async { [self] in index = ClipboardHistorySearchIndex() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            guard isCurrent(request.generation) else { continue }
            let matches = index.results(request.query, in: request.entries)
            guard isCurrent(request.generation) else { continue }
            request.completion(Response(generation: request.generation, entries: matches))
        }
    }
}
