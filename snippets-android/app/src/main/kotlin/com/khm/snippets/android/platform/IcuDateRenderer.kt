package com.khm.snippets.android.platform

import android.annotation.SuppressLint
import android.icu.text.DateFormat
import android.icu.text.SimpleDateFormat
import android.icu.util.Calendar
import android.icu.util.TimeZone
import android.icu.util.ULocale
import com.khm.snippets.core.placeholders.DateRenderer
import com.khm.snippets.core.placeholders.IcuDatePattern
import java.util.Date
import java.util.Locale

/**
 * [DateRenderer] on the device's ICU (`android.icu`, API 24+), which carries the same kind of
 * data as Foundation's: ICU pattern semantics, the locale's calendar (Buddhist for `th-TH`) and
 * its medium styles. Immutable; build one per user environment ([IcuDateRenderer.current]).
 *
 * Known differences from Foundation (see `IcuDateRendererL05Test`): a medium or longer date
 * with a time is joined with ", " where Foundation uses the locale's "at" pattern (Android
 * exposes no API for it), and some zone names, Persian/Islamic calendar names and spellings
 * come from a different CLDR version.
 *
 * @param locale The user's locale. A `-u-hc-` extension (h12, h23) is applied to the style
 *   formats, as Foundation applies the device's 12/24-hour setting.
 * @param zoneId An Olson id, for example `Europe/Paris`.
 */
class IcuDateRenderer(private val locale: Locale, private val zoneId: String) : DateRenderer {
    private val userLocale: ULocale = withRegionalCalendar(ULocale.forLocale(locale))
    private val zone: TimeZone = TimeZone.getTimeZone(zoneId)

    override fun availableLocaleIdentifiers(): Collection<String> =
        ULocale.getAvailableLocales().map { it.toLanguageTag() }

    override fun add(epochMillis: Long, unit: DateRenderer.Unit, amount: Int): Long? = try {
        val calendar = Calendar.getInstance(zone, userLocale)
        calendar.timeInMillis = epochMillis
        calendar.add(fieldOf(unit), amount)
        calendar.timeInMillis
    } catch (_: RuntimeException) {
        null
    }

    // The pattern is the snippet's own (`{date:yyyy-MM-dd}`), formatted in the user's locale.
    @SuppressLint("SimpleDateFormat")
    override fun format(epochMillis: Long, pattern: String): String = try {
        val formatter = SimpleDateFormat(capDigits(IcuDatePattern.formattablePrefix(pattern)), userLocale)
        formatter.timeZone = zone
        formatter.format(Date(epochMillis))
    } catch (_: RuntimeException) {
        ""
    }

    override fun format(epochMillis: Long, dateStyle: DateRenderer.Style, timeStyle: DateRenderer.Style, localeTag: String?): String {
        if (dateStyle == DateRenderer.Style.NONE && timeStyle == DateRenderer.Style.NONE) return ""
        return try {
            val formatLocale = if (localeTag == null) userLocale else withRegionalCalendar(ULocale.forLanguageTag(localeTag))
            val formatter = when {
                dateStyle == DateRenderer.Style.NONE -> DateFormat.getTimeInstance(icuStyle(timeStyle), formatLocale)
                timeStyle == DateRenderer.Style.NONE -> DateFormat.getDateInstance(icuStyle(dateStyle), formatLocale)
                else -> DateFormat.getDateTimeInstance(icuStyle(dateStyle), icuStyle(timeStyle), formatLocale)
            }
            formatter.timeZone = zone
            val hourCycle = formatLocale.getUnicodeLocaleType("hc")
            if (hourCycle != null && formatter is SimpleDateFormat) {
                val pattern = formatter.toPattern()
                val adjusted = HourCycle.apply(pattern, hourCycle)
                if (adjusted != pattern) formatter.applyPattern(adjusted)
            }
            formatter.format(Date(epochMillis))
        } catch (_: RuntimeException) {
            ""
        }
    }

    /**
     * The calendar Foundation uses when the locale names none: Buddhist in Thailand, Umm al-Qura
     * in Saudi Arabia, otherwise Gregorian (as core's `JvmDateRenderer`). Android's ICU defaults
     * those regions to Gregorian.
     */
    private fun withRegionalCalendar(locale: ULocale): ULocale {
        if (locale.getKeywordValue("calendar") != null) return locale
        val calendar = when (locale.country) {
            "TH" -> "buddhist"
            "SA" -> "islamic-umalqura"
            else -> return locale
        }
        return locale.setKeywordValue("calendar", calendar)
    }

    /**
     * Apple's ICU (ICU4C) prints at most ten digits of a number field, however long the field;
     * Android's ICU pads to the full length. Longer number fields are shortened to ten letters.
     */
    private fun capDigits(pattern: String): String {
        val items = IcuDatePattern.parse(pattern).items
        if (items.none { it is IcuDatePattern.Item.Field && it.letter in NUMBER_FIELDS && it.count > MAXIMUM_DIGITS }) return pattern
        return items.joinToString("") { item ->
            when (item) {
                is IcuDatePattern.Item.Field ->
                    item.letter.toString().repeat(if (item.letter in NUMBER_FIELDS) minOf(item.count, MAXIMUM_DIGITS) else item.count)
                is IcuDatePattern.Item.Literal -> HourCycle.quoted(item.text)
            }
        }
    }

    private fun fieldOf(unit: DateRenderer.Unit): Int = when (unit) {
        DateRenderer.Unit.MINUTE -> Calendar.MINUTE
        DateRenderer.Unit.HOUR -> Calendar.HOUR_OF_DAY
        DateRenderer.Unit.DAY -> Calendar.DAY_OF_MONTH
        DateRenderer.Unit.MONTH -> Calendar.MONTH
        DateRenderer.Unit.YEAR -> Calendar.YEAR
    }

    private fun icuStyle(style: DateRenderer.Style): Int = when (style) {
        DateRenderer.Style.NONE -> DateFormat.NONE
        DateRenderer.Style.SHORT -> DateFormat.SHORT
        DateRenderer.Style.MEDIUM -> DateFormat.MEDIUM
        DateRenderer.Style.LONG -> DateFormat.LONG
        DateRenderer.Style.FULL -> DateFormat.FULL
    }

    override fun equals(other: Any?): Boolean = other is IcuDateRenderer && other.locale == locale && other.zoneId == zoneId

    override fun hashCode(): Int = 31 * locale.hashCode() + zoneId.hashCode()

    companion object {
        private const val MAXIMUM_DIGITS = 10
        private const val NUMBER_FIELDS = "yYurDFgwWHhKkmsA"

        /**
         * The renderer of the user's environment now: default locale and zone, and the device's
         * 12/24-hour setting as a `-u-hc-` extension. The same instance is returned while nothing
         * changed, so resolvers built on it are reused.
         */
        fun current(is24HourFormat: () -> Boolean): () -> DateRenderer {
            var last: IcuDateRenderer? = null
            return {
                val base = Locale.getDefault()
                val locale = Locale.Builder().setLocale(base).setUnicodeLocaleKeyword("hc", if (is24HourFormat()) "h23" else "h12").build()
                val candidate = IcuDateRenderer(locale, java.util.TimeZone.getDefault().id)
                val previous = last
                if (previous != null && previous == candidate) previous else candidate.also { last = it }
            }
        }
    }
}

/**
 * The 12/24-hour preference applied to an ICU style pattern, as Foundation applies the device
 * setting: `h23` drops the day period and uses a two-digit 24-hour field; `h12` uses a 12-hour
 * field and adds the period after the last time field.
 */
internal object HourCycle {
    fun apply(pattern: String, hourCycle: String): String {
        val wants24 = when (hourCycle) {
            "h23", "h24" -> true
            "h12", "h11" -> false
            else -> return pattern
        }
        val items = IcuDatePattern.parse(pattern).items
        val hourIndex = items.indexOfFirst { it is IcuDatePattern.Item.Field && it.letter in "hHkK" }
        if (hourIndex < 0) return pattern
        val is24 = (items[hourIndex] as IcuDatePattern.Item.Field).letter in "Hk"
        if (wants24 == is24) return pattern
        val out = ArrayList<IcuDatePattern.Item>(items.size + 2)
        if (wants24) {
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
                    item is IcuDatePattern.Item.Field && item.letter in "hK" -> out += IcuDatePattern.Item.Field('H', 2)
                    item is IcuDatePattern.Item.Literal && trimNextLiteral -> {
                        out += IcuDatePattern.Item.Literal(item.text.trimStart(::isSpace))
                        trimNextLiteral = false
                    }
                    else -> {
                        out += item
                        trimNextLiteral = false
                    }
                }
            }
        } else {
            val hasPeriod = items.any { it is IcuDatePattern.Item.Field && it.letter in "abB" }
            val lastTimeField = items.indexOfLast { it is IcuDatePattern.Item.Field && it.letter in "hHkKms" }
            items.forEachIndexed { index, item ->
                out += if (item is IcuDatePattern.Item.Field && item.letter in "Hk") IcuDatePattern.Item.Field('h', 1) else item
                if (index == lastTimeField && !hasPeriod) {
                    out += IcuDatePattern.Item.Literal(" ")
                    out += IcuDatePattern.Item.Field('a', 1)
                }
            }
        }
        return out.joinToString("") { item ->
            when (item) {
                is IcuDatePattern.Item.Field -> item.letter.toString().repeat(item.count)
                is IcuDatePattern.Item.Literal -> quoted(item.text)
            }
        }
    }

    // As IcuDatePattern.formattablePrefix writes literals: one pair of quotes, apostrophes
    // doubled; text that is only apostrophes goes without the pair.
    fun quoted(text: String): String {
        if (text.isEmpty()) return ""
        val doubled = text.replace("'", "''")
        return if (text.all { it == '\'' }) doubled else "'$doubled'"
    }

    private fun isSpace(unit: Char): Boolean = unit == ' ' || unit == ' ' || unit == ' '
}
