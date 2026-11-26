package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.LibraryAvailability
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.search.SnippetLibraryProjection
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale
import java.util.UUID

/** A secure record of the fake vault: metadata as a shell, and the body in the clear. */
internal data class FakeSecureRecord(val shell: Snippet, val body: String)

/** One demo or test entry. [secureBody] non-null makes it a secure entry. */
data class SeedEntry(val snippet: Snippet, val secureBody: String? = null)

/**
 * The in-memory library behind [FakeLibraryRepository] and [FakeSecureVault]: ordinary snippets
 * in storage order, secure records, and the snapshot both publish. Nothing is written anywhere.
 *
 * @param now Seconds since 2001; tests pass a controlled clock.
 * @param tagOrder Orders tag spellings; the locale's collation ignoring case.
 */
class FakeLibraryStore(
    val now: () -> Double = AppleTime::now,
    private val tagOrder: Comparator<String> = SnippetLibraryProjection.collatingTagOrder(Locale.getDefault()),
) {
    private val lock = Any()
    private val ordinary = ArrayList<Snippet>()
    private val secure = LinkedHashMap<UUID, FakeSecureRecord>()
    private var availability = LibraryAvailability.Ready
    private var revision = 0L
    private val published = MutableStateFlow(LibrarySnapshot.build(emptyList(), emptyList(), revision = 0, tagOrder = tagOrder))

    val snapshot: StateFlow<LibrarySnapshot> = published.asStateFlow()

    /** Replaces the whole library, for a demo seed or a test fixture. */
    fun seed(entries: List<SeedEntry>, availability: LibraryAvailability = LibraryAvailability.Ready) {
        mutate {
            ordinary.clear()
            secure.clear()
            for (entry in entries) {
                if (entry.secureBody == null) {
                    ordinary += entry.snippet
                } else {
                    secure[entry.snippet.id] = FakeSecureRecord(entry.snippet.copy(content = ""), entry.secureBody)
                }
            }
            this.availability = availability
        }
    }

    fun setAvailability(value: LibraryAvailability) = mutate { availability = value }

    val hasSecureRecords: Boolean get() = synchronized(lock) { secure.isNotEmpty() }

    internal fun <T> read(block: StoreView.() -> T): T = synchronized(lock) { view.block() }

    /** Runs [block] on the storage and publishes one new snapshot. */
    internal fun <T> mutate(block: StoreView.() -> T): T = synchronized(lock) {
        val result = view.block()
        revision += 1
        published.value = LibrarySnapshot.build(
            ordinary = ordinary.toList(),
            secureShells = secure.values.map { it.shell },
            revision = revision,
            availability = availability,
            tagOrder = tagOrder,
        )
        result
    }

    private val view = StoreView()

    /** Direct access to the storage; only valid inside [read] and [mutate]. */
    internal inner class StoreView {
        val ordinary: MutableList<Snippet> get() = this@FakeLibraryStore.ordinary
        val secure: MutableMap<UUID, FakeSecureRecord> get() = this@FakeLibraryStore.secure
        var availability: LibraryAvailability
            get() = this@FakeLibraryStore.availability
            set(value) {
                this@FakeLibraryStore.availability = value
            }

        fun ordinaryIndex(id: UUID): Int = ordinary.indexOfFirst { it.id == id }
    }
}
