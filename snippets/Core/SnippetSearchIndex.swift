import Foundation

/// An immutable, ordered projection of the library's searchable fields.
///
/// Building a snapshot folds user text once. Evaluating subsequent queries only walks
/// those already-normalized strings. The snapshot contains the `Snippet` values supplied
/// by the caller, including secure-shell values, but it never asks a vault for plaintext.
nonisolated struct SnippetSearchSnapshot: Sendable {
    nonisolated struct Evaluation: Sendable {
        let searchMatches: [Snippet]
        let snippets: [Snippet]
    }

    private struct Source: Equatable, Sendable {
        let name: String
        let keyword: String
        let content: String
        let tags: [String]

        init(_ snippet: Snippet) {
            name = snippet.name
            keyword = snippet.keyword
            content = snippet.content
            tags = snippet.tags
        }
    }

    private struct NormalizedEntry: Sendable {
        let source: Source
        let searchableFields: [String]
        let tagKeys: Set<String>
        let estimatedBytes: Int
    }

    private struct Entry: Sendable {
        let snippet: Snippet
        let normalized: NormalizedEntry?
    }

    private static let foldingOptions: String.CompareOptions = [
        .caseInsensitive,
        .diacriticInsensitive,
    ]

    private let localeIdentifier: String
    private let maximumNormalizedBytes: Int
    private let entries: [Entry]
    private let normalizedEntriesByID: [UUID: NormalizedEntry]

    private init(
        snippets: [Snippet],
        locale: Locale,
        maximumNormalizedBytes: Int,
        previous: SnippetSearchSnapshot?
    ) {
        localeIdentifier = locale.identifier
        self.maximumNormalizedBytes = maximumNormalizedBytes
        let canReusePrevious = previous?.localeIdentifier == localeIdentifier
            && previous?.maximumNormalizedBytes == maximumNormalizedBytes
        let previousEntries = canReusePrevious ? previous?.normalizedEntriesByID ?? [:] : [:]

        var entries: [Entry] = []
        entries.reserveCapacity(snippets.count)
        var normalizedEntriesByID: [UUID: NormalizedEntry] = [:]
        normalizedEntriesByID.reserveCapacity(snippets.count)
        var buildCount = 0
        var estimatedBytes = 0
        var fallbackCount = 0

        for snippet in snippets {
            let source = Source(snippet)
            let normalized: NormalizedEntry?
            if let cached = previousEntries[snippet.id], cached.source == source {
                normalized = cached.estimatedBytes <= maximumNormalizedBytes - estimatedBytes
                    ? cached
                    : nil
            } else {
                let fields = [
                    snippet.displayName,
                    snippet.normalizedKeyword,
                    snippet.content,
                ] + snippet.tags
                let searchableFields = fields.map {
                    $0.folding(options: Self.foldingOptions, locale: locale)
                }
                let tagKeys = Set(snippet.tags.map(SnippetTagging.filterKey(for:)))
                let entryBytes = Self.estimatedBytes(
                    searchableFields: searchableFields,
                    tagKeys: tagKeys
                )
                let candidate = NormalizedEntry(
                    source: source,
                    searchableFields: searchableFields,
                    tagKeys: tagKeys,
                    estimatedBytes: entryBytes
                )
                buildCount += 1
                if entryBytes <= maximumNormalizedBytes - estimatedBytes {
                    normalized = candidate
                } else {
                    normalized = nil
                }
            }

            entries.append(Entry(snippet: snippet, normalized: normalized))
            if let normalized {
                normalizedEntriesByID[snippet.id] = normalized
                estimatedBytes += normalized.estimatedBytes
            } else {
                fallbackCount += 1
            }
        }

        self.entries = entries
        self.normalizedEntriesByID = normalizedEntriesByID
        normalizedEntryBuildCount = buildCount
        estimatedNormalizedBytes = estimatedBytes
        uncachedEntryCount = fallbackCount
    }

    /// Number of entries normalized while creating this snapshot. Kept internal for
    /// deterministic performance regression tests; it contains no user data.
    let normalizedEntryBuildCount: Int
    let estimatedNormalizedBytes: Int
    let uncachedEntryCount: Int

    static func build(
        from snippets: [Snippet],
        locale: Locale = .current,
        maximumNormalizedBytes: Int,
        reusing previous: SnippetSearchSnapshot? = nil
    ) -> SnippetSearchSnapshot {
        SnippetSearchSnapshot(
            snippets: snippets,
            locale: locale,
            maximumNormalizedBytes: maximumNormalizedBytes,
            previous: previous
        )
    }

    func results(
        searchText: String,
        activeTagKeys: Set<String>
    ) -> [Snippet] {
        let query = Self.normalizedQuery(searchText, localeIdentifier: localeIdentifier)
        return entries.compactMap { entry in
            if let normalized = entry.normalized {
                guard activeTagKeys.isSubset(of: normalized.tagKeys) else { return nil }
                guard query.isEmpty || normalized.searchableFields.contains(where: {
                    $0.contains(query)
                }) else { return nil }
            } else {
                guard activeTagKeys.allSatisfy({ entry.snippet.hasTag(withKey: $0) }) else {
                    return nil
                }
                guard query.isEmpty || Self.uncachedMatch(
                    entry.snippet,
                    query: query,
                    localeIdentifier: localeIdentifier
                ) else { return nil }
            }
            return entry.snippet
        }
    }

    func evaluate(
        searchText: String,
        activeTagKeys: Set<String>
    ) -> Evaluation {
        if activeTagKeys.isEmpty {
            let matches = results(searchText: searchText, activeTagKeys: [])
            return Evaluation(searchMatches: matches, snippets: matches)
        }

        let query = Self.normalizedQuery(searchText, localeIdentifier: localeIdentifier)
        var searchMatches: [Snippet] = []
        searchMatches.reserveCapacity(entries.count)
        var matches: [Snippet] = []
        matches.reserveCapacity(entries.count)

        for entry in entries {
            let matchesSearch: Bool
            let matchesTags: Bool
            if let normalized = entry.normalized {
                matchesSearch = query.isEmpty || normalized.searchableFields.contains(where: {
                    $0.contains(query)
                })
                matchesTags = activeTagKeys.isSubset(of: normalized.tagKeys)
            } else {
                matchesSearch = query.isEmpty || Self.uncachedMatch(
                    entry.snippet,
                    query: query,
                    localeIdentifier: localeIdentifier
                )
                matchesTags = activeTagKeys.allSatisfy {
                    entry.snippet.hasTag(withKey: $0)
                }
            }
            guard matchesSearch else { continue }
            searchMatches.append(entry.snippet)
            if matchesTags {
                matches.append(entry.snippet)
            }
        }
        return Evaluation(searchMatches: searchMatches, snippets: matches)
    }

    static func normalizedQuery(_ searchText: String, locale: Locale = .current) -> String {
        normalizedQuery(searchText, localeIdentifier: locale.identifier)
    }

    /// Empty searches deliberately avoid building a body index. This keeps startup and
    /// ordinary unfiltered store refreshes proportional to tags rather than body size.
    static func resultsForEmptySearch(
        in snippets: [Snippet],
        activeTagKeys: Set<String>
    ) -> [Snippet] {
        guard !activeTagKeys.isEmpty else { return snippets }
        return snippets.filter { snippet in
            activeTagKeys.allSatisfy { snippet.hasTag(withKey: $0) }
        }
    }

    private static func normalizedQuery(_ searchText: String, localeIdentifier: String) -> String {
        searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: foldingOptions,
                locale: Locale(identifier: localeIdentifier)
            )
    }

    fileprivate func represents(
        _ snippets: [Snippet],
        locale: Locale,
        maximumNormalizedBytes: Int
    ) -> Bool {
        guard locale.identifier == localeIdentifier,
              maximumNormalizedBytes == self.maximumNormalizedBytes,
              snippets.count == entries.count else { return false }
        return zip(entries, snippets).allSatisfy { $0.snippet == $1 }
    }

    private static func uncachedMatch(
        _ snippet: Snippet,
        query: String,
        localeIdentifier: String
    ) -> Bool {
        let locale = Locale(identifier: localeIdentifier)
        let fields = [
            snippet.displayName,
            snippet.normalizedKeyword,
            snippet.content,
        ] + snippet.tags
        return fields.contains {
            $0.folding(options: foldingOptions, locale: locale).contains(query)
        }
    }

    private static func estimatedBytes(
        searchableFields: [String],
        tagKeys: Set<String>
    ) -> Int {
        // The source strings and the snapshot's Snippet values retain the same
        // copy-on-write buffers as the caller. Count only newly allocated folded
        // payloads, plus a conservative allowance for String/Array/Set storage.
        let fixedOverhead = 256 + ((searchableFields.count + tagKeys.count) * 32)
        return (searchableFields + Array(tagKeys)).reduce(fixedOverhead) { partial, string in
            let (sum, overflow) = partial.addingReportingOverflow(string.utf8.count)
            return overflow ? Int.max : sum
        }
    }
}

/// Thread-safe owner of the latest immutable search snapshot.
///
/// Callers copy the store's display array first, then hand that value to this index. No
/// `SnippetStore` lock is held while fields are normalized or a query scans the snapshot.
nonisolated final class SnippetSearchIndex: @unchecked Sendable {
    nonisolated struct Statistics: Equatable, Sendable {
        let snapshotBuildCount: Int
        let normalizedEntryBuildCount: Int
        let lastSnapshotEntryBuildCount: Int
        let estimatedNormalizedBytes: Int
        let uncachedEntryCount: Int
    }

    private static let defaultMaximumNormalizedBytes = 16 * 1_024 * 1_024

    private let maximumNormalizedBytes: Int
    private let lock = NSLock()
    private var latestSnapshot: SnippetSearchSnapshot?
    private var snapshotBuildCount = 0
    private var normalizedEntryBuildCount = 0
    private var lastSnapshotEntryBuildCount = 0
    private var nextBuildSequence: UInt64 = 0
    private var committedBuildSequence: UInt64 = 0

    init(maximumNormalizedBytes: Int = SnippetSearchIndex.defaultMaximumNormalizedBytes) {
        self.maximumNormalizedBytes = max(0, maximumNormalizedBytes)
    }

    func results(
        in snippets: [Snippet],
        searchText: String,
        activeTagKeys: Set<String>,
        locale: Locale = .current
    ) -> [Snippet] {
        let snapshot = snapshot(for: snippets, locale: locale)
        return snapshot.results(searchText: searchText, activeTagKeys: activeTagKeys)
    }

    func snapshot(
        for snippets: [Snippet],
        locale: Locale = .current
    ) -> SnippetSearchSnapshot {
        lock.lock()
        if let latestSnapshot,
           latestSnapshot.represents(
               snippets,
               locale: locale,
               maximumNormalizedBytes: maximumNormalizedBytes
           ) {
            lastSnapshotEntryBuildCount = 0
            lock.unlock()
            return latestSnapshot
        }
        let previous = latestSnapshot
        nextBuildSequence &+= 1
        let buildSequence = nextBuildSequence
        lock.unlock()

        // Normalization intentionally happens outside the lock. A synchronous UI
        // refresh can therefore supersede a stale background query without waiting
        // for that older scan. The sequence below prevents the older build from later
        // replacing the newer cache.
        let snapshot = SnippetSearchSnapshot.build(
            from: snippets,
            locale: locale,
            maximumNormalizedBytes: maximumNormalizedBytes,
            reusing: previous
        )

        lock.lock()
        snapshotBuildCount += 1
        normalizedEntryBuildCount += snapshot.normalizedEntryBuildCount
        if buildSequence >= committedBuildSequence {
            latestSnapshot = snapshot
            committedBuildSequence = buildSequence
            lastSnapshotEntryBuildCount = snapshot.normalizedEntryBuildCount
        }
        lock.unlock()
        return snapshot
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            snapshotBuildCount: snapshotBuildCount,
            normalizedEntryBuildCount: normalizedEntryBuildCount,
            lastSnapshotEntryBuildCount: lastSnapshotEntryBuildCount,
            estimatedNormalizedBytes: latestSnapshot?.estimatedNormalizedBytes ?? 0,
            uncachedEntryCount: latestSnapshot?.uncachedEntryCount ?? 0
        )
    }
}

/// Runs search-index work on a serial worker queue and identifies the newest request.
/// While one scan is executing, newer submissions replace one pending slot rather than
/// retaining a full library array for every keystroke. Controllers still validate the
/// generation when hopping back to their UI actor, so a result that was current on the
/// worker cannot overwrite a newer synchronous reload.
nonisolated final class SnippetSearchPipeline: @unchecked Sendable {
    nonisolated struct Response: Sendable {
        let generation: UInt64
        let searchMatches: [Snippet]
        let snippets: [Snippet]
    }

    private struct Request: Sendable {
        let generation: UInt64
        let snippets: [Snippet]
        let searchText: String
        let activeTagKeys: Set<String>
        let includeSearchMatches: Bool
        let locale: Locale
        let completion: @Sendable (Response) -> Void
    }

    private let index: SnippetSearchIndex
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var latestGeneration: UInt64 = 0
    private var pendingRequest: Request?
    private var workerScheduled = false

    init(
        index: SnippetSearchIndex,
        queue: DispatchQueue = DispatchQueue(
            label: "com.khm.snippets.search",
            qos: .userInitiated
        )
    ) {
        self.index = index
        self.queue = queue
    }

    @discardableResult
    func submit(
        snippets: [Snippet],
        searchText: String,
        activeTagKeys: Set<String>,
        includeSearchMatches: Bool = false,
        locale: Locale = .current,
        completion: @escaping @Sendable (Response) -> Void
    ) -> UInt64 {
        stateLock.lock()
        latestGeneration &+= 1
        let generation = latestGeneration
        pendingRequest = Request(
            generation: generation,
            snippets: snippets,
            searchText: searchText,
            activeTagKeys: activeTagKeys,
            includeSearchMatches: includeSearchMatches,
            locale: locale,
            completion: completion
        )
        let shouldScheduleWorker = !workerScheduled
        if shouldScheduleWorker {
            workerScheduled = true
        }
        stateLock.unlock()

        if shouldScheduleWorker {
            queue.async { [self] in
                drainPendingRequests()
            }
        }
        return generation
    }

    func cancelPending() {
        stateLock.lock()
        latestGeneration &+= 1
        pendingRequest = nil
        stateLock.unlock()
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestGeneration == generation
    }

    private func drainPendingRequests() {
        while true {
            stateLock.lock()
            guard let request = pendingRequest else {
                workerScheduled = false
                stateLock.unlock()
                return
            }
            pendingRequest = nil
            stateLock.unlock()

            guard isCurrent(request.generation) else { continue }
            let snapshot = index.snapshot(for: request.snippets, locale: request.locale)
            let evaluation: SnippetSearchSnapshot.Evaluation
            if request.includeSearchMatches {
                evaluation = snapshot.evaluate(
                    searchText: request.searchText,
                    activeTagKeys: request.activeTagKeys
                )
            } else {
                let matches = snapshot.results(
                    searchText: request.searchText,
                    activeTagKeys: request.activeTagKeys
                )
                evaluation = SnippetSearchSnapshot.Evaluation(
                    searchMatches: [],
                    snippets: matches
                )
            }
            guard isCurrent(request.generation) else { continue }
            request.completion(Response(
                generation: request.generation,
                searchMatches: evaluation.searchMatches,
                snippets: evaluation.snippets
            ))
        }
    }
}
