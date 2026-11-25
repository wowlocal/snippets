package com.khm.snippets.core.review.foundation

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Review: an independent adversarial sample (emoji ZWJ and flag sequences, Indic
 * conjuncts, Hangul jamo, prepend characters, controls, long combining runs across the
 * 64-scalar fold buffer and the 50-character cut), every expected value recorded from
 * Swift itself (`text-differential.tsv.gz`).
 */
class TextSwiftDifferentialTest {

    private val rows = ReviewFixture.rows("text-differential.tsv.gz")
    private val id = UUID(1, 2)

    private fun report(failures: List<String>, total: Int) {
        if (failures.isNotEmpty()) fail("${failures.size} of $total rows differ from Swift:\n" + failures.take(40).joinToString("\n"))
    }

    private fun hasOutlier(text: String): Boolean = text.any { it.code == 0x0F73 || it.code == 0x0F75 || it.code == 0x0F81 }

    @Test
    fun charactersFoldTrimKeywordAndDisplayNameMatchSwift() {
        val failures = ArrayList<String>()
        val all = rows.filter { it[0] == "T" }
        assertTrue(all.size > 7000)
        for (row in all) {
            val s = ReviewFixture.text(row[1])
            fun check(what: String, expected: String, actual: String) {
                if (expected != actual) failures.add("$what [${row[1]}]: swift [$expected] kotlin [$actual]")
            }
            check("count", row[2], FoundationText.characterCount(s).toString())
            val lengths = FoundationText.characters(s).joinToString(",") { it.codePointCount(0, it.length).toString() }
            check("clusters", row[3], lengths.ifEmpty { "-" })
            check("filterKey(raw)", row[4], ReviewFixture.scalars(SnippetTagging.rawFilterKey(s)))
            check("trim", row[5], ReviewFixture.scalars(FoundationText.trimWhitespaceAndNewlines(s)))
            check("sanitizedKeyword", row[6], ReviewFixture.scalars(Snippet.sanitizedKeyword(s)))
            val snippet = Snippet(id, "", s, s, emptyList(), true, false, 0.0, 0.0)
            check("firstLineUntruncated", row[7], ReviewFixture.scalars(snippet.contentFirstLineUntruncated))
            check("firstLine", row[8], ReviewFixture.scalars(snippet.contentFirstLine))
            val named = Snippet(id, s, "", "body", emptyList(), true, false, 0.0, 0.0)
            check("displayName", row[9], ReviewFixture.scalars(named.displayName))
            check("normalizedTags", row[10], ReviewFixture.scalars(SnippetTagging.normalizedTags(listOf(s)).firstOrNull() ?: ""))
            check("normalizedDevice", row[11], ReviewFixture.scalars(Hlc.normalizedDevice(s)))
        }
        report(failures, all.size)
    }

    @Test
    fun equalityOfStringsAndOfFilterKeysMatchesSwift() {
        val failures = ArrayList<String>()
        val all = rows.filter { it[0] == "C" }
        var outliers = 0
        for (row in all) {
            val a = ReviewFixture.text(row[1])
            val b = ReviewFixture.text(row[2])
            if (hasOutlier(a) || hasOutlier(b)) {
                outliers += 1
                continue
            }
            if ((row[3] == "1") != FoundationText.canonicalEquals(a, b)) failures.add("== [${row[1]}] [${row[2]}] swift ${row[3]}")
            val ka = SnippetTagging.filterKey(a)
            val kb = SnippetTagging.filterKey(b)
            if ((row[5] == "1") != (ka == kb)) failures.add("filterKey == [${row[1]}] [${row[2]}] swift ${row[5]}")
        }
        assertTrue(outliers < all.size / 4, "too many rows skipped: $outliers")
        report(failures, all.size)
    }

    /**
     * `FoundationText.compare` is the scalar order of the NFC forms. Swift's `<` is not:
     * every difference must fall into one of three classes.
     *
     * 1. Binary prefix (declared by the author): one string's code units are a prefix of
     *    the other's, Swift answers by length.
     * 2. U+0F73/0F75/0F81 rows (declared): skipped.
     * 3. NFC prefix (found in review, not declared): the NFC forms are in a prefix
     *    relation but the code units are not, e.g. U+2ADC against U+2ADD, or U+0958
     *    against U+0915. Swift answers `a < b == false` and `b < a == false` although
     *    `a != b` (sometimes the reverse order instead). See [SwiftStringOrderTest].
     */
    @Test
    fun orderDiffersFromSwiftOnlyInTheThreeKnownClasses() {
        val failures = ArrayList<String>()
        val all = rows.filter { it[0] == "C" }
        var binaryPrefix = 0
        var nfcPrefix = 0
        fun classify(a: String, b: String, label: String) {
            val na = FoundationText.nfc(a)
            val nb = FoundationText.nfc(b)
            when {
                a.startsWith(b) || b.startsWith(a) -> binaryPrefix += 1
                na.startsWith(nb) || nb.startsWith(na) -> nfcPrefix += 1
                else -> failures.add(label)
            }
        }
        for (row in all) {
            val a = ReviewFixture.text(row[1])
            val b = ReviewFixture.text(row[2])
            if (hasOutlier(a) || hasOutlier(b)) continue
            val order = Integer.signum(FoundationText.compare(a, b))
            if (order != row[4].toInt()) classify(a, b, "< [${row[1]}] [${row[2]}] swift ${row[4]} kotlin $order")
            // Filter keys are compared as Swift gets them back from Foundation.
            val ka = SnippetTagging.rawFilterKey(a)
            val kb = SnippetTagging.rawFilterKey(b)
            val keyOrder = Integer.signum(FoundationText.compare(ka, kb))
            if (keyOrder != row[6].toInt()) classify(ka, kb, "key < [${row[1]}] [${row[2]}] swift ${row[6]} kotlin $keyOrder")
        }
        println("review: order differences from Swift in ${all.size} pairs: binary prefix $binaryPrefix, NFC prefix $nfcPrefix")
        assertTrue(binaryPrefix > 0 && nfcPrefix > 0, "the sample no longer shows both classes: $binaryPrefix, $nfcPrefix")
        report(failures, all.size)
    }

    @Test
    fun normalizedTagListsMatchSwift() {
        val failures = ArrayList<String>()
        val all = rows.filter { it[0] == "N" }
        for (row in all) {
            val tags = row[1].split(';').map(ReviewFixture::text)
            if (tags.any(::hasOutlier)) continue
            val expected = row.getOrElse(2) { "" }
            val actual = SnippetTagging.normalizedTags(tags).joinToString(";") { ReviewFixture.scalars(it) }
            if (expected != actual) failures.add("normalizedTags [${row[1]}]: swift [$expected] kotlin [$actual]")
        }
        report(failures, all.size)
    }

    @Test
    fun hlcMillisAndForeignClocksMatchSwift() {
        val failures = ArrayList<String>()
        val all = rows.filter { it[0] == "D" }
        for (row in all) {
            val value = Double.fromBits(java.lang.Long.parseUnsignedLong(row[1], 16))
            val millis = AppleTime.hlcMillis(value)
            if (java.lang.Long.toUnsignedString(millis) != row[2]) failures.add("hlcMillis(${row[1]} = $value): swift ${row[2]} kotlin $millis")
            val foreign = Hlc.foreign(value).string
            if (foreign != row[3]) failures.add("foreign(${row[1]}): swift ${row[3]} kotlin $foreign")
            assertEquals(Hlc.parse(row[3])?.string, row[3])
        }
        report(failures, all.size)
    }
}
