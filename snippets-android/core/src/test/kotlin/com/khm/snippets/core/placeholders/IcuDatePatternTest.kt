package com.khm.snippets.core.placeholders

import com.khm.snippets.core.placeholders.IcuDatePattern.Item.Field
import com.khm.snippets.core.placeholders.IcuDatePattern.Item.Literal
import com.khm.snippets.core.search.UtilitiesFixture
import java.time.ZoneId
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** How a pattern is read, and that the repaired pattern formats to the same text as the original. */
class IcuDatePatternTest {

    private fun items(pattern: String) = IcuDatePattern.parse(pattern).items

    @Test
    fun fieldsLiteralsAndQuotes() {
        assertEquals(listOf(Field('y', 4), Literal("-"), Field('M', 2), Literal("-"), Field('d', 2)), items("yyyy-MM-dd"))
        assertEquals(listOf(Field('h', 1), Literal(" o'clock")), items("h 'o''clock'"))
        assertEquals(listOf(Literal("'")), items("''"))
        assertEquals(listOf(Literal("''")), items("''''"))
        assertEquals(listOf(Field('y', 1), Literal("'y")), items("y'''y"))
        assertEquals(listOf(Field('y', 4), Literal("unterminated MM")), items("yyyy'unterminated MM"))
        assertEquals(listOf(Field('y', 4), Literal("年"), Field('M', 2), Literal("月")), items("yyyy年MM月"))
        assertEquals(listOf(Field('y', 2), Literal("y")), items("yy'y'"))
        assertEquals(listOf(Field('y', 1), Literal("x"), Field('y', 1)), items("y'x'y"), "the same letter again after a quote is a new field")
        assertEquals(emptyList(), items(""))
        assertTrue(IcuDatePattern.parse("yyyy-MM-dd").isComplete)
        for (letter in IcuDatePattern.FIELD_LETTERS) assertEquals(listOf(Field(letter, 3)), items("$letter$letter$letter"))
    }

    @Test
    fun anInvalidLetterEndsThePatternAndTheNextLiteralStillPrints() {
        assertEquals(emptyList(), items("foo"))
        assertEquals(emptyList(), items("it''s"))
        assertEquals(listOf(Field('y', 4), Literal("-"), Field('M', 2), Literal("-"), Field('d', 2)), items("yyyy-MM-ddTHH"))
        assertEquals(listOf(Field('y', 4), Literal("-")), items("yyyyp-MM"), "ICU appends the character that follows the bad run")
        assertEquals(listOf(Field('y', 4), Literal("-")), items("yyyy-pMM"))
        assertEquals(listOf(Field('y', 4), Literal("'")), items("yyyyp''MM"))
        assertEquals(listOf(Field('y', 4)), items("yyyyp'q'MM"))
        assertEquals(listOf(Field('y', 4), Literal("x")), items("yyyy'x'p'y'MM"))
        assertEquals(listOf(Field('d', 1)), items("dT"))
        assertFalse(IcuDatePattern.parse("dT").isComplete)
        assertFalse(IcuDatePattern.parse("p").isComplete)
        // `l` is deprecated and skipped without an error.
        assertEquals(listOf(Field('y', 4), Literal("-"), Field('M', 2)), items("yyyyl-MM"))
        assertEquals(emptyList(), items("lll"))
        assertTrue(IcuDatePattern.parse("lll").isComplete)
        for (letter in "CIJNPRTfijnopt") assertEquals(listOf(Field('d', 1)), items("d$letter"), "$letter is not a field")
    }

    @Test
    fun theRepairedPatternIsValidAndEquivalent() {
        assertEquals("yyyy'-'MM'-'dd", IcuDatePattern.formattablePrefix("yyyy-MM-ddTHH"))
        assertEquals("", IcuDatePattern.formattablePrefix("foo"))
        assertEquals("h' o''clock'", IcuDatePattern.formattablePrefix("h 'o''clock'"))
        assertEquals("''", IcuDatePattern.formattablePrefix("''"))
        assertEquals("''''", IcuDatePattern.formattablePrefix("''''"))
        assertEquals("'''x''y'''", IcuDatePattern.formattablePrefix("'''x''y'''"))
        for (pattern in listOf("''", "''''", "'x'", "'''x'", "'x'''", "'''x'''", "'x''y'", "''''''", "a''b", "'a''''b'", "y''''y", "d''", "d'")) {
            val repaired = IcuDatePattern.formattablePrefix(pattern)
            assertEquals(IcuDatePattern.parse(pattern).items, IcuDatePattern.parse(repaired).items, pattern)
        }
        assertEquals("yyyy'-'MM", IcuDatePattern.formattablePrefix("yyyyl-MM"))
        assertEquals("y'''y'", IcuDatePattern.formattablePrefix("y'''y"))

        // Every pattern of the Foundation fixture: the repaired pattern is complete, a fixed
        // point, and formats to the same text.
        val renderer = JvmDateRenderer(Locale.US, ZoneId.of("UTC"))
        val patterns = HashSet<String>()
        for (line in UtilitiesFixture.lines("swift-dates.tsv")) {
            val fields = line.split('\t')
            if (fields[0] != "@") patterns.add(UtilitiesFixture.text(fields[1]))
        }
        assertTrue(patterns.size > 200)
        for (pattern in patterns) {
            val repaired = IcuDatePattern.formattablePrefix(pattern)
            val label = UtilitiesFixture.scalars(pattern)
            assertTrue(IcuDatePattern.parse(repaired).isComplete, label)
            assertEquals(repaired, IcuDatePattern.formattablePrefix(repaired), label)
            assertEquals(renderer.format(1_769_902_215_000L, pattern), renderer.format(1_769_902_215_000L, repaired), label)
        }
    }
}
