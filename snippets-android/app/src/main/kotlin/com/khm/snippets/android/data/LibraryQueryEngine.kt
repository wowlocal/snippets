package com.khm.snippets.android.data

/**
 * What the library is asked to show.
 *
 * @param text The search text as typed; blank means no search.
 * @param tagKeys Folded keys of the active tag filters, in the order they were selected. A
 *   snippet must carry every one (AND).
 */
data class LibraryQuery(val text: String = "", val tagKeys: List<String> = emptyList()) {
    val hasText: Boolean get() = text.isNotBlank()
    val isFiltering: Boolean get() = hasText || tagKeys.isNotEmpty()
}

/**
 * One listed entry and where the search text matched it. Ranges index the raw field texts
 * (`snippet.name`, [LibraryEntry.keyword], the tag as spelled on the entry, `snippet.content`).
 *
 * @param tags Matches inside tags, by folded tag key.
 * @param content The contiguous match in the content, or null. Always null for a secure entry.
 */
data class QueryRow(
    val entry: LibraryEntry,
    val name: List<TextRange> = emptyList(),
    val keyword: List<TextRange> = emptyList(),
    val tags: Map<String, List<TextRange>> = emptyMap(),
    val content: TextRange? = null,
)

/**
 * @param query The query this answers, with [LibraryQuery.tagKeys] reduced to keys that still
 *   exist in the library.
 * @param revision [LibrarySnapshot.revision] of the snapshot searched.
 * @param rows Matches in display order; there is no relevance ranking.
 * @param totalCount Entries in the library.
 */
data class LibraryQueryResult(
    val query: LibraryQuery,
    val revision: Long,
    val rows: List<QueryRow>,
    val tags: List<TagCount>,
    val totalCount: Int,
)

/**
 * Search text and AND tag filters to ordered rows with highlight ranges.
 *
 * Contract: names, keywords, tags and ordinary content are searched, case- and
 * diacritic-insensitively; a secure body is never searched, also while it is revealed. The call
 * is main-safe and cancellable; a caller drops the result of a query it has replaced.
 */
interface LibraryQueryEngine {
    suspend fun search(snapshot: LibrarySnapshot, query: LibraryQuery): LibraryQueryResult
}
