package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
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
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `WireTests.swift`, suites "Envelope shape" and "Snippet and vault conversions", test for
 * test and under the same names. Every test names the failure it prevents.
 */
class SyncEnvelopeTest {

    private val thisDevice = WireFixtures.THIS_DEVICE

    // Envelope shape

    /** A key set that cannot grow cannot be stripped by an older build. Future fields go in `x`. */
    @Test fun theEnvelopeHasExactlyTenTopLevelKeysAndTheyAreTheseTen() {
        val envelope = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val members = canonicalObject(envelope)

        assertEquals(10, members.size)
        assertEquals(10, SyncEnvelope.TOP_LEVEL_KEYS.size)
        assertEquals(SyncEnvelope.TOP_LEVEL_KEYS, members.keys)
        assertEquals(
            setOf("schemaVersion", "id", "hlc", "origin", "secure", "deleted", "hash", "contentHash", "fields", "x"),
            members.keys,
        )
    }

    @Test fun malformedUserDeletionAuthorityIsRejectedAtTheWireBoundary() {
        val hashA = "a".repeat(64)
        val hashB = "b".repeat(64)
        val tombstone = SyncEnvelope.tombstone(id = id(7), secure = false, hlc = clock(2_000), origin = thisDevice)

        fun data(envelope: SyncEnvelope, marker: JsonValue): ByteArray {
            val members = LinkedHashMap(canonicalObject(envelope))
            val extensions = LinkedHashMap(members.getValue("x").objectOrNull!!)
            extensions[SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY] = marker
            members["x"] = JsonValue.Object(extensions)
            return canonicalBytesRefreshingHash(members)
        }

        val malformedTombstoneMarkers = listOf(
            JsonValue.array(),
            JsonValue.array(JsonValue.of(hashA), JsonValue.of(hashA)),
            JsonValue.Array((0 until 9).map { JsonValue.of(it.toString(16).repeat(64)) }),
            JsonValue.array(JsonValue.of("A".repeat(64))),
            JsonValue.array(JsonValue.of("not-a-sha-256")),
            JsonValue.array(JsonValue.of(hashA), JsonValue.of(7)),
            JsonValue.of(hashA),
        )
        for ((index, marker) in malformedTombstoneMarkers.withIndex()) {
            val input = data(tombstone, marker)
            assertFailsWith<SyncEnvelope.Failure.Malformed>("marker $index") { SyncEnvelope.parse(input) }
        }

        // The well-formed marker is accepted on a tombstone, so the refusals above are about the marker.
        val accepted = SyncEnvelope.parse(data(tombstone, JsonValue.array(JsonValue.of(hashA), JsonValue.of(hashB))))
        assertEquals(setOf(hashA, hashB), accepted.userInitiatedDeletionAncestorHashes)
        assertTrue(accepted.carriesUserInitiatedDeletion)

        val live = SyncEnvelope.plain(snippet(7), hlc = clock(2_000), origin = thisDevice)
        val liveBytes = data(live, JsonValue.array(JsonValue.of(hashB)))
        assertFailsWith<SyncEnvelope.Failure.Malformed> { SyncEnvelope.parse(liveBytes) }
    }

    @Test fun theFieldsObjectHasExactlyEightKeysAndTheyAreTheseEight() {
        val envelope = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val fields = canonicalObject(envelope).getValue("fields").objectOrNull!!

        assertEquals(8, fields.size)
        assertEquals(8, SyncEnvelope.Fields.KEYS.size)
        assertEquals(SyncEnvelope.Fields.KEYS, fields.keys)
        assertEquals(
            setOf("name", "keyword", "content", "tags", "isEnabled", "isPinned", "createdAt", "updatedAt"),
            fields.keys,
        )
    }

    /**
     * These are wire spellings, not UI cleanup choices. Pinning the normalised values and
     * the resulting hash makes a format migration necessary before either normaliser changes.
     */
    @Test fun locallyProducedTagAndDeviceSpellingsArePinnedToLiterals() {
        val envelope = SyncEnvelope.plain(
            snippet(0, tags = listOf("  Team\n Notes  ", "TEAM NOTES", "Café", "CAFE", " \t ")),
            hlc = Hlc.of(1_000, 2, "AA-BB-CC-DD"),
            origin = "AB-CD-EF-01",
        )

        assertEquals(listOf("Team Notes", "Café"), envelope.fields?.tags)
        assertEquals("0000000003e8-0002-aabbccdd", envelope.hlc.string)
        assertEquals("abcdef01", envelope.origin)
        assertEquals("dbc644e2963dccd24f99ff4919e1a61b03216d80bf0459b01977c2855560ec4c", envelope.envelopeHash())
        // The nine-key preimage of that hash, as written out in the porting brief.
        assertEquals(
            "{\"contentHash\":\"98f638839878a42acf8b855dd8284baed0029fe70963ae013a959e6341292073\"," +
                "\"deleted\":false,\"fields\":{\"content\":\"Best,\\nMike\",\"createdAt\":807004800.0," +
                "\"isEnabled\":true,\"isPinned\":false,\"keyword\":\"sig\",\"name\":\"Signature\"," +
                "\"tags\":[\"Team Notes\",\"Café\"],\"updatedAt\":807004800.0}," +
                "\"hlc\":\"0000000003e8-0002-aabbccdd\",\"id\":\"00000000-0000-4000-8000-000000000000\"," +
                "\"origin\":\"abcdef01\",\"schemaVersion\":1,\"secure\":false,\"x\":{}}",
            CanonicalJson.encodeToString(envelope.canonicalValue(includingHash = false)),
        )
    }

    /**
     * Parsing is the compatibility boundary: a future build may clean tags differently for
     * new snippets, but it must verify and re-emit every already-hashed spelling byte for byte.
     */
    @Test fun parsedTagsBypassDomainNormalizationBeforeHashVerification() {
        val envelope = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val members = LinkedHashMap(canonicalObject(envelope))
        val fields = LinkedHashMap(members.getValue("fields").objectOrNull!!)
        val legacyTags = listOf("  Legacy\n Tag  ", "LEGACY TAG", "")
        fields["tags"] = JsonValue.Array(legacyTags.map { JsonValue.of(it) })
        members["fields"] = JsonValue.Object(fields)
        val legacyBytes = canonicalBytesRefreshingHash(members)

        val parsed = SyncEnvelope.parse(legacyBytes)
        val declaredHash = CanonicalJson.parse(legacyBytes).objectOrNull!!.getValue("hash").textOrNull

        assertEquals(legacyTags, parsed.fields?.tags)
        assertContentEquals(legacyBytes, parsed.canonicalBytes())
        assertEquals(declaredHash, parsed.envelopeHash())
    }

    /** `origin` has a frozen spelling. Refusing another is safer than changing a hash-covered value. */
    @Test fun aNoncanonicalOriginIsRejectedRatherThanNormalized() {
        val envelope = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val members = LinkedHashMap(canonicalObject(envelope))
        members["origin"] = JsonValue.of("AABBCCDD")
        val input = canonicalBytesRefreshingHash(members)

        val failure = assertFailsWith<SyncEnvelope.Failure.Malformed> { SyncEnvelope.parse(input) }
        assertEquals(
            SyncEnvelope.Failure.Malformed("\"origin\" is not an eight-character lowercase hexadecimal device id"),
            failure,
        )
    }

    /** A tombstone still emits all ten keys, with `fields` and `contentHash` null. */
    @Test fun aTombstoneStillHasTenKeysWithFieldsAndContentHashNull() {
        val envelope = SyncEnvelope.tombstone(id = id(0), secure = true, hlc = clock(2_000), origin = thisDevice)
        val members = canonicalObject(envelope)

        assertEquals(10, members.size)
        assertTrue(members.getValue("fields").isNull)
        assertTrue(members.getValue("contentHash").isNull)
        assertEquals(true, members.getValue("deleted").boolOrNull)
    }

    /** Ignoring an unknown key means re-emitting the record without it: the silent strip. */
    @Test fun anUnknownTopLevelKeyIsRefusedRatherThanSilentlyStripped() {
        val envelope = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val members = LinkedHashMap(canonicalObject(envelope))
        members["surprise"] = JsonValue.of(1)

        val failure = assertFailsWith<SyncEnvelope.Failure.Malformed> { SyncEnvelope.parse(bytes(members)) }
        assertEquals("unknown top-level key(s): surprise; future fields belong in \"x\"", failure.detail)
    }

    /** A newer schema must land in "this build is too old", not in "the record is corrupt". */
    @Test fun aRecordFromANewerSchemaReportsTooNewRatherThanMalformed() {
        val envelope = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val members = LinkedHashMap(canonicalObject(envelope))
        members["schemaVersion"] = JsonValue.of(99)

        val failure = assertFailsWith<SyncEnvelope.Failure.TooNew> { SyncEnvelope.parse(bytes(members)) }
        assertEquals(SyncEnvelope.Failure.TooNew(99), failure)
    }

    /** A build that does not understand a key in `x` still hands it back untouched. */
    @Test fun thePassthroughBagSurvivesARoundTripByteForByte() {
        val bag = mapOf(
            "futureFlag" to JsonValue.of(true),
            "futureCount" to JsonValue.of(42),
            "futureNested" to JsonValue.obj(
                "a" to JsonValue.array(JsonValue.of(1), JsonValue.of(2.5), JsonValue.of("three"), JsonValue.Null),
            ),
        )
        val envelope = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice, x = bag)

        val reopened = SyncEnvelope.parse(envelope.canonicalBytes())
        assertEquals(bag, reopened.x)
        assertContentEquals(envelope.canonicalBytes(), reopened.canonicalBytes())
    }

    /** The hash covers the nine-key form, so an edited plaintext fails to parse. */
    @Test fun anEditedPlaintextIsCaughtByTheEnvelopesOwnHash() {
        val envelope = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val members = LinkedHashMap(canonicalObject(envelope))
        val fields = LinkedHashMap(members.getValue("fields").objectOrNull!!)
        fields["name"] = JsonValue.of("Tampered")
        members["fields"] = JsonValue.Object(fields)

        val failure = assertFailsWith<SyncEnvelope.Failure.HashMismatch> { SyncEnvelope.parse(bytes(members)) }
        assertEquals(SyncEnvelope.Failure.HashMismatch(), failure)
    }

    /** Two devices holding the same record must compute the same hash, or they push for ever. */
    @Test fun twoDevicesWithIdenticalContentComputeTheSameHash() {
        val one = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val two = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        assertEquals(one.envelopeHash(), two.envelopeHash())

        val elsewhere = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = "11112222")
        assertNotEquals(
            one.envelopeHash(), elsewhere.envelopeHash(),
            "origin is part of the record, so it must be part of its hash",
        )
    }

    @Test fun contentHashChangesWithTheBodyAndNotWithTheName() {
        val base = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val renamed = SyncEnvelope.plain(snippet(0, name = "Different"), hlc = clock(1_000), origin = thisDevice)
        val rewritten = SyncEnvelope.plain(snippet(0, content = "Different"), hlc = clock(1_000), origin = thisDevice)

        assertEquals(base.contentHash, renamed.contentHash)
        assertNotEquals(base.contentHash, rewritten.contentHash)
    }

    // Snippet and vault conversions

    /** The core round trip. Anything lost here is lost on every sync. */
    @Test fun aSnippetSurvivesTheEnvelopeUnchanged() {
        val original = snippet(
            3, name = "Grüße 😀", keyword = "hi", content = "line1\nline2\ttab \"quoted\" / slash",
            tags = listOf("Deutsch", "email"), isEnabled = false, isPinned = true,
            createdAt = 12.5, updatedAt = 900.25,
        )

        val envelope = SyncEnvelope.plain(original, hlc = clock(1_000), origin = thisDevice)
        val reopened = SyncEnvelope.parse(envelope.canonicalBytes())
        val restored = assertNotNull(reopened.plainSnippet)

        assertEquals(original, restored)
        // `Snippet ==` is canonical equivalence; the spelling must survive too.
        assertEquals(original.name, restored.name)
        assertEquals(original.content, restored.content)
        assertEquals(original.tags, restored.tags)
    }

    /**
     * The envelope stores exactly the number the model stores. Milliseconds since 1970 or
     * ISO 8601 would both round here, and a timestamp that moves on every pass means every
     * record looks changed on every sync.
     */
    @Test fun timestampsSurviveToTheLastBitRatherThanToTheNearestMillisecond() {
        val random = WireRandom(0x5EED_0042)
        repeat(200) {
            val jitter = random.int(1_000_000_000).toDouble() / 1_000_000_000
            val original = snippet(0, createdAt = jitter, updatedAt = 1_000 + jitter)

            val envelope = SyncEnvelope.plain(original, hlc = clock(1), origin = thisDevice)
            val restored = assertNotNull(SyncEnvelope.parse(envelope.canonicalBytes()).plainSnippet)

            assertEquals(original.updatedAt.toRawBits(), restored.updatedAt.toRawBits())
            assertEquals(original.createdAt.toRawBits(), restored.createdAt.toRawBits())
        }
    }

    /** A secure record's body is bytes on the way in, in the envelope, in the canonical form and on the way out. */
    @Test fun aVaultRecordRoundTripsWithItsBodyNeverLeavingData() {
        val secret = utf8("correct horse battery staple")
        val envelope = SyncEnvelope.secureRecord(
            id = id(5), name = "Router admin", keyword = "rtr", plaintext = secret,
            tags = listOf("infra"), isEnabled = true, isPinned = false,
            createdAt = at(1.0), updatedAt = at(2.0), hlc = clock(3_000), origin = thisDevice,
        )

        val reopened = SyncEnvelope.parse(envelope.canonicalBytes())
        val fields = assertNotNull(reopened.vaultFields)

        assertContentEquals(secret, fields.content)
        assertTrue(fields.contentEquals(secret))
        assertContentEquals(secret, reopened.plaintext)
        assertEquals("Router admin", fields.name)
        assertEquals("rtr", fields.keyword)
        assertTrue(reopened.secure)
    }

    /** `Snippet.content` is text bound for `snippets.json`, which every old build, export and link can read. */
    @Test fun aSecureRecordRefusesToBecomeAPlainSnippet() {
        val envelope = SyncEnvelope.secureRecord(
            id = id(5), name = "Router admin", keyword = "rtr",
            plaintext = utf8("hunter2"), createdAt = at(1.0), updatedAt = at(2.0),
            hlc = clock(3_000), origin = thisDevice,
        )

        assertNull(envelope.plainSnippet)
        assertNotNull(envelope.vaultFields)
        // And the plain record has no vault view.
        val plain = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        assertNull(plain.vaultFields)
        assertNotNull(plain.plainSnippet)
    }

    /** The invariant is enforced in the constructor, not checked at call sites. */
    @Test fun aTombstoneCarriesNoFieldsEvenWhenTheCallerSuppliesThem() {
        val secret = "correct horse battery staple"
        val live = SyncEnvelope.secureRecord(
            id = id(5), name = "Router admin", keyword = "rtr", plaintext = utf8(secret),
            createdAt = at(1.0), updatedAt = at(2.0), hlc = clock(3_000), origin = thisDevice,
        )

        // Both routes: the constructor handed fields it must drop, and the conversion.
        val direct = SyncEnvelope(
            id = live.id, hlc = live.hlc, origin = live.origin, secure = true, deleted = true, fields = live.fields,
        )
        val converted = live.tombstoned(hlc = clock(4_000), origin = thisDevice)

        for (tombstone in listOf(direct, converted)) {
            assertNull(tombstone.fields)
            assertNull(tombstone.contentHash, "a SHA-256 of a short secret is an offline brute-force oracle")
            assertNull(tombstone.plaintext)
            assertNull(tombstone.vaultFields)
            assertTrue(tombstone.secure, "which store it left is still needed to remove it")

            val text = String(tombstone.canonicalBytes(), Charsets.UTF_8)
            assertFalse(text.contains(secret))
            assertFalse(text.contains("Router admin"))
            assertFalse(text.contains("rtr"))
        }
    }

    /** A future build could have put anything in `x`, including something derived from the body. */
    @Test fun thePassthroughBagDoesNotTravelIntoATombstone() {
        val live = SyncEnvelope.plain(
            snippet(0), hlc = clock(1_000), origin = thisDevice, x = mapOf("derived" to JsonValue.of("secret-ish")),
        )

        assertTrue(live.tombstoned(hlc = clock(2_000), origin = thisDevice).x.isEmpty())
        // A plain record's `vaultKID` is not structural and does not travel either.
        val stamped = live.withExtension(SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY, JsonValue.of("k"))
        assertTrue(stamped.tombstoned(hlc = clock(2_000), origin = thisDevice).x.isEmpty())
    }

    /** The vault scope is the one entry a secure tombstone keeps, so another vault cannot apply the deletion. */
    @Test fun aSecureTombstoneRetainsOnlyItsVaultScope() {
        val live = SyncEnvelope.secureRecord(
            id = id(5), name = "Router admin", keyword = "rtr",
            plaintext = utf8("sealed bytes"), createdAt = at(1.0), updatedAt = at(2.0),
            hlc = clock(3_000), origin = thisDevice,
            x = mapOf(
                SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY to JsonValue.of("k-origin"),
                "derived" to JsonValue.of("must disappear"),
            ),
        )

        val tombstone = live.tombstoned(hlc = clock(4_000), origin = thisDevice)
        assertEquals(mapOf(SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY to JsonValue.of("k-origin")), tombstone.x)
    }

    @Test fun aTombstoneThatArrivesCarryingFieldsIsRefusedRatherThanTrusted() {
        val live = SyncEnvelope.plain(snippet(0), hlc = clock(1_000), origin = thisDevice)
        val members = LinkedHashMap(canonicalObject(live))
        members["deleted"] = JsonValue.of(true)

        val failure = assertFailsWith<SyncEnvelope.Failure.Malformed> { SyncEnvelope.parse(bytes(members)) }
        assertEquals("a tombstone must not carry \"fields\"", failure.detail)
    }
}
