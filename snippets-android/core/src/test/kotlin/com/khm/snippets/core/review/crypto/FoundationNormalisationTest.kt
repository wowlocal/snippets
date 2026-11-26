package com.khm.snippets.core.review.crypto

import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * DEFECT D2. `thePassphraseKeyIsTheOneSwiftDerives` fails until the port derives what Swift
 * derives for these passphrases.
 *
 * Swift stretches `Array(passphrase.precomposedStringWithCanonicalMapping.utf8)`
 * (`PassphraseKDF.swift:184`); the port stretches `java.text.Normalizer` NFC
 * (`PassphraseKdf.kt:135-140`). The specification (§1 row 8, hazard H15) takes the two to be
 * the same function. They are not. Measured on macOS 27.2.1 (Swift 6.4) against the JVM's
 * normaliser on 1.88 million strings of Unicode 13 characters, Foundation departs from NFC in
 * four families, and 1 164 of those strings came out different:
 *
 * - a precomposed Hangul LV syllable followed by a conjoining final consonant is left
 *   alone (`AC00 11AB` stays; NFC is `AC04`), while `1100 1161 11AB` does compose;
 * - U+0F73, U+0F75 and U+0F81 after another combining mark are decomposed in place and not
 *   reordered (`0F40 0F39 0F73` gives `0F40 0F39 0F71 0F72`; NFC is `0F40 0F71 0F72 0F39`);
 * - a supplementary-plane base before a combining mark composes as the BMP character with
 *   the same low 16 bits (`10041 030A` gives `00C5`), and before Hangul jamo becomes U+FFFD;
 * - an archaic jamo outside the modern ranges composes into a wrong syllable or U+FFFD
 *   (`1105 1176` gives `B9C8`, `1113 1176` gives `FFFD`).
 *
 * A backup or passphrase wrap made on an Apple device under such a passphrase answers
 * "wrong passphrase" on Android, and the other way round. `foundation-nfc.tsv` holds the
 * recorded Swift keys (2 rounds, fixed salt) and Foundation's normal forms.
 */
class FoundationNormalisationTest {

    private val rows = ReviewCrypto.rows("foundation-nfc.tsv")

    @Test fun thePassphraseKeyIsTheOneSwiftDerives() {
        val keys = rows.filter { it[0] == "kdf" }
        assertTrue(keys.size >= 20)
        val wrong = keys.filter { KotlinJudge.disagreement(it.dropLast(1), it.last()) != null }
            .map { row -> ReviewCrypto.text(row[1]).codePoints().toArray().joinToString(" ") { "%04X".format(it) } }
        if (wrong.isNotEmpty()) {
            fail("${wrong.size} of ${keys.size} passphrases derive another key than Swift's PassphraseKDF.derive:\n  " + wrong.joinToString("\n  "))
        }
    }

    /** The ordinary cases in the same file do agree; this keeps the fixture honest. */
    @Test fun ordinaryPassphrasesInTheSameFixtureDeriveSwiftsKey() {
        val ordinary = rows.filter { it[0] == "kdf" }.take(8)
        for (row in ordinary) {
            val actual = KotlinJudge.disagreement(row.dropLast(1), row.last())
            assertTrue(actual == null, "${ReviewCrypto.text(row[1])}: $actual")
        }
    }
}
