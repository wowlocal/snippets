package com.khm.snippets.core.crypto

import org.junit.Test
import java.security.MessageDigest
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

// `Tests/Core/CryptoTests.swift`, suites 1 to 7. Each class is one Swift suite and each
// test keeps its Swift name, so the two files can be read side by side. Tests that Swift
// runs once per argument loop over the same arguments here.

private const val SCOPE = "e3b0c442-98fc-4c14-9afb-f4c8996fb924"

/** A fixed root key: none of the properties below depend on the key being unpredictable. */
private fun keyring(libraryByte: Int = 0x11, saltByte: Int = 0x22) = SnippetCrypto.Keyring(
    libraryKey = filled(libraryByte, SnippetCrypto.KEY_BYTE_COUNT),
    salt = filled(saltByte, SnippetCrypto.SALT_BYTE_COUNT),
)

private fun context(index: Int, deleted: Boolean = false, scopeId: String = SCOPE) =
    SnippetCrypto.RecordContext(scopeId = scopeId, recordId = recordId(index), isDeleted = deleted)

private fun body(text: String): ByteArray = utf8(text)

/** Suite 1, "Seal and open". */
class SnippetCryptoSealAndOpenTest {

    /** The floor: what goes in comes out, byte for byte, across the lengths a snippet body takes. */
    @Test fun aSealedBodyOpensBackToTheExactBytesItWentInAs() {
        for (length in listOf(0, 1, 6, 16, 255, 256, 257, 1024, 10_000)) {
            val plaintext = SeededRandom(length + 1L).bytes(length)
            val ring = keyring()

            val envelope = SnippetCrypto.seal(plaintext, context(0), ring)
            val opened = SnippetCrypto.open(envelope, context(0), ring)

            assertContentEquals(plaintext, opened, "length $length")
        }
    }

    @Test fun aUTF8BodySurvivesTheRoundTripThroughDataAndBack() {
        val ring = keyring()
        val text = "caf\u00E9 ☕\uFE0F \u2014 na\u00EFve 🔐 \uD83C\uDDEF\uD83C\uDDF5"
        val envelope = SnippetCrypto.seal(body(text), context(0), ring)
        val opened = SnippetCrypto.open(envelope, context(0), ring)

        assertEquals(text, SnippetCrypto.plaintextString(opened))
    }

    /** A format change here is a compatibility break, and this test is what makes that break loud. */
    @Test fun theEnvelopeIsThreeDotSeparatedURLSafeFieldsBehindAVersionPrefix() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("hunter2"), context(0), ring)

        val parts = envelope.split('.')
        assertEquals(3, parts.size)
        assertEquals("v1", parts[0])

        val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toSet()
        assertTrue(parts[1].all { it in allowed })
        assertTrue(parts[2].all { it in allowed })

        val parsed = SealedEnvelope.parse(envelope)
        assertEquals(SnippetCrypto.NONCE_BYTE_COUNT, parsed.nonce.size)
        assertEquals(envelope, parsed.text)
    }

    @Test fun anEnvelopeFromAFutureWireVersionIsRefusedRatherThanGuessedAt() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("secret"), context(0), ring)
        val future = rebuilt(envelope, version = "v2")

        val failure = assertFailsWith<SnippetCrypto.Failure.UnsupportedWireVersion> {
            SnippetCrypto.open(future, context(0), ring)
        }
        assertEquals("v2", failure.version)
    }

    @Test fun aStringThatIsNotAnEnvelopeIsRejectedWithoutTouchingAnyKeyMaterial() {
        val ring = keyring()
        for (text in listOf("", "v1", "v1.abc", "v1.abc.def.ghi", "v1..", "v1.\$\$\$\$.abcd", "v1.abcd.\$\$\$\$")) {
            assertFailsWith<SnippetCrypto.Failure.MalformedEnvelope>("\"$text\"") {
                SnippetCrypto.open(text, context(0), ring)
            }
        }
    }

    /** A truncated body must not be mistaken for a tag failure or, worse, opened. */
    @Test fun anEnvelopeTooShortToHoldATagIsRejected() {
        val ring = keyring()
        val stub = SealedEnvelope(
            version = "v1",
            nonce = ByteArray(SnippetCrypto.NONCE_BYTE_COUNT),
            sealed = ByteArray(SnippetCrypto.TAG_BYTE_COUNT),
        ).text

        val failure = assertFailsWith<SnippetCrypto.Failure.MalformedEnvelope> {
            SnippetCrypto.open(stub, context(0), ring)
        }
        assertEquals("body is too short to contain a tag", failure.detail)
    }

    // Added: the envelope value type itself.

    @Test fun envelopesCompareByContentAndKeepTheirOwnCopies() {
        val nonce = filled(1, 12)
        val sealed = filled(2, 17)
        val envelope = SealedEnvelope("v1", nonce, sealed)
        nonce.fill(9)
        sealed.fill(9)
        assertEquals(SealedEnvelope("v1", filled(1, 12), filled(2, 17)), envelope)
        assertEquals(SealedEnvelope("v1", filled(1, 12), filled(2, 17)).hashCode(), envelope.hashCode())
        assertNotEquals(SealedEnvelope("v2", filled(1, 12), filled(2, 17)), envelope)
        envelope.nonce.fill(7)
        assertContentEquals(filled(1, 12), envelope.nonce)
        assertEquals(envelope, SealedEnvelope.parse(envelope.text))
    }

    /** `20 + ceil(4 * (256 * ceil((P + 1) / 256) + 16) / 3)` characters; a 32-byte key always seals to 383. */
    @Test fun theSealedLengthFollowsThePublishedFormula() {
        val ring = keyring()
        for (length in listOf(0, 1, 32, 255, 256, 257, 511, 512, 1000)) {
            val blocks = (length + 1 + 255) / 256
            val expected = 20 + (4 * (256 * blocks + 16) + 2) / 3
            assertEquals(expected, SnippetCrypto.seal(ByteArray(length), context(0), ring).length, "length $length")
        }
        assertEquals(383, SnippetCrypto.seal(ByteArray(32), context(0), ring).length)
    }
}

/** Suite 2, "Tampering": one test per envelope field. */
class SnippetCryptoTamperingTest {

    @Test fun aFlippedBitInTheCiphertextFailsToOpen() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("hunter2"), context(0), ring)
        val tampered = rebuilt(envelope, sealed = ::flippingFirstBit)

        assertNotEquals(envelope, tampered)
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(tampered, context(0), ring) }
    }

    @Test fun aFlippedBitInTheAuthenticationTagFailsToOpen() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("hunter2"), context(0), ring)
        val tampered = rebuilt(envelope, sealed = ::flippingLastBit)

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(tampered, context(0), ring) }
    }

    @Test fun aFlippedBitInTheNonceFailsToOpen() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("hunter2"), context(0), ring)
        val tampered = rebuilt(envelope, nonce = ::flippingFirstBit)

        assertNotEquals(envelope, tampered)
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(tampered, context(0), ring) }
    }

    @Test fun aCiphertextDoesNotOpenUnderDifferentAdditionalData() {
        val ring = keyring()
        val key = ring.recordKey(recordId(0))
        val envelope = SnippetCrypto.seal(body("hunter2"), key, SnippetCrypto.additionalData(context(0)))

        val altered = context(0).copy(scopeId = SCOPE + "x")

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            SnippetCrypto.open(envelope, key, SnippetCrypto.additionalData(altered))
        }
        // The untouched context still works, so the failure above is the AAD.
        assertContentEquals(body("hunter2"), SnippetCrypto.open(envelope, key, SnippetCrypto.additionalData(context(0))))
    }

    /** Empty AAD is the shape an accidental `aad = ByteArray(0)` takes, and AES-GCM accepts it happily. */
    @Test fun aCiphertextSealedWithRealAADDoesNotOpenWithEmptyAAD() {
        val ring = keyring()
        val key = ring.recordKey(recordId(0))
        val envelope = SnippetCrypto.seal(body("hunter2"), key, SnippetCrypto.additionalData(context(0)))

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(envelope, key, ByteArray(0)) }
    }

    // Added: every bit position of every field, and the version field, on one envelope.

    @Test fun everySingleBitFlipInEitherFieldFailsToAuthenticate() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("x"), context(0), ring)
        val parsed = SealedEnvelope.parse(envelope)

        for (index in 0 until parsed.nonce.size * 8) {
            val tampered = rebuilt(envelope, nonce = { it[index / 8] = (it[index / 8].toInt() xor (1 shl (index % 8))).toByte() })
            assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed>("nonce bit $index") {
                SnippetCrypto.open(tampered, context(0), ring)
            }
        }
        // Every bit of the tag and of the first and last ciphertext blocks.
        val sealedSize = parsed.sealed.size
        val positions = (0 until 16 * 8) + ((sealedSize - 32) * 8 until sealedSize * 8)
        for (index in positions) {
            val tampered = rebuilt(envelope, sealed = { it[index / 8] = (it[index / 8].toInt() xor (1 shl (index % 8))).toByte() })
            assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed>("sealed bit $index") {
                SnippetCrypto.open(tampered, context(0), ring)
            }
        }
    }

    @Test fun aTruncatedOrExtendedBodyFailsToAuthenticate() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("hunter2"), context(0), ring)
        val parsed = SealedEnvelope.parse(envelope)
        val shorter = SealedEnvelope("v1", parsed.nonce, parsed.sealed.copyOf(parsed.sealed.size - 1)).text
        val longer = SealedEnvelope("v1", parsed.nonce, parsed.sealed + byteArrayOf(0)).text

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(shorter, context(0), ring) }
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(longer, context(0), ring) }
    }

    /** A valid tag over bytes that are not padded is a peer speaking another format, reported as such. */
    @Test fun authenticBytesWithForeignPaddingAreMalformedPaddingNotAnAuthenticationFailure() {
        val key = filled(7, 32)
        val nonce = filled(8, 12)
        val aad = utf8("aad")
        for (unpadded in listOf(ByteArray(256), filled(0x41, 256), ByteArray(255), utf8("no padding at all"))) {
            val sealed = AesGcm.seal(key, nonce, unpadded, aad)
            val envelope = SealedEnvelope("v1", nonce, sealed).text
            assertFailsWith<SnippetCrypto.Failure.MalformedPadding> { SnippetCrypto.open(envelope, key, aad) }
        }
    }
}

/** Suite 3, "Identity binding". */
class SnippetCryptoIdentityBindingTest {

    /** The positive control: a suite of only negative assertions passes when nothing decrypts at all. */
    @Test fun thematchingContextOpensWhatItSealed() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("123456"), context(0), ring)

        assertContentEquals(body("123456"), SnippetCrypto.open(envelope, context(0), ring))
    }

    @Test fun aBodySealedForOneRecordCannotBeOpenedAsAnother() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("123456"), context(0), ring)

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(envelope, context(1), ring) }
    }

    @Test fun theRecordIdBindsThroughTheKeyEvenWhenTheAADIsHeldConstant() {
        val ring = keyring()
        val aad = SnippetCrypto.additionalData(context(0))
        val envelope = SnippetCrypto.seal(body("123456"), ring.recordKey(recordId(0)), aad)

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            SnippetCrypto.open(envelope, ring.recordKey(recordId(1)), aad)
        }
    }

    @Test fun theRecordIdBindsThroughTheAADEvenWhenTheKeyIsHeldConstant() {
        val ring = keyring()
        val key = ring.recordKey(recordId(0))
        val envelope = SnippetCrypto.seal(body("123456"), key, SnippetCrypto.additionalData(context(0)))

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            SnippetCrypto.open(envelope, key, SnippetCrypto.additionalData(context(1)))
        }
    }

    @Test fun theDeletedFlagIsBoundSoATombstoneAndALiveRecordCannotBeSwapped() {
        val ring = keyring()
        val live = SnippetCrypto.seal(body("still here"), context(0), ring)
        val dead = SnippetCrypto.seal(ByteArray(0), context(0, deleted = true), ring)

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            SnippetCrypto.open(live, context(0, deleted = true), ring)
        }
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(dead, context(0), ring) }
    }

    @Test fun theScopeIsBoundSoARecordCannotBeMovedBetweenVaults() {
        val ring = keyring()
        val envelope = SnippetCrypto.seal(body("secret"), context(0), ring)

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            SnippetCrypto.open(envelope, context(0, scopeId = "some-other-scope"), ring)
        }
    }

    /** Without length prefixes, `scope "ab"` + `"c"` would collide with `scope "a"` + `"bc"`. */
    @Test fun adjacentFieldsCannotBeShuffledAcrossTheAADBoundary() {
        val left = SnippetCrypto.domainSeparated("d", listOf(body("ab"), body("c")))
        val right = SnippetCrypto.domainSeparated("d", listOf(body("a"), body("bc")))
        assertFalse(left.contentEquals(right))

        val movedDomain = SnippetCrypto.domainSeparated("da", listOf(body("b"), body("c")))
        assertFalse(movedDomain.contentEquals(left))
    }

    @Test fun theKeyWrappingDomainCannotCollideWithTheRecordDomain() {
        assertNotEquals(SnippetCrypto.ADDITIONAL_DATA_DOMAIN, PassphraseKdf.ADDITIONAL_DATA_DOMAIN)

        val record = SnippetCrypto.additionalData(context(0))
        val wrap = PassphraseKdf.additionalData(
            alg = PassphraseKdf.ALGORITHM, iterations = 1, salt = ByteArray(16), kid = "k-test",
        )
        assertFalse(record.contentEquals(wrap))
    }

    // Added: the exact bytes.

    @Test fun theLengthPrefixedLayoutIsExactlyAsSpecified() {
        // u32be(len(domain)) ‖ domain ‖ u32be(len(f1)) ‖ f1 ‖ …
        assertEquals("00000001" + "64" + "00000002" + "6162" + "00000000" + "00000001" + "63",
            DomainSeparated.encode("d", body("ab"), ByteArray(0), body("c")).hex())
        assertEquals("00000000", DomainSeparated.encode("").hex())
        assertEquals("00000002c3a9", DomainSeparated.encode("\u00E9").hex())

        val live = SnippetCrypto.additionalData(context(1))
        assertEquals(
            "0000000b" + utf8("snip.aad.v1").hex() +
                "00000002" + utf8("v1").hex() +
                "00000024" + utf8(SCOPE).hex() +
                "00000010" + "00000000000040008000000000000001" +
                "00000001" + "00",
            live.hex(),
        )
        val dead = SnippetCrypto.additionalData(context(1, deleted = true))
        assertEquals(live.hex().dropLast(2) + "01", dead.hex())
    }

    /** The three distinct domains: record, key wrap, passphrase wrap. None can stand in for another. */
    @Test fun theThreeAADDomainsAreTheDocumentedStrings() {
        assertEquals("snip.aad.v1", SnippetCrypto.ADDITIONAL_DATA_DOMAIN)
        assertEquals("snip.wrap.v1", KeyWrap.ADDITIONAL_DATA_DOMAIN)
        assertEquals("snip.kdf.v1", PassphraseKdf.ADDITIONAL_DATA_DOMAIN)
        assertEquals("snip.wire.v1|", SnippetCrypto.RECORD_KEY_INFO_PREFIX)
        assertEquals("snip.chash.v1", SnippetCrypto.CONTENT_HASH_INFO)
        assertEquals("snip.wrap.v1|", KeyWrap.WRAPPING_KEY_INFO_PREFIX)
        assertEquals("v1", SnippetCrypto.WIRE_VERSION)
    }
}

/** Suite 4, "Nonces". */
class SnippetCryptoNoncesTest {

    @Test fun theSamePlaintextSealedTwiceProducesDifferentBytes() {
        val ring = keyring()
        val plaintext = body("hunter2")

        val first = SnippetCrypto.seal(plaintext, context(0), ring)
        val second = SnippetCrypto.seal(plaintext, context(0), ring)

        assertNotEquals(first, second)
        assertFalse(SealedEnvelope.parse(first).nonce.contentEquals(SealedEnvelope.parse(second).nonce))
        assertFalse(SealedEnvelope.parse(first).sealed.contentEquals(SealedEnvelope.parse(second).sealed))

        // Both still open, so the difference is nonce freshness rather than one being broken.
        assertContentEquals(plaintext, SnippetCrypto.open(first, context(0), ring))
        assertContentEquals(plaintext, SnippetCrypto.open(second, context(0), ring))
    }

    @Test fun repeatedSealsNeverReuseANonce() {
        val ring = keyring()
        val nonces = HashSet<String>()
        repeat(100) {
            val envelope = SnippetCrypto.seal(body("same"), context(0), ring)
            nonces.add(SealedEnvelope.parse(envelope).nonce.hex())
        }
        assertEquals(100, nonces.size)
    }

    @Test fun theInjectedNonceSourceIsTheOnlyThingConsultedForNonces() {
        val ring = keyring()
        val nonces = CountedNonces()

        val first = SnippetCrypto.seal(body("a"), context(0), ring, nonces.source)
        val second = SnippetCrypto.seal(body("a"), context(0), ring, nonces.source)

        assertEquals(2, nonces.count)
        val expected = ByteArray(SnippetCrypto.NONCE_BYTE_COUNT)
        expected[SnippetCrypto.NONCE_BYTE_COUNT - 1] = 1
        assertContentEquals(expected, SealedEnvelope.parse(first).nonce)
        expected[SnippetCrypto.NONCE_BYTE_COUNT - 1] = 2
        assertContentEquals(expected, SealedEnvelope.parse(second).nonce)
    }

    /** What the catastrophic case looks like, so nobody later mistakes identical output for a caching win. */
    @Test fun aStationaryNonceProducesIdenticalCiphertextWhichIsWhyThereIsNoFixedConvenience() {
        val ring = keyring()
        val first = SnippetCrypto.seal(body("hunter2"), context(0), ring, stationaryNonces())
        val second = SnippetCrypto.seal(body("hunter2"), context(0), ring, stationaryNonces())

        assertEquals(first, second)
    }

    @Test fun aNonceSourceOfTheWrongWidthIsRefused() {
        val ring = keyring()
        val short = NonceSource { ByteArray(8) }

        val failure = assertFailsWith<SnippetCrypto.Failure.MalformedNonce> {
            SnippetCrypto.seal(body("x"), context(0), ring, short)
        }
        assertEquals(8, failure.count)
        assertEquals(13, assertFailsWith<SnippetCrypto.Failure.MalformedNonce> {
            SnippetCrypto.seal(body("x"), context(0), ring, NonceSource { ByteArray(13) })
        }.count)
    }

    // Added

    @Test fun theSystemSourceYieldsTwelveFreshBytesEachTime() {
        val first = NonceSource.System.nextNonce()
        val second = NonceSource.System.nextNonce()
        assertEquals(12, first.size)
        assertFalse(first.contentEquals(second))
    }

    /** A source that later reuses or clears its array must not be able to reach into a sealed envelope. */
    @Test fun theEnvelopeKeepsItsOwnCopyOfTheNonce() {
        val shared = filled(3, 12)
        val envelope = SnippetCrypto.seal(body("x"), context(0), keyring(), NonceSource { shared })
        shared.fill(0)
        assertContentEquals(filled(3, 12), SealedEnvelope.parse(envelope).nonce)
    }
}

/** Suite 5, "Key hierarchy". */
class SnippetCryptoKeyHierarchyTest {

    @Test fun everySubkeyDiffersFromTheRootAndFromEveryOtherSubkey() {
        val ring = keyring()
        val root = ring.libraryKey().hex()
        val hash = ring.contentHashKey().hex()
        val recordKeys = (0 until 8).map { ring.recordKey(recordId(it)) }

        assertFalse(recordKeys.any { it.hex() == root })
        assertNotEquals(root, hash)
        assertFalse(recordKeys.any { it.hex() == hash })
        assertEquals(recordKeys.size, recordKeys.map { it.hex() }.toSet().size)
        assertTrue(recordKeys.all { it.size == SnippetCrypto.KEY_BYTE_COUNT })
    }

    @Test fun derivationIsDeterministicAcrossIndependentKeyringInstances() {
        assertContentEquals(keyring().recordKey(recordId(3)), keyring().recordKey(recordId(3)))
    }

    @Test fun adifferentSaltDerivesCompletelyDifferentSubkeys() {
        val a = keyring(saltByte = 0x22).recordKey(recordId(0))
        val b = keyring(saltByte = 0x33).recordKey(recordId(0))
        assertFalse(a.contentEquals(b))

        val hashA = keyring(saltByte = 0x22).contentHashKey()
        val hashB = keyring(saltByte = 0x33).contentHashKey()
        assertFalse(hashA.contentEquals(hashB))
    }

    @Test fun aGeneratedKeyringIsFullWidthAndNotRepeatable() {
        val a = SnippetCrypto.Keyring.generate()
        val b = SnippetCrypto.Keyring.generate()

        assertEquals(SnippetCrypto.SALT_BYTE_COUNT, a.salt().size)
        assertEquals(SnippetCrypto.KEY_BYTE_COUNT, a.libraryKey().size)
        assertFalse(a.salt().contentEquals(b.salt()))
        assertFalse(a.libraryKey().contentEquals(b.libraryKey()))
        assertFalse(a.libraryKey().contentEquals(ByteArray(32)))
    }

    @Test fun aKeyOfTheWrongWidthIsRefusedBySealAndOpen() {
        val stunted = ByteArray(16)

        assertEquals(16, assertFailsWith<SnippetCrypto.Failure.WrongKeySize> {
            SnippetCrypto.seal(body("x"), stunted, ByteArray(0))
        }.count)
        assertEquals(16, assertFailsWith<SnippetCrypto.Failure.WrongKeySize> {
            SnippetCrypto.open("v1.AAAAAAAAAAAAAAAA.AAAAAAAAAAAAAAAAAAAAAA", stunted, ByteArray(0))
        }.count)
    }

    // Added

    /** The record key is plain HKDF with the documented info, over the 16 raw id bytes and never the text. */
    @Test fun theSubkeysAreTheDocumentedHKDFDerivations() {
        val root = filled(0x11, 32)
        val salt = filled(0x22, 32)
        val id = recordId(0xabc)
        val expectedRecord = Hkdf.deriveKey(root, salt, utf8("snip.wire.v1|") + Uuids.toBytes(id), 32)
        val expectedHash = Hkdf.deriveKey(root, salt, utf8("snip.chash.v1"), 32)
        assertContentEquals(expectedRecord, keyring().recordKey(id))
        assertContentEquals(expectedHash, keyring().contentHashKey())
        // Not the text form in either case.
        assertFalse(Hkdf.deriveKey(root, salt, utf8("snip.wire.v1|" + id.toString()), 32).contentEquals(expectedRecord))
    }

    /** Key material is copied in, handed out as copies, absent from `toString`, and gone after `close`. */
    @Test fun aKeyringOwnsItsMaterialAndWipesItOnClose() {
        val key = filled(0x11, 32)
        val salt = filled(0x22, 32)
        val ring = SnippetCrypto.Keyring(key, salt)
        val before = ring.recordKey(recordId(0))
        key.fill(0)
        salt.fill(0)
        assertContentEquals(before, ring.recordKey(recordId(0)))

        ring.libraryKey().fill(0)
        assertContentEquals(filled(0x11, 32), ring.libraryKey())
        assertFalse(ring.toString().contains("11"))

        ring.close()
        assertContentEquals(ByteArray(32), ring.libraryKey())
    }
}

/** Suite 6, "Padding". */
class SnippetCryptoPaddingTest {

    /** Empty, one byte, one short of a block, exactly a block, one over, and something large. */
    @Test fun paddingRoundTripsAtEveryAwkwardLength() {
        for (length in listOf(0, 1, 255, 256, 257, 10_000)) {
            val plaintext = SeededRandom(length + 7L).bytes(length)

            val padded = Padding.pad(plaintext)
            assertEquals(0, padded.size % Padding.BLOCK_SIZE)
            assertTrue(padded.size > length)
            assertContentEquals(plaintext, Padding.unpad(padded), "length $length")
        }
    }

    /** A body ending in zero bytes is the case a "strip trailing zeros" scheme gets wrong. */
    @Test fun aBodyThatEndsInItsOwnZeroBytesStillRoundTrips() {
        for (trailingZeros in listOf(0, 1, 200, 255, 256)) {
            val plaintext = body("payload") + ByteArray(trailingZeros)
            assertContentEquals(plaintext, Padding.unpad(Padding.pad(plaintext)), "$trailingZeros zeros")
        }
    }

    @Test fun aBodyThatEndsInTheMarkerByteStillRoundTrips() {
        val plaintext = byteArrayOf(0x41, 0x80.toByte(), 0x80.toByte())
        assertContentEquals(plaintext, Padding.unpad(Padding.pad(plaintext)))
    }

    /** A four-digit PIN and a wifi password must produce the same number of ciphertext bytes. */
    @Test fun everyShortSecretSealsToTheSameNumberOfBytes() {
        val ring = keyring()
        val bodies = listOf("1234", "hunter2", "correct horse battery staple", "x".repeat(200))

        val sizes = bodies.map { text ->
            SealedEnvelope.parse(SnippetCrypto.seal(body(text), context(0), ring)).sealed.size
        }.toSet()

        assertEquals(setOf(Padding.BLOCK_SIZE + SnippetCrypto.TAG_BYTE_COUNT), sizes)
    }

    @Test fun malformedPaddingIsRefusedRatherThanTruncatedIntoSomething() {
        val malformed = listOf(
            ByteArray(0),            // nothing at all
            ByteArray(255),          // not a block multiple
            ByteArray(256),          // all zeros: no marker
            filled(0x41, 256),       // no marker anywhere
        )
        for (padded in malformed) {
            assertFailsWith<SnippetCrypto.Failure.MalformedPadding>("${padded.size} bytes") { Padding.unpad(padded) }
        }
    }

    /**
     * Swift guards against a `Data` slice whose indices do not start at zero. A `ByteArray`
     * has no such thing; the equivalent hazard here is a copy taken from the middle of a
     * larger buffer, which must unpad the same.
     */
    @Test fun unpadHandlesASliceWhoseIndicesDoNotStartAtZero() {
        val plaintext = body("hunter2")
        val padded = filled(0xEE, 9) + Padding.pad(plaintext)
        assertContentEquals(plaintext, Padding.unpad(padded.copyOfRange(9, padded.size)))
    }

    // Added: the exact bytes at the block boundary (hazard H14).

    @Test fun theBoundaryLengthsPadToExactlyTheseSizesAndBytes() {
        val expectedSizes = mapOf(0 to 256, 1 to 256, 254 to 256, 255 to 256, 256 to 512, 257 to 512, 511 to 512, 512 to 768)
        for ((length, expected) in expectedSizes) {
            val plaintext = filled(0x61, length)
            val padded = Padding.pad(plaintext)
            assertEquals(expected, padded.size, "length $length")
            assertContentEquals(plaintext, padded.copyOf(length))
            assertEquals(0x80.toByte(), padded[length])
            assertTrue(padded.copyOfRange(length + 1, padded.size).all { it == 0.toByte() })
        }
        // An empty body is legal and is one whole block: the marker, then zeros.
        assertEquals("80" + "00".repeat(255), Padding.pad(ByteArray(0)).hex())
        // 255 bytes grow by one byte; 256 bytes grow by a whole block.
        assertEquals("80", Padding.pad(ByteArray(255)).hex().substring(510))
        assertEquals("80" + "00".repeat(255), Padding.pad(ByteArray(256)).hex().substring(512))
    }

    @Test fun paddingDoesNotModifyItsInputAndUnpadRefusesAMarkerlessTail() {
        val plaintext = filled(0x61, 10)
        Padding.pad(plaintext).fill(0)
        assertContentEquals(filled(0x61, 10), plaintext)

        // The last non-zero byte must be the marker itself.
        val wrongMarker = Padding.pad(plaintext).also { it[10] = 0x81.toByte() }
        assertFailsWith<SnippetCrypto.Failure.MalformedPadding> { Padding.unpad(wrongMarker) }
        // A full block of marker-then-zeros unpads to the empty body.
        assertContentEquals(ByteArray(0), Padding.unpad(Padding.pad(ByteArray(0))))
        // Two blocks whose marker is the very last byte.
        val full = filled(0x62, 511) + byteArrayOf(0x80.toByte())
        assertContentEquals(filled(0x62, 511), Padding.unpad(full))
    }
}

/** Suite 7, "Content hash". */
class SnippetCryptoContentHashTest {

    @Test fun equalPlaintextAlwaysProducesTheSameHash() {
        val ring = keyring()
        val first = SnippetCrypto.contentHash(body("hunter2"), ring)
        val second = SnippetCrypto.contentHash(body("hunter2"), ring)

        assertEquals(first, second)
        assertEquals(SnippetCrypto.CONTENT_HASH_BYTE_COUNT * 2, first.length)
        assertTrue(first.all { it in "0123456789abcdef" })
    }

    @Test fun differentPlaintextProducesADifferentHash() {
        val ring = keyring()
        assertNotEquals(SnippetCrypto.contentHash(body("hunter2"), ring), SnippetCrypto.contentHash(body("hunter3"), ring))
        assertNotEquals(SnippetCrypto.contentHash(ByteArray(0), ring), SnippetCrypto.contentHash(byteArrayOf(0), ring))
    }

    /** The whole reason the hash is keyed. */
    @Test fun adifferentKeyProducesADifferentHashOfTheSamePlaintext() {
        val plaintext = body("123456")
        val underLibraryKeyA = SnippetCrypto.contentHash(plaintext, keyring(libraryByte = 0x11))
        val underLibraryKeyB = SnippetCrypto.contentHash(plaintext, keyring(libraryByte = 0x12))
        val underSaltB = SnippetCrypto.contentHash(plaintext, keyring(saltByte = 0x23))

        assertNotEquals(underLibraryKeyA, underLibraryKeyB)
        assertNotEquals(underLibraryKeyA, underSaltB)
    }

    @Test fun theHashIsNotSomethingAnAttackerCanComputeWithoutTheKey() {
        val plaintext = body("123456")
        val unkeyed = MessageDigest.getInstance("SHA-256").digest(plaintext).hex()
        val keyed = SnippetCrypto.contentHash(plaintext, keyring())

        assertNotEquals(unkeyed.substring(0, keyed.length), keyed)
    }

    @Test fun aResealChangesTheCiphertextButNotTheContentHash() {
        val ring = keyring()
        val plaintext = body("unchanged body")

        val first = SnippetCrypto.seal(plaintext, context(0), ring)
        val second = SnippetCrypto.seal(plaintext, context(0), ring)

        assertNotEquals(first, second)
        assertEquals(SnippetCrypto.contentHash(plaintext, ring), SnippetCrypto.contentHash(plaintext, ring))
    }

    @Test fun aLockedVaultCanTellChangedFromUnchangedUsingOnlyStoredHashes() {
        val ring = keyring()
        val storedLocally = SnippetCrypto.contentHash(body("v1 body"), ring)
        val arrivedFromRemoteUnchanged = SnippetCrypto.contentHash(body("v1 body"), ring)
        val arrivedFromRemoteEdited = SnippetCrypto.contentHash(body("v2 body"), ring)

        assertEquals(storedLocally, arrivedFromRemoteUnchanged)
        assertNotEquals(storedLocally, arrivedFromRemoteEdited)
    }

    // Added

    /** HMAC-SHA256 under `K_hash`, first 16 bytes, over the body as it is, with no padding. */
    @Test fun theHashIsTheTruncatedHMACOfTheUnpaddedBody() {
        val ring = keyring()
        val plaintext = body("hunter2")
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        mac.init(javax.crypto.spec.SecretKeySpec(ring.contentHashKey(), "HmacSHA256"))
        val expected = mac.doFinal(plaintext).copyOf(16).hex()

        assertEquals(expected, SnippetCrypto.contentHash(plaintext, ring))
        assertEquals(expected, SnippetCrypto.contentHash(plaintext, ring.contentHashKey()))
        assertNotEquals(expected, SnippetCrypto.contentHash(Padding.pad(plaintext), ring))
    }

    @Test fun plaintextBecomesAStringOnlyWhenItIsValidUTF8() {
        assertEquals("héllo", SnippetCrypto.plaintextString(utf8("héllo")))
        assertEquals("", SnippetCrypto.plaintextString(ByteArray(0)))
        assertNull(SnippetCrypto.plaintextString(unhex("c328")))
        assertNull(SnippetCrypto.plaintextString(unhex("eda080")))
    }
}
