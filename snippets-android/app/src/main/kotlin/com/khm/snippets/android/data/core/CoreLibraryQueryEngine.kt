package com.khm.snippets.android.data.core

import com.khm.snippets.android.data.LibraryEntry
import com.khm.snippets.android.data.LibraryQuery
import com.khm.snippets.android.data.LibraryQueryEngine
import com.khm.snippets.android.data.LibraryQueryResult
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.android.data.QueryRow
import com.khm.snippets.android.data.TextRange
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.search.FuzzyMatch
import com.khm.snippets.core.search.SnippetLibraryQuery
import com.khm.snippets.core.search.SnippetSearchSnapshot
import com.khm.snippets.core.text.FoundationText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/**
 * [LibraryQueryEngine] on `core.search`: [SnippetLibraryQuery] decides which entries match
 * (fuzzy subsequence on name, keyword and tags, literal substring on ordinary content, case-
 * and diacritic-insensitive), [FuzzyMatch] and [ContentMatch] say where, for highlighting.
 *
 * A secure entry is a shell with empty content in [LibrarySnapshot], so its body can never be
 * searched or highlighted. One instance keeps one search index: share it per screen.
 */
class CoreLibraryQueryEngine(private val dispatcher: CoroutineDispatcher) : LibraryQueryEngine {
    // The tag order is irrelevant here: the snapshot already carries its ordered tags.
    private val query = SnippetLibraryQuery(tagOrder = FoundationText.order)

    override suspend fun search(snapshot: LibrarySnapshot, query: LibraryQuery): LibraryQueryResult = withContext(dispatcher) {
        val existingKeys = snapshot.tags.mapTo(HashSet()) { it.key }
        val activeKeys = query.tagKeys.filter { it in existingKeys }.distinct()
        val snippets = snapshot.entries.map { it.snippet }
        val matches = this@CoreLibraryQueryEngine.query.results(snippets, query.text, activeKeys.toSet()).all
        val needle = FoundationText.trimWhitespaceAndNewlines(query.text)
        val highlighter = if (needle.isEmpty()) null else Highlighter(needle)
        val rows = matches.mapNotNull { snippet ->
            val entry = snapshot.entry(snippet.id) ?: return@mapNotNull null
            highlighter?.row(entry) ?: QueryRow(entry)
        }
        LibraryQueryResult(
            query = query.copy(tagKeys = activeKeys),
            revision = snapshot.revision,
            rows = rows,
            tags = snapshot.tags,
            totalCount = snapshot.counts.total,
        )
    }

    /** The ranges of one query. Not thread-safe: one per search. */
    private class Highlighter(needle: String) {
        private val prepared = FuzzyMatch.PreparedQuery(needle)
        private val workspace = FuzzyMatch.Workspace()
        private val content = ContentMatch(SnippetSearchSnapshot.normalizedQuery(needle))

        fun row(entry: LibraryEntry): QueryRow {
            val snippet = entry.snippet
            val name = if (FoundationText.trimWhitespaceAndNewlines(snippet.name).isEmpty()) emptyList() else fuzzy(snippet.name)
            val tags = HashMap<String, List<TextRange>>()
            for (tag in snippet.tags) {
                val ranges = fuzzy(tag)
                if (ranges.isNotEmpty()) tags[SnippetTagging.filterKey(tag)] = ranges
            }
            return QueryRow(
                entry = entry,
                name = name,
                keyword = fuzzy(entry.keyword),
                tags = tags,
                content = if (entry.isSecure) null else content.find(snippet.content),
            )
        }

        private fun fuzzy(text: String): List<TextRange> {
            if (text.isEmpty()) return emptyList()
            val result = FuzzyMatch.score(prepared, FuzzyMatch.PreparedTarget(text), includingRanges = true, workspace = workspace)
            if (!result.matched) return emptyList()
            return result.highlightRanges.map { TextRange(it.start, it.end) }
        }
    }
}
