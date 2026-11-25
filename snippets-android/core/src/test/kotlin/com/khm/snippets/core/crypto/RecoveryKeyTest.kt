package com.khm.snippets.core.crypto

import org.junit.Test
import java.util.Locale
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** `Tests/Core/CryptoTests.swift`, suite 9 "Recovery key". Test names are the Swift ones. */
class RecoveryKeyTest {

    @Test fun ageneratedKeyRoundTripsThroughItsPrintedForm() {
        val bytes = RecoveryKey.generate()
        assertEquals(RecoveryKey.BYTE_COUNT, bytes.size)

        val printed = RecoveryKey.formatted(bytes)
        assertContentEquals(bytes, RecoveryKey.decode(printed))
    }

    /** Including the patterns a bit-packing bug mangles. */
    @Test fun everyExtremeBitPatternRoundTrips() {
        val patterns = listOf(
            filled(0x00, 16), filled(0xFF, 16), filled(0xAA, 16), filled(0x55, 16),
            ByteArray(16) { it.toByte() }, ByteArray(16) { (255 - it).toByte() },
        )
        for (bytes in patterns) {
            assertContentEquals(bytes, RecoveryKey.decode(RecoveryKey.encode(bytes)), bytes.hex())
        }
    }

    @Test fun athousandRandomKeysRoundTrip() {
        val random = SeededRandom(0xDEC0_DE01)
        repeat(1_000) {
            val bytes = random.bytes(RecoveryKey.BYTE_COUNT)
            assertContentEquals(bytes, RecoveryKey.decode(RecoveryKey.encode(bytes)))
        }
    }

    /** 27 characters, not 26: 2 spare bits cannot catch every typo. */
    @Test fun theCanonicalFormIsTwentySevenCrockfordCharactersAndTheGroupedFormIsFours() {
        val printed = RecoveryKey.encode(filled(0xA5, 16))
        assertEquals(27, printed.length)
        assertTrue(printed.all { it in RecoveryKey.ALPHABET })

        val grouped = RecoveryKey.formatted(filled(0xA5, 16))
        assertEquals(listOf(4, 4, 4, 4, 4, 4, 3), grouped.split("-").map { it.length })
    }

    @Test fun theAlphabetOmitsTheGlyphsCrockfordOmits() {
        assertEquals(32, RecoveryKey.ALPHABET.length)
        assertEquals(32, RecoveryKey.ALPHABET.toSet().size)
        for (excluded in "ILOU") assertFalse(excluded in RecoveryKey.ALPHABET)
        assertEquals("0123456789ABCDEFGHJKMNPQRSTVWXYZ", RecoveryKey.ALPHABET)
    }

    // The checksum

    /**
     * **The** property: a user who mistypes one character must be told they mistyped it.
     * For each key, every position, every other symbol: 27 × 31 substitutions.
     */
    @Test fun everySingleCharacterSubstitutionIsCaught() {
        val random = SeededRandom(0xC0FF_EE42)

        for (sample in 0 until 12) {
            val bytes = if (sample == 0) ByteArray(RecoveryKey.BYTE_COUNT) else random.bytes(RecoveryKey.BYTE_COUNT)
            val canonical = RecoveryKey.encode(bytes)

            for (position in canonical.indices) {
                for (replacement in RecoveryKey.ALPHABET) {
                    if (replacement == canonical[position]) continue
                    val mutated = StringBuilder(canonical).also { it.setCharAt(position, replacement) }.toString()

                    assertFailsWith<RecoveryKey.Failure>(
                        "sample $sample, position $position, '${canonical[position]}' -> '$replacement'",
                    ) { RecoveryKey.decode(mutated) }
                }
            }
        }
    }

    /** Not every transposition: neighbours differing by exactly 16 slip through. The honest claim is "most". */
    @Test fun mostAdjacentTranspositionsAreCaught() {
        val random = SeededRandom(0x7A50_0001)
        var attempts = 0
        var caught = 0

        repeat(50) {
            val canonical = RecoveryKey.encode(random.bytes(RecoveryKey.BYTE_COUNT)).toCharArray()
            for (position in 0 until canonical.size - 1) {
                if (canonical[position] == canonical[position + 1]) continue
                val swapped = canonical.copyOf()
                swapped[position] = canonical[position + 1]
                swapped[position + 1] = canonical[position]
                attempts += 1
                if (runCatching { RecoveryKey.decode(String(swapped)) }.isFailure) caught += 1
            }
        }

        assertTrue(attempts > 500)
        assertTrue(caught.toDouble() / attempts > 0.9)
    }

    @Test fun adroppedOrDoubledCharacterIsCaught() {
        val canonical = RecoveryKey.encode(filled(0x3C, 16))

        assertEquals(26, assertFailsWith<RecoveryKey.Failure.WrongLength> {
            RecoveryKey.decode(canonical.dropLast(1))
        }.count)
        assertEquals(28, assertFailsWith<RecoveryKey.Failure.WrongLength> {
            RecoveryKey.decode(canonical + "0")
        }.count)
    }

    @Test fun acharacterOutsideTheAlphabetIsNamedInTheError() {
        val canonical = RecoveryKey.encode(filled(0x3C, 16))
        val withU = "U" + canonical.drop(1)

        assertEquals("U", assertFailsWith<RecoveryKey.Failure.InvalidCharacter> { RecoveryKey.decode(withU) }.character)
    }

    // What a human actually types

    /** Read off a photo of a scrap of paper, at midnight. Every one of these spellings is the same key. */
    @Test fun caseSeparatorsAndConfusableGlyphsAllDecodeToTheSameKey() {
        val bytes = RecoveryKey.generate()
        val canonical = RecoveryKey.encode(bytes)
        val grouped = RecoveryKey.grouped(canonical)

        val spellings = listOf(
            canonical,
            canonical.lowercase(Locale.ROOT),
            grouped,
            grouped.lowercase(Locale.ROOT),
            grouped.replace("-", " "),
            grouped.replace("-", "\u2014"),   // em dash, courtesy of Notes
            grouped.replace("-", "\u00A0"),   // non-breaking space
            "  $grouped\n",
            canonical.replace("1", "I"),
            canonical.replace("1", "l"),
            canonical.replace("0", "O"),
            canonical.replace("0", "o"),
        )

        for (spelling in spellings) {
            assertContentEquals(bytes, RecoveryKey.decode(spelling), "spelling: $spelling")
        }
    }

    @Test fun allConfusablesFoldAtOnceAcrossAWholeKey() {
        val random = SeededRandom(0x1101_0011)
        repeat(200) {
            val bytes = random.bytes(RecoveryKey.BYTE_COUNT)
            val canonical = RecoveryKey.encode(bytes)
            val misread = canonical.replace("1", "l").replace("0", "O")
            assertContentEquals(bytes, RecoveryKey.decode(misread))
        }
    }

    /** Two different strings must never decode to the same key. */
    @Test fun anEncodingWithNonZeroTrailingBitsIsRefusedRatherThanSilentlyTruncated() {
        val bytes = ByteArray(RecoveryKey.BYTE_COUNT)
        val symbols = RecoveryKey.symbolsFromBytes(bytes)
        assertEquals(RecoveryKey.PAYLOAD_CHARACTER_COUNT, symbols.size)

        // Set the padding bits without disturbing the 3 payload bits above them.
        symbols[RecoveryKey.PAYLOAD_CHARACTER_COUNT - 1] = symbols[RecoveryKey.PAYLOAD_CHARACTER_COUNT - 1] or 0b11
        val forged = (symbols.toList() + RecoveryKey.checkSymbol(symbols)).map { RecoveryKey.ALPHABET[it] }.joinToString("")

        // The checksum is recomputed over the mutated payload, so it agrees: this string
        // is rejected by the canonical-encoding rule alone.
        assertFailsWith<RecoveryKey.Failure.NonCanonical> { RecoveryKey.decode(forged) }
    }

    @Test fun encodingRefusesAnythingThatIsNotSixteenBytes() {
        assertEquals(15, assertFailsWith<RecoveryKey.Failure.WrongByteCount> { RecoveryKey.encode(ByteArray(15)) }.count)
        assertEquals(0, assertFailsWith<RecoveryKey.Failure.WrongByteCount> { RecoveryKey.encode(ByteArray(0)) }.count)
        assertEquals(17, assertFailsWith<RecoveryKey.Failure.WrongByteCount> { RecoveryKey.formatted(ByteArray(17)) }.count)
    }

    @Test fun generatedKeysAreFullWidthAndDistinct() {
        val keys = (0 until 64).map { RecoveryKey.generate() }
        assertEquals(64, keys.map { it.hex() }.toSet().size)
        assertTrue(keys.all { it.size == RecoveryKey.BYTE_COUNT })
        assertFalse(keys.any { it.contentEquals(ByteArray(RecoveryKey.BYTE_COUNT)) })
    }

    /** End to end: a recovery key written on paper, typed back in badly, and used to unwrap the library key. */
    @Test fun arecoveryKeyTypedBackInBadlyStillUnwrapsTheLibraryKey() {
        val libraryKey = Bytes.random(SnippetCrypto.KEY_BYTE_COUNT)
        val recovery = RecoveryKey.generate()
        val salt = SnippetCrypto.randomBytes(SnippetCrypto.SALT_BYTE_COUNT)

        val wrapped = KeyWrap.wrap(libraryKey, recovery, KeyWrap.Purpose.RECOVERY, "k-1", salt)

        // Off the card in lower case, with the grouping dashes the UI printed.
        val asWrittenDown = RecoveryKey.formatted(recovery).lowercase(Locale.ROOT)
        val retyped = RecoveryKey.decode(asWrittenDown)

        assertContentEquals(libraryKey, KeyWrap.unwrap(wrapped, retyped, KeyWrap.Purpose.RECOVERY, "k-1", salt))
    }

    // Known answers

    /** `GitSyncVaultTests.knownAnswerMatchesTheLinuxMirror`, part (a). */
    @Test fun knownAnswerMatchesTheLinuxMirror() {
        val secret = counting(0xa0, 16)
        assertEquals("M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ", RecoveryKey.formatted(secret))
        assertEquals("M2GT58X4MPKAFA59NANTSBDENWJ", RecoveryKey.encode(secret))
        assertContentEquals(secret, RecoveryKey.decode("M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ"))
    }

    /** `RecoveryKey.encode` and `.formatted` from Swift, for six byte patterns. */
    @Test fun encodingMatchesSwiftForEveryReferencePattern() {
        val cases = SwiftReference.json.array("recovery")
        assertEquals(6, cases.size)
        for (case in cases) {
            val bytes = unhex(case.string("bytes"))
            assertEquals(case.string("encoded"), RecoveryKey.encode(bytes))
            assertEquals(case.string("formatted"), RecoveryKey.formatted(bytes))
            assertContentEquals(bytes, RecoveryKey.decode(case.string("formatted")))
        }
    }

    /**
     * `RecoveryKey.decode` from Swift for 36 typed spellings: which decode, and which of the
     * five distinct failures each of the others is, with its payload (the length Swift
     * counted, the character it named).
     */
    @Test fun decodingMatchesSwiftOnEveryReferenceSpelling() {
        val cases = SwiftReference.json.array("recoveryDecodes")
        assertEquals(36, cases.size)
        for (case in cases) {
            val input = fromUtf16Hex(case.string("inputUTF16"))
            val actual = try {
                "ok:" + RecoveryKey.decode(input).hex()
            } catch (failure: RecoveryKey.Failure) {
                when (failure) {
                    is RecoveryKey.Failure.WrongByteCount -> "wrongByteCount:${failure.count}"
                    is RecoveryKey.Failure.WrongLength -> "wrongLength:${failure.count}"
                    is RecoveryKey.Failure.InvalidCharacter -> "invalidCharacter:" + scalars(failure.character)
                    is RecoveryKey.Failure.ChecksumMismatch -> "checksumMismatch"
                    is RecoveryKey.Failure.NonCanonical -> "nonCanonical"
                }
            }
            assertEquals(case.string("result"), actual, "input ${case.string("inputUTF16")}")
        }
    }

    private fun scalars(text: String): String =
        text.codePoints().toArray().joinToString("+") { "%04x".format(it) }

    // Added: the behaviours a port is most likely to get wrong.

    /** JVM upper-casing with a Turkish default locale turns `i` into `I-with-dot (U+0130)`, which is not `I`, which is not `1`. */
    @Test fun caseFoldingDoesNotDependOnTheDefaultLocale() {
        val bytes = ByteArray(16)                            // encodes to zeros
        val key = unhex("08421084210842108421084210842108")  // 25 symbols of value 1
        val canonical = RecoveryKey.encode(key)
        assertEquals("1".repeat(25) + "0H", canonical)
        val typed = canonical.replace('1', 'i').replace('0', 'o')

        val saved = Locale.getDefault()
        try {
            for (tag in listOf("tr-TR", "az-AZ", "lt-LT", "en-US")) {
                Locale.setDefault(Locale.forLanguageTag(tag))
                assertContentEquals(key, RecoveryKey.decode(typed), tag)
                assertContentEquals(bytes, RecoveryKey.decode("o".repeat(27)), tag)
            }
        } finally {
            Locale.setDefault(saved)
        }
    }

    /**
     * Swift iterates `Character`s, and `\r\n` is a single one that is neither `\r` nor `\n`:
     * a key pasted with Windows line breaks is not accepted, while lone `\r` and `\n` are
     * dropped. Mirrored, and worth knowing about.
     */
    @Test fun aWindowsLineBreakIsNotASeparatorExactlyAsInSwift() {
        val grouped = "M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ"
        assertContentEquals(counting(0xa0, 16), RecoveryKey.decode(grouped.replace("-", "\n")))
        assertContentEquals(counting(0xa0, 16), RecoveryKey.decode(grouped.replace("-", "\r")))
        assertContentEquals(counting(0xa0, 16), RecoveryKey.decode(grouped.replace("-", "\n\r")))
        assertEquals(33, assertFailsWith<RecoveryKey.Failure.WrongLength> {
            RecoveryKey.decode(grouped.replace("-", "\r\n"))
        }.count)
        assertEquals(28, assertFailsWith<RecoveryKey.Failure.WrongLength> {
            RecoveryKey.decode(grouped + "\r\n")
        }.count)
    }

    /** Swift compares characters by canonical equivalence, so the Kelvin sign is the letter K. */
    @Test fun aCanonicallyEquivalentGlyphDecodesAsItsLetter() {
        assertContentEquals(counting(0xa0, 16), RecoveryKey.decode("M2GT58X4MP\u212AAFA59NANTSBDENWJ"))
        // A compatibility lookalike is not canonically equivalent and stays a typo.
        assertEquals("\uFF2D", assertFailsWith<RecoveryKey.Failure.InvalidCharacter> {
            RecoveryKey.decode("\uFF2D2GT58X4MPKAFA59NANTSBDENWJ")
        }.character)
    }

    /** Each of the five failures is a different answer; a typo is never reported as anything else. */
    @Test fun theFailureCasesAreDistinct() {
        val canonical = "M2GT58X4MPKAFA59NANTSBDENWJ"
        assertFailsWith<RecoveryKey.Failure.WrongLength> { RecoveryKey.decode("") }
        assertFailsWith<RecoveryKey.Failure.WrongLength> { RecoveryKey.decode(canonical.drop(1)) }
        assertFailsWith<RecoveryKey.Failure.InvalidCharacter> { RecoveryKey.decode(canonical.replace('M', '*')) }
        assertFailsWith<RecoveryKey.Failure.ChecksumMismatch> { RecoveryKey.decode(canonical.replace('2', '3')) }
        assertFailsWith<RecoveryKey.Failure.ChecksumMismatch> { RecoveryKey.decode(canonical.dropLast(1) + "K") }
        assertFailsWith<RecoveryKey.Failure.NonCanonical> { RecoveryKey.decode("0".repeat(25) + "1K") }
        assertFailsWith<RecoveryKey.Failure.WrongByteCount> { RecoveryKey.encode(ByteArray(8)) }
        // Length is judged before the alphabet, the alphabet before the checksum.
        assertFailsWith<RecoveryKey.Failure.WrongLength> { RecoveryKey.decode("U") }
        assertFailsWith<RecoveryKey.Failure.InvalidCharacter> { RecoveryKey.decode("U" + "0".repeat(26)) }
    }

    @Test fun theCheckSymbolIsTheOddWeightedSumModuloThirtyTwo() {
        assertEquals(0, RecoveryKey.checkSymbol(IntArray(26)))
        assertEquals(1, RecoveryKey.checkSymbol(IntArray(26).also { it[0] = 1 }))
        assertEquals(3, RecoveryKey.checkSymbol(IntArray(26).also { it[1] = 1 }))
        assertEquals(51 % 32, RecoveryKey.checkSymbol(IntArray(26).also { it[25] = 1 }))
        assertEquals((1 * 5 + 3 * 7 + 51 * 31) % 32, RecoveryKey.checkSymbol(IntArray(26).also { it[0] = 5; it[1] = 7; it[25] = 31 }))
    }

    /** 128 bits fill 25 symbols and leave 3, the high bits of a 26th. */
    @Test fun theBitPackingIsBigEndianFiveBitsPerSymbol() {
        val first = RecoveryKey.symbolsFromBytes(unhex("80000000000000000000000000000001"))
        assertEquals(26, first.size)
        assertEquals(0b10000, first[0])
        assertEquals(0b00100, first[25])    // the last bit of the last byte, then two zero bits
        assertTrue(first.slice(1..24).all { it == 0 })
        assertContentEquals(unhex("80000000000000000000000000000001"), RecoveryKey.bytesFromSymbols(first))
        assertEquals("Z".repeat(25) + "W", RecoveryKey.encode(filled(0xFF, 16)).dropLast(1))
    }

    @Test fun groupingIsFoursWithARaggedTail() {
        assertEquals("", RecoveryKey.grouped(""))
        assertEquals("ABC", RecoveryKey.grouped("ABC"))
        assertEquals("ABCD", RecoveryKey.grouped("ABCD"))
        assertEquals("ABCD-E", RecoveryKey.grouped("ABCDE"))
        assertEquals("0000-0000-0000-0000-0000-0000-000", RecoveryKey.formatted(ByteArray(16)))
    }

    @Test fun normalisationDropsExactlyTheListedSeparators() {
        val dropped = listOf(" ", "\t", "\n", "\r", "\u00A0", "-", "\u2010", "\u2011", "\u2012", "\u2013", "\u2014", "\u2212", "_")
        for (separator in dropped) assertEquals("AB", RecoveryKey.normalized("a${separator}b"), "U+%04X".format(separator[0].code))
        // Near misses that stay: horizontal bar, thin space, zero-width space, full stop.
        for (kept in listOf("\u2015", "\u2009", "\u200B", ".", "\u3000")) {
            assertEquals("A${kept}B", RecoveryKey.normalized("a${kept}b"))
        }
        assertEquals("1100", RecoveryKey.normalized("iLoO"))
        assertEquals("1100", RecoveryKey.normalized("IlOo"))
    }
}
