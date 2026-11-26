package com.khm.snippets.android.app

import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.feature.editor.EditorTags
import com.khm.snippets.android.feature.library.LibraryTags
import com.khm.snippets.android.ui.components.TestTags
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Two panes, resizing and rotation, process-death restoration, TalkBack semantics, font scale. */
@RunWith(AndroidJUnit4::class)
class AdaptiveAndStateTest {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()
    private val app = AppHarness(rule)

    @Test
    fun twoPanesSelectOnTapAndCopyWithTheTrailingButton() {
        app.size = AppHarness.TABLET
        app.start()
        app.waitFor("editor.empty")
        rule.onNodeWithTag("editor.empty.title").assertTextEquals("Select a snippet")
        app.row(Demo.MEETING_NOTES).performClick()
        app.waitFor(EditorTags.SCREEN)
        rule.onNodeWithTag(TestTags.TOPBAR_TITLE).assertTextEquals("Meeting notes")
        // No Up arrow in the detail pane, no tabs: one form with the preview always open.
        rule.onAllNodesWithTag(TestTags.TOPBAR_BACK).assertCountEquals(0)
        rule.onAllNodesWithTag(EditorTags.TAB_DETAILS).assertCountEquals(0)
        app.waitFor(EditorTags.PREVIEW_TEXT)
        app.clearClipboard()
        rule.onNodeWithTag(AppHarness.rowTag(Demo.MEETING_ROOM) + TestTags.Row.COPY, useUnmergedTree = true).performClick()
        rule.waitUntil(3_000) { app.clipboardText() == "https://meet.example.com/design-review" }
    }

    @Test
    fun theSelectionSurvivesResizingBetweenPhoneAndTablet() {
        app.size = AppHarness.TABLET
        app.start()
        app.row(Demo.PROJECT_BRIEF).performClick()
        app.waitFor(EditorTags.SCREEN)
        rule.runOnIdle { app.size = AppHarness.PHONE }
        // Compact: the selected entry is the editor on top of the library.
        rule.waitUntil(3_000) { rule.onAllNodesWithTag(TestTags.TOPBAR_BACK).fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag(TestTags.TOPBAR_TITLE).assertTextEquals("Project brief")
        rule.onAllNodesWithTag(LibraryTags.SCREEN).assertCountEquals(0)
        rule.runOnIdle { app.size = AppHarness.TABLET }
        app.waitFor(LibraryTags.SCREEN)
        rule.onNodeWithTag(TestTags.TOPBAR_TITLE).assertTextEquals("Project brief")
    }

    @Test
    fun rotationKeepsTheEditorAndItsTab() {
        app.start()
        app.row(Demo.QUICK_REPLY)
        rule.onNodeWithTag(AppHarness.rowTag(Demo.QUICK_REPLY) + TestTags.Row.EDIT, useUnmergedTree = true).performClick()
        app.waitFor(EditorTags.SCREEN)
        rule.onNodeWithTag(EditorTags.TAB_DETAILS).performClick()
        app.waitFor(EditorTags.KEYWORD)
        rule.runOnIdle { app.size = AppHarness.PHONE_LANDSCAPE }
        rule.waitForIdle()
        rule.onNodeWithTag(EditorTags.KEYWORD).assertIsDisplayed()
        rule.runOnIdle { app.size = AppHarness.PHONE }
        rule.onNodeWithTag(EditorTags.KEYWORD).assertIsDisplayed()
    }

    @Test
    fun processDeathRestoresBackStackQueryFiltersAndTabButNoSecret() {
        val tester = StateRestorationTester(rule)
        app.prepare()
        tester.setContent {
            // A fresh ViewModel store after the restore: ViewModels are rebuilt from saved state,
            // as after process death.
            val owner = remember { object : ViewModelStoreOwner { override val viewModelStore = ViewModelStore() } }
            CompositionLocalProvider(LocalViewModelStoreOwner provides owner) { app.App() }
        }
        app.chip("work").performClick()
        rule.onNodeWithTag(TestTags.LIBRARY_SEARCH).performTextInput("token")
        app.waitForCount("1 of 9 snippets")
        app.row(Demo.ATLAS_TOKEN)
        rule.onNodeWithTag(AppHarness.rowTag(Demo.ATLAS_TOKEN) + TestTags.Row.EDIT, useUnmergedTree = true).performClick()
        app.waitFor(EditorTags.SCREEN)
        rule.onNodeWithTag(TestTags.SECURE_REVEAL).performClick()
        app.waitFor(TestTags.SECURE_BODY)
        rule.onNodeWithTag(EditorTags.TAB_DETAILS).performClick()
        rule.onNodeWithTag(EditorTags.TAB_CONTENT).performClick()

        tester.emulateSavedInstanceStateRestore()

        // The editor is back, its body locked: a revealed secret is never saved.
        app.waitFor(EditorTags.SCREEN)
        rule.onNodeWithTag(TestTags.TOPBAR_TITLE).assertTextEquals("Atlas API token")
        rule.onAllNodesWithTag(TestTags.SECURE_BODY, useUnmergedTree = true).assertCountEquals(0)
        rule.onNodeWithTag(TestTags.TOPBAR_BACK).performClick()
        app.waitFor(LibraryTags.LIST)
        rule.onNodeWithTag(TestTags.LIBRARY_SEARCH).assertTextEquals("token")
        app.waitForCount("1 of 9 snippets")
    }

    @Test
    fun rowsAreOneTalkBackNodeWithStateAndCustomActions() {
        app.start()
        val row = app.row(Demo.ATLAS_TOKEN).fetchSemanticsNode()
        assertEquals(listOf("Atlas API token"), row.config.getOrNull(SemanticsProperties.ContentDescription))
        assertEquals("Secure, Enabled, Keyword \\atlas-token, Tags: work, tokens", row.config.getOrNull(SemanticsProperties.StateDescription))
        assertEquals("authenticate and copy", row.config.getOrNull(SemanticsActions.OnClick)?.label)
        val actions = row.config.getOrNull(SemanticsActions.CustomActions).orEmpty().map { it.label }
        assertEquals(listOf("Copy", "Edit", "Pin", "Delete"), actions)
        val ordinary = app.row(Demo.MEETING_ROOM).fetchSemanticsNode()
        assertEquals(listOf("Copy", "Edit", "Unpin", "Duplicate", "Delete"), ordinary.config.getOrNull(SemanticsActions.CustomActions).orEmpty().map { it.label })
        // The pane title of the library.
        assertTrue(rule.onAllNodes(SemanticsMatcher.expectValue(SemanticsProperties.PaneTitle, "Snippets")).fetchSemanticsNodes().isNotEmpty())
    }

    @Test
    fun libraryAndEditorFitAtFontScaleTwo() {
        app.fontScale = 2f
        app.start()
        assertNoTextCut()
        app.row(Demo.MEETING_NOTES)
        rule.onNodeWithTag(AppHarness.rowTag(Demo.MEETING_NOTES) + TestTags.Row.EDIT, useUnmergedTree = true).performClick()
        app.waitFor(EditorTags.SCREEN)
        assertNoTextCut()
        rule.onNodeWithTag(EditorTags.TAB_DETAILS).performClick()
        app.waitFor(EditorTags.SECURE)
        assertNoTextCut()
    }

    /**
     * Single-line texts may end in an ellipsis where the spec allows it (names, previews,
     * keyword tokens, the top bar title); everything else must be fully shown at the large font scale.
     */
    private fun assertNoTextCut() {
        rule.waitForIdle()
        val allowedToEllipsise = setOf(".name", ".preview", ".keyword", TestTags.TOPBAR_TITLE)
        val cut = allNodes().filter { node ->
            val tag = node.config.getOrNull(SemanticsProperties.TestTag).orEmpty()
            if (allowedToEllipsise.any { tag.endsWith(it) }) return@filter false
            val layouts = ArrayList<androidx.compose.ui.text.TextLayoutResult>()
            node.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(layouts)
            layouts.any { layout -> (0 until layout.lineCount).any(layout::isLineEllipsized) || layout.multiParagraph.didExceedMaxLines }
        }
        assertTrue("cut texts: ${cut.map { it.config.getOrNull(SemanticsProperties.Text) }}", cut.isEmpty())
    }

    private fun allNodes(): List<SemanticsNode> {
        val out = ArrayList<SemanticsNode>()
        fun visit(node: SemanticsNode) {
            out += node
            node.children.forEach(::visit)
        }
        visit(rule.onRoot(useUnmergedTree = true).fetchSemanticsNode())
        return out
    }
}
