import Foundation

/// Presentation work shared by the library, tag controls, and search callers.
/// Owned by SnippetStore on its actor; unchanged arrays share their storage.
nonisolated struct SnippetLibraryProjection {
    struct Snapshot {
        let sorted: [Snippet]
        let tagUsage: [(tag: String, count: Int)]
        let tags: [String]
        let tagKeys: Set<String>
    }

    private var ordinary: [Snippet] = []
    private var secure: [Snippet] = []
    private var localeIdentifier: String?
    private var cached: Snapshot?
    private(set) var buildCount = 0

    mutating func snapshot(ordinary: [Snippet], secure: [Snippet], locale: Locale = .current) -> Snapshot {
        if let cached, self.ordinary == ordinary, self.secure == secure,
           localeIdentifier == locale.identifier { return cached }
        let combined = ordinary + secure
        var canonicalTags: [String: String] = [:]
        var counts: [String: Int] = [:]
        for snippet in combined {
            for tag in snippet.tags {
                let key = SnippetTagging.filterKey(for: tag)
                if canonicalTags[key] == nil { canonicalTags[key] = tag }
                counts[key, default: 0] += 1
            }
        }
        let usage = canonicalTags.sorted {
            $0.value.compare($1.value, options: [.caseInsensitive], locale: locale) == .orderedAscending
        }.map { (tag: $0.value, count: counts[$0.key] ?? 0) }
        let result = Snapshot(sorted: SnippetDisplayOrder.sorted(combined), tagUsage: usage,
                              tags: usage.map(\.tag), tagKeys: Set(canonicalTags.keys))
        self.ordinary = ordinary
        self.secure = secure
        localeIdentifier = locale.identifier
        cached = result
        buildCount += 1
        return result
    }
}

/// An immutable, ordered projection of the library's searchable fields.
///
/// Building a snapshot folds user text once. Evaluating subsequent queries only walks
/// those already-normalized strings. The snapshot contains the `Snippet` values supplied
/// by the caller, including secure-shell values, but it never asks a vault for plaintext.
nonisolated final class SnippetSearchSnapshot: Sendable {
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
        let searchableFields: [PreparedSubstringSearch.Field]
        let fuzzyMetadata: [String]
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
    private let sourceSnippets: [Snippet]
    private let normalizedEntriesByID: [UUID: NormalizedEntry]

    private init(
        snippets: [Snippet],
        locale: Locale,
        maximumNormalizedBytes: Int,
        previous: SnippetSearchSnapshot?
    ) {
        localeIdentifier = locale.identifier
        sourceSnippets = snippets
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
                // An unnamed snippet displays its first body line. Do not turn
                // that fallback into fuzzy body search: only explicit metadata.
                let fuzzyMetadata = (snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? [] : [searchableFields[0]]) + [searchableFields[1]] + searchableFields.dropFirst(3)
                let tagKeys = Set(snippet.tags.map(SnippetTagging.filterKey(for:)))
                let entryBytes = Self.estimatedBytes(
                    searchableFields: searchableFields,
                    tagKeys: tagKeys
                ) + 32 + fuzzyMetadata.reduce(0) { $0 + 32 + $1.utf8.count }
                    + searchableFields.count * 64
                let candidate = NormalizedEntry(
                    source: source,
                    searchableFields: searchableFields.map(PreparedSubstringSearch.Field.init),
                    fuzzyMetadata: fuzzyMetadata,
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

    func results(searchText: String, activeTagKeys: Set<String>) -> [Snippet] {
        evaluate(searchText: searchText, activeTagKeys: activeTagKeys).snippets
    }

    func evaluate(searchText: String, activeTagKeys: Set<String>) -> Evaluation {
        let query = Self.normalizedQuery(searchText, localeIdentifier: localeIdentifier)
        let prepared = FuzzyMatch.PreparedQuery(query, locale: Locale(identifier: localeIdentifier))
        return evaluation(matching: matchingIndices(query: query, prepared: prepared, candidates: nil),
                          activeTagKeys: activeTagKeys)
    }

    fileprivate var entryCount: Int { entries.count }

    fileprivate func matchingIndices(
        query: String, prepared: FuzzyMatch.PreparedQuery, candidates: [Int]?
    ) -> [Int] {
        let literal = PreparedSubstringSearch.Query(query)
        func matches(_ index: Int) -> Bool {
            if query.isEmpty { return true }
            let entry = entries[index]
            if let normalized = entry.normalized {
                // Keep full-body substring search and extend only metadata with
                // subsequence matching. Filtering preserves canonical list order.
                let fields = normalized.searchableFields
                return fields[0].contains(literal) || fields[1].contains(literal)
                    || fields.dropFirst(3).contains { $0.contains(literal) }
                    || normalized.fuzzyMetadata.contains { FuzzyMatch.matches(query: prepared, foldedTarget: $0) }
                    || fields[2].contains(literal)
            }
            return Self.uncachedMatch(entry.snippet, query: query, prepared: prepared,
                                      localeIdentifier: localeIdentifier)
        }
        if let candidates { return candidates.filter(matches) }
        return entries.indices.filter(matches)
    }

    fileprivate func evaluation(matching indices: [Int], activeTagKeys: Set<String>) -> Evaluation {
        let searchMatches = indices.map { entries[$0].snippet }
        guard !activeTagKeys.isEmpty else { return Evaluation(searchMatches: searchMatches, snippets: searchMatches) }
        let matches = indices.compactMap { index -> Snippet? in
            let entry = entries[index]
            if let normalized = entry.normalized {
                guard activeTagKeys.isSubset(of: normalized.tagKeys) else { return nil }
            } else {
                guard activeTagKeys.allSatisfy({ entry.snippet.hasTag(withKey: $0) }) else { return nil }
            }
            return entry.snippet
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
        return sourceSnippets == snippets
    }

    private static func uncachedMatch(
        _ snippet: Snippet,
        query: String,
        prepared: FuzzyMatch.PreparedQuery,
        localeIdentifier: String
    ) -> Bool {
        let locale = Locale(identifier: localeIdentifier)
        let fields = [
            snippet.displayName,
            snippet.normalizedKeyword,
            snippet.content,
        ] + snippet.tags
        if fields.contains(where: { $0.folding(options: foldingOptions, locale: locale).contains(query) }) {
            return true
        }
        return ([snippet.name, snippet.normalizedKeyword] + snippet.tags).contains {
            FuzzyMatch.matches(query: prepared, foldedTarget: $0.folding(options: foldingOptions, locale: locale))
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
        let lastCandidateCount: Int
    }

    private struct Scan {
        let snapshot: SnippetSearchSnapshot
        let query: String
        let prepared: FuzzyMatch.PreparedQuery
        let matches: [Int]
    }

    private static let defaultMaximumNormalizedBytes = 16 * 1_024 * 1_024

    private let maximumNormalizedBytes: Int
    private let beforeSnapshotBuildForTesting: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var latestSnapshot: SnippetSearchSnapshot?
    private var snapshotBuildCount = 0
    private var normalizedEntryBuildCount = 0
    private var lastSnapshotEntryBuildCount = 0
    private var nextRequestSequence: UInt64 = 0
    private var committedBuildSequence: UInt64 = 0
    private var latestScan: Scan?
    private var scanSequence: UInt64 = 0
    private var lastCandidateCount = 0

    init(
        maximumNormalizedBytes: Int = SnippetSearchIndex.defaultMaximumNormalizedBytes,
        beforeSnapshotBuildForTesting: (@Sendable () -> Void)? = nil
    ) {
        self.maximumNormalizedBytes = max(0, maximumNormalizedBytes)
        self.beforeSnapshotBuildForTesting = beforeSnapshotBuildForTesting
    }

    func results(
        in snippets: [Snippet],
        searchText: String,
        activeTagKeys: Set<String>,
        locale: Locale = .current
    ) -> [Snippet] {
        evaluate(in: snippets, searchText: searchText, activeTagKeys: activeTagKeys, locale: locale).snippets
    }

    func evaluate(
        in snippets: [Snippet], searchText: String, activeTagKeys: Set<String>, locale: Locale = .current
    ) -> SnippetSearchSnapshot.Evaluation {
        let snapshot = snapshot(for: snippets, locale: locale)
        let query = SnippetSearchSnapshot.normalizedQuery(searchText, locale: locale)
        let prepared = FuzzyMatch.PreparedQuery(query, locale: locale)
        lock.lock()
        scanSequence &+= 1
        let sequence = scanSequence
        let previous = latestScan
        lock.unlock()
        // Narrow only a normalized prefix extension over this exact snapshot.
        // Keep pre-tag matches so relaxing a tag filter cannot hide valid rows.
        let candidates: [Int]?
        if let previous, previous.snapshot === snapshot,
           query.hasPrefix(previous.query), prepared.extends(previous.prepared) {
            candidates = previous.matches
        } else {
            candidates = nil
        }
        let matches = snapshot.matchingIndices(query: query, prepared: prepared, candidates: candidates)
        lock.lock()
        if scanSequence == sequence, latestSnapshot === snapshot {
            latestScan = Scan(snapshot: snapshot, query: query, prepared: prepared, matches: matches)
            lastCandidateCount = candidates?.count ?? snapshot.entryCount
        }
        lock.unlock()
        return snapshot.evaluation(matching: matches, activeTagKeys: activeTagKeys)
    }

    func snapshot(
        for snippets: [Snippet],
        locale: Locale = .current
    ) -> SnippetSearchSnapshot {
        lock.lock()
        nextRequestSequence &+= 1
        let requestSequence = nextRequestSequence
        if let latestSnapshot,
           latestSnapshot.represents(
               snippets,
               locale: locale,
               maximumNormalizedBytes: maximumNormalizedBytes
           ) {
            // A cache hit is still a newer request. Advancing the committed sequence
            // prevents an older in-flight build from replacing this requested state.
            committedBuildSequence = requestSequence
            lastSnapshotEntryBuildCount = 0
            lock.unlock()
            return latestSnapshot
        }
        let previous = latestSnapshot
        lock.unlock()

        // Normalization intentionally happens outside the lock. A synchronous UI
        // refresh can therefore supersede a stale background query without waiting
        // for that older scan. The sequence below prevents the older build from later
        // replacing the newer cache.
        beforeSnapshotBuildForTesting?()
        let snapshot = SnippetSearchSnapshot.build(
            from: snippets,
            locale: locale,
            maximumNormalizedBytes: maximumNormalizedBytes,
            reusing: previous
        )

        lock.lock()
        snapshotBuildCount += 1
        normalizedEntryBuildCount += snapshot.normalizedEntryBuildCount
        if requestSequence >= committedBuildSequence {
            latestSnapshot = snapshot
            latestScan = nil
            committedBuildSequence = requestSequence
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
            uncachedEntryCount: latestSnapshot?.uncachedEntryCount ?? 0,
            lastCandidateCount: lastCandidateCount
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
            let evaluation = index.evaluate(in: request.snippets, searchText: request.searchText,
                                            activeTagKeys: request.activeTagKeys, locale: request.locale)
            guard isCurrent(request.generation) else { continue }
            request.completion(Response(
                generation: request.generation,
                searchMatches: request.includeSearchMatches ? evaluation.searchMatches : [],
                snippets: evaluation.snippets
            ))
        }
    }
}
