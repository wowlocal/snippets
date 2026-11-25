package com.khm.snippets.core.crypto

import org.junit.Test
import java.util.Locale
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The wrap parts of `Tests/Core/VaultIntegrationTests.swift` (test names are the Swift
 * ones) and the known-answer literals of `Tests/Core/GitSyncVaultTests.swift:146-175`.
 * The parts of those suites that need `VaultDocument`, `VaultFile` or the wire come with
 * those types.
 */
class KeyWrapTest {

    private val vaultKid = "k-7f3a91c0"

    /** Cheap enough to run in every test; the pinned 600 000 is covered elsewhere. */
    private val fastIterations = 2_000L

    /** Everything the app holds after a vault is created, minus the document type that is not ported yet. */
    private class NewVault(passphrase: String, iterations: Long, kid: String) {
        val keyring = SnippetCrypto.Keyring.generate()
        val recoveryKey = RecoveryKey.generate()
        val cliSecret = SnippetCrypto.randomBytes(32)

        val passphraseWrap = PassphraseKdf.wrap(keyring.libraryKey(), passphrase, PassphraseKdf.makeSalt(), kid, iterations)

        /** base64url, from the crypto layer's own encoder, as `VaultDocument.vaultSalt` stores it. */
        val vaultSalt: String = Base64Url.encode(keyring.salt())
        val wrapRecovery = KeyWrap.wrap(keyring.libraryKey(), recoveryKey, KeyWrap.Purpose.RECOVERY, kid, keyring.salt())
        val wrapCli = KeyWrap.wrap(keyring.libraryKey(), cliSecret, KeyWrap.Purpose.CLI, kid, keyring.salt())

        val vaultSaltBytes: ByteArray get() = Base64Url.decode(vaultSalt)!!
    }

    private fun newVault(passphrase: String = "p") = NewVault(passphrase, fastIterations, vaultKid)

    // The two seams that were broken

    @Test fun avaultBuiltThroughThePublicAPIUnlocksWithItsOwnPassphrase() {
        val vault = newVault("correct horse battery staple")

        val recovered = PassphraseKdf.unwrap(vault.passphraseWrap, "correct horse battery staple", vaultKid)

        assertContentEquals(vault.keyring.libraryKey(), recovered)
        assertEquals(PassphraseKdf.ALGORITHM, vault.passphraseWrap.alg)
    }

    /** A 16-byte salt in standard base64 always ends `==`, which the crypto layer refuses. */
    @Test fun thesaltsRoundTripThroughTheEncodingTheCryptoLayerActuallyAccepts() {
        val vault = newVault()

        assertContentEquals(vault.keyring.salt(), vault.vaultSaltBytes)

        val kdfSalt = Base64Url.decode(vault.passphraseWrap.salt)!!
        assertEquals(PassphraseKdf.SALT_BYTE_COUNT, kdfSalt.size)

        for (salt in listOf(vault.vaultSalt, vault.passphraseWrap.salt)) {
            assertFalse(salt.contains("="))
            assertFalse(salt.contains("+"))
            assertFalse(salt.contains("/"))
        }
    }

    // All three doors

    /** Every door opens the same `K_lib`. */
    @Test fun allthreeDoorsRecoverTheIdenticalLibraryKey() {
        val vault = newVault()
        val expected = vault.keyring.libraryKey()
        val salt = vault.vaultSaltBytes

        assertContentEquals(expected, PassphraseKdf.unwrap(vault.passphraseWrap, "p", vaultKid))
        assertContentEquals(expected, KeyWrap.unwrap(vault.wrapRecovery, vault.recoveryKey, KeyWrap.Purpose.RECOVERY, vaultKid, salt))
        assertContentEquals(expected, KeyWrap.unwrap(vault.wrapCli, vault.cliSecret, KeyWrap.Purpose.CLI, vaultKid, salt))
    }

    @Test fun therecoveryDoorWorksFromTheFormOfTheKeyTheUserActuallyHas() {
        val vault = newVault()

        val printed = RecoveryKey.formatted(vault.recoveryKey)
        // Typed back in the way people actually type: lower case, spaces for dashes.
        val retyped = RecoveryKey.decode(printed.lowercase(Locale.ROOT).replace("-", " "))

        assertContentEquals(
            vault.keyring.libraryKey(),
            KeyWrap.unwrap(vault.wrapRecovery, retyped, KeyWrap.Purpose.RECOVERY, vaultKid, vault.vaultSaltBytes),
        )
    }

    /** Swapping the two wrap blobs must not work, or the weaker door becomes the only one that matters. */
    @Test fun awrapBlobCannotBeMovedFromOneDoorToTheOther() {
        val vault = newVault()
        val salt = vault.vaultSaltBytes

        assertEquals(KeyWrap.Purpose.RECOVERY, assertFailsWith<KeyWrap.Failure.WrongKey> {
            KeyWrap.unwrap(vault.wrapCli, vault.cliSecret, KeyWrap.Purpose.RECOVERY, vaultKid, salt)
        }.purpose)
        assertEquals(KeyWrap.Purpose.CLI, assertFailsWith<KeyWrap.Failure.WrongKey> {
            KeyWrap.unwrap(vault.wrapRecovery, vault.recoveryKey, KeyWrap.Purpose.CLI, vaultKid, salt)
        }.purpose)
    }

    /** Purpose separation is enforced twice; these two pin each binding with the other held constant. */
    @Test fun thepurposeBindsThroughTheAADEvenWhenTheWrappingKeyIsHeldConstant() {
        val material = RecoveryKey.generate()
        val salt = SnippetCrypto.randomBytes(SnippetCrypto.SALT_BYTE_COUNT)
        val key = KeyWrap.wrappingKey(material, KeyWrap.Purpose.RECOVERY, salt)
        val secret = SnippetCrypto.randomBytes(SnippetCrypto.KEY_BYTE_COUNT)

        val envelope = SnippetCrypto.seal(secret, key, KeyWrap.additionalData(KeyWrap.Purpose.RECOVERY, vaultKid))

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            SnippetCrypto.open(envelope, key, KeyWrap.additionalData(KeyWrap.Purpose.CLI, vaultKid))
        }
    }

    @Test fun thepurposeBindsThroughTheWrappingKeyEvenWhenTheAADIsHeldConstant() {
        val material = RecoveryKey.generate()
        val salt = SnippetCrypto.randomBytes(SnippetCrypto.SALT_BYTE_COUNT)
        val aad = KeyWrap.additionalData(KeyWrap.Purpose.RECOVERY, vaultKid)
        val secret = SnippetCrypto.randomBytes(SnippetCrypto.KEY_BYTE_COUNT)

        val recoveryWrappingKey = KeyWrap.wrappingKey(material, KeyWrap.Purpose.RECOVERY, salt)
        val cliWrappingKey = KeyWrap.wrappingKey(material, KeyWrap.Purpose.CLI, salt)
        assertFalse(recoveryWrappingKey.contentEquals(cliWrappingKey))

        val envelope = SnippetCrypto.seal(secret, recoveryWrappingKey, aad)

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(envelope, cliWrappingKey, aad) }
    }

    /** A blob left over from before a rekey fails at the door rather than unwrapping to a stale key. */
    @Test fun awrapFromAnotherVaultIsRefusedByAllThreeDoors() {
        val vault = newVault()
        val salt = vault.vaultSaltBytes
        val otherKid = "k-after-rekey"

        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> { PassphraseKdf.unwrap(vault.passphraseWrap, "p", otherKid) }
        assertFailsWith<KeyWrap.Failure.WrongKey> {
            KeyWrap.unwrap(vault.wrapRecovery, vault.recoveryKey, KeyWrap.Purpose.RECOVERY, otherKid, salt)
        }
        // The third door, which the Swift test leaves out.
        assertFailsWith<KeyWrap.Failure.WrongKey> {
            KeyWrap.unwrap(vault.wrapCli, vault.cliSecret, KeyWrap.Purpose.CLI, otherKid, salt)
        }
    }

    /** The salt is mixed in at HKDF, not only at the AAD. */
    @Test fun thesamerecoveryKeyAgainstAnotherVaultsSaltDoesNotOpenIt() {
        val vault = newVault()

        assertFailsWith<KeyWrap.Failure.WrongKey> {
            KeyWrap.unwrap(
                vault.wrapRecovery, vault.recoveryKey, KeyWrap.Purpose.RECOVERY, vaultKid,
                SnippetCrypto.randomBytes(SnippetCrypto.SALT_BYTE_COUNT),
            )
        }
    }

    /** `VaultIntegrationTests.asealedBodyCannotBeMovedOntoAnotherRecord`, without the document around it. */
    @Test fun asealedBodyCannotBeMovedOntoAnotherRecord() {
        val vault = newVault()
        val first = UUID.randomUUID()
        val second = UUID.randomUUID()
        val sealed = SnippetCrypto.seal(utf8("bank otp"), SnippetCrypto.RecordContext(vaultKid, first), vault.keyring)

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            SnippetCrypto.open(sealed, SnippetCrypto.RecordContext(vaultKid, second), vault.keyring)
        }
        assertContentEquals(utf8("bank otp"), SnippetCrypto.open(sealed, SnippetCrypto.RecordContext(vaultKid, first), vault.keyring))
    }

    // The optional CLI-wrap format

    /** Pins the dormant wrap format end to end: reserved, never written by a shipping path, but readable. */
    @Test fun anOptionalCLIWrapCanBeOpenedByItsSecretStoreMaterial() {
        val vault = newVault()
        val recordId = UUID.randomUUID()
        val plaintext = utf8("deploy-token-77")
        val context = SnippetCrypto.RecordContext(scopeId = "s", recordId = recordId)
        val sealed = SnippetCrypto.seal(plaintext, context, vault.keyring)

        val libraryKey = KeyWrap.unwrap(vault.wrapCli, vault.cliSecret, KeyWrap.Purpose.CLI, vaultKid, vault.vaultSaltBytes)
        val keyring = SnippetCrypto.Keyring(libraryKey, vault.vaultSaltBytes)

        assertContentEquals(plaintext, SnippetCrypto.open(sealed, context, keyring))
    }

    /** A stored secret is 32 bytes and a recovery key 16; both must clear the wrap's floor. */
    @Test fun thestoresSecretSizeIsAcceptableKeyMaterial() {
        assertTrue(32 >= KeyWrap.MINIMUM_MATERIAL_BYTE_COUNT)
        assertTrue(RecoveryKey.BYTE_COUNT >= KeyWrap.MINIMUM_MATERIAL_BYTE_COUNT)
        assertEquals(16, KeyWrap.MINIMUM_MATERIAL_BYTE_COUNT)
    }

    /** Passing something that is not key material, a UTF-8 passphrase most likely, must be refused. */
    @Test fun shortmaterialIsRefusedRatherThanQuietlyWrappingUnderIt() {
        assertEquals(6, assertFailsWith<KeyWrap.Failure.MaterialTooShort> {
            KeyWrap.wrap(
                Bytes.random(32), utf8("hunter"), KeyWrap.Purpose.RECOVERY, vaultKid,
                SnippetCrypto.randomBytes(SnippetCrypto.SALT_BYTE_COUNT),
            )
        }.count)
    }

    // GitSyncVaultTests.knownAnswerMatchesTheLinuxMirror, parts (a) and (b)

    /**
     * Fixed bytes shared with `snippets-linux` (`git_tests.rs`). The seal direction: with
     * the fixed nonce the whole envelope text must come out, which pins HKDF, the AAD, the
     * padding and AES-GCM for a 32-byte body in one comparison. Then the way a second
     * device uses it: the typed code unwraps the key.
     */
    @Test fun knownAnswerMatchesTheLinuxMirror() {
        val key = counting(0x80, 32)
        val salt = counting(0x40, 32)
        val secret = counting(0xa0, 16)
        val wrapNonce = counting(0x10, 12)

        assertEquals(GIT_VAULT_KNOWN_CODE, RecoveryKey.formatted(secret))

        val wrapRecovery = KeyWrap.wrap(key, secret, KeyWrap.Purpose.RECOVERY, GIT_VAULT_KNOWN_KID, salt, fixedNonce(wrapNonce))
        assertEquals(GIT_VAULT_KNOWN_WRAP, wrapRecovery)
        assertEquals(383, wrapRecovery.length)

        val unwrapped = KeyWrap.unwrap(
            GIT_VAULT_KNOWN_WRAP, RecoveryKey.decode(GIT_VAULT_KNOWN_CODE), KeyWrap.Purpose.RECOVERY, GIT_VAULT_KNOWN_KID, salt,
        )
        assertContentEquals(key, unwrapped)
    }

    /** `KeyWrap.wrap` with purpose `cli`, which no fixture anywhere pins, plus the keys and AADs underneath. */
    @Test fun bothPurposesMatchSwiftByteForByte() {
        val reference = SwiftReference.json
        val key = counting(0x80, 32)
        val salt = counting(0x40, 32)
        val nonces = fixedNonce(counting(0x10, 12))

        assertEquals(GIT_VAULT_KNOWN_WRAP, reference.string("wrapRecovery"))
        assertEquals(
            reference.string("wrapCLI"),
            KeyWrap.wrap(key, counting(0xd0, 32), KeyWrap.Purpose.CLI, GIT_VAULT_KNOWN_KID, salt, nonces),
        )
        assertContentEquals(
            key,
            KeyWrap.unwrap(reference.string("wrapCLI"), counting(0xd0, 32), KeyWrap.Purpose.CLI, GIT_VAULT_KNOWN_KID, salt),
        )

        assertEquals(reference.string("wrapKeyRecovery"), KeyWrap.wrappingKey(counting(0xa0, 16), KeyWrap.Purpose.RECOVERY, salt).hex())
        assertEquals(reference.string("wrapKeyCLI"), KeyWrap.wrappingKey(counting(0xa0, 16), KeyWrap.Purpose.CLI, salt).hex())
        assertEquals(reference.string("wrapAADRecovery"), KeyWrap.additionalData(KeyWrap.Purpose.RECOVERY, GIT_VAULT_KNOWN_KID).hex())
        // A non-ASCII kid is its UTF-8 bytes, length-prefixed in bytes and not in characters.
        assertEquals(reference.string("wrapAADCLI"), KeyWrap.additionalData(KeyWrap.Purpose.CLI, "k-\u00E9").hex())
    }

    // Added

    @Test fun theAADAndTheWrappingKeyAreTheDocumentedConstructions() {
        assertEquals(
            "0000000c" + utf8("snip.wrap.v1").hex() +
                "00000002" + utf8("v1").hex() +
                "00000008" + utf8("recovery").hex() +
                "00000006" + utf8("k-test").hex(),
            KeyWrap.additionalData(KeyWrap.Purpose.RECOVERY, "k-test").hex(),
        )
        val material = counting(1, 16)
        val salt = counting(2, 32)
        assertContentEquals(
            Hkdf.deriveKey(material, salt, utf8("snip.wrap.v1|recovery"), 32),
            KeyWrap.wrappingKey(material, KeyWrap.Purpose.RECOVERY, salt),
        )
        assertContentEquals(
            Hkdf.deriveKey(material, salt, utf8("snip.wrap.v1|cli"), 32),
            KeyWrap.wrappingKey(material, KeyWrap.Purpose.CLI, salt),
        )
        assertEquals(listOf("recovery", "cli"), KeyWrap.Purpose.values().map { it.rawValue })
    }

    @Test fun theLimitsAndTheErrorTaxonomyAreExactlySwifts() {
        val key = Bytes.random(32)
        val material = Bytes.random(16)
        val salt = Bytes.random(32)

        assertEquals(15, assertFailsWith<KeyWrap.Failure.MaterialTooShort> {
            KeyWrap.wrappingKey(ByteArray(15), KeyWrap.Purpose.RECOVERY, salt)
        }.count)
        assertEquals("empty salt", assertFailsWith<KeyWrap.Failure.InvalidParameters> {
            KeyWrap.wrappingKey(material, KeyWrap.Purpose.RECOVERY, ByteArray(0))
        }.detail)
        // Swift accepts any non-empty salt at this layer (16 bytes appears in its fixtures).
        assertEquals(32, KeyWrap.wrappingKey(material, KeyWrap.Purpose.RECOVERY, ByteArray(1)).size)
        assertEquals(31, assertFailsWith<SnippetCrypto.Failure.WrongKeySize> {
            KeyWrap.wrap(ByteArray(31), material, KeyWrap.Purpose.RECOVERY, "k", salt)
        }.count)
        // The key size is judged before the material, as in Swift.
        assertFailsWith<SnippetCrypto.Failure.WrongKeySize> { KeyWrap.wrap(ByteArray(31), ByteArray(3), KeyWrap.Purpose.RECOVERY, "k", salt) }

        val wrapped = KeyWrap.wrap(key, material, KeyWrap.Purpose.RECOVERY, "k", salt)
        // Wrong material is the user's mistake…
        assertFailsWith<KeyWrap.Failure.WrongKey> { KeyWrap.unwrap(wrapped, Bytes.random(16), KeyWrap.Purpose.RECOVERY, "k", salt) }
        // …a truncated or foreign blob is not, and keeps its own error.
        assertFailsWith<SnippetCrypto.Failure.MalformedEnvelope> { KeyWrap.unwrap(wrapped.take(5), material, KeyWrap.Purpose.RECOVERY, "k", salt) }
        assertFailsWith<SnippetCrypto.Failure.MalformedEnvelope> { KeyWrap.unwrap("v1.notanenvelope", material, KeyWrap.Purpose.RECOVERY, "k", salt) }
        assertFailsWith<SnippetCrypto.Failure.UnsupportedWireVersion> { KeyWrap.unwrap(rebuilt(wrapped, version = "v2"), material, KeyWrap.Purpose.RECOVERY, "k", salt) }
        assertFailsWith<KeyWrap.Failure.WrongKey> { KeyWrap.unwrap(rebuilt(wrapped, sealed = ::flippingFirstBit), material, KeyWrap.Purpose.RECOVERY, "k", salt) }
        assertFailsWith<KeyWrap.Failure.WrongKey> { KeyWrap.unwrap(rebuilt(wrapped, nonce = ::flippingFirstBit), material, KeyWrap.Purpose.RECOVERY, "k", salt) }
        assertFailsWith<KeyWrap.Failure.MaterialTooShort> { KeyWrap.unwrap(wrapped, ByteArray(8), KeyWrap.Purpose.RECOVERY, "k", salt) }

        // A tag that verifies over something that is not a 32-byte key.
        val wrapping = KeyWrap.wrappingKey(material, KeyWrap.Purpose.RECOVERY, salt)
        val odd = SnippetCrypto.seal(ByteArray(33), wrapping, KeyWrap.additionalData(KeyWrap.Purpose.RECOVERY, "k"))
        assertEquals("wrapped key is 33 bytes", assertFailsWith<KeyWrap.Failure.InvalidParameters> {
            KeyWrap.unwrap(odd, material, KeyWrap.Purpose.RECOVERY, "k", salt)
        }.detail)
    }

    /** Material longer than the floor is used whole: a 32-byte secret is not truncated to 16. */
    @Test fun longerMaterialIsUsedInFull() {
        val key = Bytes.random(32)
        val salt = Bytes.random(32)
        val material = counting(0, 32)
        val wrapped = KeyWrap.wrap(key, material, KeyWrap.Purpose.CLI, "k", salt)
        assertFailsWith<KeyWrap.Failure.WrongKey> { KeyWrap.unwrap(wrapped, material.copyOf(16), KeyWrap.Purpose.CLI, "k", salt) }
        assertContentEquals(key, KeyWrap.unwrap(wrapped, material, KeyWrap.Purpose.CLI, "k", salt))
    }

    companion object {
        const val GIT_VAULT_KNOWN_KID = "k-0f1e2d3c-4b5"
        const val GIT_VAULT_KNOWN_CODE = "M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ"
        const val GIT_VAULT_KNOWN_WRAP =
            "v1.EBESExQVFhcYGRob.qUF4uXZngBvzSRgme_SKaRQDkG-x67b2_sbB8MU6aK6jjnoZqp7TQGXxuoj-7Mf_Vz_Yw697Ajxzygx1rVrF-Qy0RkQqGDiLVfEUNhedNvQr4o0l6Q_9hWxHiaxMkenw9HpreSqCE93FTxFr8siez0bnIPGvOCsVY8L7R_C2o7fEWIPVMRV1cDmXepTFGsf4lp_Wi8yAe4z0o7SwO_sLbuVXooNbn_3VVHyYWsgr6wtdsJC5ZJu5o3BJlNInXj08zidXd8pPj6sJoF8XHX9Y9BDxZ_XgUIkmK2DB_jyi7cIXTNJsEo0ApPvCQOrZTLYLgfRs7tia7CFlrLJrUHHluOjnQOHfRlRfZYN8y6MBqUU"

        /** `knownCiphertext` of the same Swift test: the `keys/vault.json` body, used here only as base64 test data. */
        const val GIT_VAULT_KNOWN_CIPHERTEXT =
            "ICEiIyQlJicoKSorul4Dv23bwTOhvOYKTu1b+0rWFeE2UdslKKtfLiTwkw4Q/aNUqUeyELUg84tqzJwhiQQlOtY9MBswBrDtosF2sCT2cE0McqvKBXTN9ppi/ZtjnlfXiG3yNd2DBGJHKMBCzoAf3Pipt/jhmrui2oUL6JFhWQR/tbcoC1kgdISIQO7tlMHMvClol2oPGArvEFk+GhHYVhdoIuGG/kO9Vt29GSbUq6wFi7YBXf4uZPMOeQP6OZh5mNLcY8nKqqnGPibPYxjKHXQ14Pl++Yhwzq3T612lwlt6hPHQSWnUChK9/8/W3SsYa+ulItytSDrG0rGWT01u8AdipQ9qG3OIlz3D/KlUJKrOhfgKpIGooirpC7+IhGqTisPc2koF9Lo3EC3WFlHNXGj/cUHXHkYIrM3OvtwfY4fxpMqaWzDyy4nd8xGOQhRK9KCCvkbian9NMKi/doF8+Yq3sokaNyOz5ixd80mYT47c4v2Kg9d/hURNrpDBgub2NbenZQsoyMvTmoelRgxST4VtNF8WAlkA9GRYDST6oXRrNkzqSo3tVMgkHIt8uxT5uZyYGksiiroicR3GbZ1qBd48/waDrljrtld4LODOWlrrAs90TOTcKAqiyPWPEWLrsO1ASsFdpeuNVZpuwd3GH8q5ySIKqJe9rP5ISGb3LR/osq3EshxTrRwwBPGfAJ9eEaGT85wpsiJfvd60bTh5VCAVnLNNCL47xkI/Drtv9PhBA4YDeCYS5BNUfGTGPYEs10IQhlnN9snawHg13t1hvxpO2ONSHVw1s+7afsptDD9Jrb6XixZsJx0="
    }
}
