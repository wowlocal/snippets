package com.khm.snippets.core.review.foundation

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.text.FoundationText
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Review: `HLC(parsing:)` on 1,500 spellings, most of them damaged (uppercase, fullwidth
 * and Arabic-Indic digits, combining marks, NUL, inserted and missing characters), with
 * Swift's verdict for each (`P` rows of `text-differential.tsv.gz`).
 */
class HlcParseSwiftDifferentialTest {

    @Test
    fun parsingAcceptsExactlyWhatSwiftAccepts() {
        val rows = ReviewFixture.rows("text-differential.tsv.gz").filter { it[0] == "P" }
        assertTrue(rows.size >= 1500, "missing P rows: ${rows.size}")
        val failures = ArrayList<String>()
        var accepted = 0
        for (row in rows) {
            val raw = ReviewFixture.text(row[1])
            val parsed = Hlc.parse(raw)
            val actual = if (parsed == null) "nil" else "${java.lang.Long.toUnsignedString(parsed.wallMs)} ${parsed.counter} ${parsed.device} ${parsed.string}"
            if (actual != row[2]) failures.add("parse [${row[1]}]: swift ${row[2]} kotlin $actual")
            if (parsed != null) {
                accepted += 1
                if (parsed.string != raw) failures.add("a parsed clock must print as it was written: [${row[1]}]")
            }
            // `String(raw.suffix(8))` in Swift is the last eight Characters.
            val characters = FoundationText.characters(raw)
            val suffix = characters.takeLast(8).joinToString("")
            if (Hlc.isCanonicalDeviceId(suffix) != (row[3] == "1")) failures.add("isCanonicalDeviceId [${ReviewFixture.scalars(suffix)}]: swift ${row[3]}")
        }
        assertTrue(accepted > 300, "too few accepted spellings: $accepted")
        if (failures.isNotEmpty()) fail("${failures.size} of ${rows.size} differ from Swift:\n" + failures.take(40).joinToString("\n"))
    }
}
