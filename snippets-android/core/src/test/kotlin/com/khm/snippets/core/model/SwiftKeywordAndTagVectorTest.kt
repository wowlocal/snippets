package com.khm.snippets.core.model

import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.text.FoundationFixture
import com.khm.snippets.core.text.FoundationText
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `L03-keyword-and-tags` and `L03b-filterkey-table`: keyword and tag normalization, the
 * fold of every Unicode scalar, and the fate of U+0301 after every base, from Swift.
 *
 * L03b and `foundation-fold.txt` are two independent measurements of the same Foundation
 * function, by two tools. They must agree scalar for scalar.
 */
class SwiftKeywordAndTagVectorTest {

    private val file = "L03-keyword-and-tags"
    private val tableFile = "L03b-filterkey-table"

    private fun scalar(value: Int): String = String(Character.toChars(value))

    /** The vectors' `inputScalars` spelling: like the corpus's, but the empty string is empty. */
    private fun vectorScalars(text: String): String = if (text.isEmpty()) "" else FoundationFixture.scalars(text)

    @Test
    fun sanitizedKeywords() {
        val cases = SwiftVectors.cases(file, "sanitizedKeyword")
        assertEquals(43, cases.size)
        for (case in cases) {
            val sanitized = Snippet.sanitizedKeyword(case.text("input"))
            assertEquals(case.text("sanitized"), sanitized, case.label)
            assertEquals(case.text("filterKey"), SnippetTagging.rawFilterKey(sanitized), case.label)
        }
    }

    @Test
    fun normalizedTags() {
        val cases = SwiftVectors.cases(file, "normalizedTags")
        assertEquals(29, cases.size)
        for (case in cases) {
            val input = case.texts("input")
            assertEquals(case.texts("normalized"), SnippetTagging.normalizedTags(input), case.label)
            assertEquals(case.texts("inputFilterKeys"), input.map(SnippetTagging::rawFilterKey), case.label)
        }
    }

    @Test
    fun filterKeys() {
        val cases = SwiftVectors.cases(file, "filterKey")
        assertEquals(126, cases.size)
        for (case in cases) {
            val input = case.text("input")
            assertEquals(case.string("inputScalars"), vectorScalars(input), case.label)
            val folded = SnippetTagging.rawFilterKey(input)
            assertEquals(case.string("foldedScalars"), vectorScalars(folded), case.label)
            assertEquals(case.text("folded"), folded, case.label)
            // The key callers compare is the same key in Swift's eyes.
            assertTrue(FoundationText.canonicalEquals(folded, SnippetTagging.filterKey(input)), case.label)
        }
    }

    @Test
    fun characterSets() {
        val cases = SwiftVectors.cases(file, "characterSet")
        assertEquals(3, cases.size)
        for (case in cases) {
            val isMember: (Int) -> Boolean = when (case.string("set")) {
                "whitespacesAndNewlines" -> FoundationText::isWhitespaceOrNewline
                "whitespaces" -> FoundationText::isWhitespace
                "newlines" -> FoundationText::isNewline
                else -> fail("${case.label}: unknown set")
            }
            val members = HashSet<Int>()
            for (range in case.strings("ranges")) {
                val bounds = range.split('-').map { it.toInt(16) }
                for (value in bounds.first()..bounds.last()) members.add(value)
            }
            for (value in 0..0x10FFFF) assertEquals(value in members, isMember(value), "${case.label} U+%04X".format(value))
        }
    }

    /** Every scalar: the 1,943 that change fold to exactly the listed scalars, and every other one folds to itself. */
    @Test
    fun theFoldOfEveryScalarMatchesTheSwiftTable() {
        val case = SwiftVectors.cases(tableFile, "scalar-table").single()
        val expected = HashMap<Int, String>()
        for (entry in case.array("entries")) {
            val pair = entry.jsonArray.map { it.jsonPrimitive.content }
            expected[pair[0].toInt(16)] = pair[1]
        }
        assertEquals(case.int("count"), expected.size)
        assertEquals(1943, expected.size)

        var changed = 0
        for (value in 0..0x10FFFF) {
            if (value in 0xD800..0xDFFF) continue
            val folded = FoundationFixture.scalars(FoundationText.fold(scalar(value)))
            val own = FoundationFixture.scalars(scalar(value))
            assertEquals(expected[value] ?: own, folded, "fold of U+%04X".format(value))
            if (folded != own) changed += 1
        }
        assertEquals(1943, changed)
    }

    /** Base + U+0301 for every base below U+30000: where the mark is dropped, and where it is kept after the folded base. */
    @Test
    fun theAcuteAfterEveryBaseMatchesTheSwiftTable() {
        val case = SwiftVectors.cases(tableFile, "mark-after-base").single()
        assertEquals("0301", case.string("mark"))
        val stripped = java.util.BitSet(0x30000)
        for (range in case.strings("strippedAfter")) {
            val bounds = range.split('-').map { it.toInt(16) }
            stripped.set(bounds.first(), bounds.last() + 1)
        }
        val otherwise = HashMap<Int, String>()
        for (entry in case.array("otherwise")) {
            val pair = entry.jsonArray.map { it.jsonPrimitive.content }
            otherwise[pair[0].toInt(16)] = pair[1]
        }

        var strippedCount = 0
        for (value in 0 until 0x30000) {
            if (value in 0xD800..0xDFFF) continue
            val alone = FoundationText.fold(scalar(value))
            val withMark = FoundationText.fold(scalar(value) + "́")
            val label = "U+%04X + U+0301".format(value)
            when {
                stripped.get(value) -> {
                    assertEquals(FoundationFixture.scalars(alone), FoundationFixture.scalars(withMark), label)
                    strippedCount += 1
                }
                value in otherwise -> assertEquals(otherwise.getValue(value), FoundationFixture.scalars(withMark), label)
                else -> assertEquals(FoundationFixture.scalars(alone + "́"), FoundationFixture.scalars(withMark), label)
            }
        }
        assertTrue(strippedCount > 100_000, "stripped after $strippedCount bases")
    }

    @Test
    fun everyKindIsAccountedFor() {
        val kinds = SwiftVectors.cases(file).groupingBy { it.kind }.eachCount()
        assertEquals(setOf("sanitizedKeyword", "normalizedTags", "filterKey", "characterSet"), kinds.keys)
        assertEquals(201, kinds.values.sum())
        assertEquals(listOf("scalar-table", "mark-after-base"), SwiftVectors.cases(tableFile).map { it.kind })
    }
}
