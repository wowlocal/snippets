package com.khm.snippets.android.ui.components

import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import com.khm.snippets.android.ui.model.RowPreviewUi
import com.khm.snippets.android.ui.model.SnippetRowAction
import com.khm.snippets.android.ui.model.SnippetRowLayout
import com.khm.snippets.android.ui.model.SwipeActions
import com.khm.snippets.android.ui.model.TextHighlight
import com.khm.snippets.android.ui.model.rowCustomActions
import com.khm.snippets.android.ui.model.rowMenuActions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RowLogicTest {
    private val strings = RowPreviewStrings(
        noContent = "No content",
        secure = "Secure snippet",
        disabled = "Disabled",
        disabledWith = { "Disabled · $it" },
        excerpt = { "…$it" },
    )

    // Line 2 text rules (components.md §1.2)

    @Test
    fun ordinaryContentIsShownAsGiven() {
        val preview = rowPreviewText(RowPreviewUi.Text("first line", listOf(TextHighlight(0, 5))), isEnabled = true, strings)
        assertEquals(RowPreviewText("first line", listOf(TextHighlight(0, 5))), preview)
    }

    @Test
    fun keywordOnlyShowsNothingAfterTheToken() {
        assertNull(rowPreviewText(RowPreviewUi.None, isEnabled = true, strings))
    }

    @Test
    fun neitherKeywordNorContentShowsNoContent() {
        assertEquals("No content", rowPreviewText(RowPreviewUi.NoContent, isEnabled = true, strings)?.text)
    }

    @Test
    fun secureEntriesShowTheFixedTextWithoutHighlights() {
        val preview = rowPreviewText(RowPreviewUi.Secure, isEnabled = true, strings)
        assertEquals(RowPreviewText("Secure snippet", emptyList()), preview)
    }

    @Test
    fun disabledEntriesGetThePrefixAndHighlightsMoveWithTheText() {
        val preview = rowPreviewText(RowPreviewUi.Text("hello world", listOf(TextHighlight(6, 11))), isEnabled = false, strings)
        assertEquals("Disabled · hello world", preview?.text)
        assertEquals(listOf(TextHighlight(17, 22)), preview?.highlights)
        assertEquals("world", preview!!.text.substring(17, 22))
    }

    @Test
    fun disabledKeywordOnlyShowsDisabled() {
        assertEquals(RowPreviewText("Disabled", emptyList()), rowPreviewText(RowPreviewUi.None, isEnabled = false, strings))
    }

    @Test
    fun disabledSecureAndDisabledEmpty() {
        assertEquals("Disabled · Secure snippet", rowPreviewText(RowPreviewUi.Secure, isEnabled = false, strings)?.text)
        assertEquals("Disabled · No content", rowPreviewText(RowPreviewUi.NoContent, isEnabled = false, strings)?.text)
    }

    @Test
    fun excerptGetsAnEllipsisAndKeepsItsMatch() {
        val excerpt = RowPreviewUi.Text("with the atlas profile", listOf(TextHighlight(9, 14)), isExcerpt = true)
        val preview = rowPreviewText(excerpt, isEnabled = true, strings)!!
        assertEquals("…with the atlas profile", preview.text)
        assertEquals("atlas", preview.text.substring(preview.highlights.single().start, preview.highlights.single().end))
    }

    @Test
    fun disabledExcerptStacksBothPrefixes() {
        val excerpt = RowPreviewUi.Text("the atlas", listOf(TextHighlight(4, 9)), isExcerpt = true)
        val preview = rowPreviewText(excerpt, isEnabled = false, strings)!!
        assertEquals("Disabled · …the atlas", preview.text)
        assertEquals("atlas", preview.text.substring(preview.highlights.single().start, preview.highlights.single().end))
    }

    // Tag line (components.md §1.1, line 3)

    @Test
    fun allPillsFitWhenThereIsRoom() {
        val count = fittingPillCount(listOf(40, 40, 40), totalTags = 3, gap = 6, maxWidth = 200) { 20 }
        assertEquals(3, count)
    }

    @Test
    fun hiddenTagsReserveRoomForTheOverflowLabel() {
        // 3 pills = 132; with "+2" (20 + 6) = 158 > 150, so only two pills are shown.
        val count = fittingPillCount(listOf(40, 40, 40), totalTags = 5, gap = 6, maxWidth = 150) { 20 }
        assertEquals(2, count)
    }

    @Test
    fun pillsThatDoNotFitAreCountedIntoTheOverflow() {
        val requested = ArrayList<Int>()
        val count = fittingPillCount(listOf(80, 80, 80), totalTags = 3, gap = 6, maxWidth = 120) {
            requested += it
            20
        }
        assertEquals(1, count)
        assertTrue(requested.contains(2))
    }

    @Test
    fun atLeastOnePillIsAlwaysShown() {
        assertEquals(1, fittingPillCount(listOf(500), totalTags = 4, gap = 6, maxWidth = 100) { 20 })
        assertEquals(0, fittingPillCount(emptyList(), totalTags = 0, gap = 6, maxWidth = 100) { 20 })
    }

    // Menu, accessibility actions and swipes

    @Test
    fun singlePaneMenuForAnOrdinaryEntry() {
        assertEquals(
            listOf(
                SnippetRowAction.Copy,
                SnippetRowAction.Edit,
                SnippetRowAction.TogglePin,
                SnippetRowAction.Duplicate,
                SnippetRowAction.Delete,
            ),
            rowMenuActions(SnippetRowLayout.SinglePane, isSecure = false),
        )
    }

    @Test
    fun singlePaneMenuForASecureEntryHasNoDuplicate() {
        assertEquals(
            listOf(SnippetRowAction.Copy, SnippetRowAction.Edit, SnippetRowAction.TogglePin, SnippetRowAction.Delete),
            rowMenuActions(SnippetRowLayout.SinglePane, isSecure = true),
        )
    }

    @Test
    fun twoPaneMenuUsesTheTabletSet() {
        assertEquals(
            listOf(
                SnippetRowAction.Copy,
                SnippetRowAction.TogglePin,
                SnippetRowAction.ToggleEnabled,
                SnippetRowAction.ToggleSecure,
                SnippetRowAction.Duplicate,
                SnippetRowAction.CopyShareLink,
                SnippetRowAction.Delete,
            ),
            rowMenuActions(SnippetRowLayout.TwoPane, isSecure = false),
        )
        assertEquals(
            listOf(
                SnippetRowAction.Copy,
                SnippetRowAction.TogglePin,
                SnippetRowAction.ToggleEnabled,
                SnippetRowAction.ToggleSecure,
                SnippetRowAction.Delete,
            ),
            rowMenuActions(SnippetRowLayout.TwoPane, isSecure = true),
        )
    }

    @Test
    fun menusEndWithDeleteAndHoldAtMostSevenItems() {
        for (layout in SnippetRowLayout.entries) {
            for (secure in listOf(false, true)) {
                val actions = rowMenuActions(layout, secure)
                assertEquals(SnippetRowAction.Delete, actions.last())
                assertTrue(actions.size <= 7)
                assertEquals(actions.size, actions.distinct().size)
            }
        }
    }

    @Test
    fun customActionsFollowTheSpecifiedOrder() {
        assertEquals(
            listOf(
                SnippetRowAction.Copy,
                SnippetRowAction.Edit,
                SnippetRowAction.TogglePin,
                SnippetRowAction.Duplicate,
                SnippetRowAction.Delete,
            ),
            rowCustomActions(isSecure = false),
        )
        assertFalse(rowCustomActions(isSecure = true).contains(SnippetRowAction.Duplicate))
    }

    @Test
    fun deleteIsNeverASwipeAction() {
        assertEquals(listOf(SnippetRowAction.Edit, SnippetRowAction.TogglePin), SwipeActions)
        assertFalse(SwipeActions.contains(SnippetRowAction.Delete))
    }

    @Test
    fun menuTagsAreTheSpecifiedOnes() {
        assertEquals(
            listOf("copy", "edit", "pin", "enabled", "secure", "duplicate", "copy-link", "delete"),
            SnippetRowAction.entries.map { it.menuTag },
        )
        assertEquals("menu.item.copy-link", TestTags.menuItem(SnippetRowAction.CopyShareLink.menuTag))
    }

    // Haptics and snackbar timing

    @Test
    fun hapticsMapToTheSpecifiedConstants() {
        assertEquals(HapticFeedbackType.Confirm, hapticFeedbackTypeOf(SnippetsHaptic.CopySucceeded))
        assertEquals(HapticFeedbackType.Reject, hapticFeedbackTypeOf(SnippetsHaptic.Rejected))
        assertEquals(HapticFeedbackType.LongPress, hapticFeedbackTypeOf(SnippetsHaptic.RowMenuOpened))
        assertEquals(HapticFeedbackType.GestureThresholdActivate, hapticFeedbackTypeOf(SnippetsHaptic.SwipeArmed))
        assertEquals(HapticFeedbackType.SegmentTick, hapticFeedbackTypeOf(SnippetsHaptic.SwipeDisarmed))
        assertEquals(HapticFeedbackType.ToggleOn, hapticFeedbackTypeOf(SnippetsHaptic.ToggledOn))
        assertEquals(HapticFeedbackType.ToggleOff, hapticFeedbackTypeOf(SnippetsHaptic.ToggledOff))
        assertEquals(HapticFeedbackType.Confirm, hapticFeedbackTypeOf(SnippetsHaptic.Deleted))
        assertEquals(HapticFeedbackType.SegmentTick, hapticFeedbackTypeOf(SnippetsHaptic.TagFilterToggled))
        assertEquals(HapticFeedbackType.Confirm, hapticFeedbackTypeOf(SnippetsHaptic.SecretCopied))
        assertEquals(HapticFeedbackType.Reject, hapticFeedbackTypeOf(SnippetsHaptic.ValidationFailed))
    }

    @Test
    fun snackbarWithActionStaysTenSeconds() {
        assertEquals(10_000L, SnackbarTiming.withAction(touchExploration = false) { 99_000L })
    }

    @Test
    fun touchExplorationRaisesTheTimeoutToAtLeastTwentySeconds() {
        assertEquals(20_000L, SnackbarTiming.withAction(touchExploration = true) { it })
        assertEquals(30_000L, SnackbarTiming.withAction(touchExploration = true) { 30_000L })
    }

    @Test
    fun testTagsFollowTheNamingScheme() {
        assertEquals("library.row.abc.glyph.secure", TestTags.row("abc") + TestTags.Row.GLYPH_SECURE)
        assertEquals("library.tag-chip.work", TestTags.tagChip("work"))
        assertEquals("git.error.git_http_401.code-copy", TestTags.problem("git", "git_http_401") + TestTags.Problem.CODE_COPY)
        assertEquals("progress.step.2", TestTags.progressStep(2))
        assertEquals("settings.row.sync.detail", TestTags.settingsRow("sync") + TestTags.Settings.DETAIL)
    }
}
