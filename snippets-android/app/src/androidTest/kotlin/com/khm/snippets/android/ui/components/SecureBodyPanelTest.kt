package com.khm.snippets.android.ui.components

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.model.LockReason
import com.khm.snippets.android.ui.model.ProtectedCause
import com.khm.snippets.android.ui.model.SecurePanelState
import com.khm.snippets.android.ui.model.UnavailableCause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SecureBodyPanelTest {
    @get:Rule
    val rule = createComposeRule()

    private val secret = "sk-live-9f3c2a7b41d8"
    private val events = ArrayList<String>()
    private var state by mutableStateOf<SecurePanelState>(SecurePanelState.Locked())

    private fun setPanel(initial: SecurePanelState) {
        state = initial
        rule.setThemedContent {
            SecureBodyPanel(
                state = state,
                onReveal = { events += "reveal" },
                onLock = { events += "lock" },
                onBodyChange = { events += "body" },
                onUnavailableAction = { events += "unavailable" },
            )
        }
    }

    private fun assertPanelState(name: String) {
        val config = rule.onNodeWithTag("editor.secure-panel", useUnmergedTree = true).fetchSemanticsNode().config
        assertEquals(name, config[SemanticsProperties.StateDescription])
    }

    private fun assertStandIn(stateDescription: String) {
        val node = rule.onNodeWithTag("editor.secure.standin", useUnmergedTree = true)
        node.assertContentDescriptionEquals("Protected secure snippet body")
        assertEquals(stateDescription, node.fetchSemanticsNode().config[SemanticsProperties.StateDescription])
    }

    @Test
    fun lockedOffersRevealAndDescribesItself() {
        setPanel(SecurePanelState.Locked())
        assertPanelState("locked")
        assertStandIn("Use Reveal Secure Content to show it visually. The text is unavailable to accessibility.")
        rule.onNodeWithTag("editor.secure.reveal").assertIsEnabled().assertTextEquals("Reveal Secure Content").performClick()
        assertEquals(listOf("reveal"), events)
        rule.onNodeWithTag("editor.secure.footer").assertTextEquals("Content is encrypted. Metadata remains searchable.")
        rule.onNodeWithTag("editor.secure.body", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag("editor.secure.reason").assertDoesNotExist()
    }

    @Test
    fun lockedShowsTheReasonOfAnAutomaticLock() {
        setPanel(SecurePanelState.Locked(LockReason.IdleTimeout))
        rule.onNodeWithTag("editor.secure.reason").assertTextEquals("Locked after 5 minutes without use.")
        state = SecurePanelState.Locked(LockReason.SessionExpired)
        rule.onNodeWithTag("editor.secure.reason").assertTextEquals("Locked after 30 minutes.")
        state = SecurePanelState.Locked(LockReason.LeftApp)
        rule.onNodeWithTag("editor.secure.reason").assertTextEquals("Locked when you left the app.")
    }

    @Test
    fun unlockingDisablesTheButton() {
        setPanel(SecurePanelState.Unlocking)
        assertPanelState("unlocking")
        assertStandIn("Authenticated secure content is being prepared. The text is unavailable to accessibility.")
        rule.onNodeWithTag("editor.secure.reveal").assertIsNotEnabled().assertTextEquals("Authenticating…")
    }

    @Test
    fun revealedBodyIsAbsentFromTheSemanticsTree() {
        setPanel(SecurePanelState.Revealed(secret))
        assertPanelState("revealed")
        assertStandIn("Content is shown visually. The text remains unavailable to accessibility.")

        // The field exists, but it exposes nothing: no text, no editing, no actions.
        val body = rule.onNodeWithTag("editor.secure.body", useUnmergedTree = true).fetchSemanticsNode().config
        assertNull(body.getOrNull(SemanticsProperties.EditableText))
        assertNull(body.getOrNull(SemanticsProperties.Text))
        assertNull(body.getOrNull(SemanticsProperties.InputText))
        assertNull(body.getOrNull(SemanticsActions.SetText))
        assertNull(body.getOrNull(SemanticsActions.GetTextLayoutResult))
        assertNull(body.getOrNull(SemanticsActions.CopyText))

        // And no node anywhere in either tree carries the plaintext.
        for (unmerged in listOf(false, true)) {
            rule.onNodeWithText(secret, substring = true, useUnmergedTree = unmerged).assertDoesNotExist()
            assertTrue(rule.onAllNodes(hasSetTextAction(), useUnmergedTree = unmerged).fetchSemanticsNodes().isEmpty())
            val leaks = rule.onAllNodes(SemanticsMatcher("mentions the secret") { node ->
                node.config.any { entry -> entry.value.toString().contains(secret) }
            }, useUnmergedTree = unmerged).fetchSemanticsNodes()
            assertTrue(leaks.isEmpty())
        }

        rule.onNodeWithTag("editor.secure.footer")
            .assertTextEquals("Secure content is revealed and editable until you leave this screen.")
        rule.onNodeWithTag("editor.secure.lock").assertTextEquals("Lock").performClick()
        assertEquals(listOf("lock"), events)
        rule.onNodeWithTag("editor.secure.reveal").assertDoesNotExist()
    }

    @Test
    fun plaintextLeavesCompositionWhenThePanelLocks() {
        setPanel(SecurePanelState.Revealed(secret))
        rule.onNodeWithTag("editor.secure.body", useUnmergedTree = true).assertExists()
        state = SecurePanelState.Locked(LockReason.LeftApp)
        rule.onNodeWithTag("editor.secure.body", useUnmergedTree = true).assertDoesNotExist()
        assertPanelState("locked")
    }

    @Test
    fun revealedStateNeverPrintsTheBody() {
        assertFalse(SecurePanelState.Revealed(secret).toString().contains(secret))
    }

    @Test
    fun protectedStatesShowTheirMessages() {
        setPanel(SecurePanelState.Protected(ProtectedCause.ScreenRecording))
        assertPanelState("protected")
        assertStandIn("Screen recording detected. Secure content stays hidden.")
        rule.onNodeWithTag("editor.secure.message").assertTextEquals("Screen recording detected. Secure content stays hidden.")
        rule.onNodeWithTag("editor.secure.reveal").assertDoesNotExist()

        state = SecurePanelState.Protected(ProtectedCause.UnprotectedDisplay)
        rule.onNodeWithTag("editor.secure.message").assertTextEquals("Protected display unavailable. Secure content stays hidden.")
        rule.onNodeWithTag("editor.secure.footer").assertTextEquals("Secure content was hidden because protected display failed.")
    }

    @Test
    fun unavailableStatesOfferTheirWayOut() {
        setPanel(SecurePanelState.Unavailable(UnavailableCause.NoScreenLock))
        assertPanelState("unavailable")
        rule.onNodeWithTag("editor.secure.message").assertTextEquals("Set a screen lock to use secure snippets.")
        rule.onNodeWithTag("editor.secure.unavailable-action").assertTextEquals("Open Settings").performClick()
        assertEquals(listOf("unavailable"), events)
        rule.onNodeWithTag("editor.secure.footer").assertDoesNotExist()
        rule.onNodeWithTag("editor.secure.standin", useUnmergedTree = true).assertDoesNotExist()

        state = SecurePanelState.Unavailable(UnavailableCause.GitVaultNotSetUp)
        rule.onNode(hasText("Open Git Repository")).assertExists()
        state = SecurePanelState.Unavailable(UnavailableCause.VaultKeyMissing)
        rule.onNode(hasText("Open Secure Snippets")).assertExists()
        rule.onNodeWithTag("editor.secure.message")
            .assertTextEquals("This device can’t open this secure snippet yet. Restore the vault key with your recovery key.")
    }
}
