package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.LibraryError
import com.khm.snippets.android.data.NewSnippet
import com.khm.snippets.android.data.Outcome
import com.khm.snippets.android.data.SnippetEdit
import com.khm.snippets.android.data.errorOrNull
import com.khm.snippets.android.data.valueOrNull
import com.khm.snippets.android.testing.id
import com.khm.snippets.android.testing.seed
import com.khm.snippets.android.testing.snippet
import com.khm.snippets.core.interchange.SnippetDeepLink
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FakeLibraryRepositoryTest {
    private var clock = 100.0
    private val store = FakeLibraryStore(now = { clock })
    private val controls = FakeControls()
    private val repository = FakeLibraryRepository(store, controls)

    private fun storageOrder() = store.read { ordinary.map { it.id } }

    @Test
    fun aBlankCreateReusesTheBlankDraftWhileItIsBlank() = runTest {
        val first = repository.create().valueOrNull()!!
        assertEquals(first, repository.create().valueOrNull())
        repository.update(first, SnippetEdit(name = "Named"))
        assertNotEquals(first, repository.create().valueOrNull())
    }

    @Test
    fun aCreateWithContentIsANewOrdinaryEnabledEntry() = runTest {
        val created = repository.create(NewSnippet(content = "text", tags = listOf("a", "A"))).valueOrNull()!!
        val entry = repository.snapshot.value.entry(created)!!
        assertEquals("text", entry.snippet.content)
        assertEquals(listOf("a"), entry.snippet.tags)
        assertTrue(entry.snippet.isEnabled)
        assertFalse(entry.isSecure)
    }

    @Test
    fun onlyTheRememberedBlankDraftIsDiscarded() = runTest {
        store.seed(listOf(seed(snippet(1, name = ""))))
        assertFalse(repository.discardBlankDraft(id(1)))
        val draft = repository.create().valueOrNull()!!
        repository.update(draft, SnippetEdit(content = "x"))
        assertFalse(repository.discardBlankDraft(draft))
        repository.update(draft, SnippetEdit(content = ""))
        assertTrue(repository.discardBlankDraft(draft))
        assertNull(repository.snapshot.value.entry(draft))
    }

    @Test
    fun aNoOpUpdateKeepsUpdatedAt() = runTest {
        store.seed(listOf(seed(snippet(1, name = "A"))))
        clock = 500.0
        repository.update(id(1), SnippetEdit(name = "A"))
        assertEquals(1.0, repository.snapshot.value.entry(id(1))!!.snippet.updatedAt, 0.0)
        repository.update(id(1), SnippetEdit(name = "B"))
        assertEquals(500.0, repository.snapshot.value.entry(id(1))!!.snippet.updatedAt, 0.0)
    }

    @Test
    fun updateSanitisesTheKeywordAndNormalisesTags() = runTest {
        store.seed(listOf(seed(snippet(1))))
        repository.update(id(1), SnippetEdit(keyword = " \\a b ", tags = listOf(" x  y ", "X Y")))
        val snippet = repository.snapshot.value.entry(id(1))!!.snippet
        assertEquals("a-b", snippet.keyword)
        assertEquals(listOf("x y"), snippet.tags)
    }

    @Test
    fun deleteAndRestorePutTheEntryBackAtItsPlaceOnce() = runTest {
        store.seed(listOf(seed(snippet(1)), seed(snippet(2)), seed(snippet(3))))
        val deletion = repository.delete(id(2)).valueOrNull()!!
        assertFalse(deletion.wasSecure)
        assertEquals(listOf(id(1), id(3)), storageOrder())
        assertTrue(repository.restore(deletion.undo!!) is Outcome.Success)
        assertEquals(listOf(id(1), id(2), id(3)), storageOrder())
        assertEquals(LibraryError.UndoUnavailable, repository.restore(deletion.undo!!).errorOrNull())
    }

    @Test
    fun restoreKeepsEditsMadeInBetween() = runTest {
        store.seed(listOf(seed(snippet(1)), seed(snippet(2))))
        val deletion = repository.delete(id(1)).valueOrNull()!!
        repository.update(id(2), SnippetEdit(name = "Edited"))
        repository.restore(deletion.undo!!)
        assertEquals("Edited", repository.snapshot.value.entry(id(2))!!.snippet.name)
        assertEquals("Entry 1", repository.snapshot.value.entry(id(1))!!.snippet.name)
    }

    @Test
    fun aSecureDeletionHasNoUndo() = runTest {
        store.seed(listOf(seed(snippet(1), secureBody = "s")))
        val deletion = repository.delete(id(1)).valueOrNull()!!
        assertTrue(deletion.wasSecure)
        assertNull(deletion.undo)
    }

    @Test
    fun duplicateOfAnEnabledEntryWithAKeywordIsDisabled() = runTest {
        store.seed(listOf(seed(snippet(1, name = "Mail", keyword = "m", content = "c", tags = listOf("t"), pinned = true)), seed(snippet(2))))
        val copyId = repository.duplicate(id(1)).valueOrNull()!!
        val copy = repository.snapshot.value.entry(copyId)!!.snippet
        assertEquals("Mail Copy", copy.name)
        assertEquals("m", copy.keyword)
        assertEquals("c", copy.content)
        assertEquals(listOf("t"), copy.tags)
        assertTrue(copy.isPinned)
        assertFalse(copy.isEnabled)
        assertEquals(listOf(id(1), copyId, id(2)), storageOrder())
    }

    @Test
    fun duplicateWithoutKeywordStaysEnabledAndABlankNameStaysBlank() = runTest {
        store.seed(listOf(seed(snippet(1, name = "  ", content = "c"))))
        val copyId = repository.duplicate(id(1)).valueOrNull()!!
        val copy = repository.snapshot.value.entry(copyId)!!.snippet
        assertEquals("", copy.name)
        assertTrue(copy.isEnabled)
    }

    @Test
    fun secureEntriesCannotBeDuplicatedOrShared() = runTest {
        store.seed(listOf(seed(snippet(1), secureBody = "s")))
        assertEquals(LibraryError.NotAvailableForSecure, repository.duplicate(id(1)).errorOrNull())
        assertEquals(LibraryError.NotAvailableForSecure, repository.shareLink(id(1)).errorOrNull())
        assertEquals(LibraryError.NotFound, repository.duplicate(id(9)).errorOrNull())
    }

    @Test
    fun shareLinkRoundTripsThroughTheDeepLinkCodec() = runTest {
        store.seed(listOf(seed(snippet(1, name = "Mail", keyword = "m", content = "Hello", tags = listOf("t")))))
        val link = repository.shareLink(id(1)).valueOrNull()!!
        assertTrue(link.startsWith("snippets://share?data="))
        val received = SnippetDeepLink.snippet(link)
        assertEquals("Mail", received.name)
        assertEquals("Hello", received.content)
        assertEquals(listOf("t"), received.tags)
    }

    @Test
    fun aWriteErrorChangesNothing() = runTest {
        store.seed(listOf(seed(snippet(1))))
        controls.writeError = LibraryError.WriteFailed
        assertEquals(LibraryError.WriteFailed, repository.update(id(1), SnippetEdit(name = "X")).errorOrNull())
        assertEquals("Entry 1", repository.snapshot.value.entry(id(1))!!.snippet.name)
        assertEquals(LibraryError.WriteFailed, repository.create().errorOrNull())
    }

    @Test
    fun aSaveErrorKeepsTheChangeInMemoryButReportsIt() = runTest {
        store.seed(listOf(seed(snippet(1))))
        controls.saveError = LibraryError.WriteFailed
        assertEquals(LibraryError.WriteFailed, repository.update(id(1), SnippetEdit(name = "X")).errorOrNull())
        assertEquals("X", repository.snapshot.value.entry(id(1))!!.snippet.name)
        assertEquals(LibraryError.WriteFailed, repository.flush().errorOrNull())
    }

    @Test
    fun latencyIsVirtualTime() = runTest {
        controls.latencyMillis = 1_000
        val before = testScheduler.currentTime
        repository.create()
        assertEquals(1_000, testScheduler.currentTime - before)
    }

    @Test
    fun aQuarantinedLibraryRefusesWrites() = runTest {
        store.setAvailability(com.khm.snippets.android.data.LibraryAvailability.Quarantined)
        assertEquals(LibraryError.RecoveryRequired, repository.create().errorOrNull())
    }

    @Test
    fun importMergesByIdThenKeyword() = runTest {
        store.seed(listOf(seed(snippet(1, name = "One", keyword = "one")), seed(snippet(2, name = "Two", keyword = "two"))))
        val count = repository.importSnippets(
            listOf(snippet(1, name = "One again"), snippet(5, name = "Two again", keyword = "TWO"), snippet(6, name = "New")),
        ).valueOrNull()
        assertEquals(3, count)
        val snapshot = repository.snapshot.value
        assertEquals("One again", snapshot.entry(id(1))!!.snippet.name)
        assertEquals("Two again", snapshot.entry(id(2))!!.snippet.name)
        assertNull(snapshot.entry(id(5)))
        assertEquals("New", snapshot.entry(id(6))!!.snippet.name)
    }

    @Test
    fun importConflictingWithASecureEntryIsRefusedWhole() = runTest {
        store.seed(listOf(seed(snippet(1, keyword = "tok"), secureBody = "s")))
        assertEquals(
            LibraryError.ImportConflicts(1),
            repository.importSnippets(listOf(snippet(5, keyword = "tok"), snippet(6))).errorOrNull(),
        )
        assertNull(repository.snapshot.value.entry(id(6)))
        assertEquals(LibraryError.EmptyImport, repository.importSnippets(emptyList()).errorOrNull())
    }

    @Test
    fun exportListsOnlyOrdinarySnippets() = runTest {
        store.seed(listOf(seed(snippet(1)), seed(snippet(2), secureBody = "s")))
        assertEquals(listOf(id(1)), repository.exportableSnippets().valueOrNull()!!.map { it.id })
    }

    @Test
    fun toggleTagAddsOrRemovesByFoldedKey() = runTest {
        store.seed(listOf(seed(snippet(1, tags = listOf("Work")))))
        repository.toggleTag(id(1), "WORK")
        assertTrue(repository.snapshot.value.entry(id(1))!!.snippet.tags.isEmpty())
        repository.toggleTag(id(1), "home")
        assertEquals(listOf("home"), repository.snapshot.value.entry(id(1))!!.snippet.tags)
    }
}
