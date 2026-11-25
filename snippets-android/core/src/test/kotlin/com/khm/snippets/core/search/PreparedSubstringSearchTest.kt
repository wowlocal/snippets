package com.khm.snippets.core.search

import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.text.SeededRandom
import kotlin.test.Test
import kotlin.test.assertEquals

/** `Tests/Core/PreparedSubstringSearchTests.swift`, with the expected values emitted from Swift's `String.contains`. */
class PreparedSubstringSearchTest {

    /**
     * `testBytePathAndUnicodeFallbackAgreeWithCanonicalSubstringSearch`: the Swift test's
     * 16 texts and 25 queries, and more of each, 748 pairs in all.
     */
    @Test
    fun bytePathAndUnicodeFallbackAgreeWithCanonicalSubstringSearch() {
        val rows = UtilitiesFixture.rows("swift-substring.tsv")
        assertEquals(748, rows.size)
        for (row in rows) {
            val text = UtilitiesFixture.text(row[0])
            val query = UtilitiesFixture.text(row[1])
            val label = "text=${UtilitiesFixture.scalars(text)} query=${UtilitiesFixture.scalars(query)}"
            assertEquals(row[2], row[3], "Swift's own two answers differ: $label")
            val actual = PreparedSubstringSearch.Field(text).contains(PreparedSubstringSearch.Query(query))
            assertEquals(row[2] == "1", actual, label)
            if (query.isNotEmpty()) assertEquals(actual, SwiftStrings.contains(text, query), label)
        }
    }

    @Test
    fun swiftVectorsL04PreparedSubstring() {
        val cases = SwiftVectors.cases("L04-search", "preparedSubstring")
        assertEquals(22, cases.size)
        for (case in cases) {
            val field = PreparedSubstringSearch.Field(case.text("field"))
            val query = PreparedSubstringSearch.Query(case.text("needle"))
            assertEquals(case.text("needle"), query.text, case.label)
            assertEquals(case.boolean("contains"), field.contains(query), case.label)
            assertEquals(case.boolean("swiftStringContains"), field.contains(query), case.label)
        }
    }

    /** A brute-force reading of the contract: the needle's Characters occur as consecutive Characters of the text. */
    @Test
    fun randomTextsAgreeWithCharacterByCharacterSearch() {
        val pieces = listOf("a", "b", "é", "e", "\u0301", "\r", "\n", "\r\n", "👩", "🏽", "\u200D", "💻", "🇦", "🇧", "가", "\u1100", "\u1161", "K", "\u212A", " ")
        val random = SeededRandom(0x5B57)
        repeat(20_000) {
            val text = buildString { repeat(random.int(9)) { append(random.pick(pieces)) } }
            val needle = buildString { repeat(1 + random.int(3)) { append(random.pick(pieces)) } }
            val haystack = FoundationText.characters(text).map(FoundationText::nfc)
            val wanted = FoundationText.characters(needle).map(FoundationText::nfc)
            val expected = (0..haystack.size - wanted.size).any { start -> wanted.indices.all { haystack[start + it] == wanted[it] } }
            assertEquals(
                expected, PreparedSubstringSearch.Field(text).contains(PreparedSubstringSearch.Query(needle)),
                "text=${UtilitiesFixture.scalars(text)} needle=${UtilitiesFixture.scalars(needle)}",
            )
        }
    }
}
