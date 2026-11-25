package com.khm.snippets.android.ui.components

import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.model.RowPreviewUi
import com.khm.snippets.android.ui.model.SnippetRowAction
import com.khm.snippets.android.ui.model.SnippetRowLayout
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.model.TextHighlight
import androidx.compose.foundation.layout.requiredWidth
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SnippetRowTest {
    @get:Rule
    val rule = createComposeRule()

    private val clicks = ArrayList<String>()
    private val actions = ArrayList<SnippetRowAction>()

    private fun setRow(
        layout: SnippetRowLayout = SnippetRowLayout.SinglePane,
        isSecure: Boolean = false,
        isPinned: Boolean = false,
        isEnabled: Boolean = true,
        copied: Boolean = false,
        selected: Boolean = false,
    ) {
        rule.setThemedContent {
            SnippetListItem(
                row = sampleRow(isSecure = isSecure, isPinned = isPinned, isEnabled = isEnabled),
                onClick = { clicks += "click" },
                onAction = { actions += it },
                layout = layout,
                copied = copied,
                selected = selected,
                announceCopied = false,
            )
        }
    }

    @Test
    fun tapReportsTheClickOnly() {
        setRow()
        rule.onNodeWithTag("library.row.row").performClick()
        assertEquals(listOf("click"), clicks)
        assertTrue(actions.isEmpty())
    }

    @Test
    fun trailingButtonEditsInSinglePane() {
        setRow()
        rule.onNodeWithTag("library.row.row.edit", useUnmergedTree = true).performClick()
        assertEquals(listOf(SnippetRowAction.Edit), actions)
        assertTrue(clicks.isEmpty())
        rule.onNodeWithTag("library.row.row.copy", useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun trailingButtonCopiesInTwoPane() {
        setRow(layout = SnippetRowLayout.TwoPane)
        rule.onNodeWithTag("library.row.row.copy", useUnmergedTree = true).performClick()
        assertEquals(listOf(SnippetRowAction.Copy), actions)
        rule.onNodeWithTag("library.row.row.edit", useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun pickerHasNoTrailingButton() {
        setRow(layout = SnippetRowLayout.Picker)
        rule.onNodeWithTag("library.row.row.edit", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag("library.row.row.copy", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag("library.row.row").performClick()
        assertEquals(listOf("click"), clicks)
    }

    @Test
    fun longPressOpensTheMenuAndAnItemReportsItsAction() {
        setRow()
        rule.onNodeWithTag("library.row.row").performTouchInput { longClick() }
        listOf("copy", "edit", "pin", "duplicate", "delete").forEach {
            rule.onNodeWithTag("menu.item.$it").assertIsDisplayed()
        }
        rule.onNodeWithTag("menu.item.enabled").assertDoesNotExist()
        rule.onNodeWithTag("menu.item.pin").performClick()
        assertEquals(listOf(SnippetRowAction.TogglePin), actions)
        assertTrue("a long-press must not copy", clicks.isEmpty())
        rule.onNodeWithTag("menu.item.pin").assertDoesNotExist()
    }

    @Test
    fun menuOfASecurePinnedRowInTwoPane() {
        setRow(layout = SnippetRowLayout.TwoPane, isSecure = true, isPinned = true)
        rule.onNodeWithTag("library.row.row").performTouchInput { longClick() }
        rule.onNodeWithText("Unpin").assertIsDisplayed()
        rule.onNodeWithText("Disable").assertIsDisplayed()
        rule.onNodeWithText("Make Ordinary").assertIsDisplayed()
        rule.onNodeWithTag("menu.item.edit").assertDoesNotExist()
        rule.onNodeWithTag("menu.item.duplicate").assertDoesNotExist()
        rule.onNodeWithTag("menu.item.copy-link").assertDoesNotExist()
        rule.onNodeWithTag("menu.item.delete").performClick()
        assertEquals(listOf(SnippetRowAction.Delete), actions)
    }

    @Test
    fun partsCarryTheirTestTags() {
        setRow(isSecure = true, isPinned = true, isEnabled = false)
        listOf("", ".name", ".preview", ".keyword", ".time", ".tags", ".edit", ".glyph.secure", ".glyph.pinned", ".glyph.disabled").forEach {
            rule.onNodeWithTag("library.row.row$it", useUnmergedTree = true).assertExists()
        }
        rule.onNodeWithTag("library.row.row.copied", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag("library.row.row.name", useUnmergedTree = true).assertTextEquals("Meeting notes")
        rule.onNodeWithTag("library.row.row.keyword", useUnmergedTree = true).assertTextEquals("\\notes")
        rule.onNodeWithTag("library.row.row.preview", useUnmergedTree = true).assertTextEquals("Disabled · Secure snippet")
    }

    @Test
    fun glyphsAreAbsentForAPlainRow() {
        setRow()
        listOf(".glyph.secure", ".glyph.pinned", ".glyph.disabled").forEach {
            rule.onNodeWithTag("library.row.row$it", useUnmergedTree = true).assertDoesNotExist()
        }
    }

    @Test
    fun copiedStateShowsItsTaggedLine() {
        setRow(copied = true)
        rule.onNodeWithTag("library.row.row.copied", useUnmergedTree = true).assertExists()
        rule.onNodeWithText("Copied", useUnmergedTree = true).assertExists()
    }

    @Test
    fun rowIsOneButtonNodeWithNameStateAndClickLabel() {
        setRow(isPinned = true)
        val node = rule.onNodeWithTag("library.row.row")
        node.assertHasClickAction()
        node.assertContentDescriptionEquals("Meeting notes")
        node.assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
        node.assert(
            SemanticsMatcher.expectValue(
                SemanticsProperties.StateDescription,
                "Standard, Pinned, Enabled, Keyword \\notes, Tags: work, notes",
            ),
        )
        val config = node.fetchSemanticsNode().config
        assertEquals("copy", config[SemanticsActions.OnClick].label)
    }

    @Test
    fun secureDisabledRowDescribesItselfAndAuthenticates() {
        setRow(isSecure = true, isEnabled = false)
        val config = rule.onNodeWithTag("library.row.row").fetchSemanticsNode().config
        assertEquals("Secure, Disabled, Keyword \\notes, Tags: work, notes", config[SemanticsProperties.StateDescription])
        assertEquals("authenticate and copy", config[SemanticsActions.OnClick].label)
    }

    @Test
    fun twoPaneRowOpens() {
        setRow(layout = SnippetRowLayout.TwoPane)
        val config = rule.onNodeWithTag("library.row.row").fetchSemanticsNode().config
        assertEquals("open", config[SemanticsActions.OnClick].label)
    }

    @Test
    fun customActionsAreInOrderAndReport() {
        setRow()
        val custom = rule.onNodeWithTag("library.row.row").fetchSemanticsNode().config[SemanticsActions.CustomActions]
        assertEquals(listOf("Copy", "Edit", "Pin", "Duplicate", "Delete"), custom.map { it.label })
        rule.runOnUiThread { custom.forEach { it.action() } }
        assertEquals(
            listOf(
                SnippetRowAction.Copy,
                SnippetRowAction.Edit,
                SnippetRowAction.TogglePin,
                SnippetRowAction.Duplicate,
                SnippetRowAction.Delete,
            ),
            actions,
        )
    }

    @Test
    fun securePinnedRowOffersUnpinAndNoDuplicate() {
        setRow(isSecure = true, isPinned = true)
        val custom = rule.onNodeWithTag("library.row.row").fetchSemanticsNode().config[SemanticsActions.CustomActions]
        assertEquals(listOf("Copy", "Edit", "Unpin", "Delete"), custom.map { it.label })
    }

    @Test
    fun trailingButtonAndPillsAreCoveredByTheRow() {
        setRow()
        // The trailing button exposes nothing of its own: no action, no description.
        val edit = rule.onNodeWithTag("library.row.row.edit", useUnmergedTree = true).fetchSemanticsNode().config
        assertNull(edit.getOrNull(SemanticsActions.OnClick))
        assertNull(edit.getOrNull(SemanticsProperties.ContentDescription))
        assertNull(edit.getOrNull(SemanticsProperties.Role))
        // In the tree accessibility services read, the row is a single node without children,
        // and neither the pills nor the button contribute to it.
        val row = rule.onNodeWithTag("library.row.row").fetchSemanticsNode()
        assertTrue("children: ${row.children.map { it.describe() }}", row.children.isEmpty())
        val texts = row.config[SemanticsProperties.Text].map { it.text }
        assertTrue("texts: $texts", texts.contains("Meeting notes"))
        assertFalse("texts: $texts", texts.contains("work"))
        assertFalse("texts: $texts", texts.contains("notes"))
        assertEquals(listOf("Meeting notes"), row.config[SemanticsProperties.ContentDescription])
    }

    @Test
    fun blankNameShowsUntitledSnippet() {
        rule.setThemedContent {
            SnippetRow(row = sampleRow(name = " "), onClick = {}, onAction = {})
        }
        rule.onNodeWithTag("library.row.row").assertContentDescriptionEquals("Untitled Snippet")
        rule.onNodeWithTag("library.row.row.name", useUnmergedTree = true).assertTextEquals("Untitled Snippet")
    }

    @Test
    fun rowIsAtLeastItsMinimumHeightAndTheTrailingButtonIsATouchTarget() {
        setRow()
        val row = rule.onNodeWithTag("library.row.row").fetchSemanticsNode()
        val edit = rule.onNodeWithTag("library.row.row.edit", useUnmergedTree = true).fetchSemanticsNode()
        with(rule.density) {
            assertTrue(row.size.height >= 96.dp.roundToPx() - 1)
            assertTrue(edit.size.width >= 48.dp.roundToPx() - 1)
            assertTrue(edit.size.height >= 48.dp.roundToPx() - 1)
        }
    }

    @Test
    fun rowWithoutTagsIsAtLeastSeventyTwoDp() {
        rule.setThemedContent {
            SnippetRow(row = sampleRow(tags = emptyList()), onClick = {}, onAction = {})
        }
        val row = rule.onNodeWithTag("library.row.row").fetchSemanticsNode()
        with(rule.density) { assertTrue(row.size.height >= 72.dp.roundToPx() - 1) }
        rule.onNodeWithTag("library.row.row.tags", useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun outOfRangeHighlightsRenderWithoutCrashing() {
        val wild = listOf(TextHighlight(-10, 2), TextHighlight(3, 3), TextHighlight(9, 4), TextHighlight(500, 900), TextHighlight(1, 10_000))
        rule.setThemedContent {
            androidx.compose.foundation.layout.Column {
                SnippetRow(
                    row = sampleRow().copy(
                        nameHighlights = wild,
                        keywordHighlights = wild,
                        preview = RowPreviewUi.Text("short", highlights = wild, isExcerpt = true),
                        tags = listOf(TagUi("work", "work", highlights = wild), TagUi("", "", highlights = wild)),
                        isEnabled = false,
                    ),
                    onClick = {},
                    onAction = {},
                )
                KeywordToken(keyword = "", highlights = wild)
                TagPill(TagUi("conflict", "conflict", highlights = wild))
            }
        }
        rule.onNodeWithTag("library.row.row.name", useUnmergedTree = true).assertTextEquals("Meeting notes")
        rule.onNodeWithTag("library.row.row.preview", useUnmergedTree = true).assertTextEquals("Disabled · …short")
        rule.onNodeWithTag("library.row.row.keyword", useUnmergedTree = true).assertTextEquals("\\notes")
    }

    @Test
    fun tagsThatDoNotFitCollapseIntoAnOverflowLabel() {
        rule.setThemedContent {
            SnippetRow(
                row = sampleRow(tags = listOf("alpha", "beta", "gamma", "delta", "epsilon").map(::tag)),
                onClick = {},
                onAction = {},
            )
        }
        // At most three pills are drawn; the other two are counted.
        rule.onNodeWithText("+2", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("alpha", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("gamma", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("delta", useUnmergedTree = true).assertDoesNotExist()
        // Every tag is still spoken with the row.
        val state = rule.onNodeWithTag("library.row.row").fetchSemanticsNode().config[SemanticsProperties.StateDescription]
        assertTrue(state.endsWith("Tags: alpha, beta, gamma, delta, epsilon"))
    }

    @Test
    fun aNarrowRowShowsFewerPillsAndCountsTheRest() {
        rule.setThemedContent {
            androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.requiredWidth(220.dp)) {
                SnippetRow(
                    row = sampleRow(tags = listOf("documentation", "infrastructure", "gamma").map(::tag)),
                    onClick = {},
                    onAction = {},
                )
            }
        }
        rule.onNodeWithText("documentation", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("+2", useUnmergedTree = true).assertIsDisplayed()
        // Measured to see whether it fits, but not placed.
        rule.onNodeWithText("infrastructure", useUnmergedTree = true).assertIsNotDisplayed()
        rule.onNodeWithText("gamma", useUnmergedTree = true).assertIsNotDisplayed()
    }
}
