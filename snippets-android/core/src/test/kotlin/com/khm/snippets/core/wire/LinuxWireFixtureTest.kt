package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.wire.WireFixtures.bytes
import com.khm.snippets.core.wire.WireFixtures.canonicalObject
import com.khm.snippets.core.wire.WireFixtures.filled
import com.khm.snippets.core.wire.WireFixtures.unhex
import com.khm.snippets.core.wire.WireFixtures.utf8
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The four tests of `snippets-linux/src/wire.rs`, and its fixture
 * `sync-wire-v1.json` (copied byte for byte into `fixtures/linux/`), which was produced
 * with OpenSSL and the Swift double formatter independently of both ports.
 *
 * Two Rust behaviours have no counterpart in Swift's wire layer and are adapted, not
 * ported: the 674 815-byte plaintext ceiling (Swift's is `SyncMerge.maximumWireCanonicalBytes`,
 * in the merge layer), and `tombstone(explicit: true)`, which Swift's journal does by
 * setting `userDeletion.v1` on the tombstone.
 */
class LinuxWireFixtureTest {

    private fun linux(name: String): JsonObject {
        val stream = javaClass.getResourceAsStream("/fixtures/linux/$name") ?: error("missing fixture $name")
        return stream.bufferedReader(Charsets.UTF_8).use { Json.parseToJsonElement(it.readText()) }.jsonObject
    }

    private fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.content

    private fun envelope(): SyncEnvelope = SyncEnvelope.plain(
        Snippet(
            id = UUID(0, 1), name = "Public fixture", keyword = "", content = "Fictional 🦀\n",
            createdAt = -0.0, updatedAt = 812_578_800.123456,
        ),
        hlc = Hlc.parse("019f1a3d4880-0000-1234abcd")!!,
        origin = "1234abcd",
    )

    private fun sealer(key: Int, salt: Int): SnippetCryptoSealer =
        SnippetCryptoSealer(SnippetCrypto.Keyring(filled(key, 32), filled(salt, 32)), SyncKeyMaterial.SCOPE_ID)

    @Test fun ciphertextAuthenticatesIdentityRevisionDeletionAndKeyWithoutExposingVault() {
        val root = sealer(0x11, 0x22)
        val envelope = envelope()
        val wire = WireCodec.seal(envelope, root)
        val opened = WireCodec.open(wire, root)
        assertContentEquals(envelope.canonicalBytes(), opened.canonicalBytes())
        assertEquals((-0.0).toRawBits(), opened.fields!!.createdAt.toRawBits())

        val lastButOne = wire.blobByteCount - 2
        val changed = listOf(
            wire.copy(id = UUID(0, 2)),
            wire.copy(rev = "f".repeat(32)),
            wire.copy(deleted = true),
            wire.copy(blob = wire.blob.also { it[lastButOne] = (it[lastButOne].toInt() xor 1).toByte() }),
        )
        for ((which, record) in changed.withIndex()) {
            assertFailsWith<Exception>("change $which") { WireCodec.open(record, root) }
        }
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { WireCodec.open(wire, sealer(0x33, 0x22)) }
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { WireCodec.open(wire, sealer(0x11, 0x44)) }
    }

    @Test fun deletionRemovesFieldsAndHashAndUnknownExtensionsRoundTrip() {
        val envelope = envelope().withExtension("future", CanonicalJson.parse(utf8("{\"v\":[1,1.0,\"é\"]}")))
        val encoded = envelope.canonicalBytes()
        assertContentEquals(encoded, SyncEnvelope.parse(encoded).canonicalBytes())
        assertTrue(String(encoded, Charsets.UTF_8).contains("\"x\":{\"future\":{\"v\":[1,1.0,\"é\"]}}"))

        // An explicit deletion: Swift's journal stamps the tombstone with the live hash.
        val deleted = envelope.tombstoned(envelope.hlc, "1234abcd").withExtension(
            SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY, JsonValue.array(JsonValue.of(envelope.envelopeHash())),
        )
        val deletedBytes = deleted.canonicalBytes()
        val members = CanonicalJson.parse(deletedBytes).objectOrNull!!
        assertTrue(members.getValue("fields").isNull)
        assertTrue(members.getValue("contentHash").isNull)
        val parsed = SyncEnvelope.parse(deletedBytes)
        assertTrue(parsed.deleted)
        assertEquals(setOf(envelope.envelopeHash()), parsed.userInitiatedDeletionAncestorHashes)
        assertEquals(setOf(SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY), parsed.x.keys, "the unknown extension is gone")

        // A tombstone cannot be made to carry fields: the constructor drops them (Rust refuses to encode).
        val bad = SyncEnvelope(
            id = deleted.id, hlc = deleted.hlc, origin = deleted.origin, secure = false, deleted = true,
            fields = envelope.fields,
        )
        assertNull(bad.fields)
        assertTrue(canonicalObject(bad).getValue("fields").isNull)

        val unexpected = LinkedHashMap(members)
        unexpected["unexpected"] = JsonValue.of(true)
        assertFailsWith<SyncEnvelope.Failure.Malformed> { SyncEnvelope.parse(bytes(unexpected)) }
    }

    @Test fun wireBudgetSupportsSecureCiphertextAndTheBlobHasTheSizeRustPins() {
        val keyring = SnippetCrypto.Keyring(filled(0x11, 32), filled(0x22, 32))
        val wireSealer = SnippetCryptoSealer(keyring, SyncKeyMaterial.SCOPE_ID)
        val id = UUID(0, 1)
        val identity = WireIdentity(id, "0".repeat(32), deleted = false)

        // `SyncMerge.maximumWireCanonicalBytes` / Rust `MAX_WIRE_PLAINTEXT`.
        val plaintext = filled('x'.code, 674_815)
        val sealed = wireSealer.seal(plaintext, identity)
        assertEquals(899_796, sealed.size)
        assertContentEquals(plaintext, wireSealer.open(sealed, identity))
        // One more byte takes a whole further padding block of 256 bytes (Rust refuses it; in
        // Swift that is the merge layer's check).
        assertEquals(900_138, wireSealer.seal(filled('x'.code, 674_816), identity).size)

        // A vault body is sealed under the vault's kid and never opens as a wire blob.
        val vault = SnippetCrypto.seal(
            utf8("Fictional secret"), SnippetCrypto.RecordContext("public-vault", id), keyring,
        )
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { wireSealer.open(utf8(vault), identity) }
    }

    @Test fun independentOpensslAndSwiftFormatterFixtureMatchesBothLayers() {
        val fixture = linux("sync-wire-v1.json")
        val sealer = SnippetCryptoSealer(
            SnippetCrypto.Keyring(unhex(fixture.text("rootKeyHex")), unhex(fixture.text("saltHex"))),
            SyncKeyMaterial.SCOPE_ID,
        )
        val records = fixture.getValue("records").jsonArray.map { it.jsonObject }
        assertEquals(2, records.size)
        var secureRecords = 0

        for (record in records) {
            val wireJson = record.getValue("wire").jsonObject
            val wire = WireRecord(
                id = Uuids.parseLowercase(wireJson.text("id"))!!,
                rev = wireJson.text("rev"),
                deleted = wireJson.getValue("deleted").jsonPrimitive.boolean,
                blob = Base64Std.decodeCanonical(wireJson.text("blob"))!!,
            )
            val canonical = utf8(record.text("canonical"))

            // Open direction.
            val envelope = WireCodec.open(wire, sealer)
            assertContentEquals(canonical, envelope.canonicalBytes())
            assertEquals(record.text("hash"), envelope.envelopeHash())
            assertEquals(record.getValue("secure").jsonPrimitive.boolean, envelope.secure)
            assertEquals(record.text("hash").take(32), wire.rev)

            // Seal direction, with the fixture's own nonce: the same blob, byte for byte.
            val nonce = Base64Url.decode(String(wire.blob, Charsets.US_ASCII).split('.')[1])!!
            val resealed = WireCodec.seal(
                SyncEnvelope.parse(canonical),
                SnippetCryptoSealer(sealer.keyring, SyncKeyMaterial.SCOPE_ID, WireFixtures.fixedNonce(nonce)),
            )
            assertEquals(wire, resealed)

            // The unknown `x` members, doubles included, survive in the spelling Swift gives them.
            val numbers = assertNotNull(envelope.x["numbers"]?.arrayOrNull)
            assertEquals(
                "[9007199254740992.0,9.007199254740994e+15,0.0001,1e-05]",
                CanonicalJson.encodeToString(JsonValue.Array(numbers)),
            )
            assertEquals((-0.0).toRawBits(), envelope.fields!!.createdAt.toRawBits())

            if (!envelope.secure) {
                val snippet = assertNotNull(envelope.plainSnippet)
                assertEquals("Fictional ordinary 🦀\n", snippet.content)
                continue
            }
            secureRecords += 1
            assertNull(envelope.plainSnippet)

            // The body is the vault's sealed text, verbatim, and opens under the vault's key and kid.
            val vault = linux("crypto-v1.json")
            val document = vault.getValue("document").jsonObject
            val sealedText = document.getValue("records").jsonArray[0].jsonObject.text("sealed")
            assertContentEquals(utf8(sealedText), envelope.fields!!.content)
            assertEquals(document.text("kid"), envelope.x[SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY]?.textOrNull)
            assertEquals("public-interop-fixture", document.text("kid"))
            val vaultKeyring = SnippetCrypto.Keyring(
                unhex(vault.text("rootKeyHex")), Base64Url.decode(document.text("vaultSalt"))!!,
            )
            assertContentEquals(filled(0x11, 32), vaultKeyring.libraryKey())
            assertContentEquals(filled(0x22, 32), vaultKeyring.salt())
            val body = SnippetCrypto.open(
                String(envelope.fields!!.content, Charsets.US_ASCII),
                SnippetCrypto.RecordContext("public-interop-fixture", envelope.id),
                vaultKeyring,
            )
            assertContentEquals(utf8(vault.text("plaintext")), body)
            // The top-level contentHash is the SHA-256 of the sealed text, never the vault's keyed hash.
            assertEquals(SyncEnvelope.sha256Hex(utf8(sealedText)), envelope.contentHash)
            assertEquals(
                SnippetCrypto.contentHash(body, vaultKeyring),
                envelope.x[SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY]?.textOrNull,
            )

            // A tombstone keeps `vaultKID` and nothing else; an explicit one adds the deletion marker.
            val deleted = envelope.tombstoned(envelope.hlc, "1234abcd")
            assertEquals(setOf(SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY), deleted.x.keys)
            val explicit = deleted.withExtension(
                SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY,
                JsonValue.array(JsonValue.of(envelope.envelopeHash())),
            )
            assertEquals(
                setOf(SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY, SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY),
                SyncEnvelope.parse(explicit.canonicalBytes()).x.keys,
            )
        }
        assertEquals(1, secureRecords)
    }
}
