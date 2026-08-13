package com.khm.snippets.android

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.semantics.SemanticsActions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Rule
import org.junit.Test

class LibraryPresentationUiTest {
    @get:Rule
    val compose = createComposeRule()

    private val snippet = SnippetItem(
        id = "test-id",
        name = "Email follow up",
        keyword = "followup",
        content = "Reply tomorrow",
        tags = listOf("email", "work"),
        isEnabled = true,
        isPinned = false,
    )

    private var copyCount = 0
    private var edit: SnippetItem? = null
    private var shareCount = 0
    private var showsTags = false
    private var toggledTag: String? = null

    @Before
    fun showLibrary() {
        compose.setContent {
            SnippetsTheme(dynamicColor = false) {
                LibraryScreen(
                    state = LibraryState(snippets = listOf(snippet)),
                    query = "",
                    onQuery = {},
                    activeTagKeys = emptySet(),
                    availableTags = tagUsage(listOf(snippet)),
                    onShowTagFilters = { showsTags = true },
                    onToggleTag = { toggledTag = it },
                    onClearTagFilters = {},
                    onEdit = { edit = it },
                    onSync = {},
                    copyAction = { copyCount += 1 },
                    shareAction = { shareCount += 1 },
                )
            }
        }
    }

    @Test
    fun rowCopiesWhileEditAndShareStayInTheOverflowMenu() {
        compose.onNodeWithText("Email follow up").performClick()
        assertEquals(1, copyCount)
        compose.onNodeWithText("Email follow up").assert(
            SemanticsMatcher("has Copy snippet accessibility action") { node ->
                node.config.contains(SemanticsActions.OnClick) &&
                    node.config[SemanticsActions.OnClick].label == "Copy snippet"
            })
        compose.onAllNodesWithText("Copy").assertCountEquals(0)
        compose.onAllNodesWithText("Edit").assertCountEquals(0)
        compose.onAllNodesWithText("Share").assertCountEquals(0)

        compose.onNodeWithContentDescription("More options for Email follow up").performClick()
        compose.onNodeWithText("Edit").performClick()
        assertSame(snippet, edit)

        compose.onNodeWithContentDescription("More options for Email follow up").performClick()
        compose.onNodeWithText("Share").performClick()
        assertEquals(1, shareCount)
        assertEquals(1, copyCount)
    }

    @Test
    fun tagsAreVisibleAndCanOpenOrNarrowTheFilter() {
        compose.onNodeWithContentDescription("Tag filters").performClick()
        assertEquals(true, showsTags)

        compose.onAllNodesWithText("work")[0].performClick()
        assertEquals("work", toggledTag)
    }

    @Test
    fun searchStatusAndFastTagFiltersAreAlwaysAvailable() {
        compose.onNodeWithContentDescription("Search snippets").assertExists()
        compose.onNodeWithText("Email follow up").assertHasClickAction()
        compose.onNodeWithText("On device").assertExists()
        compose.onAllNodesWithText("email").assertCountEquals(1)
        compose.onAllNodesWithText("work").assertCountEquals(1)
    }
}
