package com.khm.snippets.android.app

import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.android.feature.editor.EditorTags
import com.khm.snippets.android.feature.library.LibraryTags
import com.khm.snippets.android.platform.AppShortcut
import com.khm.snippets.android.platform.AuthResult
import com.khm.snippets.android.ui.components.TestTags
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The library on a phone: states, search, filters, copy, swipes, menus, delete, shortcuts. */
@RunWith(AndroidJUnit4::class)
class LibraryFlowTest {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()
    private val app = AppHarness(rule)

    private val snapshot: LibrarySnapshot get() = app.container.library.snapshot.value

    @Test
    fun firstRunShowsTheEmptyLibraryWithoutFabOrFilters() {
        app.start(demo = false)
        rule.onNodeWithTag("library.empty.title").assertTextEquals("Your Library Is Empty")
        rule.onNodeWithTag("library.empty.action").assertTextEquals("New Snippet")
        rule.onNodeWithTag("library.empty.action-2").assertTextEquals("Import…")
        rule.onNodeWithTag("library.empty.action-3").assertTextEquals("Set Up Sync")
        rule.onNodeWithTag("library.empty.note").assertIsDisplayed()
        rule.onAllNodesWithTag(TestTags.LIBRARY_FAB).assertCountEquals(0)
        rule.onAllNodesWithTag(TestTags.LIBRARY_FILTER).assertCountEquals(0)
        rule.onNodeWithTag(TestTags.LIBRARY_SEARCH).assertIsDisplayed()
    }

    @Test
    fun emptyStateNewSnippetCreatesAndAutosaves() {
        app.start(demo = false)
        rule.onNodeWithTag("library.empty.action").performClick()
        app.waitFor(EditorTags.BODY)
        rule.onNodeWithTag(EditorTags.BODY).performTextInput("Hello from the test")
        // Autosave: written after 300 ms of quiet, no Save button.
        rule.waitUntil(3_000) { snapshot.entries.singleOrNull()?.snippet?.content == "Hello from the test" }
        rule.onNodeWithTag(TestTags.TOPBAR_BACK).performClick()
        app.waitFor(LibraryTags.LIST)
        val created = snapshot.entries.single().id
        rule.onNodeWithTag(TestTags.row(created.toString())).assertIsDisplayed()
    }

    @Test
    fun aBlankDraftIsDiscardedWhenLeaving() {
        app.start(demo = false)
        rule.onNodeWithTag("library.empty.action").performClick()
        app.waitFor(EditorTags.BODY)
        rule.onNodeWithTag(TestTags.TOPBAR_BACK).performClick()
        rule.waitUntil(3_000) { snapshot.entries.isEmpty() && snapshot.revision > 1 }
        app.waitFor("library.empty.title")
    }

    @Test
    fun searchFiltersAndHighlights() {
        app.start()
        rule.onNodeWithTag(TestTags.LIBRARY_SEARCH).performTextInput("mtng")
        app.waitForCount("2 of 9 snippets")
        app.row(Demo.MEETING_ROOM).assertIsDisplayed()
        app.row(Demo.MEETING_NOTES).assertIsDisplayed()
        rule.onAllNodesWithTag(AppHarness.rowTag(Demo.QUICK_REPLY)).assertCountEquals(0)
        // Secure bodies are never searched.
        rule.onNodeWithTag(TestTags.LIBRARY_SEARCH_CLEAR).performClick()
        rule.onNodeWithTag(TestTags.LIBRARY_SEARCH).performTextInput("sk-live")
        app.waitFor("library.empty.title")
        rule.onNodeWithTag("library.empty.title").assertTextEquals("No Results")
        rule.onNodeWithTag("library.empty.note").assertTextEquals("Secure snippet bodies are not searched.")
    }

    @Test
    fun tagFiltersCombineWithAnd() {
        app.start()
        app.chip("work").performClick()
        app.waitForCount("5 of 9 snippets")
        app.chip("links").performClick()
        app.waitForCount("2 of 9 snippets")
        rule.onNodeWithTag(TestTags.LIBRARY_FILTER_BADGE, useUnmergedTree = true).assertIsDisplayed()
        // A third filter nobody matches: the filters-no-match state.
        rule.onNodeWithTag(TestTags.LIBRARY_FILTER).performClick()
        app.waitFor(TestTags.tagsRow("travel"))
        rule.onNodeWithTag(TestTags.tagsRow("travel")).performClick()
        app.waitFor("library.empty.title")
        rule.onNodeWithTag("library.empty.title").assertTextEquals("No Snippets Match")
        rule.onNodeWithTag(TestTags.TAGS_CLEAR).performClick()
        app.waitForCount("9 snippets")
    }

    @Test
    fun tapCopiesAndShowsCopied() {
        app.start()
        app.clearClipboard()
        app.row(Demo.MEETING_ROOM).performClick()
        app.waitFor(AppHarness.rowTag(Demo.MEETING_ROOM) + TestTags.Row.COPIED)
        assertEquals("https://meet.example.com/design-review", app.clipboardText())
        // The state lasts 1.5 s.
        app.waitUntilGone(AppHarness.rowTag(Demo.MEETING_ROOM) + TestTags.Row.COPIED)
    }

    @Test
    fun copyResolvesPlaceholders() {
        app.start()
        app.row(Demo.MEETING_NOTES).performClick()
        rule.waitUntil(3_000) { app.clipboardText()?.startsWith("Meeting notes — 2") == true }
        assertFalse(app.clipboardText()!!.contains("{date"))
    }

    @Test
    fun secureCopyShowsTheCountdownAndClearNowClearsTheClipboard() {
        app.start()
        app.row(Demo.ATLAS_TOKEN).performClick()
        app.waitFor(TestTags.COUNTDOWN_ROW)
        rule.onNodeWithTag(TestTags.COUNTDOWN_TEXT, useUnmergedTree = true).assertTextContains("Copied “Atlas API token”. Clears in ", substring = true)
        assertEquals("sk-live-9f3c2a7e41b8d6c0e5", app.clipboardText())
        assertTrue(app.container.fakes.authenticator.requests.isNotEmpty())
        rule.onNodeWithTag(TestTags.COUNTDOWN_CLEAR).performClick()
        rule.waitUntil(3_000) { rule.onAllNodes(hasText("Clipboard cleared.")).fetchSemanticsNodes().isNotEmpty() }
        assertNull(app.clipboardText())
        app.waitUntilGone(TestTags.COUNTDOWN_ROW, timeoutMillis = 6_000)
    }

    @Test
    fun secureClipIsClearedAtItsDeadline() {
        app.start { clipboard.secureClipLifetimeMillis = 2_000 }
        app.row(Demo.ATLAS_TOKEN).performClick()
        app.waitFor(TestTags.COUNTDOWN_ROW)
        rule.waitUntil(5_000) { rule.onAllNodes(hasText("Clipboard cleared.")).fetchSemanticsNodes().isNotEmpty() }
        assertNull(app.clipboardText())
    }

    @Test
    fun cancelledAuthenticationIsSilent() {
        app.start { fakes.authenticator.answer = AuthResult.Cancelled }
        app.clearClipboard()
        app.row(Demo.ATLAS_TOKEN).performClick()
        rule.waitUntil(3_000) { app.container.fakes.authenticator.requests.isNotEmpty() }
        rule.waitForIdle()
        rule.onAllNodesWithTag(TestTags.COUNTDOWN_ROW).assertCountEquals(0)
        rule.onAllNodesWithTag(TestTags.DIALOG_ERROR).assertCountEquals(0)
        rule.onAllNodesWithTag(TestTags.SNACKBAR).assertCountEquals(0)
        assertNull(app.clipboardText())
    }

    @Test
    fun swipeRightEditsAndSwipeLeftPins() {
        app.start()
        app.row(Demo.QUICK_REPLY).performTouchInput { swipeLeft() }
        rule.waitUntil(3_000) { snapshot.entry(DemoLibrary.id(Demo.QUICK_REPLY))!!.snippet.isPinned }
        app.row(Demo.QUICK_REPLY).performTouchInput { swipeRight() }
        app.waitFor(EditorTags.SCREEN)
        rule.onNodeWithTag(TestTags.TOPBAR_TITLE).assertTextEquals("Quick reply")
    }

    @Test
    fun rowMenuPinsAndDuplicatesWithTheKeywordRule() {
        app.start()
        app.row(Demo.TRAVEL).performTouchInput { longClick() }
        rule.onNodeWithTag(TestTags.menuItem("pin")).performClick()
        rule.waitUntil(3_000) { snapshot.entry(DemoLibrary.id(Demo.TRAVEL))!!.snippet.isPinned }
        app.row(Demo.TRAVEL).performTouchInput { longClick() }
        rule.onNodeWithTag(TestTags.menuItem("duplicate")).performClick()
        app.waitFor(EditorTags.SCREEN)
        rule.onNodeWithTag(TestTags.TOPBAR_TITLE).assertTextEquals("Travel checklist Copy")
        val copy = snapshot.entries.single { it.snippet.name == "Travel checklist Copy" }.snippet
        // The source was enabled and has a keyword: the copy starts disabled.
        assertFalse(copy.isEnabled)
        assertEquals("travel", copy.normalizedKeyword)
    }

    @Test
    fun secureRowsOfferNoDuplicate() {
        app.start()
        app.row(Demo.ATLAS_TOKEN).performTouchInput { longClick() }
        rule.onNodeWithTag(TestTags.menuItem("copy")).assertIsDisplayed()
        rule.onAllNodesWithTag(TestTags.menuItem("duplicate")).assertCountEquals(0)
    }

    @Test
    fun deleteShowsUndoWhichRestoresTheEntryInPlace() {
        app.start()
        val before = snapshot.entries.map { it.id }
        app.row(Demo.QUICK_REPLY).performTouchInput { longClick() }
        rule.onNodeWithTag(TestTags.menuItem("delete")).performClick()
        app.waitFor(TestTags.SNACKBAR)
        rule.onNodeWithTag(TestTags.SNACKBAR, useUnmergedTree = true).assertTextEquals("Deleted “Quick reply”.")
        assertFalse(DemoLibrary.id(Demo.QUICK_REPLY) in snapshot)
        rule.onNodeWithTag(TestTags.SNACKBAR_ACTION).performClick()
        rule.waitUntil(3_000) { DemoLibrary.id(Demo.QUICK_REPLY) in snapshot }
        assertEquals(before, snapshot.entries.map { it.id })
    }

    @Test
    fun deletingASecureEntryConfirmsAndHasNoUndo() {
        app.start()
        app.row(Demo.ATLAS_TOKEN).performTouchInput { longClick() }
        rule.onNodeWithTag(TestTags.menuItem("delete")).performClick()
        rule.onNodeWithTag(TestTags.DIALOG_TITLE).assertTextEquals("Delete “Atlas API token”?")
        rule.onNodeWithTag(TestTags.DIALOG_CONFIRM).performClick()
        app.waitFor(TestTags.SNACKBAR)
        rule.onNodeWithTag(TestTags.SNACKBAR, useUnmergedTree = true).assertTextEquals("Secure snippet deleted.")
        rule.onAllNodesWithTag(TestTags.SNACKBAR_ACTION).assertCountEquals(0)
        assertFalse(DemoLibrary.id(Demo.ATLAS_TOKEN) in snapshot)
    }

    @Test
    fun moreMenuOpensPlaceholdersWithTheirRouteNames() {
        app.start()
        rule.onNodeWithTag(TestTags.LIBRARY_MORE).performClick()
        rule.onNodeWithTag(TestTags.menuItem("settings")).performClick()
        app.waitFor("placeholder.settings")
        rule.onNodeWithTag(TestTags.TOPBAR_TITLE).assertTextEquals("settings")
        rule.onNodeWithTag(TestTags.TOPBAR_BACK).performClick()
        app.waitFor(LibraryTags.LIST)
        rule.onNodeWithTag(TestTags.LIBRARY_MORE).performClick()
        rule.onNodeWithTag(TestTags.menuItem("backup")).performClick()
        app.waitFor("placeholder.backup/new-password")
    }

    @Test
    fun newFromClipboardWithAnEmptyClipboardExplains() {
        app.start()
        app.clearClipboard()
        rule.onNodeWithTag(TestTags.LIBRARY_MORE).performClick()
        rule.onNodeWithTag(TestTags.menuItem("new-from-clipboard")).performClick()
        rule.onNodeWithTag(TestTags.DIALOG_TITLE).assertTextEquals("Clipboard Is Empty")
    }

    @Test
    fun pullToRefreshWithoutSyncAsksToSetUp() {
        app.start()
        rule.onNodeWithTag(LibraryTags.LIST).performTouchInput { swipeDown(startY = top + 10f, endY = bottom) }
        app.waitFor("dialog.sync-opt-in")
        rule.onNodeWithTag(TestTags.DIALOG_TITLE).assertTextEquals("Set Up Sync?")
    }

    @Test
    fun keyboardShortcutsCreateAndSearch() {
        app.start()
        rule.runOnIdle { assertTrue(app.container.shortcuts.dispatch(AppShortcut.NewSnippet)) }
        app.waitFor(EditorTags.BODY)
        rule.onNodeWithTag(EditorTags.BODY).performTextInput("From Ctrl+N")
        rule.onNodeWithTag(TestTags.TOPBAR_BACK).performClick()
        app.waitFor(LibraryTags.LIST)
        rule.runOnIdle { app.container.shortcuts.dispatch(AppShortcut.Search) }
        rule.waitUntil(3_000) { rule.onAllNodes(hasTestTag(TestTags.LIBRARY_SEARCH) and isFocused()).fetchSemanticsNodes().isNotEmpty() }
        val created = snapshot.entries.single { it.snippet.content == "From Ctrl+N" }
        assertNotEquals(0, created.snippet.content.length)
    }

    @Test
    fun ctrlZUndoesTheDeleteWhileItsSnackbarShows() {
        app.start()
        app.row(Demo.QUICK_REPLY).performTouchInput { longClick() }
        rule.onNodeWithTag(TestTags.menuItem("delete")).performClick()
        app.waitFor(TestTags.SNACKBAR_ACTION)
        rule.runOnIdle { app.container.shortcuts.dispatch(AppShortcut.Undo) }
        rule.waitUntil(3_000) { DemoLibrary.id(Demo.QUICK_REPLY) in snapshot }
    }

    @Test
    fun backClearsTheQueryButKeepsFilters() {
        app.start()
        app.chip("work").performClick()
        rule.onNodeWithTag(TestTags.LIBRARY_SEARCH).performTextInput("brief")
        app.waitForCount("1 of 9 snippets")
        rule.runOnIdle { rule.activity.onBackPressedDispatcher.onBackPressed() }
        app.waitForCount("5 of 9 snippets")
        rule.onNodeWithText("Search snippets", useUnmergedTree = true).assertIsDisplayed()
    }
}
