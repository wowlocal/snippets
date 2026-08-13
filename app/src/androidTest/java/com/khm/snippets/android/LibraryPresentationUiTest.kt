package com.khm.snippets.android

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
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
            MaterialTheme {
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
    fun cardCopiesWhileEditAndShareRemainSeparateActions() {
        compose.onNodeWithText("Email follow up").performClick()
        assertEquals(1, copyCount)
        compose.onAllNodesWithText("Copy").assertCountEquals(0)

        compose.onNodeWithText("Edit").performClick()
        assertSame(snippet, edit)

        compose.onNodeWithText("Share").performClick()
        assertEquals(1, shareCount)
    }

    @Test
    fun tagsAreVisibleAndCanOpenOrNarrowTheFilter() {
        compose.onNodeWithText("Tags").performClick()
        assertEquals(true, showsTags)

        compose.onNodeWithText("work").performClick()
        assertEquals("work", toggledTag)
    }

    @Test
    fun tagsAndSecondaryActionsShareOneRow() {
        val tagBounds = compose.onNodeWithText("work").fetchSemanticsNode().boundsInRoot
        val editBounds = compose.onNodeWithText("Edit").fetchSemanticsNode().boundsInRoot

        assertEquals(true, tagBounds.top < editBounds.bottom && editBounds.top < tagBounds.bottom)
    }
}
