package com.khm.snippets.android.data.core

import com.khm.snippets.android.data.TextRange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ContentMatchTest {
    @Test
    fun asciiMatchIsCaseInsensitive() {
        assertEquals(TextRange(6, 11), ContentMatch("world").find("Hello WORLD!"))
    }

    @Test
    fun noMatchAndEmptyInputsGiveNull() {
        assertNull(ContentMatch("xyz").find("Hello"))
        assertNull(ContentMatch("").find("Hello"))
        assertNull(ContentMatch("a").find(""))
    }

    @Test
    fun aMatchMayNotSplitCarriageReturnLineFeed() {
        assertNull(ContentMatch("\nb").find("a\r\nb"))
        assertEquals(TextRange(3, 4), ContentMatch("b").find("a\r\nb"))
    }

    @Test
    fun aCombiningMarkBelongsToItsCharacter() {
        assertEquals(TextRange(0, 2), ContentMatch("e").find("éx"))
    }

    @Test
    fun foldedLengthsMapBackToWholeCharacters() {
        assertEquals(TextRange(4, 10), ContentMatch("strasse").find("Die Straße ist"))
        assertEquals(TextRange(0, 2), ContentMatch("sse").find("ße"))
        // A match may not start in the middle of a folded `ß`.
        assertNull(ContentMatch("se").find("ße"))
    }
}
