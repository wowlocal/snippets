import Foundation

nonisolated struct SnippetLibraryQuery {
    struct Results: Equatable {
        let pinned: [Snippet]
        let snippets: [Snippet]

        var all: [Snippet] { pinned + snippets }
        var isEmpty: Bool { pinned.isEmpty && snippets.isEmpty }
    }

    static func results(
        in snippets: [Snippet],
        searchText: String,
        activeTagKeys: Set<String>
    ) -> Results {
        sharedSearchIndex.results(
            in: snippets,
            searchText: searchText,
            activeTagKeys: activeTagKeys
        )
    }

    /// The phone library calls the static API above, so its index has to survive the
    /// individual keystroke-driven calls. `SnippetLibrarySearchIndex` is internally
    /// locked rather than actor-isolated because query evaluation is a synchronous,
    /// pure-looking operation and is also exercised outside the main actor in tests.
    private static let sharedSearchIndex = SnippetLibrarySearchIndex()
}

/// A bounded, exact cache of the expensive folded search fields.
///
/// `SnippetStore` returns fresh arrays of value-typed `Snippet`s on every reload. The
/// strings inside unchanged values keep their copy-on-write storage, so comparing the
/// source fields is cheap while repeatedly applying Unicode case/diacritic folding to
/// a long body is not. The full relevant source is retained in each entry so a caller
/// that changes a field without advancing `updatedAt` still invalidates deterministically.
/// Both source and folded UTF-8 payloads count toward the byte budget.
nonisolated final class SnippetLibrarySearchIndex: @unchecked Sendable {
    nonisolated struct Statistics: Equatable, Sendable {
        let cachedSnippetCount: Int
        let estimatedPayloadBytes: Int
        let normalizedEntryBuildCount: Int
    }

    private struct Source: Equatable {
        let updatedAt: Date
        let name: String
        let keyword: String
        let content: String
        let tags: [String]

        init(_ snippet: Snippet) {
            updatedAt = snippet.updatedAt
            name = snippet.name
            keyword = snippet.keyword
            content = snippet.content
            tags = snippet.tags
        }
    }

    private struct Entry {
        let source: Source
        let foldedFields: [String]
        let estimatedPayloadBytes: Int
    }

    private static let defaultMaximumPayloadBytes = 8 * 1_024 * 1_024
    private static let defaultMaximumEntryCount = 2_048
    private static let foldingOptions: String.CompareOptions = [
        .caseInsensitive,
        .diacriticInsensitive,
    ]

    private let maximumPayloadBytes: Int
    private let maximumEntryCount: Int
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var estimatedPayloadBytes = 0
    private var normalizedEntryBuildCount = 0
    private var localeIdentifier: String?

    init(
        maximumPayloadBytes: Int = SnippetLibrarySearchIndex.defaultMaximumPayloadBytes,
        maximumEntryCount: Int = SnippetLibrarySearchIndex.defaultMaximumEntryCount
    ) {
        self.maximumPayloadBytes = max(0, maximumPayloadBytes)
        self.maximumEntryCount = max(0, maximumEntryCount)
    }

    func results(
        in snippets: [Snippet],
        searchText: String,
        activeTagKeys: Set<String>
    ) -> SnippetLibraryQuery.Results {
        lock.lock()
        defer { lock.unlock() }

        let locale = Locale.current
        resetForLocaleChangeIfNeeded(locale)
        removeEntriesMissing(from: snippets)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: Self.foldingOptions, locale: locale)

        let filtered = snippets.filter { snippet in
            let matchesTags = activeTagKeys.allSatisfy { snippet.hasTag(withKey: $0) }
            guard matchesTags else { return false }
            guard !query.isEmpty else { return true }

            return entry(for: snippet, locale: locale).foldedFields.contains {
                $0.contains(query)
            }
        }

        return SnippetLibraryQuery.Results(
            pinned: filtered.filter(\.isPinned),
            snippets: filtered.filter { !$0.isPinned }
        )
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            cachedSnippetCount: entries.count,
            estimatedPayloadBytes: estimatedPayloadBytes,
            normalizedEntryBuildCount: normalizedEntryBuildCount
        )
    }

    private func entry(for snippet: Snippet, locale: Locale) -> Entry {
        let source = Source(snippet)
        if let cached = entries[snippet.id], cached.source == source {
            return cached
        }

        removeEntry(for: snippet.id)

        let searchableFields = [
            snippet.displayName,
            snippet.normalizedKeyword,
            snippet.content,
        ] + snippet.tags
        let foldedFields = searchableFields.map {
            $0.folding(options: Self.foldingOptions, locale: locale)
        }
        let payloadBytes = Self.estimatedBytes(
            source: source,
            foldedFields: foldedFields
        )
        let newEntry = Entry(
            source: source,
            foldedFields: foldedFields,
            estimatedPayloadBytes: payloadBytes
        )
        normalizedEntryBuildCount += 1

        // A very large body must not make the cache unbounded. It is still searched
        // correctly for this call; it simply gets normalized again for a later query.
        guard entries.count < maximumEntryCount,
              payloadBytes <= maximumPayloadBytes - estimatedPayloadBytes else {
            return newEntry
        }

        entries[snippet.id] = newEntry
        estimatedPayloadBytes += payloadBytes
        return newEntry
    }

    private func resetForLocaleChangeIfNeeded(_ locale: Locale) {
        let identifier = locale.identifier
        guard localeIdentifier != identifier else { return }
        entries.removeAll(keepingCapacity: true)
        estimatedPayloadBytes = 0
        localeIdentifier = identifier
    }

    private func removeEntriesMissing(from snippets: [Snippet]) {
        guard !entries.isEmpty else { return }
        let liveIDs = Set(snippets.map(\.id))
        let staleIDs = entries.keys.filter { !liveIDs.contains($0) }
        for id in staleIDs {
            removeEntry(for: id)
        }
    }

    private func removeEntry(for id: UUID) {
        guard let removed = entries.removeValue(forKey: id) else { return }
        estimatedPayloadBytes -= removed.estimatedPayloadBytes
    }

    private static func estimatedBytes(source: Source, foldedFields: [String]) -> Int {
        // Include a conservative fixed allowance for dictionary/array/String headers;
        // the variable payload is counted exactly as UTF-8. This is an in-memory budget,
        // never a diagnostic, so no snippet text or stable identifier leaves the cache.
        let fixedOverhead = 256 + ((source.tags.count + foldedFields.count) * 32)
        let sourceStrings = [source.name, source.keyword, source.content] + source.tags
        return (sourceStrings + foldedFields).reduce(fixedOverhead) { partial, string in
            let (sum, overflow) = partial.addingReportingOverflow(string.utf8.count)
            return overflow ? Int.max : sum
        }
    }
}
