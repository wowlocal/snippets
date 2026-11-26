package com.khm.snippets.android.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BackPolicyTest {
    private val list = PaneRole.List
    private val detail = PaneRole.Detail

    @Test
    fun anOverlayIsDismissedUnlessItIsWorking() {
        assertEquals(BackDecision.DismissOverlay, BackPolicy.decide(BackInput(listOf(list), isTwoPane = false, hasOverlay = true)))
        assertEquals(
            BackDecision.Blocked,
            BackPolicy.decide(BackInput(listOf(list), isTwoPane = false, hasOverlay = true, overlayIsWorking = true)),
        )
    }

    @Test
    fun aQueryIsClearedBeforeLeaving() {
        assertEquals(BackDecision.ClearSearch, BackPolicy.decide(BackInput(listOf(list), isTwoPane = false, libraryHasQuery = true)))
    }

    @Test
    fun theLibraryAloneLeavesTheApp() {
        assertEquals(BackDecision.LeaveApp, BackPolicy.decide(BackInput(listOf(list), isTwoPane = false)))
        assertEquals(BackDecision.LeaveApp, BackPolicy.decide(BackInput(listOf(list), isTwoPane = true)))
    }

    @Test
    fun aPhoneEditorPopsToTheLibrary() {
        assertEquals(BackDecision.Pop(1), BackPolicy.decide(BackInput(listOf(list, detail), isTwoPane = false)))
    }

    @Test
    fun twoPanesWithASelectionLeaveTheApp() {
        assertEquals(BackDecision.LeaveApp, BackPolicy.decide(BackInput(listOf(list, detail), isTwoPane = true)))
    }

    @Test
    fun twoPaneSettingsReturnToTheLibrary() {
        // library, settings, settings/sync
        assertEquals(BackDecision.Pop(2), BackPolicy.decide(BackInput(listOf(list, list, detail), isTwoPane = true)))
        // library, editor, settings, settings/sync: back to library with its selection
        assertEquals(BackDecision.Pop(2), BackPolicy.decide(BackInput(listOf(list, detail, list, detail), isTwoPane = true)))
    }

    @Test
    fun aNestedDetailPopsAlone() {
        // library, settings, settings/sync, settings/sync/git
        assertEquals(BackDecision.Pop(1), BackPolicy.decide(BackInput(listOf(list, list, detail, detail), isTwoPane = true)))
    }

    @Test
    fun aFullWindowRoutePopsOne() {
        assertEquals(BackDecision.Pop(1), BackPolicy.decide(BackInput(listOf(list, null), isTwoPane = true)))
        assertNull(BackPolicy.twoPanePlan(listOf(list, null)))
    }

    @Test
    fun twoPanePlans() {
        assertEquals(TwoPanePlan(listIndex = 0, detailIndex = null, remainingAfterBack = 0), BackPolicy.twoPanePlan(listOf(list)))
        assertEquals(TwoPanePlan(listIndex = 0, detailIndex = 1, remainingAfterBack = 0), BackPolicy.twoPanePlan(listOf(list, detail)))
        assertEquals(TwoPanePlan(listIndex = 1, detailIndex = 3, remainingAfterBack = 3), BackPolicy.twoPanePlan(listOf(list, list, detail, detail)))
        assertNull(BackPolicy.twoPanePlan(listOf(detail)))
    }
}
