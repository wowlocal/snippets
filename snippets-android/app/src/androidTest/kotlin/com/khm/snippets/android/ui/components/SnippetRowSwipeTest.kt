package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.model.SnippetRowAction
import com.khm.snippets.android.ui.model.SnippetRowLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SnippetRowSwipeTest {
    @get:Rule
    val rule = createComposeRule()

    private val clicks = ArrayList<String>()
    private val actions = ArrayList<SnippetRowAction>()

    private fun setRow(layout: SnippetRowLayout = SnippetRowLayout.SinglePane, isPinned: Boolean = false) {
        rule.setThemedContent {
            Column {
                SnippetListItem(
                    row = sampleRow(isPinned = isPinned),
                    onClick = { clicks += "click" },
                    onAction = { actions += it },
                    layout = layout,
                )
            }
        }
    }

    private val row get() = rule.onNodeWithTag("library.row.row")

    @Test
    fun swipeRightCommitsEditOnce() {
        setRow()
        row.performTouchInput { swipeRight() }
        rule.waitForIdle()
        assertEquals(listOf(SnippetRowAction.Edit), actions)
        assertTrue(clicks.isEmpty())
    }

    @Test
    fun swipeLeftCommitsPinOnce() {
        setRow()
        row.performTouchInput { swipeLeft() }
        rule.waitForIdle()
        assertEquals(listOf(SnippetRowAction.TogglePin), actions)
        assertTrue(clicks.isEmpty())
    }

    @Test
    fun rowReturnsAndCanBeSwipedAgain() {
        setRow()
        row.performTouchInput { swipeLeft() }
        rule.waitForIdle()
        row.performTouchInput { swipeRight() }
        rule.waitForIdle()
        assertEquals(listOf(SnippetRowAction.TogglePin, SnippetRowAction.Edit), actions)
        // Back in place: a tap reaches the row again.
        row.performTouchInput { down(center); up() }
        rule.waitForIdle()
        assertEquals(listOf("click"), clicks)
    }

    @Test
    fun slowSwipePastTheThresholdCommitsByPosition() {
        setRow()
        row.performTouchInput {
            swipe(start = Offset(width * 0.1f, centerY), end = Offset(width * 0.75f, centerY), durationMillis = 4_000)
        }
        rule.waitForIdle()
        assertEquals(listOf(SnippetRowAction.Edit), actions)
    }

    @Test
    fun slowSwipeBelowTheThresholdCommitsNothing() {
        setRow()
        row.performTouchInput {
            swipe(start = Offset(width * 0.1f, centerY), end = Offset(width * 0.35f, centerY), durationMillis = 4_000)
        }
        rule.waitForIdle()
        row.performTouchInput {
            swipe(start = Offset(width * 0.9f, centerY), end = Offset(width * 0.65f, centerY), durationMillis = 4_000)
        }
        rule.waitForIdle()
        assertTrue(actions.isEmpty())
    }

    @Test
    fun deleteIsNotReachableByAnySwipe() {
        setRow()
        repeat(2) {
            row.performTouchInput { swipeRight() }
            rule.waitForIdle()
            row.performTouchInput { swipeLeft() }
            rule.waitForIdle()
            row.performTouchInput { swipe(start = centerLeft, end = centerRight, durationMillis = 50) }
            rule.waitForIdle()
            row.performTouchInput { swipe(start = centerRight, end = centerLeft, durationMillis = 50) }
            rule.waitForIdle()
        }
        assertFalse(actions.contains(SnippetRowAction.Delete))
        assertTrue(actions.all { it == SnippetRowAction.Edit || it == SnippetRowAction.TogglePin })
        assertEquals(4, actions.count { it == SnippetRowAction.Edit })
        assertEquals(4, actions.count { it == SnippetRowAction.TogglePin })
    }

    @Test
    fun backgroundNamesTheActionWhileSwiping() {
        setRow(isPinned = true)
        rule.mainClock.autoAdvance = false
        row.performTouchInput {
            down(center)
            moveBy(Offset(-width * 0.3f, 0f))
        }
        rule.mainClock.advanceTimeByFrame()
        rule.onNodeWithText("Unpin", useUnmergedTree = true).assertExists()
        rule.onNodeWithText("Delete", useUnmergedTree = true).assertDoesNotExist()
        row.performTouchInput { moveBy(Offset(width * 0.6f, 0f)) }
        rule.mainClock.advanceTimeByFrame()
        rule.onNodeWithTag("$SWIPE_BACKGROUND_TAG.edit", useUnmergedTree = true).assertExists()
        rule.onNodeWithText("Delete", useUnmergedTree = true).assertDoesNotExist()
        // Back to the start, slowly: neither position nor speed commits anything.
        row.performTouchInput {
            moveBy(Offset(-width * 0.25f, 0f), delayMillis = 2_000)
            moveBy(Offset(-width * 0.04f, 0f), delayMillis = 2_000)
            up()
        }
        rule.mainClock.autoAdvance = true
        rule.waitForIdle()
        assertTrue(actions.isEmpty())
    }

    @Test
    fun swipesAreOffInTwoPane() {
        setRow(layout = SnippetRowLayout.TwoPane)
        row.performTouchInput { swipeRight() }
        rule.waitForIdle()
        row.performTouchInput { swipeLeft() }
        rule.waitForIdle()
        assertTrue(actions.isEmpty())
    }

    @Test
    fun swipeContainerAloneReportsThroughItsCallbacks() {
        val events = ArrayList<String>()
        rule.setThemedContent {
            SnippetRowSwipeBox(pinned = false, onEdit = { events += "edit" }, onTogglePin = { events += "pin" }) {
                SnippetRow(row = sampleRow(), onClick = {}, onAction = {})
            }
        }
        row.performTouchInput { swipeRight() }
        rule.waitForIdle()
        row.performTouchInput { swipeLeft() }
        rule.waitForIdle()
        assertEquals(listOf("edit", "pin"), events)
    }
}
