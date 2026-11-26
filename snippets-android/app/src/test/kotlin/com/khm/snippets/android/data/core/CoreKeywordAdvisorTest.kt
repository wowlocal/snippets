package com.khm.snippets.android.data.core

import com.khm.snippets.android.data.KeywordAdvice
import com.khm.snippets.android.data.KeywordDraft
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.android.testing.id
import com.khm.snippets.android.testing.snippet
import com.khm.snippets.core.model.Snippet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreKeywordAdvisorTest {
    private val advisor = CoreKeywordAdvisor()

    private fun library(vararg others: Snippet, secure: List<Snippet> = emptyList()) =
        LibrarySnapshot.build(listOf(snippet(1)) + others, secure, revision = 1)

    private fun draft(keyword: String, enabled: Boolean = true, name: String = "Entry", firstLine: String = "") =
        KeywordDraft(id(1), keyword, name, firstLine, enabled)

    @Test
    fun missingKeywordComesFirst() {
        assertEquals(KeywordAdvice.MissingKeyword, advisor.advice(draft("", enabled = false), library()))
    }

    @Test
    fun aDisabledEntryReportsOnlyThat() {
        val withDuplicate = library(snippet(2, keyword = "sig"))
        assertEquals(KeywordAdvice.EntryDisabled("sig"), advisor.advice(draft("sig", enabled = false), withDuplicate))
    }

    @Test
    fun aMultiScalarCharacterIsAWarning() {
        val advice = advisor.advice(draft("café"), library())
        assertEquals(KeywordAdvice.InvalidCharacters("café"), advice)
        assertTrue(advice.isWarning)
    }

    @Test
    fun duplicatesNameTheOtherEntry() {
        assertEquals(KeywordAdvice.Duplicate("sig", "Signature"), advisor.advice(draft("sig"), library(snippet(2, name = "Signature", keyword = "SIG"))))
    }

    @Test
    fun aSecureEntryCollidesToo() {
        val secure = snippet(3, name = "Token", keyword = "tok", content = "body")
        assertEquals(KeywordAdvice.Duplicate("tok", "Token"), advisor.advice(draft("tok"), library(secure = listOf(secure))))
    }

    @Test
    fun prefixRelationsBothWays() {
        assertEquals(KeywordAdvice.BlockedByLonger("sig", "sig-long"), advisor.advice(draft("sig"), library(snippet(2, keyword = "sig-long"))))
        assertEquals(KeywordAdvice.BlocksShorter("si"), advisor.advice(draft("sig"), library(snippet(2, keyword = "si"))))
    }

    @Test
    fun disabledOthersAndTheEntryItselfAreIgnored() {
        assertEquals(KeywordAdvice.None, advisor.advice(draft("sig"), library(snippet(2, keyword = "sig", enabled = false))))
        val self = LibrarySnapshot.build(listOf(snippet(1, keyword = "sig")), emptyList(), 1)
        assertEquals(KeywordAdvice.None, advisor.advice(draft("sig"), self))
    }

    @Test
    fun suggestionsSkipEnabledCollisionsAndStopAtThree() {
        val suggestions = advisor.suggestions(draft("", name = "Meeting notes", firstLine = "Agenda for today"), library(snippet(2, keyword = "meet")))
        assertFalse("meet" in suggestions)
        assertFalse("mee" in suggestions)
        assertTrue(suggestions.size <= 3)
        assertTrue(suggestions.isNotEmpty())
    }

    @Test
    fun suggestionsComeOnlyFromNameAndTheGivenFirstLine() {
        // The editor passes an empty first line for a secure entry.
        val suggestions = advisor.suggestions(draft("", name = "", firstLine = ""), library())
        assertTrue(suggestions.isEmpty())
        assertEquals(listOf("hello"), advisor.suggestions(draft("", name = "", firstLine = "hello"), library()))
    }

    @Test
    fun existingMatchesShowEightAndCountTheRest() {
        val others = (2..11).map { snippet(it, keyword = "ab$it") }.toTypedArray()
        val existing = advisor.existingMatches("ab", id(1), library(*others))
        assertEquals(8, existing.shown.size)
        assertEquals(2, existing.moreCount)
    }

    @Test
    fun existingMatchesExcludeTheEntryItself() {
        val self = LibrarySnapshot.build(listOf(snippet(1, keyword = "abc")), emptyList(), 1)
        assertTrue(advisor.existingMatches("ab", id(1), self).shown.isEmpty())
    }

    @Test
    fun completionStopsAfterTheNextSeparator() {
        val dotted = library(snippet(2, keyword = "git.push"), snippet(3, keyword = "git.pull"))
        assertEquals("git.", advisor.completion("git", id(1), dotted))
        assertEquals("git.pu", advisor.completion("git.p", id(1), dotted))
        val dashed = library(snippet(2, keyword = "mail-home"), snippet(3, keyword = "mail-work"))
        assertEquals("mail-", advisor.completion("ma", id(1), dashed))
        assertNull(advisor.completion("zz", id(1), dashed))
    }
}
