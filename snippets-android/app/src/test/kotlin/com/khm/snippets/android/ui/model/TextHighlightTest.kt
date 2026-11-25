package com.khm.snippets.android.ui.model

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TextHighlightTest {
    @Test
    fun emptyInputYieldsNothing() {
        assertEquals(emptyList<TextHighlight>(), mergeHighlights(emptyList(), 10))
        assertEquals(emptyList<TextHighlight>(), mergeHighlights(listOf(TextHighlight(0, 3)), 0))
    }

    @Test
    fun overlappingRangesMerge() {
        val merged = mergeHighlights(listOf(TextHighlight(2, 5), TextHighlight(4, 8)), 20)
        assertEquals(listOf(TextHighlight(2, 8)), merged)
    }

    @Test
    fun touchingRangesMerge() {
        // Fuzzy matches arrive one character at a time.
        val merged = mergeHighlights(listOf(TextHighlight(0, 1), TextHighlight(1, 2), TextHighlight(2, 3)), 20)
        assertEquals(listOf(TextHighlight(0, 3)), merged)
    }

    @Test
    fun separateRangesStaySeparateAndSorted() {
        val merged = mergeHighlights(listOf(TextHighlight(9, 11), TextHighlight(0, 2), TextHighlight(4, 5)), 20)
        assertEquals(listOf(TextHighlight(0, 2), TextHighlight(4, 5), TextHighlight(9, 11)), merged)
    }

    @Test
    fun containedRangeDoesNotShortenItsContainer() {
        val merged = mergeHighlights(listOf(TextHighlight(0, 10), TextHighlight(2, 4)), 20)
        assertEquals(listOf(TextHighlight(0, 10)), merged)
    }

    @Test
    fun rangesAreClampedToTheText() {
        val merged = mergeHighlights(listOf(TextHighlight(-5, 2), TextHighlight(8, 99)), 10)
        assertEquals(listOf(TextHighlight(0, 2), TextHighlight(8, 10)), merged)
    }

    @Test
    fun emptyInvertedAndOutsideRangesAreDropped() {
        val merged = mergeHighlights(
            listOf(TextHighlight(3, 3), TextHighlight(7, 4), TextHighlight(50, 60), TextHighlight(-9, -1)),
            10,
        )
        assertEquals(emptyList<TextHighlight>(), merged)
    }

    @Test
    fun shiftMovesEveryRange() {
        assertEquals(
            listOf(TextHighlight(11, 13), TextHighlight(15, 16)),
            shiftHighlights(listOf(TextHighlight(0, 2), TextHighlight(4, 5)), 11),
        )
        val unchanged = listOf(TextHighlight(1, 2))
        assertTrue(shiftHighlights(unchanged, 0) === unchanged)
    }

    @Test
    fun highlightedStringKeepsTheTextAndSpansTheMergedRanges() {
        val result = highlightedString(
            text = "Atlas staging URL",
            ranges = listOf(TextHighlight(0, 3), TextHighlight(3, 5), TextHighlight(100, 200)),
            background = Color.Yellow,
            foreground = Color.Black,
        )
        assertEquals("Atlas staging URL", result.text)
        assertEquals(1, result.spanStyles.size)
        assertEquals(0, result.spanStyles.single().start)
        assertEquals(5, result.spanStyles.single().end)
        assertEquals(Color.Yellow, result.spanStyles.single().item.background)
    }

    @Test
    fun highlightedStringWithoutValidRangesHasNoSpans() {
        val result = highlightedString("abc", listOf(TextHighlight(9, 12)), Color.Yellow, Color.Black)
        assertEquals("abc", result.text)
        assertTrue(result.spanStyles.isEmpty())
    }
}
