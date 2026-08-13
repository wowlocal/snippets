package com.khm.snippets.android

import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import org.junit.Rule
import org.junit.Test

class MainActivityRestorationUiTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun newSnippetRouteAndUnsavedDraftSurviveActivityRecreation() {
        compose.onNodeWithContentDescription("New snippet").performClick()
        compose.onNode(hasText("Name") and hasSetTextAction())
            .performTextReplacement("Restored activity draft")

        compose.activityRule.scenario.recreate()
        compose.waitForIdle()

        compose.onNodeWithText("New snippet").assertExists()
        compose.onNode(hasText("Restored activity draft") and hasSetTextAction())
            .assertExists()
    }
}
