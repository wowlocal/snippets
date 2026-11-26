package com.khm.snippets.core.vault

import com.khm.snippets.core.clock.AppleTime

/**
 * The timestamp format of `vault.json`: ISO-8601 in UTC with milliseconds
 * (`VaultTimestampCodec` in `VaultDocument.swift`, which is Foundation's
 * `ISO8601DateFormatter`).
 *
 * A timestamp does not survive the file bit for bit, and the doubles that come back are
 * what a secure record later carries onto the wire, where they are hashed. So the
 * arithmetic is Foundation's, established by running it (vector V14 and a differential
 * run over 830 000 values):
 *
 * ```
 * write:  ms = floor((t + 978307200.0) * 1000.0 + 0.5)        whole milliseconds since 1970
 * read:   t  = Double(ms) / 1000.0 - 978307200.0              digits past the third are dropped
 * ```
 *
 * `812578800.123` is written `2026-10-01T20:20:00.123Z` and read back as
 * `812578800.1229999`.
 *
 * The calendar is Foundation's Gregorian calendar, which is Julian before 1582-10-15;
 * `Date.distantPast` is therefore `0001-01-01T00:00:00.000Z`.
 */
object VaultTimestamp {

    /** `Date.distantPast` as seconds since 2001: what an undated record gets. */
    const val DISTANT_PAST: Double = -63_114_076_800.0

    private const val MILLIS_PER_DAY = 86_400_000L

    /** 1582-10-15, the first Gregorian day, as days since 1970-01-01. */
    private const val GREGORIAN_CUTOVER_EPOCH_DAY = -141_427L

    /** The Julian day number of 1970-01-01. */
    private const val EPOCH_JULIAN_DAY = 2_440_588L

    /** Whole milliseconds since 1970 as Foundation's formatter rounds them. [appleSeconds] must be finite. */
    fun epochMillis(appleSeconds: Double): Long {
        require(appleSeconds.isFinite()) { "a timestamp must be finite" }
        return Math.floor((appleSeconds + AppleTime.UNIX_EPOCH_OFFSET_SECONDS) * 1000.0 + 0.5).toLong()
    }

    /** The double Foundation's formatter returns for whole milliseconds since 1970. */
    fun fromEpochMillis(epochMillis: Long): Double = epochMillis / 1000.0 - AppleTime.UNIX_EPOCH_OFFSET_SECONDS

    /**
     * `yyyy-MM-ddTHH:mm:ss.SSSZ`. A year before 1 is printed as its year of era, as
     * Foundation does (so such a date does not read back); a year past 9999 takes five
     * digits.
     */
    fun string(appleSeconds: Double): String {
        val millis = epochMillis(appleSeconds)
        val day = Math.floorDiv(millis, MILLIS_PER_DAY)
        val ofDay = Math.floorMod(millis, MILLIS_PER_DAY)
        val date = civil(day)
        val year = if (date.year <= 0) 1 - date.year else date.year

        val out = StringBuilder(24)
        appendPadded(out, year, 4)
        out.append('-')
        appendPadded(out, date.month.toLong(), 2)
        out.append('-')
        appendPadded(out, date.day.toLong(), 2)
        out.append('T')
        appendPadded(out, ofDay / 3_600_000, 2)
        out.append(':')
        appendPadded(out, ofDay / 60_000 % 60, 2)
        out.append(':')
        appendPadded(out, ofDay / 1000 % 60, 2)
        out.append('.')
        appendPadded(out, ofDay % 1000, 3)
        out.append('Z')
        return out.toString()
    }

    /**
     * Reads a timestamp with or without a fraction, or `null`.
     *
     * Foundation parses with ICU's lenient date parser. What this accepts is the part of
     * that leniency with a defined meaning, each point confirmed against Foundation:
     *
     * - leading ASCII whitespace, and anything after the time zone, is ignored;
     * - the date is `year-month-day` with a mandatory uppercase `T`; month 1…12 and day
     *   1…31, where a day past the end of its month rolls over (`02-30` is March 2);
     * - the time is `hour:minute:second`, hour 0…24, minute and second 0…59;
     * - a fraction is `.` and at least one digit; the first three digits count;
     * - the zone is `Z`, `z`, or `±hh`, `±hh:mm`, `±hhmm`, optionally after spaces.
     *
     * Deviations, all for input no writer produces: Foundation also accepts non-ASCII
     * digits, `GMT` and `UTC`, a sign inside the fraction, and malformed zone offsets, to
     * which it gives a value by accident (`+2:00` is twenty hours); a fraction of more
     * than nine digits overflows there. Those are `null` here, or for the long fraction
     * its first three digits.
     */
    fun parse(text: String): Double? {
        val cursor = Cursor(text)
        cursor.skipSpaces()

        val negativeYear = cursor.accept('-')
        val yearDigits = cursor.number(1, 6) ?: return null
        val year = if (negativeYear) -yearDigits else yearDigits
        if (!cursor.accept('-')) return null
        val month = cursor.number(1, 2) ?: return null
        if (!cursor.accept('-')) return null
        val day = cursor.number(1, 2) ?: return null
        if (!cursor.accept('T')) return null
        val hour = cursor.number(1, 2) ?: return null
        if (!cursor.accept(':')) return null
        val minute = cursor.number(1, 2) ?: return null
        if (!cursor.accept(':')) return null
        val second = cursor.number(1, 2) ?: return null
        if (month !in 1..12 || day !in 1..31 || hour > 24 || minute > 59 || second > 59) return null

        var millis = 0L
        if (cursor.accept('.')) {
            var digits = 0
            while (true) {
                val digit = cursor.digit() ?: break
                if (digits < 3) millis = millis * 10 + digit
                digits += 1
            }
            if (digits == 0) return null
            while (digits < 3) {
                millis *= 10
                digits += 1
            }
        }

        cursor.skipSpaces()
        val offsetSeconds = cursor.zoneOffsetSeconds() ?: return null

        val seconds = epochDay(year, month.toInt(), day.toInt()) * 86_400L +
            hour * 3600L + minute * 60L + second - offsetSeconds
        return fromEpochMillis(seconds * 1000L + millis)
    }

    /** `yyyyMMdd-HHmmss` in UTC, the stamp in a quarantined vault's file name. */
    internal fun compactStamp(appleSeconds: Double): String {
        val seconds = Math.floor(AppleTime.unixSeconds(appleSeconds)).toLong()
        val day = Math.floorDiv(seconds, 86_400L)
        val ofDay = Math.floorMod(seconds, 86_400L)
        val date = civil(day)
        val out = StringBuilder(15)
        appendPadded(out, if (date.year <= 0) 1 - date.year else date.year, 4)
        appendPadded(out, date.month.toLong(), 2)
        appendPadded(out, date.day.toLong(), 2)
        out.append('-')
        appendPadded(out, ofDay / 3600, 2)
        appendPadded(out, ofDay / 60 % 60, 2)
        appendPadded(out, ofDay % 60, 2)
        return out.toString()
    }

    private class CivilDate(val year: Long, val month: Int, val day: Int)

    private fun civil(epochDay: Long): CivilDate =
        if (epochDay >= GREGORIAN_CUTOVER_EPOCH_DAY) gregorian(epochDay) else julian(epochDay)

    private fun gregorian(epochDay: Long): CivilDate {
        val shifted = epochDay + 719_468
        val era = Math.floorDiv(shifted, 146_097L)
        val dayOfEra = shifted - era * 146_097
        val yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        val dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        val monthIndex = (5 * dayOfYear + 2) / 153
        val day = (dayOfYear - (153 * monthIndex + 2) / 5 + 1).toInt()
        val month = (if (monthIndex < 10) monthIndex + 3 else monthIndex - 9).toInt()
        val year = yearOfEra + era * 400 + if (month <= 2) 1 else 0
        return CivilDate(year, month, day)
    }

    private fun julian(epochDay: Long): CivilDate {
        val c = epochDay + EPOCH_JULIAN_DAY + 32_082
        val d = Math.floorDiv(4 * c + 3, 1461L)
        val e = c - Math.floorDiv(1461 * d, 4L)
        val m = (5 * e + 2) / 153
        val day = (e - (153 * m + 2) / 5 + 1).toInt()
        val month = (m + 3 - 12 * (m / 10)).toInt()
        return CivilDate(d - 4800 + m / 10, month, day)
    }

    /** Days since 1970 of a date whose day may run past its month. Julian before the cutover, as Foundation reads it. */
    private fun epochDay(year: Long, month: Int, day: Int): Long {
        val gregorian = gregorianEpochDay(year, month) + (day - 1)
        if (gregorian >= GREGORIAN_CUTOVER_EPOCH_DAY) return gregorian
        return julianEpochDay(year, month) + (day - 1)
    }

    private fun gregorianEpochDay(year: Long, month: Int): Long {
        val y = if (month <= 2) year - 1 else year
        val era = Math.floorDiv(y, 400L)
        val yearOfEra = y - era * 400
        val dayOfYear = (153L * (month + (if (month > 2) -3 else 9)) + 2) / 5
        val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private fun julianEpochDay(year: Long, month: Int): Long {
        val a = (14 - month) / 12
        val y = year + 4800 - a
        val m = month + 12 * a - 3
        val julianDay = 1 + (153L * m + 2) / 5 + 365 * y + Math.floorDiv(y, 4L) - 32_083
        return julianDay - EPOCH_JULIAN_DAY
    }

    private fun appendPadded(out: StringBuilder, value: Long, width: Int) {
        val digits = value.toString()
        repeat(width - digits.length) { out.append('0') }
        out.append(digits)
    }

    private class Cursor(private val text: String) {
        private var index = 0

        fun skipSpaces() {
            while (index < text.length && (text[index] == ' ' || text[index] in '\t'..'\r')) index += 1
        }

        fun accept(character: Char): Boolean {
            if (index < text.length && text[index] == character) {
                index += 1
                return true
            }
            return false
        }

        fun digit(): Int? {
            if (index < text.length && text[index] in '0'..'9') {
                index += 1
                return text[index - 1] - '0'
            }
            return null
        }

        /** Between [minimum] and [maximum] ASCII digits, as many as there are. */
        fun number(minimum: Int, maximum: Int): Long? {
            var value = 0L
            var count = 0
            while (count < maximum) {
                val digit = digit() ?: break
                value = value * 10 + digit
                count += 1
            }
            return if (count < minimum) null else value
        }

        fun zoneOffsetSeconds(): Long? {
            if (accept('Z') || accept('z')) return 0
            val sign = when {
                accept('+') -> 1L
                accept('-') -> -1L
                else -> return null
            }
            val hours = exactly(2) ?: return null
            val mark = index
            val minutes = if (accept(':')) {
                exactly(2) ?: return null
            } else {
                exactly(2) ?: run {
                    index = mark
                    0L
                }
            }
            if (hours > 23 || minutes > 59) return null
            return sign * (hours * 3600 + minutes * 60)
        }

        private fun exactly(count: Int): Long? {
            val start = index
            val value = number(count, count)
            if (value == null) index = start
            return value
        }
    }
}
