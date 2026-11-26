package com.khm.snippets.android.platform

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class RowTimeKindTest {
    private val zone = ZoneId.of("Europe/Paris")
    private val now = millis(2026, 11, 26, 9, 0)

    private fun millis(year: Int, month: Int, day: Int, hour: Int, minute: Int) =
        LocalDateTime.of(year, month, day, hour, minute).atZone(zone).toInstant().toEpochMilli()

    @Test
    fun kindsByCalendarDay() {
        assertEquals(RowTimeKind.Today, rowTimeKind(millis(2026, 11, 26, 0, 1), now, zone))
        assertEquals(RowTimeKind.Yesterday, rowTimeKind(millis(2026, 11, 25, 23, 59), now, zone))
        assertEquals(RowTimeKind.Weekday, rowTimeKind(millis(2026, 11, 24, 12, 0), now, zone))
        assertEquals(RowTimeKind.Weekday, rowTimeKind(millis(2026, 11, 20, 12, 0), now, zone))
        assertEquals(RowTimeKind.Date, rowTimeKind(millis(2026, 11, 19, 12, 0), now, zone))
        assertEquals(RowTimeKind.Date, rowTimeKind(millis(2026, 11, 28, 12, 0), now, zone))
    }
}
