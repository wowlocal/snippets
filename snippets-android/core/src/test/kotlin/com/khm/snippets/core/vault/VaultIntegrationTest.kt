package com.khm.snippets.core.vault

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Fixtures
import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.RecoveryKey
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.wire.SnippetCryptoSealer
import com.khm.snippets.core.wire.SyncEnvelope
import com.khm.snippets.core.wire.WireCodec
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import java.nio.file.Files
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The parts of `Tests/Core/VaultIntegrationTests.swift` that need `VaultDocument` and
 * `VaultFile`, plus its two wire tests (the wrap-only parts are in `crypto.KeyWrapTest`),
 * and the independent Linux fixtures read as vault documents
 * (`snippets-linux/src/vault.rs`: `ciphertext_fixture_uses_iso_dates_and_round_trips_unknown_fields`).
 */
class VaultIntegrationTest {

    private val vaultKid = "k-7f3a91c0"

    /** Cheap enough to run in every test; the pinned 600 000 is covered by the fixtures below. */
    private val fastIterations = 2_000L

    /** Everything the app holds after a vault is created, built the way the app must build it. */
    private inner class NewVault(passphrase: String) {
        val keyring = SnippetCrypto.Keyring.generate()
        val recoveryKey = RecoveryKey.generate()
        val cliSecret = SnippetCrypto.randomBytes(32)
        private val passphraseWrap =
            PassphraseKdf.wrap(keyring.libraryKey(), passphrase, PassphraseKdf.makeSalt(), vaultKid, fastIterations)

        var document = VaultDocument(
            kid = vaultKid,
            // base64url, from the crypto layer's own encoder, so the two cannot disagree.
            vaultSalt = Base64Url.encode(keyring.salt()),
            // Derived from the wrap rather than restated, so `alg` cannot drift.
            kdf = VaultKdfParameters.of(passphraseWrap),
            wrapPass = passphraseWrap.envelope,
            wrapRecovery = KeyWrap.wrap(keyring.libraryKey(), recoveryKey, KeyWrap.Purpose.RECOVERY, vaultKid, keyring.salt()),
            wrapCLI = KeyWrap.wrap(keyring.libraryKey(), cliSecret, KeyWrap.Purpose.CLI, vaultKid, keyring.salt()),
        )
    }

    private fun contains(haystack: ByteArray, needle: ByteArray): Boolean {
        if (needle.isEmpty()) return true
        outer@ for (start in 0..haystack.size - needle.size) {
            for (offset in needle.indices) if (haystack[start + offset] != needle[offset]) continue@outer
            return true
        }
        return false
    }

    /** A vault built through the public API must open with the passphrase that built it. */
    @Test fun avaultBuiltThroughThePublicAPIUnlocksWithItsOwnPassphrase() {
        val vault = NewVault("correct horse battery staple")

        val recovered = PassphraseKdf.unwrap(
            assertNotNull(vault.document.passphraseWrap), "correct horse battery staple", vault.document.kid,
        )

        assertContentEquals(vault.keyring.libraryKey(), recovered)
        assertEquals(PassphraseKdf.ALGORITHM, vault.document.kdf.alg)
        // Without a passphrase wrap there is nothing to stitch together.
        assertEquals(null, vault.document.copy(wrapPass = null).passphraseWrap)
    }

    /** The salts travel as base64url, the only spelling the crypto layer decodes. */
    @Test fun thesaltsRoundTripThroughTheEncodingTheCryptoLayerActuallyAccepts() {
        val vault = NewVault("p")

        val saltBack = assertNotNull(vault.document.vaultSaltBytes, "vaultSalt must be base64url")
        assertContentEquals(vault.keyring.salt(), saltBack)
        assertEquals(PassphraseKdf.SALT_BYTE_COUNT, assertNotNull(Base64Url.decode(vault.document.kdf.saltP)).size)
        for (salt in listOf(vault.document.vaultSalt, vault.document.kdf.saltP)) {
            assertFalse(salt.contains("=") || salt.contains("+") || salt.contains("/"))
        }
        // A standard-base64 salt is not a salt: `null`, never an empty array a caller could derive under.
        assertEquals(null, vault.document.copy(vaultSalt = "c2FsdA==").vaultSaltBytes)
    }

    /** The whole trip: seal a body, put it in a record, write the file, read it back, unlock, get the bytes out. */
    @Test fun asecretSurvivesTheFullRoundTripThroughTheRealFile() {
        val scratch = Scratch("roundtrip")
        try {
            val vault = NewVault("correct horse")
            val recordId = UUID.randomUUID()
            val plaintext = "hunter2".toByteArray()
            val context = SnippetCrypto.RecordContext("scope-a", recordId)
            val created = EPOCH

            vault.document = vault.document.copy(
                records = listOf(
                    VaultRecord(
                        id = recordId, name = "AWS root password", keyword = "awsroot", tags = listOf("work"),
                        isEnabled = true, isPinned = false, createdAt = created, updatedAt = created,
                        hlc = Hlc.of(1_785_312_000_000, 0, "aabbccdd"),
                        contentHash = SnippetCrypto.contentHash(plaintext, vault.keyring),
                        sealed = SnippetCrypto.seal(plaintext, context, vault.keyring),
                    ),
                ),
            )
            scratch.vaultFile().write(vault.document)

            // A cold start: nothing but the file and what the user can type.
            val loaded = assertNotNull(scratch.vaultFile().load().valueOrNull)
            val libraryKey = PassphraseKdf.unwrap(assertNotNull(loaded.passphraseWrap), "correct horse", loaded.kid)
            val keyring = SnippetCrypto.Keyring(libraryKey, assertNotNull(loaded.vaultSaltBytes))

            val record = assertNotNull(loaded.record(recordId))
            val opened = SnippetCrypto.open(record.sealed, context, keyring)

            assertContentEquals(plaintext, opened)
            assertEquals("hunter2", SnippetCrypto.plaintextString(opened))
            // Written by one keyring, verified by another rebuilt from the file.
            assertEquals(record.contentHash, SnippetCrypto.contentHash(opened, keyring))
        } finally {
            scratch.destroy()
        }
    }

    /** The file holds no plaintext of the secret and no plaintext of any key; the metadata deliberately is legible. */
    @Test fun nothingsecretIsLegibleInTheFileThatGetsBackedUp() {
        val scratch = Scratch("legible")
        try {
            val vault = NewVault("correct horse")
            val recordId = UUID.randomUUID()
            val plaintext = "swordfish-9134".toByteArray()

            vault.document = vault.document.copy(
                records = listOf(
                    VaultRecord(
                        id = recordId, name = "n", keyword = "k",
                        createdAt = -978_307_200.0, updatedAt = -978_307_200.0,
                        hlc = Hlc.of(0, 0, "aabbccdd"),
                        contentHash = SnippetCrypto.contentHash(plaintext, vault.keyring),
                        sealed = SnippetCrypto.seal(plaintext, SnippetCrypto.RecordContext("s", recordId), vault.keyring),
                    ),
                ),
            )
            scratch.vaultFile().write(vault.document)

            val bytes = Files.readAllBytes(scratch.vault.toPath())
            assertFalse(contains(bytes, plaintext))
            assertFalse(contains(bytes, vault.keyring.libraryKey()))
            assertFalse(contains(bytes, vault.recoveryKey))
            assertFalse(contains(bytes, vault.cliSecret))
            assertFalse(contains(bytes, "correct horse".toByteArray()))
            // No encoding of the key either.
            val text = String(bytes, Charsets.UTF_8)
            assertFalse(text.contains(Bytes.toHex(vault.keyring.libraryKey())))
            assertFalse(text.contains(Base64Url.encode(vault.keyring.libraryKey())))
            assertFalse(text.contains(RecoveryKey.encode(vault.recoveryKey)))

            // The disclosed leak, asserted rather than assumed.
            assertTrue(contains(bytes, "\"keyword\" : \"k\"".toByteArray()))
        } finally {
            scratch.destroy()
        }
    }

    /** A secure body sealed onto the wire comes back as a vault record, never as text for the plaintext library. */
    @Test fun asecurerecordSurvivesTheTripToTheWireAndBack() {
        val vault = NewVault("p")
        val sealer = SnippetCryptoSealer(vault.keyring, "scope-a")
        val plaintext = "one time code 819244".toByteArray()
        val created = 1_785_312_000.0 - 978_307_200.0

        val envelope = SyncEnvelope.secureRecord(
            id = UUID.randomUUID(), name = "OTP", keyword = "otp", plaintext = plaintext,
            createdAt = created, updatedAt = created,
            hlc = Hlc.of(1_785_312_000_000, 0, "aabbccdd"), origin = "aabbccdd",
        )

        val wire = WireCodec.seal(envelope, sealer)
        assertFalse(contains(wire.blob, plaintext))

        val reopened = WireCodec.open(wire, sealer)
        assertContentEquals(plaintext, reopened.plaintext)
        // The path that types ciphertext into a chat window starts with a secure body accepted as plain text.
        assertNull(reopened.plainSnippet)
        assertContentEquals(plaintext, assertNotNull(reopened.vaultFields).content)
    }

    /**
     * `VaultRecord.contentHash` is a keyed HMAC because it sits in `vault.json` in the
     * clear; the envelope's `contentHash` is a bare SHA-256 that only exists inside a
     * sealed blob. They must never be compared.
     */
    @Test fun thetwoContentHashesAreDeliberatelyDifferentValues() {
        val vault = NewVault("p")
        val plaintext = "the same body".toByteArray()
        val created = 1_785_312_000.0 - 978_307_200.0

        val vaultHash = SnippetCrypto.contentHash(plaintext, vault.keyring)
        val envelope = SyncEnvelope.secureRecord(
            id = UUID.randomUUID(), name = "n", keyword = "k", plaintext = plaintext,
            createdAt = created, updatedAt = created,
            hlc = Hlc.of(1, 0, "aabbccdd"), origin = "aabbccdd",
        )

        assertNotEquals(vaultHash, envelope.contentHash)
        assertEquals(vaultHash, SnippetCrypto.contentHash(plaintext, vault.keyring))
        assertEquals(SnippetCrypto.CONTENT_HASH_BYTE_COUNT * 2, vaultHash.length)
        assertEquals(64, envelope.contentHash?.length)
    }

    /** The dormant CLI wrap format, end to end through the document. */
    @Test fun anOptionalCLIWrapCanBeOpenedByItsSecretStoreMaterial() {
        val vault = NewVault("p")
        val recordId = UUID.randomUUID()
        val plaintext = "deploy-token-77".toByteArray()
        val context = SnippetCrypto.RecordContext("s", recordId)
        vault.document = vault.document.copy(
            records = listOf(
                VaultRecord(
                    id = recordId, name = "n", keyword = "k", createdAt = 0.0, updatedAt = 0.0,
                    hlc = Hlc.of(0, 0, "aabbccdd"),
                    contentHash = SnippetCrypto.contentHash(plaintext, vault.keyring),
                    sealed = SnippetCrypto.seal(plaintext, context, vault.keyring),
                ),
            ),
        )
        val decoded = VaultFile.decode(VaultFile.encode(vault.document))

        val salt = assertNotNull(decoded.vaultSaltBytes)
        val libraryKey = KeyWrap.unwrap(assertNotNull(decoded.wrapCLI), vault.cliSecret, KeyWrap.Purpose.CLI, decoded.kid, salt)
        val keyring = SnippetCrypto.Keyring(libraryKey, salt)

        assertContentEquals(plaintext, SnippetCrypto.open(assertNotNull(decoded.record(recordId)).sealed, context, keyring))
    }

    /** A vault written by this build, read by this build, byte-identical: long base64url strings survive the JSON round trip. */
    @Test fun arealvaultRoundTripsThroughTheFileByteForByte() {
        val scratch = Scratch("bytes")
        try {
            val vault = NewVault("p")
            val file = scratch.vaultFile()
            file.write(vault.document)
            val first = Files.readAllBytes(scratch.vault.toPath())

            val loaded = assertNotNull(file.load().valueOrNull)
            assertEquals(vault.document, loaded)

            file.write(loaded)
            assertContentEquals(first, Files.readAllBytes(scratch.vault.toPath()))
        } finally {
            scratch.destroy()
        }
    }

    // The independent fixtures (Python and OpenSSL), read as whole documents

    private fun fixtureDocumentBytes(name: String): Pair<JsonObject, ByteArray> {
        val fixture = Fixtures.linux(name)
        val document = fixture.getValue("document")
        return fixture to Json.encodeToString(kotlinx.serialization.json.JsonElement.serializer(), document).toByteArray()
    }

    /** `ciphertext_fixture_uses_iso_dates_and_round_trips_unknown_fields` */
    @Test fun ciphertextFixtureUsesIsoDatesAndRoundTripsUnknownFields() {
        for (name in listOf("crypto-v1.json", "restoration-current-vault-v1.json", "restoration-additional-vault-v1.json")) {
            val (fixture, bytes) = fixtureDocumentBytes(name)
            val document = VaultFile.decode(bytes)
            val raw = fixture.getValue("document").jsonObject

            assertEquals(1L, document.schemaVersion, name)
            assertEquals(raw.getValue("kid").jsonPrimitive.content, document.kid, name)
            assertEquals(PassphraseKdf.ITERATIONS, document.kdf.iterations, name)
            assertEquals(32, assertNotNull(document.vaultSaltBytes).size, name)
            assertEquals(null, document.wrapCLI, name)

            // 2026-09-30T10:00:00.000Z and 10:01:00.000Z, whole seconds: exact through the file.
            for (record in document.records) {
                assertEquals(812455200.0, record.createdAt, name)
                assertEquals(812455260.0, record.updatedAt, name)
                assertEquals("019f1a3d4880-0000-1234abcd", record.hlc.string, name)
            }

            // Unknown fields survive, at the document level here.
            val unknown = raw.keys - setOf("schemaVersion", "kid", "vaultSalt", "kdf", "wrapPass", "wrapRecovery", "wrapCLI", "records")
            assertEquals(unknown, document.x.keys, name)
            for (key in unknown) assertEquals(JsonValue.obj("enabled" to JsonValue.of(true)), document.x[key], name)

            // Every record opens under the fixture's root key and matches its keyed hash.
            val keyring = SnippetCrypto.Keyring(Bytes.fromHex(fixture.getValue("rootKeyHex").jsonPrimitive.content)!!, document.vaultSaltBytes!!)
            for (record in document.records) {
                val body = SnippetCrypto.open(record.sealed, SnippetCrypto.RecordContext(document.kid, record.id), keyring)
                assertEquals(record.contentHash, SnippetCrypto.contentHash(body, keyring), name)
            }
            assertEquals(
                fixture.getValue("plaintext").jsonPrimitive.content,
                SnippetCrypto.plaintextString(
                    SnippetCrypto.open(document.records[0].sealed, SnippetCrypto.RecordContext(document.kid, document.records[0].id), keyring),
                ),
                name,
            )

            // Both doors of the fixture open the same key, through the document's own accessors.
            val root = Bytes.fromHex(fixture.getValue("rootKeyHex").jsonPrimitive.content)!!
            val recoveryMaterial = Bytes.fromHex(fixture.getValue("recoveryMaterialHex").jsonPrimitive.content)!!
            assertContentEquals(
                root,
                KeyWrap.unwrap(document.wrapRecovery!!, recoveryMaterial, KeyWrap.Purpose.RECOVERY, document.kid, document.vaultSaltBytes!!),
                name,
            )
            assertContentEquals(
                root,
                PassphraseKdf.unwrap(document.passphraseWrap!!, fixture.getValue("passphrase").jsonPrimitive.content, document.kid),
                name,
            )

            // A decode and encode cycle is stable, and the result still decodes to the same document.
            val reencoded = VaultFile.encode(document)
            assertEquals(document, VaultFile.decode(reencoded), name)
            assertContentEquals(reencoded, VaultFile.encode(VaultFile.decode(reencoded)), name)
        }
    }

    /** `malformed_versions_types_duplicates_and_plaintext_escape_fail_closed`, as far as Swift is as strict as Linux. */
    @Test fun malformedVersionsAndTypesFailClosed() {
        val (_, bytes) = fixtureDocumentBytes("crypto-v1.json")
        val text = String(bytes, Charsets.UTF_8)

        for (damaged in listOf(
            text.replace("\"schemaVersion\":1", "\"schemaVersion\":\"1\""),
            text.replace("\"schemaVersion\":1", "\"schemaVersion\":1.5"),
            text.replace("\"kid\":\"public-interop-fixture\"", "\"kid\":7"),
            text.replace("\"iterations\":600000", "\"iterations\":\"many\""),
            text.replace("\"records\":[", "\"records\":{\"a\":["),
            text.replace("\"id\":\"00000000-0000-4000-8000-000000000001\"", "\"id\":\"1-1-1-1-1\""),
            text.dropLast(1),
            "[]",
            "null",
        )) {
            assertFailsWith<VaultDecodeException>(damaged.take(60)) { VaultFile.decode(damaged.toByteArray()) }
        }
        // A newer version decodes (reading is safe) but is refused by the loader and the writer.
        val newer = VaultFile.decode(text.replace("\"schemaVersion\":1", "\"schemaVersion\":2").toByteArray())
        assertEquals(2L, newer.schemaVersion)
    }
}
