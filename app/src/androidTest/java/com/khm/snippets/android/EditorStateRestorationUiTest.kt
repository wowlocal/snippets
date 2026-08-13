package com.khm.snippets.android

import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTextReplacement
import org.junit.Rule
import org.junit.Test

class EditorStateRestorationUiTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun unsavedEditorDraftSurvivesActivityStateRestoration() {
        val restoration = StateRestorationTester(compose)
        val snippet = SnippetItem(
            id = "draft-id",
            name = "Original name",
            keyword = "draft",
            content = "Original content",
            tags = listOf("work"),
            isEnabled = true,
            isPinned = false,
        )
        restoration.setContent {
            SnippetsTheme(dynamicColor = false) {
                EditorScreen(snippet, onSave = {}, onDelete = {})
            }
        }

        compose.onNodeWithText("Original name").performTextReplacement("Restored draft")
        restoration.emulateSavedInstanceStateRestore()

        compose.onNodeWithText("Restored draft").assertExists()
    }
}
