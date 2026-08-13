package com.khm.snippets.android

import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTextReplacement
import org.junit.Rule
import org.junit.Test

class TagFilterSheetUiTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun searchKeepsLargeTagLibrariesUsable() {
        compose.setContent {
            SnippetsTheme(darkTheme = true, dynamicColor = false) {
                TagFilterSheet(
                    tags = (1..20).map { index ->
                        TagUsage(tag = "tag-$index", key = "tag-$index", count = index)
                    },
                    activeTagKeys = emptySet(),
                    onToggle = {},
                    onClear = {},
                    onDismiss = {},
                )
            }
        }

        compose.onNode(hasText("Search tags") and hasSetTextAction())
            .performTextReplacement("20")

        compose.onNodeWithText("tag-20").assertExists()
        compose.onNodeWithText("tag-1").assertDoesNotExist()
    }
}
