package com.khm.snippets.core.crypto

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * The independent fixtures of `snippets-linux/tests/fixtures/` (generated with Python and
 * OpenSSL, not with Swift, Rust or this code) and the tests of `snippets-linux/src/crypto.rs`
 * that read them. Rust test names are kept in the method names.
 */
class CryptoFixtureTest {

    private class Vault(val fixture: JsonObject) {
        val document: JsonObject = fixture.obj("document")
        val kid: String = document.string("kid")
        val root: ByteArray = unhex(fixture.string("rootKeyHex"))
        val salt: ByteArray = Base64Url.decode(document.string("vaultSalt"))!!
        val keyring = SnippetCrypto.Keyring(root, salt)
        val recoveryMaterial: ByteArray = unhex(fixture.string("recoveryMaterialHex"))
        val passphrase: String = fixture.string("passphrase")
        val wrappedKey = PassphraseKdf.WrappedKey(
            alg = document.obj("kdf").string("alg"),
            iterations = document.obj("kdf").long("iterations"),
            salt = document.obj("kdf").string("saltP"),
            envelope = document.string("wrapPass"),
        )
        val wrapRecovery: String = document.string("wrapRecovery")
        val records: List<JsonObject> = document.array("records").map { it.jsonObject }
    }

    private val crypto = Vault(Fixtures.linux("crypto-v1.json"))

    // crypto.rs

    /** `independent_openssl_fixture_matches_key_hierarchy_aad_and_padding` */
    @Test fun independentOpensslFixtureMatchesKeyHierarchyAadAndPadding() {
        val record = crypto.records[0]
        assertContentEquals(filled(0x11, 32), crypto.root)
        assertContentEquals(filled(0x22, 32), crypto.salt)
        assertEquals("public-interop-fixture", crypto.kid)

        val id = Uuids.parseLowercase(record.string("id"))!!
        val context = SnippetCrypto.RecordContext(crypto.kid, id)
        val body = SnippetCrypto.open(record.string("sealed"), context, crypto.keyring)

        assertEquals(crypto.fixture.string("plaintext"), SnippetCrypto.plaintextString(body))
        assertContentEquals(utf8("Fictional secret 🦀\n"), body)
        assertEquals(record.string("contentHash"), SnippetCrypto.contentHash(body, crypto.keyring))
        assertEquals("9536abd4a3609b9f098e9e2d91a42622", SnippetCrypto.contentHash(body, crypto.keyring))
    }

    /** The same vector in the seal direction: the fixture's nonce (`0x44` × 12) must reproduce its envelope. */
    @Test fun theFixtureRecordSealsToTheSameEnvelopeText() {
        val record = crypto.records[0]
        val sealed = record.string("sealed")
        assertContentEquals(filled(0x44, 12), SealedEnvelope.parse(sealed).nonce)

        val context = SnippetCrypto.RecordContext(crypto.kid, Uuids.parse(record.string("id"))!!)
        assertEquals(sealed, SnippetCrypto.seal(utf8(crypto.fixture.string("plaintext")), context, crypto.keyring, nonceOf(sealed)))
    }

    /** `envelope_authenticates_id_scope_deletion_flag_key_and_salt` */
    @Test fun envelopeAuthenticatesIdScopeDeletionFlagKeyAndSalt() {
        val root = Bytes.random(32)
        val id = UUID.randomUUID()
        val salt = filled(0x22, 32)
        val ring = SnippetCrypto.Keyring(root, salt)
        val sealed = SnippetCrypto.seal(utf8("Fictional secret"), SnippetCrypto.RecordContext("fixture", id), ring)

        fun refused(context: SnippetCrypto.RecordContext, keyring: SnippetCrypto.Keyring, envelope: String = sealed) {
            assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(envelope, context, keyring) }
        }
        refused(SnippetCrypto.RecordContext("other", id), ring)
        refused(SnippetCrypto.RecordContext("fixture", UUID.randomUUID()), ring)
        refused(SnippetCrypto.RecordContext("fixture", id, isDeleted = true), ring)
        refused(SnippetCrypto.RecordContext("fixture", id), SnippetCrypto.Keyring(Bytes.random(32), salt))
        refused(SnippetCrypto.RecordContext("fixture", id), SnippetCrypto.Keyring(root, filled(0x23, 32)))
        refused(SnippetCrypto.RecordContext("fixture", id), ring, rebuilt(sealed, sealed = { it[20] = (it[20].toInt() xor 1).toByte() }))
        refused(SnippetCrypto.RecordContext("fixture", id), ring, rebuilt(sealed, nonce = ::flippingFirstBit))
        assertContentEquals(utf8("Fictional secret"), SnippetCrypto.open(sealed, SnippetCrypto.RecordContext("fixture", id), ring))
    }

    /**
     * `padding_preserves_empty_full_block_and_trailing_zero_data_with_fresh_nonces`.
     * The Rust sealer also refuses a body over 256 KiB. Swift's `SnippetCrypto` has no
     * ceiling, so there is none here to test.
     */
    @Test fun paddingPreservesEmptyFullBlockAndTrailingZeroDataWithFreshNonces() {
        val ring = SnippetCrypto.Keyring(Bytes.random(32), filled(1, 32))
        val context = SnippetCrypto.RecordContext("fixture", UUID.randomUUID())
        for (length in listOf(0, 1, 255, 256, 257, 256 * 1024)) {
            val body = ByteArray(length)
            val first = SnippetCrypto.seal(body, context, ring)
            val second = SnippetCrypto.seal(body, context, ring)
            assertNotEquals(first, second)
            assertContentEquals(body, SnippetCrypto.open(first, context, ring), "length $length")
            assertEquals(0, (SealedEnvelope.parse(first).sealed.size - 16) % 256)
        }
    }

    /**
     * `noncanonical_encodings_and_unbounded_or_unknown_envelopes_are_refused`.
     * Two differences from Rust, both where Swift is the authority: `Zh` (non-zero unused
     * bits) decodes in Swift, and `Sealed::parse` in Rust also judges the version and the
     * block structure, which in Swift is `open`'s job. The envelope outcomes are therefore
     * checked through `open`.
     */
    @Test fun noncanonicalEncodingsAndUnboundedOrUnknownEnvelopesAreRefused() {
        for (text in listOf("Zg==", "AA+_", "", "x")) assertTrue(Base64Url.decode(text) == null, text)
        assertEquals("66", Base64Url.decode("Zh")!!.hex())   // Swift accepts; Rust refuses

        val key = Bytes.random(32)
        assertFailsWith<SnippetCrypto.Failure.UnsupportedWireVersion> { SnippetCrypto.open("v2.AAAA.AAAA", key, ByteArray(0)) }
        for (text in listOf("v1.AAAA.AAAA", "v1..", "v1.a.b.c")) {
            assertFailsWith<SnippetCrypto.Failure.MalformedEnvelope>(text) { SnippetCrypto.open(text, key, ByteArray(0)) }
        }
    }

    /** `passphrase_normalization_parameters_and_scope_match_the_independent_fixture` (600 000 rounds). */
    @Test fun passphraseNormalizationParametersAndScopeMatchTheIndependentFixture() {
        assertEquals(600_000L, crypto.wrappedKey.iterations)
        assertContentEquals(filled(0x55, 16), Base64Url.decode(crypto.wrappedKey.salt))
        assertEquals("Caf\u00E9 public fixture", crypto.passphrase)

        // The fixture was sealed from the precomposed spelling; it must open from the decomposed one.
        val key = PassphraseKdf.unwrap(crypto.wrappedKey, "Cafe\u0301 public fixture", crypto.kid)
        assertContentEquals(filled(0x11, 32), key)

        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> {
            PassphraseKdf.unwrap(crypto.wrappedKey, "Wrong public fixture", crypto.kid)
        }
        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> {
            PassphraseKdf.unwrap(crypto.wrappedKey, "Caf\u00E9 public fixture", "other")
        }
        for (iterations in listOf(0L, 20_000_001L)) {
            assertFailsWith<PassphraseKdf.Failure.InvalidParameters>("$iterations") {
                PassphraseKdf.unwrap(crypto.wrappedKey.copy(iterations = iterations), "Caf\u00E9 public fixture", crypto.kid)
            }
        }
        assertFailsWith<PassphraseKdf.Failure.EmptyPassphrase> { PassphraseKdf.derive("", filled(1, 16), 1) }
        // Rust also caps a passphrase at 4 KiB. Swift has no cap, so a long one derives.
        assertEquals(32, PassphraseKdf.derive("x".repeat(4097), filled(1, 16), 1).size)
    }

    /** The passphrase wrap in the seal direction, through both PBKDF2 implementations (nonce `0x33` × 12). */
    @Test fun theFixturePassphraseWrapIsReproducedByBothPbkdf2Implementations() {
        assertContentEquals(filled(0x33, 12), SealedEnvelope.parse(crypto.wrappedKey.envelope).nonce)
        for (pbkdf2 in listOf(MacPbkdf2HmacSha512, JcaPbkdf2HmacSha512)) {
            val wrapped = PassphraseKdf.wrap(
                key = crypto.root,
                passphrase = "Cafe\u0301 public fixture",      // NFD-typed
                salt = filled(0x55, 16),
                kid = crypto.kid,
                nonces = nonceOf(crypto.wrappedKey.envelope),
                pbkdf2 = pbkdf2,
            )
            assertEquals(crypto.wrappedKey, wrapped)
        }
    }

    /** `recovery_wrap_and_every_single_symbol_transcription_are_checked` */
    @Test fun recoveryWrapAndEverySingleSymbolTranscriptionAreChecked() {
        assertContentEquals(filled(0x66, 16), crypto.recoveryMaterial)
        val root = KeyWrap.unwrap(crypto.wrapRecovery, filled(0x66, 16), KeyWrap.Purpose.RECOVERY, crypto.kid, crypto.salt)
        assertContentEquals(filled(0x11, 32), root)
        assertFailsWith<KeyWrap.Failure.WrongKey> {
            KeyWrap.unwrap(crypto.wrapRecovery, filled(0x67, 16), KeyWrap.Purpose.RECOVERY, crypto.kid, crypto.salt)
        }
        // Seal direction (nonce `0x77` × 12).
        assertContentEquals(filled(0x77, 12), SealedEnvelope.parse(crypto.wrapRecovery).nonce)
        assertEquals(
            crypto.wrapRecovery,
            KeyWrap.wrap(crypto.root, filled(0x66, 16), KeyWrap.Purpose.RECOVERY, crypto.kid, crypto.salt, nonceOf(crypto.wrapRecovery)),
        )

        for (material in listOf(ByteArray(16), filled(0xff, 16), filled(0x66, 16))) {
            val formatted = RecoveryKey.formatted(material)
            assertContentEquals(material, RecoveryKey.decode(formatted))
            val alias = formatted.lowercase().replace('0', 'O').replace("1", "l").replace('-', '\u2011')
            assertContentEquals(material, RecoveryKey.decode(alias))
            val original = formatted.replace("-", "")
            for (index in 0 until 27) {
                for (symbol in RecoveryKey.ALPHABET) {
                    if (symbol == original[index]) continue
                    val changed = StringBuilder(original).also { it.setCharAt(index, symbol) }.toString()
                    assertFailsWith<RecoveryKey.Failure>("$changed at $index") { RecoveryKey.decode(changed) }
                }
            }
        }
    }

    // The two restoration fixtures: more independent vaults with 600 000-round wraps.

    @Test fun theRestorationVaultsOpenAndResealByteForByte() {
        val expectedSalts = mapOf(
            "restoration-current-vault-v1.json" to 0x55,
            "restoration-additional-vault-v1.json" to 0x88,
        )
        for ((name, saltByte) in expectedSalts) {
            val vault = Vault(Fixtures.linux(name))
            assertContentEquals(filled(saltByte, 32), vault.salt, name)

            // Recovery door, both directions.
            val viaRecovery = KeyWrap.unwrap(vault.wrapRecovery, vault.recoveryMaterial, KeyWrap.Purpose.RECOVERY, vault.kid, vault.salt)
            assertContentEquals(vault.root, viaRecovery, name)
            assertEquals(
                vault.wrapRecovery,
                KeyWrap.wrap(vault.root, vault.recoveryMaterial, KeyWrap.Purpose.RECOVERY, vault.kid, vault.salt, nonceOf(vault.wrapRecovery)),
                name,
            )

            // Passphrase door at the production cost, opened with the decomposed spelling.
            assertTrue(vault.passphrase.startsWith("Caf\u00E9"), name)
            val decomposed = vault.passphrase.replace("\u00E9", "e\u0301")
            assertContentEquals(vault.root, PassphraseKdf.unwrap(vault.wrappedKey, decomposed, vault.kid), name)
            assertEquals(
                vault.wrappedKey,
                PassphraseKdf.wrap(
                    vault.root, vault.passphrase, Base64Url.decode(vault.wrappedKey.salt)!!, vault.kid,
                    vault.wrappedKey.iterations, nonceOf(vault.wrappedKey.envelope),
                ),
                name,
            )

            // Every record opens under the vault's own scope, hashes to its stored value, and reseals identically.
            for (record in vault.records) {
                val context = SnippetCrypto.RecordContext(vault.kid, Uuids.parseLowercase(record.string("id"))!!)
                val sealed = record.string("sealed")
                val body = SnippetCrypto.open(sealed, context, vault.keyring)
                assertEquals(record.string("contentHash"), SnippetCrypto.contentHash(body, vault.keyring), name)
                assertEquals(sealed, SnippetCrypto.seal(body, context, vault.keyring, nonceOf(sealed)), name)
            }
            val first = vault.records.first { it.string("contentHash") in setOf("ebde54873db0cbc9d04c37fd941ef76f", "369d7b8de6de423ae4f5551a057adbe1") }
            val context = SnippetCrypto.RecordContext(vault.kid, Uuids.parseLowercase(first.string("id"))!!)
            assertEquals(vault.fixture.string("plaintext"), SnippetCrypto.plaintextString(SnippetCrypto.open(first.string("sealed"), context, vault.keyring)))
        }
    }

    /** The additional fixture's backup container: a passphrase wrap whose `kid` is the backup id. */
    @Test fun theBackupContainersPassphraseWrapOpensWithTheBackupIdAsItsScope() {
        val fixture = Fixtures.linux("restoration-additional-vault-v1.json")
        val container = fixture.obj("container")
        val wrappedKey = container.obj("wrappedKey")
        val wrapped = PassphraseKdf.WrappedKey(
            alg = wrappedKey.string("alg"),
            iterations = wrappedKey.long("iterations"),
            salt = wrappedKey.string("salt"),
            envelope = wrappedKey.string("envelope"),
        )
        val backupId = container.string("backupID")
        val password = fixture.string("backupPassword")

        val exportKey = PassphraseKdf.unwrap(wrapped, password, backupId)
        assertContentEquals(filled(0x15, 32), exportKey)
        assertEquals(wrapped, PassphraseKdf.wrap(exportKey, password, filled(0x16, 16), backupId, nonces = nonceOf(wrapped.envelope)))
        // Bound to the backup id, not to the vault's kid.
        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> {
            PassphraseKdf.unwrap(wrapped, password, fixture.obj("document").string("kid"))
        }
        // The vault passphrase of the same fixture is another secret.
        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> {
            PassphraseKdf.unwrap(wrapped, fixture.string("passphrase"), backupId)
        }
    }

    // The same formats, from the Swift sources themselves.

    private val reference = SwiftReference.json
    private val referenceRing = SnippetCrypto.Keyring(counting(0x01, 32), counting(0x61, 32))
    private val referenceId = UUID.fromString("0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9")
    private val live = SnippetCrypto.RecordContext("k-0f1e2d3c-4b5", referenceId)
    private val dead = SnippetCrypto.RecordContext("sync-v1", referenceId, isDeleted = true)

    /** `SnippetCrypto.additionalData` for a live vault context and a deleted wire context. */
    @Test fun theRecordAADMatchesSwiftForALiveAndADeletedContext() {
        assertEquals(reference.string("aadLive"), SnippetCrypto.additionalData(live).hex())
        assertEquals(reference.string("aadDeleted"), SnippetCrypto.additionalData(dead).hex())
    }

    /** `Keyring.recordKey` and `contentHashKey` raw bytes. */
    @Test fun theDerivedKeysMatchSwift() {
        assertEquals(reference.string("recordKey"), referenceRing.recordKey(referenceId).hex())
        assertEquals(reference.string("contentHashKey"), referenceRing.contentHashKey().hex())
        // The id's case in text does not matter: the key takes its 16 bytes.
        assertEquals(reference.string("recordKey"), referenceRing.recordKey(Uuids.parse("0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9")!!).hex())
    }

    /**
     * `SnippetCrypto.seal(_:for:keyring:nonces:)` in the seal direction at the padding
     * boundaries. Body byte `i` is `(7i + 3) mod 256`; the nonce for case `n` is
     * `0x30 + n, 0x31 + n, …`. The two short envelopes are compared as text, the longer
     * ones by length and SHA-256 of the text.
     */
    @Test fun sealingAtEveryPaddingBoundaryIsByteIdenticalToSwift() {
        val lengths = listOf(0, 1, 255, 256, 257, 1000)
        val cases = reference.array("seals")
        assertEquals(lengths.size, cases.size)
        for ((index, case) in cases.withIndex()) {
            val length = case.string("length").toInt()
            assertEquals(lengths[index], length)
            val body = ByteArray(length) { (it * 7 + 3).toByte() }
            val nonce = counting(case.string("nonceStart").toInt(), 12)

            val text = SnippetCrypto.seal(body, live, referenceRing, fixedNonce(nonce))

            assertEquals(case.string("chars").toInt(), text.length, "length $length")
            assertEquals(case.string("sha256"), sha256Hex(utf8(text)), "length $length")
            if (case.string("text").isNotEmpty()) assertEquals(case.string("text"), text)
            assertEquals(case.string("contentHash"), SnippetCrypto.contentHash(body, referenceRing), "length $length")
            assertContentEquals(body, SnippetCrypto.open(text, live, referenceRing))
        }
        assertTrue(cases.count { it.string("text").isNotEmpty() } == 2)
    }

    /** A multi-byte UTF-8 body sealed as a tombstone-flagged wire record. */
    @Test fun aMultiByteBodyUnderADeletedWireContextMatchesSwift() {
        val body = utf8("caf\u00E9 ☕\uFE0F \u2014 na\u00EFve 🔐 \uD83C\uDDEF\uD83C\uDDF5")
        val expected = reference.string("sealUTF8")
        assertEquals(expected, SnippetCrypto.seal(body, dead, referenceRing, fixedNonce(counting(0x70, 12))))
        assertContentEquals(body, SnippetCrypto.open(expected, dead, referenceRing))
        assertEquals(reference.string("contentHashUTF8"), SnippetCrypto.contentHash(body, referenceRing))
        // The same ciphertext under the live flag or the vault scope is not this record.
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(expected, dead.copy(isDeleted = false), referenceRing) }
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(expected, live, referenceRing) }
        assertFalse(expected == SnippetCrypto.seal(body, live, referenceRing, fixedNonce(counting(0x70, 12))))
    }
}

class DeterministicUuidTest {

    /** The RFC 4122 construction with SHA-1, checked against Python's `uuid.uuid5`. */
    @Test fun theStandardNamespaceExamplesHold() {
        val dns = UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        assertEquals("2ed6657d-e927-568b-95e1-2665a8aea6a2", DeterministicUuid.make(dns, "www.example.com").toString())
        assertEquals("886313e1-3b8a-5372-9b90-0c9aee199e5d", DeterministicUuid.make(dns, "python.org").toString())
    }

    /** `merge-v1.json`: the conflict copy id is `v5(sourceID, "sync-content-conflict-v1|" + fingerprint)`. */
    @Test fun theConflictCopyIdOfTheMergeFixtureIsReproduced() {
        val fixture = Fixtures.linux("merge-v1.json")
        val source = UUID.fromString("00000000-0000-4000-8000-000000000021")
        val name = "sync-content-conflict-v1|" + fixture.string("fingerprint")
        assertEquals(fixture.string("copyID"), DeterministicUuid.make(source, name).toString())
    }

    /** `SyncMerge.deterministicUUID` itself: a non-ASCII name and the empty name. */
    @Test fun theResultMatchesSwift() {
        val expected = SwiftReference.json.array("uuid5").map { it.toString().trim('"') }
        val id = UUID.fromString("0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9")
        val dns = UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        assertEquals(expected[0], DeterministicUuid.make(dns, "www.example.com").toString())
        assertEquals(expected[1], DeterministicUuid.make(id, "conflict|naïve 🔐 body|1234567890123").toString())
        assertEquals(expected[2], DeterministicUuid.make(id, "").toString())
    }

    /** The `deterministic-uuid` cases of the golden vector `V13-secure-conflict` (the rest of that file belongs to the merge). */
    @Test fun v13DeterministicUuidCasesOfTheSwiftVectors() {
        val cases = SwiftVectors.sealed("V13-secure-conflict").filter { it.string("kind") == "deterministic-uuid" }
        assertEquals(5, cases.size)
        for (case in cases) {
            val namespace = Uuids.parseLowercase(case.string("namespace"))!!
            assertEquals(case.string("uuid"), Uuids.lowercase(DeterministicUuid.make(namespace, case.exactText("uuidName"))), case.string("name"))
        }
    }

    @Test fun theVersionAndVariantBitsAreSetAndTheResultIsStable() {
        val random = SeededRandom(0x5EED)
        repeat(200) { round ->
            val namespace = Uuids.fromBytes(random.bytes(16))
            val made = DeterministicUuid.make(namespace, "name $round")
            assertEquals(5, made.version())
            assertEquals(2, made.variant())
            assertEquals(made, DeterministicUuid.make(namespace, "name $round"))
            assertNotEquals(made, DeterministicUuid.make(namespace, "name ${round + 1}"))
            assertNotEquals(made, DeterministicUuid.make(Uuids.fromBytes(random.bytes(16)), "name $round"))
        }
    }

    /** `UUID.nameUUIDFromBytes` is MD5 and version 3: not the same function. */
    @Test fun itIsNotThePlatformsNameBasedUuid() {
        val dns = UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        val platform = UUID.nameUUIDFromBytes(Uuids.toBytes(dns) + utf8("www.example.com"))
        assertEquals(3, platform.version())
        assertNotEquals(platform, DeterministicUuid.make(dns, "www.example.com"))
    }
}
