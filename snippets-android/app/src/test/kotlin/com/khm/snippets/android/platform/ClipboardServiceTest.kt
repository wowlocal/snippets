package com.khm.snippets.android.platform

import com.khm.snippets.android.testing.FakeClipboard
import com.khm.snippets.android.testing.RecordingScheduler
import com.khm.snippets.android.testing.monotonicClock
import com.khm.snippets.android.ui.model.CountdownUi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardServiceTest {
    private val clipboard = FakeClipboard()
    private val backstop = RecordingScheduler()

    private fun TestScope.service(sdk: Int = 35) =
        ClipboardService(clipboard, testScheduler.monotonicClock(), backgroundScope, backstop, PlatformInfo(sdk))

    @Test
    fun anOrdinaryCopyIsNotSensitive() = runTest {
        service().copyOrdinary("hello")
        assertEquals("hello", clipboard.text)
        assertFalse(clipboard.sensitive)
        assertFalse(backstop.active)
    }

    @Test
    fun theSystemConfirmsCopiesFromAndroid13() = runTest {
        assertTrue(service(33).showsSystemCopyConfirmation)
        assertFalse(service(32).showsSystemCopyConfirmation)
    }

    @Test
    fun aSecureCopyRunsTheCountdownAndClearsAtTheDeadline() = runTest {
        val service = service()
        service.copySecure("Token", "s3cret")
        assertTrue(clipboard.sensitive)
        assertEquals(CountdownUi.Running("Token", deadlineMillis = 60_000, totalMillis = 60_000), service.countdown.value)
        assertEquals(60_000L, backstop.scheduled.single().second)
        advanceTimeBy(59_999)
        runCurrent()
        assertEquals("s3cret", clipboard.text)
        advanceTimeBy(1)
        runCurrent()
        assertNull(clipboard.text)
        assertEquals(CountdownUi.Cleared, service.countdown.value)
        assertFalse(backstop.active)
        advanceTimeBy(3_000)
        runCurrent()
        assertNull(service.countdown.value)
    }

    @Test
    fun clearNowClearsAtOnce() = runTest {
        val service = service()
        service.copySecure("Token", "s3cret")
        service.clearSecureNow()
        runCurrent()
        assertNull(clipboard.text)
        assertEquals(CountdownUi.Cleared, service.countdown.value)
    }

    @Test
    fun aClipFromAnotherAppIsLeftAloneAndTheRowLeavesSilently() = runTest {
        val service = service()
        service.copySecure("Token", "s3cret")
        clipboard.replaceFromOutside("theirs")
        assertNull(service.countdown.value)
        advanceTimeBy(61_000)
        runCurrent()
        assertEquals("theirs", clipboard.text)
        assertEquals(0, clipboard.clears)
    }

    @Test
    fun anOrdinaryCopyEndsTheCountdown() = runTest {
        val service = service()
        service.copySecure("Token", "s3cret")
        service.copyOrdinary("plain")
        assertNull(service.countdown.value)
        assertFalse(backstop.active)
        advanceTimeBy(61_000)
        runCurrent()
        assertEquals("plain", clipboard.text)
    }

    @Test
    fun anUnreadableClipboardIsClearedAnyway() = runTest {
        val service = service()
        service.copySecure("Token", "s3cret")
        clipboard.readable = false
        advanceTimeBy(60_001)
        assertEquals(1, clipboard.clears)
    }

    @Test
    fun aShortenedLifetimeIsHonoured() = runTest {
        val service = service()
        service.secureClipLifetimeMillis = 5_000
        service.copySecure("Token", "s3cret")
        advanceTimeBy(5_001)
        assertNull(clipboard.text)
    }

    @Test
    fun aSecretIsClearedAfterItsLifetimeWithoutACountdown() = runTest {
        val service = service()
        service.copySecret("KEY", 300_000)
        assertTrue(clipboard.sensitive)
        assertNull(service.countdown.value)
        assertEquals(300_000L, backstop.scheduled.single().second)
        advanceTimeBy(300_001)
        assertNull(clipboard.text)
        assertFalse(backstop.active)
    }

    @Test
    fun readTextReadsTheClipboard() = runTest {
        clipboard.text = "x"
        assertEquals("x", service().readText())
        assertEquals(1, clipboard.reads)
    }
}
