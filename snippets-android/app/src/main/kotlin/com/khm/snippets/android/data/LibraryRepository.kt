package com.khm.snippets.android.data

import com.khm.snippets.core.model.Snippet
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

/**
 * The library as the UI reads and changes it: ordinary snippets and the metadata of secure ones,
 * in one list. Every function is main-safe and returns a typed [Outcome]; none throws for an
 * expected failure.
 *
 * Changes are visible in [snapshot] before the function returns. Writing to disk may lag behind
 * (autosave): [flush] waits for it.
 */
interface LibraryRepository {
    /** The current library. Starts as [LibrarySnapshot.Loading]. */
    val snapshot: StateFlow<LibrarySnapshot>

    /**
     * Creates an ordinary, enabled entry without a keyword and returns its id. A blank [draft]
     * reuses the blank draft created last when it is still blank.
     */
    suspend fun create(draft: NewSnippet = NewSnippet()): Outcome<UUID, LibraryError>

    /**
     * Applies [edit] to an ordinary entry or to the metadata of a secure one. A no-op edit
     * succeeds without touching `updatedAt`. Duplicate keywords are allowed: the editor warns.
     */
    suspend fun update(id: UUID, edit: SnippetEdit): Outcome<Unit, LibraryError>

    /** Waits until every accepted change is written. Call on blur, on leaving a screen, on stop. */
    suspend fun flush(): Outcome<Unit, LibraryError>

    /**
     * Removes the entry [id] if it is the remembered blank draft and is still blank (name,
     * keyword, content and tags). Returns true when it was removed.
     */
    suspend fun discardBlankDraft(id: UUID): Boolean

    /**
     * Deletes an entry. An ordinary deletion carries an [UndoToken]; a secure one does not.
     * Deleting a secure entry needs no authentication.
     */
    suspend fun delete(id: UUID): Outcome<Deletion, LibraryError>

    /**
     * Puts back exactly the entry a deletion removed, at its original position, without
     * reverting anything done since. Works once per token.
     */
    suspend fun restore(token: UndoToken): Outcome<Unit, LibraryError>

    /**
     * Copies an ordinary entry: name plus ` Copy` (a blank name stays blank), same keyword,
     * content, tags and pin. The copy is disabled when the source was enabled and has a keyword,
     * so two enabled entries never share one. Returns the id of the copy.
     */
    suspend fun duplicate(id: UUID): Outcome<UUID, LibraryError>

    suspend fun setPinned(id: UUID, pinned: Boolean): Outcome<Unit, LibraryError>

    suspend fun setEnabled(id: UUID, enabled: Boolean): Outcome<Unit, LibraryError>

    /** Removes the tag with the same folded key, else appends [tag]. */
    suspend fun toggleTag(id: UUID, tag: String): Outcome<Unit, LibraryError>

    /** `snippets://share?data=…` for an ordinary entry. A secure entry is refused. */
    suspend fun shareLink(id: UUID): Outcome<String, LibraryError>

    /**
     * Import hook: merges [snippets] by id, then by keyword, as one undoable step. Any conflict
     * refuses the whole import. Returns the number of incoming records.
     */
    suspend fun importSnippets(snippets: List<Snippet>): Outcome<Int, LibraryError>

    /** Export hook: the ordinary snippets, in storage order. Secure entries are never included. */
    suspend fun exportableSnippets(): Outcome<List<Snippet>, LibraryError>
}
