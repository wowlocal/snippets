package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.CountdownUi
import com.khm.snippets.android.ui.model.LockReason
import com.khm.snippets.android.ui.model.ProblemUi
import com.khm.snippets.android.ui.model.SecurePanelState
import com.khm.snippets.android.ui.model.StepState
import com.khm.snippets.android.ui.model.StepUi
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.SyncReviewKind
import com.khm.snippets.android.ui.model.SyncReviewUi
import com.khm.snippets.android.ui.model.SyncStatusUi
import com.khm.snippets.android.ui.model.TagFilterUi
import com.khm.snippets.android.ui.model.UnavailableCause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * At font scale 2.0 no text is cut by its container: text containers have minimum heights, never
 * fixed ones. Every laid-out text must fit its own box vertically, and no text may be clipped
 * by an ancestor.
 */
@RunWith(AndroidJUnit4::class)
class FontScaleTest {
    @get:Rule
    val rule = createComposeRule()

    private val widthDp = 360

    private fun setScaled(fontScale: Float = 2f, content: @Composable () -> Unit) {
        rule.setThemedContent(fontScale = fontScale) {
            // Scrolling, so nothing is squeezed by the height of the screen.
            Column(modifier = Modifier.requiredWidth(widthDp.dp).verticalScroll(rememberScrollState())) { content() }
        }
        rule.waitForIdle()
    }

    private fun allNodes(): List<SemanticsNode> {
        val result = ArrayList<SemanticsNode>()
        fun visit(node: SemanticsNode) {
            result += node
            node.children.forEach(::visit)
        }
        rule.onAllNodes(isRoot(), useUnmergedTree = true).fetchSemanticsNodes().forEach(::visit)
        return result
    }

    /**
     * Asserts that every text fits the box it was given and that no text on screen is clipped
     * by a container; returns the text count.
     */
    private fun assertNoTextIsCut(expectedAtLeast: Int): Int {
        val viewport = rule.onAllNodes(isRoot(), useUnmergedTree = true).fetchSemanticsNodes().first().boundsInRoot
        var texts = 0
        for (node in allNodes()) {
            val layouts = node.textLayouts()
            if (layouts.isEmpty()) continue
            texts++
            val what = node.describe()
            layouts.forEach { layout ->
                // A fixed-height container would cut the bottom of the last line.
                val lastLineBottom = layout.getLineBottom(layout.lineCount - 1)
                assertTrue(
                    "“$what” needs $lastLineBottom px but its box is ${layout.size.height} px high",
                    lastLineBottom <= layout.size.height + 1f,
                )
            }
            val top = node.positionInRoot.y
            val onScreen = node.layoutInfo.isPlaced && top >= viewport.top && top + node.size.height <= viewport.bottom
            if (onScreen) {
                val clipped = node.boundsInRoot
                assertTrue(
                    "“$what” is clipped vertically: ${clipped.height} of ${node.size.height} px",
                    clipped.height >= node.size.height - 1f,
                )
            }
        }
        assertTrue("expected at least $expectedAtLeast texts, found $texts", texts >= expectedAtLeast)
        return texts
    }

    /** Asserts that a text that must never be shortened shows all of it. */
    private fun assertFullyShown(text: String) {
        val nodes = rule.onAllNodes(hasText(text), useUnmergedTree = true).fetchSemanticsNodes()
        val layouts = nodes.flatMap { it.textLayouts() }
        assertTrue("“$text” is not on screen", layouts.isNotEmpty())
        layouts.forEach { assertTrue("“$text” is shortened: ${it.measurements()}", it.isFullyShown()) }
    }

    @Test
    fun rowsGrowWithTheFont() {
        setScaled {
            SnippetRow(row = sampleRow(id = "a", isSecure = true, isPinned = true, isEnabled = false), onClick = {}, onAction = {})
            SnippetRow(row = sampleRow(id = "b"), onClick = {}, onAction = {}, copied = true, announceCopied = false)
        }
        assertNoTextIsCut(expectedAtLeast = 8)
        // The row is taller than its 96 dp minimum, and the preview may take two lines.
        val row = rule.onNodeWithTag("library.row.a").fetchSemanticsNode()
        assertTrue(row.size.height > with(rule.density) { 96.dp.roundToPx() })
        val preview = rule.onNodeWithTag("library.row.a.preview", useUnmergedTree = true).fetchSemanticsNode()
        assertEquals(2, preview.textLayouts().single().lineCount)
        assertFullyShown("9:04 PM")
    }

    @Test
    fun previewStaysOnOneLineBelowScaleOnePointThree() {
        setScaled(fontScale = 1f) {
            SnippetRow(row = sampleRow(id = "a", isSecure = true, isEnabled = false), onClick = {}, onAction = {})
        }
        val preview = rule.onNodeWithTag("library.row.a.preview", useUnmergedTree = true).fetchSemanticsNode()
        assertEquals(1, preview.textLayouts().single().lineCount)
        assertNoTextIsCut(expectedAtLeast = 4)
    }

    @Test
    fun libraryChromeGrowsWithTheFont() {
        setScaled {
            LibrarySearchBar(query = "", onQueryChange = {}, onMoreClick = {})
            TagFilterRow(tags = listOf(TagFilterUi(tag("work"), 12, true)), onToggleTag = {}, onOpenFilters = {})
            SecureCopyCountdown(
                state = CountdownUi.Running("Atlas API token", deadlineMillis = 42_000),
                onClearNow = {},
                nowMillis = { 0 },
                announce = false,
            )
            SyncStatusRow(SyncStatusUi(SyncGlyph.Synced, "Synced at 9:04 PM"), onClick = {})
            SyncReviewCard(
                review = SyncReviewUi(SyncReviewKind.Halted, SyncGlyph.Halted, "Stopped because the repository changed.", "Review Account Change"),
                onClick = {},
                onAction = {},
            )
            PinnedHeader()
            LibraryCountFooter(visibleCount = 3, totalCount = 42, filtered = true)
        }
        assertNoTextIsCut(expectedAtLeast = 9)
        // The time left is never shortened, whatever happens to the name.
        val tail = allNodes().first { node ->
            node.config.getOrNull(SemanticsProperties.Text)?.any { it.text.contains("Clears in 0:42") } == true &&
                node.textLayouts().isNotEmpty()
        }
        tail.textLayouts().forEach { assertTrue(it.measurements(), it.isFullyShown()) }
        assertFullyShown("Review Account Change")
        assertFullyShown("Clear Now")
    }

    @Test
    fun fieldsGrowWithTheFont() {
        setScaled {
            LabeledField(value = "Meeting notes", onValueChange = {}, caption = "Name", supportingText = "First line is used when blank")
            KeywordField(value = "notes", onValueChange = {}, caption = "Keyword", message = "\\notes is already used by Meeting room.", messageIsWarning = true)
            CodeField(value = "7K2M9QXD", onValueChange = {}, caption = "Recovery key", expectedLength = 27, onPasteClick = {})
            TagField(
                tags = listOf(tag("work"), tag("notes")),
                input = "",
                onInputChange = {},
                onCommitInput = {},
                onRemoveTag = {},
                onRemoveLastTag = {},
                caption = "Tags",
            )
            SwitchRow(
                title = "Secure",
                checked = false,
                onCheckedChange = {},
                supportingText = "Encrypt the body and require fingerprint, face or screen lock to reveal or copy it.",
            )
        }
        assertNoTextIsCut(expectedAtLeast = 12)
        assertFullyShown("Encrypt the body and require fingerprint, face or screen lock to reveal or copy it.")
        assertFullyShown("\\notes is already used by Meeting room.")
    }

    @Test
    fun securePanelGrowsWithTheFont() {
        setScaled {
            SecureBodyPanel(SecurePanelState.Locked(LockReason.IdleTimeout), onReveal = {}, onLock = {}, onBodyChange = {})
            SecureBodyPanel(SecurePanelState.Unavailable(UnavailableCause.GitVaultNotSetUp), onReveal = {}, onLock = {}, onBodyChange = {})
        }
        assertNoTextIsCut(expectedAtLeast = 5)
        assertFullyShown("Reveal Secure Content")
        assertFullyShown("This device can’t open this secure snippet yet. Set up secure snippets for your Git library first.")
    }

    @Test
    fun cardsStepsAndSettingsGrowWithTheFont() {
        setScaled {
            ProblemCard(
                problem = ProblemUi("git_http_401", "Access Token Refused", "The Git host didn’t accept the access token. It may have expired.", primaryAction = "Enter a New Token"),
                tagArea = "git",
                onCopyCode = {},
            )
            ProgressSteps(steps = listOf(StepUi("Checking the repository", StepState.Done), StepUi("Creating the library…", StepState.Running)))
            SettingsRow(key = "remove-vault", title = "Remove Secure Snippets from This Device", kind = SettingsRowKind.Destructive, icon = SnippetsIcon.Delete, detail = "This also removes the vault key stored on this device.")
        }
        assertNoTextIsCut(expectedAtLeast = 8)
        assertFullyShown("The Git host didn’t accept the access token. It may have expired.")
        assertFullyShown("Remove Secure Snippets from This Device")
        assertFullyShown("Creating the library…")
    }

    @Test
    fun buttonsWrapTheirLabels() {
        val long = "Move Your Secure Snippets to the Library’s New Key"
        setScaled {
            SnippetsButton(long, onClick = {})
            SnippetsButton(long, onClick = {}, level = ButtonLevel.Secondary, icon = SnippetsIcon.Key)
            SnippetsButton("Working…", onClick = {}, working = true)
        }
        assertNoTextIsCut(expectedAtLeast = 3)
        val labels = allNodes().filter { node -> node.config.getOrNull(SemanticsProperties.Text)?.any { it.text == long } == true }
        assertTrue(labels.isNotEmpty())
        labels.flatMap { it.textLayouts() }.forEach { layout ->
            assertTrue(layout.lineCount > 1)
            assertTrue(layout.isFullyShown())
        }
    }

    @Test
    fun emptyStateAndSecretBlockGrowWithTheFont() {
        setScaled {
            EmptyState(
                tagArea = "library",
                title = "Your Library Is Empty",
                message = "Create a snippet, import a library, or set up sync to fetch the library from your other devices.",
                icon = SnippetsIcon.Description,
                primaryAction = "New Snippet",
                textActions = listOf("Import…", "Set Up Sync"),
                note = "Sync is optional. Everything works on this device without an account.",
            )
            SecretBlock("7K2M9QXD4FTRHV3NP8WC6YJAB5G")
        }
        assertNoTextIsCut(expectedAtLeast = 6)
        assertFullyShown("Create a snippet, import a library, or set up sync to fetch the library from your other devices.")
        // monoCode stops growing at 1.3: a four-symbol group still fits on one line.
        assertTrue(rule.onAllNodes(hasTestTag("secret.code"), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())
    }
}
