package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.wire.WireFixtures.fixedNonce
import com.khm.snippets.core.wire.WireFixtures.unhex
import com.khm.snippets.core.wire.WireFixtures.utf8
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The golden vectors the Swift sources emitted (`tools/swift-interop`) for the wire layer:
 *
 * - V11: envelope canonical bytes, hash preimage, hash, `rev`, `contentHash`; what the
 *   constructor normalises; every `SyncEnvelope.parse` outcome.
 * - V12: `WireCodec.seal` with the shipping sealer and fixed nonces, and `WireCodec.open`
 *   outcomes.
 * - V18: the split of the 64-byte `K_sync` material, followed by one seal.
 * - V19: the portable key bundle's JSON bytes and its strict reader.
 *
 * Every case is run, and in both directions where it has two.
 */
class SwiftWireVectorsTest {

    // V11

    @Test fun v11EnvelopesEmitTheBytesSwiftEmittedAndParseBackToTheSameEnvelope() {
        val cases = SwiftVectors.cases("V11-sync-envelope", "envelope")
        for (case in cases) {
            val expected = case.obj("envelope")
            val canonical = expected.bytes("canonicalHex")
            assertContentEquals(utf8(expected.string("canonicalText")), canonical, "${case.label}: text and hex")

            // Emit direction: the listed members, through the constructor a local record goes through.
            val built = envelopeFrom(expected)
            assertExpected(case.label, expected, built)

            // Parse direction: Swift's bytes, verbatim.
            val parsed = SyncEnvelope.parse(canonical)
            assertExpected("${case.label} (parsed)", expected, parsed)
            assertEquals(built, parsed, case.label)
            assertMembers(case.label, expected, parsed)
        }
        assertEquals(9, cases.size)
    }

    @Test fun v11ConstructorNormalisesWhatSwiftsConstructorNormalises() {
        val cases = SwiftVectors.cases("V11-sync-envelope", "construct")
        for (case in cases) {
            val expected = case.obj("envelope")
            val deleted = expected.boolean("deleted")
            val inputX = if (case.has("inputX")) {
                CanonicalJson.parse(utf8(case.string("inputX"))).objectOrNull!!
            } else {
                emptyMap()
            }
            val fields = if (deleted) {
                // The fields Swift handed to the tombstone's constructor, which must be dropped.
                SyncEnvelope.Fields(
                    name = "n", keyword = "k", content = utf8("gone"), tags = emptyList(), isEnabled = true,
                    isPinned = false, createdAt = 807_004_800.5, updatedAt = 812_578_800.123456,
                )
            } else {
                val listed = expected.obj("fields")
                SyncEnvelope.Fields(
                    name = listed.string("name"), keyword = listed.string("keyword"),
                    content = listed.bytes("contentHex"), tags = case.strings("inputTags"),
                    isEnabled = listed.boolean("isEnabled"), isPinned = listed.boolean("isPinned"),
                    createdAt = listed.double("createdAt"), updatedAt = listed.double("updatedAt"),
                )
            }
            val built = SyncEnvelope(
                id = Uuids.parseLowercase(expected.string("id"))!!,
                hlc = Hlc.parse(expected.string("hlc"))!!,
                origin = case.string("inputOrigin"),
                secure = expected.boolean("secure"),
                deleted = deleted,
                fields = fields,
                x = inputX,
            )
            assertExpected(case.label, expected, built)
            assertMembers(case.label, expected, built)
            assertEquals(built, SyncEnvelope.parse(expected.bytes("canonicalHex")), case.label)
        }
        assertEquals(2, cases.size)
    }

    @Test fun v11ParseOutcomesAreSwifts() {
        val cases = SwiftVectors.cases("V11-sync-envelope", "parse")
        var accepted = 0
        var refused = 0
        for (case in cases) {
            val input = case.bytes("inputHex")
            if (case.has("ok")) {
                val envelope = SyncEnvelope.parse(input)
                assertEquals(case.string("ok"), envelope.envelopeHash(), case.label)
                // What was accepted is re-emitted canonically and parses to the same value.
                assertEquals(envelope, SyncEnvelope.parse(envelope.canonicalBytes()), case.label)
                accepted += 1
            } else {
                assertEquals(case.string("error"), swiftErrorOf { SyncEnvelope.parse(input) }, case.label)
                refused += 1
            }
        }
        assertEquals(54, cases.size)
        assertEquals(10 to 44, accepted to refused)
    }

    @Test fun v11HasSixtyFiveCases() {
        assertEquals(65, SwiftVectors.cases("V11-sync-envelope").size)
    }

    // V12

    @Test fun v12SealsToTheBlobsSwiftSealedAndOpensThem() {
        val cases = SwiftVectors.cases("V12-wire-record", "seal")
        val envelopes = SwiftVectors.cases("V11-sync-envelope", "envelope").associateBy { it.name }
        for (case in cases) {
            val plaintext = case.bytes("plaintextHex")
            // The sealed envelope is V11's of the same name.
            assertContentEquals(envelopes.getValue(case.name).obj("envelope").bytes("canonicalHex"), plaintext, case.label)
            val envelope = SyncEnvelope.parse(plaintext)
            val wire = case.obj("wire")
            val id = Uuids.parseLowercase(wire.string("id"))!!
            val keyring = SnippetCrypto.Keyring(case.bytes("syncKeyHex"), case.bytes("syncSaltHex"))
            assertEquals(SyncKeyMaterial.SCOPE_ID, case.string("scopeID"), case.label)

            // What the blob is bound to: no `rev` in it.
            val context = SnippetCrypto.RecordContext(case.string("scopeID"), id, wire.boolean("deleted"))
            assertContentEquals(case.bytes("aadHex"), SnippetCrypto.additionalData(context), case.label)
            assertContentEquals(case.bytes("recordKeyHex"), keyring.recordKey(id), case.label)

            // Seal direction, with Swift's nonce.
            val sealer = SnippetCryptoSealer(keyring, case.string("scopeID"), fixedNonce(case.bytes("nonceHex")))
            val record = WireCodec.seal(envelope, sealer)
            val expectedBlob = Base64Std.decodeCanonical(wire.string("blobBase64"))!!
            assertContentEquals(utf8(wire.string("blobText")), expectedBlob, "${case.label}: text and base64")
            assertEquals(id, record.id, case.label)
            assertEquals(wire.string("rev"), record.rev, case.label)
            assertEquals(wire.boolean("deleted"), record.deleted, case.label)
            assertEquals(Bytes.toHex(expectedBlob), Bytes.toHex(record.blob), case.label)
            assertNull(record.recordVersion, case.label)

            // Open direction, from Swift's bytes and with the system nonce source.
            val swiftRecord = WireRecord(id, wire.string("rev"), wire.boolean("deleted"), expectedBlob)
            val opened = WireCodec.open(swiftRecord, SnippetCryptoSealer(keyring, case.string("scopeID")))
            assertEquals(envelope, opened, case.label)
            assertContentEquals(plaintext, opened.canonicalBytes(), case.label)
        }
        assertEquals(9, cases.size)
    }

    @Test fun v12OpenOutcomesAreSwifts() {
        val cases = SwiftVectors.cases("V12-wire-record", "open")
        var opened = 0
        for (case in cases) {
            val wire = case.obj("wire")
            val record = WireRecord(
                id = Uuids.parseLowercase(wire.string("id"))!!,
                rev = wire.string("rev"),
                deleted = wire.boolean("deleted"),
                blob = Base64Std.decodeCanonical(wire.string("blobBase64"))!!,
            )
            val sealer = SnippetCryptoSealer(
                SnippetCrypto.Keyring(case.bytes("syncKeyHex"), case.bytes("syncSaltHex")), case.string("scopeID"),
            )
            if (case.has("ok")) {
                assertEquals(case.string("ok"), WireCodec.open(record, sealer).envelopeHash(), case.label)
                opened += 1
            } else {
                assertEquals(case.string("error"), swiftErrorOf { WireCodec.open(record, sealer) }, case.label)
            }
        }
        assertEquals(10, cases.size)
        assertEquals(1, opened)
    }

    // V18

    @Test fun v18SplitsTheSyncKeyMaterialAsSwiftDoesAndSealsUnderIt() {
        val cases = SwiftVectors.cases("V18-sync-key-split")
        var split = 0
        for (case in cases) {
            val material = case.bytes("materialHex")
            if (case.has("error")) {
                assertEquals(case.string("error"), swiftErrorOf { SyncKeyMaterial.keyring(material) }, case.label)
                assertEquals(case.string("error"), swiftErrorOf { SyncKeyMaterial.sealer(material) }, case.label)
                continue
            }
            val keyring = SyncKeyMaterial.keyring(material)
            assertContentEquals(case.bytes("keyHex"), keyring.libraryKey(), case.label)
            assertContentEquals(case.bytes("saltHex"), keyring.salt(), case.label)
            assertEquals(SyncKeyMaterial.SCOPE_ID, case.string("scopeID"), case.label)

            val envelope = SyncEnvelope.parse(utf8(case.string("envelopeCanonicalText")))
            assertContentEquals(case.bytes("recordKeyHex"), keyring.recordKey(envelope.id), case.label)

            val wire = case.obj("wire")
            val record = WireCodec.seal(envelope, SyncKeyMaterial.sealer(material, fixedNonce(case.bytes("nonceHex"))))
            assertEquals(wire.string("id"), Uuids.lowercase(record.id), case.label)
            assertEquals(wire.string("rev"), record.rev, case.label)
            assertEquals(wire.boolean("deleted"), record.deleted, case.label)
            assertEquals(wire.string("blobText"), String(record.blob, Charsets.US_ASCII), case.label)

            // Open direction, with a sealer made from the material alone.
            val swiftRecord = WireRecord(record.id, wire.string("rev"), wire.boolean("deleted"), utf8(wire.string("blobText")))
            assertEquals(envelope, WireCodec.open(swiftRecord, SyncKeyMaterial.sealer(material)), case.label)
            split += 1
        }
        assertEquals(7, cases.size)
        assertEquals(3, split)
    }

    // V19

    @Test fun v19EncodesTheKeyBundleToSwiftsBytes() {
        val cases = SwiftVectors.cases("V19-portable-key-bundle", "encode")
        var encoded = 0
        for (case in cases) {
            val material = case.bytes("materialHex")
            if (case.has("error")) {
                assertEquals(case.string("error"), swiftErrorOf { PortableKeyBundle(material) }, case.label)
                continue
            }
            val bundle = PortableKeyBundle(material)
            val json = bundle.jsonData()
            assertContentEquals(utf8(case.string("jsonText")), case.bytes("jsonHex"), "${case.label}: text and hex")
            assertEquals(case.string("jsonHex"), Bytes.toHex(json), case.label)
            // And back.
            val reread = PortableKeyBundle.fromJson(json)
            assertContentEquals(material, reread.material(), case.label)
            assertEquals(bundle, reread, case.label)
            assertEquals(1, reread.schemaVersion)
            assertEquals("sync-v1", reread.scopeId)
            encoded += 1
        }
        assertEquals(7, cases.size)
        assertEquals(4, encoded)
    }

    @Test fun v19ReadsTheKeyBundleAsStrictlyAsSwiftDoes() {
        val cases = SwiftVectors.cases("V19-portable-key-bundle", "parse")
        var read = 0
        for (case in cases) {
            val json = utf8(case.string("jsonText"))
            assertEquals(case.int("jsonByteCount"), json.size, "${case.label}: the vector's own byte count")
            if (case.has("ok")) {
                assertEquals(case.string("ok"), Bytes.toHex(PortableKeyBundle.fromJson(json).material()), case.label)
                read += 1
            } else {
                assertEquals(case.string("error"), swiftErrorOf { PortableKeyBundle.fromJson(json) }, case.label)
            }
        }
        assertEquals(13, cases.size)
        assertEquals(3, read)
    }

    // Reading a V11 envelope description

    /** The envelope a device would build locally from the members the vector lists. */
    private fun envelopeFrom(expected: SwiftVectors.Case): SyncEnvelope {
        val fields = if (expected.isNull("fields")) {
            null
        } else {
            val listed = expected.obj("fields")
            SyncEnvelope.Fields(
                name = listed.string("name"), keyword = listed.string("keyword"),
                content = listed.bytes("contentHex"), tags = listed.strings("tags"),
                isEnabled = listed.boolean("isEnabled"), isPinned = listed.boolean("isPinned"),
                createdAt = listed.double("createdAt"), updatedAt = listed.double("updatedAt"),
            )
        }
        return SyncEnvelope(
            schemaVersion = expected.int("schemaVersion").toLong(),
            id = Uuids.parseLowercase(expected.string("id"))!!,
            hlc = Hlc.parse(expected.string("hlc"))!!,
            origin = expected.string("origin"),
            secure = expected.boolean("secure"),
            deleted = expected.boolean("deleted"),
            fields = fields,
            x = typedValue(expected.element("x")).objectOrNull!!,
        )
    }

    /** Canonical bytes, hash preimage, hash, `rev` and `contentHash`, against the vector. */
    private fun assertExpected(label: String, expected: SwiftVectors.Case, envelope: SyncEnvelope) {
        assertEquals(expected.string("canonicalHex"), Bytes.toHex(envelope.canonicalBytes()), "$label: canonical bytes")
        assertEquals(
            expected.string("hashPreimageHex"),
            Bytes.toHex(CanonicalJson.encode(envelope.canonicalValue(includingHash = false))),
            "$label: hash preimage",
        )
        assertContentEquals(
            utf8(expected.string("hashPreimageText")), expected.bytes("hashPreimageHex"), "$label: preimage text and hex",
        )
        assertEquals(expected.string("envelopeHash"), envelope.envelopeHash(), "$label: hash")
        assertEquals(
            expected.string("envelopeHash"), SyncEnvelope.sha256Hex(expected.bytes("hashPreimageHex")), "$label: hash of the preimage",
        )
        assertEquals(expected.string("rev"), PassthroughSealer().revisionToken(envelope.envelopeHash()), "$label: rev")
        assertEquals(expected.stringOrNull("contentHash"), envelope.contentHash, "$label: contentHash")
        assertEquals(
            expected.string("xCanonical"), CanonicalJson.encodeToString(JsonValue.Object(envelope.x)), "$label: x",
        )
    }

    /** Every member the vector lists, against the envelope, spelling for spelling. */
    private fun assertMembers(label: String, expected: SwiftVectors.Case, envelope: SyncEnvelope) {
        assertEquals(expected.int("schemaVersion").toLong(), envelope.schemaVersion, label)
        assertEquals(expected.string("id"), Uuids.lowercase(envelope.id), label)
        assertEquals(expected.string("hlc"), envelope.hlc.string, label)
        assertEquals(expected.string("origin"), envelope.origin, label)
        assertEquals(expected.boolean("secure"), envelope.secure, label)
        assertEquals(expected.boolean("deleted"), envelope.deleted, label)
        assertEquals(typedValue(expected.element("x")).objectOrNull!!, envelope.x, label)
        if (expected.isNull("fields")) {
            assertNull(envelope.fields, label)
            assertTrue(envelope.deleted, label)
            return
        }
        val listed = expected.obj("fields")
        val fields = assertNotNull(envelope.fields, label)
        assertEquals(listed.string("name"), fields.name, label)
        assertEquals(listed.string("keyword"), fields.keyword, label)
        assertEquals(listed.string("contentHex"), Bytes.toHex(fields.content), label)
        assertContentEquals(utf8(listed.string("contentText")), fields.content, "$label: content text and hex")
        assertEquals(listed.strings("tags"), fields.tags, label)
        assertEquals(listed.boolean("isEnabled"), fields.isEnabled, label)
        assertEquals(listed.boolean("isPinned"), fields.isPinned, label)
        assertEquals(listed.double("createdAt").toRawBits(), fields.createdAt.toRawBits(), label)
        assertEquals(listed.double("updatedAt").toRawBits(), fields.updatedAt.toRawBits(), label)
    }

    /** The tool's typed tree: `{"t": <type>, "v": …}`, with keys and strings given as UTF-8 hex. */
    private fun typedValue(element: JsonElement): JsonValue {
        val node = element.jsonObject
        return when (val type = node.getValue("t").jsonPrimitive.content) {
            "null" -> JsonValue.Null
            "bool" -> JsonValue.of(node.getValue("v").jsonPrimitive.boolean)
            "int" -> JsonValue.of(node.getValue("v").jsonPrimitive.content.toLong())
            "double" -> JsonValue.of(SwiftVectors.Case.double(element))
            "string" -> JsonValue.Utf8(unhex(node.getValue("utf8Hex").jsonPrimitive.content))
            "array" -> JsonValue.Array(node.getValue("v").jsonArray.map(::typedValue))
            "object" -> {
                val members = LinkedHashMap<String, JsonValue>()
                for (member in node.getValue("v").jsonArray) {
                    val key = String(unhex(member.jsonObject.getValue("kHex").jsonPrimitive.content), Charsets.UTF_8)
                    members[key] = typedValue(member.jsonObject.getValue("v"))
                }
                JsonValue.Object(members)
            }
            else -> error("unknown typed value \"$type\"")
        }
    }
}
