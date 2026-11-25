package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.wire.WireFixtures.at
import com.khm.snippets.core.wire.WireFixtures.bytes
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
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * What `SyncEnvelope.parse` refuses: every tampered member, every missing member, every
 * explicit null, every wrong type, unknown and duplicate keys, and every spelling that is
 * not the frozen one. The parser is strict at the top level and in `fields`, and a
 * lossless passthrough in `x`.
 */
class SyncEnvelopeStrictnessTest {

    private val thisDevice = WireFixtures.THIS_DEVICE

    private val live = SyncEnvelope.secureRecord(
        id = id(5), name = "Router admin", keyword = "rtr", plaintext = utf8("v1.sealed.text"),
        tags = listOf("infra", "home"), isEnabled = true, isPinned = false,
        createdAt = at(1.0), updatedAt = at(2.5), hlc = clock(3_000, counter = 4), origin = thisDevice,
        x = mapOf(
            SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY to JsonValue.of("k-origin"),
            "future" to JsonValue.obj("n" to JsonValue.of(1), "list" to JsonValue.array(JsonValue.of(2.5), JsonValue.Null)),
        ),
    )

    private val tombstone = live.tombstoned(clock(4_000), thisDevice)
        .withExtension(SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY, JsonValue.array(JsonValue.of("a".repeat(64))))

    private fun members(envelope: SyncEnvelope = live) = LinkedHashMap(canonicalObject(envelope))

    private fun withField(key: String, value: JsonValue?): LinkedHashMap<String, JsonValue> {
        val members = members()
        val fields = LinkedHashMap(members.getValue("fields").objectOrNull!!)
        if (value == null) fields.remove(key) else fields[key] = value
        members["fields"] = JsonValue.Object(fields)
        return members
    }

    private fun malformed(input: ByteArray): String =
        assertFailsWith<SyncEnvelope.Failure.Malformed> { SyncEnvelope.parse(input) }.detail

    private val oneOfEveryType = listOf(
        JsonValue.Null, JsonValue.of(true), JsonValue.of(7), JsonValue.of(7.5), JsonValue.of("text"),
        JsonValue.array(JsonValue.of(1)), JsonValue.obj("k" to JsonValue.of(1)),
    )

    @Test fun theFixturesParse() {
        assertEquals(live, SyncEnvelope.parse(live.canonicalBytes()))
        assertEquals(tombstone, SyncEnvelope.parse(tombstone.canonicalBytes()))
        assertEquals(live, SyncEnvelope.parse(canonicalBytesRefreshingHash(members())))
    }

    // Tampering

    /** One member changed to another valid value, the `hash` left as it was: nothing parses. */
    @Test fun everyTopLevelMemberIsCoveredByAHash() {
        val replacements = mapOf(
            "schemaVersion" to JsonValue.of(0),
            "id" to JsonValue.of("00000000-0000-4000-8000-000000000006"),
            "hlc" to JsonValue.of(clock(3_000, counter = 5).string),
            "origin" to JsonValue.of("11112222"),
            "secure" to JsonValue.of(false),
            "contentHash" to JsonValue.of("0".repeat(64)),
            "hash" to JsonValue.of("0".repeat(64)),
            "x" to JsonValue.obj(SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY to JsonValue.of("k-rival")),
        )
        for ((key, value) in replacements) {
            val members = members()
            members[key] = value
            assertFailsWith<SyncEnvelope.Failure.HashMismatch>(key) { SyncEnvelope.parse(bytes(members)) }
        }
        assertEquals(SyncEnvelope.TOP_LEVEL_KEYS - "deleted" - "fields", replacements.keys)

        // The deletion flag is caught earlier, by the tombstone invariant.
        val flipped = members()
        flipped["deleted"] = JsonValue.of(true)
        assertEquals("a tombstone must not carry \"fields\"", malformed(bytes(flipped)))
        val revived = members(tombstone)
        revived["deleted"] = JsonValue.of(false)
        assertTrue(malformed(bytes(revived)).contains("userDeletion.v1"))
    }

    @Test fun everyFieldsMemberIsCoveredByTheHash() {
        val replacements = mapOf(
            "name" to JsonValue.of("Router Admin"),
            "keyword" to JsonValue.of("rtr2"),
            "content" to JsonValue.of("v1.sealed.texu"),
            "tags" to JsonValue.array(JsonValue.of("infra")),
            "isEnabled" to JsonValue.of(false),
            "isPinned" to JsonValue.of(true),
            "createdAt" to JsonValue.of(Math.nextUp(at(1.0))),
            "updatedAt" to JsonValue.of(Math.nextDown(at(2.5))),
        )
        for ((key, value) in replacements) {
            assertFailsWith<SyncEnvelope.Failure.HashMismatch>(key) { SyncEnvelope.parse(bytes(withField(key, value))) }
        }
        assertEquals(SyncEnvelope.Fields.KEYS, replacements.keys)

        // A changed body with a refreshed `hash` but the old `contentHash` is still refused.
        val staleContentHash = canonicalBytesRefreshingHash(withField("content", JsonValue.of("another body")))
        assertFailsWith<SyncEnvelope.Failure.HashMismatch> { SyncEnvelope.parse(staleContentHash) }
    }

    @Test fun everyChangeToThePassthroughBagIsCoveredByTheHash() {
        val bag = live.x
        val changes = listOf(
            bag + ("added" to JsonValue.of(1)),
            bag - "future",
            bag + ("future" to JsonValue.obj("n" to JsonValue.of(2), "list" to JsonValue.array(JsonValue.of(2.5), JsonValue.Null))),
            bag + ("future" to JsonValue.obj("n" to JsonValue.of(1.0), "list" to JsonValue.array(JsonValue.of(2.5), JsonValue.Null))),
            bag + ("future" to JsonValue.obj("n" to JsonValue.of(1), "list" to JsonValue.array(JsonValue.Null, JsonValue.of(2.5)))),
            emptyMap(),
        )
        for ((index, changed) in changes.withIndex()) {
            val members = members()
            members["x"] = JsonValue.Object(changed)
            assertFailsWith<SyncEnvelope.Failure.HashMismatch>("change $index") { SyncEnvelope.parse(bytes(members)) }
        }
    }

    /** Every single altered, removed or missing byte of the canonical form is refused. */
    @Test fun noSingleByteOfTheCanonicalFormCanChange() {
        for (envelope in listOf(live, tombstone)) {
            val canonical = envelope.canonicalBytes()
            for (index in canonical.indices) {
                val altered = canonical.copyOf()
                altered[index] = (altered[index].toInt() xor 1).toByte()
                expectRefused("byte $index altered") { SyncEnvelope.parse(altered) }

                val removed = canonical.copyOfRange(0, index) + canonical.copyOfRange(index + 1, canonical.size)
                expectRefused("byte $index removed") { SyncEnvelope.parse(removed) }

                expectRefused("cut at $index") { SyncEnvelope.parse(canonical.copyOfRange(0, index)) }
            }
            expectRefused("a byte appended") { SyncEnvelope.parse(canonical + '}'.code.toByte()) }
        }
    }

    private fun expectRefused(label: String, block: () -> Unit) {
        try {
            block()
        } catch (_: SyncEnvelope.Failure) {
            return
        } catch (_: CanonicalJson.Failure) {
            return
        }
        fail("$label: the envelope still parsed")
    }

    // Missing members, explicit nulls, wrong types

    @Test fun everyTopLevelMemberIsRequired() {
        for (key in SyncEnvelope.TOP_LEVEL_KEYS) {
            for (envelope in listOf(live, tombstone)) {
                val members = members(envelope)
                members.remove(key)
                val expected =
                    if (key == "schemaVersion") "missing or non-integer \"schemaVersion\"" else "missing \"$key\""
                assertEquals(expected, malformed(bytes(members)), key)
            }
        }
    }

    @Test fun everyFieldsMemberIsRequired() {
        for (key in SyncEnvelope.Fields.KEYS) {
            assertEquals(
                "\"fields\" is missing \"$key\"", malformed(canonicalBytesRefreshingHash(withField(key, null))), key,
            )
        }
    }

    /** `null` is not "absent" and not a default, anywhere. */
    @Test fun anExplicitNullIsRefusedWhereAValueIsRequired() {
        val expected = mapOf(
            "schemaVersion" to "missing or non-integer \"schemaVersion\"",
            "id" to "\"id\" is not a UUID",
            "hlc" to "\"hlc\" is not a clock reading",
            "origin" to "\"origin\" is not a string",
            "secure" to "\"secure\" and \"deleted\" must be booleans",
            "deleted" to "\"secure\" and \"deleted\" must be booleans",
            "x" to "\"x\" is not an object",
            "fields" to "a live record must carry \"fields\"",
        )
        for ((key, detail) in expected) {
            val members = members()
            members[key] = JsonValue.Null
            assertEquals(detail, malformed(canonicalBytesRefreshingHash(members)), key)
        }
        // `hash` (set after the refresh, or it would be recomputed) and `contentHash`.
        val nullHash = members()
        nullHash["hash"] = JsonValue.Null
        assertEquals("\"hash\" is not a string", malformed(bytes(nullHash)))
        val nullContentHash = members()
        nullContentHash["contentHash"] = JsonValue.Null
        assertFailsWith<SyncEnvelope.Failure.HashMismatch> {
            SyncEnvelope.parse(canonicalBytesRefreshingHash(nullContentHash))
        }

        for (key in SyncEnvelope.Fields.KEYS) {
            assertEquals(
                "a \"fields\" member has the wrong type",
                malformed(canonicalBytesRefreshingHash(withField(key, JsonValue.Null))), key,
            )
        }
    }

    @Test fun everyTopLevelMemberOfTheWrongTypeIsRefused() {
        fun isRightType(key: String, value: JsonValue): Boolean = when (key) {
            "schemaVersion" -> value is JsonValue.Integer
            "id", "hlc", "origin", "hash" -> value is JsonValue.Text
            "secure", "deleted" -> value is JsonValue.Bool
            "contentHash" -> value is JsonValue.Text || value.isNull
            "fields" -> value is JsonValue.Object || value.isNull
            "x" -> value is JsonValue.Object
            else -> error(key)
        }
        var checked = 0
        for (key in SyncEnvelope.TOP_LEVEL_KEYS) {
            for (value in oneOfEveryType) {
                if (isRightType(key, value)) continue
                val members = members()
                members[key] = value
                val input = if (key == "hash") bytes(members) else canonicalBytesRefreshingHash(members)
                // Malformed for all but `contentHash`, whose wrong type is a hash that does not match.
                val failure = assertFailsWith<SyncEnvelope.Failure>("$key = $value") { SyncEnvelope.parse(input) }
                assertEquals(key == "contentHash", failure is SyncEnvelope.Failure.HashMismatch, "$key = $value")
                checked += 1
            }
        }
        assertEquals(10 * 7 - (1 + 4 + 2 + 2 + 2 + 1), checked)
    }

    @Test fun everyFieldsMemberOfTheWrongTypeIsRefused() {
        fun isRightType(key: String, value: JsonValue): Boolean = when (key) {
            "name", "keyword", "content" -> value is JsonValue.Text
            "tags" -> value is JsonValue.Array
            "isEnabled", "isPinned" -> value is JsonValue.Bool
            // An integer token is a number; the vectors pin that it is hashed as a double.
            "createdAt", "updatedAt" -> value is JsonValue.Real || value is JsonValue.Integer
            else -> error(key)
        }
        for (key in SyncEnvelope.Fields.KEYS) {
            for (value in oneOfEveryType) {
                if (isRightType(key, value)) continue
                assertEquals(
                    "a \"fields\" member has the wrong type",
                    malformed(canonicalBytesRefreshingHash(withField(key, value))), "$key = $value",
                )
            }
        }
        for (tags in listOf(
            JsonValue.array(JsonValue.of(1)),
            JsonValue.array(JsonValue.of("ok"), JsonValue.Null),
            JsonValue.array(JsonValue.array(JsonValue.of("nested"))),
        )) {
            assertEquals(
                "\"tags\" must be an array of strings", malformed(canonicalBytesRefreshingHash(withField("tags", tags))),
            )
        }
        assertEquals("\"fields\" is not an object", malformed(bytes(members().also { it["fields"] = JsonValue.of("x") })))
    }

    // Unknown and duplicate keys

    @Test fun unknownKeysAreRefusedAtTheTopLevelAndInFieldsAndListedInSwiftsOrder() {
        // Scalar order, not UTF-16 order: U+FFFD sorts before U+10000.
        val extras = listOf("𐀀", "a", "�", "Z", "é")
        val sorted = "Z, a, é, �, 𐀀"

        val top = members()
        for (key in extras) top[key] = JsonValue.of(1)
        assertEquals(
            "unknown top-level key(s): $sorted; future fields belong in \"x\"", malformed(canonicalBytesRefreshingHash(top)),
        )

        val nested = members()
        val fields = LinkedHashMap(nested.getValue("fields").objectOrNull!!)
        for (key in extras) fields[key] = JsonValue.of(1)
        nested["fields"] = JsonValue.Object(fields)
        assertEquals("unknown key(s) in \"fields\": $sorted", malformed(canonicalBytesRefreshingHash(nested)))

        // A newer schema is reported as too new even when it also brings a new key.
        top["schemaVersion"] = JsonValue.of(2)
        assertEquals(SyncEnvelope.Failure.TooNew(2), assertFailsWith<SyncEnvelope.Failure.TooNew> { SyncEnvelope.parse(bytes(top)) })
    }

    @Test fun unknownMembersOfThePassthroughBagArePreservedLosslessly() {
        val bag = LinkedHashMap(live.x)
        bag["𐀀"] = JsonValue.of(Long.MIN_VALUE)
        bag["�"] = JsonValue.of(Long.MAX_VALUE)
        bag["whole"] = JsonValue.of(3.0)
        bag["integer"] = JsonValue.of(3)
        bag["tiny"] = JsonValue.of(5e-324)
        bag["text"] = JsonValue.of("line\nbreak \u0001 \"quoted\" / é é  ")
        bag["deep"] = JsonValue.obj("a" to JsonValue.obj("b" to JsonValue.array(JsonValue.obj(), JsonValue.array())))
        bag["contentConflict.v1.abc"] = JsonValue.obj("fields" to JsonValue.Null)
        val members = members()
        members["x"] = JsonValue.Object(bag)
        val input = canonicalBytesRefreshingHash(members)

        val parsed = SyncEnvelope.parse(input)
        assertEquals(bag, parsed.x)
        assertContentEquals(input, parsed.canonicalBytes())
        // An integer stays an integer and a whole double keeps its `.0`.
        val text = String(input, Charsets.UTF_8)
        assertTrue(text.contains("\"integer\":3,"))
        assertTrue(text.contains("\"whole\":3.0,"))
        // The bag survives a tombstone only as `vaultKID`.
        assertEquals(setOf(SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY), parsed.tombstoned(clock(9_000), thisDevice).x.keys)
    }

    @Test fun duplicateKeysAreRefusedAtEveryLevel() {
        val canonical = String(live.canonicalBytes(), Charsets.UTF_8)
        val duplicates = listOf(
            canonical.replaceFirst("{", "{\"secure\":true,"),
            canonical.replaceFirst("{", "{\"hash\":\"${live.envelopeHash()}\","),
            canonical.replace("\"fields\":{", "\"fields\":{\"name\":\"Router admin\","),
            canonical.replace("\"x\":{", "\"x\":{\"vaultKID\":\"k-origin\","),
            canonical.replace("\"x\":{", "\"x\":{\"dup\":{\"a\":1,\"a\":1},"),
            // Canonically equivalent spellings are one key to Swift.
            canonical.replace("\"x\":{", "\"x\":{\"é\":1,\"é\":2,"),
        )
        for ((index, text) in duplicates.withIndex()) {
            assertTrue(text != canonical, "duplicate $index was not inserted")
            assertFailsWith<CanonicalJson.Failure.DuplicateKey>("duplicate $index") { SyncEnvelope.parse(utf8(text)) }
        }
    }

    // Frozen spellings

    /**
     * An uppercase id is read as the same UUID, as Foundation reads it, and the hash always
     * covers the lowercase spelling. So bytes hashed over an uppercase id are refused, and
     * an uppercase id beside the lowercase hash is the same record and re-emits in lowercase.
     */
    @Test fun theIdIsHashedInLowercaseAndNoOtherUuidSpellingIsAccepted() {
        val lowercase = "00000000-0000-4000-8000-00000000000a"
        val envelope = SyncEnvelope.plain(snippet(10), hlc = clock(1_000), origin = thisDevice)
        assertTrue(String(envelope.canonicalBytes(), Charsets.UTF_8).contains("\"id\":\"$lowercase\""))

        for (spelling in listOf(lowercase.uppercase(), "00000000-0000-4000-8000-00000000000A")) {
            val members = members(envelope)
            members["id"] = JsonValue.of(spelling)
            assertFailsWith<SyncEnvelope.Failure.HashMismatch>(spelling) {
                SyncEnvelope.parse(canonicalBytesRefreshingHash(members))
            }
            val sameRecord = SyncEnvelope.parse(bytes(members))
            assertEquals(envelope, sameRecord, spelling)
            assertContentEquals(envelope.canonicalBytes(), sameRecord.canonicalBytes(), spelling)
        }

        val notUuids = listOf(
            "", "1-1-1-1-1", lowercase.replace("-", ""), "{$lowercase}", "$lowercase ", " $lowercase",
            lowercase.dropLast(1), lowercase + "0", lowercase.replace('a', 'g'), "urn:uuid:$lowercase",
            "00000000_0000_4000_8000_00000000000a", "０0000000-0000-4000-8000-00000000000a",
        )
        for (spelling in notUuids) {
            val members = members(envelope)
            members["id"] = JsonValue.of(spelling)
            assertEquals("\"id\" is not a UUID", malformed(canonicalBytesRefreshingHash(members)), spelling)
        }
    }

    @Test fun theClockAndTheOriginHaveExactlyOneSpelling() {
        val goodClock = live.hlc.string
        val badClocks = listOf(
            goodClock.uppercase(), goodClock.dropLast(1), goodClock + "0", goodClock.replace('-', '_'),
            "", " $goodClock", "000000000bb8-0004-AABBCCDD", "000000000bb8-4-aabbccdd", "00000000bb8-00004-aabbccdd",
        )
        for (spelling in badClocks) {
            val members = members()
            members["hlc"] = JsonValue.of(spelling)
            assertEquals("\"hlc\" is not a clock reading", malformed(canonicalBytesRefreshingHash(members)), spelling)
        }

        val badOrigins = listOf("AABBCCDD", "aabbccd", "aabbccdd0", "", "aabbccdg", "aa-bb-cc", " aabbccd", "ａabbccdd", "0xaabbcc")
        for (spelling in badOrigins) {
            val members = members()
            members["origin"] = JsonValue.of(spelling)
            assertEquals(
                "\"origin\" is not an eight-character lowercase hexadecimal device id",
                malformed(canonicalBytesRefreshingHash(members)), spelling,
            )
        }

        // The origin need not be the clock's device, and the reserved foreign device is a valid origin.
        for (origin in listOf("11112222", "00000000", "ffffffff")) {
            val members = members()
            members["origin"] = JsonValue.of(origin)
            assertEquals(origin, SyncEnvelope.parse(canonicalBytesRefreshingHash(members)).origin)
        }
    }

    @Test fun theHashesAreLowercaseHexOfTheirFullLength() {
        val hash = live.envelopeHash()
        for (spelling in listOf(hash.uppercase(), hash.take(32), hash + "0", " $hash", "")) {
            val members = members()
            members["hash"] = JsonValue.of(spelling)
            assertFailsWith<SyncEnvelope.Failure.HashMismatch>(spelling) { SyncEnvelope.parse(bytes(members)) }
        }
        val contentHash = live.contentHash!!
        for (spelling in listOf(contentHash.uppercase(), contentHash.take(32), "")) {
            val members = members()
            members["contentHash"] = JsonValue.of(spelling)
            assertFailsWith<SyncEnvelope.Failure.HashMismatch>(spelling) {
                SyncEnvelope.parse(canonicalBytesRefreshingHash(members))
            }
        }
    }

    @Test fun theSchemaVersionIsAnIntegerTokenNotNewerThanThisBuild() {
        fun withVersion(token: String): ByteArray {
            val text = String(live.canonicalBytes(), Charsets.UTF_8)
            assertTrue(text.contains("\"schemaVersion\":1,"))
            return utf8(text.replace("\"schemaVersion\":1,", "\"schemaVersion\":$token,"))
        }
        for (token in listOf("1.0", "1e0", "\"1\"", "true", "[1]", "9223372036854775808", "-9223372036854775809")) {
            assertEquals("missing or non-integer \"schemaVersion\"", malformed(withVersion(token)), token)
        }
        for ((token, version) in listOf("2" to 2L, "99" to 99L, "9223372036854775807" to Long.MAX_VALUE)) {
            val failure = assertFailsWith<SyncEnvelope.Failure.TooNew>(token) { SyncEnvelope.parse(withVersion(token)) }
            assertEquals(version, failure.version)
        }
        // Swift accepts anything not newer, down to the smallest 64-bit integer, and keeps it.
        for (version in listOf(0L, -1L, Long.MIN_VALUE)) {
            val members = members()
            members["schemaVersion"] = JsonValue.of(version)
            val input = canonicalBytesRefreshingHash(members)
            val parsed = SyncEnvelope.parse(input)
            assertEquals(version, parsed.schemaVersion)
            assertContentEquals(input, parsed.canonicalBytes())
        }
        // `-0` is the integer zero and `01` is not a number.
        assertFailsWith<SyncEnvelope.Failure.HashMismatch> { SyncEnvelope.parse(withVersion("-0")) }
        assertFailsWith<CanonicalJson.Failure.UnexpectedByte> { SyncEnvelope.parse(withVersion("01")) }
    }

    @Test fun aTombstoneCarriesNeitherFieldsNorAContentHashAndALiveRecordCarriesBoth() {
        val liveFields = members().getValue("fields")

        val withFields = members(tombstone)
        withFields["fields"] = liveFields
        assertEquals("a tombstone must not carry \"fields\"", malformed(canonicalBytesRefreshingHash(withFields)))

        val withContentHash = members(tombstone)
        withContentHash["contentHash"] = JsonValue.of(live.contentHash!!)
        assertEquals("a tombstone must not carry \"contentHash\"", malformed(canonicalBytesRefreshingHash(withContentHash)))
        withContentHash["contentHash"] = JsonValue.of(false)
        assertEquals("a tombstone must not carry \"contentHash\"", malformed(canonicalBytesRefreshingHash(withContentHash)))

        val withoutFields = members()
        withoutFields["fields"] = JsonValue.Null
        withoutFields["contentHash"] = JsonValue.Null
        assertEquals("a live record must carry \"fields\"", malformed(canonicalBytesRefreshingHash(withoutFields)))
    }

    // Not JSON, or not canonical-parser JSON

    @Test fun inputThatIsNotStrictJsonIsRefusedByTheJsonLayer() {
        val canonical = String(live.canonicalBytes(), Charsets.UTF_8)
        val inputs = listOf(
            utf8(""),
            utf8("   "),
            byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + utf8(canonical),            // byte order mark
            utf8(canonical.dropLast(1) + ",}"),                                                    // trailing comma
            utf8(canonical.replace("\"secure\":true", "'secure':true")),                           // single quotes
            utf8(canonical.replace("\"secure\":true", "\"secure\":True")),                         // not a literal
            utf8(canonical.replace("\"x\":{", "/* note */\"x\":{")),                               // a comment
            utf8(canonical.replace("\"keyword\":\"rtr\"", "\"keyword\":\"r\tr\"")),                // raw control character
            utf8(canonical.replace("\"keyword\":\"rtr\"", "\"keyword\":\"r\\ud800r\"")),           // lone surrogate escape
            utf8(canonical.replace("\"keyword\":\"rtr\"", "\"keyword\":\"r\\xr\"")),               // unknown escape
            utf8(canonical.replace("\"isPinned\":false", "\"isPinned\":false,\"createdAt\":NaN")),
            utf8("$canonical$canonical"),                                                          // two documents
            utf8(canonical.replace("\"x\":{", "\"x\":{\"deep\":" + "[".repeat(40) + "]".repeat(40) + ",")),
        )
        for ((index, input) in inputs.withIndex()) {
            assertFailsWith<CanonicalJson.Failure>("input $index") { SyncEnvelope.parse(input) }
        }
        // An over-long encoding inside a string: the classic way to smuggle a quote past an escaper.
        val invalidUtf8 = utf8(canonical.substringBefore("\"keyword\":\"rtr\"") + "\"keyword\":\"r") +
            byteArrayOf(0xC0.toByte(), 0xA2.toByte()) + utf8("r\"" + canonical.substringAfter("\"keyword\":\"rtr\""))
        assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { SyncEnvelope.parse(invalidUtf8) }
        // Surrounding whitespace is JSON, and the envelope inside is what is hashed.
        assertEquals(live, SyncEnvelope.parse(utf8(" \t\r\n$canonical\n ")))
        // Top-level values that are JSON but not an object.
        for (text in listOf("[]", "null", "1", "\"envelope\"", "true")) {
            assertEquals("the envelope is not a JSON object", malformed(utf8(text)), text)
        }
    }

    /** A timestamp too large for a double parses as infinity, which has no canonical spelling to hash. */
    @Test fun aTimestampThatIsNotFiniteCannotBeHashed() {
        val text = String(live.canonicalBytes(), Charsets.UTF_8)
        val createdAt = "\"createdAt\":${text.substringAfter("\"createdAt\":").substringBefore(',')}"
        for (token in listOf("1e999", "-1e999")) {
            assertFailsWith<CanonicalJson.Failure.NonFiniteNumber>(token) {
                SyncEnvelope.parse(utf8(text.replace(createdAt, "\"createdAt\":$token")))
            }
        }
    }
}
