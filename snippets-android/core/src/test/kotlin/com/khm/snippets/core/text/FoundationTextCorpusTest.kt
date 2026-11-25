package com.khm.snippets.core.text

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Every expected value here was produced by Foundation or the Swift standard library
 * (`tools/foundation-tables`). Nothing is computed twice in Kotlin and compared with itself.
 */
class FoundationTextCorpusTest {

    // Character sets

    @Test
    fun theThreeCharacterSetsHaveExactlyFoundationsMembers() {
        val members = HashMap<String, HashSet<Int>>()
        for (row in FoundationFixture.rows("character-sets.tsv")) {
            val range = row[1].split('-')
            val start = range[0].toInt(16)
            val end = range[range.size - 1].toInt(16)
            for (scalar in start..end) members.getOrPut(row[0]) { HashSet() }.add(scalar)
        }
        assertEquals(setOf("whitespaces", "newlines", "whitespacesAndNewlines"), members.keys)

        for (scalar in 0..0x10FFFF) {
            assertEquals(scalar in members.getValue("whitespaces"), FoundationText.isWhitespace(scalar), "whitespaces U+%04X".format(scalar))
            assertEquals(scalar in members.getValue("newlines"), FoundationText.isNewline(scalar), "newlines U+%04X".format(scalar))
            assertEquals(
                scalar in members.getValue("whitespacesAndNewlines"), FoundationText.isWhitespaceOrNewline(scalar),
                "whitespacesAndNewlines U+%04X".format(scalar),
            )
        }
    }

    /** The scalars where `Char.isWhitespace` and Foundation disagree, named so a refactor to `trim()` fails here. */
    @Test
    fun foundationsWhitespaceIsNotTheJvms() {
        for (scalar in listOf(0x0085, 0x200B)) {
            assertTrue(FoundationText.isWhitespaceOrNewline(scalar))
            assertTrue(!scalar.toChar().isWhitespace(), "U+%04X".format(scalar))
        }
        for (scalar in 0x001C..0x001F) {
            assertTrue(!FoundationText.isWhitespaceOrNewline(scalar))
            assertTrue(scalar.toChar().isWhitespace(), "U+%04X".format(scalar))
        }
        assertEquals("\u001Ca\u001F", FoundationText.trimWhitespaceAndNewlines(" ​\u0085\u001Ca\u001F\u0085​ "))
    }

    @Test
    fun trimmingAndSplittingMatchFoundation() {
        var trims = 0
        var splits = 0
        for (row in FoundationFixture.rows("trim-split-corpus.tsv")) {
            val input = FoundationFixture.text(row[1])
            when (row[0]) {
                "trim" -> {
                    assertEquals(row[2], FoundationFixture.scalars(FoundationText.trimWhitespaceAndNewlines(input)), "trim ${row[1]}")
                    trims += 1
                }
                "trimWhitespaces" ->
                    assertEquals(row[2], FoundationFixture.scalars(FoundationText.trimWhitespace(input)), "trimWhitespaces ${row[1]}")
                "split" -> {
                    val pieces = FoundationText.splitOnWhitespaceAndNewlines(input)
                    assertEquals(row[2], pieces.joinToString(";") { FoundationFixture.scalars(it) }, "split ${row[1]}")
                    splits += 1
                }
                else -> fail("unknown row kind ${row[0]}")
            }
        }
        assertTrue(trims > 500 && splits > 500, "the corpus is unexpectedly small")
    }

    // Folding

    @Test
    fun foldMatchesFoundationOnTheWholeCorpus() {
        val rows = FoundationFixture.rows("fold-corpus.tsv")
        assertTrue(rows.size > 4000, "the corpus is unexpectedly small: ${rows.size}")
        var failures = 0
        val firstFailures = StringBuilder()
        for (row in rows) {
            val actual = FoundationFixture.scalars(FoundationText.fold(FoundationFixture.text(row[0])))
            if (actual != row[1]) {
                failures += 1
                if (failures <= 10) firstFailures.append("\n  [${row[0]}] expected [${row[1]}] got [$actual]")
            }
        }
        assertEquals(0, failures, "fold differs from Foundation for $failures of ${rows.size} strings:$firstFailures")
    }

    /** The cases the porting brief singles out, spelled out so the rule is readable here. */
    @Test
    fun foldExamples() {
        fun fold(text: String) = FoundationText.fold(text)
        assertEquals("work", fold("WORK"))
        assertEquals("cafe", fold("CAFÉ"))
        assertEquals("cafe", fold("Café"))
        assertEquals("strasse", fold("Straße"))
        assertEquals("ss", fold("ẞ"))
        assertEquals("fi", fold("ﬁ"))
        assertEquals("istanbul", fold("İstanbul"))
        assertEquals("ı", fold("ı"))
        assertEquals("σ", fold("Σ"))
        assertEquals("σ", fold("ς"))
        assertEquals("и", fold("Й"))
        assertEquals("е", fold("ё"))
        // No width folding, and stroke letters do not decompose.
        assertEquals("ａ", fold("Ａ"))
        assertEquals("ø", fold("Ø"))
        // Marks are dropped after Latin, kept after scripts above U+0510 ...
        assertEquals("a", fold("á́"))
        assertEquals("אָ", fold("אָ"))
        // ... except a first mark at or below U+050F after an unchanged leader.
        assertEquals("א", fold("א́"))
        assertEquals("א֑́", fold("א֑́"))
        // A leader that itself changes keeps every mark, and kept marks are sorted by class.
        assertEquals("ⴀ́", fold("Ⴀ́"))
        assertEquals("ⴀְ֑", fold("Ⴀְ֑"))
        // Precomposed letters outside Latin, Greek and Cyrillic are left alone.
        assertEquals("が", fold("が"))
        assertEquals("が", fold("が"))
        // A mark with nothing before it is kept; U+0000 never takes marks.
        assertEquals("́", fold("́"))
        assertEquals("\u0000́", fold("\u0000́"))
        assertEquals("", fold(""))
    }

    @Test
    fun foldLeavesAnUnpairedSurrogateInPlace() {
        // Swift cannot hold one; the port must at least not throw or lose its neighbours.
        assertEquals("a\uD83Db", FoundationText.fold("A\uD83DB"))
        assertEquals("\uDE00e", FoundationText.fold("\uDE00É"))
    }

    // Characters

    @Test
    fun graphemeClustersMatchSwiftOnTheWholeCorpus() {
        val rows = FoundationFixture.rows("grapheme-corpus.tsv")
        assertTrue(rows.size > 3000, "the corpus is unexpectedly small: ${rows.size}")
        var failures = 0
        val firstFailures = StringBuilder()
        for (row in rows) {
            val text = FoundationFixture.text(row[0])
            val expected = row[1].split(' ').map { it.toInt() }
            val characters = FoundationText.characters(text)
            val actual = characters.map { it.codePointCount(0, it.length) }
            if (actual != expected) {
                failures += 1
                if (failures <= 10) firstFailures.append("\n  [${row[0]}] expected $expected got $actual")
                continue
            }
            // The other entry points must agree with the same segmentation.
            assertEquals(expected.size, FoundationText.characterCount(text), row[0])
            assertEquals(text, characters.joinToString(""), row[0])
            for (count in 0..minOf(expected.size + 1, 4)) {
                assertEquals(characters.take(count).joinToString(""), FoundationText.characterPrefix(text, count), "prefix $count of ${row[0]}")
            }
        }
        assertEquals(0, failures, "segmentation differs from Swift for $failures of ${rows.size} strings:$firstFailures")
    }

    @Test
    fun graphemeExamples() {
        assertEquals(1, FoundationText.characterCount("👨‍👩‍👧‍👦"))
        assertEquals(1, FoundationText.characterCount("👩🏽‍💻"))
        assertEquals(2, FoundationText.characterCount("🇩🇪🇫🇷"))
        assertEquals(1, FoundationText.characterCount("é"))
        assertEquals(1, FoundationText.characterCount("\r\n"))
        assertEquals(2, FoundationText.characterCount("\n\r"))
        assertEquals(1, FoundationText.characterCount("क्ष"))
        assertEquals(1, FoundationText.characterCount("각"))
        assertEquals(0, FoundationText.characterCount(""))
        assertEquals("", FoundationText.characterPrefix("abc", 0))
        assertEquals("abc", FoundationText.characterPrefix("abc", 10))
        assertEquals("éx", FoundationText.characterPrefix("éxy", 2))
        assertEquals(listOf("a", "\uD83D", "b"), FoundationText.characters("a\uD83Db"))
    }

    // Equality and order

    @Test
    fun equalityAndOrderMatchSwiftOnTheWholeCorpus() {
        val rows = FoundationFixture.rows("string-comparison-corpus.tsv")
        assertTrue(rows.size > 3000, "the corpus is unexpectedly small: ${rows.size}")
        var outlierRows = 0
        var outlierDifferences = 0
        var prefixShortcuts = 0
        for (row in rows) {
            val first = FoundationFixture.text(row[0])
            val second = FoundationFixture.text(row[1])
            val label = "[${row[0]}] vs [${row[1]}]"
            val equal = FoundationText.canonicalEquals(first, second)
            val order = Integer.signum(FoundationText.compare(first, second))
            // Internal consistency holds for every row, whatever Swift answered.
            assertEquals(equal, FoundationText.canonicalEquals(second, first), "== reversed $label")
            assertEquals(-order, Integer.signum(FoundationText.compare(second, first)), "order reversed $label")
            assertEquals(order, Integer.signum(FoundationText.order.compare(first, second)), "comparator $label")
            assertEquals(equal, order == 0, "== and order disagree $label")

            if (row[5] == "1") {
                // U+0F73, U+0F75 or U+0F81 is present: see appleNormalizationOutliers below.
                outlierRows += 1
                if (equal != (row[2] == "1") || order != row[3].toInt()) outlierDifferences += 1
                continue
            }
            assertEquals(row[2] == "1", equal, "== $label")
            assertEquals(row[4].toInt(), order, "order of the NFC forms $label")
            if (row[3] != row[4]) {
                // Swift's shortcut for a binary prefix: see swiftOrdersABinaryPrefixByLength below.
                assertTrue(first.startsWith(second) || second.startsWith(first), "Swift and NFC order differ without a prefix: $label")
                prefixShortcuts += 1
            }
        }
        assertTrue(outlierRows in 1..rows.size / 10, "outlier rows: $outlierRows")
        assertTrue(outlierDifferences in 1 until outlierRows, "outlier differences: $outlierDifferences of $outlierRows")
        assertTrue(prefixShortcuts in 1..rows.size / 20, "prefix shortcuts: $prefixShortcuts")
    }

    /**
     * Swift documents `<` on strings as the order of their canonical forms, and that is
     * what [FoundationText.compare] is. Swift's own implementation takes one shortcut
     * that departs from it: when the UTF-8 of one native string is a prefix of the
     * other's, the shorter one is smaller, without normalizing. A mark at the start of
     * the remainder can sort in front of the last mark of the prefix, and then the
     * canonical order is the other way round. (A bridged `NSString` skips the shortcut,
     * so Swift is not consistent with itself here.)
     */
    @Test
    fun swiftOrdersABinaryPrefixByLength() {
        // Swift: "R\u{1DC8}" < "R\u{1DC8}\u{33C}". NFC puts U+033C (class 220) before U+1DC8 (class 230).
        assertEquals("R\u033C\u1DC8", FoundationText.nfc("R\u1DC8\u033C"))
        assertTrue(FoundationText.compare("R\u1DC8", "R\u1DC8\u033C") > 0)
        // Where nothing reorders, a prefix is smaller in both.
        assertTrue(FoundationText.compare("R\u1DC8", "R\u1DC8\u0301") < 0)
        assertTrue(FoundationText.compare("a", "ab") < 0)
    }

    /**
     * The one known difference from Swift. U+0F73, U+0F75 and U+0F81 have combining class
     * 0 but decompose into marks of class 129 and 130. Unicode's canonical ordering moves
     * an earlier mark of a higher class behind those; Apple's normalizers (the Swift
     * standard library's and Foundation's) leave it in front. `java.text.Normalizer`
     * conforms, so for a string with one of these three deprecated Tibetan vowel signs
     * after another mark, Kotlin and Swift can disagree about `==` and `<`. Swift's answers
     * are in the comments; the assertions are what this port does.
     */
    @Test
    fun appleNormalizationOutliers() {
        // Swift: "\u{952}\u{F73}" != "\u{F71}\u{F72}\u{952}".
        assertTrue(FoundationText.canonicalEquals("\u0952\u0F73", "\u0F71\u0F72\u0952"))
        // Swift: "\u{F72}\u{F73}" != "\u{F71}\u{F72}\u{F72}".
        assertTrue(FoundationText.canonicalEquals("\u0F72\u0F73", "\u0F71\u0F72\u0F72"))
        // Without an earlier mark of a higher class the two agree.
        assertTrue(FoundationText.canonicalEquals("a\u0301\u0F73", "\u00E1\u0F71\u0F72"))
        assertTrue(FoundationText.canonicalEquals("\u0F73\u0301", "\u0F71\u0F72\u0301"))
        assertTrue(FoundationText.canonicalEquals("\u0F71\u0F73", "\u0F71\u0F71\u0F72"))
    }

    @Test
    fun orderIsByScalarNotByUtf16Unit() {
        // U+FF21 is one UTF-16 unit above the surrogates; U+1F600 is two surrogates below it.
        assertTrue("Ａ" > "😀", "String.compareTo is the UTF-16 order this must not be")
        assertTrue(FoundationText.compare("Ａ", "😀") < 0)
        assertTrue(FoundationText.compareScalars("Ａ", "😀") < 0)
        assertTrue(FoundationText.compareScalars("😀", "😁") < 0)
        assertTrue(FoundationText.compare("Z", "a") < 0)
        assertTrue(FoundationText.compare("a", "ab") < 0)
        assertEquals(0, FoundationText.compare("é", "é"))
        assertTrue(FoundationText.compareScalars("é", "é") != 0)
        assertEquals("é", FoundationText.nfc("é"))
    }
}
