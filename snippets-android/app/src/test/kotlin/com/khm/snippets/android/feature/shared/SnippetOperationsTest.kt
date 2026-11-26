package com.khm.snippets.android.feature.shared

import com.khm.snippets.android.data.fake.FakeBackends
import com.khm.snippets.android.data.valueOrNull
import com.khm.snippets.android.platform.AuthReason
import com.khm.snippets.android.platform.AuthResult
import com.khm.snippets.android.platform.ClipboardService
import com.khm.snippets.android.platform.PlatformInfo
import com.khm.snippets.android.testing.FakeClipboard
import com.khm.snippets.android.testing.RecordingScheduler
import com.khm.snippets.android.testing.id
import com.khm.snippets.android.testing.monotonicClock
import com.khm.snippets.android.testing.resolver
import com.khm.snippets.android.testing.seed
import com.khm.snippets.android.testing.snippet
import com.khm.snippets.android.ui.model.CountdownUi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SnippetOperationsTest {
    private val clipboard = FakeClipboard()

    private class Harness(val fakes: FakeBackends, val operations: SnippetOperations, val service: ClipboardService)

    private fun TestScope.harness(): Harness {
        val clock = testScheduler.monotonicClock()
        val fakes = FakeBackends(backgroundScope, clock)
        val service = ClipboardService(clipboard, clock, backgroundScope, RecordingScheduler(), PlatformInfo(35))
        val operations = SnippetOperations(fakes.library, fakes.vault, resolver(), service, RecoveryKeyPresenter(), backgroundScope)
        fakes.seed(
            listOf(
                seed(snippet(1, name = "Plain", content = "Hello {date:yyyy}")),
                seed(snippet(2, name = "Clip", content = "Pasted: {clipboard}")),
                seed(snippet(3, name = "Empty")),
                seed(snippet(4, name = "Token"), secureBody = "s3cret {clipboard}"),
            ),
        )
        return Harness(fakes, operations, service)
    }

    @Test
    fun anOrdinaryCopyResolvesWithoutReadingTheClipboard() = runTest {
        val h = harness()
        assertEquals(CopyResult.Copied("Plain", wasSecure = false), h.operations.copy(id(1)))
        assertEquals("Hello 2026", clipboard.text)
        assertEquals(0, clipboard.reads)
        assertFalse(clipboard.sensitive)
    }

    @Test
    fun theClipboardIsReadOnlyForTheClipboardPlaceholder() = runTest {
        val h = harness()
        clipboard.text = "earlier"
        h.operations.copy(id(2))
        assertEquals("Pasted: earlier", clipboard.text)
        assertEquals(1, clipboard.reads)
    }

    @Test
    fun emptyAndMissingEntries() = runTest {
        val h = harness()
        assertEquals(CopyResult.NothingToCopy("Empty"), h.operations.copy(id(3)))
        assertEquals(CopyResult.Missing, h.operations.copy(id(99)))
    }

    @Test
    fun aSecureCopyAuthenticatesAndMarksTheClipSensitive() = runTest {
        val h = harness()
        clipboard.text = "c"
        assertEquals(CopyResult.Copied("Token", wasSecure = true), h.operations.copy(id(4)))
        assertEquals("s3cret c", clipboard.text)
        assertTrue(clipboard.sensitive)
        assertTrue(h.service.countdown.value is CountdownUi.Running)
        assertEquals(AuthReason.CopySnippet("Token"), h.fakes.authenticator.requests.single())
    }

    @Test
    fun aCancelledSecureCopyWritesNothing() = runTest {
        val h = harness()
        h.fakes.authenticator.answer = AuthResult.Cancelled
        assertEquals(CopyResult.Cancelled, h.operations.copy(id(4)))
        assertEquals(null, clipboard.text)
    }

    @Test
    fun deletionsAreRememberedAsLocalAndCanBeUndone() = runTest {
        val h = harness()
        val deletion = h.operations.delete(id(1)).valueOrNull()!!
        assertTrue(h.operations.wasRemovedLocally(id(1)))
        h.operations.undoDelete(deletion.undo!!)
        runCurrent()
        assertFalse(h.operations.wasRemovedLocally(id(1)))
        assertNotNull(h.fakes.library.snapshot.value.entry(id(1)))
    }

    @Test
    fun shareLinkAndResolvedText() = runTest {
        val h = harness()
        assertEquals("Hello 2026", h.operations.resolvedText(id(1)))
        assertEquals(null, h.operations.resolvedText(id(4)))
        h.operations.copyShareLink(id(1))
        assertTrue(clipboard.text!!.startsWith("snippets://share?data="))
    }
}
