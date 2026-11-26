package com.khm.snippets.android.platform

import org.junit.Assert.assertEquals
import org.junit.Test

class HourCycleTest {
    @Test
    fun h23DropsTheDayPeriod() {
        assertEquals("HH':'mm", HourCycle.apply("h:mm a", "h23"))
        assertEquals("MMM' 'd', 'y', 'HH':'mm", HourCycle.apply("MMM d, y, h:mm a", "h23"))
    }

    @Test
    fun h23DropsALeadingPeriodAndItsSpace() {
        assertEquals("HH':'mm", HourCycle.apply("a h:mm", "h23"))
    }

    @Test
    fun h12AddsThePeriodAfterTheLastTimeField() {
        assertEquals("h':'mm' 'a", HourCycle.apply("HH:mm", "h12"))
        assertEquals("h':'mm':'ss' 'a", HourCycle.apply("HH:mm:ss", "h12"))
    }

    @Test
    fun aMatchingOrUnknownCycleOrNoHourLeavesThePatternAlone() {
        assertEquals("HH:mm", HourCycle.apply("HH:mm", "h23"))
        assertEquals("h:mm a", HourCycle.apply("h:mm a", "h12"))
        assertEquals("h:mm a", HourCycle.apply("h:mm a", "h99"))
        assertEquals("MMM d, y", HourCycle.apply("MMM d, y", "h23"))
    }

    @Test
    fun quotedLiteralsSurvive() {
        assertEquals("HH' o''clock'", HourCycle.apply("h 'o''clock' a", "h23"))
    }
}
