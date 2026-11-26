package com.khm.snippets.android.feature.library

import com.khm.snippets.android.data.LibraryEntry
import com.khm.snippets.android.data.QueryRow
import com.khm.snippets.android.data.TextRange
import com.khm.snippets.android.testing.FakeTimeFormatter
import com.khm.snippets.android.testing.snippet
import com.khm.snippets.android.ui.model.RowPreviewUi
import com.khm.snippets.android.ui.model.TextHighlight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryRowMapperTest {
    private val mapper = LibraryRowMapper(FakeTimeFormatter())

    private fun row(
        name: String = "Name",
        keyword: String = "",
        content: String = "",
        secure: Boolean = false,
        match: (LibraryEntry) -> QueryRow = { QueryRow(it) },
    ) = mapper.row(match(LibraryEntry(snippet(1, name = name, keyword = keyword, content = if (secure) "" else content, tags = listOf("Work")), secure)))

    @Test
    fun keywordAndContent() {
        val row = row(keyword = "kw", content = "\n  first   line \nsecond")
        assertEquals("kw", row.keyword)
        assertEquals(RowPreviewUi.Text("first line"), row.preview)
        assertEquals("row:1", row.time)
    }

    @Test
    fun keywordOnlyHasNoPreview() {
        assertEquals(RowPreviewUi.None, row(keyword = "kw").preview)
    }

    @Test
    fun contentOnly() {
        val row = row(content = "text")
        assertNull(row.keyword)
        assertEquals(RowPreviewUi.Text("text"), row.preview)
    }

    @Test
    fun neitherIsNoContent() {
        assertEquals(RowPreviewUi.NoContent, row().preview)
    }

    @Test
    fun secureEntriesShowTheFixedPreview() {
        val row = row(keyword = "tok", secure = true)
        assertEquals(RowPreviewUi.Secure, row.preview)
        assertTrue(row.isSecure)
    }

    @Test
    fun aLaterLineHitBecomesAnExcerptWithItsHighlightShifted() {
        val content = "first line\nsecond line has the needle here"
        val start = content.indexOf("needle")
        val row = row(content = content) { QueryRow(it, content = TextRange(start, start + 6)) }
        val preview = row.preview as RowPreviewUi.Text
        assertTrue(preview.isExcerpt)
        assertEquals("nd line has the needle here", preview.text)
        assertEquals(listOf(TextHighlight(16, 22)), preview.highlights)
    }

    @Test
    fun aFirstLineHitStaysOnTheFirstLine() {
        val content = "a  needle\nb"
        val row = row(content = content) { QueryRow(it, content = TextRange(3, 9)) }
        assertEquals(RowPreviewUi.Text("a needle", listOf(TextHighlight(2, 8))), row.preview)
    }

    @Test
    fun aBlankNameShowsTheFirstContentLine() {
        assertEquals("first", row(name = "  ", content = "first\nsecond").name)
        assertEquals("", row(name = "", secure = true).name)
    }

    @Test
    fun nameHighlightsFollowTheTrimmedName() {
        val row = row(name = "  Alpha") { QueryRow(it, name = listOf(TextRange(2, 4))) }
        assertEquals("Alpha", row.name)
        assertEquals(listOf(TextHighlight(0, 2)), row.nameHighlights)
    }

    @Test
    fun keywordAndTagHighlightsAreCarried() {
        val row = row(keyword = "kw") {
            QueryRow(it, keyword = listOf(TextRange(0, 1)), tags = mapOf("work" to listOf(TextRange(0, 2))))
        }
        assertEquals(listOf(TextHighlight(0, 1)), row.keywordHighlights)
        assertEquals(listOf(TextHighlight(0, 2)), row.tags.single().highlights)
        assertEquals("work", row.tags.single().folded)
    }
}
