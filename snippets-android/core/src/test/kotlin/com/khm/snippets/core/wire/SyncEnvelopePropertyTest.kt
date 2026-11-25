package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.wire.WireFixtures.at
import com.khm.snippets.core.wire.WireFixtures.canonicalBytesRefreshingHash
import com.khm.snippets.core.wire.WireFixtures.canonicalObject
import com.khm.snippets.core.wire.WireFixtures.clock
import com.khm.snippets.core.wire.WireFixtures.id
import com.khm.snippets.core.wire.WireFixtures.snippet
import com.khm.snippets.core.wire.WireFixtures.utf8
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Properties of the envelope over generated input: envelope → canonical bytes → parse is
 * the identity and the bytes are a fixed point, for random snippets with awkward Unicode,
 * extreme doubles, empty and huge bodies and unknown `x` members. Seeded, so a failure
 * reproduces.
 */
class SyncEnvelopePropertyTest {

    private val thisDevice = WireFixtures.THIS_DEVICE

    // Generators

    private val awkwardPieces = listOf(
        "", "a", "Z", " ", "  ", "\t", "\n", "\r\n", "\"", "\\", "/", "\\n", "\\u0041", "\u0000", "\u0001", "\u001F",
        "\u007F", "\u0085", " ", "​", " ", " ", "é", "é", "ﬁ", "ß", "İ", "ı", "Å", "Å",
        "日本語", "한글", "עברית", "العربية", "﻿", "�", "￿", "𐀀", "􏿿", "😀", "👩🏽‍💻",
        "🇫🇷", "à́̂", "{", "}", "[", "]", ":", ",", "null", "true", "1e5", "-0.0", "</script>", "%00",
    )

    private fun text(random: WireRandom, maxPieces: Int = 6): String {
        val out = StringBuilder()
        repeat(random.int(maxPieces + 1)) {
            if (random.int(4) == 0) {
                // Any scalar value, surrogates excluded.
                var scalar = random.int(0x110000)
                if (scalar in 0xD800..0xDFFF) scalar = 0x1F600
                out.appendCodePoint(scalar)
            } else {
                out.append(random.pick(awkwardPieces))
            }
        }
        return out.toString()
    }

    private val notableDoubles = listOf(
        0.0, -0.0, 1.0, -1.0, 0.5, 0.1, 1e-7, 1e-5, 0.0001, 1e15, 1e16, 9007199254740992.0, 9007199254740994.0,
        5e-324, Double.MIN_VALUE, java.lang.Double.MIN_NORMAL, Double.MAX_VALUE, -Double.MAX_VALUE,
        807_004_800.0, 807_004_800.5, 812_578_800.123456, -978_307_200.0, -31_622_400.25, 123456789012345680.0,
    )

    private fun double(random: WireRandom): Double {
        if (random.int(3) == 0) return random.pick(notableDoubles)
        while (true) {
            val candidate = Double.fromBits(random.next())
            if (candidate.isFinite()) return candidate
        }
    }

    private fun body(random: WireRandom): String = when (random.int(8)) {
        0 -> ""
        1 -> text(random, 1)
        2 -> "x".repeat(255 + random.int(3))
        3 -> text(random, 400)
        else -> text(random, 12)
    }

    private fun jsonValue(random: WireRandom, depth: Int): JsonValue = when (random.int(if (depth >= 4) 6 else 8)) {
        0 -> JsonValue.Null
        1 -> JsonValue.of(random.bool())
        2 -> JsonValue.of(random.pick(listOf(0L, 1L, -1L, 42L, Long.MAX_VALUE, Long.MIN_VALUE, random.next())))
        3 -> JsonValue.of(double(random))
        4 -> JsonValue.of(text(random))
        5 -> JsonValue.Utf8(utf8(text(random)))
        6 -> JsonValue.Array(List(random.int(4)) { jsonValue(random, depth + 1) })
        else -> JsonValue.Object(bag(random, depth + 1, maxMembers = 4))
    }

    /** Keys that are distinct to Swift too: no two of them canonically equivalent. */
    private fun bag(random: WireRandom, depth: Int, maxMembers: Int): Map<String, JsonValue> {
        val members = LinkedHashMap<String, JsonValue>()
        val seen = HashSet<String>()
        repeat(random.int(maxMembers + 1)) {
            val key = if (random.int(3) == 0) "future.${random.int(1000)}" else text(random, 3)
            if (key != SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY && seen.add(FoundationText.nfc(key))) {
                members[key] = jsonValue(random, depth)
            }
        }
        return members
    }

    private fun hlc(random: WireRandom): Hlc = Hlc.of(
        wallMs = random.pick(listOf(0L, 1L, Hlc.MAX_WALL_MS, random.next() and Hlc.MAX_WALL_MS)),
        counter = random.pick(listOf(0, 1, Hlc.MAX_COUNTER, random.int(Hlc.MAX_COUNTER + 1))),
        device = "%08x".format(random.next() and 0xFFFF_FFFFL),
    )

    private fun envelope(random: WireRandom): SyncEnvelope {
        val origin = "%08x".format(random.next() and 0xFFFF_FFFFL)
        val x = bag(random, depth = 0, maxMembers = 5)
        return when (random.int(6)) {
            0 -> SyncEnvelope.tombstone(random.uuid(), secure = random.bool(), hlc = hlc(random), origin = origin, x = x)
            1 -> SyncEnvelope.secureRecord(
                id = random.uuid(), name = text(random), keyword = text(random, 2), plaintext = utf8(body(random)),
                tags = List(random.int(5)) { text(random, 3) }, isEnabled = random.bool(), isPinned = random.bool(),
                createdAt = double(random), updatedAt = double(random), hlc = hlc(random), origin = origin, x = x,
            )
            else -> SyncEnvelope.plain(
                Snippet(
                    id = random.uuid(), name = text(random), keyword = text(random, 2), content = body(random),
                    tags = List(random.int(5)) { text(random, 3) }, isEnabled = random.bool(), isPinned = random.bool(),
                    createdAt = double(random), updatedAt = double(random),
                ),
                hlc = hlc(random), origin = origin, x = x,
            )
        }
    }

    // Properties

    @Test fun anEnvelopeSurvivesItsCanonicalBytesAndTheBytesAreAFixedPoint() {
        val random = WireRandom(0x5EED_0011)
        var tombstones = 0
        var secure = 0
        repeat(600) { round ->
            val envelope = envelope(random)
            val encoded = envelope.canonicalBytes()
            val label = "round $round"

            val parsed = SyncEnvelope.parse(encoded)
            assertEquals(envelope, parsed, label)
            assertContentEquals(encoded, parsed.canonicalBytes(), label)
            assertEquals(envelope.envelopeHash(), parsed.envelopeHash(), label)
            assertEquals(envelope.hashCode(), parsed.hashCode(), label)

            // The hash is the SHA-256 of the nine-key form, and the ten-key form adds only `hash`.
            val members = CanonicalJson.parse(encoded).objectOrNull!!
            assertEquals(SyncEnvelope.TOP_LEVEL_KEYS, members.keys, label)
            assertEquals(envelope.envelopeHash(), members.getValue("hash").textOrNull, label)
            assertEquals(
                envelope.envelopeHash(),
                SyncEnvelope.sha256Hex(CanonicalJson.encode(JsonValue.Object(members - "hash"))), label,
            )
            assertEquals(JsonValue.Object(members), envelope.canonicalValue(), label)

            // Spelling for spelling, bit for bit.
            assertEquals(envelope.x, parsed.x, label)
            val fields = envelope.fields
            if (fields == null) {
                assertTrue(envelope.deleted, label)
                assertNull(parsed.fields, label)
                assertNull(parsed.contentHash, label)
                tombstones += 1
            } else {
                val reread = assertNotNull(parsed.fields, label)
                assertEquals(fields.name, reread.name, label)
                assertEquals(fields.keyword, reread.keyword, label)
                assertEquals(fields.tags, reread.tags, label)
                assertContentEquals(fields.content, reread.content, label)
                assertEquals(fields.createdAt.toRawBits(), reread.createdAt.toRawBits(), label)
                assertEquals(fields.updatedAt.toRawBits(), reread.updatedAt.toRawBits(), label)
                assertEquals(SyncEnvelope.sha256Hex(fields.content), parsed.contentHash, label)
                // Local construction normalised the tags; normalising again changes nothing.
                assertEquals(fields.tags, SnippetTagging.normalizedTags(fields.tags), label)
                if (envelope.secure) secure += 1
            }
            assertTrue(Hlc.isCanonicalDeviceId(envelope.origin), label)
        }
        assertTrue(tombstones > 50 && secure > 50, "the generator covers every kind: $tombstones, $secure")
    }

    @Test fun anEnvelopeSurvivesTheWireUnderBothSealers() {
        val random = WireRandom(0x5EED_0012)
        val shipping = productionSealer()
        val passthrough = PassthroughSealer()
        repeat(120) { round ->
            val envelope = envelope(random)
            for (sealer in listOf(shipping, passthrough, TestSealer())) {
                val record = WireCodec.seal(envelope, sealer)
                assertEquals(envelope.id, record.id)
                assertEquals(envelope.deleted, record.deleted)
                assertEquals(envelope.envelopeHash().take(32), record.rev)
                assertEquals(envelope, WireCodec.open(record, sealer), "round $round")
                assertContentEquals(envelope.canonicalBytes(), WireCodec.open(record, sealer).canonicalBytes())
            }
        }
    }

    @Test fun aPlainSnippetSurvivesTheEnvelopeWhateverItsText() {
        val random = WireRandom(0x5EED_0013)
        repeat(300) { round ->
            val original = Snippet(
                id = random.uuid(), name = text(random), keyword = text(random, 2), content = body(random),
                // Already normalised, as the store keeps them.
                tags = SnippetTagging.normalizedTags(List(random.int(5)) { text(random, 3) }),
                isEnabled = random.bool(), isPinned = random.bool(),
                createdAt = double(random), updatedAt = double(random),
            )
            val envelope = SyncEnvelope.plain(original, hlc = hlc(random), origin = thisDevice)
            val restored = assertNotNull(SyncEnvelope.parse(envelope.canonicalBytes()).plainSnippet, "round $round")

            assertEquals(original, restored, "round $round")
            assertEquals(original.name, restored.name)
            assertEquals(original.keyword, restored.keyword)
            assertEquals(original.content, restored.content)
            assertEquals(original.tags, restored.tags)
            assertEquals(original.createdAt.toRawBits(), restored.createdAt.toRawBits())
            assertEquals(original.updatedAt.toRawBits(), restored.updatedAt.toRawBits())
        }
    }

    /** Whatever spelling is on the wire is kept: tags a newer or older build did not normalise our way. */
    @Test fun parsedSpellingsAreNeverNormalised() {
        val random = WireRandom(0x5EED_0014)
        repeat(200) { round ->
            val envelope = SyncEnvelope.plain(snippet(round), hlc = clock(1_000), origin = thisDevice)
            val members = LinkedHashMap(canonicalObject(envelope))
            val fields = LinkedHashMap(members.getValue("fields").objectOrNull!!)
            val rawTags = List(random.int(6)) { random.pick(listOf("  spaced  ", "", "DUP", "dup", "Dup", " \t ", "a\n b")) + text(random, 1) }
            fields["tags"] = JsonValue.Array(rawTags.map { JsonValue.of(it) })
            fields["name"] = JsonValue.of("  " + text(random) + "  ")
            fields["keyword"] = JsonValue.of("\\ " + text(random, 2))
            members["fields"] = JsonValue.Object(fields)
            val input = canonicalBytesRefreshingHash(members)

            val parsed = SyncEnvelope.parse(input)
            assertEquals(rawTags, parsed.fields!!.tags, "round $round")
            assertContentEquals(input, parsed.canonicalBytes(), "round $round")
            // A copy of a parsed value is still verbatim.
            assertContentEquals(input, parsed.copy().canonicalBytes())
            assertEquals(rawTags, parsed.fields!!.copy(isPinned = true).tags)
        }
    }

    // Bodies

    @Test fun emptyAndHugeBodiesRoundTrip() {
        val random = WireRandom(0x5EED_0015)
        val huge = StringBuilder()
        while (huge.length < 1_500_000) huge.append(text(random, 20)).append("\n\"\\\u0001é😀")
        for (content in listOf("", "x", "\u0000", huge.toString())) {
            val original = snippet(1, content = content)
            val envelope = SyncEnvelope.plain(original, hlc = clock(1_000), origin = thisDevice)
            val encoded = envelope.canonicalBytes()
            val parsed = SyncEnvelope.parse(encoded)

            assertEquals(content, parsed.plainSnippet!!.content)
            assertEquals(utf8(content).size, parsed.fields!!.contentByteCount)
            assertContentEquals(encoded, parsed.canonicalBytes())
            assertEquals(envelope, WireCodec.open(WireCodec.seal(envelope, productionSealer()), productionSealer()))
        }
        // The empty body still has a digest: the SHA-256 of nothing.
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            SyncEnvelope.plain(snippet(1, content = ""), hlc = clock(1), origin = thisDevice).contentHash,
        )
    }

    // Doubles

    @Test fun everyFiniteTimestampRoundTripsToTheBit() {
        val random = WireRandom(0x5EED_0016)
        val samples = notableDoubles + List(2_000) { double(random) }
        for (value in samples) {
            val envelope = SyncEnvelope.secureRecord(
                id = id(1), name = "n", keyword = "k", plaintext = utf8("b"),
                createdAt = value, updatedAt = -value, hlc = clock(1), origin = thisDevice,
            )
            val parsed = SyncEnvelope.parse(envelope.canonicalBytes())
            assertEquals(value.toRawBits(), parsed.fields!!.createdAt.toRawBits(), value.toString())
            assertEquals((-value).toRawBits(), parsed.fields!!.updatedAt.toRawBits(), value.toString())
        }
        // The spelling is Swift's `Double.description`, always with a `.` or an exponent.
        val pinned = SyncEnvelope.secureRecord(
            id = id(1), name = "n", keyword = "k", plaintext = utf8("b"),
            createdAt = 1e16, updatedAt = -0.0, hlc = clock(1), origin = thisDevice,
        )
        val text = String(pinned.canonicalBytes(), Charsets.UTF_8)
        assertTrue(text.contains("\"createdAt\":1e+16,"), text)
        assertTrue(text.contains("\"updatedAt\":-0.0}"), text)
    }

    @Test fun aTimestampThatIsNotFiniteHasNoEnvelope() {
        for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            val envelope = SyncEnvelope.plain(
                snippet(1).copy(updatedAt = value), hlc = clock(1), origin = thisDevice,
            )
            assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { envelope.canonicalBytes() }
            assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { envelope.envelopeHash() }
            // The value itself is still usable and equal to itself.
            assertEquals(envelope, envelope.copy())
        }
    }

    // Construction

    @Test fun theConstructorNormalisesAndCopyDoesNot() {
        val marker = JsonValue.array(JsonValue.of("a".repeat(64)))
        val live = SyncEnvelope(
            id = id(1), hlc = clock(1), origin = "AB-CD-EF-01-99", secure = false, deleted = false,
            fields = SyncEnvelope.Fields(
                name = "  spaced  ", keyword = "\\kw", content = utf8("x"),
                tags = listOf("  Work ", "work", "two   words", ""), isEnabled = true, isPinned = false,
                createdAt = at(0.0), updatedAt = at(0.0),
            ),
            x = mapOf(SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY to marker, "kept" to JsonValue.of(1)),
        )
        assertEquals("abcdef01", live.origin)
        assertEquals(listOf("Work", "two words"), live.fields!!.tags)
        assertEquals("  spaced  ", live.fields!!.name, "only tags are normalised")
        assertEquals("\\kw", live.fields!!.keyword)
        assertEquals(setOf("kept"), live.x.keys, "a live record cannot carry deletion authority")
        assertFalse(live.carriesUserInitiatedDeletion)
        assertEquals(SyncEnvelope.CURRENT_SCHEMA_VERSION, live.schemaVersion)

        // A tombstone keeps the marker, and its fields are dropped.
        val dead = SyncEnvelope(
            id = id(1), hlc = clock(2), origin = "7", secure = false, deleted = true, fields = live.fields,
            x = mapOf(SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY to marker),
        )
        assertEquals("00000007", dead.origin)
        assertNull(dead.fields)
        assertEquals(setOf("a".repeat(64)), dead.userInitiatedDeletionAncestorHashes)

        // `copy` is Swift's assignment to a `var` member: exactly what was given.
        val assigned = live.copy(origin = "AB-CD", x = live.x + (SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY to marker))
        assertEquals("AB-CD", assigned.origin)
        assertTrue(SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY in assigned.x)
        assertFalse(assigned.carriesUserInitiatedDeletion, "the marker counts only on a tombstone")
        assertSame(live.fields, assigned.fields)
        assertFalse(assigned.deleted)
        val retagged = live.fields!!.copy(tags = listOf("  raw  ", "RAW"))
        assertEquals(listOf("  raw  ", "RAW"), retagged.tags)
        // Bytes with a spelling the parser refuses can be built this way, and are refused on the way back in.
        assertFailsWith<SyncEnvelope.Failure.Malformed> { SyncEnvelope.parse(assigned.canonicalBytes()) }

        val moved = live.copy(id = id(2), hlc = clock(9), secure = true, schemaVersion = 0)
        assertEquals(id(2), moved.id)
        assertEquals(clock(9), moved.hlc)
        assertTrue(moved.secure)
        assertEquals(0L, moved.schemaVersion)
        assertNotEquals(live, moved)

        assertEquals(JsonValue.of(1), live.withExtension("added", JsonValue.of(1)).x["added"])
        assertEquals(emptySet(), live.withExtension("kept", null).x.keys)
        assertEquals(live, live.withExtension("absent", null))
    }

    @Test fun theUserDeletionMarkerIsReadOnlyFromAValidTombstone() {
        val hashes = (0 until 8).map { it.toString(16).repeat(64) }
        fun tombstone(marker: JsonValue?) = SyncEnvelope.tombstone(
            id(1), secure = false, hlc = clock(1), origin = thisDevice,
            x = if (marker == null) emptyMap() else mapOf(SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY to marker),
        )
        fun array(values: List<String>) = JsonValue.Array(values.map { JsonValue.of(it) })

        assertEquals(hashes.toSet(), tombstone(array(hashes)).userInitiatedDeletionAncestorHashes)
        assertEquals(setOf(hashes[0]), tombstone(array(hashes.take(1))).userInitiatedDeletionAncestorHashes)
        assertTrue(tombstone(array(hashes)).carriesUserInitiatedDeletion)

        val invalid = listOf(
            null,
            array(emptyList()),
            array(hashes + "8".repeat(64)),
            array(listOf(hashes[0], hashes[0])),
            array(listOf("A".repeat(64))),
            array(listOf("a".repeat(63))),
            array(listOf("a".repeat(65))),
            array(listOf("g".repeat(64))),
            JsonValue.array(JsonValue.of(hashes[0]), JsonValue.of(1)),
            JsonValue.of(hashes[0]),
            JsonValue.obj("hash" to JsonValue.of(hashes[0])),
        )
        for ((index, marker) in invalid.withIndex()) {
            val envelope = tombstone(marker)
            assertEquals(emptySet(), envelope.userInitiatedDeletionAncestorHashes, "marker $index")
            assertFalse(envelope.carriesUserInitiatedDeletion, "marker $index")
            if (marker != null) {
                assertFailsWith<SyncEnvelope.Failure.Malformed>("marker $index") { SyncEnvelope.parse(envelope.canonicalBytes()) }
            }
        }
    }

    // Text

    /** A Swift string cannot hold an unpaired surrogate; a new local value is repaired the way Swift repairs it. */
    @Test fun unpairedSurrogatesInNewLocalTextBecomeTheReplacementCharacter() {
        val broken = Snippet(
            id = id(1), name = "a\uD800b", keyword = "\uDC00k", content = "body \uD83D end",
            tags = listOf("t\uDFFF"), createdAt = at(0.0), updatedAt = at(0.0),
        )
        val envelope = SyncEnvelope.plain(broken, hlc = clock(1), origin = thisDevice)
        val fields = envelope.fields!!
        assertEquals("a�b", fields.name)
        assertEquals("�k", fields.keyword)
        assertEquals(listOf("t�"), fields.tags)
        assertContentEquals(utf8("body � end"), fields.content)
        // Well-formed pairs are left alone.
        val fine = SyncEnvelope.plain(snippet(1, name = "😀 𐀀"), hlc = clock(1), origin = thisDevice)
        assertEquals("😀 𐀀", fine.fields!!.name)
        assertEquals(envelope, SyncEnvelope.parse(envelope.canonicalBytes()))

        // Assigned verbatim, the same text has no canonical form.
        val assigned = envelope.fields!!.copy(name = "a\uD800b")
        val unrepaired = SyncEnvelope(id = id(1), hlc = clock(1), origin = thisDevice, secure = false, deleted = false, fields = assigned)
        assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { unrepaired.canonicalBytes() }
    }

    /** Swift compares text by canonical equivalence, and the hash by bytes. */
    @Test fun equalityIsSwiftsAndTheHashIsTheBytes() {
        val composed = SyncEnvelope.plain(snippet(1, name = "Café"), hlc = clock(1), origin = thisDevice)
        val decomposed = SyncEnvelope.plain(snippet(1, name = "Café"), hlc = clock(1), origin = thisDevice)
        assertEquals(composed, decomposed)
        assertEquals(composed.hashCode(), decomposed.hashCode())
        assertNotEquals(composed.envelopeHash(), decomposed.envelopeHash())
        // Each spelling survives its own round trip.
        assertEquals("Café", SyncEnvelope.parse(decomposed.canonicalBytes()).fields!!.name)
        assertEquals("Café", SyncEnvelope.parse(composed.canonicalBytes()).fields!!.name)

        // Bodies compare by bytes, timestamps as IEEE doubles.
        val composedBody = SyncEnvelope.plain(snippet(1, content = "é"), hlc = clock(1), origin = thisDevice)
        val decomposedBody = SyncEnvelope.plain(snippet(1, content = "é"), hlc = clock(1), origin = thisDevice)
        assertNotEquals(composedBody, decomposedBody)
        val zero = SyncEnvelope.plain(snippet(1).copy(createdAt = 0.0), hlc = clock(1), origin = thisDevice)
        val negativeZero = SyncEnvelope.plain(snippet(1).copy(createdAt = -0.0), hlc = clock(1), origin = thisDevice)
        assertEquals(zero, negativeZero)
        assertNotEquals(zero.envelopeHash(), negativeZero.envelopeHash())

        // Every other member takes part.
        val base = SyncEnvelope.plain(snippet(1), hlc = clock(1), origin = thisDevice)
        assertNotEquals(base, base.copy(hlc = clock(2)))
        assertNotEquals(base, base.copy(origin = "11112222"))
        assertNotEquals(base, base.copy(secure = true))
        assertNotEquals(base, base.withExtension("k", JsonValue.Null))
        assertNotEquals(base, base.tombstoned(clock(1), thisDevice))
        assertNotEquals<Any?>(base, base.fields)
        // And nothing of the record's text is in its description.
        assertFalse(base.toString().contains("Signature"))
        assertFalse(base.fields.toString().contains("Best"))
    }

    @Test fun theBodyOfAnEnvelopeCannotBeChangedThroughTheArraysItHandsOut() {
        val source = utf8("body")
        val fields = SyncEnvelope.Fields(
            name = "n", keyword = "k", content = source, tags = emptyList(), isEnabled = true, isPinned = false,
            createdAt = at(0.0), updatedAt = at(0.0),
        )
        val envelope = SyncEnvelope(id = id(1), hlc = clock(1), origin = thisDevice, secure = true, deleted = false, fields = fields)
        val hash = envelope.envelopeHash()

        source.fill(0)
        fields.content.fill(0)
        envelope.plaintext!!.fill(0)
        (envelope.canonicalValue().objectOrNull!!.getValue("fields").objectOrNull!!.getValue("content") as JsonValue.Utf8).wipe()
        (fields.canonicalValue.objectOrNull!!.getValue("content") as JsonValue.Utf8).wipe()

        assertContentEquals(utf8("body"), fields.content)
        assertEquals(hash, envelope.envelopeHash())
        assertTrue(fields.contentEquals(utf8("body")))
        assertTrue(fields.contentEquals(fields.copy(name = "other")))
    }
}
