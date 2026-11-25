package com.khm.snippets.core.crypto

import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BytesTest {

    @Test fun hexIsLowercaseAndRoundTrips() {
        val all = ByteArray(256) { it.toByte() }
        val text = Bytes.toHex(all)
        assertEquals(512, text.length)
        assertTrue(text.startsWith("000102") && text.endsWith("fdfeff"))
        assertEquals(text, text.lowercase())
        assertContentEquals(all, Bytes.fromHex(text))
        assertContentEquals(all, Bytes.fromHex(text.uppercase()))
        assertEquals("0a0b", Bytes.toHex(byteArrayOf(9, 10, 11, 12), 1, 2))
        assertEquals("", Bytes.toHex(ByteArray(0)))
    }

    @Test fun hexDecodingRefusesOddLengthsAndForeignCharacters() {
        for (bad in listOf("a", "abc", "0g", "0x10", " 0a", "0a ", "0\u0661", "\uFF21\uFF22")) {
            assertNull(Bytes.fromHex(bad), bad)
        }
        assertContentEquals(ByteArray(0), Bytes.fromHex(""))
    }

    /** Readers of hashes and ids require the lowercase spelling; uppercase is another string. */
    @Test fun lowercaseHexDecodingRefusesUppercase() {
        assertContentEquals(byteArrayOf(0xAB.toByte(), 0xCD.toByte()), Bytes.fromLowercaseHex("abcd"))
        assertNull(Bytes.fromLowercaseHex("ABCD"))
        assertNull(Bytes.fromLowercaseHex("abCd"))
    }

    @Test fun constantTimeEqualsComparesContentNotIdentity() {
        assertTrue(Bytes.constantTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 3)))
        assertTrue(Bytes.constantTimeEquals(ByteArray(0), ByteArray(0)))
        assertFalse(Bytes.constantTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 4)))
        assertFalse(Bytes.constantTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(0, 2, 3)))
        assertFalse(Bytes.constantTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2)))
        // Bytes that differ only in the sign bit, which a signed comparison could confuse.
        assertFalse(Bytes.constantTimeEquals(byteArrayOf(0x7F), byteArrayOf(0xFF.toByte())))
    }

    @Test fun wipeZeroesInPlaceAndToleratesNull() {
        val key = filled(0xAA, 32)
        Bytes.wipe(key)
        assertContentEquals(ByteArray(32), key)
        val characters = "secret".toCharArray()
        Bytes.wipe(characters)
        assertContentEquals(CharArray(6), characters)
        Bytes.wipe(null as ByteArray?)
        Bytes.wipe(null as CharArray?)
    }

    @Test fun bigEndianIntegersAreMostSignificantFirst() {
        assertEquals("00000000", Bytes.u32be(0).hex())
        assertEquals("0000000b", Bytes.u32be(11).hex())
        assertEquals("01020304", Bytes.u32be(0x01020304).hex())
        assertEquals("ffffffff", Bytes.u32be(-1).hex())
        assertEquals("00000000000927c0", Bytes.u64be(600_000).hex())
        assertEquals("0102030405060708", Bytes.u64be(0x0102030405060708).hex())
        assertEquals("8000000000000000", Bytes.u64be(Long.MIN_VALUE).hex())
    }

    @Test fun concatJoinsInOrder() {
        assertEquals("010203", Bytes.concat(byteArrayOf(1), ByteArray(0), byteArrayOf(2, 3)).hex())
        assertEquals("", Bytes.concat().hex())
    }

    @Test fun randomBytesAreFullWidthAndNotRepeatable() {
        val first = Bytes.random(32)
        val second = Bytes.random(32)
        assertEquals(32, first.size)
        assertNotEquals(first.hex(), second.hex())
        assertNotEquals(ByteArray(32).hex(), first.hex())
        assertEquals(0, Bytes.random(0).size)
    }

    // UTF-8 with Swift's `String` semantics

    @Test fun utf8EncodingMatchesTheStandardEncoderForWellFormedText() {
        for (text in listOf("", "ascii", "caf\u00E9 ☕\uFE0F \u2014 na\u00EFve 🔐 \uD83C\uDDEF\uD83C\uDDF5", "\u0000\u007F\u0080\u07FF\u0800\uFFFF")) {
            assertContentEquals(text.toByteArray(Charsets.UTF_8), Utf8.encode(text), text)
            assertContentEquals(text.toByteArray(Charsets.UTF_8), Utf8.encode(text.toCharArray()), text)
            assertContentEquals(text.toByteArray(Charsets.UTF_8), Utf8.encodeStrict(text), text)
        }
    }

    /**
     * A Swift `String` cannot hold an unpaired surrogate: one arriving from UTF-16 becomes
     * U+FFFD. `toByteArray()` would write `?` instead, and the two would hash differently.
     */
    @Test fun anUnpairedSurrogateBecomesTheReplacementCharacterAsItDoesInSwift() {
        assertEquals("61efbfbd62", Utf8.encode("a\uD83Db").hex())
        assertEquals("efbfbd", Utf8.encode("\uDE00").hex())
        assertEquals("61efbfbd", Utf8.encode("a\uD83D").hex())
        assertNull(Utf8.encodeStrict("a\uD83Db"))
        assertNull(Utf8.encodeStrict("\uDE00"))
    }

    @Test fun strictDecodingRefusesEverythingThatIsNotWellFormedUTF8() {
        assertEquals("\u00E9😀", Utf8.decodeStrict(unhex("c3a9f09f9880")))
        assertEquals("", Utf8.decodeStrict(ByteArray(0)))
        for (bad in listOf("c0af", "eda080", "f4908080", "f09f98", "80", "c3", "ff", "e08080", "f8888080")) {
            assertNull(Utf8.decodeStrict(unhex(bad)), bad)
        }
    }
}

class UuidsTest {

    private val id = UUID.fromString("0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9")

    @Test fun parsingAcceptsExactlyTheEightFourFourFourTwelveForm() {
        assertEquals(id, Uuids.parse("0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9"))
        assertEquals(id, Uuids.parse("0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9"))
        assertEquals(id, Uuids.parse("0a1B2c3D-4e5F-4071-8293-A4b5C6d7E8f9"))
        assertEquals(UUID(0, 0), Uuids.parse("00000000-0000-0000-0000-000000000000"))
        assertEquals(UUID(-1, -1), Uuids.parse("ffffffff-ffff-ffff-ffff-ffffffffffff"))
    }

    /** Every one of these is accepted by `java.util.UUID.fromString` or by a sloppy parser, and by Foundation not. */
    @Test fun lenientSpellingsAreRefused() {
        val refused = listOf(
            "1-1-1-1-1",                                        // java.util.UUID accepts this
            "0a1b2c3d4e5f40718293a4b5c6d7e8f9",                 // no hyphens
            "{0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9}",
            "0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9 ",
            " 0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9",
            "0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f",              // 35
            "0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f90",            // 37
            "0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8fg",
            "0a1b2c3-d4e5f-4071-8293-a4b5c6d7e8f9",             // hyphen one place early
            "0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8-9",
            "+a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9",
            "0x1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9",
            "0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f\uFF19",         // fullwidth digit
            "0a1b2c3d\u20104e5f-4071-8293-a4b5c6d7e8f9",         // U+2010 for a hyphen
            "",
        )
        for (text in refused) {
            assertNull(Uuids.parse(text), text)
            assertNull(Uuids.parseLowercase(text), text)
        }
    }

    /**
     * `UUID(uuidString:)` accepts a valid id followed by an embedded NUL (observed with
     * Swift 6.4; it reads the text as a C string). That is not followed.
     */
    @Test fun anEmbeddedNulAfterAValidIdIsRefusedUnlikeFoundation() {
        assertNull(Uuids.parse("0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9\u0000"))
        assertNull(Uuids.parse("0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9\u0000trailing"))
    }

    /** Envelope ids, dataset ids and Git files are lowercase and readers require `text == lower(parsed)`. */
    @Test fun caseIsAnExplicitChoice() {
        val lower = "0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8f9"
        val upper = "0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9"
        assertEquals(id, Uuids.parseLowercase(lower))
        assertNull(Uuids.parseLowercase(upper))
        assertNull(Uuids.parseLowercase("0a1b2c3d-4e5f-4071-8293-a4b5c6d7e8F9"))
        assertEquals(id, Uuids.parseUppercase(upper))
        assertNull(Uuids.parseUppercase(lower))
        assertEquals(lower, Uuids.lowercase(id))
        assertEquals(upper, Uuids.uppercase(id))
        // Digits only: both forms at once.
        assertEquals(UUID(0x1111111111111111, 0x1111111111111111), Uuids.parseLowercase("11111111-1111-1111-1111-111111111111"))
        assertEquals(UUID(0x1111111111111111, 0x1111111111111111), Uuids.parseUppercase("11111111-1111-1111-1111-111111111111"))
    }

    /** HKDF info and AADs take the 16 raw bytes in the order of the hex digits. */
    @Test fun bytesAreInTextOrderMostSignificantFirst() {
        assertEquals("0a1b2c3d4e5f40718293a4b5c6d7e8f9", Uuids.toBytes(id).hex())
        assertEquals(SwiftReference.json.string("uuidBytes"), Uuids.toBytes(id).hex())
        assertEquals(id, Uuids.fromBytes(unhex("0a1b2c3d4e5f40718293a4b5c6d7e8f9")))
        assertEquals("ffffffffffffffff0000000000000000", Uuids.toBytes(UUID(-1, 0)).hex())
    }

    @Test fun everyRandomIdRoundTripsThroughTextAndBytes() {
        val random = SeededRandom(0x1D1D)
        repeat(500) {
            val bytes = random.bytes(16)
            val value = Uuids.fromBytes(bytes)
            assertContentEquals(bytes, Uuids.toBytes(value))
            assertEquals(value, Uuids.parse(Uuids.lowercase(value)))
            assertEquals(value, Uuids.parse(Uuids.uppercase(value)))
            assertEquals(Bytes.toHex(bytes), Uuids.lowercase(value).replace("-", ""))
        }
    }
}
