package com.khm.snippets.core.placeholders

/**
 * What the placeholder resolver needs from the platform's date machinery: Foundation's
 * `DateFormatter` and `Calendar.current`, which are ICU with the user's locale, time zone
 * and calendar.
 *
 * A renderer is created for one user environment and is immutable. "The user's" below
 * means that environment: locale (with its 12/24-hour preference), time zone and calendar.
 *
 * `:core` has [JvmDateRenderer], built on `java.time`. The Android app supplies one built
 * on `android.icu`, which has the same data as Foundation; the contract is written so
 * that it maps onto ICU directly:
 *
 * - [add] is `Calendar.add(field, amount)` on a calendar of the user's type and zone.
 * - [format] with a pattern is `SimpleDateFormat(pattern, locale)` with the user's zone,
 *   after [IcuDatePattern.formattablePrefix]: ICU4J refuses an invalid pattern outright,
 *   where Foundation formats it up to the first invalid letter.
 * - [format] with styles is `DateFormat.getDateTimeInstance(dateStyle, timeStyle, locale)`
 *   (or the date-only and time-only instances) with the user's zone.
 *
 * Instants are milliseconds since 1970-01-01T00:00:00Z, the unit of ICU's `UDate`.
 *
 * No function may throw, whatever the pattern, locale tag or instant: these values come
 * from snippet text. The resolver treats an exception as "no date" all the same.
 */
interface DateRenderer {

    /** The units a placeholder offset can name: `m`, `h`, `d`, `M`, `y`. */
    enum class Unit { MINUTE, HOUR, DAY, MONTH, YEAR }

    /** `DateFormatter.Style`. The resolver uses [NONE] and [MEDIUM]. */
    enum class Style { NONE, SHORT, MEDIUM, LONG, FULL }

    /**
     * `Locale.availableIdentifiers`: the locales the platform has data for, as BCP 47 tags
     * or ICU identifiers (`fr-FR`, `fr_FR`, `zh-Hant-TW`). A `locale="…"` attribute is
     * accepted only when it names one of them or a prefix of one. The set differs between
     * platforms and OS versions, as it does between Apple's.
     */
    fun availableLocaleIdentifiers(): Collection<String>

    /**
     * `Calendar.current.date(byAdding:value:to:)`: [epochMillis] moved by [amount] units
     * in the user's calendar and time zone. Minutes and hours are exact durations. A day
     * keeps the time on the clock across a change of UTC offset; a month or year also
     * keeps the day of the month, or the last day of a shorter month.
     *
     * `null` when the result cannot be represented; the placeholder then stays as written.
     */
    fun add(epochMillis: Long, unit: Unit, amount: Int): Long?

    /**
     * `DateFormatter` with `dateFormat = pattern`: an ICU (UTS 35) pattern, as typed by the
     * user, in the user's locale, zone and calendar. Never throws: an invalid pattern
     * yields what precedes its first invalid letter, as Foundation does (`{date:foo}`
     * resolves to nothing).
     */
    fun format(epochMillis: Long, pattern: String): String

    /**
     * `DateFormatter` with `dateStyle` and `timeStyle`.
     *
     * @param localeTag the placeholder's `locale="…"` attribute (BCP 47, possibly with
     * `-u-` extensions such as `hc`, `ca`, `nu`), or `null` for the user's locale. A named
     * locale brings its own calendar and conventions; the time zone stays the user's.
     */
    fun format(epochMillis: Long, dateStyle: Style, timeStyle: Style, localeTag: String?): String
}
