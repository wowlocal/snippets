package com.khm.snippets.core.search

import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText

/**
 * What a library screen shows for a search text and a set of tag filters
 * (`snippets-ios/SnippetLibraryQuery.swift` and the reload steps both iOS list
 * controllers share).
 *
 * The Swift helper keeps one process-wide search index. Here the index and the tag
 * projection belong to the instance: keep one per screen or view model.
 *
 * @param tagOrder see [SnippetLibraryProjection].
 */
class SnippetLibraryQuery(
    tagOrder: Comparator<String>,
    private val index: SnippetSearchIndex = SnippetSearchIndex(),
) {

    private val projection = SnippetLibraryProjection(tagOrder)

    /** The matches, split as the phone shows them: the "Pinned" section, then the rest. Each keeps display order. */
    data class Results(val pinned: List<Snippet>, val snippets: List<Snippet>) {
        val all: List<Snippet> get() = pinned + snippets
        val isEmpty: Boolean get() = pinned.isEmpty() && snippets.isEmpty()
    }

    /**
     * @property sorted every snippet, ordinary and secure, in display order.
     * @property tagUsage every tag of the library with its count, for the filter controls.
     * @property activeTagKeys the requested filters that still exist in the library. The
     * caller keeps this set: a filter whose last tag was removed must not stay active.
     */
    class Library(
        val results: Results,
        val sorted: List<Snippet>,
        val tagUsage: List<SnippetLibraryProjection.TagUsage>,
        val tagKeys: Set<String>,
        val activeTagKeys: Set<String>,
    )

    /**
     * `SnippetLibraryQuery.results(in:searchText:activeTagKeys:)`. [snippets] is already
     * in display order. An empty search text (after trimming) applies the tag filters
     * only; every active key must be a tag of the snippet.
     */
    fun results(snippets: List<Snippet>, searchText: String, activeTagKeys: Set<String>): Results {
        val matches = if (SnippetSearchSnapshot.normalizedQuery(searchText).isEmpty()) {
            SnippetSearchSnapshot.resultsForEmptySearch(snippets, activeTagKeys)
        } else {
            index.results(snippets, searchText, activeTagKeys)
        }
        return Results(matches.filter { it.isPinned }, matches.filter { !it.isPinned })
    }

    /**
     * The whole reload: display order, tag list, filters pruned to the tags that exist,
     * then [results].
     *
     * [secureShells] are the secure snippets as the vault lists them, without their
     * bodies. A shell that arrives with content anyway is searched and returned without
     * it: a secure body is never searched.
     */
    fun library(
        ordinary: List<Snippet>,
        secureShells: List<Snippet>,
        searchText: String,
        activeTagKeys: Set<String>,
    ): Library {
        val shells = if (secureShells.all { it.content.isEmpty() }) secureShells else secureShells.map { it.copy(content = "") }
        val snapshot = projection.snapshot(ordinary, shells)
        val active = activeTagKeys.mapTo(HashSet(), FoundationText::nfc).apply { retainAll(snapshot.tagKeys) }
        return Library(results(snapshot.sorted, searchText, active), snapshot.sorted, snapshot.tagUsage, snapshot.tagKeys, active)
    }

    companion object {
        /** The key of a tag as [Library.tagKeys] and the `activeTagKeys` parameters use it. */
        fun tagKey(tag: String): String = SnippetTagging.filterKey(tag)
    }
}
