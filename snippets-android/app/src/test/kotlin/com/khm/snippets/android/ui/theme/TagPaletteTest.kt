package com.khm.snippets.android.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TagPaletteTest {
    @Test
    fun hashOfTheEmptyStringIsTheOffsetBasis() {
        assertEquals(0xcbf29ce484222325UL.toLong(), fnv1a64(""))
    }

    @Test
    fun hashMatchesTheFnv1a64ReferenceVectors() {
        assertEquals(0xaf63dc4c8601ec8cUL.toLong(), fnv1a64("a"))
        assertEquals(0x85944171f73967e8UL.toLong(), fnv1a64("foobar"))
    }

    @Test
    fun slotsMatchTheAppleClients() {
        // The same folded tag selects the same slot on every platform.
        assertEquals(7, tagColorIndex("email"))
        assertEquals(8, tagColorIndex("work"))
        assertEquals(4, tagColorIndex("support"))
    }

    @Test
    fun slotIsStableAndInRangeForAnyText() {
        listOf("", "a", "conflict", "über", "日本語", "x".repeat(500)).forEach { tag ->
            val index = tagColorIndex(tag)
            assertTrue(index in 0 until TagPalette.SLOT_COUNT)
            assertEquals(index, tagColorIndex(tag))
        }
    }

    @Test
    fun hashUsesUtf8Bytes() {
        // "é" is two bytes in UTF-8; a per-char hash would give another slot sequence.
        assertNotEquals(fnv1a64("e"), fnv1a64("é"))
        assertEquals(fnv1a64("é"), fnv1a64(String(byteArrayOf(0xC3.toByte(), 0xA9.toByte()), Charsets.UTF_8)))
    }

    @Test
    fun palettesHaveTwelveSlotsAndSelectByIndex() {
        assertEquals(12, SnippetsLightTagPalette.slots.size)
        assertEquals(12, SnippetsDarkTagPalette.slots.size)
        assertEquals(SnippetsLightTagPalette.slots[8], SnippetsLightTagPalette.colorFor("work"))
        assertEquals(SnippetsDarkTagPalette.slots[7], SnippetsDarkTagPalette.colorFor("email"))
    }

    @Test
    fun fontScaleCapStopsGrowingAtTheMaximum() {
        assertEquals(1f, fontScaleCapFactor(1f, 1.3f), 0f)
        assertEquals(1f, fontScaleCapFactor(1.3f, 1.3f), 0f)
        assertEquals(0.65f, fontScaleCapFactor(2f, 1.3f), 0.0001f)
        assertEquals(1f, fontScaleCapFactor(0f, 1.3f), 0f)
        // 22 sp at scale 2.0 is drawn like 22 sp at scale 1.3.
        assertEquals(22f * 1.3f, 22f * fontScaleCapFactor(2f, 1.3f) * 2f, 0.001f)
    }
}
