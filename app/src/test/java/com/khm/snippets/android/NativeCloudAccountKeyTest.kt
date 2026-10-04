package com.khm.snippets.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Server ADR 0006 account-key vectors and client normalization rules. */
class NativeCloudAccountKeyTest {
    private data class Vector(val body: String, val canonical: String, val display: String)

    private val vectors = listOf(
        Vector("00000000000000000000000000", "00000000000000000000000000HF",
            "0000-0000-0000-0000-0000-0000-00HF"),
        Vector("ZZZZZZZZZZZZZZZZZZZZZZZZZZ", "ZZZZZZZZZZZZZZZZZZZZZZZZZZ8R",
            "ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZ8R"),
        Vector("7KQF9M2XR4TDH8WBZN3CP6YE1A", "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7",
            "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7"),
        Vector("0123456789ABCDEFGHJKMNPQRS", "0123456789ABCDEFGHJKMNPQRS45",
            "0123-4567-89AB-CDEF-GHJK-MNPQ-RS45"),
    )

    @Test fun adrVectorsProduceCheckCanonicalAndDisplayForms() {
        for (vector in vectors) {
            assertEquals(vector.canonical, vector.body + NativeCloudAccountKey.check(vector.body))
            assertEquals(vector.canonical, NativeCloudAccountKey.normalize(vector.canonical))
            assertTrue(NativeCloudAccountKey.isCanonical(vector.canonical))
            assertEquals(vector.display, NativeCloudAccountKey.displayForm(vector.canonical))
            assertEquals(vector.canonical, NativeCloudAccountKey.normalize(vector.display))
        }
    }

    @Test fun adrNormalizationExamples() {
        val expected = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"
        assertEquals(expected, NativeCloudAccountKey.normalize(" 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-1aq7 "))
        assertEquals(expected, NativeCloudAccountKey.normalize("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-IAQ7"))
        assertNull(NativeCloudAccountKey.normalize("7KQF9M2XR4TDH8WBZN3CP6YE1AQ8"))
        assertNull(NativeCloudAccountKey.normalize("7KQF9M2XR4TDH8WBZN3CP6YE1AU7"))
        assertNull(NativeCloudAccountKey.normalize("U".repeat(28)))
    }

    @Test fun lookAlikesSeparatorsAndAsciiWhitespaceNormalize() {
        // O -> 0 and l/L/i/I -> 1 in any case.
        assertEquals("00000000000000000000000000HF",
            NativeCloudAccountKey.normalize("oOoO-0000\t0000\r\n0000-0000-0000-00hf"))
        assertEquals("7KQF9M2XR4TDH8WBZN3CP6YE1AQ7",
            NativeCloudAccountKey.normalize("7KQF9M2XR4TDH8WBZN3CP6YElAQ7"))
        assertEquals("7KQF9M2XR4TDH8WBZN3CP6YE1AQ7",
            NativeCloudAccountKey.normalize("7KQF9M2XR4TDH8WBZN3CP6YEiAQ7\u000B\u000C"))
    }

    @Test fun rejectsLengthAlphabetAndNonAsciiInput() {
        val canonical = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"
        assertNull(NativeCloudAccountKey.normalize(""))
        assertNull(NativeCloudAccountKey.normalize(canonical.dropLast(1)))
        assertNull(NativeCloudAccountKey.normalize(canonical + "0"))
        assertNull(NativeCloudAccountKey.normalize(canonical + "_"))
        assertNull(NativeCloudAccountKey.normalize(canonical.replaceFirst('7', '!')))
        // Non-ASCII look-alikes are not folded: Turkish dotless i, fullwidth digits, NBSP.
        assertNull(NativeCloudAccountKey.normalize(canonical.replace('1', 'ı')))
        assertNull(NativeCloudAccountKey.normalize(canonical.replaceFirst('7', '７')))
        assertNull(NativeCloudAccountKey.normalize(" " + canonical))
    }

    @Test fun rejectsInputLongerThanSixtyFourUtf8Bytes() {
        val display = "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7"
        val atLimit = display + " ".repeat(64 - display.length)
        assertEquals(64, atLimit.toByteArray(Charsets.UTF_8).size)
        assertEquals("7KQF9M2XR4TDH8WBZN3CP6YE1AQ7", NativeCloudAccountKey.normalize(atLimit))
        assertNull(NativeCloudAccountKey.normalize("$atLimit "))
        assertNull(NativeCloudAccountKey.normalize(" ".repeat(1_000) + display))
    }

    @Test fun onlyTheExactWireFormIsCanonical() {
        assertTrue(NativeCloudAccountKey.isCanonical("7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"))
        assertFalse(NativeCloudAccountKey.isCanonical("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7"))
        assertFalse(NativeCloudAccountKey.isCanonical("7kqf9m2xr4tdh8wbzn3cp6ye1aq7"))
        assertFalse(NativeCloudAccountKey.isCanonical(" 7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"))
    }

    @Test fun singleSymbolTyposAreAlmostAlwaysRejectedLocally() {
        // The ten-bit check is a typo detector, not a guarantee: one substituted body
        // symbol in the ADR vector must almost never reach the network.
        val canonical = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"
        var accepted = 0
        for (index in 0 until NativeCloudAccountKey.BODY_LENGTH) {
            for (symbol in NativeCloudAccountKey.ALPHABET) {
                if (symbol == canonical[index]) continue
                val typo = canonical.substring(0, index) + symbol + canonical.substring(index + 1)
                if (NativeCloudAccountKey.normalize(typo) != null) accepted += 1
            }
        }
        // 26 * 31 substitutions; a ten-bit check lets through roughly one in 1,024.
        assertTrue("too many undetected typos: $accepted", accepted <= 6)
    }
}
