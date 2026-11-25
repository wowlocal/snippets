package com.khm.snippets.android.ui.model

import androidx.compose.ui.text.AnnotatedString
import com.khm.snippets.android.ui.components.GroupingTransformation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CodeFormatTest {
    private val key = "7K2M9QXD4FTRHV3NP8WC6YJAB5G"

    @Test
    fun sanitizeUpperCasesAndDropsSeparators() {
        assertEquals("7K2M9QXD4F", CodeFormat.sanitize("7k2m-9qxd 4f"))
        assertEquals("7K2M9QXD", CodeFormat.sanitize(" 7K2M--9QXD\n"))
        assertEquals("", CodeFormat.sanitize(" - - "))
    }

    @Test
    fun sanitizeKeepsCharactersOutsideTheAlphabetForValidation() {
        assertEquals("7K2!", CodeFormat.sanitize("7k2!"))
    }

    @Test
    fun sanitizeEditKeepsTheCaretBehindTheSameSymbol() {
        // "7k2m-|9q": the caret follows the hyphen, which is removed.
        assertEquals("7K2M9Q" to 4, CodeFormat.sanitizeEdit("7k2m-9q", 5))
        // Caret in the middle, nothing removed before it.
        assertEquals("7K2M9Q" to 2, CodeFormat.sanitizeEdit("7k2m9q", 2))
        // Caret at the end after a pasted, grouped value.
        assertEquals("7K2M9QXD" to 8, CodeFormat.sanitizeEdit("7k2m-9qxd", 9))
        // A stray separator typed in the middle leaves the caret where it was.
        assertEquals("7K2M" to 2, CodeFormat.sanitizeEdit("7K 2M", 3))
    }

    @Test
    fun sanitizeEditBoundsTheCaret() {
        assertEquals("AB" to 2, CodeFormat.sanitizeEdit("ab", 99))
        assertEquals("AB" to 0, CodeFormat.sanitizeEdit("ab", -3))
    }

    @Test
    fun groupsOfFourWithAShortLastGroup() {
        assertEquals(listOf("7K2M", "9QXD", "4FTR", "HV3N", "P8WC", "6YJA", "B5G"), CodeFormat.groups(key))
        assertEquals("7K2M-9QXD-4FTR-HV3N-P8WC-6YJA-B5G", CodeFormat.grouped(key))
        assertEquals("", CodeFormat.grouped(""))
        assertEquals("7K2M", CodeFormat.grouped("7K2M"))
        assertEquals("7K2M-9", CodeFormat.grouped("7K2M9"))
    }

    @Test
    fun groupedNeverStartsOrEndsWithASeparator() {
        for (length in 0..key.length) {
            val grouped = CodeFormat.grouped(key.take(length))
            assertTrue(grouped, !grouped.startsWith("-") && !grouped.endsWith("-"))
        }
    }

    @Test
    fun rawOffsetsMapIntoTheGroupedText() {
        // ABCD-EFGH-I
        assertEquals(0, CodeFormat.rawToGroupedOffset(0, 9))
        assertEquals(4, CodeFormat.rawToGroupedOffset(4, 9)) // before the separator
        assertEquals(6, CodeFormat.rawToGroupedOffset(5, 9))
        assertEquals(9, CodeFormat.rawToGroupedOffset(8, 9))
        assertEquals(11, CodeFormat.rawToGroupedOffset(9, 9))
        assertEquals(11, CodeFormat.rawToGroupedOffset(42, 9))
    }

    @Test
    fun groupedOffsetsMapBackToRaw() {
        assertEquals(4, CodeFormat.groupedToRawOffset(4, 9))
        assertEquals(4, CodeFormat.groupedToRawOffset(5, 9)) // just after the separator
        assertEquals(5, CodeFormat.groupedToRawOffset(6, 9))
        assertEquals(8, CodeFormat.groupedToRawOffset(10, 9))
        assertEquals(9, CodeFormat.groupedToRawOffset(11, 9))
        assertEquals(9, CodeFormat.groupedToRawOffset(99, 9))
        assertEquals(0, CodeFormat.groupedToRawOffset(-1, 9))
    }

    @Test
    fun offsetMappingsRoundTripForEveryLength() {
        for (length in 0..key.length) {
            val groupedLength = CodeFormat.grouped(key.take(length)).length
            for (raw in 0..length) {
                val grouped = CodeFormat.rawToGroupedOffset(raw, length)
                assertTrue(grouped in 0..groupedLength)
                assertEquals(raw, CodeFormat.groupedToRawOffset(grouped, length))
            }
            for (grouped in 0..groupedLength) {
                assertTrue(CodeFormat.groupedToRawOffset(grouped, length) in 0..length)
            }
        }
    }

    @Test
    fun visualTransformationGroupsAndMapsOffsets() {
        val transformed = GroupingTransformation(groupSize = 4).filter(AnnotatedString("7K2M9QXD4F"))
        assertEquals("7K2M-9QXD-4F", transformed.text.text)
        assertEquals(6, transformed.offsetMapping.originalToTransformed(5))
        assertEquals(12, transformed.offsetMapping.originalToTransformed(10))
        assertEquals(4, transformed.offsetMapping.transformedToOriginal(5))
        assertEquals(10, transformed.offsetMapping.transformedToOriginal(12))
    }

    @Test
    fun spelledSeparatesCharactersAndGroups() {
        assertEquals("7 K 2 M, 9 Q X D, 4", CodeFormat.spelled("7K2M9QXD4"))
        assertEquals("", CodeFormat.spelled(""))
    }

    @Test
    fun endingTakesTheLastSixCharacters() {
        assertEquals("device", CodeFormat.ending("ssh-ed25519 AAAA snippets-device"))
        assertEquals("abc", CodeFormat.ending("abc"))
    }
}

class CountdownFormatTest {
    @Test
    fun remainingRoundsUpToWholeSeconds() {
        assertEquals("1:00", CountdownFormat.remaining(60_000))
        assertEquals("1:00", CountdownFormat.remaining(59_001))
        assertEquals("0:59", CountdownFormat.remaining(59_000))
        assertEquals("0:42", CountdownFormat.remaining(42_000))
        assertEquals("0:42", CountdownFormat.remaining(41_050))
        assertEquals("0:01", CountdownFormat.remaining(1))
        assertEquals("0:00", CountdownFormat.remaining(0))
    }

    @Test
    fun remainingIsNeverNegative() {
        assertEquals("0:00", CountdownFormat.remaining(-5_000))
    }

    @Test
    fun remainingCoversLongerLifetimes() {
        assertEquals("5:00", CountdownFormat.remaining(300_000))
        assertEquals("2:05", CountdownFormat.remaining(125_000))
    }

    @Test
    fun fractionDrainsFromOneToZero() {
        assertEquals(1f, CountdownFormat.fraction(60_000, 60_000), 0f)
        assertEquals(0.5f, CountdownFormat.fraction(30_000, 60_000), 0f)
        assertEquals(0f, CountdownFormat.fraction(0, 60_000), 0f)
        assertEquals(0f, CountdownFormat.fraction(-1, 60_000), 0f)
        assertEquals(1f, CountdownFormat.fraction(90_000, 60_000), 0f)
        assertEquals(0f, CountdownFormat.fraction(10, 0), 0f)
    }
}
