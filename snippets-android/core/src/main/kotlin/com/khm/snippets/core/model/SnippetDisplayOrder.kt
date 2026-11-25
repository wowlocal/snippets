package com.khm.snippets.core.model

import java.util.UUID

/**
 * The one order of every user-facing library listing (`SnippetDisplayOrder`): pinned
 * first, then newest [Snippet.createdAt], then the id.
 *
 * File order in `snippets.json` is not synced and is never presentation state. Every
 * field used here is, so the order is the same on every device.
 */
object SnippetDisplayOrder {

    /** `SnippetDisplayOrder.ranks(_:before:)`. */
    fun ranks(first: Snippet, before: Snippet): Boolean = comparator.compare(first, before) < 0

    /** `SnippetDisplayOrder.sorted`. */
    fun sorted(snippets: List<Snippet>): List<Snippet> = snippets.sortedWith(comparator)

    /**
     * Creation time, not update time: editing or pinning must not make a row jump within
     * its section. Times compare as IEEE doubles, so `0.0` and `-0.0` tie and the id
     * decides. A not-a-number time has no place in Swift's order (its comparator is
     * inconsistent there); here it sorts after every number so the order stays total.
     */
    val comparator: Comparator<Snippet> = Comparator { first, second ->
        if (first.isPinned != second.isPinned) return@Comparator if (first.isPinned) -1 else 1
        val a = first.createdAt
        val b = second.createdAt
        when {
            a > b -> -1
            a < b -> 1
            a.isNaN() != b.isNaN() -> if (a.isNaN()) 1 else -1
            else -> compareUuidStrings(first.id, second.id)
        }
    }

    /**
     * Swift breaks the tie with `id.uuidString < other.uuidString`. For two ids that is
     * the order of their 16 bytes read as unsigned, which this computes without building
     * the strings. `UUID.compareTo` is no substitute: it compares two signed longs.
     */
    fun compareUuidStrings(first: UUID, second: UUID): Int {
        val high = java.lang.Long.compareUnsigned(first.mostSignificantBits, second.mostSignificantBits)
        return if (high != 0) high else java.lang.Long.compareUnsigned(first.leastSignificantBits, second.leastSignificantBits)
    }
}
