import Foundation

/// Owns per-snippet usage statistics: an in-memory document, a debounced
/// atomic writer, and the frozen snapshots the suggestion panel ranks against.
///
/// Shares no code path with `SnippetStore`. Recording a use never touches the
/// snippet library, its undo stack, its `updatedAt` timestamps, or its change
/// notification — so expanding a snippet in another app cannot reshuffle the
/// main window's list or rewrite `snippets.json`.
@MainActor
final class SnippetUsageStore {

    enum Event: Int {
        case expansion = 0
        case pasteFromApp = 1
        case copyFromApp = 2

        var weight: Double {
            switch self {
            case .expansion:
                return SnippetFrecency.expandWeight
            case .pasteFromApp:
                return SnippetFrecency.pasteWeight
            case .copyFromApp:
                return SnippetFrecency.copyWeight
            }
        }
    }

    /// Hidden hard switch. Disables reading, writing, ranking, and every
    /// filesystem touch:
    /// `defaults write com.khm.snippets snippets.frecency.killSwitch -bool YES`
    static let killSwitchKey = "snippets.frecency.killSwitch"
    /// Visible switch. Disables ranking only; recording continues, so turning
    /// it back on is not a cold start.
    static let rankingEnabledKey = "snippets.frecency.rankingEnabled"
    static let selectionMemoryEnabledKey = "snippets.frecency.selectionMemoryEnabled"

    /// Both switches default to ON. The project registers no defaults, and
    /// `UserDefaults.bool(forKey:)` returns false for a missing key — which
    /// would silently ship the feature disabled for everyone. A missing key
    /// means "the user never chose", exactly as `GlobalHotkeyManager` treats it.
    static func flag(_ key: String, default fallback: Bool) -> Bool {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Bool else { return fallback }
        return stored
    }

    var isRankingEnabled: Bool { Self.flag(Self.rankingEnabledKey, default: true) }
    var isSelectionMemoryEnabled: Bool { Self.flag(Self.selectionMemoryEnabledKey, default: true) }

    private(set) var document: SnippetUsageDocument
    private(set) var isReadOnly = false
    private let isKilled: Bool

    /// Injectable clock. Without it the coalescing window, the debounce, and
    /// the staleness ceiling are untestable.
    var now: () -> Double = { Date().timeIntervalSince1970 }

    /// Injected by `AppDelegate`. Consulted only when `maxRecords` is exceeded,
    /// so that a forced eviction drops orphaned UUIDs first.
    var liveSnippetIDs: (@MainActor () -> Set<UUID>)?
    /// Injected by `AppDelegate` so the settings pane can name the most-used
    /// snippet without this store holding a reference to the library.
    var snippetDisplayName: (@MainActor (UUID) -> String?)?

    /// All disk work happens here — never on the main thread, therefore never
    /// inside the event-tap callback.
    private let ioQueue = DispatchQueue(label: "com.khm.snippets.usage-io", qos: .utility)

    private var flushWorkItem: DispatchWorkItem?
    private var firstDirtyAt: Double?
    private var isDirty = false
    private var lastRecorded: (id: UUID, eventTag: Int, at: Double)?

    private var cachedWeights: [UUID: Double] = [:]
    private var cachedBindings: [String: [UUID: Double]] = [:]

    init() {
        isKilled = Self.flag(Self.killSwitchKey, default: false)
        document = .empty(now: Date().timeIntervalSince1970)
        guard !isKilled else { return }
        // Created here rather than lazily on first flush: creating it later
        // would mutate the parent directory's vnode at an arbitrary moment and
        // trip the library store's file monitor.
        try? FileManager.default.createDirectory(
            at: SnippetStorageLocations.usageFolderURL, withIntermediateDirectories: true)
        loadSynchronously()
    }

    // MARK: - Reading (hot path)

    /// One `exp2` and two copy-on-write retains. This is the only frecency work
    /// reachable synchronously from the event-tap callback.
    func makeRankingSnapshot() -> FrecencySnapshot {
        guard !isKilled, isRankingEnabled else { return .empty }
        guard !document.records.isEmpty || !document.bindings.isEmpty else { return .empty }

        let growth = SnippetFrecency.growth(
            epoch: document.epoch,
            now: now(),
            halfLifeSeconds: SnippetFrecency.halfLifeSeconds
        )
        return FrecencySnapshot(
            weights: cachedWeights,
            bindings: isSelectionMemoryEnabled ? cachedBindings : [:],
            cutoff: SnippetFrecency.meaningfulnessFloor * growth
        )
    }

    // MARK: - Recording

    func record(_ event: Event, snippetID: UUID, bindingQuery: String? = nil) {
        guard !isKilled else { return }
        let timestamp = now()
        guard timestamp.isFinite else { return }

        if SnippetFrecency.shouldCoalesce(
            lastID: lastRecorded?.id,
            lastEventTag: lastRecorded?.eventTag,
            lastAt: lastRecorded?.at,
            id: snippetID,
            eventTag: event.rawValue,
            now: timestamp
        ) { return }
        lastRecorded = (snippetID, event.rawValue, timestamp)

        rebaseIfNeeded(now: timestamp)
        let growth = SnippetFrecency.growth(
            epoch: document.epoch, now: timestamp, halfLifeSeconds: SnippetFrecency.halfLifeSeconds)

        var record = document.records[snippetID.uuidString] ?? SnippetUsageRecord()
        record.weight = SnippetFrecency.clamp(weight: record.weight + event.weight * growth)
        record.count = min(record.count &+ 1, Int.max / 2)
        record.lastUsedAt = max(record.lastUsedAt, min(timestamp, SnippetFrecency.maxTimestamp))
        document.records[snippetID.uuidString] = record

        if isSelectionMemoryEnabled,
           let query = bindingQuery,
           let key = SnippetFrecency.bindingKey(for: query) {
            var table = document.bindings[key] ?? [:]
            for other in table.keys where other != snippetID.uuidString {
                table[other] = (table[other] ?? 0) * SnippetFrecency.bindingCompetitorDecay
            }
            // Saturation is what makes "one correction escapes a wrong binding"
            // a theorem instead of a slogan.
            let raised = (table[snippetID.uuidString] ?? 0) + growth
            table[snippetID.uuidString] = SnippetFrecency.clamp(
                weight: min(raised, SnippetFrecency.bindingWeightCap * growth))
            document.bindings[key] = table
        }

        rebuildCaches()
        markDirty(at: timestamp)
    }

    // MARK: - Targeted and full resets

    /// "Reset Usage" from a row's context menu.
    ///
    /// Also stamps the reset markers, because the join is a `max` and cannot
    /// express a deletion: without a marker the next merge would resurrect the
    /// record straight off disk. The cost is that a concurrent second instance
    /// of the app loses its unflushed additions — acceptable, since the CLI
    /// never touches this file and the alternative is a reset that silently
    /// does not stick.
    func forget(snippetID: UUID) {
        guard !isKilled else { return }
        let timestamp = now()
        let key = snippetID.uuidString

        document.records.removeValue(forKey: key)
        for (bindingKey, var table) in document.bindings {
            guard table.removeValue(forKey: key) != nil else { continue }
            if table.isEmpty {
                document.bindings.removeValue(forKey: bindingKey)
            } else {
                document.bindings[bindingKey] = table
            }
        }

        document.recordsClearedAt = max(document.recordsClearedAt, timestamp)
        document.bindingsClearedAt = max(document.bindingsClearedAt, timestamp)
        if lastRecorded?.id == snippetID { lastRecorded = nil }

        rebuildCaches()
        markDirty(at: timestamp)
        flush()
    }

    /// "Reset Usage Data" from Settings. Writes an empty document carrying the
    /// reset marker rather than deleting the file: the marker is what stops a
    /// merge from bringing everything back, and an empty document holds no user
    /// data anyway.
    func eraseAll() {
        guard !isKilled else { return }
        let timestamp = now()

        document.records = [:]
        document.bindings = [:]
        document.recordsClearedAt = max(document.recordsClearedAt, timestamp)
        document.bindingsClearedAt = max(document.bindingsClearedAt, timestamp)
        lastRecorded = nil

        rebuildCaches()
        markDirty(at: timestamp)
        flush()
    }

    /// Switching selection memory off promises deletion, not merely "stop
    /// collecting" — so a guard in `record` alone would not be enough.
    func forgetAllBindings() {
        guard !isKilled else { return }
        let timestamp = now()

        document.bindings = [:]
        document.bindingsClearedAt = max(document.bindingsClearedAt, timestamp)

        rebuildCaches()
        markDirty(at: timestamp)
        flush()
    }

    // MARK: - Inventory for the UI

    var trackedSnippetCount: Int { document.records.count }

    func usageCount(for id: UUID) -> Int? {
        document.records[id.uuidString]?.count
    }

    var mostUsedSummary: (name: String, count: Int)? {
        let ranked = document.records
            .filter { $0.value.count > 0 }
            .max { lhs, rhs in
                if lhs.value.weight != rhs.value.weight { return lhs.value.weight < rhs.value.weight }
                return lhs.key > rhs.key
            }
        guard let ranked,
              let id = UUID(uuidString: ranked.key),
              let name = snippetDisplayName?(id) else { return nil }
        return (name, ranked.value.count)
    }

    var storageFootprintDescription: String {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: SnippetStorageLocations.usageFileURL.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: bytes)) on this Mac"
    }

    // MARK: - Saving

    private func markDirty(at timestamp: Double) {
        guard !isReadOnly, !isKilled else { return }
        isDirty = true
        if firstDirtyAt == nil { firstDirtyAt = timestamp }

        flushWorkItem?.cancel()
        let delay = SnippetFrecency.flushDelay(now: timestamp, firstDirtyAt: firstDirtyAt)
        let item = DispatchWorkItem { MainActor.assumeIsolated { self.flush() } }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// `synchronously: true` is mandatory on the terminate and sleep paths:
    /// `applicationWillTerminate` returns and the process dies well before an
    /// `ioQueue.async` block would run, so an async flush there writes nothing.
    func flush(synchronously: Bool = false) {
        flushWorkItem?.cancel()
        flushWorkItem = nil

        guard isDirty, !isReadOnly, !isKilled else { return }
        isDirty = false
        firstDirtyAt = nil

        let snapshot = document
        let live = liveSnippetIDs?()
        let timestamp = now()
        let work: () -> Void = {
            _ = SnippetUsageFile.mergeAndWrite(snapshot, liveIDs: live, now: timestamp)
        }

        if synchronously {
            ioQueue.sync(execute: work)
        } else {
            ioQueue.async(execute: work)
        }
    }

    // MARK: - Loading

    /// Total: never throws, never blocks the app on bad data.
    ///
    /// Synchronous at launch on purpose. An async load would mean the first
    /// suggestion session after every launch silently ranks as if there were no
    /// data — nondeterminism nobody could ever reproduce from a bug report.
    private func loadSynchronously() {
        guard let data = try? Data(contentsOf: SnippetStorageLocations.usageFileURL) else { return }

        // The version probe runs FIRST. Decoding a future format may fail
        // outright, and when it does the failure has to land in read-only:
        // otherwise an older build overwrites a newer build's data in a
        // directory both of them share.
        if let probe = try? JSONDecoder().decode(SnippetUsageVersionProbe.self, from: data),
           let version = probe.v,
           version > SnippetUsageDocument.currentVersion {
            Diagnostics.record(.storageState(
                area: .usage,
                state: .versionTooNew,
                value: version))
            isReadOnly = true
            return
        }

        guard let decoded = try? JSONDecoder().decode(SnippetUsageDocument.self, from: data) else {
            Diagnostics.record(.storageState(area: .usage, state: .recreated, value: nil))
            return
        }
        guard decoded.version <= SnippetUsageDocument.currentVersion else {
            isReadOnly = true
            return
        }

        document = SnippetUsageFile.rebasedIfNeeded(
            SnippetUsageFile.sanitized(decoded), now: Date().timeIntervalSince1970)
        rebuildCaches()
    }

    private func rebaseIfNeeded(now timestamp: Double) {
        let rebased = SnippetUsageFile.rebasedIfNeeded(document, now: timestamp)
        guard rebased.epoch != document.epoch || rebased.halfLifeDays != document.halfLifeDays else { return }
        document = rebased
        rebuildCaches()
    }

    /// The comparator indexes by `UUID`; the document is keyed by `uuidString`
    /// so the file stays readable. Converting once per mutation keeps the
    /// keystroke path free of string parsing.
    private func rebuildCaches() {
        cachedWeights = document.records.reduce(into: [:]) { accumulated, entry in
            guard let id = UUID(uuidString: entry.key) else { return }
            accumulated[id] = entry.value.weight
        }
        cachedBindings = document.bindings.reduce(into: [:]) { accumulated, entry in
            let table = entry.value.reduce(into: [UUID: Double]()) { inner, pair in
                guard let id = UUID(uuidString: pair.key) else { return }
                inner[id] = pair.value
            }
            guard !table.isEmpty else { return }
            accumulated[entry.key] = table
        }
    }
}
