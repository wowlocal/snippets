package com.khm.snippets.core.vault

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Foundation's `ISO8601DateFormatter` beyond what vector V14 holds. Every expectation
 * here was read off a run of the real formatter (macOS 27, Swift 6.4): bit patterns are
 * `timeIntervalSinceReferenceDate.bitPattern`.
 */
class VaultTimestampTest {

    private fun bits(value: Double): String = java.lang.Long.toHexString(value.toRawBits())

    private fun parsedBits(text: String): String? = VaultTimestamp.parse(text)?.let(::bits)

    /**
     * The rounding is `floor(x + 0.5)`, not "round half away from zero": the two differ
     * for an exact half millisecond before 1970. A differential run of 830 000 values
     * against Foundation had no mismatch for this form and 36 641 for the other.
     */
    @Test fun halfMillisecondsRoundUpOnBothSidesOfTheUnixEpoch() {
        assertEquals("2001-01-01T00:00:00.001Z", VaultTimestamp.string(0.0005))
        assertEquals("2001-01-01T00:00:00.002Z", VaultTimestamp.string(0.0015))
        assertEquals("2001-01-01T00:00:00.003Z", VaultTimestamp.string(0.0025))
        assertEquals("2001-01-01T00:00:00.000Z", VaultTimestamp.string(-0.0005))
        assertEquals("2000-12-31T23:59:59.999Z", VaultTimestamp.string(-0.0015))
        assertEquals("2001-01-01T00:00:02.000Z", VaultTimestamp.string(1.9995))
        assertEquals("2026-10-01T20:20:01.000Z", VaultTimestamp.string(812578800.9995))
        assertEquals("2026-10-01T20:20:00.999Z", VaultTimestamp.string(812578800.99949))

        // Negative milliseconds since 1970, exactly on a half: Foundation goes up, toward the later instant.
        assertEquals("1878-09-02T06:02:29.355Z", VaultTimestamp.string(-3860416650.6455))
        assertEquals(-2882109450645, VaultTimestamp.epochMillis(-3860416650.6455))
        assertEquals("1877-09-20T22:07:28.826Z", VaultTimestamp.string(-3890339551.1745))
        assertEquals("1681-08-07T06:12:26.159Z", VaultTimestamp.string(-10079315253.8415))
        assertEquals("0001-01-01T00:00:00.000Z", VaultTimestamp.string(-63114076800.0005))
        // Not on a half: ordinary rounding.
        assertEquals("1903-05-12T06:06:00.243Z", VaultTimestamp.string(-3081347639.757))
        assertEquals("1854-12-30T07:13:59.994Z", VaultTimestamp.string(-4607513160.006))
        assertEquals("1917-03-10T23:29:17.407Z", VaultTimestamp.string(-2644878642.5925))
        assertEquals("1970-01-01T00:00:00.000Z", VaultTimestamp.string(-978307200.0005))
        assertEquals("1970-01-01T00:00:00.000Z", VaultTimestamp.string(-978307199.9995))
    }

    /** Foundation's Gregorian calendar is Julian before 1582-10-15, and prints a year before 1 as its year of era. */
    @Test fun theCalendarIsJulianBeforeTheGregorianCutover() {
        assertEquals("0001-01-01T00:00:00.000Z", VaultTimestamp.string(VaultTimestamp.DISTANT_PAST))
        assertEquals("1582-10-15T00:00:00.000Z", VaultTimestamp.string(-13197600000.0))
        assertEquals("1582-10-16T00:00:00.000Z", VaultTimestamp.string(-13197513600.0))
        assertEquals("1582-10-15T23:59:59.999Z", VaultTimestamp.string(-13197513600.001))
        assertEquals("1582-10-04T23:59:59.999Z", VaultTimestamp.string(-13197600000.001))
        assertEquals("0219-10-19T19:33:20.000Z", VaultTimestamp.string(-70000000000.0))
        assertEquals("0001-01-02T00:00:00.000Z", VaultTimestamp.string(-63145612800.0))
        assertEquals("0003-04-12T12:26:40.000Z", VaultTimestamp.string(-63200000000.0))
        assertEquals("10000-01-01T00:00:00.000Z", VaultTimestamp.string(252423993600.0))
        assertEquals("11507-08-17T05:20:00.000Z", VaultTimestamp.string(300000000000.0))

        assertEquals("c2089525b4000000", parsedBits("1582-10-04T00:00:00Z"))
        // The ten days that never happened are read as Julian dates.
        assertEquals("c208951b28000000", parsedBits("1582-10-05T00:00:00Z"))
        assertEquals("c20894bc3c000000", parsedBits("1582-10-14T00:00:00Z"))
        assertEquals("c208951b28000000", parsedBits("1582-10-15T00:00:00Z"))
        assertEquals("c20d7007d4000000", parsedBits("1500-02-29T00:00:00Z"))
        assertEquals("c201aee014000000", parsedBits("1700-02-29T00:00:00Z"))
        assertEquals("c22d57e5ff000000", parsedBits("0004-02-29T00:00:00Z"))
        assertEquals("c21d67c28aff0000", parsedBits("1000-06-15T12:00:00.250Z"))
        assertEquals("c22d678dcf000000", parsedBits("0000-01-01T00:00:00Z"))
        assertEquals("c22d6b5036000000", parsedBits("-0001-01-01T00:00:00Z"))
        assertEquals("c22d63c8c4ffff7d", parsedBits("0001-01-01T00:00:00.001Z"))
        assertEquals("424d62d23c7f8000", parsedBits("9999-12-31T23:59:59Z"))
        assertEquals("424d62d23c800000", parsedBits("10000-01-01T00:00:00.000Z"))
        assertEquals("425176592e000000", parsedBits("11507-08-17T05:20:00.000Z"))
    }

    @Test fun theParsersLeniencyIsFoundations() {
        val reference = "41c8377bf80fbe76" // 2026-10-01T20:20:00.123Z read back: 812578800.1229999
        val whole = "41c8377bf8000000"

        // Whitespace before, anything after.
        assertEquals(reference, parsedBits("2026-10-01T20:20:00.123Z "))
        assertEquals(reference, parsedBits("2026-10-01T20:20:00.123Z\n"))
        assertEquals(reference, parsedBits("\t2026-10-01T20:20:00.123Z"))
        assertEquals(whole, parsedBits("  2026-10-01T20:20:00Z"))
        assertEquals(whole, parsedBits("\n2026-10-01T20:20:00Z"))
        assertEquals(reference, parsedBits("2026-10-01T20:20:00.123Zjunk"))
        assertEquals(whole, parsedBits("2026-10-01T20:20:00Zjunk"))
        assertEquals(reference, parsedBits("2026-10-01T20:20:00.123ZZ"))
        assertEquals(reference, parsedBits("2026-10-01T20:20:00.123z "))
        assertEquals(whole, parsedBits("2026-10-01T20:20:00 Z"))
        assertEquals(reference, parsedBits("2026-10-01T20:20:00.123 Z"))

        // Fields may be short, a day may run past its month, and the hour may be 24.
        assertEquals("41c782f840000000", parsedBits("2026-1-01T00:00:00Z"))
        assertEquals("41c782f840000000", parsedBits("2026-01-1T00:00:00Z"))
        assertEquals("41c782f840000000", parsedBits("2026-01-01T0:00:00Z"))
        assertEquals("41c782f840000000", parsedBits("2026-01-01T00:0:00Z"))
        assertEquals("41c782f840000000", parsedBits("2026-01-01T00:00:0Z"))
        assertEquals("41c7d21240000000", parsedBits("2026-04-31T00:00:00Z"))
        assertEquals("41c6b942c0000000", parsedBits("2025-02-29T00:00:00Z"))
        assertEquals("41c783a100000000", parsedBits("2026-01-01T24:00:00Z"))
        assertEquals("41c783a0ff800000", parsedBits("2026-01-01T23:59:59Z"))
        assertEquals("c22a128687200000", parsedBits("226-10-01T20:20:00Z"))
        assertEquals(whole, parsedBits("02026-10-01T20:20:00Z"))

        // Offsets.
        assertEquals("41c8376de8000000", parsedBits("2026-10-01T20:20:00+02"))
        assertEquals("41c8376a64000000", parsedBits("2026-10-01T20:20:00+02:30"))
        assertEquals("41c8376a64000000", parsedBits("2026-10-01T20:20:00+0230"))
        assertEquals("41c837b438000000", parsedBits("2026-10-01T20:20:00-08:00"))
        assertEquals("41c83774f0400000", parsedBits("2026-10-01T20:20:00.5+01:00"))
        assertEquals("41c8376de80fbe76", parsedBits("2026-10-01T20:20:00.123 +02:00"))

        // Only the first three fraction digits count; nothing is rounded.
        assertEquals("41c8377c15ffdf3c", parsedBits("2026-10-01T20:20:59.9996Z"))
        assertEquals("41c8377bf87fdf3c", parsedBits("2026-10-01T20:20:00.999999999Z"))
        assertEquals("c1cd27e440400000", parsedBits("1969-12-31T23:59:59.5Z"))
        assertEquals("c1cd27e440800000", parsedBits("1969-12-31T23:59:59.0005Z"))
    }

    @Test fun whatFoundationRefusesIsRefused() {
        for (text in listOf(
            "2026-10-01T20:20:00.Z", "2026-13-01T00:00:00Z", "2026-00-01T00:00:00Z", "2026-01-00T00:00:00Z",
            "2026-01-32T00:00:00Z", "2026-01-01T23:60:00Z", "2026-01-01T25:00:00Z", "20261001T202000Z",
            "2026-10-01T202000Z", "+2026-10-01T20:20:00Z", "2026-10-01T20:20:00+", "2026-10-01T20:20:00-",
            "2026-10-01T20:20:00.+123Z", "2026-10-01T20:20:00.123−02:00",
        )) {
            assertNull(VaultTimestamp.parse(text), text)
        }
    }

    /**
     * Input no writer produces, where Foundation's lenient parser gives a value by
     * accident and this port deliberately does not follow it. Stated here so the
     * difference is a decision and not a surprise.
     */
    @Test fun documentedDeviationsFromFoundationsAccidents() {
        // Foundation: 812578800.0 (accepts the names).
        assertNull(VaultTimestamp.parse("2026-10-01T20:20:00GMT"))
        assertNull(VaultTimestamp.parse("2026-10-01T20:20:00UTC"))
        // Foundation: twenty hours, two hours, zero.
        assertNull(VaultTimestamp.parse("2026-10-01T20:20:00+2:00"))
        assertNull(VaultTimestamp.parse("2026-10-01T20:20:00+24:00"))
        assertNull(VaultTimestamp.parse("2026-10-01T20:20:00+00:60"))
        // Foundation: fullwidth digits read as digits.
        assertNull(VaultTimestamp.parse("２０２６-10-01T20:20:00Z"))
        // Foundation: minus 123 milliseconds.
        assertNull(VaultTimestamp.parse("2026-10-01T20:20:00.-123Z"))
        // Foundation: 1 millisecond (an integer overflow in ICU). Here: the first three digits.
        assertEquals("41c8377bf80fbe76", parsedBits("2026-10-01T20:20:00.1234567890123Z"))
        // Foundation: the year 2026 for a whole-second timestamp. Here: the year as written.
        assertNotNull(VaultTimestamp.parse("12026-10-01T20:20:00Z"))
    }

    @Test fun aTimestampThatIsNotFiniteHasNoSpelling() {
        assertFailsWith<IllegalArgumentException> { VaultTimestamp.string(Double.NaN) }
        assertFailsWith<IllegalArgumentException> { VaultTimestamp.string(Double.POSITIVE_INFINITY) }
    }

    @Test fun theQuarantineStampIsUtcAndSortable() {
        assertEquals("20260729-080000", VaultTimestamp.compactStamp(EPOCH))
        assertEquals("20260729-080059", VaultTimestamp.compactStamp(EPOCH + 59.9))
        assertEquals("20001231-235959", VaultTimestamp.compactStamp(-0.5))
    }
}
