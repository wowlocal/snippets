package com.khm.snippets.core.review.foundation

import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Review of deviation 1: `FoundationText.compare` against Swift's `<` on strings.
 *
 * Swift's answers below were measured with Swift 6.4 on macOS 27.2.1 (scratch scripts
 * `cmp1.swift` to `cmp4.swift`). These tests pass: they pin what the port does and record
 * what Swift does, because the sync merge (`SyncMerge.mergeTags`, `for tagKey in
 * added.sorted()`) orders filter keys with `<`, and that order is written into a synced
 * tag array.
 *
 * Swift's `<` is not a strict weak order on strings that are not in NFC:
 * - it is not transitive (see [swiftsOrderHasACycle]);
 * - for some unequal pairs neither `a < b` nor `b < a` holds, so `Set<String>.sorted()`
 *   returns them in the set's iteration order, which is seeded per process. Twelve
 *   launches of the same Swift binary printed both orders for the Hindi pair below.
 *
 * So Swift cannot be reproduced bit for bit here, and a comparator that copied it would
 * break `java.util` sorting ("Comparison method violates its general contract").
 * For two NFC strings the two orders are the same.
 *
 * Every string is spelled as scalar values so that no editor can renormalize a case.
 */
class SwiftStringOrderTest {

    private fun text(scalars: String): String = ReviewFixture.text(scalars)

    private fun key(text: String): String = SnippetTagging.filterKey(text)

    /**
     * Class 1, binary prefix. An Arabic word with alef + combining madda (two scalars)
     * against the word that is its first three letters.
     * Swift: `key(qra) < key(quran)` is true and `key(quran) < key(qra)` is false.
     */
    @Test
    fun arabicDecomposedAlefMaddaSortsBeforeItsBarePrefixHereAndAfterItInSwift() {
        val qra = text("0642 0631 0627")
        val quran = text("0642 0631 0627 0653 0646")
        val quranComposed = text("0642 0631 0622 0646")
        assertTrue(quran.startsWith(qra))
        assertEquals(quranComposed, FoundationText.nfc(quran))
        assertEquals("0642 0631 0627 0653 0646", ReviewFixture.scalars(SnippetTagging.rawFilterKey(quran)), "Foundation's fold keeps both scalars")
        assertTrue(FoundationText.compare(key(quran), key(qra)) < 0, "Kotlin orders the NFC forms: U+0622 < U+0627")
        // Typed on a keyboard the word carries U+0622, and then Swift and Kotlin agree.
        assertTrue(FoundationText.compare(key(quranComposed), key(qra)) < 0)
    }

    /**
     * Class 3, NFC prefix. A Hindi word ending in the precomposed U+095B (common in Hindi
     * text, not NFC) against the same word ending in U+091C. Swift: `==` is false and `<`
     * is false both ways; `Set([a, b]).sorted()` came back in either order across launches.
     */
    @Test
    fun hindiPrecomposedNuktaAgainstItsBaseIsOrderedHereAndUnorderedInSwift() {
        val raaz = text("0930 093E 095B")
        val raaj = text("0930 093E 091C")
        assertEquals("0930 093E 095B", ReviewFixture.scalars(SnippetTagging.rawFilterKey(raaz)), "Foundation's fold keeps U+095B")
        assertTrue(FoundationText.compare(key(raaj), key(raaz)) < 0)
        assertTrue(FoundationText.compare(key(raaz), key(raaj)) > 0)
        // The KDoc of SnippetTagging.filterKey says compareScalars "orders them as Swift's < does".
        // It cannot for this pair: Swift has no order for it.
        assertTrue(FoundationText.compareScalars(key(raaj), key(raaz)) < 0)
    }

    /** Swift: `p < q`, `q < r` and `r < p` are all true for p = U+0627, q = U+0627 U+0653, r = U+0623. */
    @Test
    fun swiftsOrderHasACycle() {
        val p = text("0627")
        val q = text("0627 0653")
        val r = text("0623")
        // Kotlin: q < r < p, a chain.
        assertTrue(FoundationText.compare(q, r) < 0)
        assertTrue(FoundationText.compare(r, p) < 0)
        assertTrue(FoundationText.compare(q, p) < 0)
    }

    /** What makes the port's order safe to sort with: it is a total order consistent with `canonicalEquals`. */
    @Test
    fun kotlinsOrderIsATotalOrderOnAHostileSample() {
        val alphabet = intArrayOf(
            0x61, 0x65, 0xE9, 0x300, 0x301, 0x323, 0x315, 0x627, 0x622, 0x623, 0x653, 0x915, 0x958, 0x93C,
            0x1100, 0x1161, 0x11A8, 0xAC00, 0xAC01, 0x2ADC, 0x2ADD, 0x338, 0xF73, 0xF71, 0xF72, 0xF74, 0x1F600, 0xFF21, 0xE000,
        )
        var state = 0x1234_5678_9ABCL
        fun next(bound: Int): Int {
            state = state xor (state shl 13)
            state = state xor (state ushr 7)
            state = state xor (state shl 17)
            return java.lang.Long.remainderUnsigned(state, bound.toLong()).toInt()
        }
        val sample = List(400) {
            val out = StringBuilder()
            repeat(1 + next(4)) { out.appendCodePoint(alphabet[next(alphabet.size)]) }
            out.toString()
        }
        // Sorting must not throw, and must give the same result from any starting order.
        val sorted = sample.sortedWith(FoundationText.order)
        val again = sample.reversed().sortedWith(FoundationText.order)
        assertEquals(sorted.map(FoundationText::nfc), again.map(FoundationText::nfc))
        for (index in 1 until sorted.size) {
            assertTrue(FoundationText.compare(sorted[index - 1], sorted[index]) <= 0)
        }
        for (a in sample.take(60)) for (b in sample.take(60)) {
            assertEquals(FoundationText.canonicalEquals(a, b), FoundationText.compare(a, b) == 0)
            assertEquals(Integer.signum(FoundationText.compare(a, b)), -Integer.signum(FoundationText.compare(b, a)))
        }
    }
}
