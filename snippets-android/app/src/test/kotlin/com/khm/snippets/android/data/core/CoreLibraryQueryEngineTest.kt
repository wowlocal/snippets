package com.khm.snippets.android.data.core

import com.khm.snippets.android.data.LibraryQuery
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.android.data.TextRange
import com.khm.snippets.android.testing.id
import com.khm.snippets.android.testing.snippet
import com.khm.snippets.core.model.Snippet
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreLibraryQueryEngineTest {
    private val engine = CoreLibraryQueryEngine(Dispatchers.Unconfined)

    private fun snapshot(ordinary: List<Snippet>, secure: List<Snippet> = emptyList()) =
        LibrarySnapshot.build(ordinary, secure, revision = 7)

    @Test
    fun emptyQueryListsEverythingInDisplayOrderWithoutHighlights() = runTest {
        val result = engine.search(
            snapshot(listOf(snippet(1), snippet(2, pinned = true), snippet(3))),
            LibraryQuery(),
        )
        assertEquals(listOf(id(2), id(3), id(1)), result.rows.map { it.entry.id })
        assertTrue(result.rows.all { it.name.isEmpty() && it.content == null })
        assertEquals(7, result.revision)
        assertEquals(3, result.totalCount)
    }

    @Test
    fun fuzzyNameMatchHighlightsEachMatchedCharacter() = runTest {
        val result = engine.search(snapshot(listOf(snippet(1, name = "Project Alpha"), snippet(2, name = "Other"))), LibraryQuery("prjal"))
        val row = result.rows.single()
        assertEquals(id(1), row.entry.id)
        assertTrue(row.name.isNotEmpty())
        assertEquals(0, row.name.first().start)
        assertTrue(row.name.any { it.start >= 8 })
    }

    @Test
    fun keywordAndTagMatchesAreHighlighted() = runTest {
        val result = engine.search(
            snapshot(listOf(snippet(1, keyword = "atlas-token", tags = listOf("Work")))),
            LibraryQuery("atl"),
        )
        assertEquals(listOf(TextRange(0, 3)), result.rows.single().keyword)
        val tags = engine.search(snapshot(listOf(snippet(1, tags = listOf("Work")))), LibraryQuery("wrk")).rows.single().tags
        assertEquals(setOf("work"), tags.keys)
    }

    @Test
    fun contentMatchIsOneContiguousRangeEvenOnALaterLine() = runTest {
        val content = "first line\nsecond line with needle here"
        val row = engine.search(snapshot(listOf(snippet(1, name = "N", content = content))), LibraryQuery("needle")).rows.single()
        val start = content.indexOf("needle")
        assertEquals(TextRange(start, start + 6), row.content)
    }

    @Test
    fun contentMatchIgnoresDiacriticsAndFoldsSharpS() = runTest {
        val accent = engine.search(snapshot(listOf(snippet(1, name = "N", content = "Café crème"))), LibraryQuery("creme")).rows.single()
        assertEquals(TextRange(5, 10), accent.content)
        val sharp = engine.search(snapshot(listOf(snippet(1, name = "N", content = "Die Straße ist"))), LibraryQuery("strasse")).rows.single()
        assertEquals(TextRange(4, 10), sharp.content)
    }

    @Test
    fun tagFiltersCombineWithAnd() = runTest {
        val library = snapshot(
            listOf(snippet(1, tags = listOf("a", "b")), snippet(2, tags = listOf("a")), snippet(3, tags = listOf("b"))),
        )
        val result = engine.search(library, LibraryQuery(tagKeys = listOf("a", "b")))
        assertEquals(listOf(id(1)), result.rows.map { it.entry.id })
    }

    @Test
    fun filtersForVanishedTagsAreDropped() = runTest {
        val result = engine.search(snapshot(listOf(snippet(1, tags = listOf("a")))), LibraryQuery(tagKeys = listOf("gone", "a")))
        assertEquals(listOf("a"), result.query.tagKeys)
        assertEquals(1, result.rows.size)
    }

    @Test
    fun searchAndFiltersCombine() = runTest {
        val library = snapshot(listOf(snippet(1, name = "alpha", tags = listOf("a")), snippet(2, name = "alpha")))
        val result = engine.search(library, LibraryQuery("alpha", listOf("a")))
        assertEquals(listOf(id(1)), result.rows.map { it.entry.id })
    }

    @Test
    fun aSecureBodyIsNeverSearchedOrHighlighted() = runTest {
        val secure = snippet(1, name = "Token", content = "secretword")
        val library = snapshot(emptyList(), listOf(secure))
        assertTrue(engine.search(library, LibraryQuery("secretword")).rows.isEmpty())
        val byName = engine.search(library, LibraryQuery("tok")).rows.single()
        assertTrue(byName.entry.isSecure)
        assertNull(byName.content)
    }

    @Test
    fun matchesKeepDisplayOrder() = runTest {
        val library = snapshot(
            listOf(snippet(1, name = "note a"), snippet(2, name = "note b", pinned = true), snippet(3, name = "note c")),
        )
        assertEquals(listOf(id(2), id(3), id(1)), engine.search(library, LibraryQuery("note")).rows.map { it.entry.id })
    }
}
