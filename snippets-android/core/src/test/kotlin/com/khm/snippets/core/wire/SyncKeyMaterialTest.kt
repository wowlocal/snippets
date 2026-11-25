package com.khm.snippets.core.wire

import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.wire.WireFixtures.clock
import com.khm.snippets.core.wire.WireFixtures.filled
import com.khm.snippets.core.wire.WireFixtures.snippet
import com.khm.snippets.core.wire.WireFixtures.utf8
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * The split of the 64-byte `K_sync` material and the portable key bundle, beyond what the
 * Swift vectors V18 and V19 pin (`SwiftWireVectorsTest`).
 */
class SyncKeyMaterialTest {

    private fun material(): ByteArray = ByteArray(64) { it.toByte() }

    private val bundleJson =
        "{\"key\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\"," +
            "\"salt\":\"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=\",\"schemaVersion\":1,\"scopeID\":\"sync-v1\"}"

    // The split

    @Test fun theFirstHalfIsTheKeyAndTheSecondTheSalt() {
        val keyring = SyncKeyMaterial.keyring(material())
        assertContentEquals(ByteArray(32) { it.toByte() }, keyring.libraryKey())
        assertContentEquals(ByteArray(32) { (32 + it).toByte() }, keyring.salt())
        assertEquals(64, SyncKeyMaterial.MATERIAL_BYTE_COUNT)
        assertEquals("sync-v1", SyncKeyMaterial.SCOPE_ID)
    }

    @Test fun theKeyringHoldsCopiesAndLeavesTheMaterialAlone() {
        val source = material()
        val keyring = SyncKeyMaterial.keyring(source)
        assertContentEquals(material(), source, "the caller's array is not modified")
        source.fill(0)
        assertContentEquals(ByteArray(32) { it.toByte() }, keyring.libraryKey())
    }

    @Test fun anyOtherLengthIsRefusedWithTheCount() {
        for (count in listOf(0, 1, 31, 32, 33, 63, 65, 96, 128)) {
            val failure = assertFailsWith<SyncKeyMaterial.MalformedMaterial>("$count bytes") {
                SyncKeyMaterial.keyring(ByteArray(count))
            }
            assertEquals(count, failure.count)
            assertEquals("the stored sync key must be 64 bytes; found $count", failure.message)
            assertFailsWith<SyncKeyMaterial.MalformedMaterial> { SyncKeyMaterial.sealer(ByteArray(count)) }
        }
    }

    /** Hazard H11: a wire blob is bound to `sync-v1`, a vault body to the vault's kid. Neither opens as the other. */
    @Test fun theWireSealerIsBoundToTheSyncScopeAndNoOther() {
        val sealer = SyncKeyMaterial.sealer(material())
        assertEquals("sync-v1", sealer.scopeId)
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = WireFixtures.THIS_DEVICE)
        val record = WireCodec.seal(envelope, sealer)
        assertEquals(envelope, WireCodec.open(record, SyncKeyMaterial.sealer(material())))

        val sameKeyOtherScope = SnippetCryptoSealer(SyncKeyMaterial.keyring(material()), "k-7f3a91c0-1b2")
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { WireCodec.open(record, sameKeyOtherScope) }
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            WireCodec.open(WireCodec.seal(envelope, sameKeyOtherScope), sealer)
        }

        // The key half and the salt half both matter, and swapping them is another key.
        val otherKey = material().also { it[0] = 1 }
        val otherSalt = material().also { it[63] = 0 }
        val swapped = material().copyOfRange(32, 64) + material().copyOfRange(0, 32)
        for (other in listOf(otherKey, otherSalt, swapped)) {
            assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
                WireCodec.open(record, SyncKeyMaterial.sealer(other))
            }
        }
        // Nothing of the key in a description.
        assertFalse(sealer.toString().contains("0001"))
    }

    // The bundle

    @Test fun theBundleWritesExactlySwiftsBytes() {
        val bundle = PortableKeyBundle(material())
        assertEquals(bundleJson, String(bundle.jsonData(), Charsets.UTF_8))
        assertContentEquals(material(), bundle.material())
        assertEquals(1, bundle.schemaVersion)
        assertEquals("sync-v1", bundle.scopeId)
        // Slashes and plus signs are standard base64 and are not escaped.
        val slashes = String(PortableKeyBundle(filled(0xFB, 32) + filled(0xFF, 32)).jsonData(), Charsets.UTF_8)
        assertTrue(slashes.contains("\"key\":\"+/v7+/v7"), slashes)
        assertFalse(slashes.contains("\\/"))
    }

    @Test fun theBundleFeedsTheKeyring() {
        val bundle = PortableKeyBundle.fromJson(utf8(bundleJson))
        val keyring = SyncKeyMaterial.keyring(bundle.material())
        assertContentEquals(ByteArray(32) { it.toByte() }, keyring.libraryKey())
        assertContentEquals(ByteArray(32) { (32 + it).toByte() }, keyring.salt())
    }

    @Test fun aBundleIsBuiltOnlyFromSixtyFourBytesOfTheSyncScope() {
        for (count in listOf(0, 32, 63, 65)) {
            assertFailsWith<PortableKeyBundle.Failure.InvalidFormat>("$count bytes") { PortableKeyBundle(ByteArray(count)) }
        }
        assertFailsWith<PortableKeyBundle.Failure.InvalidFormat> { PortableKeyBundle(material(), scopeId = "sync-v2") }
        assertFailsWith<PortableKeyBundle.Failure.InvalidFormat> { PortableKeyBundle(material(), scopeId = "") }
        assertEquals(PortableKeyBundle(material()), PortableKeyBundle(material(), scopeId = "sync-v1"))
    }

    @Test fun theReaderAcceptsAnyKeyOrderAndWhitespaceAndNothingElse() {
        fun read(text: String) = PortableKeyBundle.fromJson(utf8(text))
        val key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
        val salt = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="
        fun json(
            keyValue: String = "\"$key\"", saltValue: String = "\"$salt\"",
            version: String = "1", scope: String = "\"sync-v1\"", extra: String = "",
        ) = "{\"scopeID\":$scope, \"salt\":$saltValue,\n\"key\":$keyValue,\t\"schemaVersion\":$version$extra}"

        assertContentEquals(material(), read(json()).material())
        assertContentEquals(material(), read(json(version = "1.0")).material())
        assertContentEquals(material(), read(json(version = "1e0")).material())
        assertContentEquals(material(), read(" ${json()} \n").material())

        val invalidFormat = listOf(
            json(extra = ",\"extra\":1"),
            json(extra = ",\"x\":null"),
            "{\"key\":\"$key\",\"schemaVersion\":1,\"scopeID\":\"sync-v1\"}",
            "{}",
            "[]",
            json(version = "2"), json(version = "0"), json(version = "-1"), json(version = "2.0"),
            json(scope = "\"sync-v2\""), json(scope = "\"SYNC-V1\""), json(scope = "\"\""),
            json(keyValue = "\"\""),
            json(keyValue = "\"${key.dropLast(1)}\""),                          // unpadded
            json(keyValue = "\"${key.replace('+', '-').replace('/', '_').dropLast(1)}\""),   // base64url
            json(keyValue = "\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh9=\""), // trailing bits
            json(keyValue = "\"$key\\n\""),                                     // a line break
            json(keyValue = "\" $key\""),
            json(keyValue = "\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHg==\""), // 31 bytes
            json(keyValue = "\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g\""), // 33 bytes
            json(saltValue = "\"${salt.dropLast(1)}\""),
            json(saltValue = "\"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pg==\""),
            json(saltValue = "\"!!!!\""),
        )
        for ((index, text) in invalidFormat.withIndex()) {
            assertFailsWith<PortableKeyBundle.Failure.InvalidFormat>("input $index") { read(text) }
        }

        val undecodable = listOf(
            "", "bundle", "\"bundle\"", "1", "null", "{", json().dropLast(1),
            json(version = "\"1\""), json(version = "1.5"), json(version = "null"), json(version = "true"),
            json(version = "9223372036854775808"),
            json(scope = "1"), json(scope = "null"),
            json(keyValue = "null"), json(keyValue = "1"), json(keyValue = "[\"$key\"]"),
            json(saltValue = "null"), json(saltValue = "{}"),
            // Stricter than Foundation: a duplicate key is refused before it can shadow anything.
            json(extra = ",\"key\":\"$key\""),
        )
        for ((index, text) in undecodable.withIndex()) {
            assertFailsWith<PortableKeyBundle.Failure.Undecodable>("input $index") { read(text) }
        }
    }

    @Test fun theReaderRefusesMoreThanTwoThousandAndFortyEightBytesBeforeParsing() {
        val exactly = bundleJson + " ".repeat(2_048 - bundleJson.length)
        assertEquals(2_048, exactly.length)
        assertContentEquals(material(), PortableKeyBundle.fromJson(utf8(exactly)).material())
        assertFailsWith<PortableKeyBundle.Failure.InvalidFormat> { PortableKeyBundle.fromJson(utf8("$exactly ")) }
        // The size is judged first: even input that is not JSON is "invalid format" when too long.
        assertFailsWith<PortableKeyBundle.Failure.InvalidFormat> { PortableKeyBundle.fromJson(ByteArray(2_049) { 'x'.code.toByte() }) }
    }

    @Test fun aBundleIsAValueThatDoesNotShowItsKey() {
        val bundle = PortableKeyBundle(material())
        assertEquals(bundle, PortableKeyBundle(material()))
        assertEquals(bundle.hashCode(), PortableKeyBundle(material()).hashCode())
        assertNotEquals(bundle, PortableKeyBundle(material().also { it[5] = 0 }))
        assertEquals("PortableKeyBundle(redacted)", bundle.toString())

        // The arrays it hands out are copies, and `close` wipes what it holds.
        bundle.material().fill(0)
        bundle.jsonData().fill(0)
        assertContentEquals(material(), bundle.material())
        bundle.close()
        assertContentEquals(ByteArray(64), bundle.material())
    }
}
