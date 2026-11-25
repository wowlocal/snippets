package com.khm.snippets.android.ui.components

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.model.CountdownUi
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SecureCopyCountdownTest {
    @get:Rule
    val rule = createComposeRule()

    /** The test clock the deadline is measured on. */
    private var now = 1_000_000L
    private var state by mutableStateOf<CountdownUi>(CountdownUi.Cleared)
    private var cleared = 0

    private fun setCountdown(initial: CountdownUi) {
        state = initial
        rule.setThemedContent {
            SecureCopyCountdown(
                state = state,
                onClearNow = { cleared++ },
                nowMillis = { now },
                announce = false,
            )
        }
    }

    /** Moves the test clock and lets the row read it. */
    private fun advance(millis: Long) {
        now += millis
        rule.mainClock.advanceTimeBy(200)
        rule.waitForIdle()
    }

    private fun text() = rule.onNodeWithTag("countdown.text", useUnmergedTree = true)

    private fun progress(): Float =
        rule.onNodeWithTag("countdown.progress", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsProperties.ProgressBarRangeInfo].current

    @Test
    fun countsDownWithTheClock() {
        setCountdown(CountdownUi.Running(name = "Atlas API token", deadlineMillis = now + 60_000))
        text().assertTextEquals("Copied “Atlas API token”. Clears in 1:00")
        assertEquals(1f, progress(), 0.001f)

        advance(1_000)
        text().assertTextEquals("Copied “Atlas API token”. Clears in 0:59")

        advance(17_000)
        text().assertTextEquals("Copied “Atlas API token”. Clears in 0:42")
        assertEquals(0.7f, progress(), 0.001f)

        advance(41_500)
        text().assertTextEquals("Copied “Atlas API token”. Clears in 0:01")

        advance(500)
        text().assertTextEquals("Copied “Atlas API token”. Clears in 0:00")
        assertEquals(0f, progress(), 0.001f)

        // Past the deadline the row never shows a negative time.
        advance(5_000)
        text().assertTextEquals("Copied “Atlas API token”. Clears in 0:00")
    }

    @Test
    fun followsTheDeadlineNotTheTimeOnScreen() {
        // A row that is composed late (after rotation, or on another screen) shows what is left.
        now += 18_000
        setCountdown(CountdownUi.Running(name = "Atlas", deadlineMillis = now + 42_000))
        text().assertTextEquals("Copied “Atlas”. Clears in 0:42")
        assertEquals(0.7f, progress(), 0.001f)
    }

    @Test
    fun aNewCopyRestartsTheRowWithTheNewName() {
        setCountdown(CountdownUi.Running(name = "Atlas", deadlineMillis = now + 60_000))
        advance(30_000)
        text().assertTextEquals("Copied “Atlas”. Clears in 0:30")
        state = CountdownUi.Running(name = "Database password", deadlineMillis = now + 60_000)
        advance(0)
        text().assertTextEquals("Copied “Database password”. Clears in 1:00")
    }

    @Test
    fun clearNowIsAButtonAndACustomAction() {
        setCountdown(CountdownUi.Running(name = "Atlas", deadlineMillis = now + 60_000))
        rule.onNodeWithTag("countdown.clear").assertTextEquals("Clear Now").performClick()
        assertEquals(1, cleared)
        val actions = rule.onNodeWithTag("countdown.row", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsActions.CustomActions]
        assertEquals(listOf("Clear Now"), actions.map { it.label })
        rule.runOnUiThread { actions.single().action() }
        assertEquals(2, cleared)
    }

    @Test
    fun clearedStateShowsTheMessageWithoutBarOrButton() {
        setCountdown(CountdownUi.Running(name = "Atlas", deadlineMillis = now + 60_000))
        state = CountdownUi.Cleared
        rule.waitForIdle()
        text().assertTextEquals("Clipboard cleared.")
        rule.onNodeWithTag("countdown.clear").assertDoesNotExist()
        rule.onNodeWithTag("countdown.progress", useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun usesTheLifetimeItIsGiven() {
        setCountdown(CountdownUi.Running(name = "Key", deadlineMillis = now + 120_000, totalMillis = 120_000))
        text().assertTextEquals("Copied “Key”. Clears in 2:00")
        advance(30_000)
        text().assertTextEquals("Copied “Key”. Clears in 1:30")
        assertEquals(0.75f, progress(), 0.001f)
    }
}
