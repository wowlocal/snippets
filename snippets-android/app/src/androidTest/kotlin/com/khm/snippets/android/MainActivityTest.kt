package com.khm.snippets.android

import android.content.Intent
import android.view.KeyEvent
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.khm.snippets.android.app.AppContainer
import com.khm.snippets.android.app.LaunchOptionsReader
import com.khm.snippets.android.feature.editor.EditorTags
import com.khm.snippets.android.ui.components.TestTags
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The real activity: demo launch extra, keyboard shortcuts through `onKeyDown`, recreation. */
@RunWith(AndroidJUnit4::class)
class MainActivityTest {
    @get:Rule
    val rule = createEmptyComposeRule()

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val application = instrumentation.targetContext.applicationContext as SnippetsApplication

    private fun launch(demo: Boolean): ActivityScenario<MainActivity> {
        instrumentation.runOnMainSync { application.replaceContainer(AppContainer(application)) }
        val intent = Intent(application, MainActivity::class.java)
        if (demo) intent.putExtra(LaunchOptionsReader.EXTRA_DEMO_SEED, "standard")
        return ActivityScenario.launch(intent)
    }

    @Test
    fun theDemoExtraSeedsTheLibrary() {
        launch(demo = true).use {
            rule.waitUntil(5_000) { rule.onAllNodes(hasTestTag(TestTags.LIBRARY_COUNT)).fetchSemanticsNodes().isNotEmpty() || rule.onAllNodes(hasTestTag("library.list")).fetchSemanticsNodes().isNotEmpty() }
            rule.onNodeWithTag(TestTags.LIBRARY_SEARCH).assertIsDisplayed()
            rule.onNodeWithTag(TestTags.tagChip("links")).assertIsDisplayed()
        }
    }

    @Test
    fun withoutExtrasTheLibraryStartsEmpty() {
        launch(demo = false).use {
            rule.waitUntil(5_000) { rule.onAllNodes(hasTestTag("library.empty.title")).fetchSemanticsNodes().isNotEmpty() }
        }
    }

    @Test
    fun ctrlNFromTheHardwareKeyboardCreatesASnippet() {
        launch(demo = true).use {
            rule.waitUntil(5_000) { rule.onAllNodes(hasTestTag("library.list")).fetchSemanticsNodes().isNotEmpty() }
            val down = KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_N, 0, KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON)
            val up = KeyEvent(0, 0, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_N, 0, KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON)
            instrumentation.sendKeySync(down)
            instrumentation.sendKeySync(up)
            rule.waitUntil(5_000) { rule.onAllNodes(hasTestTag(EditorTags.BODY)).fetchSemanticsNodes().isNotEmpty() }
        }
    }

    @Test
    fun recreationKeepsTheOpenEditor() {
        launch(demo = true).use { scenario ->
            rule.waitUntil(5_000) { rule.onAllNodes(hasTestTag("library.list")).fetchSemanticsNodes().isNotEmpty() }
            val down = KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_N, 0, KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON)
            instrumentation.sendKeySync(down)
            rule.waitUntil(5_000) { rule.onAllNodes(hasTestTag(EditorTags.BODY)).fetchSemanticsNodes().isNotEmpty() }
            scenario.recreate()
            rule.waitUntil(5_000) { rule.onAllNodes(hasTestTag(EditorTags.BODY)).fetchSemanticsNodes().isNotEmpty() }
        }
    }
}
