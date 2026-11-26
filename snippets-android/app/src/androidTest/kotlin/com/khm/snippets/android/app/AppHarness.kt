package com.khm.snippets.android.app

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.FontScale
import androidx.compose.ui.test.ForcedSize
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.then
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.khm.snippets.android.feature.library.LibraryTags
import com.khm.snippets.android.ui.components.TestTags

/**
 * Runs the whole app UI ([SnippetsApp]) on a fresh [AppContainer] per test. The window size and
 * font scale are forced through [DeviceConfigurationOverride], so phone, tablet and rotation
 * cases never resize the emulator. Tests reach the fakes through [container].
 */
internal class AppHarness(private val rule: ComposeContentTestRule) {
    val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    lateinit var container: AppContainer
        private set

    /** The window the app gets; [PHONE] by default. Change it to rotate or resize. */
    var size: DpSize by mutableStateOf(PHONE)
    var fontScale: Float by mutableFloatStateOf(1f)

    /** Builds the container on the main thread, lets [configure] seed the fakes, shows the app. */
    fun start(demo: Boolean = true, configure: AppContainer.() -> Unit = {}) {
        prepare(demo, configure)
        rule.setContent { App() }
        rule.waitForIdle()
    }

    /** [start] without setting the content, for a test that composes [App] itself. */
    fun prepare(demo: Boolean = true, configure: AppContainer.() -> Unit = {}) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            container = AppContainer(context)
            if (demo) container.fakes.seed(DemoLibrary.standard())
            container.configure()
        }
    }

    @Composable
    fun App() {
        DeviceConfigurationOverride(DeviceConfigurationOverride.ForcedSize(size) then DeviceConfigurationOverride.FontScale(fontScale)) {
            SnippetsApp(container)
        }
    }

    fun waitFor(tag: String, timeoutMillis: Long = TIMEOUT) {
        rule.waitUntil(timeoutMillis) { rule.onAllNodes(hasTestTag(tag), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
    }

    fun waitUntilGone(tag: String, timeoutMillis: Long = TIMEOUT) {
        rule.waitUntil(timeoutMillis) { rule.onAllNodes(hasTestTag(tag), useUnmergedTree = true).fetchSemanticsNodes().isEmpty() }
    }

    fun waitFor(matcher: SemanticsMatcher, timeoutMillis: Long = TIMEOUT) {
        rule.waitUntil(timeoutMillis) { rule.onAllNodes(matcher, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
    }

    /** Scrolls the library list to a row and returns it. */
    fun row(number: Int): SemanticsNodeInteraction {
        val tag = rowTag(number)
        // While a pane is entering, its list can be merged into the transition's node for a frame.
        rule.waitUntil(TIMEOUT) { rule.onAllNodes(hasTestTag(LibraryTags.LIST)).fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag(LibraryTags.LIST).performScrollToNode(hasTestTag(tag))
        return rule.onNodeWithTag(tag)
    }

    /** Waits until the count footer (at the end of the list, scrolled to) reads [text]. */
    fun waitForCount(text: String, timeoutMillis: Long = TIMEOUT) {
        rule.waitUntil(timeoutMillis) {
            try {
                rule.onNodeWithTag(LibraryTags.LIST).performScrollToNode(hasTestTag(TestTags.LIBRARY_COUNT))
                rule.onAllNodes(hasTestTag(TestTags.LIBRARY_COUNT) and hasText(text), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
            } catch (_: AssertionError) {
                false
            }
        }
    }

    /** Scrolls the tag chip row to a chip and returns it. */
    fun chip(folded: String): SemanticsNodeInteraction {
        val tag = TestTags.tagChip(folded)
        rule.onNodeWithTag(TestTags.LIBRARY_TAG_ROW).performScrollToNode(hasTestTag(tag))
        return rule.onNodeWithTag(tag)
    }

    fun clipboardText(): String? {
        var text: String? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val manager = context.getSystemService(ClipboardManager::class.java)
            text = manager.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
        }
        return text
    }

    fun clearClipboard() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            context.getSystemService(ClipboardManager::class.java).clearPrimaryClip()
        }
    }

    companion object {
        val PHONE = DpSize(411.dp, 891.dp)
        val PHONE_LANDSCAPE = DpSize(891.dp, 411.dp)
        val TABLET = DpSize(1280.dp, 800.dp)
        const val TIMEOUT = 5_000L

        /** `library.row.<id>` of demo entry [number] (see [DemoLibrary]). */
        fun rowTag(number: Int): String = TestTags.row(DemoLibrary.id(number).toString())
    }
}

/** Demo entries by number, as [DemoLibrary] defines them. */
internal object Demo {
    const val MEETING_ROOM = 1
    const val PROJECT_BRIEF = 2
    const val MEETING_NOTES = 3
    const val ATLAS_TOKEN = 4
    const val QUICK_REPLY = 5
    const val TRAVEL = 6
    const val TEAM_DASHBOARD = 9
}
