package com.khm.snippets.android.data

import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.search.SnippetLibraryProjection
import java.util.Locale
import java.util.UUID

/** Whether the library can be shown and changed. */
enum class LibraryAvailability {
    /** The store has not reported yet. Nothing may be created or changed. */
    Loading,

    Ready,

    /** `snippets.json` could not be read and is preserved; only import and recovery work. */
    Quarantined,
}

/**
 * One entry of the library as every list shows it.
 *
 * A secure entry is a shell: [snippet] carries its metadata (name, keyword, tags, flags, dates)
 * and an empty `content`. The body of a secure entry never travels through this type.
 */
data class LibraryEntry(val snippet: Snippet, val isSecure: Boolean) {
    val id: UUID get() = snippet.id

    /** Name, else the first content line (ordinary entries only), else `Untitled Snippet`. */
    val displayName: String get() = snippet.displayName

    /** The sanitised keyword; empty when the entry has none. */
    val keyword: String get() = snippet.normalizedKeyword
}

/**
 * A tag of the library.
 *
 * @param name The first spelling seen.
 * @param key The folded identity (`SnippetTagging.filterKey`).
 * @param count Entries carrying the tag over the whole library, secure entries included.
 */
data class TagCount(val name: String, val key: String, val count: Int)

/** Sizes of the library, for footers and the Review screen. */
data class LibraryCounts(val total: Int, val secure: Int)

/**
 * An immutable picture of the whole library.
 *
 * @param entries Ordinary and secure entries interleaved in display order: pinned first, then
 *   newest created first, then id (`SnippetDisplayOrder`).
 * @param revision Grows with every change; lets a consumer drop results computed for an older
 *   snapshot.
 * @param tags Every tag with its count over the whole library, in the locale's collation
 *   ignoring case (`SnippetLibraryProjection`).
 */
class LibrarySnapshot private constructor(
    val availability: LibraryAvailability,
    val entries: List<LibraryEntry>,
    val revision: Long,
    val tags: List<TagCount>,
    val counts: LibraryCounts,
) {
    private val byId: Map<UUID, LibraryEntry> = entries.associateBy { it.id }

    fun entry(id: UUID): LibraryEntry? = byId[id]

    operator fun contains(id: UUID): Boolean = id in byId

    override fun equals(other: Any?): Boolean =
        other is LibrarySnapshot && other.revision == revision && other.availability == availability &&
            other.entries == entries

    override fun hashCode(): Int = revision.hashCode()

    override fun toString(): String = "LibrarySnapshot(revision=$revision, entries=${entries.size})"

    companion object {
        val Loading: LibrarySnapshot = build(emptyList(), emptyList(), revision = 0, availability = LibraryAvailability.Loading)

        /**
         * The snapshot of a library: [ordinary] snippets and the [secureShells] of secure ones,
         * each in storage order (a tag shows in the first spelling met walking the ordinary
         * entries, then the secure ones). A shell that arrives with content is emptied: a
         * secure body never enters a snapshot.
         *
         * @param tagOrder Orders the tag spellings; the locale's collation ignoring case.
         */
        fun build(
            ordinary: List<Snippet>,
            secureShells: List<Snippet>,
            revision: Long,
            availability: LibraryAvailability = LibraryAvailability.Ready,
            tagOrder: Comparator<String> = SnippetLibraryProjection.collatingTagOrder(Locale.getDefault()),
        ): LibrarySnapshot {
            val shells = secureShells.map { if (it.content.isEmpty()) it else it.copy(content = "") }
            val projection = SnippetLibraryProjection.build(ordinary, shells, tagOrder)
            val secureIds = shells.mapTo(HashSet()) { it.id }
            val entries = projection.sorted.map { LibraryEntry(it, isSecure = it.id in secureIds) }
            return LibrarySnapshot(
                availability = availability,
                entries = entries,
                revision = revision,
                tags = projection.tagUsage.map { TagCount(it.tag, SnippetTagging.filterKey(it.tag), it.count) },
                counts = LibraryCounts(total = entries.size, secure = secureIds.size),
            )
        }
    }
}

/** What a new entry starts with. All blank makes a blank draft. */
data class NewSnippet(
    val name: String = "",
    val content: String = "",
    val tags: List<String> = emptyList(),
)

/**
 * A field-level edit: null leaves a field as it is. The repository sanitises the keyword and
 * normalises the tags. [content] applies to ordinary entries only; a secure body is written
 * through `SecureVault.updateBody`.
 */
data class SnippetEdit(
    val name: String? = null,
    val keyword: String? = null,
    val content: String? = null,
    val tags: List<String>? = null,
    val isEnabled: Boolean? = null,
    val isPinned: Boolean? = null,
) {
    val isEmpty: Boolean
        get() = name == null && keyword == null && content == null && tags == null && isEnabled == null && isPinned == null

    /** This edit with the non-null fields of [newer] laid over it. */
    fun mergedWith(newer: SnippetEdit): SnippetEdit = SnippetEdit(
        name = newer.name ?: name,
        keyword = newer.keyword ?: keyword,
        content = newer.content ?: content,
        tags = newer.tags ?: tags,
        isEnabled = newer.isEnabled ?: isEnabled,
        isPinned = newer.isPinned ?: isPinned,
    )
}

/** Restores one deleted ordinary entry, once. Opaque: only the repository that issued it reads it. */
class UndoToken(val id: UUID, val serial: Long) {
    override fun equals(other: Any?): Boolean = other is UndoToken && other.id == id && other.serial == serial
    override fun hashCode(): Int = 31 * id.hashCode() + serial.hashCode()
    override fun toString(): String = "UndoToken($serial)"
}

/**
 * A finished deletion.
 *
 * @param name Display name of the deleted entry, for the snackbar.
 * @param undo Present for an ordinary entry; a secure deletion cannot be undone.
 */
data class Deletion(val id: UUID, val name: String, val wasSecure: Boolean, val undo: UndoToken?)

/** Why a library operation did not happen. Nothing was changed unless a case says otherwise. */
sealed interface LibraryError {
    /** The entry no longer exists. */
    data object NotFound : LibraryError

    /** The library is quarantined or still loading; it must be recovered first. */
    data object RecoveryRequired : LibraryError

    /** Duplicate, share and export do not exist for secure entries. */
    data object NotAvailableForSecure : LibraryError

    /** The change is in memory but could not be written; the next successful write includes it. */
    data object WriteFailed : LibraryError

    /** The undo token was used, replaced by a newer deletion of the same entry, or dropped. */
    data object UndoUnavailable : LibraryError

    data object EmptyImport : LibraryError

    /** The import was refused as a whole. [count] conflicts were found (ids or keywords). */
    data class ImportConflicts(val count: Int) : LibraryError
}
