package com.khm.snippets.core.placeholders

import com.khm.snippets.core.search.UtilitiesFixture
import java.time.ZoneId
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * [JvmDateRenderer] against Foundation: what `DateFormatter` printed and what
 * `Calendar.date(byAdding:)` returned on macOS, for the same locale, zone and instant.
 */
class JvmDateRendererTest {

    /** Noon on 1 January 4713 BC, in milliseconds since 1970. */
    private val JULIAN_DAY_ZERO_MILLIS = -210_866_760_000_000L

    private fun renderer(localeTag: String, zone: String) = JvmDateRenderer(Locale.forLanguageTag(localeTag), ZoneId.of(zone))

    /**
     * Patterns whose output is locale text that the JDK spells differently from Apple's
     * ICU, or cannot produce. Everything else in the fixture must match exactly.
     */
    private fun isKnownGap(pattern: String): Boolean =
        // Apple prints an ordinal day for three or more `d` ("31st").
        Regex("d{3,}").containsMatchIn(pattern) ||
            // ICU's two-letter weekday; the JDK has the abbreviated, wide and narrow forms only.
            Regex("(?<![Ee])E{6}(?!E)|(?<!e)e{6}(?!e)|(?<!c)c{6}(?!c)").containsMatchIn(pattern)

    /**
     * The JDK's Umm al-Qura table covers 1300 to 1600 AH and its Japanese calendar starts
     * with Meiji 6 (1873); ICU continues both by rule. Outside the tables the renderer
     * falls back to Gregorian, which is documented, so those groups are not compared.
     */
    private fun isOutsideTheJdkCalendarTables(locale: String, millis: Long): Boolean = when {
        "islamic" in locale || locale == "ar-SA" -> millis !in -2_000_000_000_000L..6_000_000_000_000L
        "japanese" in locale -> millis < -3_000_000_000_000L
        else -> false
    }

    /**
     * 57 000 formatted dates. The numeric tier holds no locale text at all: years in five
     * calendars, weeks, day counts, fractions, padding, ISO offsets, quoting, and where
     * output stops at an invalid letter. The text tier is en-US month, weekday, era,
     * quarter and day-period names, which every CLDR version spells the same.
     */
    @Test
    fun patternsFormatAsFoundationFormatsThem() {
        var locale = ""
        var zone = ""
        var millis = 0L
        var renderer: JvmDateRenderer? = null
        var checked = 0
        var skipped = 0
        val mismatches = ArrayList<String>()
        for (line in UtilitiesFixture.lines("swift-dates.tsv")) {
            val fields = line.split('\t')
            if (fields[0] == "@") {
                locale = fields[1]
                zone = fields[2]
                millis = fields[3].toLong()
                renderer = renderer(locale, zone)
                continue
            }
            val pattern = UtilitiesFixture.text(fields[1])
            if (isKnownGap(pattern) || isOutsideTheJdkCalendarTables(locale, millis)) {
                skipped += 1
                continue
            }
            val expected = UtilitiesFixture.text(fields[2])
            val actual = renderer!!.format(millis, pattern)
            checked += 1
            if (actual != expected && mismatches.size < 40) {
                mismatches.add("$locale $zone $millis ${fields[0]} ${UtilitiesFixture.scalars(pattern)}: expected ${UtilitiesFixture.scalars(expected)} got ${UtilitiesFixture.scalars(actual)}")
            }
        }
        if (mismatches.isNotEmpty()) fail(mismatches.joinToString("\n"))
        assertTrue(checked > 54_000, "checked $checked")
        assertTrue(skipped in 1..3_000, "skipped $skipped")
    }

    /**
     * 22 000 offsets in four zones: every unit, amounts up to 100 000 either way, month
     * ends, leap days, both daylight-saving changes (skipped and repeated hours), and the
     * Julian calendar before 1582.
     */
    @Test
    fun offsetsMoveAsFoundationMovesThem() {
        var calendar = ""
        var zone = ""
        var millis = 0L
        var renderer: JvmDateRenderer? = null
        var checked = 0
        var ancient = 0
        val mismatches = ArrayList<String>()
        for (line in UtilitiesFixture.lines("swift-calendar.tsv")) {
            val fields = line.split('\t')
            if (fields[0] == "@") {
                calendar = fields[1]
                zone = fields[2]
                millis = fields[3].toLong()
                renderer = renderer(if (calendar == "buddhist") "th-TH" else "en-US", zone)
                continue
            }
            val unit = when (fields[0]) {
                "m" -> DateRenderer.Unit.MINUTE
                "h" -> DateRenderer.Unit.HOUR
                "d" -> DateRenderer.Unit.DAY
                "M" -> DateRenderer.Unit.MONTH
                "y" -> DateRenderer.Unit.YEAR
                else -> throw IllegalStateException(fields[0])
            }
            val expected = fields[2].toLongOrNull()
            val actual = renderer!!.add(millis, unit, fields[1].toInt())
            checked += 1
            if (actual == expected) continue
            // Before Julian day 0 (4713 BC) Foundation's Gregorian calendar is one day
            // ahead of ICU's (its Buddhist calendar, which is ICU's, agrees with the JDK
            // in this very fixture). Android formats with ICU, so the JDK's answer stands.
            val beforeJulianDayZero = expected != null && expected < JULIAN_DAY_ZERO_MILLIS
            if (calendar == "gregorian" && beforeJulianDayZero && actual == expected - 86_400_000L) {
                ancient += 1
                continue
            }
            mismatches.add("$calendar $zone $millis ${fields[0]} ${fields[1]}: expected $expected got $actual")
        }
        if (mismatches.isNotEmpty()) fail("${mismatches.size} of $checked\n" + mismatches.take(40).joinToString("\n"))
        assertEquals(250, ancient)
        assertTrue(checked > 22_000, "checked $checked")
    }

    private val monthEnd = 1_769_902_215_000L // 2026-01-31T23:30:15Z

    /** The numeric medium styles are the same in every CLDR version; the Mac's strings are those of the L05 vectors. */
    @Test
    fun localizedStylesThatHoldNoNames() {
        val renderer = renderer("en-US", "UTC")
        fun style(date: DateRenderer.Style, time: DateRenderer.Style, locale: String?) = renderer.format(monthEnd, date, time, locale)
        assertEquals("31.01.2026, 23:30:15", style(DateRenderer.Style.MEDIUM, DateRenderer.Style.MEDIUM, "de-DE"))
        assertEquals("2026/01/31 23:30:15", style(DateRenderer.Style.MEDIUM, DateRenderer.Style.MEDIUM, "ja-JP"))
        assertEquals("23:30:15", style(DateRenderer.Style.NONE, DateRenderer.Style.MEDIUM, "fr-FR"))
        assertEquals("", style(DateRenderer.Style.NONE, DateRenderer.Style.NONE, null))
        assertEquals("", style(DateRenderer.Style.NONE, DateRenderer.Style.NONE, "fr-FR"))
        // Names the JDK and the Mac spell alike.
        assertEquals("Jan 31, 2026", style(DateRenderer.Style.MEDIUM, DateRenderer.Style.NONE, null))
        assertEquals("31 janv. 2026", style(DateRenderer.Style.MEDIUM, DateRenderer.Style.NONE, "fr-FR"))
        assertEquals("31 janv. 2026", style(DateRenderer.Style.MEDIUM, DateRenderer.Style.NONE, "fr"))
        // A named locale brings its own calendar and digits; the zone stays the user's.
        assertEquals("31 ม.ค. 2569 23:30:15", style(DateRenderer.Style.MEDIUM, DateRenderer.Style.MEDIUM, "th-TH"))
        assertEquals("31 ม.ค. 2026", style(DateRenderer.Style.MEDIUM, DateRenderer.Style.NONE, "th-TH-u-ca-gregory"))
        assertEquals("Jan ٣١, ٢٠٢٦", style(DateRenderer.Style.MEDIUM, DateRenderer.Style.NONE, "en-US-u-nu-arab"))
        assertEquals("1 févr. 2026", renderer("en-US", "Europe/Paris").format(monthEnd, DateRenderer.Style.MEDIUM, DateRenderer.Style.NONE, "fr-FR"))
        // Every style of every environment formats to something.
        for (date in DateRenderer.Style.entries) {
            for (time in DateRenderer.Style.entries) {
                if (date == DateRenderer.Style.NONE && time == DateRenderer.Style.NONE) continue
                for (locale in listOf(null, "en-GB", "ar-SA", "fa-IR", "zh-Hant-TW", "ja-JP-u-ca-japanese")) {
                    assertTrue(style(date, time, locale).isNotEmpty(), "$date $time $locale")
                }
            }
        }
    }

    /** `-u-hc-` turns a 12-hour style into a 24-hour one and back, as it does in Foundation. */
    @Test
    fun theHourCyclePreferenceRewritesTheStyle() {
        val renderer = renderer("en-US", "UTC")
        fun time(locale: String, at: Long = monthEnd) = renderer.format(at, DateRenderer.Style.NONE, DateRenderer.Style.MEDIUM, locale)
        assertEquals("23:30:15", time("en-US-u-hc-h23"))
        assertEquals("00:00:00", time("en-US-u-hc-h23", 0L))
        assertEquals("11:30:15\u202FPM", time("fr-FR-u-hc-h12"))
        assertEquals("12:00:00\u202FAM", time("fr-FR-u-hc-h12", 0L))
        // Already of the wanted kind: untouched.
        assertEquals(time("fr-FR"), time("fr-FR-u-hc-h23"))
        assertEquals(time("en-US"), time("en-US-u-hc-h12"))
        assertEquals("Jan 31, 2026", renderer.format(monthEnd, DateRenderer.Style.MEDIUM, DateRenderer.Style.NONE, "en-US-u-hc-h23"))
        val both = renderer.format(monthEnd, DateRenderer.Style.MEDIUM, DateRenderer.Style.MEDIUM, "en-US-u-hc-h23")
        assertTrue(both.endsWith("23:30:15") && both.startsWith("Jan 31, 2026"), both)
        // The user's own locale carries the preference too.
        val twentyFour = JvmDateRenderer(Locale.forLanguageTag("en-US-u-hc-h23"), ZoneId.of("UTC"))
        assertEquals("23:30:15", twentyFour.format(monthEnd, DateRenderer.Style.NONE, DateRenderer.Style.MEDIUM, null))
    }

    /** The locales the L05 vectors name are known to the JVM too, and nonsense is not. */
    @Test
    fun theJvmKnowsTheLocalesOfTheVectors() {
        val resolver = PlaceholderResolver(renderer("en-US", "UTC"))
        for (tag in listOf("en-US", "en-GB", "de-DE", "ja-JP", "ar-SA", "th-TH", "fa-IR", "he-IL", "zh-Hant-TW", "fr", "fr-FR", "fr-CA", "sr-Latn-RS", "en-US-u-hc-h23", "th-TH-u-ca-gregory", "en-US-u-nu-arab")) {
            assertTrue(resolver.isResolvablePlaceholder("{date locale=\"$tag\"}"), tag)
        }
        for (tag in listOf("xx-XX", "zz", "english", "fr_FR", "")) {
            assertTrue(!resolver.isResolvablePlaceholder("{date locale=\"$tag\"}"), tag)
        }
        assertTrue(renderer("en-US", "UTC").availableLocaleIdentifiers().size > 100)
    }

    @Test
    fun instantsOutsideTheCalendarFormatAsNothingAndOverflowIsNoDate() {
        val renderer = renderer("en-US", "Europe/Paris")
        assertEquals("", renderer.format(Long.MAX_VALUE, "yyyy"))
        assertEquals("", renderer.format(Long.MIN_VALUE, "yyyy"))
        assertEquals("", renderer.format(Long.MAX_VALUE, DateRenderer.Style.MEDIUM, DateRenderer.Style.MEDIUM, null))
        assertNull(renderer.add(Long.MAX_VALUE, DateRenderer.Unit.MINUTE, 1))
        assertNull(renderer.add(Long.MIN_VALUE, DateRenderer.Unit.HOUR, -1))
        assertEquals(60_000L, renderer.add(0L, DateRenderer.Unit.MINUTE, 1))
        assertEquals(-3_600_000L, renderer.add(0L, DateRenderer.Unit.HOUR, -1))
        // Adding nothing is the identity, also for an instant that cannot be formatted.
        for (unit in DateRenderer.Unit.entries) assertEquals(Long.MAX_VALUE, renderer.add(Long.MAX_VALUE, unit, 0))
        // 800 000 years on: far, and still a date.
        var instant: Long? = 0L
        repeat(8) { instant = renderer.add(instant!!, DateRenderer.Unit.YEAR, 100_000) }
        assertEquals("801970-01-01", renderer.format(instant!!, "y-MM-dd"))
    }

    /** The Umm al-Qura calendar as the user's own: months and years step in it. */
    @Test
    fun aUsersHijriCalendarStepsInHijriMonths() {
        val renderer = renderer("ar-SA-u-nu-latn", "UTC")
        assertEquals("1447-08-12", renderer.format(monthEnd, "yyyy-MM-dd"))
        assertEquals("1447-09-12", renderer.format(renderer.add(monthEnd, DateRenderer.Unit.MONTH, 1)!!, "yyyy-MM-dd"))
        assertEquals("1448-08-12", renderer.format(renderer.add(monthEnd, DateRenderer.Unit.YEAR, 1)!!, "yyyy-MM-dd"))
        assertEquals("1447-08-13", renderer.format(renderer.add(monthEnd, DateRenderer.Unit.DAY, 1)!!, "yyyy-MM-dd"))
        // A Gregorian user who names the locale gets Gregorian steps, shown in the Hijri calendar (L05 month-end-93).
        val gregorian = renderer("en-US", "UTC")
        val nextMonth = gregorian.add(monthEnd, DateRenderer.Unit.MONTH, 1)!!
        assertEquals("2026-02-28", gregorian.format(nextMonth, "yyyy-MM-dd"))
        assertEquals("1447-09-11", renderer.format(nextMonth, "yyyy-MM-dd"))
    }
}
