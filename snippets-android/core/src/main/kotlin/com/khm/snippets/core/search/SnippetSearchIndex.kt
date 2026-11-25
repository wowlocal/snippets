package com.khm.snippets.core.search

import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetDisplayOrder
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import java.text.Collator
import java.util.Locale
import java.util.UUID

/**
 * The display order and the tag list of a library (`SnippetLibraryProjection` in
 * `SnippetSearchIndex.swift`; unrelated to the sync layer's projection).
 *
 * A tag is identified by its [SnippetTagging.filterKey]. It is shown in the first spelling
 * met walking the ordinary snippets and then the secure ones, each in array order, with
 * the number of snippets that carry it.
 *
 * The last result is kept, so asking again for an unchanged library costs one comparison
 * of the two lists. Safe to call from several threads.
 *
 * @param tagOrder orders the shown spellings. Swift compares them with
 * `compare(_:options: [.caseInsensitive], locale:)`, which with a locale is that locale's
 * collation ignoring case; [collatingTagOrder] is the equivalent here.
 */
class SnippetLibraryProjection(private val tagOrder: Comparator<String>) {

    data class TagUsage(val tag: String, val count: Int)

    class Snapshot internal constructor(
        /** Ordinary and secure snippets together in [SnippetDisplayOrder]. */
        val sorted: List<Snippet>,
        val tagUsage: List<TagUsage>,
        /** The filter keys of [tagUsage]. */
        val tagKeys: Set<String>,
    ) {
        /** The shown spellings, in order. */
        val tags: List<String> get() = tagUsage.map { it.tag }
    }

    private val lock = Any()
    private var ordinary: List<Snippet> = emptyList()
    private var secure: List<Snippet> = emptyList()
    private var cached: Snapshot? = null

    /** How many snapshots were computed rather than answered from the cache. */
    var buildCount: Int = 0
        private set

    fun snapshot(ordinary: List<Snippet>, secure: List<Snippet>): Snapshot = synchronized(lock) {
        cached?.let { if (this.ordinary == ordinary && this.secure == secure) return it }
        val result = build(ordinary, secure, tagOrder)
        this.ordinary = ordinary.toList()
        this.secure = secure.toList()
        cached = result
        buildCount += 1
        result
    }

    companion object {

        /** The projection of one library, without a cache. */
        fun build(ordinary: List<Snippet>, secure: List<Snippet>, tagOrder: Comparator<String>): Snapshot {
            val combined = ordinary + secure
            val spellings = LinkedHashMap<String, String>()
            val counts = HashMap<String, Int>()
            for (snippet in combined) {
                for (tag in snippet.tags) {
                    val key = SnippetTagging.filterKey(tag)
                    spellings.putIfAbsent(key, tag)
                    counts[key] = (counts[key] ?: 0) + 1
                }
            }
            // Swift sorts a dictionary, so spellings that compare equal come out in any
            // order there. Here the key settles them.
            val usage = spellings.entries
                .sortedWith { first, second ->
                    val bySpelling = tagOrder.compare(first.value, second.value)
                    if (bySpelling != 0) bySpelling else FoundationText.compareScalars(first.key, second.key)
                }
                .map { TagUsage(it.value, counts[it.key] ?: 0) }
            return Snapshot(SnippetDisplayOrder.sorted(combined), usage, spellings.keys.toSet())
        }

        /**
         * [locale]'s collation with case ignored and accents respected. On Android
         * `java.text.Collator` is ICU's, as Foundation's is; on a desktop JVM the order of
         * punctuation, emoji and non-Latin scripts follows the JDK's own rules.
         */
        fun collatingTagOrder(locale: Locale): Comparator<String> {
            val collator = Collator.getInstance(locale)
            collator.strength = Collator.SECONDARY
            collator.decomposition = Collator.CANONICAL_DECOMPOSITION
            // A Collator is not thread-safe; a clone per comparison is the simple way to share one.
            return Comparator { first, second -> (collator.clone() as Collator).compare(first, second) }
        }
    }
}

/**
 * An immutable, ordered projection of a library's searchable text
 * (`SnippetSearchSnapshot`).
 *
 * Building one folds each snippet's text once; a query then only walks folded strings.
 * A secure snippet enters as its shell, with empty content: its name, keyword and tags are
 * searchable, its body never is, and nothing here asks a vault for plaintext.
 *
 * Results keep the order of the input. There is no ranking.
 */
class SnippetSearchSnapshot private constructor(
    snippets: List<Snippet>,
    private val maximumNormalizedUnits: Int,
    previous: SnippetSearchSnapshot?,
) {

    /** [searchMatches] is the text search alone; [snippets] is that after the tag filter. */
    class Evaluation(val searchMatches: List<Snippet>, val snippets: List<Snippet>)

    private class Source(snippet: Snippet) {
        val name = snippet.name
        val keyword = snippet.keyword
        val content = snippet.content
        val tags = snippet.tags

        // Exact comparison: a canonically equivalent respelling is refolded, which is only work.
        fun sameText(other: Source): Boolean =
            name == other.name && keyword == other.keyword && content == other.content && tags == other.tags
    }

    private class NormalizedEntry(
        val source: Source,
        /** Display name, keyword and content, then the tags. */
        val searchableFields: List<PreparedSubstringSearch.Field>,
        /** The name when there is one, the keyword and the tags: what a subsequence may match. */
        val fuzzyMetadata: List<String>,
        val tagKeys: Set<String>,
        val estimatedUnits: Int,
    )

    private class Entry(val snippet: Snippet, val normalized: NormalizedEntry?)

    private val sourceSnippets: List<Snippet> = snippets.toList()
    private val entries: List<Entry>
    private val normalizedEntriesById: Map<UUID, NormalizedEntry>

    /** Entries folded while building this snapshot, as opposed to taken from the previous one. */
    val normalizedEntryBuildCount: Int

    /** The estimated UTF-16 units held for folded text. Never above the budget. */
    val estimatedNormalizedUnits: Int

    /** Entries that did not fit the budget and are folded again for every query. */
    val uncachedEntryCount: Int

    init {
        val reusable = if (previous != null && previous.maximumNormalizedUnits == maximumNormalizedUnits) {
            previous.normalizedEntriesById
        } else {
            emptyMap()
        }
        val built = ArrayList<Entry>(sourceSnippets.size)
        val byId = HashMap<UUID, NormalizedEntry>(sourceSnippets.size * 2)
        var buildCount = 0
        var units = 0
        var fallbackCount = 0
        for (snippet in sourceSnippets) {
            val source = Source(snippet)
            val cachedEntry = reusable[snippet.id]
            val candidate = if (cachedEntry != null && cachedEntry.source.sameText(source)) {
                cachedEntry
            } else {
                buildCount += 1
                normalize(snippet, source)
            }
            val normalized = if (candidate.estimatedUnits <= maximumNormalizedUnits - units) candidate else null
            built.add(Entry(snippet, normalized))
            if (normalized != null) {
                byId[snippet.id] = normalized
                units += normalized.estimatedUnits
            } else {
                fallbackCount += 1
            }
        }
        entries = built
        normalizedEntriesById = byId
        normalizedEntryBuildCount = buildCount
        estimatedNormalizedUnits = units
        uncachedEntryCount = fallbackCount
    }

    fun results(searchText: String, activeTagKeys: Set<String>): List<Snippet> =
        evaluate(searchText, activeTagKeys).snippets

    fun evaluate(searchText: String, activeTagKeys: Set<String>): Evaluation {
        val query = normalizedQuery(searchText)
        return evaluation(matchingIndices(query, FuzzyMatch.PreparedQuery(query), candidates = null), activeTagKeys)
    }

    internal val entryCount: Int get() = entries.size

    /**
     * The entries that match the query, in order. A snippet matches when the query is a
     * literal part of its display name, its keyword or a tag; or a subsequence of its
     * name, keyword or a tag; or a literal part of its content. The content is never
     * matched as a subsequence, and neither is the first content line that stands in for
     * a missing name.
     */
    internal fun matchingIndices(query: String, prepared: FuzzyMatch.PreparedQuery, candidates: IntArray?): IntArray {
        val literal = PreparedSubstringSearch.Query(query)
        val matching = IntArray(candidates?.size ?: entries.size)
        var count = 0
        val total = candidates?.size ?: entries.size
        for (position in 0 until total) {
            val index = candidates?.get(position) ?: position
            if (query.isEmpty() || matches(entries[index], literal, prepared)) matching[count++] = index
        }
        return matching.copyOf(count)
    }

    private fun matches(entry: Entry, literal: PreparedSubstringSearch.Query, prepared: FuzzyMatch.PreparedQuery): Boolean {
        val normalized = entry.normalized ?: normalize(entry.snippet, Source(entry.snippet))
        val fields = normalized.searchableFields
        if (fields[0].contains(literal) || fields[1].contains(literal)) return true
        for (index in 3 until fields.size) if (fields[index].contains(literal)) return true
        for (metadata in normalized.fuzzyMetadata) if (FuzzyMatch.matches(prepared, metadata)) return true
        return fields[2].contains(literal)
    }

    internal fun evaluation(indices: IntArray, activeTagKeys: Set<String>): Evaluation {
        val searchMatches = indices.map { entries[it].snippet }
        if (activeTagKeys.isEmpty()) return Evaluation(searchMatches, searchMatches)
        val wanted = normalizedKeys(activeTagKeys)
        val filtered = ArrayList<Snippet>()
        for (index in indices) {
            val entry = entries[index]
            val tagKeys = entry.normalized?.tagKeys ?: tagKeysOf(entry.snippet)
            if (tagKeys.containsAll(wanted)) filtered.add(entry.snippet)
        }
        return Evaluation(searchMatches, filtered)
    }

    internal fun represents(snippets: List<Snippet>, maximumNormalizedUnits: Int): Boolean =
        maximumNormalizedUnits == this.maximumNormalizedUnits && snippets.size == entries.size && sourceSnippets == snippets

    companion object {

        /**
         * @param maximumNormalizedUnits the budget for folded text, in UTF-16 units. A
         * snippet that does not fit is searched with the same results, folded per query.
         * @param reusing a previous snapshot of the same library: entries whose name,
         * keyword, content and tags did not change are taken from it.
         */
        fun build(
            snippets: List<Snippet>,
            maximumNormalizedUnits: Int = SnippetSearchIndex.DEFAULT_MAXIMUM_NORMALIZED_UNITS,
            reusing: SnippetSearchSnapshot? = null,
        ): SnippetSearchSnapshot = SnippetSearchSnapshot(snippets, maxOf(0, maximumNormalizedUnits), reusing)

        /**
         * `normalizedQuery`: the search text trimmed of whitespace and newlines, then
         * folded. The whole query is one needle; inner spaces are part of it.
         */
        fun normalizedQuery(searchText: String): String =
            FoundationText.fold(FoundationText.trimWhitespaceAndNewlines(searchText))

        /**
         * `resultsForEmptySearch`: the tag filter alone, without building an index. Every
         * active key must be the key of one of the snippet's tags.
         */
        fun resultsForEmptySearch(snippets: List<Snippet>, activeTagKeys: Set<String>): List<Snippet> {
            if (activeTagKeys.isEmpty()) return snippets
            val wanted = normalizedKeys(activeTagKeys)
            return snippets.filter { tagKeysOf(it).containsAll(wanted) }
        }

        // Swift's Set<String> holds canonically equivalent keys as one; filter keys are
        // in Normalization Form C, so normalizing the caller's makes plain equality enough.
        private fun normalizedKeys(keys: Set<String>): Set<String> = keys.mapTo(HashSet(), FoundationText::nfc)

        private fun tagKeysOf(snippet: Snippet): Set<String> = snippet.tags.mapTo(HashSet(), SnippetTagging::filterKey)

        private fun normalize(snippet: Snippet, source: Source): NormalizedEntry {
            val folded = ArrayList<String>(3 + snippet.tags.size)
            folded.add(FoundationText.fold(snippet.displayName))
            folded.add(FoundationText.fold(snippet.normalizedKeyword))
            folded.add(FoundationText.fold(snippet.content))
            for (tag in snippet.tags) folded.add(FoundationText.fold(tag))

            // An unnamed snippet shows its first content line. That stand-in must not
            // turn into subsequence search over the body.
            val fuzzyMetadata = ArrayList<String>(2 + snippet.tags.size)
            if (FoundationText.trimWhitespaceAndNewlines(snippet.name).isNotEmpty()) fuzzyMetadata.add(folded[0])
            fuzzyMetadata.add(folded[1])
            for (index in 3 until folded.size) fuzzyMetadata.add(folded[index])

            val tagKeys = tagKeysOf(snippet)
            // The Swift estimate, in UTF-16 units instead of UTF-8 bytes: the folded
            // strings plus an allowance per string, array and set.
            var units = 256L + (folded.size + tagKeys.size) * 32L + 32L + folded.size * 64L
            for (text in folded) units += text.length
            for (key in tagKeys) units += key.length
            for (text in fuzzyMetadata) units += 32L + text.length
            return NormalizedEntry(
                source, folded.map { PreparedSubstringSearch.Field(it) }, fuzzyMetadata, tagKeys,
                units.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            )
        }
    }
}

/**
 * Keeps the latest [SnippetSearchSnapshot] and answers queries against it
 * (`SnippetSearchIndex`). Safe to call from several threads; folding and scanning happen
 * outside the lock, so a newer request never waits for an older one.
 *
 * Two things are remembered between calls, and both only save work: the snapshot, so an
 * edit refolds one snippet instead of the library, and the last scan, so a query that
 * extends the previous one over the same snapshot only looks at that scan's matches.
 */
class SnippetSearchIndex(maximumNormalizedUnits: Int = DEFAULT_MAXIMUM_NORMALIZED_UNITS) {

    data class Statistics(
        val snapshotBuildCount: Int,
        val normalizedEntryBuildCount: Int,
        val lastSnapshotEntryBuildCount: Int,
        val estimatedNormalizedUnits: Int,
        val uncachedEntryCount: Int,
        val lastCandidateCount: Int,
    )

    private class Scan(
        val snapshot: SnippetSearchSnapshot,
        val query: String,
        val prepared: FuzzyMatch.PreparedQuery,
        val matches: IntArray,
    )

    private val maximumNormalizedUnits = maxOf(0, maximumNormalizedUnits)
    private val lock = Any()
    private var latestSnapshot: SnippetSearchSnapshot? = null
    private var snapshotBuildCount = 0
    private var normalizedEntryBuildCount = 0
    private var lastSnapshotEntryBuildCount = 0
    private var nextRequestSequence = 0L
    private var committedBuildSequence = 0L
    private var latestScan: Scan? = null
    private var scanSequence = 0L
    private var lastCandidateCount = 0

    /** [snippets] is the library in the order to show; the result keeps that order. */
    fun results(snippets: List<Snippet>, searchText: String, activeTagKeys: Set<String>): List<Snippet> =
        evaluate(snippets, searchText, activeTagKeys).snippets

    fun evaluate(snippets: List<Snippet>, searchText: String, activeTagKeys: Set<String>): SnippetSearchSnapshot.Evaluation {
        val snapshot = snapshot(snippets)
        val query = SnippetSearchSnapshot.normalizedQuery(searchText)
        val prepared = FuzzyMatch.PreparedQuery(query)
        val sequence: Long
        val previous: Scan?
        synchronized(lock) {
            scanSequence += 1
            sequence = scanSequence
            previous = latestScan
        }
        // Narrow only for a query that extends the previous one over this very snapshot.
        // The remembered matches are those before the tag filter, so relaxing a filter
        // cannot hide a row.
        val candidates = if (previous != null && previous.snapshot === snapshot &&
            SwiftStrings.hasPrefix(query, previous.query) && prepared.extends(previous.prepared)
        ) {
            previous.matches
        } else {
            null
        }
        val matches = snapshot.matchingIndices(query, prepared, candidates)
        synchronized(lock) {
            if (scanSequence == sequence && latestSnapshot === snapshot) {
                latestScan = Scan(snapshot, query, prepared, matches)
                lastCandidateCount = candidates?.size ?: snapshot.entryCount
            }
        }
        return snapshot.evaluation(matches, activeTagKeys)
    }

    /** The snapshot for [snippets]: the current one when it describes them, otherwise a new one. */
    fun snapshot(snippets: List<Snippet>): SnippetSearchSnapshot {
        val requestSequence: Long
        val previous: SnippetSearchSnapshot?
        synchronized(lock) {
            nextRequestSequence += 1
            requestSequence = nextRequestSequence
            val latest = latestSnapshot
            if (latest != null && latest.represents(snippets, maximumNormalizedUnits)) {
                // A cache hit is still the newest request: an older build that is still
                // running must not replace it.
                committedBuildSequence = requestSequence
                lastSnapshotEntryBuildCount = 0
                return latest
            }
            previous = latest
        }
        val snapshot = SnippetSearchSnapshot.build(snippets, maximumNormalizedUnits, previous)
        synchronized(lock) {
            snapshotBuildCount += 1
            normalizedEntryBuildCount += snapshot.normalizedEntryBuildCount
            if (requestSequence >= committedBuildSequence) {
                latestSnapshot = snapshot
                latestScan = null
                committedBuildSequence = requestSequence
                lastSnapshotEntryBuildCount = snapshot.normalizedEntryBuildCount
            }
        }
        return snapshot
    }

    /** Counters for performance tests. They hold no user data. */
    val statistics: Statistics
        get() = synchronized(lock) {
            Statistics(
                snapshotBuildCount, normalizedEntryBuildCount, lastSnapshotEntryBuildCount,
                latestSnapshot?.estimatedNormalizedUnits ?: 0, latestSnapshot?.uncachedEntryCount ?: 0, lastCandidateCount,
            )
        }

    companion object {
        /** The Swift budget is 16 MiB of UTF-8; this is the same number of UTF-16 units. */
        const val DEFAULT_MAXIMUM_NORMALIZED_UNITS: Int = 16 * 1024 * 1024
    }
}
