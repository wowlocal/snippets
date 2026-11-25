package com.khm.snippets.core.crypto

import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Published vectors as anchors that do not depend on any Snippets code, Swift or Kotlin.

class HkdfTest {

    /** RFC 5869, appendix A.1: basic test case with SHA-256. */
    @Test fun rfc5869TestCase1() {
        val ikm = filled(0x0b, 22)
        val salt = counting(0x00, 13)
        val info = counting(0xf0, 10)
        assertEquals(
            "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5",
            Hkdf.extract(salt, ikm).hex(),
        )
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            Hkdf.deriveKey(ikm, salt, info, 42).hex(),
        )
    }

    /** RFC 5869, appendix A.2: longer inputs and outputs (three expand blocks). */
    @Test fun rfc5869TestCase2() {
        val ikm = counting(0x00, 80)
        val salt = counting(0x60, 80)
        val info = counting(0xb0, 80)
        assertEquals(
            "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244",
            Hkdf.extract(salt, ikm).hex(),
        )
        assertEquals(
            "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09" +
                "da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87",
            Hkdf.deriveKey(ikm, salt, info, 82).hex(),
        )
    }

    /** RFC 5869, appendix A.3: zero-length salt and info. `SecretKeySpec` refuses an empty key, HKDF must not. */
    @Test fun rfc5869TestCase3WithEmptySaltAndInfo() {
        val ikm = filled(0x0b, 22)
        assertEquals(
            "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04",
            Hkdf.extract(ByteArray(0), ikm).hex(),
        )
        assertEquals(
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
            Hkdf.deriveKey(ikm, ByteArray(0), ByteArray(0), 42).hex(),
        )
        // The RFC's rule spelled out: no salt is HashLen zero bytes.
        assertContentEquals(Hkdf.extract(ByteArray(32), ikm), Hkdf.extract(ByteArray(0), ikm))
    }

    @Test fun theDefaultOutputIsThirtyTwoBytesAndAPrefixOfALongerOne() {
        val short = Hkdf.deriveKey(filled(1, 32), filled(2, 32), utf8("info"))
        val long = Hkdf.deriveKey(filled(1, 32), filled(2, 32), utf8("info"), 100)
        assertEquals(32, short.size)
        assertContentEquals(short, long.copyOf(32))
        assertEquals(0, Hkdf.deriveKey(filled(1, 32), filled(2, 32), utf8("info"), 0).size)
        assertEquals(255 * 32, Hkdf.expand(filled(7, 32), ByteArray(0), 255 * 32).size)
        assertFailsWith<IllegalArgumentException> { Hkdf.expand(filled(7, 32), ByteArray(0), 255 * 32 + 1) }
    }
}

class AesGcmTest {

    private val zeroKey = ByteArray(32)
    private val zeroNonce = ByteArray(12)

    /** McGrew & Viega, "The Galois/Counter Mode of Operation", test case 13: 256-bit key, no plaintext, no AAD. */
    @Test fun gcmSpecTestCase13() {
        assertEquals(
            "530f8afbc74536b9a963b4f1c4cb738b",
            AesGcm.seal(zeroKey, zeroNonce, ByteArray(0), ByteArray(0)).hex(),
        )
    }

    /** Test case 14: one zero block. */
    @Test fun gcmSpecTestCase14() {
        val sealed = AesGcm.seal(zeroKey, zeroNonce, ByteArray(16), ByteArray(0))
        assertEquals("cea7403d4d606b6e074ec5d3baf39d18" + "d0d1c8a799996bf0265b98b5d48ab919", sealed.hex())
        assertContentEquals(ByteArray(16), AesGcm.open(zeroKey, zeroNonce, sealed, ByteArray(0)))
    }

    private val specKey = unhex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
    private val specNonce = unhex("cafebabefacedbaddecaf888")
    private val specPlaintext = unhex(
        "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" +
            "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255",
    )
    private val specCiphertext =
        "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa" +
            "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad"

    /** Test case 15: four blocks, no AAD. */
    @Test fun gcmSpecTestCase15() {
        val sealed = AesGcm.seal(specKey, specNonce, specPlaintext, ByteArray(0))
        assertEquals(specCiphertext + "b094dac5d93471bdec1a502270e3cc6c", sealed.hex())
    }

    /** Test case 16: a partial last block and 20 bytes of AAD. */
    @Test fun gcmSpecTestCase16WithAdditionalData() {
        val plaintext = specPlaintext.copyOf(60)
        val aad = unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        val sealed = AesGcm.seal(specKey, specNonce, plaintext, aad)
        assertEquals(specCiphertext.substring(0, 120) + "76fc6ece0f4e1768cddf8853bb2d551b", sealed.hex())
        assertContentEquals(plaintext, AesGcm.open(specKey, specNonce, sealed, aad))
    }

    /** One answer for every way an open can fail: no caller may learn which input was wrong. */
    @Test fun everyAlteredInputFailsTheSameWay() {
        val aad = utf8("aad")
        val sealed = AesGcm.seal(specKey, specNonce, utf8("body"), aad)
        assertNotNull(AesGcm.open(specKey, specNonce, sealed, aad))

        assertNull(AesGcm.open(specKey.copyOf().also(::flippingFirstBit), specNonce, sealed, aad))
        assertNull(AesGcm.open(specKey, specNonce.copyOf().also(::flippingFirstBit), sealed, aad))
        assertNull(AesGcm.open(specKey, specNonce, sealed.copyOf().also(::flippingFirstBit), aad))
        assertNull(AesGcm.open(specKey, specNonce, sealed.copyOf().also(::flippingLastBit), aad))
        assertNull(AesGcm.open(specKey, specNonce, sealed, utf8("aae")))
        assertNull(AesGcm.open(specKey, specNonce, sealed, ByteArray(0)))
        assertNull(AesGcm.open(specKey, specNonce, sealed.copyOf(sealed.size - 1), aad))
        assertNull(AesGcm.open(specKey, specNonce, ByteArray(15), aad))
        assertNull(AesGcm.open(specKey, specNonce, ByteArray(0), aad))
    }

    /** Format keys take a caller-supplied nonce, including the same one twice: each call is a fresh cipher. */
    @Test fun sealingTwiceWithTheSameNonceIsDeterministicAndDoesNotThrow() {
        val first = AesGcm.seal(specKey, specNonce, utf8("body"), ByteArray(0))
        val second = AesGcm.seal(specKey, specNonce, utf8("body"), ByteArray(0))
        assertContentEquals(first, second)
    }

    @Test fun wrongKeyOrNonceWidthIsAProgrammingError() {
        assertFailsWith<IllegalArgumentException> { AesGcm.seal(ByteArray(16), zeroNonce, ByteArray(0), ByteArray(0)) }
        assertFailsWith<IllegalArgumentException> { AesGcm.seal(zeroKey, ByteArray(16), ByteArray(0), ByteArray(0)) }
        assertFailsWith<IllegalArgumentException> { AesGcm.open(zeroKey, ByteArray(8), ByteArray(32), ByteArray(0)) }
    }

    /** CryptoKit's `SealedBox.combined`: nonce, ciphertext, tag, and nothing else. */
    @Test fun theCombinedFramingIsNonceThenCiphertextThenTag() {
        val aad = unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        val combined = AesGcm.sealCombined(specKey, specNonce, specPlaintext.copyOf(60), aad)
        assertEquals(
            specNonce.hex() + specCiphertext.substring(0, 120) + "76fc6ece0f4e1768cddf8853bb2d551b",
            combined.hex(),
        )
        assertContentEquals(specPlaintext.copyOf(60), AesGcm.openCombined(specKey, combined, aad))
        assertNull(AesGcm.openCombined(specKey, combined, ByteArray(0)))

        // An empty plaintext is the shortest legal box.
        val empty = AesGcm.sealCombined(zeroKey, zeroNonce, ByteArray(0), ByteArray(0))
        assertEquals(AesGcm.COMBINED_OVERHEAD_BYTES, empty.size)
        assertContentEquals(ByteArray(0), AesGcm.openCombined(zeroKey, empty, ByteArray(0)))
        assertFailsWith<IllegalArgumentException> { AesGcm.openCombined(zeroKey, ByteArray(27), ByteArray(0)) }
    }
}

class Pbkdf2Test {

    private val implementations = listOf(
        "Mac (default)" to MacPbkdf2HmacSha512,
        "JCA provider" to JcaPbkdf2HmacSha512,
    )

    @Test fun theDefaultIsTheImplementationThatHashesTheBytesItIsGiven() {
        assertTrue(Pbkdf2HmacSha512.Default === MacPbkdf2HmacSha512)
    }

    /**
     * The PBKDF2-HMAC-SHA512 vectors that circulate with RFC 6070's inputs (RFC 6070 itself
     * only covers SHA-1). Confirmed here against OpenSSL through Python's `hashlib`.
     */
    @Test fun publishedVectorsHoldForBothImplementations() {
        val vectors = listOf(
            Triple("password" to "salt", 1,
                "867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252" +
                    "c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b60a57fce"),
            Triple("password" to "salt", 2,
                "e1d9c16aa681708a45f5c7c4e215ceb66e011a2e9f0040713f18aefdb866d53c" +
                    "f76cab2868a39b9f7840edce4fef5a82be67335c77a6068e04112754f27ccf4e"),
            Triple("password" to "salt", 4096,
                "d197b1b33db0143e018b12f3d1d1479e6cdebdcc97c5c0f87f6902e072f457b5" +
                    "143f30602641b3d55cd335988cb36b84376060ecd532e039b742a239434af2d5"),
            Triple("passwordPASSWORDpassword" to "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096,
                "8c0511f4c6e597c6ac6315d8f0362e225f3c501495ba23b868c005174dc4ee71" +
                    "115b59f9e60cd9532fa33e0f75aefe30225c583a186cd82bd4daea9724a3d3b8"),
        )
        for ((name, pbkdf2) in implementations) {
            for ((inputs, iterations, expected) in vectors) {
                val (password, salt) = inputs
                val full = pbkdf2.derive(utf8(password), utf8(salt), iterations, 64)
                assertEquals(expected, full.hex(), "$name, $password, $iterations rounds")
                // dkLen 32, the only length Snippets uses, is the first half of block one…
                assertEquals(expected.substring(0, 64), pbkdf2.derive(utf8(password), utf8(salt), iterations, 32).hex())
            }
            // …and a length past one block exercises the block counter.
            val long = pbkdf2.derive(utf8("password"), utf8("salt"), 2, 100)
            assertEquals(100, long.size)
            assertEquals(vectors[1].third, long.copyOf(64).hex(), name)
        }
    }

    /**
     * The trap this interface exists for: `PBEKeySpec` takes `char[]` and the provider decides
     * how those become bytes. Each case is `CCKeyDerivationPBKDF` output over the NFC UTF-8
     * of the password, for precomposed, decomposed, astral (surrogate-pair) and compatibility
     * characters, and one password longer than a SHA-512 block (which HMAC hashes first).
     */
    @Test fun nonAsciiAndNonBmpPasswordsMatchCommonCryptoInBothImplementations() {
        val salt = counting(0xc0, 16)
        var checked = 0
        for (case in SwiftReference.json.array("kdf")) {
            val iterations = case.string("iterations").toInt()
            if (iterations == 600_000) continue   // measured in the test below
            val password = unhex(case.string("nfcUTF8"))
            for ((name, pbkdf2) in implementations) {
                assertEquals(
                    case.string("key"), pbkdf2.derive(password, salt, iterations, 32).hex(),
                    "$name, ${case.string("label")}, $iterations rounds",
                )
                checked += 1
            }
        }
        assertEquals(6 * 3 * 2, checked)
    }

    /** The two implementations agree on arbitrary UTF-8 passwords, salts and counts, not just the vectors. */
    @Test fun theTwoImplementationsAgreeOnRandomInputs() {
        val random = SeededRandom(0x9B4D_F2)
        val alphabet = listOf("a", "Z", "0", " ", "\u00E9", "e\u0301", "ß", "🔐", "\uD834\uDD1E", "한", "\u0000", "\u07FF", "\uFFFD")
        repeat(40) { round ->
            val password = buildString { repeat(1 + round % 23) { append(alphabet[(random.next() ushr 8).mod(alphabet.size)]) } }
            val salt = random.bytes(1 + round % 40)
            val iterations = 1 + round % 7
            val length = 1 + (round * 13) % 150
            assertEquals(
                MacPbkdf2HmacSha512.derive(utf8(password), salt, iterations, length).hex(),
                JcaPbkdf2HmacSha512.derive(utf8(password), salt, iterations, length).hex(),
                "round $round",
            )
        }
    }

    /** A password that is not UTF-8 is still a password for the byte-level implementation; the provider cannot take it. */
    @Test fun onlyTheByteLevelImplementationTakesAnArbitraryByteString() {
        val notUtf8 = unhex("ff00fe80c0")
        assertEquals(32, MacPbkdf2HmacSha512.derive(notUtf8, utf8("salt"), 2, 32).size)
        assertFailsWith<IllegalArgumentException> { JcaPbkdf2HmacSha512.derive(notUtf8, utf8("salt"), 2, 32) }
    }

    @Test fun nonPositiveParametersAreRefused() {
        for ((_, pbkdf2) in implementations) {
            assertFailsWith<IllegalArgumentException> { pbkdf2.derive(utf8("p"), utf8("s"), 0, 32) }
            assertFailsWith<IllegalArgumentException> { pbkdf2.derive(utf8("p"), utf8("s"), -1, 32) }
            assertFailsWith<IllegalArgumentException> { pbkdf2.derive(utf8("p"), utf8("s"), 1, 0) }
        }
    }

    /**
     * The pinned production cost, once per implementation, against CommonCrypto's answer for
     * an NFD-typed and an astral password. Prints the time each takes on this machine.
     */
    @Test fun sixHundredThousandRoundsMatchCommonCryptoAndAreTimed() {
        val salt = counting(0xc0, 16)
        val cases = SwiftReference.json.array("kdf").filter { it.string("iterations") == "600000" }
        assertEquals(2, cases.size)
        for ((name, pbkdf2) in implementations) {
            // Warm the JIT so the figure is the steady state rather than the interpreter's.
            pbkdf2.derive(utf8("warm-up"), salt, 20_000, 32)
            for (case in cases) {
                val password = unhex(case.string("nfcUTF8"))
                val started = System.nanoTime()
                val key = pbkdf2.derive(password, salt, 600_000, 32)
                val milliseconds = (System.nanoTime() - started) / 1_000_000
                println("PBKDF2-HMAC-SHA512, 600000 rounds, $name, ${case.string("label")}: $milliseconds ms")
                assertEquals(case.string("key"), key.hex(), "$name, ${case.string("label")}")
            }
        }
    }
}
