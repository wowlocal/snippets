package com.khm.snippets.android.platform

import android.content.Context
import android.text.format.DateFormat
import com.khm.snippets.android.R
import com.khm.snippets.core.clock.AppleTime
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.Date
import java.util.Locale

/** How a row shows a moment (components.md §1.1). */
enum class RowTimeKind { Today, Yesterday, Weekday, Date }

/**
 * Which form a moment takes relative to [nowMillis]: today, yesterday, 2 to 6 days ago, or
 * anything else (also a moment in the future on another day).
 */
fun rowTimeKind(thenMillis: Long, nowMillis: Long, zone: ZoneId): RowTimeKind {
    val then = Instant.ofEpochMilli(thenMillis).atZone(zone).toLocalDate()
    val today = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
    return when (ChronoUnit.DAYS.between(then, today)) {
        0L -> RowTimeKind.Today
        1L -> RowTimeKind.Yesterday
        in 2L..6L -> RowTimeKind.Weekday
        else -> RowTimeKind.Date
    }
}

/**
 * Timestamps for display. Inputs are seconds since 2001 (`AppleTime`); they are converted here
 * and nowhere else.
 */
interface TimeFormatter {
    /** A row's time: time of day today, `Yesterday`, an abbreviated weekday, else `MMM d`. */
    fun rowTime(appleSeconds: Double): String

    /** Short time of day, following the device's 12/24-hour setting. */
    fun shortTime(appleSeconds: Double): String

    /** Medium date, for example `Nov 25, 2026`. */
    fun mediumDate(appleSeconds: Double): String

    fun isToday(appleSeconds: Double): Boolean
}

class AndroidTimeFormatter(
    context: Context,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) : TimeFormatter {
    private val appContext = context.applicationContext

    override fun rowTime(appleSeconds: Double): String {
        val millis = AppleTime.displayUnixMillis(appleSeconds)
        return when (rowTimeKind(millis, nowMillis(), ZoneId.systemDefault())) {
            RowTimeKind.Today -> shortTime(appleSeconds)
            RowTimeKind.Yesterday -> appContext.getString(R.string.time_yesterday)
            RowTimeKind.Weekday -> SimpleDateFormat("EEE", locale()).format(Date(millis))
            RowTimeKind.Date -> SimpleDateFormat(DateFormat.getBestDateTimePattern(locale(), "MMMd"), locale()).format(Date(millis))
        }
    }

    override fun shortTime(appleSeconds: Double): String =
        DateFormat.getTimeFormat(appContext).format(Date(AppleTime.displayUnixMillis(appleSeconds)))

    override fun mediumDate(appleSeconds: Double): String =
        DateFormat.getMediumDateFormat(appContext).format(Date(AppleTime.displayUnixMillis(appleSeconds)))

    override fun isToday(appleSeconds: Double): Boolean =
        rowTimeKind(AppleTime.displayUnixMillis(appleSeconds), nowMillis(), ZoneId.systemDefault()) == RowTimeKind.Today

    private fun locale(): Locale = appContext.resources.configuration.locales[0]
}
