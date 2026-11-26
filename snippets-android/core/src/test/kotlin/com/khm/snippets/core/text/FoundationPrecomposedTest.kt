package com.khm.snippets.core.text

import java.security.MessageDigest
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `FoundationText.foundationPrecomposed` against Foundation's
 * `precomposedStringWithCanonicalMapping`, recorded by `tools/foundation-tables`.
 *
 * `precomposed-corpus.tsv` lists a readable sample; `precomposed-digests.tsv` holds a
 * SHA-256 per block of 65 536 results for every string the generator compared its rule with
 * Foundation on (39 million). The families below are `forEachPrecomposedCase` in
 * `tools/foundation-tables/Sources/PrecomposedTables.swift`, string for string.
 */
class FoundationPrecomposedTest {

    private fun precomposed(scalars: IntArray): IntArray {
        val out = FoundationText.foundationPrecomposed(toChars(scalars))
        return out.toScalars()
    }

    @Test fun theReadableCorpusMatchesFoundation() {
        val rows = FoundationFixture.rows("precomposed-corpus.tsv")
        assertTrue(rows.size > 50_000, "only ${rows.size} rows")
        val wrong = ArrayList<String>()
        for (row in rows) {
            val actual = FoundationText.foundationPrecomposed(FoundationFixture.text(row[1]))
            if (actual != FoundationFixture.text(row[2])) {
                wrong += "${row[0]}: ${row[1]} is ${row[2]} in Foundation, ${FoundationFixture.scalars(actual)} here"
            }
        }
        if (wrong.isNotEmpty()) fail("${wrong.size} of ${rows.size} rows differ:\n" + wrong.take(20).joinToString("\n"))
    }

    @Test fun everyDigestedFamilyMatchesFoundation() {
        val rows = FoundationFixture.rows("precomposed-digests.tsv")
        val pool = rows.first { it[0] == "pool" }[1].split(' ').map { it.toInt(16) }.toIntArray()
        val expected = LinkedHashMap<String, MutableList<String>>()
        var total = 0L
        for (row in rows) {
            if (row[0] != "digest") continue
            expected.getOrPut(row[1]) { ArrayList() }.add(row[4])
            total += row[3].toLong()
        }
        assertTrue(total > 39_000_000, "only $total strings recorded")

        val families = families(pool)
        assertEquals(expected.keys.toList(), families.map { it.first }, "the families are not the generator's")

        val executor = Executors.newFixedThreadPool(maxOf(2, Runtime.getRuntime().availableProcessors()))
        try {
            val results = families.map { (name, walk) -> executor.submit(Callable { name to digests(walk) }) }
            val wrong = ArrayList<String>()
            for (future in results) {
                val (name, actual) = future.get()
                val recorded = expected.getValue(name)
                if (actual.size != recorded.size) wrong += "$name: ${actual.size} blocks, Foundation ${recorded.size}"
                for (block in recorded.indices) {
                    if (actual.getOrNull(block) != recorded[block]) wrong += "$name: block $block differs"
                }
            }
            if (wrong.isNotEmpty()) fail("${wrong.size} blocks differ from Foundation:\n" + wrong.take(30).joinToString("\n"))
        } finally {
            executor.shutdownNow()
        }
    }

    /** The reviewer's four families, spelled out. */
    @Test fun whereFoundationIsNotNfc() {
        fun check(input: String, expected: String) =
            assertEquals(expected, FoundationFixture.scalars(FoundationText.foundationPrecomposed(FoundationFixture.text(input))), input)
        check("AC00 11AB", "AC00 11AB")                 // NFC: AC04
        check("1100 1161 11AB", "AC04")
        check("0F40 0F39 0F73", "0F40 0F39 0F71 0F72")  // NFC: 0F40 0F71 0F72 0F39
        check("10041 030A", "00C5")                     // NFC: unchanged
        check("1105 1176", "B9C8")                      // NFC: unchanged
        check("1113 1176", "FFFD")                      // a lone surrogate, read back as U+FFFD
        check("0065 0301", "00E9")
        check("212B", "00C5")
    }

    @Test fun anUnpairedSurrogateIsFirstReadAsAReplacementCharacter() {
        assertEquals("�aé", FoundationText.foundationPrecomposed("\uD800aé"))
        assertEquals("é�", FoundationText.foundationPrecomposed("é\uDC00"))
    }

    @Test fun theArrayFormLeavesItsInputAloneAndReturnsANewArray() {
        val input = "é".toCharArray()
        val out = FoundationText.foundationPrecomposed(input)
        assertEquals("é", String(input))
        assertEquals("é", String(out))
    }

    // The generator's families

    private fun digests(walk: ((IntArray) -> Unit) -> Unit): List<String> {
        val out = ArrayList<String>()
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(4 * 256)
        var inBlock = 0
        walk { input ->
            val result = precomposed(input)
            var length = 0
            fun put(value: Int) {
                buffer[length] = (value ushr 24).toByte()
                buffer[length + 1] = (value ushr 16).toByte()
                buffer[length + 2] = (value ushr 8).toByte()
                buffer[length + 3] = value.toByte()
                length += 4
                if (length == buffer.size) {
                    digest.update(buffer, 0, length)
                    length = 0
                }
            }
            for (value in result) put(value)
            put(-1)
            digest.update(buffer, 0, length)
            inBlock += 1
            if (inBlock == BLOCK) {
                out += hex(digest.digest())
                inBlock = 0
            }
        }
        if (inBlock > 0) out += hex(digest.digest())
        return out
    }

    private fun families(pool: IntArray): List<Pair<String, ((IntArray) -> Unit) -> Unit>> {
        val families = ArrayList<Pair<String, ((IntArray) -> Unit) -> Unit>>()
        fun add(name: String, walk: ((IntArray) -> Unit) -> Unit) { families += name to walk }

        add("single") { visit -> for (s in ALL) visit(intArrayOf(s)) }
        add("after 0061") { visit -> for (s in ALL) visit(intArrayOf(0x61, s)) }
        add("before 0301") { visit -> for (s in ALL) visit(intArrayOf(s, 0x0301)) }
        for (leader in LEADERS) add("after ${hex(leader)}") { visit -> for (s in ALL) visit(intArrayOf(leader, s)) }
        for (follower in FOLLOWERS) add("before ${hex(follower)}") { visit -> for (s in ALL) visit(intArrayOf(s, follower)) }
        add("before 0F39 0F73") { visit -> for (s in ALL) visit(intArrayOf(s, 0x0F39, 0x0F73)) }
        add("before 0301 0327") { visit -> for (s in ALL) visit(intArrayOf(s, 0x0301, 0x0327)) }
        add("between 0061 0301") { visit -> for (s in ALL) visit(intArrayOf(0x61, s, 0x0301)) }
        add("jamo pairs") { visit -> for (l in 0x1100..0x11FF) for (v in 0x1100..0x11FF) visit(intArrayOf(l, v)) }
        add("jamo triples") { visit ->
            for (l in 0x1100..0x1114) for (v in 0x1160..0x1177) for (t in 0x11A6..0x11C4) visit(intArrayOf(l, v, t))
        }
        add("syllable and trail") { visit -> for (s in 0xAC00..0xD7A4) for (t in 0x11A6..0x11C4) visit(intArrayOf(s, t)) }
        add("random") { visit ->
            val random = SeededRandom(12345)
            repeat(3_000_000) {
                val length = 1 + random.int(8)
                val input = IntArray(length)
                for (index in 0 until length) {
                    input[index] = if (random.int(10) == 0) ALL[random.int(ALL.size)] else pool[random.int(pool.size)]
                }
                visit(input)
            }
        }
        add("long runs") { visit ->
            for (length in 55..75) {
                for (mark in intArrayOf(0x0344, 0x0340, 0x0341, 0x0343, 0x0301)) {
                    for (leader in intArrayOf(0x61, 0x00E9, 0x05D0, 0x1E09)) {
                        for (filler in intArrayOf(0x0334, 0x0301, 0x0345, 0x05B0)) {
                            for (position in intArrayOf(length - 1, length - 3, length / 2)) {
                                val input = IntArray(length + 1) { if (it == 0) leader else filler }
                                input[position] = mark
                                visit(input)
                                visit(input + intArrayOf(0x0344, 0x0301))
                                visit(input + intArrayOf(0x61))
                            }
                        }
                    }
                }
            }
        }
        add("random long") { visit ->
            val random = SeededRandom(67890)
            repeat(20_000) {
                val length = 40 + random.int(40)
                val input = IntArray(length + 1)
                input[0] = pool[random.int(pool.size)]
                for (index in 1..length) input[index] = pool[random.int(pool.size)]
                visit(input)
            }
        }
        return families
    }

    private companion object {
        const val BLOCK = 65_536

        val LEADERS = intArrayOf(0x00E7, 0x0F40, 0xAC00, 0xAC01, 0x1100, 0x1113, 0x10041, 0x11100, 0x0DD9, 0x0B47, 0x1D157, 0x05D0, 0x1E0C)
        val FOLLOWERS = intArrayOf(0x0327, 0x0F39, 0x0F73, 0x11AB, 0x1161, 0x1176, 0x11A7, 0x11C3, 0x0DCF, 0x0334, 0x0345, 0x0344, 0x3099)

        /** Every scalar value, in order, as the generator's `allScalars`. */
        val ALL: IntArray = (0..0x10FFFF).filter { it !in 0xD800..0xDFFF }.toIntArray()

        fun hex(value: Int): String = value.toString(16).uppercase().padStart(4, '0')

        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

        fun toChars(scalars: IntArray): CharArray {
            val builder = StringBuilder(scalars.size * 2)
            for (value in scalars) builder.appendCodePoint(value)
            return CharArray(builder.length) { builder[it] }
        }

        fun CharArray.toScalars(): IntArray {
            val out = IntArray(size)
            var count = 0
            var index = 0
            while (index < size) {
                val value = Character.codePointAt(this, index)
                out[count++] = value
                index += Character.charCount(value)
            }
            return out.copyOf(count)
        }
    }
}
