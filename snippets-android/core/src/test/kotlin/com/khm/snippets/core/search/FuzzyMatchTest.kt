package com.khm.snippets.core.search

import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.text.SeededRandom
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** `Tests/Core/FuzzyMatchTests.swift` ("Prepared fuzzy matching"), the L04 vectors and Swift-emitted results. */
class FuzzyMatchTest {

    private class Token(val character: String, val range: FuzzyMatch.MatchRange, val wordStart: Boolean)

    private fun tokens(text: String): List<Token> {
        val result = ArrayList<Token>()
        var offset = 0
        var previous: String? = null
        for (original in FoundationText.characters(text)) {
            val range = FuzzyMatch.MatchRange(offset, original.length)
            FoundationText.characters(FoundationText.fold(original)).forEachIndexed { index, character ->
                val previousIsLetter = previous?.let { Character.isAlphabetic(it.codePointAt(0)) } == true
                result.add(Token(FoundationText.nfc(character), range, index == 0 && !previousIsLetter))
            }
            offset += original.length
            previous = original
        }
        return result
    }

    /**
     * The independent oracle of the Swift test: enumerate alignments, not DP states.
     * Several middle paths can tie completely; any of them is accepted, but every scoring
     * and tie-break tier is required.
     */
    private fun optimal(query: String, target: String): List<FuzzyMatch.Result> {
        val needle = tokens(query).map { it.character }
        val haystack = tokens(target)
        if (needle.isEmpty()) return listOf(FuzzyMatch.Result(0, true, emptyList()))
        var best: IntArray? = null
        val results = ArrayList<FuzzyMatch.Result>()

        fun precedes(first: IntArray, second: IntArray): Boolean {
            for (index in first.indices) if (first[index] != second[index]) return first[index] < second[index]
            return false
        }

        fun visit(path: List<Int>, score: Int, streak: Int) {
            if (path.size == needle.size) {
                val key = intArrayOf(score, -path.last(), -haystack[path[0]].range.start, streak)
                val current = best
                if (current != null) {
                    if (precedes(key, current)) return
                    if (!key.contentEquals(current)) results.clear()
                }
                best = key
                results.add(FuzzyMatch.Result(score, true, path.map { haystack[it].range }))
                return
            }
            val start = (path.lastOrNull() ?: -1) + 1
            for (index in start until haystack.size) {
                if (haystack[index].character != needle[path.size]) continue
                val nextStreak = if (path.isEmpty()) 0 else if (index == path.last() + 1) streak + 1 else 0
                val bonus = 1 + (if (haystack[index].wordStart) 3 else 0) + (if (path.isEmpty() && index == 0) 5 else 0) + nextStreak * 2
                visit(path + index, score + bonus, nextStreak)
            }
        }
        visit(emptyList(), 0, 0)
        return if (results.isEmpty()) listOf(FuzzyMatch.Result.NO_MATCH) else results
    }

    @Test
    fun exhaustiveSmallInputsPreserveScoresAndHighlightTieBreaks() {
        fun strings(maxLength: Int): List<String> {
            val all = arrayListOf("")
            var row = listOf("")
            repeat(maxLength) {
                row = row.flatMap { prefix -> listOf("a", "b", " ").map { prefix + it } }
                all += row
            }
            return all
        }
        val workspace = FuzzyMatch.Workspace()
        for (target in strings(5)) {
            val preparedTarget = FuzzyMatch.PreparedTarget(target)
            for (query in strings(3)) {
                val preparedQuery = FuzzyMatch.PreparedQuery(query)
                val result = FuzzyMatch.score(preparedQuery, preparedTarget, workspace = workspace)
                val expected = optimal(query, target)
                assertTrue(result in expected, "query=$query, target=$target: $result not in $expected")
                assertEquals(result.matched, FuzzyMatch.matches(preparedQuery, preparedTarget))
                assertEquals(result.matched, FuzzyMatch.matches(preparedQuery, target))
                val scoreOnly = FuzzyMatch.score(preparedQuery, preparedTarget, includingRanges = false, workspace = workspace)
                assertTrue(scoreOnly.score == result.score && scoreOnly.matched == result.matched)
                assertTrue(scoreOnly.matchedRanges.isEmpty())
            }
        }
    }

    // The Swift test also runs under tr_TR, az_AZ and lt_LT. Android folds the same for
    // every user, so one pass.
    @Test
    fun unicodeFoldingPreservesUtf16Ranges() {
        val targets = listOf(
            "Café", "Cafe\u0301", "Straße", "ßss ß", "İIıi", "Привет мир",
            "👩🏽\u200D💻 cafe", "🇫🇷 Français", "ﬃ file", "a\r\nb", "\u212Aelvin", "\u0301a",
        )
        val queries = listOf("", "cafe", "é", "ss", "sss", "i", "I", "ı", "прм", "👩🏽\u200D💻", "ffi", "ab", "\r\n", "k")
        val workspace = FuzzyMatch.Workspace()
        for (target in targets) {
            for (query in queries) {
                val result = FuzzyMatch.score(FuzzyMatch.PreparedQuery(query), FuzzyMatch.PreparedTarget(target), workspace = workspace)
                assertTrue(result in optimal(query, target), "query=$query, target=$target: $result")
                assertEquals(result.matched, FuzzyMatch.matches(FuzzyMatch.PreparedQuery(query), FoundationText.fold(target)), "query=$query, target=$target")
            }
        }
    }

    @Test
    fun repeatedCharactersAndWorkspaceReuseKeepTheBestStreak() {
        val workspace = FuzzyMatch.Workspace()
        val cases = listOf(
            "aaab" to "aa aaaaab", "ababa" to "a b ababa", "aaaaaa" to "a".repeat(256), "zz" to "z", "" to "", "ab" to "ba",
        )
        for ((query, target) in cases) {
            val result = FuzzyMatch.score(FuzzyMatch.PreparedQuery(query), FuzzyMatch.PreparedTarget(target), workspace = workspace)
            if (target.length < 20) {
                assertTrue(result in optimal(query, target), "query=$query, target=$target")
            } else {
                assertEquals(44, result.score)
                assertEquals((0 until 6).map { FuzzyMatch.MatchRange(it, 1) }, result.matchedRanges)
            }
        }
    }

    private fun ranges(field: String): List<FuzzyMatch.MatchRange> =
        if (field == "-") emptyList() else field.split(',').map { FuzzyMatch.MatchRange(it.substringBefore(':').toInt(), it.substringAfter(':').toInt()) }

    /** 841 Swift results under en_US: the same algorithm must pick the same path, not merely an optimal one. */
    @Test
    fun swiftResultsForUnicodeTargets() {
        val rows = UtilitiesFixture.rows("swift-fuzzy.tsv")
        assertEquals(841, rows.size)
        for (row in rows) {
            val query = UtilitiesFixture.text(row[0])
            val target = UtilitiesFixture.text(row[1])
            val label = "query=${UtilitiesFixture.scalars(query)} target=${UtilitiesFixture.scalars(target)}"
            val result = FuzzyMatch.score(query, target)
            assertEquals(row[2] == "1", result.matched, label)
            assertEquals(row[3].toInt(), result.score, label)
            assertEquals(ranges(row[4]), result.matchedRanges, label)
            val folded = UtilitiesFixture.text(row[5])
            assertTrue(FoundationText.canonicalEquals(folded, FoundationText.fold(target)), label)
            assertEquals(row[6] == "1", FuzzyMatch.matches(FuzzyMatch.PreparedQuery(query), folded), label)
            assertEquals(result.matched, FuzzyMatch.matches(FuzzyMatch.PreparedQuery(query), FuzzyMatch.PreparedTarget(target)), label)
        }
    }

    /**
     * L04 `fuzzy`. Six of the 66 cases were emitted under tr_TR or az_AZ, where Foundation
     * folds `I` to dotless `ı`. Android folds the same for every user (owner decision), so
     * those six must give what Swift gives for the same input under en_US; three of them
     * have an en_US twin in the file, and all six are checked against the oracle.
     */
    @Test
    fun swiftVectorsL04Fuzzy() {
        val cases = SwiftVectors.cases("L04-search", "fuzzy")
        assertEquals(66, cases.size)
        val english = cases.filter { it.string("locale") == "en_US" }
        assertEquals(60, english.size)
        val byInput = english.associateBy { it.text("query") to it.text("target") }
        var twins = 0
        for (case in cases) {
            val query = case.text("query")
            val target = case.text("target")
            val result = FuzzyMatch.score(query, target)
            val expected = if (case.string("locale") == "en_US") {
                case
            } else {
                assertTrue(result in optimal(query, target), case.label)
                byInput[query to target]?.also { twins += 1 } ?: continue
            }
            assertEquals(expected.boolean("matched"), result.matched, case.label)
            assertEquals(expected.int("score"), result.score, case.label)
            val wanted = expected.array("matchedRangesUTF16").map {
                FuzzyMatch.MatchRange(it.jsonArray[0].jsonPrimitive.int, it.jsonArray[1].jsonPrimitive.int)
            }
            assertEquals(wanted, result.matchedRanges, case.label)
            assertEquals(expected.boolean("subsequenceMatches"), FuzzyMatch.matches(FuzzyMatch.PreparedQuery(query), FuzzyMatch.PreparedTarget(target)), case.label)
            // The emitter abbreviates a long target in `text` ("a×256") and, for that one
            // case, recorded the abbreviation's bytes as the folded target too.
            val abbreviated = expected.obj("target").string("text") != target
            val folded = if (abbreviated) FoundationText.fold(target) else expected.text("foldedTarget")
            assertTrue(FoundationText.canonicalEquals(folded, FoundationText.fold(target)), case.label)
            assertEquals(expected.boolean("matchesFoldedTarget"), FuzzyMatch.matches(FuzzyMatch.PreparedQuery(query), folded), case.label)
        }
        assertEquals(3, twins)
    }

    @Test
    fun preparedQueryExtendsItsPrefixes() {
        assertTrue(FuzzyMatch.PreparedQuery("").isEmpty)
        assertFalse(FuzzyMatch.PreparedQuery(" ").isEmpty)
        assertTrue(FuzzyMatch.PreparedQuery("Café").extends(FuzzyMatch.PreparedQuery("caf")))
        assertTrue(FuzzyMatch.PreparedQuery("cafe").extends(FuzzyMatch.PreparedQuery("CAFÉ")))
        assertTrue(FuzzyMatch.PreparedQuery("x").extends(FuzzyMatch.PreparedQuery("")))
        assertFalse(FuzzyMatch.PreparedQuery("caf").extends(FuzzyMatch.PreparedQuery("cafe")))
        assertFalse(FuzzyMatch.PreparedQuery("cab").extends(FuzzyMatch.PreparedQuery("caf")))
        assertEquals(FuzzyMatch.PreparedQuery("É"), FuzzyMatch.PreparedQuery("e"))
    }

    @Test
    fun highlightRangesMergeRepeatsAndNeighbours() {
        val eszett = FuzzyMatch.score("strasse", "Straße")
        assertEquals(listOf(0, 1, 2, 3, 4, 4, 5).map { FuzzyMatch.MatchRange(it, 1) }, eszett.matchedRanges)
        assertEquals(listOf(FuzzyMatch.MatchRange(0, 6)), eszett.highlightRanges)
        val gaps = FuzzyMatch.score("fb", "FooBar foo_bar fooBar")
        assertEquals(listOf(FuzzyMatch.MatchRange(0, 1), FuzzyMatch.MatchRange(11, 1)), gaps.highlightRanges)
        assertEquals(emptyList(), FuzzyMatch.Result.NO_MATCH.highlightRanges)
    }

    private val alphabet = listOf(
        "a", "b", "A", "B", " ", "-", ".", "é", "e\u0301", "ß", "İ", "ı", "ﬁ", "\r\n", "\n", "\u0301", "日", "本",
        "👩🏽\u200D💻", "👩", "🇫🇷", "🇫", "\u200D", "가", "\u1100", "\u1161", "1", "K", "\u212A", "x\u20DD", "\uD83D", "\uDC69", "\u0000",
    )

    private fun randomText(random: SeededRandom, maxPieces: Int): String {
        val out = StringBuilder()
        repeat(random.int(maxPieces + 1)) { out.append(random.pick(alphabet)) }
        return out.toString()
    }

    /** Whatever the input: ranges lie inside the target, on `Character` boundaries, in order; score and membership agree. */
    @Test
    fun highlightRangesAreAlwaysWithinBoundsAndOnCharacterBoundaries() {
        val random = SeededRandom(0x5EA4C4)
        val workspace = FuzzyMatch.Workspace()
        repeat(20_000) {
            val target = randomText(random, 12)
            val query = randomText(random, 4)
            val preparedQuery = FuzzyMatch.PreparedQuery(query)
            val preparedTarget = FuzzyMatch.PreparedTarget(target)
            val result = FuzzyMatch.score(preparedQuery, preparedTarget, workspace = workspace)
            val label = "query=${UtilitiesFixture.scalars(query)} target=${UtilitiesFixture.scalars(target)}"
            assertEquals(FuzzyMatch.matches(preparedQuery, preparedTarget), result.matched, label)
            // Not compared with matches(query, fold(target)): folding the whole text can drop
            // a combining mark that folding Character by Character keeps (after a line
            // feed, say). The two entry points differ there in Swift as well.
            assertEquals(result, FuzzyMatch.score(preparedQuery, preparedTarget), label)
            val scoreOnly = FuzzyMatch.score(preparedQuery, preparedTarget, includingRanges = false, workspace = workspace)
            assertEquals(result.score, scoreOnly.score, label)
            if (!result.matched) {
                assertEquals(FuzzyMatch.Result.NO_MATCH, result, label)
                return@repeat
            }
            assertEquals(tokens(query).size, result.matchedRanges.size, label)
            val boundaries = HashSet<Int>().apply {
                add(0)
                var index = 0
                while (index < target.length) {
                    index = FoundationText.nextCharacterBoundary(target, index)
                    add(index)
                }
            }
            var previousStart = 0
            for (range in result.matchedRanges) {
                assertTrue(range.length > 0 && range.start >= 0 && range.end <= target.length, label)
                assertTrue(range.start in boundaries && range.end in boundaries, label)
                assertEquals(range.end, FoundationText.nextCharacterBoundary(target, range.start), label)
                assertTrue(range.start >= previousStart, label)
                previousStart = range.start
            }
            var covered = 0
            for (range in result.highlightRanges) {
                assertTrue(range.start >= covered && range.start in boundaries && range.end in boundaries, label)
                covered = range.end
            }
        }
    }

    @Test
    fun randomInputsAgreeWithTheOracle() {
        val random = SeededRandom(0xF022)
        repeat(4_000) {
            val target = randomText(random, 7)
            val query = randomText(random, 3)
            val result = FuzzyMatch.score(query, target)
            assertTrue(result in optimal(query, target), "query=${UtilitiesFixture.scalars(query)} target=${UtilitiesFixture.scalars(target)}: $result")
        }
    }
}
