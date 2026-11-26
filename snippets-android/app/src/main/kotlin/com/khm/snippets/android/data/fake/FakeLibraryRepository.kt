package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.Deletion
import com.khm.snippets.android.data.LibraryAvailability
import com.khm.snippets.android.data.LibraryError
import com.khm.snippets.android.data.LibraryRepository
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.android.data.NewSnippet
import com.khm.snippets.android.data.Outcome
import com.khm.snippets.android.data.SnippetEdit
import com.khm.snippets.android.data.UndoToken
import com.khm.snippets.core.interchange.SnippetDeepLink
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

/**
 * [LibraryRepository] over [FakeLibraryStore]: the store rules of the porting brief (blank
 * drafts, undo tokens, the duplicate rule) without persistence. Deterministic; a test steers it
 * through [FakeControls].
 */
class FakeLibraryRepository(
    private val store: FakeLibraryStore,
    private val controls: FakeControls = FakeControls(),
) : LibraryRepository {
    private class DeletedSnippet(val token: UndoToken, val snippet: Snippet, val index: Int)

    private val undoLock = Any()
    private val deleted = ArrayDeque<DeletedSnippet>()
    private var undoSerial = 0L
    private var blankDraftId: UUID? = null

    override val snapshot: StateFlow<LibrarySnapshot> get() = store.snapshot

    override suspend fun create(draft: NewSnippet): Outcome<UUID, LibraryError> = write {
        val tags = SnippetTagging.normalizedTags(draft.tags)
        val isBlank = draft.name.isBlank() && draft.content.isBlank() && tags.isEmpty()
        store.mutate {
            val remembered = blankDraftId?.let { id -> ordinary.firstOrNull { it.id == id } }
            if (isBlank && remembered != null && remembered.isBlankDraft()) {
                return@mutate Outcome.Success(remembered.id)
            }
            val now = store.now()
            val snippet = Snippet(name = draft.name, keyword = "", content = draft.content, tags = tags, createdAt = now, updatedAt = now)
            ordinary.add(0, snippet)
            blankDraftId = if (isBlank) snippet.id else blankDraftId
            Outcome.Success(snippet.id)
        }
    }

    override suspend fun update(id: UUID, edit: SnippetEdit): Outcome<Unit, LibraryError> = write {
        val found = store.mutate {
            val index = ordinaryIndex(id)
            when {
                index >= 0 -> {
                    ordinary[index] = ordinary[index].edited(edit, withContent = true)
                    true
                }
                id in secure -> {
                    val record = secure.getValue(id)
                    secure[id] = record.copy(shell = record.shell.edited(edit, withContent = false))
                    true
                }
                else -> false
            }
        }
        when {
            !found -> Outcome.Failure(LibraryError.NotFound)
            else -> controls.saveError?.let { Outcome.Failure(it) } ?: Outcome.Success(Unit)
        }
    }

    override suspend fun flush(): Outcome<Unit, LibraryError> {
        controls.pause()
        return controls.saveError?.let { Outcome.Failure(it) } ?: Outcome.Success(Unit)
    }

    override suspend fun discardBlankDraft(id: UUID): Boolean {
        controls.pause()
        if (blankDraftId != id) return false
        return store.mutate {
            val index = ordinaryIndex(id)
            if (index < 0 || !ordinary[index].isBlankDraft()) return@mutate false
            ordinary.removeAt(index)
            blankDraftId = null
            true
        }
    }

    override suspend fun delete(id: UUID): Outcome<Deletion, LibraryError> = write {
        store.mutate {
            val index = ordinaryIndex(id)
            if (index >= 0) {
                val snippet = ordinary.removeAt(index)
                val token = remember(snippet, index)
                return@mutate Outcome.Success(Deletion(id, snippet.displayName, wasSecure = false, undo = token))
            }
            val record = secure.remove(id) ?: return@mutate Outcome.Failure(LibraryError.NotFound)
            Outcome.Success(Deletion(id, record.shell.displayName, wasSecure = true, undo = null))
        }
    }

    override suspend fun restore(token: UndoToken): Outcome<Unit, LibraryError> = write {
        val entry = synchronized(undoLock) {
            deleted.firstOrNull { it.token == token }?.also { deleted.remove(it) }
        } ?: return@write Outcome.Failure(LibraryError.UndoUnavailable)
        store.mutate {
            if (ordinaryIndex(entry.snippet.id) < 0 && entry.snippet.id !in secure) {
                ordinary.add(minOf(entry.index, ordinary.size), entry.snippet)
            }
        }
        Outcome.Success(Unit)
    }

    override suspend fun duplicate(id: UUID): Outcome<UUID, LibraryError> = write {
        store.mutate {
            val index = ordinaryIndex(id)
            if (index < 0) {
                return@mutate Outcome.Failure(if (id in secure) LibraryError.NotAvailableForSecure else LibraryError.NotFound)
            }
            val source = ordinary[index]
            val trimmedName = FoundationText.trimWhitespaceAndNewlines(source.name)
            val now = store.now()
            val copy = Snippet(
                name = if (trimmedName.isEmpty()) "" else "$trimmedName Copy",
                keyword = source.keyword,
                content = source.content,
                tags = source.tags,
                // Two enabled entries must never share a keyword.
                isEnabled = source.isEnabled && source.normalizedKeyword.isEmpty(),
                isPinned = source.isPinned,
                createdAt = now,
                updatedAt = now,
            )
            ordinary.add(index + 1, copy)
            Outcome.Success(copy.id)
        }
    }

    override suspend fun setPinned(id: UUID, pinned: Boolean): Outcome<Unit, LibraryError> =
        update(id, SnippetEdit(isPinned = pinned))

    override suspend fun setEnabled(id: UUID, enabled: Boolean): Outcome<Unit, LibraryError> =
        update(id, SnippetEdit(isEnabled = enabled))

    override suspend fun toggleTag(id: UUID, tag: String): Outcome<Unit, LibraryError> {
        val entry = store.snapshot.value.entry(id) ?: return Outcome.Failure(LibraryError.NotFound)
        val key = SnippetTagging.filterKey(tag)
        val current = entry.snippet.tags
        val without = current.filterNot { SnippetTagging.filterKey(it) == key }
        return update(id, SnippetEdit(tags = if (without.size == current.size) current + tag else without))
    }

    override suspend fun shareLink(id: UUID): Outcome<String, LibraryError> {
        controls.pause()
        val entry = store.snapshot.value.entry(id) ?: return Outcome.Failure(LibraryError.NotFound)
        if (entry.isSecure) return Outcome.Failure(LibraryError.NotAvailableForSecure)
        return Outcome.Success(SnippetDeepLink.url(entry.snippet, isSecure = false))
    }

    override suspend fun importSnippets(snippets: List<Snippet>): Outcome<Int, LibraryError> = write {
        if (snippets.isEmpty()) return@write Outcome.Failure(LibraryError.EmptyImport)
        store.mutate {
            val secureKeywords = secure.values.map { foldedKeyword(it.shell) }.filter { it.isNotEmpty() }.toSet()
            val conflicts = snippets.count { it.id in secure || foldedKeyword(it) in secureKeywords }
            if (conflicts > 0) return@mutate Outcome.Failure(LibraryError.ImportConflicts(conflicts))
            for (incoming in snippets) {
                val normalized = incoming.copy(
                    keyword = incoming.normalizedKeyword,
                    tags = SnippetTagging.normalizedTags(incoming.tags),
                    updatedAt = maxOf(incoming.updatedAt, incoming.createdAt),
                )
                val sameId = ordinaryIndex(normalized.id)
                val keyword = foldedKeyword(normalized)
                val sameKeyword = if (keyword.isEmpty()) -1 else ordinary.indexOfFirst { foldedKeyword(it) == keyword }
                when {
                    sameId >= 0 -> ordinary[sameId] = normalized
                    sameKeyword >= 0 -> {
                        val existing = ordinary[sameKeyword]
                        ordinary[sameKeyword] = normalized.copy(id = existing.id, createdAt = existing.createdAt)
                    }
                    else -> ordinary.add(0, normalized)
                }
            }
            Outcome.Success(snippets.size)
        }
    }

    override suspend fun exportableSnippets(): Outcome<List<Snippet>, LibraryError> {
        controls.pause()
        return Outcome.Success(store.read { ordinary.toList() })
    }

    private fun remember(snippet: Snippet, index: Int): UndoToken = synchronized(undoLock) {
        deleted.removeAll { it.snippet.id == snippet.id }
        val token = UndoToken(snippet.id, ++undoSerial)
        deleted.addLast(DeletedSnippet(token, snippet, index))
        while (deleted.size > MAX_UNDO_TOKENS) deleted.removeFirst()
        token
    }

    private suspend fun <T> write(block: suspend () -> Outcome<T, LibraryError>): Outcome<T, LibraryError> {
        controls.pause()
        if (store.snapshot.value.availability != LibraryAvailability.Ready) {
            return Outcome.Failure(LibraryError.RecoveryRequired)
        }
        controls.writeError?.let { return Outcome.Failure(it) }
        return block()
    }

    private fun Snippet.edited(edit: SnippetEdit, withContent: Boolean): Snippet {
        val changed = copy(
            name = edit.name ?: name,
            keyword = edit.keyword?.let(Snippet::sanitizedKeyword) ?: keyword,
            content = if (withContent) edit.content ?: content else content,
            tags = edit.tags?.let(SnippetTagging::normalizedTags) ?: tags,
            isEnabled = edit.isEnabled ?: isEnabled,
            isPinned = edit.isPinned ?: isPinned,
        )
        return if (changed == this) this else changed.copy(updatedAt = store.now())
    }

    private fun Snippet.isBlankDraft(): Boolean =
        name.isBlank() && normalizedKeyword.isEmpty() && content.isBlank() && tags.isEmpty()

    private fun foldedKeyword(snippet: Snippet): String = SnippetTagging.filterKey(snippet.normalizedKeyword)

    private companion object {
        const val MAX_UNDO_TOKENS = 50
    }
}
