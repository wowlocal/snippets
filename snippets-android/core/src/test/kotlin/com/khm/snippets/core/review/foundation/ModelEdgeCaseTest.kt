package com.khm.snippets.core.review.foundation

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetDisplayOrder
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/** Review: model behaviour at the edges that the Swift vectors cannot reach, and deviations 2, 4 and 5. */
class ModelEdgeCaseTest {

    private fun text(scalars: String): String = ReviewFixture.text(scalars)

    private fun units(vararg codes: Int): String = String(CharArray(codes.size) { codes[it].toChar() })

    /**
     * Deviation 4, fails by design. Swift gives every record that lacks `createdAt` its own
     * `Date()`; measured on 500 such records: 500 distinct values, strictly increasing in
     * file order, so `SnippetDisplayOrder` shows the file reversed, the same on every run.
     * `AppleTime.now()` has millisecond resolution, so here a whole file shares one or two
     * values and the id decides: the list comes out shuffled, and that order is then synced.
     */
    @Test
    fun recordsWithoutDatesKeepTheirFileOrderAsInSwift() {
        val json = StringBuilder("[")
        val names = (0 until 500).map { "n$it" }
        for ((index, name) in names.withIndex()) {
            if (index > 0) json.append(',')
            json.append("{\"id\":\"").append(UUID.randomUUID()).append("\",\"name\":\"").append(name)
                .append("\",\"keyword\":\"\",\"content\":\"c\"}")
        }
        json.append(']')
        val snippets = SnippetLibraryCodec.decode(json.toString().toByteArray())
        val distinct = snippets.map { it.createdAt.toRawBits() }.toSet().size
        val shown = SnippetDisplayOrder.sorted(snippets).map { it.name }
        if (shown != names.reversed()) {
            fail("500 records share $distinct createdAt value(s); Swift shows them in reverse file order, Kotlin starts with ${shown.take(5)}")
        }
    }

    /** Deviation 5: with a not-a-number time the order stays total and sorting never throws. */
    @Test
    fun displayOrderIsTotalWithEveryKindOfDouble() {
        val times = doubleArrayOf(Double.NaN, 0.0, -0.0, 1.0, -1.0, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, 7.0e8, 7.0e8 + 1e-7, Double.MIN_VALUE)
        var state = 0x0BAD_5EEDL
        fun next(bound: Int): Int {
            state = state xor (state shl 13)
            state = state xor (state ushr 7)
            state = state xor (state shl 17)
            return java.lang.Long.remainderUnsigned(state, bound.toLong()).toInt()
        }
        val snippets = List(600) {
            Snippet(UUID(state, it.toLong()), "", "", "", emptyList(), true, next(4) == 0, times[next(times.size)], 0.0)
        }
        val sorted = SnippetDisplayOrder.sorted(snippets)
        assertEquals(sorted.map { it.id }, SnippetDisplayOrder.sorted(snippets.reversed()).map { it.id })
        for (a in snippets.take(80)) for (b in snippets.take(80)) {
            val ab = SnippetDisplayOrder.comparator.compare(a, b)
            assertEquals(Integer.signum(ab), -Integer.signum(SnippetDisplayOrder.comparator.compare(b, a)))
            if (!a.createdAt.isNaN() && !b.createdAt.isNaN() && a.id != b.id) {
                // Swift's rule, where Swift has one.
                val swift = if (a.isPinned != b.isPinned) a.isPinned else if (a.createdAt != b.createdAt) a.createdAt > b.createdAt
                else a.id.toString().uppercase() < b.id.toString().uppercase()
                assertEquals(swift, SnippetDisplayOrder.ranks(a, b))
            }
        }
    }

    /** Deviation 2: canonical equality, id-only hash, and both hold together in hashed collections. */
    @Test
    fun snippetEqualityIsCanonicalAndConsistentWithItsHash() {
        val id = UUID(7, 9)
        val composed = Snippet(id, text("0043 0061 0066 00E9"), "k", text("00E9"), listOf(text("00E9")), true, false, 0.0, -0.0)
        val decomposed = Snippet(id, text("0043 0061 0066 0065 0301"), "k", text("0065 0301"), listOf(text("0065 0301")), true, false, -0.0, 0.0)
        assertEquals(composed, decomposed)
        assertEquals(composed.hashCode(), decomposed.hashCode())
        assertEquals(1, hashSetOf(composed, decomposed).size)
        assertTrue(composed != composed.copy(content = "e"))
        val nan = composed.copy(createdAt = Double.NaN)
        assertEquals(nan, nan.copy())
        assertTrue(composed.hasTag(SnippetTagging.filterKey(text("0045 0301"))))
    }

    /**
     * A Kotlin string can hold an unpaired surrogate; a Swift string cannot. Nothing in the
     * layer may throw on one, and the text functions must leave it where it is.
     */
    @Test
    fun unpairedSurrogatesNeverThrow() {
        val high = 0xD83D
        val low = 0xDE00
        val samples = listOf(
            units(high), units(low), units(0x61, high), units(high, 0x61), units(low, high), units(0x5C, high),
            units(0x20, high, 0x20), units(high, 0x301), units(0x61, 0x301, low), units(high, 0x200D, low), units(0x0D, high, 0x0A),
            units(high, high, low), units(0x1100, high, 0x1161),
        )
        for (sample in samples) {
            val pieces = FoundationText.characters(sample)
            assertEquals(sample, pieces.joinToString(""))
            assertEquals(pieces.size, FoundationText.characterCount(sample))
            assertEquals(sample, FoundationText.characterPrefix(sample, 1000))
            FoundationText.fold(sample)
            SnippetTagging.filterKey(sample)
            SnippetTagging.normalizedTags(listOf(sample, sample))
            Snippet.sanitizedKeyword(sample)
            Hlc.normalizedDevice(sample)
            assertTrue(FoundationText.canonicalEquals(sample, sample))
            assertEquals(0, FoundationText.compare(sample, sample))
            val snippet = Snippet(UUID(1, 1), sample, sample, sample, listOf(sample), true, false, 0.0, 0.0)
            snippet.displayName
            snippet.contentFirstLine
            // Written as U+FFFD, so what is read back is a different string: the caller must
            // not put such text into a snippet and expect a save to be a fixed point.
            val reread = SnippetLibraryCodec.decode(SnippetLibraryCodec.encode(listOf(snippet))).single()
            assertTrue(Utf8.encodeStrict(reread.name) != null, "what is read back is well-formed")
            assertEquals(String(Utf8.encode(sample), Charsets.UTF_8), reread.content)
        }
        // A lone surrogate is a cluster of its own, also between scalars that would otherwise join.
        assertEquals(3, FoundationText.characterCount(units(0x1100, high, 0x1161)))
        assertEquals(1, FoundationText.characterCount(units(0x1100, 0x1161)))
    }

    /**
     * `java.text.Normalizer` follows the runtime's Unicode version (JDK 17: 13.0; Android
     * API 28: 10.0; API 36: 16.0), Swift's follows the OS (macOS 27: 16.0). For scalars
     * assigned in between, `canonicalEquals` and Swift's `==` disagree. This records the
     * probes; it asserts only what must hold on every runtime.
     */
    @Test
    fun normalizationOfRecentScalarsDependsOnTheRuntime() {
        // a + U+0301 + mark against a + mark + U+0301. Swift 6.4 on macOS 27: equal for all of these.
        val marks = intArrayOf(0x8D3, 0x1ABF, 0x1DFA, 0x899, 0x10EFD, 0xC3C, 0xEBA)
        // Precomposed scalar against its parts. Swift: equal for all of these.
        val composed = listOf("11938" to "11935 11930", "16D68" to "16D67 16D67", "113C5" to "113C2 113C2", "16121" to "1611E 1611E", "105C9" to "105D2 0307")
        var disagreements = 0
        for (mark in marks) {
            val first = StringBuilder("a").appendCodePoint(0x301).appendCodePoint(mark).toString()
            val second = StringBuilder("a").appendCodePoint(mark).appendCodePoint(0x301).toString()
            if (!FoundationText.canonicalEquals(first, second)) disagreements += 1
            assertEquals(FoundationText.canonicalEquals(first, second), FoundationText.compare(first, second) == 0)
        }
        for ((whole, parts) in composed) {
            if (!FoundationText.canonicalEquals(text(whole), text(parts))) disagreements += 1
        }
        println("review: on Java ${System.getProperty("java.version")} canonicalEquals disagrees with Swift on $disagreements of ${marks.size + composed.size} probes with scalars assigned after Unicode 10")
        // Unicode 10 and earlier never changes.
        assertTrue(FoundationText.canonicalEquals(text("0061 0301 0323"), text("1EA1 0301")))
        assertTrue(FoundationText.canonicalEquals(text("0627 0653"), text("0622")))
        assertTrue(FoundationText.canonicalEquals(text("1100 1161 11A8"), text("AC01")))
    }

    /**
     * Coverage gap for the layers above: the foundation has no equivalent of Swift's
     * `lowercased()`, which `GitPlainText` uses for slugs (file names in a synced
     * repository) and front-matter keys. `String.lowercase(Locale.ROOT)` is not it: the JVM
     * applies the final-sigma rule and Swift does not (Swift 6.4: `lowercased()` of
     * U+0391 U+03A3 is U+03B1 U+03C3), and case pairs newer than the runtime's Unicode
     * version are missing (Swift maps U+1C89 to U+1C8A, Unicode 16).
     */
    @Test
    fun theJvmsLowercaseIsNotSwiftsLowercased() {
        val swift = text("03B1 03C3")
        val jvm = text("0391 03A3").lowercase(java.util.Locale.ROOT)
        assertEquals("03B1 03C2", ReviewFixture.scalars(jvm), "the JVM writes a final sigma")
        assertTrue(jvm != swift)
        // Hex device ids and provider keys, the only uses inside this layer, are unaffected.
        assertEquals("0000abcd", Hlc.normalizedDevice("ABCD"))
    }
}
