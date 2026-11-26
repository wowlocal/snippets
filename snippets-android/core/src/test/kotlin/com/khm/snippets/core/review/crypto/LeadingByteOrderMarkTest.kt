package com.khm.snippets.core.review.crypto

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.wire.SyncEnvelope
import java.io.File
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * DEFECT D1. These tests fail until the port treats a leading U+FEFF as Swift does.
 *
 * Foundation's `String(data:encoding: .utf8)` drops one leading U+FEFF (measured: Swift 6.4,
 * macOS 27.2; `EF BB BF 41` gives `"A"`, `EF BB BF EF BB BF 41` gives `"\u{FEFF}A"`). Swift
 * reaches that initialiser in three places the port mirrors with a plain UTF-8 decode:
 *
 * - object keys in `CanonicalJSON.value` (`SyncEnvelope.swift:312`) against `CanonicalJson.kt:267`;
 * - `CanonicalJSON.Value.text` (`SyncEnvelope.swift:535`) against `JsonValue.textOrNull` (`JsonValue.kt:142`);
 * - `SnippetCrypto.plaintextString` (`SnippetCrypto.swift`, "Plumbing") against `SnippetCrypto.kt:252`.
 *
 * The consequence is on the wire: an envelope whose name, keyword or tag starts with
 * U+FEFF hashes over the BOM when it is written, and Swift's reader, having dropped the
 * BOM, computes another hash and refuses the record (`hashMismatch`). The port accepts it.
 */
class LeadingByteOrderMarkTest {

    private fun recorded(fixture: String): List<List<String>> =
        ReviewCrypto.rows(fixture).filter { KnownDefects.isLeadingBom(it.dropLast(1)) }

    private fun assertAgreesWithSwift(rows: List<List<String>>, minimum: Int) {
        assertTrue(rows.size >= minimum, "only ${rows.size} recorded lines")
        val wrong = rows.mapNotNull { row ->
            KotlinJudge.disagreement(row.dropLast(1), row.last())?.let { "${ReviewCrypto.text(row[1])}\n    Swift:  ${row.last().take(160)}\n    Kotlin: ${it.take(160)}" }
        }
        if (wrong.isNotEmpty()) fail("${wrong.size} of ${rows.size} recorded lines differ from Swift:\n" + wrong.take(6).joinToString("\n"))
    }

    /** 47 documents recorded from Swift, e.g. `{"﻿a":1}` re-emits as `{"a":1}` and `{"﻿a":1,"a":2}` is a duplicate key. */
    @Test fun objectKeysThatStartWithABomParseAndEmitAsInSwift() = assertAgreesWithSwift(recorded("canonical.tsv.gz"), 40)

    /** `Utf8.decodeStrict` and `SnippetCrypto.plaintextString` on bytes that start with `EF BB BF`. */
    @Test fun decodingBytesThatStartWithABomGivesTheTextSwiftGives() = assertAgreesWithSwift(recorded("codecs.tsv.gz"), 10)

    @Test fun aKeyWithALeadingBomIsTheKeyWithoutIt() {
        val parsed = CanonicalJson.parse("{\"﻿a\":1}".toByteArray(Charsets.UTF_8))
        assertEquals("{\"a\":1}", CanonicalJson.encodeToString(parsed), "Swift re-emits 7b2261223a317d")
    }

    @Test fun aKeyThatDiffersFromAnotherOnlyByALeadingBomIsADuplicate() {
        try {
            val parsed = CanonicalJson.parse("{\"﻿a\":1,\"a\":2}".toByteArray(Charsets.UTF_8))
            fail("Swift refuses this document with duplicateKey(\"a\"); the port read ${KotlinJudge.dump(parsed)}")
        } catch (_: CanonicalJson.Failure.DuplicateKey) {
            // as Swift
        }
    }

    @Test fun textOfAStringWithALeadingBomIsTheTextWithoutIt() {
        val value = JsonValue.Utf8(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte(), 'R'.code.toByte()))
        assertEquals("R", value.textOrNull, "Swift's Value.text is String(data:encoding:), which drops the BOM")
        // The bytes themselves are untouched on both sides: this is what keeps a body intact.
        assertEquals(4, value.utf8OrNull!!.size)
    }

    @Test fun plaintextWithALeadingBomBecomesTheStringSwiftShows() {
        val body = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte(), 'p'.code.toByte(), 'i'.code.toByte(), 'n'.code.toByte())
        assertEquals("pin", SnippetCrypto.plaintextString(body))
        assertEquals("pin", Utf8.decodeStrict(body))
    }

    /**
     * The wire consequence, end to end. `swift-interop check envelope` was run on an
     * envelope whose name starts with U+FEFF and answered `SyncEnvelope.Failure.hashMismatch`
     * (`bom-envelope.txt`, lines 1-2). A record every Apple device refuses must not be one the
     * port writes or accepts.
     */
    @Test fun anEnvelopeWhoseNameStartsWithABomIsJudgedAsSwiftJudgesIt() {
        val fixture = ReviewCrypto.lines("bom-envelope.txt")
        assertTrue(fixture[1].contains("\"ok\":false") && fixture[1].contains("hashMismatch"), "Swift's recorded verdict: ${fixture[1]}")
        assertEquals("HashMismatch", portVerdict(ReviewCrypto.unhex(fixture[0])), "Swift refuses this envelope (${fixture[1]}); the port must agree")

        // Decision D1(b): the port no longer writes those bytes. The normalising `Fields`
        // constructor drops the BOM, and Swift accepts what it writes instead (lines 3-4).
        val envelope = envelopeWithBomName()
        assertEquals("Router", envelope.fields!!.name)
        val bytes = envelope.canonicalBytes()
        ReviewCrypto.exchangeDirectory?.let { File(it, "bom-envelope-written.json").writeBytes(bytes) }
        assertContentEquals(ReviewCrypto.unhex(fixture[2]), bytes, "the recorded Swift verdict is for other bytes; record it again")
        assertTrue(fixture[3].contains("\"ok\":true"), "Swift's recorded verdict on what the port writes: ${fixture[3]}")
        assertEquals("accepted", portVerdict(bytes))
    }

    private fun portVerdict(bytes: ByteArray): String = try {
        SyncEnvelope.parse(bytes)
        "accepted"
    } catch (failure: SyncEnvelope.Failure) {
        failure.javaClass.simpleName
    }

    private fun envelopeWithBomName(): SyncEnvelope = SyncEnvelope(
        id = UUID.fromString("00000000-0000-4000-8000-000000000005"),
        hlc = Hlc.parse("019face339f4-0003-a1b2c3d4")!!,
        origin = "a1b2c3d4",
        secure = false,
        deleted = false,
        fields = SyncEnvelope.Fields(
            name = "﻿Router", keyword = "rtr", content = "public fixture body".toByteArray(Charsets.UTF_8), tags = emptyList(),
            isEnabled = true, isPinned = false, createdAt = 1.0, updatedAt = 2.0,
        ),
    )
}
