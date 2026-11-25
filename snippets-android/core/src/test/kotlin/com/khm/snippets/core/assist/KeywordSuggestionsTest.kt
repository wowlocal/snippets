package com.khm.snippets.core.assist

import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.search.UtilitiesFixture
import com.khm.snippets.core.text.SeededRandom
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The "Keyword suggestions" suite of `Tests/Core/TextReplacementTests.swift`, the cases
 * `snippets-linux/src/editor_assistance_tests.rs` adds, the L06 vectors and Swift-emitted
 * results for a wider corpus.
 */
class KeywordSuggestionsTest {

    @Test
    fun aLongerCandidateAndTheIncumbentBlockEachOtherInBothDirections() {
        assertEquals(KeywordRelation.BLOCKS_SHORTER, KeywordRelation.between("email", "em"), "longer candidate kills the incumbent")
        assertEquals(KeywordRelation.BLOCKED_BY_LONGER, KeywordRelation.between("em", "email"), "shorter candidate is swallowed")
    }

    @Test
    fun anExactMatchIsADuplicate() {
        assertEquals(KeywordRelation.DUPLICATE, KeywordRelation.between("sig", "sig"))
    }

    @Test
    fun appendADigitDisambiguationGetsTheSameCorrection() {
        assertEquals(KeywordRelation.BLOCKS_SHORTER, KeywordRelation.between("sig2", "sig"), "sig2 beside sig kills sig")
    }

    @Test
    fun keywordsWithNothingInCommonAreUnrelated() {
        assertEquals(KeywordRelation.UNRELATED, KeywordRelation.between("sig", "tp"))
    }

    @Test
    fun aLabelAbbreviatesTwoWaysAndThenTheContentFollows() {
        assertEquals(listOf("sign", "sig", "sb", "best"), KeywordSuggestions.candidates("Signature Block", "Best regards"))
    }

    @Test
    fun aShortWordIsOfferedWhole() {
        assertEquals(listOf("email"), KeywordSuggestions.candidates("Email", ""))
    }

    @Test
    fun diacriticsAreFoldedTheWayTheEngineFoldsThem() {
        assertEquals(listOf("cafe", "co"), KeywordSuggestions.candidates("Café Order", ""), "folded, not truncated at the accent")
    }

    @Test
    fun aUrlSchemeIsSteppedOverButItsHostIsOffered() {
        assertEquals(listOf("github"), KeywordSuggestions.candidates("", "https://github.com/mike/snippets"))
    }

    @Test
    fun aContentSentenceYieldsNoInitials() {
        assertEquals(listOf("thanks"), KeywordSuggestions.candidates("", "Thanks so much for the update"))
    }

    @Test
    fun anEmptySnippetOffersNothing() {
        assertEquals(emptyList(), KeywordSuggestions.candidates("", ""))
    }

    @Test
    fun textWithNoTypeableWordOffersNothing() {
        assertEquals(emptyList(), KeywordSuggestions.candidates("日本語", "こんにちは"))
    }

    @Test
    fun oneCharacterIsNotAKeywordButItsInitialsSurvive() {
        assertEquals(emptyList(), KeywordSuggestions.candidates("A", ""))
        assertEquals(listOf("ab"), KeywordSuggestions.candidates("A B", ""))
    }

    @Test
    fun aNameAndContentThatAgreeProduceOnePairNotTwo() {
        assertEquals(listOf("invo", "inv"), KeywordSuggestions.candidates("Invoice", "Invoice for services"))
    }

    @Test
    fun existingKeywordsMatchADotComponentAnywhere() {
        assertEquals(
            listOf("doc.backend", "frontend.doc"),
            KeywordSuggestions.existingMatches("doc", listOf("frontend.doc", "doc.backend", "product")),
        )
    }

    @Test
    fun existingKeywordPartsMatchWhenTypedInTheWrongOrder() {
        assertEquals(
            listOf("doc.frontend"),
            KeywordSuggestions.existingMatches("frontend.doc", listOf("other", "doc.frontend", "doc.backend")),
        )
    }

    @Test
    fun partialReorderedKeywordPartsMatchWhileTyping() {
        assertEquals(
            listOf("doc.frontend"),
            KeywordSuggestions.existingMatches("front.do", listOf("doc.frontend", "doc.backend", "frontend.design")),
        )
    }

    @Test
    fun exactExistingKeywordLeadsAndFoldedDuplicatesCollapse() {
        assertEquals(
            listOf("Café.Doc", "cafe.doc.extra", "other.cafe.doc"),
            KeywordSuggestions.existingMatches("\\CAFÉ.DOC", listOf("cafe.doc.extra", "Café.Doc", "cafe.doc", "other.cafe.doc")),
        )
    }

    @Test
    fun tabCompletionAdvancesOnlyToTheNextKeywordPart() {
        assertEquals("doc.", KeywordSuggestions.tabCompletion("do", listOf("doc.frontend", "doc.backend")))
        assertEquals("doc.frontend.", KeywordSuggestions.tabCompletion("doc.front", listOf("doc.frontend.controls")))
        assertEquals("my-", KeywordSuggestions.tabCompletion("my", listOf("my-signature.work")), "a sanitized space is completed as a hyphen")
    }

    @Test
    fun tabCompletionOnlyAddsThePrefixSharedByEveryOption() {
        assertEquals("doc.fr", KeywordSuggestions.tabCompletion("doc.f", listOf("doc.frontend", "doc.framework")))
        assertNull(KeywordSuggestions.tabCompletion("doc.", listOf("doc.frontend", "doc.backend")), "Tab must not choose a keyword")
    }

    @Test
    fun tabCompletionIsPrefixOnlyAndPreservesTheTypedPrefix() {
        assertNull(KeywordSuggestions.tabCompletion("frontend", listOf("doc.frontend")))
        assertEquals("CAFé.", KeywordSuggestions.tabCompletion("CAF", listOf("café.docs")))
        assertNull(KeywordSuggestions.tabCompletion("doc.frontend", listOf("doc.frontend")), "an exact keyword has no continuation")
    }

    @Test
    fun anEmptyKeywordQueryShowsNoExistingReferences() {
        assertTrue(KeywordSuggestions.existingMatches("  ", listOf("doc.frontend")).isEmpty())
    }

    /** The cases of the Rust port's tests that the Swift suite does not have, with Swift's answers. */
    @Test
    fun linuxCrossChecks() {
        // The Rust port cuts its argument at the first line break and offers nothing here.
        // Swift takes what the caller says is the first line and finds its first word.
        assertEquals(listOf("second"), KeywordSuggestions.candidates("", "\nSecond line is not a name"))
        assertEquals(emptyList(), KeywordSuggestions.existingMatches("doc.doc", listOf("doc.frontend")))
        assertEquals("Straße.", KeywordSuggestions.tabCompletion("Stra", listOf("Straße.work")))
        assertNull(KeywordSuggestions.tabCompletion("STRAS", listOf("Straße.work")))
        assertEquals("CAFe\u0301.", KeywordSuggestions.tabCompletion("CAF", listOf("cafe\u0301.docs")))
        assertNull(KeywordSuggestions.tabCompletion("", listOf("doc")))
        assertEquals(KeywordRelation.BLOCKED_BY_LONGER, KeywordRelation.between(KeywordRelation.folded("em"), KeywordRelation.folded("Email")))
        assertEquals(KeywordRelation.BLOCKS_SHORTER, KeywordRelation.between(KeywordRelation.folded("email"), KeywordRelation.folded("EM")))
        assertEquals(KeywordRelation.DUPLICATE, KeywordRelation.between(KeywordRelation.folded("\\CAFÉ"), KeywordRelation.folded("cafe")))
        // The Rust port calls an empty keyword unrelated to everything. Swift does not: it is a prefix of every keyword.
        assertEquals(KeywordRelation.BLOCKED_BY_LONGER, KeywordRelation.between("", "email"))
    }

    private fun relation(swiftCase: String): KeywordRelation = when (swiftCase) {
        "unrelated" -> KeywordRelation.UNRELATED
        "duplicate" -> KeywordRelation.DUPLICATE
        "blockedByLonger" -> KeywordRelation.BLOCKED_BY_LONGER
        "blocksShorter" -> KeywordRelation.BLOCKS_SHORTER
        else -> throw IllegalStateException(swiftCase)
    }

    @Test
    fun swiftVectorsL06Candidates() {
        val cases = SwiftVectors.cases("L06-keywords-import-links", "candidates")
        assertEquals(28, cases.size)
        for (case in cases) {
            assertEquals(case.strings("candidates"), KeywordSuggestions.candidates(case.text("snippetName"), case.text("contentFirstLine")), case.label)
        }
    }

    @Test
    fun swiftVectorsL06Relations() {
        val cases = SwiftVectors.cases("L06-keywords-import-links", "relation")
        assertEquals(16, cases.size)
        for (case in cases) {
            val keyword = case.text("keyword")
            val other = case.text("other")
            assertEquals(case.string("foldedKeyword"), KeywordRelation.folded(keyword), case.label)
            assertEquals(case.string("foldedOther"), KeywordRelation.folded(other), case.label)
            assertEquals(relation(case.string("relationOfFolded")), KeywordRelation.between(KeywordRelation.folded(keyword), KeywordRelation.folded(other)), case.label)
            assertEquals(relation(case.string("relationOfRaw")), KeywordRelation.between(keyword, other), case.label)
        }
    }

    @Test
    fun swiftVectorsL06ExistingKeywords() {
        val cases = SwiftVectors.cases("L06-keywords-import-links", "existing-keywords")
        assertEquals(24, cases.size)
        for (case in cases) {
            val among = case.strings("among")
            assertEquals(case.strings("existingMatches"), KeywordSuggestions.existingMatches(case.text("query"), among), case.label)
            assertEquals(case.stringOrNull("tabCompletion"), KeywordSuggestions.tabCompletion(case.text("query"), among), case.label)
        }
    }

    /** 30 candidate phrases, 22 libraries x 56 queries, and 18 keyword pairs, as Swift answers them. */
    @Test
    fun swiftResultsForAWiderCorpus() {
        val rows = UtilitiesFixture.rows("swift-keywords.tsv")
        val counts = HashMap<String, Int>()
        for (row in rows) {
            counts[row[0]] = (counts[row[0]] ?: 0) + 1
            when (row[0]) {
                "candidates" -> {
                    val name = UtilitiesFixture.text(row[1])
                    val line = UtilitiesFixture.text(row[2])
                    val wanted = if (row[3] == "-") emptyList() else row[3].split(',')
                    assertEquals(wanted, KeywordSuggestions.candidates(name, line), "candidates ${UtilitiesFixture.scalars(name)} / ${UtilitiesFixture.scalars(line)}")
                }
                "existing" -> {
                    val query = UtilitiesFixture.text(row[1])
                    val among = UtilitiesFixture.texts(row[2])
                    val label = "query=${UtilitiesFixture.scalars(query)} among=${among.map(UtilitiesFixture::scalars)}"
                    assertEquals(
                        UtilitiesFixture.texts(row[3]).map(UtilitiesFixture::scalars),
                        KeywordSuggestions.existingMatches(query, among).map(UtilitiesFixture::scalars), "existing $label",
                    )
                    val completion = KeywordSuggestions.tabCompletion(query, among)
                    assertEquals(
                        if (row[4] == "nil") null else UtilitiesFixture.scalars(UtilitiesFixture.text(row[4])),
                        completion?.let(UtilitiesFixture::scalars), "tab $label",
                    )
                }
                "relation" -> {
                    val keyword = UtilitiesFixture.text(row[1])
                    val other = UtilitiesFixture.text(row[2])
                    val label = "${UtilitiesFixture.scalars(keyword)} / ${UtilitiesFixture.scalars(other)}"
                    assertEquals(relation(row[3]), KeywordRelation.between(KeywordRelation.folded(keyword), KeywordRelation.folded(other)), "folded $label")
                    assertEquals(relation(row[4]), KeywordRelation.between(keyword, other), "raw $label")
                }
                else -> throw IllegalStateException(row[0])
            }
        }
        assertEquals(mapOf("candidates" to 30, "existing" to 22 * 56, "relation" to 18), counts)
    }

    /** Whatever is typed: no exception, candidates are typeable, and a completion extends the typed text. */
    @Test
    fun arbitraryInputNeverThrowsAndResultsKeepTheirShape() {
        val pieces = listOf("a", "B", "doc", ".", "-", " ", "\\", "é", "e\u0301", "ß", "İ", "ı", "\u212A", "👩🏽\u200D💻", "\r\n", "\u0000", "\uD83D", "1", "日", "!", "x\u20DD", "\u0301")
        val random = SeededRandom(0xA5515)
        fun text(max: Int) = buildString { repeat(random.int(max + 1)) { append(random.pick(pieces)) } }
        repeat(5_000) {
            val query = text(5)
            val among = (0 until random.int(6)).map { text(7) }
            for (candidate in KeywordSuggestions.candidates(text(8), text(8))) {
                assertTrue(candidate.length >= 2 && candidate.all { it in 'a'..'z' || it in '0'..'9' }, candidate)
            }
            val matches = KeywordSuggestions.existingMatches(query, among)
            assertEquals(matches.map(KeywordRelation::folded).distinct().size, matches.size)
            assertTrue(matches.all { it.isNotEmpty() })
            val completion = KeywordSuggestions.tabCompletion(query, among) ?: return@repeat
            val typed = com.khm.snippets.core.model.Snippet.sanitizedKeyword(query)
            assertTrue(completion.startsWith(typed) && completion.length > typed.length, UtilitiesFixture.scalars(completion))
            assertTrue(KeywordRelation.between(KeywordRelation.folded(query), KeywordRelation.folded(completion)) != KeywordRelation.UNRELATED)
        }
    }
}
