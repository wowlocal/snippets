package com.khm.snippets.core.crypto

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** `Tests/Core/CryptoTests.swift`, suite 8 "Passphrase wrapping". Test names are the Swift ones. */
class PassphraseKdfTest {

    /** A cheap count for the tests that are about behaviour. The pinned 600 000 is exercised once, below. */
    private val fastIterations = 2_000L
    private val salt = filled(0x5E, PassphraseKdf.SALT_BYTE_COUNT)
    private val kid = "k-test"

    private fun newKey(): ByteArray = Bytes.random(SnippetCrypto.KEY_BYTE_COUNT)

    private fun wrap(key: ByteArray, passphrase: String, salt: ByteArray = this.salt) =
        PassphraseKdf.wrap(key, passphrase, salt, kid, fastIterations)

    /** The number is a shipped security parameter, not a tuning knob. */
    @Test fun theIterationCountAndAlgorithmAreThePinnedOnes() {
        assertEquals(600_000L, PassphraseKdf.ITERATIONS)
        assertEquals("pbkdf2-hmac-sha512", PassphraseKdf.ALGORITHM)
    }

    @Test fun wrappingAndUnwrappingRecoversTheExactLibraryKey() {
        val libraryKey = newKey()
        val wrapped = wrap(libraryKey, "correct horse battery staple")

        val recovered = PassphraseKdf.unwrap(wrapped, "correct horse battery staple", kid)

        assertContentEquals(libraryKey, recovered)
    }

    /** At full strength, once, so the pinned parameters are known to work end to end. */
    @Test fun wrappingAndUnwrappingWorksAtThePinnedIterationCount() {
        val libraryKey = newKey()
        val wrapped = PassphraseKdf.wrap(libraryKey, "a real passphrase", salt, kid)

        assertEquals(PassphraseKdf.ITERATIONS, wrapped.iterations)
        assertContentEquals(libraryKey, PassphraseKdf.unwrap(wrapped, "a real passphrase", kid))
    }

    /** A wrong passphrase must throw, never return plausible-looking bytes. */
    @Test fun awrongPassphraseThrowsRatherThanReturningGarbageBytes() {
        val wrapped = wrap(newKey(), "the right one")

        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> { PassphraseKdf.unwrap(wrapped, "the wrong one", kid) }
        // The near misses a case-folding or trimming bug would let through.
        for (nearMiss in listOf("The right one", "the right one ", "the right on", "therightone")) {
            assertFailsWith<PassphraseKdf.Failure.WrongPassphrase>(nearMiss) {
                PassphraseKdf.unwrap(wrapped, nearMiss, kid)
            }
        }
    }

    /**
     * No verifier field: the AEAD tag is the only gate. Swift checks the keys of the encoded
     * JSON; the record has no codec in this package, so this checks the type's own fields.
     */
    @Test fun theStoredRecordCarriesNoSecondOracle() {
        val fields = PassphraseKdf.WrappedKey::class.java.declaredFields
            .filterNot { it.isSynthetic || java.lang.reflect.Modifier.isStatic(it.modifiers) }
            .map { it.name }
            .toSet()

        assertEquals(setOf("alg", "iterations", "salt", "envelope"), fields)
    }

    /** What stops a rewritten count is the derivation: a different count is a different key. */
    @Test fun loweringTheIterationCountInTheFileBreaksTheUnwrapRatherThanCheapeningIt() {
        val wrapped = wrap(newKey(), "p").copy(iterations = 1)

        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> { PassphraseKdf.unwrap(wrapped, "p", kid) }
    }

    @Test fun editingTheSaltInTheFileBreaksTheUnwrap() {
        val wrapped = wrap(newKey(), "p").copy(salt = Base64Url.encode(filled(0x01, PassphraseKdf.SALT_BYTE_COUNT)))

        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> { PassphraseKdf.unwrap(wrapped, "p", kid) }
    }

    /** A structural problem with the file must not be reported as a wrong passphrase. */
    @Test fun atruncatedFileIsReportedAsStructuralRatherThanAsAWrongPassphrase() {
        var wrapped = wrap(newKey(), "p").copy(envelope = "v1.notanenvelope")

        assertFailsWith<SnippetCrypto.Failure.MalformedEnvelope> { PassphraseKdf.unwrap(wrapped, "p", kid) }

        wrapped = wrapped.copy(alg = "argon2id")
        val failure = assertFailsWith<PassphraseKdf.Failure.UnsupportedAlgorithm> {
            PassphraseKdf.unwrap(wrapped, "p", kid)
        }
        assertEquals("argon2id", failure.algorithm)
    }

    /** A hostile file claiming two billion rounds would wedge the unlock path. */
    @Test fun anAbsurdIterationCountIsRefusedBeforeAnyWorkHappens() {
        val wrapped = wrap(newKey(), "p").copy(iterations = PassphraseKdf.MAXIMUM_ITERATIONS + 1)

        val counting = CountingPbkdf2()
        val failure = assertFailsWith<PassphraseKdf.Failure.InvalidParameters> {
            PassphraseKdf.unwrap(wrapped, "p", kid, counting)
        }
        assertEquals("20000001 iterations exceeds the 20000000 ceiling", failure.detail)
        assertEquals(0, counting.calls, "the derivation must not have started")
    }

    /**
     * "é" is one code point or two depending on the keyboard and the input method. Swift's
     * `==` says the two spellings are the same string; Kotlin's does not, which only makes
     * the trap easier to see. Their UTF-8 differs, and PBKDF2 consumes the UTF-8.
     */
    @Test fun twoUnicodeSpellingsOfTheSamePassphraseUnlockTheSameVault() {
        val composed = "caf\u00E9 r\u00E9sum\u00E9"            // e-acute as one code point
        val decomposed = "cafe\u0301 re\u0301sume\u0301"       // e-acute as e + combining acute
        assertNotEquals(composed, decomposed)
        assertFalse(utf8(composed).contentEquals(utf8(decomposed)))

        val libraryKey = newKey()
        val wrapped = wrap(libraryKey, composed)

        assertContentEquals(libraryKey, PassphraseKdf.unwrap(wrapped, decomposed, kid))
        // And the other way round.
        assertContentEquals(libraryKey, PassphraseKdf.unwrap(wrap(libraryKey, decomposed), composed, kid))
    }

    @Test fun anEmptyPassphraseIsRefused() {
        assertFailsWith<PassphraseKdf.Failure.EmptyPassphrase> { wrap(newKey(), "") }
    }

    /** The wrapped key is a padded envelope over 32 bytes, so the file does not advertise the key length. */
    @Test fun theWrappedKeyIsAPaddedEnvelopeLikeAnyOtherRecord() {
        val wrapped = wrap(newKey(), "p")

        val parsed = SealedEnvelope.parse(wrapped.envelope)
        assertEquals(SnippetCrypto.WIRE_VERSION, parsed.version)
        assertEquals(Padding.BLOCK_SIZE + SnippetCrypto.TAG_BYTE_COUNT, parsed.sealed.size)
        assertEquals(383, wrapped.envelope.length)
    }

    @Test fun derivationIsDeterministicAndSaltSeparated() {
        val a = PassphraseKdf.derive("p", salt, 1_000)
        val b = PassphraseKdf.derive("p", salt, 1_000)
        val otherSalt = PassphraseKdf.derive("p", filled(0x01, 16), 1_000)
        val otherCount = PassphraseKdf.derive("p", salt, 1_001)

        assertContentEquals(a, b)
        assertFalse(a.contentEquals(otherSalt))
        assertFalse(a.contentEquals(otherCount))
        assertEquals(PassphraseKdf.DERIVED_KEY_BYTE_COUNT, a.size)
    }

    /** The record has to survive a round trip through `vault.json` or a backup file, which is JSON. */
    @Test fun theWrappedRecordRoundTripsThroughJSON() {
        val libraryKey = newKey()
        val wrapped = wrap(libraryKey, "p")

        val encoded = JsonObject(
            mapOf(
                "alg" to JsonPrimitive(wrapped.alg),
                "iterations" to JsonPrimitive(wrapped.iterations),
                "salt" to JsonPrimitive(wrapped.salt),
                "envelope" to JsonPrimitive(wrapped.envelope),
            ),
        ).toString()
        val fields = Json.parseToJsonElement(encoded).jsonObject
        val decoded = PassphraseKdf.WrappedKey(
            alg = fields.string("alg"),
            iterations = fields.long("iterations"),
            salt = fields.string("salt"),
            envelope = fields.string("envelope"),
        )

        assertEquals(wrapped, decoded)
        assertContentEquals(libraryKey, PassphraseKdf.unwrap(decoded, "p", kid))
    }

    @Test fun twoWrapsOfTheSameKeyUnderTheSamePassphraseAreNotIdentical() {
        val libraryKey = newKey()
        val saltA = PassphraseKdf.makeSalt()
        val saltB = PassphraseKdf.makeSalt()
        assertFalse(saltA.contentEquals(saltB))

        val a = wrap(libraryKey, "p", saltA)
        val b = wrap(libraryKey, "p", saltB)

        assertNotEquals(a.envelope, b.envelope)
    }

    // Added: limits, the error taxonomy, the AAD bytes, and the encodings.

    @Test fun theLimitsAreExactlyTheDocumentedOnes() {
        val key = newKey()
        val detail = { block: () -> Unit -> assertFailsWith<PassphraseKdf.Failure.InvalidParameters> { block() }.detail }

        assertEquals("empty salt", detail { PassphraseKdf.derive("p", ByteArray(0), 1) })
        assertEquals("iterations must be positive", detail { PassphraseKdf.derive("p", salt, 0) })
        assertEquals("iterations must be positive", detail { PassphraseKdf.derive("p", salt, -5) })
        assertEquals(
            "5000000000 iterations exceeds the 20000000 ceiling",
            detail { PassphraseKdf.derive("p", salt, 5_000_000_000) },
        )
        // An empty passphrase is reported before anything about the parameters.
        assertFailsWith<PassphraseKdf.Failure.EmptyPassphrase> { PassphraseKdf.derive("", ByteArray(0), 0) }
        // One round is legal, and so is the ceiling itself (not run here: it would take a minute).
        assertEquals(32, PassphraseKdf.derive("p", salt, 1).size)
        val ceiling = CountingPbkdf2()
        PassphraseKdf.derive("p", salt, PassphraseKdf.MAXIMUM_ITERATIONS, ceiling)
        assertEquals(1, ceiling.calls)
        assertEquals(20_000_000, ceiling.lastIterations)

        assertEquals(16, assertFailsWith<SnippetCrypto.Failure.WrongKeySize> {
            PassphraseKdf.wrap(ByteArray(16), "p", salt, kid, fastIterations)
        }.count)
        // Reading: the salt must be non-empty strict base64url.
        val wrapped = wrap(key, "p")
        for (badSalt in listOf("", "====", "Xl5eXl5eXl5eXl5eXl5eXg==", "Xl5e+l5e", "a")) {
            assertEquals("salt is not base64url", detail { PassphraseKdf.unwrap(wrapped.copy(salt = badSalt), "p", kid) }, badSalt)
        }
        assertEquals("iterations must be positive", detail { PassphraseKdf.unwrap(wrapped.copy(iterations = 0), "p", kid) })
    }

    /** `kid` is in the AAD and nothing derives from it: without the binding a stale wrap would open. */
    @Test fun aWrapForAnotherOwnerIsAWrongPassphraseNotAStructuralError() {
        val wrapped = wrap(newKey(), "p")
        assertFailsWith<PassphraseKdf.Failure.WrongPassphrase> { PassphraseKdf.unwrap(wrapped, "p", "k-other") }
    }

    /** A tag that verifies over something that is not a 32-byte key is a broken record, not a wrong passphrase. */
    @Test fun anEnvelopeThatOpensToTheWrongLengthIsInvalidParameters() {
        val wrapping = PassphraseKdf.derive("p", salt, fastIterations)
        val aad = PassphraseKdf.additionalData(PassphraseKdf.ALGORITHM, fastIterations, salt, kid)
        val record = PassphraseKdf.WrappedKey(
            alg = PassphraseKdf.ALGORITHM,
            iterations = fastIterations,
            salt = Base64Url.encode(salt),
            envelope = SnippetCrypto.seal(ByteArray(31), wrapping, aad),
        )
        val failure = assertFailsWith<PassphraseKdf.Failure.InvalidParameters> { PassphraseKdf.unwrap(record, "p", kid) }
        assertEquals("wrapped key is 31 bytes", failure.detail)
    }

    /** `domainSeparated("snip.kdf.v1", [alg, u64be(iterations), salt BYTES, kid])` (hazard H12). */
    @Test fun theAADTakesTheDecodedSaltBytesAndABigEndianCount() {
        val aad = PassphraseKdf.additionalData(PassphraseKdf.ALGORITHM, 600_000, counting(0xc0, 16), "b-fixture")
        assertEquals(
            "0000000b" + utf8("snip.kdf.v1").hex() +
                "00000012" + utf8("pbkdf2-hmac-sha512").hex() +
                "00000008" + "00000000000927c0" +
                "00000010" + counting(0xc0, 16).hex() +
                "00000009" + utf8("b-fixture").hex(),
            aad.hex(),
        )
        assertEquals(SwiftReference.json.string("passAAD"), aad.hex())
        // Not the base64url text of the salt.
        val withText = PassphraseKdf.additionalData(
            PassphraseKdf.ALGORITHM, 600_000, utf8(Base64Url.encode(counting(0xc0, 16))), "b-fixture",
        )
        assertFalse(aad.contentEquals(withText))
    }

    /** The password is NFC, then UTF-8, with every code point intact, whatever the two implementations are fed. */
    @Test fun derivationMatchesCommonCryptoForEveryReferencePasswordThroughBothImplementations() {
        val salt = counting(0xc0, 16)
        for (case in SwiftReference.json.array("kdf")) {
            val iterations = case.string("iterations").toLong()
            if (iterations == 600_000L) continue
            val passphrase = fromUtf16Hex(case.string("passwordUTF16"))
            for (pbkdf2 in listOf(MacPbkdf2HmacSha512, JcaPbkdf2HmacSha512)) {
                assertEquals(
                    case.string("key"), PassphraseKdf.derive(passphrase, salt, iterations, pbkdf2).hex(),
                    "${case.string("label")}, $iterations rounds",
                )
                assertEquals(
                    case.string("key"), PassphraseKdf.derive(passphrase.toCharArray(), salt, iterations, pbkdf2).hex(),
                )
            }
        }
    }

    /** The bytes handed to PBKDF2 are exactly `Array(passphrase.precomposedStringWithCanonicalMapping.utf8)`. */
    @Test fun thePasswordBytesAreTheNFCUTF8SwiftProduces() {
        for (case in SwiftReference.json.array("kdf")) {
            val recording = CountingPbkdf2()
            PassphraseKdf.derive(fromUtf16Hex(case.string("passwordUTF16")), counting(0xc0, 16), 1, recording)
            assertEquals(case.string("nfcUTF8"), recording.lastPassword, case.string("label"))
        }
    }

    /** A Swift `String` never holds an unpaired surrogate (it becomes U+FFFD); the derivation must not turn it into `?`. */
    @Test fun anUnpairedSurrogateInAPassphraseIsTheReplacementCharacter() {
        val recording = CountingPbkdf2()
        PassphraseKdf.derive("a\uD83Db", salt, 1, recording)
        assertEquals("61efbfbd62", recording.lastPassword)
    }

    /** Full `WrappedKey` in the seal direction, with Swift's nonce: NFD-typed, astral passphrase. */
    @Test fun aWrapWithAFixedNonceIsByteIdenticalToSwifts() {
        val expected = SwiftReference.json.obj("passWrap")
        val wrapped = PassphraseKdf.wrap(
            key = counting(0x80, 32),
            passphrase = "Cafe\u0301 🔐",
            salt = counting(0xc0, 16),
            kid = "b-fixture",
            iterations = 4096,
            nonces = fixedNonce(counting(0x50, 12)),
        )
        assertEquals(expected.string("alg"), wrapped.alg)
        assertEquals(expected.long("iterations"), wrapped.iterations)
        assertEquals(expected.string("salt"), wrapped.salt)
        assertEquals(expected.string("envelope"), wrapped.envelope)
        assertContentEquals(counting(0x80, 32), PassphraseKdf.unwrap(wrapped, "Caf\u00E9 🔐", "b-fixture"))
    }

    @Test fun theCallersPassphraseArrayIsLeftIntactForTheCallerToWipe() {
        val passphrase = "pässword".toCharArray()
        val key = PassphraseKdf.derive(passphrase, salt, 10)
        assertEquals("pässword", String(passphrase))
        assertContentEquals(key, PassphraseKdf.derive("pässword", salt, 10))
        assertTrue(key.any { it != 0.toByte() })
    }

    /** Counts calls and records what it was given, then delegates. */
    private class CountingPbkdf2 : Pbkdf2HmacSha512 {
        var calls = 0
        var lastIterations = 0
        var lastPassword = ""

        override fun derive(password: ByteArray, salt: ByteArray, iterations: Int, derivedKeyByteCount: Int): ByteArray {
            calls += 1
            lastIterations = iterations
            lastPassword = password.hex()
            // The real work is irrelevant to what these tests observe.
            return MacPbkdf2HmacSha512.derive(password, salt, 1, derivedKeyByteCount)
        }
    }
}
