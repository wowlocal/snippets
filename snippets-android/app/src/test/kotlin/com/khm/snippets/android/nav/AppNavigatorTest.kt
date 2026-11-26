package com.khm.snippets.android.nav

import androidx.navigation3.runtime.NavKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AppNavigatorTest {
    private val stack = mutableListOf<NavKey>(LibraryRoute)
    private val navigator = AppNavigator(stack)

    @Test
    fun anEditorOnTopIsReplacedNotStacked() {
        navigator.openEditor("a", focusBody = true)
        navigator.openEditor("b")
        assertEquals(listOf(LibraryRoute, EditorRoute("b")), stack)
        assertEquals("b", navigator.selectedSnippetId)
        navigator.openEditor("b", focusBody = true)
        assertEquals(listOf(LibraryRoute, EditorRoute("b")), stack)
    }

    @Test
    fun closeEditorOnlyClosesThatEditor() {
        navigator.openEditor("a")
        navigator.closeEditor("b")
        assertEquals(2, stack.size)
        navigator.closeEditor("a")
        assertEquals(listOf<NavKey>(LibraryRoute), stack)
        assertNull(navigator.selectedSnippetId)
    }

    @Test
    fun settingsPreselectSyncInTwoPanes() {
        navigator.openSettings(pane = null, isTwoPane = true)
        assertEquals(listOf(LibraryRoute, SettingsRoute, SettingsSyncRoute), stack)
    }

    @Test
    fun settingsOnAPhoneOpenTheListOrTheGivenPane() {
        navigator.openSettings(pane = null, isTwoPane = false)
        assertEquals(listOf<NavKey>(LibraryRoute, SettingsRoute), stack)
        navigator.openSettings(pane = SettingsSecureRoute, isTwoPane = false)
        assertEquals(listOf(LibraryRoute, SettingsRoute, SettingsSecureRoute), stack)
    }

    @Test
    fun backFollowsThePolicyAndKeepsTheStart() {
        navigator.openEditor("a")
        navigator.back(isTwoPane = false)
        assertEquals(listOf<NavKey>(LibraryRoute), stack)
        navigator.back(isTwoPane = false)
        assertEquals(listOf<NavKey>(LibraryRoute), stack)
    }

    @Test
    fun twoPaneBackFromSettingsReturnsToTheLibraryWithItsSelection() {
        navigator.openEditor("a")
        navigator.openSettings(pane = null, isTwoPane = true)
        navigator.back(isTwoPane = true)
        assertEquals(listOf(LibraryRoute, EditorRoute("a")), stack)
    }

    @Test
    fun navigateDoesNotDuplicateTheTop() {
        navigator.navigate(SyncReviewRoute)
        navigator.navigate(SyncReviewRoute)
        assertEquals(listOf(LibraryRoute, SyncReviewRoute), stack)
    }

    @Test
    fun routeNamesAreTheDesignNames() {
        assertEquals("editor/x", EditorRoute("x").routeName)
        assertEquals("settings/sync/git", SettingsSyncGitRoute.routeName)
        assertEquals("sync/review", SyncReviewRoute.routeName)
    }
}
