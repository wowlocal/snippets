package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.ProblemSeverity
import com.khm.snippets.android.ui.model.ProblemUi
import com.khm.snippets.android.ui.model.SecretVariant
import com.khm.snippets.android.ui.model.StepState
import com.khm.snippets.android.ui.model.StepUi
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.SyncReviewKind
import com.khm.snippets.android.ui.model.SyncReviewUi
import com.khm.snippets.android.ui.model.SyncStatusUi
import com.khm.snippets.android.ui.model.TagFilterUi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ComponentsTest {
    @get:Rule
    val rule = createComposeRule()

    private val events = ArrayList<String>()

    // Search bar

    @Test
    fun searchBarEditsClearsAndOpensMore() {
        var query by mutableStateOf("")
        rule.setThemedContent {
            LibrarySearchBar(
                query = query,
                onQueryChange = { query = it },
                onMoreClick = { events += "more" },
                onSearch = { events += "search" },
            )
        }
        rule.onNodeWithTag("library.search.clear").assertDoesNotExist()
        rule.onNodeWithTag("library.search.back").assertDoesNotExist()
        rule.onNodeWithTag("library.search").assertTextEquals("Search snippets", "") // placeholder, empty query
        rule.onNodeWithTag("library.search").performTextInput("atlas")
        assertEquals("atlas", query)
        rule.onNodeWithTag("library.search").performImeAction()
        assertEquals("atlas", query) // Search keeps the query
        rule.onNodeWithTag("library.search.clear").assertContentDescriptionEquals("Clear text").performClick()
        assertEquals("", query)
        rule.onNodeWithTag("library.search").performTextInput("x")
        rule.onNodeWithTag("library.search.back").assertContentDescriptionEquals("Clear search").performClick()
        assertEquals("", query)
        rule.onNodeWithTag("library.more").assertContentDescriptionEquals("More").performClick()
        assertEquals(listOf("search", "more"), events)
    }

    // Tag filters

    private val filters = listOf(
        TagFilterUi(tag("work"), count = 12, selected = true),
        TagFilterUi(tag("links"), count = 1, selected = false),
    )

    @Test
    fun tagFilterRowTogglesAndDescribesItsChips() {
        rule.setThemedContent {
            TagFilterRow(tags = filters, onToggleTag = { events += it.folded }, onOpenFilters = { events += "open" })
        }
        val work = rule.onNodeWithTag("library.tag-chip.work")
        work.assertContentDescriptionEquals("Filter by tag work")
        val workConfig = work.fetchSemanticsNode().config
        assertEquals("on, 12 snippets", workConfig[SemanticsProperties.StateDescription])
        assertEquals(Role.Checkbox, workConfig[SemanticsProperties.Role])
        val links = rule.onNodeWithTag("library.tag-chip.links").fetchSemanticsNode().config
        assertEquals("off, 1 snippet", links[SemanticsProperties.StateDescription])
        rule.onNodeWithTag("library.tag-chip.links").performClick()

        val filter = rule.onNodeWithTag("library.filter", useUnmergedTree = true)
        filter.performClick()
        val filterConfig = rule.onNodeWithTag("library.filter").fetchSemanticsNode().config
        assertEquals("1 active filter", filterConfig[SemanticsProperties.StateDescription])
        assertEquals("show tag filters", filterConfig[SemanticsActions.OnClick].label)
        assertEquals(listOf("Filter by tags"), filterConfig[SemanticsProperties.ContentDescription])
        rule.onNodeWithTag("library.filter.badge", useUnmergedTree = true).assertExists()
        assertEquals(listOf("links", "open"), events)
    }

    @Test
    fun tagFilterRowWithoutActiveFiltersHasNoBadge() {
        rule.setThemedContent {
            TagFilterRow(tags = filters.map { it.copy(selected = false) }, onToggleTag = {}, onOpenFilters = {})
        }
        rule.onNodeWithTag("library.filter.badge", useUnmergedTree = true).assertDoesNotExist()
        val config = rule.onNodeWithTag("library.filter").fetchSemanticsNode().config
        assertEquals("No active filters", config[SemanticsProperties.StateDescription])
    }

    @Test
    fun tagSheetTogglesClearsAndDescribesRows() {
        rule.setThemedContent {
            TagFilterSheetContent(
                tags = filters,
                libraryTagCount = 2,
                activeFilterCount = 1,
                query = "",
                onQueryChange = {},
                onToggleTag = { events += it.folded },
                onClear = { events += "clear" },
            )
        }
        rule.onNodeWithTag("tags.sheet").assertExists()
        rule.onNodeWithTag("tags.title").assertTextEquals("Filter by Tags (1)")
        rule.onNodeWithTag("tags.search").assertDoesNotExist() // 12 tags or fewer
        rule.onNodeWithTag("tags.footer").assertTextEquals("A snippet must match every selected tag.")
        val work = rule.onNodeWithTag("tags.row.work").fetchSemanticsNode().config
        assertEquals(listOf("work"), work[SemanticsProperties.ContentDescription])
        assertEquals("12 snippets, selected", work[SemanticsProperties.StateDescription])
        assertEquals("remove this filter", work[SemanticsActions.OnClick].label)
        assertEquals(Role.Checkbox, work[SemanticsProperties.Role])
        val links = rule.onNodeWithTag("tags.row.links").fetchSemanticsNode().config
        assertEquals("1 snippet, not selected", links[SemanticsProperties.StateDescription])
        assertEquals("apply this filter", links[SemanticsActions.OnClick].label)
        rule.onNodeWithTag("tags.row.links").performClick()
        rule.onNodeWithTag("tags.clear").performClick()
        assertEquals(listOf("links", "clear"), events)
    }

    @Test
    fun tagSheetStatesForNoFiltersNoMatchAndNoTags() {
        var libraryTags by mutableStateOf(20)
        var query by mutableStateOf("zz")
        rule.setThemedContent {
            TagFilterSheetContent(
                tags = emptyList(),
                libraryTagCount = libraryTags,
                activeFilterCount = 0,
                query = query,
                onQueryChange = { query = it },
                onToggleTag = {},
                onClear = {},
            )
        }
        rule.onNodeWithTag("tags.title").assertTextEquals("Filter by Tags")
        rule.onNodeWithTag("tags.clear").assertIsNotEnabled()
        rule.onNodeWithTag("tags.search").assertExists() // more than 12 tags
        rule.onNodeWithText("No tags match “zz”.").assertExists()
        libraryTags = 0
        rule.onNodeWithTag("tags.empty").assertExists()
        rule.onNodeWithTag("tags.empty.title").assertTextEquals("No Tags Yet")
        rule.onNodeWithTag("tags.empty.message")
            .assertTextEquals("Add tags to a snippet, then return here to filter your library.")
    }

    // Sections, empty state

    @Test
    fun headersAreHeadingsAndFootersCount() {
        rule.setThemedContent {
            Column {
                PinnedHeader()
                LibraryCountFooter(visibleCount = 1, totalCount = 1, filtered = false)
            }
        }
        val header = rule.onNodeWithTag("library.header.pinned")
        header.assertTextEquals("Pinned")
        assertTrue(header.fetchSemanticsNode().config.contains(SemanticsProperties.Heading))
        rule.onNodeWithTag("library.count").assertTextEquals("1 snippet")
    }

    @Test
    fun countFooterPluralAndFilteredForms() {
        var filtered by mutableStateOf(false)
        rule.setThemedContent {
            LibraryCountFooter(visibleCount = 3, totalCount = 42, filtered = filtered)
        }
        rule.onNodeWithTag("library.count").assertTextEquals("42 snippets")
        filtered = true
        rule.onNodeWithTag("library.count").assertTextEquals("3 of 42 snippets")
    }

    @Test
    fun emptyStateTagsItsPartsAndActionsInOrder() {
        rule.setThemedContent {
            EmptyState(
                tagArea = "library",
                title = "Your Library Is Empty",
                message = "Create a snippet.",
                icon = SnippetsIcon.Description,
                primaryAction = "New Snippet",
                onPrimaryAction = { events += "primary" },
                textActions = listOf("Import…", "Set Up Sync"),
                onTextAction = { events += "text$it" },
                note = "Sync is optional.",
            )
        }
        rule.onNodeWithTag("library.empty").assertExists()
        val title = rule.onNodeWithTag("library.empty.title")
        title.assertTextEquals("Your Library Is Empty")
        assertTrue(title.fetchSemanticsNode().config.contains(SemanticsProperties.Heading))
        rule.onNodeWithTag("library.empty.message").assertTextEquals("Create a snippet.")
        rule.onNodeWithTag("library.empty.note").assertTextEquals("Sync is optional.")
        rule.onNodeWithTag("library.empty.action").assertTextEquals("New Snippet").performClick()
        rule.onNodeWithTag("library.empty.action-2").assertTextEquals("Import…").performClick()
        rule.onNodeWithTag("library.empty.action-3").assertTextEquals("Set Up Sync").performClick()
        assertEquals(listOf("primary", "text0", "text1"), events)
    }

    @Test
    fun emptyStateWithOnlyATextActionTagsItFirst() {
        rule.setThemedContent {
            EmptyState(tagArea = "library", title = "No Snippets Match", message = "Clear a tag filter.", textActions = listOf("Clear Filters"))
        }
        rule.onNodeWithTag("library.empty.action").assertTextEquals("Clear Filters")
        rule.onNodeWithTag("library.empty.action-2").assertDoesNotExist()
    }

    // Sync

    @Test
    fun syncRowIsOneButtonWithLabelValueAndClickLabel() {
        rule.setThemedContent {
            SyncStatusRow(status = SyncStatusUi(SyncGlyph.Synced, "Synced at 9:04 PM"), onClick = { events += "sheet" })
        }
        val row = rule.onNodeWithTag("library.sync-row")
        val config = row.fetchSemanticsNode().config
        assertEquals(listOf("Sync"), config[SemanticsProperties.ContentDescription])
        assertEquals("Synced at 9:04 PM", config[SemanticsProperties.StateDescription])
        assertEquals("show sync status", config[SemanticsActions.OnClick].label)
        rule.onNodeWithTag("library.sync-row.text", useUnmergedTree = true).assertTextEquals("Synced at 9:04 PM")
        row.performClick()
        assertEquals(listOf("sheet"), events)
    }

    @Test
    fun reviewCardSeparatesBodyAndButton() {
        rule.setThemedContent {
            SyncReviewCard(
                review = SyncReviewUi(
                    kind = SyncReviewKind.HaltedDataAtRisk,
                    glyph = SyncGlyph.HaltedDataAtRisk,
                    text = "Stopped because an unusually large deletion arrived.",
                    actionTitle = "Confirm Deletions",
                ),
                onClick = { events += "body" },
                onAction = { events += "action" },
            )
        }
        rule.onNodeWithTag("library.sync-card").assertExists()
        rule.onNodeWithTag("library.sync-card.title", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("library.sync-card.text", useUnmergedTree = true).assertExists()
        val body = rule.onNode(hasClickAction() and androidx.compose.ui.test.hasContentDescription("Sync")).fetchSemanticsNode().config
        assertEquals(
            "Stopped because an unusually large deletion arrived. Action: Confirm Deletions.",
            body[SemanticsProperties.StateDescription],
        )
        assertEquals("confirm deletions", body[SemanticsActions.OnClick].label)
        rule.onNode(hasClickAction() and androidx.compose.ui.test.hasContentDescription("Sync")).performClick()
        rule.onNodeWithTag("library.sync-card.action").assertTextEquals("Confirm Deletions").performClick()
        assertEquals(listOf("body", "action"), events)
    }

    @Test
    fun reviewCardTitlesAndButtonStates() {
        var review by mutableStateOf(
            SyncReviewUi(SyncReviewKind.NeedsAttention, SyncGlyph.NeedsAuthentication, "The access token was refused.", "Open Sync Settings"),
        )
        rule.setThemedContent { SyncReviewCard(review = review, onClick = {}, onAction = {}) }
        rule.onNodeWithTag("library.sync-card.title", useUnmergedTree = true).assertTextEquals("Sync Needs Attention")
        review = SyncReviewUi(SyncReviewKind.WaitingForVault, SyncGlyph.WaitingForVault, "Waiting for the vault.", "Check Again", isActionRunning = true)
        rule.onNodeWithTag("library.sync-card.title", useUnmergedTree = true).assertTextEquals("Sync Is Waiting")
        rule.onNodeWithTag("library.sync-card.action").assertIsNotEnabled()
        review = SyncReviewUi(SyncReviewKind.Halted, SyncGlyph.UpdateRequired, "Update Snippets to resume sync")
        rule.onNodeWithTag("library.sync-card.title", useUnmergedTree = true).assertTextEquals("Sync Stopped")
        rule.onNodeWithTag("library.sync-card.text", useUnmergedTree = true).assertTextEquals("Update Snippets to resume sync")
        rule.onNodeWithTag("library.sync-card.action").assertDoesNotExist()
    }

    @Test
    fun problemCardShowsItsPartsAndDisclosesTheCode() {
        rule.setThemedContent {
            ProblemCard(
                problem = ProblemUi(
                    code = "git_http_401",
                    title = "Access Token Refused",
                    message = "The Git host didn’t accept the access token.",
                    severity = ProblemSeverity.Error,
                    primaryAction = "Enter a New Token",
                    secondaryAction = "Open Token Page",
                ),
                tagArea = "git",
                onCopyCode = { events += "copy" },
                onPrimaryAction = { events += "primary" },
                onSecondaryAction = { events += "secondary" },
            )
        }
        val tag = "git.error.git_http_401"
        rule.onNodeWithTag(tag).assertExists()
        rule.onNodeWithTag("$tag.title").assertTextEquals("Access Token Refused")
        rule.onNodeWithTag("$tag.message").assertTextEquals("The Git host didn’t accept the access token.")
        rule.onNodeWithTag("$tag.action").performClick()
        rule.onNodeWithTag("$tag.action-2").performClick()
        rule.onNodeWithTag("$tag.code").assertDoesNotExist() // collapsed by default
        rule.onNodeWithTag("$tag.details").performClick()
        rule.onNodeWithTag("$tag.code").assertTextEquals("Code: git_http_401")
        rule.onNodeWithTag("$tag.code-copy").assertContentDescriptionEquals("Copy").performClick()
        rule.onNodeWithTag("$tag.details").performClick()
        rule.onNodeWithTag("$tag.code").assertDoesNotExist()
        assertEquals(listOf("primary", "secondary", "copy"), events)
    }

    // Secret block, progress steps, settings rows

    @Test
    fun secretBlockSpellsCodesAndDescribesKeys() {
        var variant by mutableStateOf(SecretVariant.Code)
        var value by mutableStateOf("7K2M9QXD4")
        rule.setThemedContent { SecretBlock(value = value, variant = variant) }
        var config = rule.onNodeWithTag("secret.code").fetchSemanticsNode().config
        assertEquals("7K2M-9QXD-4", config[SemanticsProperties.Text].single().text)
        assertEquals(listOf("7 K 2 M, 9 Q X D, 4"), config[SemanticsProperties.ContentDescription])

        variant = SecretVariant.Comparison
        value = "482 913"
        config = rule.onNodeWithTag("secret.code").fetchSemanticsNode().config
        assertEquals(listOf("4 8 2, 9 1 3"), config[SemanticsProperties.ContentDescription])

        variant = SecretVariant.PublicKey
        value = "ssh-ed25519 AAAAC3Nza snippets-device"
        config = rule.onNodeWithTag("secret.code").fetchSemanticsNode().config
        assertEquals(
            listOf("SSH public key, ending in device. Use Copy Public Key to add it."),
            config[SemanticsProperties.ContentDescription],
        )
        assertEquals(value, config[SemanticsProperties.Text].single().text)

        variant = SecretVariant.Fingerprint
        value = "SHA256:nThbg6kXUpJWGl7E"
        config = rule.onNodeWithTag("secret.code").fetchSemanticsNode().config
        assertEquals("SHA256:\nnThbg6kX UpJWGl7E", config[SemanticsProperties.Text].single().text)
        assertTrue(config[SemanticsProperties.ContentDescription].single().startsWith("Host key fingerprint n T h b g 6"))
    }

    @Test
    fun progressStepsExposeTheirStates() {
        rule.setThemedContent {
            ProgressSteps(
                steps = listOf(
                    StepUi("Checking the repository", StepState.Done),
                    StepUi("Creating the library…", StepState.Running),
                    StepUi("Opening the library", StepState.Pending),
                    StepUi("Connecting", StepState.Failed),
                ),
            )
        }
        val expected = listOf("done", "running", "pending", "failed")
        expected.forEachIndexed { index, state ->
            val config = rule.onNodeWithTag("progress.step.${index + 1}").fetchSemanticsNode().config
            assertEquals(state, config[SemanticsProperties.StateDescription])
        }
        rule.onNodeWithTag("progress.step.2").assertTextEquals("Creating the library…")
        assertTrue(rule.onNodeWithTag("progress.step.2").fetchSemanticsNode().config.contains(SemanticsProperties.LiveRegion))
        assertFalse(rule.onNodeWithTag("progress.step.1").fetchSemanticsNode().config.contains(SemanticsProperties.LiveRegion))
        rule.onNodeWithTag("progress.step.5").assertDoesNotExist()
    }

    @Test
    fun settingsRowsClickOnlyWhereTheyShould() {
        rule.setThemedContent {
            Column {
                SettingsRow(key = "sync", title = "Sync", detail = "On. Last synced at 9:04 PM.", onClick = { events += "sync" })
                SettingsRow(key = "status", title = "Status", kind = SettingsRowKind.Value, detail = "Locked.", onClick = { events += "status" })
                SettingsRow(key = "provider", title = "Sync Provider", kind = SettingsRowKind.Disabled, detail = "Turn off Sync This Library first.", onClick = { events += "provider" })
                SettingsRow(key = "lock-now", title = "Lock Now", kind = SettingsRowKind.Action, working = true, onClick = { events += "lock" })
                SettingsSwitchRow(key = "sync-library", title = "Sync This Library", checked = false, onCheckedChange = { events += "switch:$it" })
            }
        }
        rule.onNodeWithTag("settings.row.sync.title", useUnmergedTree = true).assertTextEquals("Sync")
        rule.onNodeWithTag("settings.row.sync.detail", useUnmergedTree = true).assertTextEquals("On. Last synced at 9:04 PM.")
        rule.onNodeWithTag("settings.row.provider.detail", useUnmergedTree = true).assertTextEquals("Turn off Sync This Library first.")
        listOf("sync", "status", "provider", "lock-now", "sync-library").forEach {
            rule.onNodeWithTag("settings.row.$it").performClick()
        }
        assertEquals(listOf("sync", "switch:true"), events)
        assertNull(rule.onNodeWithTag("settings.row.status").fetchSemanticsNode().config.getOrNull(SemanticsActions.OnClick))
        rule.onNodeWithTag("settings.row.sync-library.switch", useUnmergedTree = true).assertExists()
    }

    // Buttons, snackbar

    @Test
    fun workingButtonIsDisabledAndKeepsItsLabel() {
        rule.setThemedContent {
            Column {
                SnippetsButton("Working…", onClick = { events += "working" }, working = true)
                NewSnippetFab(onClick = { events += "fab" })
            }
        }
        rule.onNodeWithText("Working…").assertIsNotEnabled()
        rule.onNodeWithTag("library.fab").performClick()
        assertEquals(listOf("fab"), events)
        rule.onNodeWithText("New Snippet", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("library.fab").assertContentDescriptionEquals("New snippet")
    }

    @Test
    fun snackbarShowsReplacesAndRunsItsActionOnce() {
        val hostState = SnackbarHostState()
        lateinit var controller: SnackbarController
        rule.setThemedContent {
            controller = rememberSnackbarController(hostState)
            SnippetsSnackbarHost(hostState)
        }
        rule.runOnUiThread { controller.show("Secure snippet deleted.") }
        rule.onNodeWithTag("snackbar", useUnmergedTree = true).assertTextEquals("Secure snippet deleted.")
        rule.onNodeWithTag("snackbar.action").assertDoesNotExist()

        // A new snackbar replaces the current one at once.
        rule.runOnUiThread { controller.show("Deleted “Quick reply”.", actionLabel = "Undo") { events += "undo" } }
        rule.onNodeWithTag("snackbar", useUnmergedTree = true).assertTextEquals("Deleted “Quick reply”.")
        val spoken = rule.onNodeWithTag("snackbar", useUnmergedTree = true).fetchSemanticsNode().config[SemanticsProperties.ContentDescription]
        assertEquals(listOf("Deleted “Quick reply”. Undo available."), spoken)
        rule.onNodeWithTag("snackbar.action").assertTextEquals("Undo").performClick()
        rule.waitForIdle()
        assertEquals(listOf("undo"), events)
        rule.onNodeWithTag("snackbar", useUnmergedTree = true).assertDoesNotExist()
    }
}
