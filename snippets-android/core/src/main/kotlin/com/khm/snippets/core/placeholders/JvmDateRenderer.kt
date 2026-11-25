package com.khm.snippets.core.placeholders

import java.time.DateTimeException
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.Month
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.chrono.Chronology
import java.time.chrono.HijrahChronology
import java.time.chrono.HijrahDate
import java.time.chrono.HijrahEra
import java.time.chrono.IsoChronology
import java.time.chrono.IsoEra
import java.time.chrono.JapaneseChronology
import java.time.chrono.JapaneseDate
import java.time.chrono.MinguoChronology
import java.time.chrono.MinguoEra
import java.time.chrono.ThaiBuddhistChronology
import java.time.chrono.ThaiBuddhistEra
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.DecimalStyle
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.time.temporal.ChronoField
import java.time.temporal.ChronoUnit
import java.time.temporal.IsoFields
import java.time.temporal.TemporalAccessor
import java.time.temporal.TemporalField
import java.time.temporal.WeekFields
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.Locale
import java.util.TimeZone

/**
 * A [DateRenderer] on the JDK alone, for tests, for tools and as the fallback where no
 * ICU is at hand.
 *
 * Patterns are interpreted here, letter by letter, with ICU's meanings ([IcuDatePattern]);
 * neither `java.text.SimpleDateFormat` nor `java.time`'s pattern syntax is involved.
 * Everything that is arithmetic matches Foundation exactly: numeric fields, padding,
 * week numbering, ISO zone offsets, offsets across daylight-saving changes, the Julian
 * calendar before 15 October 1582, and the Buddhist, Japanese, Republic of China and
 * Umm al-Qura calendars.
 *
 * Everything that is locale data comes from the runtime's own tables (`java.time` text,
 * styles and week rules), which are a different CLDR version from Apple's and, on
 * Android, from the device's ICU. Month names, medium styles, `am`/`pm` and zone names
 * can therefore differ in wording from what an Apple device shows. Known gaps:
 *
 * - `B` and `b` (day periods) print the `a` marker; `EEEEEE` (two-letter weekday) prints
 *   the abbreviated name; `ddd` (Apple's ordinal day) prints the plain number.
 * - `v`, `V`, `z` use the JDK's zone names; `V` has no short zone ids and prints `unk`.
 * - Calendars the JDK does not have (Persian, Hebrew, Chinese, Indian, Coptic, Ethiopic,
 *   the other Islamic variants) fall back to Gregorian. Umm al-Qura and Japanese dates
 *   outside the JDK's tables fall back the same way.
 * - The localized GMT format is always `GMT+1` / `GMT+01:00`, whatever the locale.
 * - Before 4713 BC (Julian day 0) Foundation's own Gregorian calendar is a day ahead of
 *   ICU's. This class agrees with ICU, and so with `android.icu`.
 *
 * @param locale the user's locale. Unicode extensions are honoured: `ca` (calendar), `nu`
 * (digits) and `hc` (12- or 24-hour styles).
 * @param zone the user's time zone.
 */
class JvmDateRenderer(private val locale: Locale, private val zone: ZoneId) : DateRenderer {

    private val userCalendar: CalendarSystem = CalendarSystem.of(locale)

    override fun availableLocaleIdentifiers(): Collection<String> =
        Locale.getAvailableLocales().map { it.toLanguageTag() }

    override fun add(epochMillis: Long, unit: DateRenderer.Unit, amount: Int): Long? {
        // Adding nothing is not a round trip through the calendar: the second 02:30 of
        // an autumn night stays the second.
        if (amount == 0) return epochMillis
        try {
            when (unit) {
                DateRenderer.Unit.MINUTE -> return Math.addExact(epochMillis, amount * MILLIS_PER_MINUTE)
                DateRenderer.Unit.HOUR -> return Math.addExact(epochMillis, amount * MILLIS_PER_HOUR)
                else -> Unit
            }
            val rules = zone.rules
            val offset = rules.getOffset(Instant.ofEpochMilli(epochMillis))
            val local = Math.addExact(epochMillis, offset.totalSeconds * 1000L)
            val movedLocal = if (userCalendar == CalendarSystem.ISLAMIC_UMALQURA) {
                addHijri(local, unit, amount) ?: addGregorian(local, unit, amount)
            } else {
                addGregorian(local, unit, amount)
            }

            // Back to an instant, as Foundation was measured to resolve it. A time the
            // clock skips moves later by the gap. A time it repeats is its first occurrence
            // after a step forwards. After a step backwards it is the second occurrence
            // for months and years, and for days the one with the offset the step started
            // from.
            val wallTime = LocalDateTime.ofEpochSecond(
                Math.floorDiv(movedLocal, 1000L), (Math.floorMod(movedLocal, 1000L) * 1_000_000L).toInt(), ZoneOffset.UTC,
            )
            val valid = rules.getValidOffsets(wallTime)
            val resolved = when {
                valid.size == 1 -> valid[0]
                valid.isEmpty() -> rules.getTransition(wallTime).offsetBefore
                amount > 0 -> valid[0]
                unit == DateRenderer.Unit.DAY && offset in valid -> offset
                else -> valid[valid.size - 1]
            }
            return Math.subtractExact(movedLocal, resolved.totalSeconds * 1000L)
        } catch (_: ArithmeticException) {
            return null
        } catch (_: DateTimeException) {
            return null
        }
    }

    // `java.util.GregorianCalendar` switches to the Julian calendar before October 1582
    // and pins the day of the month, as ICU's and Foundation's Gregorian calendars do.
    private fun addGregorian(local: Long, unit: DateRenderer.Unit, amount: Int): Long {
        val calendar = utcCalendar(local)
        calendar.add(
            when (unit) {
                DateRenderer.Unit.DAY -> Calendar.DAY_OF_MONTH
                DateRenderer.Unit.MONTH -> Calendar.MONTH
                else -> Calendar.YEAR
            },
            amount,
        )
        return calendar.timeInMillis
    }

    private fun addHijri(local: Long, unit: DateRenderer.Unit, amount: Int): Long? = try {
        val day = Math.floorDiv(local, MILLIS_PER_DAY)
        val moved = HijrahDate.from(LocalDate.ofEpochDay(day)).plus(
            amount.toLong(),
            when (unit) {
                DateRenderer.Unit.DAY -> ChronoUnit.DAYS
                DateRenderer.Unit.MONTH -> ChronoUnit.MONTHS
                else -> ChronoUnit.YEARS
            },
        )
        moved.toEpochDay() * MILLIS_PER_DAY + Math.floorMod(local, MILLIS_PER_DAY)
    } catch (_: DateTimeException) {
        null
    }

    override fun format(epochMillis: Long, pattern: String): String {
        if (!isRepresentable(epochMillis)) return ""
        return format(Fields(epochMillis, zone, userCalendar, locale), IcuDatePattern.parse(pattern).items, Symbols(locale))
    }

    override fun format(
        epochMillis: Long,
        dateStyle: DateRenderer.Style,
        timeStyle: DateRenderer.Style,
        localeTag: String?,
    ): String {
        if (!isRepresentable(epochMillis)) return ""
        val formatLocale = if (localeTag == null) locale else Locale.forLanguageTag(localeTag)
        val calendar = if (localeTag == null) userCalendar else CalendarSystem.of(formatLocale)
        val date = formatStyle(dateStyle)
        val time = formatStyle(timeStyle)
        if (date == null && time == null) return ""
        val stylePattern = try {
            DateTimeFormatterBuilder.getLocalizedDateTimePattern(date, time, calendar.chronology, formatLocale)
        } catch (_: RuntimeException) {
            return ""
        }
        val parsed = IcuDatePattern.parse(stylePattern)
        val fields = Fields(epochMillis, zone, calendar, formatLocale)
        if (!parsed.isComplete) return formatWithJavaTime(fields, date, time, calendar, formatLocale)
        val items = withHourCycle(parsed.items, formatLocale.getUnicodeLocaleType("hc"))
        return format(fields, items, Symbols(formatLocale))
    }

    // The JDK's style pattern used a letter ICU does not have: let the JDK format it.
    private fun formatWithJavaTime(fields: Fields, date: FormatStyle?, time: FormatStyle?, calendar: CalendarSystem, formatLocale: Locale): String = try {
        val formatter = when {
            date != null && time != null -> DateTimeFormatter.ofLocalizedDateTime(date, time)
            date != null -> DateTimeFormatter.ofLocalizedDate(date)
            else -> DateTimeFormatter.ofLocalizedTime(time)
        }
        formatter.withLocale(formatLocale).withChronology(calendar.chronology)
            .withDecimalStyle(DecimalStyle.of(formatLocale))
            .format(Instant.ofEpochMilli(fields.epochMillis).atZone(zone))
    } catch (_: RuntimeException) {
        ""
    }

    /**
     * The `hc` preference applied to a style pattern: `h23`/`h24` drop the day period and
     * use a two-digit 24-hour field; `h12`/`h11` use a 12-hour field and add the period.
     */
    private fun withHourCycle(items: List<IcuDatePattern.Item>, hourCycle: String?): List<IcuDatePattern.Item> {
        val wants24 = when (hourCycle) {
            "h23", "h24" -> true
            "h12", "h11" -> false
            else -> return items
        }
        val hourIndex = items.indexOfFirst { it is IcuDatePattern.Item.Field && it.letter in "hHkK" }
        if (hourIndex < 0) return items
        val hasPeriod = items.any { it is IcuDatePattern.Item.Field && it.letter in "abB" }
        val is24 = (items[hourIndex] as IcuDatePattern.Item.Field).letter in "Hk"
        if (wants24 == is24) return items

        val out = ArrayList<IcuDatePattern.Item>(items.size + 2)
        if (wants24) {
            // The space that set the period apart goes with it: the one before it, or
            // else the one after.
            var trimNextLiteral = false
            for (item in items) {
                when {
                    item is IcuDatePattern.Item.Field && item.letter in "abB" -> {
                        val before = out.lastOrNull()
                        if (before is IcuDatePattern.Item.Literal && before.text.isNotEmpty() && isSpace(before.text.last())) {
                            out[out.size - 1] = IcuDatePattern.Item.Literal(before.text.trimEnd(::isSpace))
                        } else {
                            trimNextLiteral = true
                        }
                    }
                    item is IcuDatePattern.Item.Field && item.letter in "hK" -> out.add(IcuDatePattern.Item.Field('H', 2))
                    item is IcuDatePattern.Item.Literal && trimNextLiteral -> {
                        out.add(IcuDatePattern.Item.Literal(item.text.trimStart(::isSpace)))
                        trimNextLiteral = false
                    }
                    else -> {
                        out.add(item)
                        trimNextLiteral = false
                    }
                }
            }
            return out.filterNot { it is IcuDatePattern.Item.Literal && it.text.isEmpty() }
        }
        val lastTimeField = items.indexOfLast { it is IcuDatePattern.Item.Field && it.letter in "hHkKms" }
        items.forEachIndexed { index, item ->
            out.add(if (item is IcuDatePattern.Item.Field && item.letter in "Hk") IcuDatePattern.Item.Field('h', 1) else item)
            if (index == lastTimeField && !hasPeriod) {
                out.add(IcuDatePattern.Item.Literal("\u202F"))
                out.add(IcuDatePattern.Item.Field('a', 1))
            }
        }
        return out
    }

    private fun isSpace(unit: Char): Boolean = unit == ' ' || unit == '\u00A0' || unit == '\u202F'

    private fun format(fields: Fields, items: List<IcuDatePattern.Item>, symbols: Symbols): String {
        val out = StringBuilder()
        for (item in items) {
            when (item) {
                is IcuDatePattern.Item.Literal -> out.append(item.text)
                is IcuDatePattern.Item.Field -> appendField(item.letter, item.count, fields, symbols, out)
            }
        }
        return out.toString()
    }

    /** `SimpleDateFormat::subFormat`, with the counts Foundation was measured to accept. */
    private fun appendField(letter: Char, count: Int, fields: Fields, symbols: Symbols, out: StringBuilder) {
        when (letter) {
            'G' -> if (count <= 5) out.append(symbols.era(fields, width(count)))
            'y', 'U' -> symbols.number(fields.year.toLong(), count, if (count == 2) 2 else MAXIMUM_DIGITS, out)
            'Y' -> symbols.number(fields.yearOfWeekOfYear.toLong(), count, if (count == 2) 2 else MAXIMUM_DIGITS, out)
            'u' -> symbols.number(fields.extendedYear.toLong(), count, MAXIMUM_DIGITS, out)
            'r' -> symbols.number(fields.relatedGregorianYear.toLong(), count, MAXIMUM_DIGITS, out)
            'M', 'L' -> when (count) {
                3, 4, 5 -> out.append(symbols.month(fields, width(count), standalone = letter == 'L'))
                else -> symbols.number(fields.month + 1L, count, MAXIMUM_DIGITS, out)
            }
            // Three or more is Apple's ordinal day ("31st"); the number is printed unpadded.
            'd' -> symbols.number(fields.dayOfMonth.toLong(), if (count <= 2) count else 1, MAXIMUM_DIGITS, out)
            'D' -> symbols.number(fields.dayOfYear.toLong(), count, MAXIMUM_DIGITS, out)
            'F' -> symbols.number(fields.dayOfWeekInMonth.toLong(), count, MAXIMUM_DIGITS, out)
            'g' -> symbols.number(fields.julianDay, count, MAXIMUM_DIGITS, out)
            'w' -> symbols.number(fields.weekOfYear.toLong(), count, MAXIMUM_DIGITS, out)
            'W' -> symbols.number(fields.weekOfMonth.toLong(), count, MAXIMUM_DIGITS, out)
            'E' -> if (count <= 6) out.append(symbols.weekday(fields, width(count), standalone = false))
            'e' -> when {
                count <= 2 -> symbols.number(fields.localDayOfWeek.toLong(), count, MAXIMUM_DIGITS, out)
                count <= 6 -> out.append(symbols.weekday(fields, width(count), standalone = false))
            }
            'c' -> when {
                count <= 2 -> symbols.number(fields.localDayOfWeek.toLong(), 1, MAXIMUM_DIGITS, out)
                count <= 6 -> out.append(symbols.weekday(fields, width(count), standalone = true))
            }
            'a', 'b', 'B' -> out.append(symbols.dayPeriod(fields, if (count == 5) Width.NARROW else Width.ABBREVIATED))
            'H' -> symbols.number(fields.hourOfDay.toLong(), count, MAXIMUM_DIGITS, out)
            'k' -> symbols.number(if (fields.hourOfDay == 0) 24L else fields.hourOfDay.toLong(), count, MAXIMUM_DIGITS, out)
            'h' -> symbols.number(if (fields.hourOfDay % 12 == 0) 12L else fields.hourOfDay % 12L, count, MAXIMUM_DIGITS, out)
            'K' -> symbols.number(fields.hourOfDay % 12L, count, MAXIMUM_DIGITS, out)
            'm' -> symbols.number(fields.minute.toLong(), count, MAXIMUM_DIGITS, out)
            's' -> symbols.number(fields.second.toLong(), count, MAXIMUM_DIGITS, out)
            'S' -> {
                // Fractions are left-justified: the first digits of the millisecond, then zeros.
                val value = when (count) {
                    1 -> fields.millisecond / 100
                    2 -> fields.millisecond / 10
                    else -> fields.millisecond
                }
                symbols.number(value.toLong(), minOf(count, 3), MAXIMUM_DIGITS, out)
                if (count > 3) symbols.number(0L, count - 3, MAXIMUM_DIGITS, out)
            }
            'A' -> symbols.number(fields.millisInDay.toLong(), count, MAXIMUM_DIGITS, out)
            'Q', 'q' -> when {
                count >= 3 -> out.append(symbols.quarter(fields, if (count >= 5) Width.NARROW else width(count), standalone = letter == 'q'))
                else -> symbols.number(fields.month / 3 + 1L, count, MAXIMUM_DIGITS, out)
            }
            'z' -> out.append(symbols.zoneName(zone, fields.isDaylightTime, long = count >= 4))
            'Z' -> when {
                count <= 3 -> out.append(isoOffset(fields.offsetSeconds, extended = false, minutes = Part.ALWAYS, seconds = true, utcAsZ = false))
                count == 5 -> out.append(isoOffset(fields.offsetSeconds, extended = true, minutes = Part.ALWAYS, seconds = true, utcAsZ = true))
                else -> out.append(localizedGmt(fields.offsetSeconds, long = true))
            }
            'O' -> when (count) {
                1 -> out.append(localizedGmt(fields.offsetSeconds, long = false))
                4 -> out.append(localizedGmt(fields.offsetSeconds, long = true))
            }
            'v' -> when (count) {
                // The JDK has no generic ("Pacific Time") names here: the standard-time name stands in.
                1 -> out.append(symbols.zoneName(zone, daylight = false, long = false))
                4 -> out.append(symbols.zoneName(zone, daylight = false, long = true))
            }
            'V' -> when (count) {
                1 -> out.append("unk")
                2 -> out.append(zone.id)
                3 -> out.append(exemplarCity())
                4 -> out.append(exemplarCity()).append(" Time")
            }
            'X', 'x' -> when (count) {
                1 -> out.append(isoOffset(fields.offsetSeconds, extended = false, minutes = Part.IF_NOT_ZERO, seconds = false, utcAsZ = letter == 'X'))
                2 -> out.append(isoOffset(fields.offsetSeconds, extended = false, minutes = Part.ALWAYS, seconds = false, utcAsZ = letter == 'X'))
                3 -> out.append(isoOffset(fields.offsetSeconds, extended = true, minutes = Part.ALWAYS, seconds = false, utcAsZ = letter == 'X'))
                4 -> out.append(isoOffset(fields.offsetSeconds, extended = false, minutes = Part.ALWAYS, seconds = true, utcAsZ = letter == 'X'))
                5 -> out.append(isoOffset(fields.offsetSeconds, extended = true, minutes = Part.ALWAYS, seconds = true, utcAsZ = letter == 'X'))
            }
        }
    }

    private fun exemplarCity(): String = zone.id.substringAfterLast('/').replace('_', ' ')

    private enum class Part { ALWAYS, IF_NOT_ZERO }

    /**
     * ICU's ISO 8601 offset formats. Seconds appear only in the "full" forms and only
     * when they are not zero. An offset whose printed fields are all zero is positive.
     */
    private fun isoOffset(offsetSeconds: Int, extended: Boolean, minutes: Part, seconds: Boolean, utcAsZ: Boolean): String {
        val absolute = Math.abs(offsetSeconds)
        if (utcAsZ && (absolute == 0 || (!seconds && absolute < 60))) return "Z"
        val hourPart = absolute / 3600
        val minutePart = absolute % 3600 / 60
        val secondPart = absolute % 60
        val showSeconds = seconds && secondPart != 0
        val showMinutes = minutes == Part.ALWAYS || minutePart != 0 || showSeconds
        val allZero = hourPart == 0 && (!showMinutes || minutePart == 0) && (!showSeconds || secondPart == 0)
        val out = StringBuilder(9)
        out.append(if (offsetSeconds < 0 && !allZero) '-' else '+')
        appendTwoDigits(hourPart, out)
        if (showMinutes) {
            if (extended) out.append(':')
            appendTwoDigits(minutePart, out)
        }
        if (showSeconds) {
            if (extended) out.append(':')
            appendTwoDigits(secondPart, out)
        }
        return out.toString()
    }

    /** `GMT+1`, `GMT+5:30` or `GMT+01:00`, as Foundation prints them in English; UTC is `GMT+0`. */
    private fun localizedGmt(offsetSeconds: Int, long: Boolean): String {
        val absolute = Math.abs(offsetSeconds)
        val hourPart = absolute / 3600
        val minutePart = absolute % 3600 / 60
        val secondPart = absolute % 60
        val out = StringBuilder("GMT").append(if (offsetSeconds < 0) '-' else '+')
        if (long) appendTwoDigits(hourPart, out) else out.append(hourPart)
        if (long || minutePart != 0 || secondPart != 0) {
            out.append(':')
            appendTwoDigits(minutePart, out)
        }
        if (secondPart != 0) {
            out.append(':')
            appendTwoDigits(secondPart, out)
        }
        return out.toString()
    }

    private fun appendTwoDigits(value: Int, out: StringBuilder) {
        if (value < 10) out.append('0')
        out.append(value)
    }

    private enum class Width { ABBREVIATED, WIDE, NARROW }

    // One to three letters are the abbreviated form, four the wide one, five the narrow
    // one. Six is ICU's "short" weekday, which the JDK does not have.
    private fun width(count: Int): Width = when (count) {
        4 -> Width.WIDE
        5 -> Width.NARROW
        else -> Width.ABBREVIATED
    }

    private enum class CalendarSystem(val chronology: Chronology) {
        GREGORIAN(IsoChronology.INSTANCE),
        BUDDHIST(ThaiBuddhistChronology.INSTANCE),
        JAPANESE(JapaneseChronology.INSTANCE),
        ROC(MinguoChronology.INSTANCE),
        ISLAMIC_UMALQURA(HijrahChronology.INSTANCE);

        companion object {
            /** The `ca` extension, else the calendar CLDR prefers for the region. */
            fun of(locale: Locale): CalendarSystem = when (locale.getUnicodeLocaleType("ca")) {
                "buddhist" -> BUDDHIST
                "japanese" -> JAPANESE
                "roc" -> ROC
                "islamic-umalqura" -> ISLAMIC_UMALQURA
                null -> when (locale.country) {
                    "TH" -> BUDDHIST
                    "SA" -> ISLAMIC_UMALQURA
                    else -> GREGORIAN
                }
                else -> GREGORIAN
            }
        }
    }

    /** ICU's calendar fields for one instant, in one zone and calendar. */
    private class Fields(val epochMillis: Long, zone: ZoneId, calendar: CalendarSystem, locale: Locale) {
        val offsetSeconds: Int
        val isDaylightTime: Boolean
        val localDay: Long
        val millisInDay: Int

        /** 1 is Sunday. */
        val dayOfWeek: Int
        val localDayOfWeek: Int
        val julianDay: Long

        var calendar: CalendarSystem = calendar
            private set

        /** The era as the calendar's own value: see [Symbols.era]. */
        var era: Int = 0
            private set
        var year: Int = 0
            private set
        var extendedYear: Int = 0
            private set
        var relatedGregorianYear: Int = 0
            private set

        /** 0 is the first month. */
        var month: Int = 0
            private set
        var dayOfMonth: Int = 0
            private set
        var dayOfYear: Int = 0
            private set
        var yearOfWeekOfYear: Int = 0
            private set
        var weekOfYear: Int = 0
            private set
        val weekOfMonth: Int
        val dayOfWeekInMonth: Int

        /** The date in the Umm al-Qura calendar, when that is the calendar. */
        var hijrahDate: HijrahDate? = null
            private set
        var japaneseDate: JapaneseDate? = null
            private set

        val hourOfDay: Int get() = millisInDay / 3_600_000
        val minute: Int get() = millisInDay / 60_000 % 60
        val second: Int get() = millisInDay / 1000 % 60
        val millisecond: Int get() = millisInDay % 1000

        init {
            val rules = zone.rules
            val instant = Instant.ofEpochMilli(epochMillis)
            offsetSeconds = rules.getOffset(instant).totalSeconds
            isDaylightTime = rules.isDaylightSavings(instant)
            val local = epochMillis + offsetSeconds * 1000L
            localDay = Math.floorDiv(local, MILLIS_PER_DAY)
            millisInDay = Math.floorMod(local, MILLIS_PER_DAY).toInt()
            julianDay = localDay + JULIAN_DAY_OF_EPOCH
            dayOfWeek = Math.floorMod(localDay + 4, 7L).toInt() + 1 // 1970-01-01 was a Thursday

            val weekRules = WeekFields.of(locale)
            val firstDayOfWeek = weekRules.firstDayOfWeek.value % 7 + 1
            val minimalDays = weekRules.minimalDaysInFirstWeek
            localDayOfWeek = (dayOfWeek - firstDayOfWeek + 7) % 7 + 1

            val gregorian = utcCalendar(localDay * MILLIS_PER_DAY)
            val gregorianExtendedYear =
                if (gregorian.get(Calendar.ERA) == GregorianCalendar.AD) gregorian.get(Calendar.YEAR) else 1 - gregorian.get(Calendar.YEAR)
            var yearLength = gregorian.getActualMaximum(Calendar.DAY_OF_YEAR)
            var previousYearLength: () -> Int = {
                (gregorian.clone() as Calendar).apply { add(Calendar.YEAR, -1) }.getActualMaximum(Calendar.DAY_OF_YEAR)
            }
            // The Gregorian reading; the calendars below replace what they count differently.
            era = gregorian.get(Calendar.ERA)
            year = gregorian.get(Calendar.YEAR)
            extendedYear = gregorianExtendedYear
            relatedGregorianYear = gregorianExtendedYear
            month = gregorian.get(Calendar.MONTH)
            dayOfMonth = gregorian.get(Calendar.DAY_OF_MONTH)
            dayOfYear = gregorian.get(Calendar.DAY_OF_YEAR)

            when (calendar) {
                CalendarSystem.GREGORIAN -> Unit
                CalendarSystem.BUDDHIST -> {
                    era = 0
                    year = gregorianExtendedYear + BUDDHIST_ERA_OFFSET
                }
                CalendarSystem.ROC -> {
                    val rocYear = gregorianExtendedYear - ROC_ERA_START
                    era = if (rocYear > 0) 1 else 0
                    year = if (rocYear > 0) rocYear else 1 - rocYear
                }
                CalendarSystem.JAPANESE -> try {
                    val date = JapaneseDate.from(LocalDate.ofEpochDay(localDay))
                    japaneseDate = date
                    year = date.get(ChronoField.YEAR_OF_ERA)
                } catch (_: DateTimeException) {
                    this.calendar = CalendarSystem.GREGORIAN
                }
                CalendarSystem.ISLAMIC_UMALQURA -> try {
                    val date = HijrahDate.from(LocalDate.ofEpochDay(localDay))
                    hijrahDate = date
                    era = 0
                    year = date.get(ChronoField.YEAR_OF_ERA)
                    extendedYear = year
                    relatedGregorianYear = gregorianYearOfIslamicYear(year)
                    month = date.get(ChronoField.MONTH_OF_YEAR) - 1
                    dayOfMonth = date.get(ChronoField.DAY_OF_MONTH)
                    dayOfYear = date.get(ChronoField.DAY_OF_YEAR)
                    yearLength = date.lengthOfYear()
                    previousYearLength = { HijrahChronology.INSTANCE.date(year - 1, 1, 1).lengthOfYear() }
                } catch (_: DateTimeException) {
                    this.calendar = CalendarSystem.GREGORIAN
                }
            }

            // `Calendar::computeWeekFields`.
            fun weekNumber(desiredDay: Int, dayOfPeriod: Int): Int {
                val periodStartDayOfWeek = Math.floorMod(dayOfWeek - firstDayOfWeek - dayOfPeriod + 1, 7)
                val week = (desiredDay + periodStartDayOfWeek - 1) / 7
                return if (7 - periodStartDayOfWeek >= minimalDays) week + 1 else week
            }

            var weekYear = extendedYear
            val relativeDayOfWeek = (dayOfWeek + 7 - firstDayOfWeek) % 7
            val relativeDayOfWeekOfJanuaryFirst = Math.floorMod(dayOfWeek - dayOfYear + 7001 - firstDayOfWeek, 7)
            var week = (dayOfYear - 1 + relativeDayOfWeekOfJanuaryFirst) / 7
            if (7 - relativeDayOfWeekOfJanuaryFirst >= minimalDays) week += 1
            if (week == 0) {
                // The last week of the previous year.
                week = weekNumber(dayOfYear + previousYearLength(), dayOfYear + previousYearLength())
                weekYear -= 1
            } else if (dayOfYear >= yearLength - 5) {
                val lastRelativeDayOfWeek = Math.floorMod(relativeDayOfWeek + yearLength - dayOfYear, 7)
                if (6 - lastRelativeDayOfWeek >= minimalDays && dayOfYear + 7 - relativeDayOfWeek > yearLength) {
                    week = 1
                    weekYear += 1
                }
            }
            weekOfYear = week
            yearOfWeekOfYear = weekYear
            weekOfMonth = weekNumber(dayOfMonth, dayOfMonth)
            dayOfWeekInMonth = (dayOfMonth - 1) / 7 + 1
        }
    }

    /** Localized text and digits from the runtime's `java.time` tables. */
    private class Symbols(private val locale: Locale) {

        private val zeroDigit: Char = try {
            DecimalStyle.of(locale).zeroDigit
        } catch (_: RuntimeException) {
            '0'
        }

        /**
         * ICU's `zeroPaddingNumber`: at least [minimumDigits] and at most [maximumDigits]
         * digits, the high ones cut off; a pad wider than the maximum is the maximum.
         */
        fun number(value: Long, minimumDigits: Int, maximumDigits: Int, out: StringBuilder) {
            var digits = Math.abs(value).toString()
            if (digits.length > maximumDigits) digits = digits.substring(digits.length - maximumDigits)
            if (value < 0) out.append('-')
            repeat(minOf(minimumDigits, maximumDigits) - digits.length) { out.append(zeroDigit) }
            for (digit in digits) out.append(zeroDigit + (digit - '0'))
        }

        private fun style(width: Width, standalone: Boolean): TextStyle = when (width) {
            Width.ABBREVIATED -> if (standalone) TextStyle.SHORT_STANDALONE else TextStyle.SHORT
            Width.WIDE -> if (standalone) TextStyle.FULL_STANDALONE else TextStyle.FULL
            Width.NARROW -> if (standalone) TextStyle.NARROW_STANDALONE else TextStyle.NARROW
        }

        private fun text(field: TemporalField, width: Width, standalone: Boolean, chronology: Chronology, value: TemporalAccessor): String = try {
            DateTimeFormatterBuilder().appendText(field, style(width, standalone)).toFormatter(locale)
                .withChronology(chronology).format(value)
        } catch (_: RuntimeException) {
            ""
        }

        fun era(fields: Fields, width: Width): String = try {
            val style = style(width, standalone = false)
            when (fields.calendar) {
                CalendarSystem.GREGORIAN -> (if (fields.era == GregorianCalendar.AD) IsoEra.CE else IsoEra.BCE).getDisplayName(style, locale)
                CalendarSystem.BUDDHIST -> ThaiBuddhistEra.BE.getDisplayName(style, locale)
                CalendarSystem.ROC -> (if (fields.era == 1) MinguoEra.ROC else MinguoEra.BEFORE_ROC).getDisplayName(style, locale)
                CalendarSystem.ISLAMIC_UMALQURA -> HijrahEra.AH.getDisplayName(style, locale)
                CalendarSystem.JAPANESE -> fields.japaneseDate?.era?.getDisplayName(style, locale) ?: ""
            }
        } catch (_: RuntimeException) {
            ""
        }

        fun month(fields: Fields, width: Width, standalone: Boolean): String {
            val hijrah = fields.hijrahDate
            if (hijrah != null) return text(ChronoField.MONTH_OF_YEAR, width, standalone, HijrahChronology.INSTANCE, hijrah)
            return try {
                Month.of(fields.month + 1).getDisplayName(style(width, standalone), locale)
            } catch (_: RuntimeException) {
                ""
            }
        }

        fun weekday(fields: Fields, width: Width, standalone: Boolean): String = try {
            // ICU counts from Sunday = 1, ISO from Monday = 1.
            DayOfWeek.of((fields.dayOfWeek + 5) % 7 + 1).getDisplayName(style(width, standalone), locale)
        } catch (_: RuntimeException) {
            ""
        }

        fun dayPeriod(fields: Fields, width: Width): String =
            text(ChronoField.AMPM_OF_DAY, width, standalone = false, IsoChronology.INSTANCE, LocalTime.of(fields.hourOfDay, 0))

        fun quarter(fields: Fields, width: Width, standalone: Boolean): String =
            text(IsoFields.QUARTER_OF_YEAR, width, standalone, IsoChronology.INSTANCE, LocalDate.of(2001, fields.month / 3 * 3 + 1, 1))

        fun zoneName(zone: ZoneId, daylight: Boolean, long: Boolean): String = try {
            TimeZone.getTimeZone(zone).getDisplayName(daylight, if (long) TimeZone.LONG else TimeZone.SHORT, locale)
        } catch (_: RuntimeException) {
            zone.id
        }
    }

    private companion object {
        const val MILLIS_PER_MINUTE = 60_000L
        const val MILLIS_PER_HOUR = 3_600_000L
        const val MILLIS_PER_DAY = 86_400_000L
        const val JULIAN_DAY_OF_EPOCH = 2_440_588L
        const val BUDDHIST_ERA_OFFSET = 543
        const val ROC_ERA_START = 1911

        /** ICU pads a number to at most this many digits, however long the pattern run. */
        const val MAXIMUM_DIGITS = 10

        /** The range of ICU's calendars; Foundation formats anything outside it as the empty string. */
        const val MINIMUM_MILLIS = -184_303_902_528_000_000L
        const val MAXIMUM_MILLIS = 183_882_168_921_600_000L

        fun isRepresentable(epochMillis: Long): Boolean = epochMillis in MINIMUM_MILLIS..MAXIMUM_MILLIS

        fun formatStyle(style: DateRenderer.Style): FormatStyle? = when (style) {
            DateRenderer.Style.NONE -> null
            DateRenderer.Style.SHORT -> FormatStyle.SHORT
            DateRenderer.Style.MEDIUM -> FormatStyle.MEDIUM
            DateRenderer.Style.LONG -> FormatStyle.LONG
            DateRenderer.Style.FULL -> FormatStyle.FULL
        }

        /** A lenient Gregorian calendar (Julian before October 1582) in UTC, set to [millis]. */
        fun utcCalendar(millis: Long): GregorianCalendar {
            val calendar = GregorianCalendar(TimeZone.getTimeZone("UTC"), Locale.ROOT)
            calendar.timeInMillis = millis
            return calendar
        }

        /** ICU's `gregoYearFromIslamicStart`: the Gregorian year an Islamic year is related to. */
        fun gregorianYearOfIslamicYear(year: Int): Int {
            val shift: Int
            if (year >= 1397) {
                val cycle = (year - 1397) / 67
                val offset = (year - 1397) % 67
                shift = 2 * cycle + if (offset >= 33) 1 else 0
            } else {
                val cycle = (year - 1396) / 67 - 1
                val offset = -(year - 1396) % 67
                shift = 2 * cycle + if (offset <= 33) 1 else 0
            }
            return year + 579 - shift
        }
    }
}
