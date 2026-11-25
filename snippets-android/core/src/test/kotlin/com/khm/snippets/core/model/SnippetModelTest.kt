package com.khm.snippets.core.model

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.text.FoundationFixture
import com.khm.snippets.core.text.SeededRandom
import java.util.Locale
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `SnippetDisplayOrderTests`, `SnippetContentPreviewTests` and the model cases of
 * `ReviewRegressionTests`, followed by the corpus that the app's own `Snippet.swift`
 * produced (`tools/foundation-tables`).
 */
class SnippetModelTest {

    // SnippetDisplayOrderTests.swift

    private fun displayOrderId(value: Int): UUID =
        UUID.fromString("00000000-0000-0000-0000-" + value.toString().padStart(12, '0'))

    private fun displayOrderSnippet(
        id: Int,
        name: String,
        createdAt: Double,
        updatedAt: Double? = null,
        isPinned: Boolean = false,
    ) = Snippet(
        id = displayOrderId(id), name = name, keyword = "k$id", content = "body", isPinned = isPinned,
        createdAt = AppleTime.fromUnixSeconds(createdAt), updatedAt = AppleTime.fromUnixSeconds(updatedAt ?: createdAt),
    )

    @Test
    fun pinnedThenNewestThenID() {
        val oldPinned = displayOrderSnippet(4, "A old pin", 100.0, isPinned = true)
        val tiedPinnedHigherId = displayOrderSnippet(2, "A ignored", 200.0, isPinned = true)
        val tiedPinnedLowerId = displayOrderSnippet(1, "Z ignored", 200.0, isPinned = true)
        val newest = displayOrderSnippet(6, "Newest", 400.0)
        val older = displayOrderSnippet(5, "Older", 300.0)

        val result = SnippetDisplayOrder.sorted(listOf(older, tiedPinnedHigherId, newest, oldPinned, tiedPinnedLowerId))

        assertEquals(listOf(tiedPinnedLowerId.id, tiedPinnedHigherId.id, oldPinned.id, newest.id, older.id), result.map { it.id })
    }

    @Test
    fun inputAndTransportOrderCannotAffectPresentation() {
        val records = listOf(
            displayOrderSnippet(1, "one", 100.0),
            displayOrderSnippet(2, "two", 300.0),
            displayOrderSnippet(3, "three", 200.0, isPinned = true),
            displayOrderSnippet(4, "four", 400.0, isPinned = true),
        )
        val expected = SnippetDisplayOrder.sorted(records).map { it.id }
        val permutations = listOf(
            records, records.reversed(),
            listOf(records[2], records[0], records[3], records[1]),
            listOf(records[1], records[3], records[0], records[2]),
        )
        for (input in permutations) assertEquals(expected, SnippetDisplayOrder.sorted(input).map { it.id })
    }

    @Test
    fun editsDoNotMoveRowsWithinASection() {
        val createdLater = displayOrderSnippet(1, "Created later", 200.0, updatedAt = 201.0)
        val editedMuchLater = displayOrderSnippet(2, "Edited much later", 100.0, updatedAt = 10_000.0)
        assertEquals(
            listOf(createdLater.id, editedMuchLater.id),
            SnippetDisplayOrder.sorted(listOf(editedMuchLater, createdLater)).map { it.id },
        )
    }

    @Test
    fun comparatorIsIrreflexive() {
        val snippet = displayOrderSnippet(1, "same", 100.0)
        assertFalse(SnippetDisplayOrder.ranks(snippet, snippet))
    }

    /** `UUID.compareTo` compares signed longs; Swift compares the uppercase strings. */
    @Test
    fun theIdTieBreakIsTheOrderOfTheUppercaseStrings() {
        val low = UUID.fromString("7FFFFFFF-0000-4000-8000-000000000000")
        val high = UUID.fromString("80000000-0000-4000-8000-000000000000")
        assertTrue(low > high, "java.util.UUID.compareTo is the signed order this must not be")
        assertTrue(SnippetDisplayOrder.compareUuidStrings(low, high) < 0)

        val random = SeededRandom(0x1D0_0DE4L)
        repeat(5_000) {
            // Shared prefixes, so the comparison reaches every byte position.
            val a = random.uuid()
            val bytes = Uuids.toBytes(a)
            bytes[random.int(16)] = random.next().toByte()
            val b = if (random.int(4) == 0) random.uuid() else Uuids.fromBytes(bytes)
            assertEquals(
                Integer.signum(Uuids.uppercase(a).compareTo(Uuids.uppercase(b))),
                Integer.signum(SnippetDisplayOrder.compareUuidStrings(a, b)),
                "$a vs $b",
            )
        }
    }

    @Test
    fun timesCompareAsDoublesAndANotANumberTimeSortsLast() {
        fun snippet(id: Int, createdAt: Double) =
            Snippet(displayOrderId(id), "", "", "", createdAt = createdAt, updatedAt = 0.0)
        // 0.0 and -0.0 tie, so the id decides, in either input order.
        val zeros = listOf(snippet(2, 0.0), snippet(1, -0.0))
        assertEquals(listOf(1, 2).map(::displayOrderId), SnippetDisplayOrder.sorted(zeros).map { it.id })
        assertEquals(listOf(1, 2).map(::displayOrderId), SnippetDisplayOrder.sorted(zeros.reversed()).map { it.id })

        val mixed = listOf(snippet(1, Double.NaN), snippet(2, 5.0), snippet(3, Double.NEGATIVE_INFINITY), snippet(4, Double.NaN))
        assertEquals(listOf(2, 3, 1, 4).map(::displayOrderId), SnippetDisplayOrder.sorted(mixed).map { it.id })
    }

    // SnippetContentPreviewTests.swift

    private fun snippet(content: String) = Snippet(name = "", keyword = "", content = content)

    @Test
    fun skipsBlankLinesAndTrimsTheFirstContentLine() {
        assertEquals("café 👩🏽‍💻", snippet(" \t\r\n\n  café 👩🏽‍💻  \nignored").contentFirstLineUntruncated)
    }

    @Test
    fun recognizesEveryFoundationNewlineScalar() {
        for (separator in listOf("\n", "\r", "\r\n", "\u000B", "\u000C", "\u0085", " ", " ")) {
            val value = snippet(" \t$separator Expected ${separator}ignored")
            assertEquals("Expected", value.contentFirstLineUntruncated)
        }
    }

    @Test
    fun returnsEmptyForEmptyOrWhitespaceOnlyContent() {
        assertEquals("", snippet("").contentFirstLineUntruncated)
        assertEquals("", snippet(" \t\r\n   ").contentFirstLineUntruncated)
        assertEquals("Untitled Snippet", snippet(" \t\r\n").displayName)
    }

    @Test
    fun stopsBeforeLargeTrailingContent() {
        val value = snippet("\n  Preview  \n" + "x".repeat(1_000_000))
        assertEquals("Preview", value.contentFirstLineUntruncated)
    }

    // ReviewRegressionTests.swift

    /** `filterKey` once folded against the process locale; under Turkish `I` then folds to `ı`. */
    @Test
    fun tagFoldingDoesNotDependOnTheProcessLocale() {
        val original = Locale.getDefault()
        try {
            for (locale in listOf(Locale("tr", "TR"), Locale("az"), Locale("lt"), Locale.ROOT, Locale.US)) {
                Locale.setDefault(locale)
                assertEquals(SnippetTagging.filterKey("work"), SnippetTagging.filterKey("WORK"))
                assertEquals(SnippetTagging.filterKey("istanbul"), SnippetTagging.filterKey("İstanbul"))
                assertEquals(SnippetTagging.filterKey("cafe"), SnippetTagging.filterKey("CAFÉ"))
                assertEquals("iı-ii", SnippetTagging.filterKey("Iı-İi"))
                assertEquals("title", SnippetTagging.filterKey("TITLE"))
                assertEquals("abcdef01", com.khm.snippets.core.clock.Hlc.normalizedDevice("ABCDEF01"))
            }
        } finally {
            Locale.setDefault(original)
        }
    }

    // The model itself

    @Test
    fun defaultsMatchTheSwiftInitializer() {
        val before = AppleTime.now()
        val first = Snippet(name = "n", keyword = "k", content = "c")
        val second = Snippet(name = "n", keyword = "k", content = "c")
        val after = AppleTime.now()
        assertNotEquals(first.id, second.id)
        assertEquals(emptyList(), first.tags)
        assertTrue(first.isEnabled)
        assertFalse(first.isPinned)
        assertTrue(first.createdAt in before..after && first.updatedAt in before..after)
    }

    /** Swift's `==` on the struct: canonical equivalence for text, IEEE equality for times. */
    @Test
    fun equalityIsSwifts() {
        val id = UUID.randomUUID()
        val composed = Snippet(id, "Café", "é", "naïve", listOf("Réf"), createdAt = 0.0, updatedAt = 1.0)
        val decomposed = Snippet(id, "Café", "é", "naïve", listOf("Réf"), createdAt = -0.0, updatedAt = 1.0)
        assertEquals(composed, decomposed)
        assertEquals(composed.hashCode(), decomposed.hashCode())

        assertNotEquals(composed, composed.copy(name = "Cafe"))
        assertNotEquals(composed, composed.copy(keyword = "e"))
        assertNotEquals(composed, composed.copy(content = "naive"))
        assertNotEquals(composed, composed.copy(tags = listOf("Ref")))
        assertNotEquals(composed, composed.copy(tags = listOf("Réf", "x")))
        assertNotEquals(composed, composed.copy(isEnabled = false))
        assertNotEquals(composed, composed.copy(isPinned = true))
        assertNotEquals(composed, composed.copy(createdAt = 1.0))
        assertNotEquals(composed, composed.copy(updatedAt = Math.nextUp(1.0)))
        assertNotEquals(composed, composed.copy(id = UUID.randomUUID()))

        val undated = composed.copy(createdAt = Double.NaN)
        assertEquals(undated, undated.copy())
    }

    @Test
    fun aSnippetDoesNotPrintItsText() {
        val snippet = Snippet(name = "secret name", keyword = "secret-keyword", content = "secret body", tags = listOf("secret-tag"))
        assertEquals("Snippet(id=${snippet.id})", snippet.toString())
    }

    @Test
    fun sanitizedKeywordExamples() {
        assertEquals("", Snippet.sanitizedKeyword(""))
        assertEquals("sig", Snippet.sanitizedKeyword("  sig \n"))
        assertEquals("my-key", Snippet.sanitizedKeyword(" \\my key "))
        assertEquals("a", Snippet.sanitizedKeyword("\\ \\ \\a"))
        assertEquals("a\\b", Snippet.sanitizedKeyword("a\\b"))
        assertEquals("Mixed-Case", Snippet.sanitizedKeyword("Mixed\t​Case"))
        // A backslash carrying a combining mark is one Character, which is not "\".
        assertEquals("\\́x", Snippet.sanitizedKeyword("\\́x"))
        assertEquals("x", Snippet(name = "", keyword = " \\x ", content = "").normalizedKeyword)
    }

    @Test
    fun tagExamples() {
        assertEquals(listOf("Work", "two words", "Two Words 2"), SnippetTagging.normalizedTags(listOf("  Work ", "work", "WÖRK", "two   words", "", " ", "Two\nWords", "Two Words 2")))
        // Composed and decomposed spellings are one key, as in a Swift Set<String>.
        assertEquals(listOf("が"), SnippetTagging.normalizedTags(listOf("が", "が")))
        assertEquals("が", SnippetTagging.rawFilterKey("が"))
        assertEquals("が", SnippetTagging.filterKey("が"))

        val snippet = Snippet(name = "", keyword = "", content = "", tags = listOf("Café", "Work"))
        assertTrue(snippet.hasTag(SnippetTagging.filterKey("CAFE")))
        assertTrue(snippet.hasTag(SnippetTagging.filterKey("wörk")))
        assertFalse(snippet.hasTag(SnippetTagging.filterKey("home")))
    }

    // Corpus from the app's own Snippet.swift

    @Test
    fun keywordsTagsDisplayNamesAndOrderMatchTheSwiftModel() {
        val counts = HashMap<String, Int>()
        for (row in FoundationFixture.rows("model-corpus.tsv")) {
            counts.merge(row[0], 1, Int::plus)
            when (row[0]) {
                "keyword" -> assertEquals(
                    row[2], FoundationFixture.scalars(Snippet.sanitizedKeyword(FoundationFixture.text(row[1]))), "keyword ${row[1]}",
                )
                "tags" -> {
                    val normalized = SnippetTagging.normalizedTags(FoundationFixture.texts(row[1]))
                    assertEquals(row[2], normalized.joinToString(";") { FoundationFixture.scalars(it) }, "tags ${row[1]}")
                }
                "display" -> {
                    val snippet = Snippet(name = FoundationFixture.text(row[1]), keyword = "", content = FoundationFixture.text(row[2]))
                    val label = "display name [${row[1]}] content [${row[2]}]"
                    assertEquals(row[3], FoundationFixture.scalars(snippet.displayName), label)
                    assertEquals(row[4], FoundationFixture.scalars(snippet.contentFirstLine), label)
                    assertEquals(row[5], FoundationFixture.scalars(snippet.contentFirstLineUntruncated), label)
                }
                "order" -> {
                    val snippets = row[1].split(';').map { item ->
                        val parts = item.split(',')
                        Snippet(
                            Uuids.parse(parts[0])!!, "", "", "", isPinned = parts[1] == "1",
                            createdAt = Double.fromBits(java.lang.Long.parseUnsignedLong(parts[2], 16)), updatedAt = 0.0,
                        )
                    }
                    val sorted = SnippetDisplayOrder.sorted(snippets).map { Uuids.uppercase(it.id) }
                    assertEquals(row[2], sorted.joinToString(";"), "order ${row[1]}")
                    assertEquals(row[2], SnippetDisplayOrder.sorted(snippets.reversed()).joinToString(";") { Uuids.uppercase(it.id) })
                }
                else -> fail("unknown row kind ${row[0]}")
            }
        }
        assertTrue(counts.getValue("keyword") > 500 && counts.getValue("tags") > 300, counts.toString())
        assertTrue(counts.getValue("display") > 400 && counts.getValue("order") > 100, counts.toString())
    }
}
