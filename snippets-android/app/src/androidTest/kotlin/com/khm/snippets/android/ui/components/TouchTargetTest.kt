package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.CountdownUi
import com.khm.snippets.android.ui.model.ProblemUi
import com.khm.snippets.android.ui.model.ReviewUi
import com.khm.snippets.android.ui.model.SecretScreenUi
import com.khm.snippets.android.ui.model.SecurePanelState
import com.khm.snippets.android.ui.model.SnippetRowLayout
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.SyncReviewKind
import com.khm.snippets.android.ui.model.SyncReviewUi
import com.khm.snippets.android.ui.model.SyncStatusUi
import com.khm.snippets.android.ui.model.TagFilterUi
import com.khm.snippets.android.ui.model.UnavailableCause
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Every interactive element is at least 48 × 48 dp (DESIGN.md §11), measured on the semantics
 * touch bounds, which include the area Compose adds around smaller visuals.
 */
@RunWith(AndroidJUnit4::class)
class TouchTargetTest {
    @get:Rule
    val rule = createComposeRule()

    /** Sets [content] and checks every node that can be activated; returns how many there were. */
    private fun assertAllTargets(
        expectedAtLeast: Int,
        scrolling: Boolean = true,
        content: @Composable () -> Unit,
    ): Int {
        rule.setThemedContent {
            Column(modifier = if (scrolling) Modifier.verticalScroll(rememberScrollState()) else Modifier) { content() }
        }
        return checkTargets(expectedAtLeast)
    }

    private fun checkTargets(expectedAtLeast: Int): Int {
        rule.waitForIdle()
        val nodes = (rule.onAllNodes(isActivatable).fetchSemanticsNodes() +
            rule.onAllNodes(isActivatable, useUnmergedTree = true).fetchSemanticsNodes()).distinctBy { it.id }
        assertTrue("expected at least $expectedAtLeast interactive nodes, found ${nodes.size}", nodes.size >= expectedAtLeast)
        nodes.forEach { rule.assertTouchTarget(it, it.describe()) }
        return nodes.size
    }

    @Test
    fun rowsInEveryLayout() {
        assertAllTargets(expectedAtLeast = 3) {
            SnippetListItem(row = sampleRow(id = "a"), onClick = {}, onAction = {})
            SnippetListItem(row = sampleRow(id = "b", tags = emptyList()), onClick = {}, onAction = {}, layout = SnippetRowLayout.TwoPane, selected = true)
            SnippetListItem(row = sampleRow(id = "c", tags = emptyList()), onClick = {}, onAction = {}, layout = SnippetRowLayout.Picker)
        }
        // Rows are at least 56 dp high, and the trailing buttons the row covers are full targets.
        val minimumRow = with(rule.density) { 56.dp.roundToPx() }
        val minimumButton = with(rule.density) { 48.dp.roundToPx() } - 1
        listOf("a", "b", "c").forEach { id ->
            assertTrue(rule.onNodeWithTag("library.row.$id").fetchSemanticsNode().size.height >= minimumRow)
        }
        listOf("library.row.a.edit", "library.row.b.copy").forEach { tag ->
            val size = rule.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().size
            assertTrue("$tag is $size", size.width >= minimumButton && size.height >= minimumButton)
        }
    }

    @Test
    fun rowMenuItems() {
        rule.setThemedContent {
            SnippetListItem(row = sampleRow(), onClick = {}, onAction = {})
        }
        rule.onNodeWithTag("library.row.row").fetchSemanticsNode().config.getOrNull(SemanticsActions.OnLongClick)!!.action!!.let { action ->
            rule.runOnUiThread { action() }
        }
        rule.onNodeWithTag("menu.item.delete").assertExists()
        checkTargets(expectedAtLeast = 6) // the row and five menu items
    }

    @Test
    fun libraryChrome() {
        assertAllTargets(expectedAtLeast = 12) {
            LibrarySearchBar(query = "atlas", onQueryChange = {}, onMoreClick = {})
            TagFilterRow(
                tags = listOf(TagFilterUi(tag("work"), 12, true), TagFilterUi(tag("a"), 1, false)),
                onToggleTag = {},
                onOpenFilters = {},
            )
            SecureCopyCountdown(
                state = CountdownUi.Running("Atlas", deadlineMillis = 60_000),
                onClearNow = {},
                nowMillis = { 0 },
                announce = false,
            )
            SyncStatusRow(SyncStatusUi(SyncGlyph.Synced, "Synced at 9:04 PM"), onClick = {})
            SyncReviewCard(
                review = SyncReviewUi(SyncReviewKind.Halted, SyncGlyph.Halted, "Sync stopped.", "Try Again"),
                onClick = {},
                onAction = {},
            )
            NewSnippetFab(onClick = {})
            NewSnippetFab(onClick = {}, expanded = false)
            NewSnippetFab(onClick = {}, small = true)
        }
        // The search field itself fills a touch target.
        val field = rule.onNodeWithTag("library.search").fetchSemanticsNode()
        assertTrue(field.size.height >= with(rule.density) { 48.dp.roundToPx() } - 1)
    }

    @Test
    fun tagSheetAndEmptyState() {
        assertAllTargets(expectedAtLeast = 6, scrolling = false) {
            TagFilterSheetContent(
                tags = listOf(TagFilterUi(tag("work"), 12, true), TagFilterUi(tag("a"), 1, false)),
                libraryTagCount = 2,
                activeFilterCount = 1,
                query = "",
                onQueryChange = {},
                onToggleTag = {},
                onClear = {},
            )
            EmptyState(
                tagArea = "library",
                title = "Your Library Is Empty",
                message = "Create a snippet.",
                icon = SnippetsIcon.Description,
                primaryAction = "New Snippet",
                textActions = listOf("Import…", "Set Up Sync"),
            )
        }
    }

    @Test
    fun fieldsAndTheirButtons() {
        assertAllTargets(expectedAtLeast = 7) {
            PasswordField(
                value = "x",
                onValueChange = {},
                caption = "Access Token",
                passwordVisible = false,
                onPasswordVisibleChange = {},
                tag = "token",
                onPasteClick = {},
            )
            CodeField(value = "7K2M", onValueChange = {}, caption = "Recovery key", expectedLength = 27, onPasteClick = {}, tag = "code")
            TagField(
                tags = listOf(tag("a"), tag("work")),
                input = "",
                onInputChange = {},
                onCommitInput = {},
                onRemoveTag = {},
                onRemoveLastTag = {},
                caption = "Tags",
            )
            SwitchRow(title = "Enabled", checked = true, onCheckedChange = {}, tag = "enabled")
            SettingsRow(key = "sync", title = "Sync", onClick = {})
            SettingsSwitchRow(key = "sync-library", title = "Sync This Library", checked = true, onCheckedChange = {})
        }
        // Text fields are at least 56 dp high.
        val minimumField = with(rule.density) { 56.dp.roundToPx() } - 1
        listOf("token", "code", "editor.tags").forEach { tag ->
            assertTrue(tag, rule.onNodeWithTag(tag).fetchSemanticsNode().size.height >= minimumField)
        }
    }

    @Test
    fun securePanelStates() {
        assertAllTargets(expectedAtLeast = 3) {
            SecureBodyPanel(SecurePanelState.Locked(), onReveal = {}, onLock = {}, onBodyChange = {})
            SecureBodyPanel(SecurePanelState.Revealed("secret"), onReveal = {}, onLock = {}, onBodyChange = {})
            SecureBodyPanel(SecurePanelState.Unavailable(UnavailableCause.NoScreenLock), onReveal = {}, onLock = {}, onBodyChange = {})
        }
    }

    @Test
    fun cardsAndTheirDisclosure() {
        assertAllTargets(expectedAtLeast = 4) {
            SecretCopyAction(label = "Copy", onCopy = {})
            ProblemCard(
                problem = ProblemUi("git_http_401", "Access Token Refused", "Refused.", primaryAction = "Enter a New Token", secondaryAction = "Open Token Page"),
                tagArea = "git",
                onCopyCode = {},
            )
        }
        rule.onNodeWithTag("git.error.git_http_401.details").performClick()
        checkTargets(expectedAtLeast = 5) // now with the code's copy button
    }

    @Test
    fun buttonsAndMenuItems() {
        assertAllTargets(expectedAtLeast = 8) {
            ButtonLevel.entries.forEach { level ->
                SnippetsButton("Go", onClick = {}, level = level)
            }
            SnippetsIconButton(SnippetsIcon.MoreVert, contentDescription = "More", onClick = {})
            SnippetsIconButton(SnippetsIcon.FilterList, contentDescription = "Filter by tags", onClick = {}, tonal = true)
            DropdownMenu(expanded = true, onDismissRequest = {}) {
                SnippetsMenuItem("Pin", SnippetsIcon.PushPin, "pin", onClick = {})
                SnippetsMenuItem("Delete", SnippetsIcon.Delete, "delete", onClick = {}, destructive = true)
            }
        }
    }

    @Test
    fun dialogButtons() {
        rule.setThemedContent {
            ConfirmDialog(
                tag = "dialog.git-mode",
                title = "Create an Encrypted Library?",
                paragraphs = listOf("Snippets encrypts every record."),
                dismissLabel = "Cancel",
                onDismiss = {},
                confirmLabel = "Create",
                onConfirm = {},
                neutralLabel = "Plain Text Instead…",
                onNeutral = {},
            )
        }
        checkTargets(expectedAtLeast = 3)
    }

    @Test
    fun secretTemplate() {
        rule.setThemedContent {
            SecretScreen(
                ui = SecretScreenUi(
                    routeTag = "git.code-show",
                    title = "Recovery Code",
                    heading = "Save Your Recovery Code",
                    body = "Store it somewhere safe.",
                    code = "7K2M9QXD4FTRHV3NP8WC6YJAB5G",
                    doneTitle = "Done, I’ve Saved It",
                    canClose = true,
                ),
                onCopy = {},
                onDone = {},
                onClose = {},
                compact = true,
            )
        }
        checkTargets(expectedAtLeast = 3)
    }

    @Test
    fun reviewTemplate() {
        rule.setThemedContent {
            ReviewScreen(
                ui = ReviewUi(
                    title = "Sync Stopped",
                    heading = "Apply These Deletions?",
                    happened = "A large deletion arrived.",
                    explanation = "It removes snippets.",
                    onDevice = "128 snippets.",
                    code = "mass_deletion",
                    confirmTitle = "Apply Deletions",
                ),
                onConfirm = {},
                onDismiss = {},
                onCopyCode = {},
                compact = true,
            )
        }
        checkTargets(expectedAtLeast = 4)
    }
}
