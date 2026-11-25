package com.khm.snippets.core.assist

import com.khm.snippets.core.model.Snippet
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The keyword warning and suggestion rules of the iOS editors. The Rust port tests the
 * same rules in `summarize` (`editor_assistance_tests.rs`); its fixtures are reused here.
 */
class KeywordAdviceTest {

    private fun record(keyword: String, enabled: Boolean = true, name: String = "Public fixture") =
        Snippet(name = name, keyword = keyword, content = "", isEnabled = enabled)

    @Test
    fun warningsFollowTheEditorsOrder() {
        assertEquals(KeywordAdvice.Warning.MissingKeyword, KeywordAdvice.warning(record(""), emptyList()))
        assertEquals(KeywordAdvice.Warning.MissingKeyword, KeywordAdvice.warning(record(" \\ ", enabled = false), emptyList()))
        // Disabled comes before every conflict.
        val email = record("email")
        assertEquals(KeywordAdvice.Warning.Disabled, KeywordAdvice.warning(record("EMAIL", enabled = false), listOf(email)))
        assertEquals(KeywordAdvice.Warning.UnsupportedCharacters, KeywordAdvice.warning(record("cafe\u0301"), listOf(record("cafe\u0301"))))
        assertEquals(KeywordAdvice.Warning.UnsupportedCharacters, KeywordAdvice.warning(record("👨\u200D👩\u200D👧"), emptyList()))
        assertNull(KeywordAdvice.warning(record("café-123"), emptyList()))
        assertNull(KeywordAdvice.warning(record("🔑"), emptyList()), "one scalar outside the BMP is one scalar")
    }

    @Test
    fun bothPrefixDirectionsAndDuplicatesAreReportedAgainstTheFirstConflict() {
        val own = record("email")
        val shorter = record("em")
        val longer = record("email-long")
        val twin = record("\\EMAIL")
        assertEquals(KeywordAdvice.Warning.Duplicate(twin), KeywordAdvice.warning(own, listOf(own, twin, shorter, longer)))
        assertEquals(KeywordAdvice.Warning.BlocksShorter(shorter), KeywordAdvice.warning(own, listOf(shorter, longer, twin)))
        assertEquals(KeywordAdvice.Warning.BlockedByLonger(longer), KeywordAdvice.warning(own, listOf(own, longer, shorter)))
        assertNull(KeywordAdvice.warning(own, listOf(own, record("sig"), record("xemail"))))
        // Folding: case, diacritics and the backslash do not make a keyword different.
        assertEquals(KeywordAdvice.Warning.Duplicate(own), KeywordAdvice.warning(record("ÉMAIL"), listOf(own)))
    }

    @Test
    fun anEntryWithoutAKeywordConflictsWithNothing() {
        val own = record("sig")
        assertNull(KeywordAdvice.warning(own, listOf(record(""), record("  "))))
        assertEquals(listOf("sign", "sig", "sb"), KeywordAdvice.suggestions("Signature Block", "", listOf("", " ")))
    }

    @Test
    fun suggestionsSkipWhatWouldCollideAndStopAtThree() {
        // "sign" and "sig" are prefixes of an existing keyword, "sb" is taken.
        assertEquals(listOf("best"), KeywordAdvice.suggestions("Signature Block", "Best regards", listOf("signature", "SB")))
        // A secure snippet passes no content line.
        assertEquals(listOf("sign", "sig", "sb"), KeywordAdvice.suggestions("Signature Block", "", emptyList()))
        assertEquals(emptyList(), KeywordAdvice.suggestions("", "", emptyList()))
        assertEquals(3, KeywordAdvice.suggestions("Signature Block", "Best regards", emptyList()).size)
        assertEquals(listOf("sign", "sig", "sb", "best"), KeywordAdvice.suggestions("Signature Block", "Best regards", emptyList(), limit = 10))
        assertEquals(emptyList(), KeywordAdvice.suggestions("Signature Block", "Best regards", emptyList(), limit = -1))
        // One existing single letter blocks every candidate that starts with it.
        assertEquals(listOf("best"), KeywordAdvice.suggestions("Signature Block", "Best regards", listOf("s")))
    }
}
