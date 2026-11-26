package com.khm.snippets.android.app

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.khm.snippets.android.feature.editor.EditorTags
import com.khm.snippets.android.feature.library.LibraryTags
import com.khm.snippets.android.ui.components.TestTags
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** The editor on a phone: autosave, keyword help, tags, switches, the secure panel and menu. */
@RunWith(AndroidJUnit4::class)
class EditorFlowTest {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()
    private val app = AppHarness(rule)

    private fun snippet(number: Int) = app.container.library.snapshot.value.entry(DemoLibrary.id(number))!!.snippet

    private fun open(number: Int) {
        app.row(number)
        rule.onNodeWithTag(AppHarness.rowTag(number) + TestTags.Row.EDIT, useUnmergedTree = true).performClick()
        app.waitFor(EditorTags.SCREEN)
    }

    @Test
    fun nameEditsAreSavedWithoutASaveButton() {
        app.start()
        open(Demo.QUICK_REPLY)
        rule.onNodeWithTag(EditorTags.NAME).performTextReplacement("Fast reply")
        rule.onNodeWithTag(TestTags.TOPBAR_TITLE).assertTextEquals("Fast reply")
        rule.waitUntil(3_000) { snippet(Demo.QUICK_REPLY).name == "Fast reply" }
        rule.onNodeWithTag(EditorTags.FOOTER).assertIsDisplayed()
    }

    @Test
    fun keywordSpaceCompletesTheNextPartAndWarnsOfDuplicates() {
        app.start()
        open(Demo.QUICK_REPLY)
        rule.onNodeWithTag(EditorTags.TAB_DETAILS).performClick()
        app.waitFor(EditorTags.KEYWORD)
        // "atl" + space completes to the existing keyword part "atlas-".
        rule.onNodeWithTag(EditorTags.KEYWORD).performTextReplacement("atl")
        rule.onNodeWithTag(EditorTags.KEYWORD).performTextInput(" ")
        rule.waitUntil(3_000) { rule.onAllNodes(hasTestTag(EditorTags.KEYWORD) and hasText("atlas-", substring = true)).fetchSemanticsNodes().isNotEmpty() }
        app.waitFor(EditorTags.KEYWORD_EXISTING)
        // A duplicate of an enabled keyword warns once the field has lost focus.
        rule.onNodeWithTag(EditorTags.KEYWORD).performTextReplacement("meet")
        rule.onNodeWithTag(EditorTags.TAGS + TestTags.Field.INPUT).performClick()
        app.waitFor(EditorTags.KEYWORD + TestTags.Field.MESSAGE)
        rule.onNodeWithTag(EditorTags.KEYWORD + TestTags.Field.MESSAGE, useUnmergedTree = true).assertTextEquals("\\meet is already used by Meeting room.")
        app.waitFor(EditorTags.TAB_DETAILS_DOT)
        rule.waitUntil(3_000) { snippet(Demo.QUICK_REPLY).keyword == "meet" }
    }

    @Test
    fun tagsCommitOnCommaAndComplete() {
        app.start()
        open(Demo.QUICK_REPLY)
        rule.onNodeWithTag(EditorTags.TAB_DETAILS).performClick()
        rule.onNodeWithTag(EditorTags.TAGS + TestTags.Field.INPUT).performTextInput("Alpha, wo")
        app.waitFor(EditorTags.tagCompletion("work"))
        rule.waitUntil(3_000) { snippet(Demo.QUICK_REPLY).tags == listOf("Alpha") }
        rule.onNodeWithTag(EditorTags.tagCompletion("work")).performClick()
        rule.waitUntil(3_000) { snippet(Demo.QUICK_REPLY).tags == listOf("Alpha", "work") }
        rule.onNodeWithTag(TestTags.editorTag("alpha") + TestTags.Field.REMOVE, useUnmergedTree = true).performClick()
        rule.waitUntil(3_000) { snippet(Demo.QUICK_REPLY).tags == listOf("work") }
    }

    @Test
    fun enabledSwitchWritesAtOnce() {
        app.start()
        open(Demo.QUICK_REPLY)
        rule.onNodeWithTag(EditorTags.TAB_DETAILS).performClick()
        rule.onNodeWithTag(EditorTags.ENABLED).assertIsOn().performClick()
        rule.waitUntil(2_000) { !snippet(Demo.QUICK_REPLY).isEnabled }
        rule.onNodeWithTag(EditorTags.ENABLED).assertIsOff()
    }

    @Test
    fun previewResolvesPlaceholdersWithAClipboardStandIn() {
        app.start()
        open(Demo.MEETING_NOTES)
        rule.onNodeWithTag(EditorTags.PREVIEW_TOGGLE).performClick()
        app.waitFor(EditorTags.PREVIEW_TEXT)
        rule.onNodeWithTag(EditorTags.BODY).performTextInput("{clipboard}")
        rule.waitUntil(3_000) {
            rule.onAllNodes(hasTestTag(EditorTags.PREVIEW_TEXT) and hasText("[Clipboard content]", substring = true)).fetchSemanticsNodes().isNotEmpty()
        }
    }

    @Test
    fun revealShowsTheBodyOutsideTheAccessibilityTreeAndLockHidesIt() {
        app.start()
        open(Demo.ATLAS_TOKEN)
        rule.onNodeWithTag(TestTags.SECURE_PANEL).assert(stateIs("locked"))
        rule.onNodeWithTag(TestTags.SECURE_REVEAL).performClick()
        app.waitFor(TestTags.SECURE_BODY)
        rule.onNodeWithTag(TestTags.SECURE_PANEL).assert(stateIs("revealed"))
        // The plaintext is drawn but never in the semantics tree.
        rule.onAllNodes(hasText("sk-live", substring = true), useUnmergedTree = true).assertCountEquals(0)
        saveScreenshot("phone-secure-revealed")
        rule.onNodeWithTag(TestTags.SECURE_LOCK).performClick()
        app.waitUntilGone(TestTags.SECURE_BODY)
        rule.onNodeWithTag(TestTags.SECURE_PANEL).assert(stateIs("locked"))
    }

    @Test
    fun revealedEditsGoToTheVault() {
        app.start()
        open(Demo.ATLAS_TOKEN)
        rule.onNodeWithTag(TestTags.SECURE_REVEAL).performClick()
        app.waitFor(TestTags.SECURE_BODY)
        // The revealed body is outside the semantics tree: type into it with key events.
        rule.onNodeWithTag(TestTags.SECURE_BODY, useUnmergedTree = true).performClick()
        rule.waitForIdle()
        InstrumentationRegistry.getInstrumentation().sendStringSync("NEW")
        rule.onNodeWithTag(EditorTags.NAME).performClick()
        rule.onNodeWithTag(TestTags.SECURE_LOCK).performClick()
        app.waitUntilGone(TestTags.SECURE_BODY)
        rule.onNodeWithTag(TestTags.SECURE_REVEAL).performClick()
        app.waitFor(TestTags.SECURE_BODY)
        // The vault holds the edit after a lock and a second reveal (checked through the copy).
        rule.onNodeWithTag(EditorTags.COPY).performClick()
        rule.waitUntil(3_000) { app.clipboardText()?.let { it.contains("NEW") && it.length == "sk-live-9f3c2a7e41b8d6c0e5".length + 3 } == true }
    }

    @Test
    fun makingAnEntrySecureMovesTheBodyAndShowsTheLockedPanel() {
        app.start()
        open(Demo.QUICK_REPLY)
        rule.onNodeWithTag(EditorTags.TAB_DETAILS).performClick()
        rule.onNodeWithTag(EditorTags.SECURE).assertIsOff().performClick()
        rule.waitUntil(3_000) { app.container.library.snapshot.value.entry(DemoLibrary.id(Demo.QUICK_REPLY))!!.isSecure }
        rule.onNodeWithTag(EditorTags.SECURE).assertIsOn()
        app.waitFor(TestTags.SNACKBAR)
        rule.onNodeWithTag(TestTags.SNACKBAR, useUnmergedTree = true).assertTextEquals("The body is now in the encrypted vault.")
        rule.onNodeWithTag(EditorTags.TAB_CONTENT).performClick()
        rule.onNodeWithTag(TestTags.SECURE_PANEL).assert(stateIs("locked"))
    }

    @Test
    fun makingASecureEntryOrdinaryConfirmsFirst() {
        app.start()
        open(Demo.ATLAS_TOKEN)
        rule.onNodeWithTag(EditorTags.TAB_DETAILS).performClick()
        rule.onNodeWithTag(EditorTags.SECURE).performClick()
        rule.onNodeWithTag(TestTags.DIALOG_TITLE).assertTextEquals("Make This Snippet Ordinary?")
        rule.onNodeWithTag(TestTags.DIALOG_CONFIRM).performClick()
        rule.waitUntil(3_000) { !app.container.library.snapshot.value.entry(DemoLibrary.id(Demo.ATLAS_TOKEN))!!.isSecure }
        assertEquals("sk-live-9f3c2a7e41b8d6c0e5", snippet(Demo.ATLAS_TOKEN).content)
    }

    @Test
    fun deleteFromTheMenuLeavesTheEditorWithUndo() {
        app.start()
        open(Demo.QUICK_REPLY)
        rule.onNodeWithTag(EditorTags.MORE).performClick()
        rule.onNodeWithTag(TestTags.menuItem(EditorTags.ACTION_DELETE)).performClick()
        app.waitFor(LibraryTags.LIST)
        app.waitFor(TestTags.SNACKBAR_ACTION)
        rule.onNodeWithTag(TestTags.SNACKBAR_ACTION).performClick()
        rule.waitUntil(3_000) { DemoLibrary.id(Demo.QUICK_REPLY) in app.container.library.snapshot.value }
    }

    @Test
    fun duplicateSwitchesTheEditorToTheCopy() {
        app.start()
        open(Demo.PROJECT_BRIEF)
        rule.onNodeWithTag(EditorTags.MORE).performClick()
        rule.onNodeWithTag(TestTags.menuItem(EditorTags.ACTION_DUPLICATE)).performClick()
        rule.waitUntil(3_000) { rule.onAllNodes(hasTestTag(TestTags.TOPBAR_TITLE) and hasText("Project brief Copy")).fetchSemanticsNodes().isNotEmpty() }
        // Up returns to the library, not to the source (the copy replaced it on the stack).
        rule.onNodeWithTag(TestTags.TOPBAR_BACK).performClick()
        app.waitFor(LibraryTags.LIST)
    }

    @Test
    fun anEntryDeletedElsewhereClosesTheEditor() {
        app.start()
        open(Demo.QUICK_REPLY)
        rule.runOnIdle {
            kotlinx.coroutines.runBlocking { app.container.fakes.library.delete(DemoLibrary.id(Demo.QUICK_REPLY)) }
        }
        app.waitFor(LibraryTags.LIST)
        app.waitFor(TestTags.SNACKBAR)
        rule.onNodeWithTag(TestTags.SNACKBAR, useUnmergedTree = true).assertTextEquals("“Quick reply” was deleted on another device.")
    }

    @Test
    fun secureMenuOffersPinAndDeleteOnly() {
        app.start()
        open(Demo.ATLAS_TOKEN)
        rule.onNodeWithTag(EditorTags.MORE).performClick()
        rule.onNodeWithTag(TestTags.menuItem(EditorTags.ACTION_PIN)).assertIsDisplayed()
        rule.onNodeWithTag(TestTags.menuItem(EditorTags.ACTION_DELETE)).assertIsDisplayed()
        rule.onAllNodesWithTag(TestTags.menuItem(EditorTags.ACTION_SHARE_TEXT)).assertCountEquals(0)
        rule.onAllNodesWithTag(TestTags.menuItem(EditorTags.ACTION_DUPLICATE)).assertCountEquals(0)
        assertTrue(snippet(Demo.ATLAS_TOKEN).content.isEmpty())
        assertFalse(snippet(Demo.ATLAS_TOKEN).isPinned)
    }

    private fun stateIs(state: String) = SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, state)

    /**
     * Renders the app into a file for visual review: `captureToImage` draws the composition
     * itself, so a window under FLAG_SECURE (which blanks screenshots) can still be checked.
     */
    private fun saveScreenshot(name: String) {
        val bitmap = rule.onRoot().captureToImage().asAndroidBitmap()
        val directory = File(app.context.getExternalFilesDir(null), "screenshots").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
