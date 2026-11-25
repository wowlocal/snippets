package com.khm.snippets.android.ui.components

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import android.view.KeyEvent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.khm.snippets.android.ui.model.ReviewUi
import com.khm.snippets.android.ui.model.SecretScreenUi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DialogsTest {
    @get:Rule
    val rule = createComposeRule()

    private val events = ArrayList<String>()

    private fun pressBack() {
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
    }

    private fun setConfirm(
        confirmLabel: String? = "Delete",
        neutralLabel: String? = null,
        paragraphs: List<String> = listOf("This permanently removes the encrypted snippet from this device."),
    ) {
        rule.setThemedContent {
            ConfirmDialog(
                tag = "dialog.delete-secure",
                title = "Delete “Atlas API token”?",
                paragraphs = paragraphs,
                dismissLabel = "Cancel",
                onDismiss = { events += "dismiss" },
                confirmLabel = confirmLabel,
                onConfirm = { events += "confirm" },
                neutralLabel = neutralLabel,
                onNeutral = { events += "neutral" },
                destructive = true,
            )
        }
    }

    @Test
    fun templatePartsCarryTheSharedTags() {
        setConfirm()
        rule.onNodeWithTag("dialog.delete-secure").assertIsDisplayed()
        rule.onNodeWithTag("dialog.title").assertTextEquals("Delete “Atlas API token”?")
        rule.onNodeWithTag("dialog.message").assertTextEquals("This permanently removes the encrypted snippet from this device.")
        rule.onNodeWithTag("dialog.confirm").assertTextEquals("Delete")
        rule.onNodeWithTag("dialog.dismiss").assertTextEquals("Cancel")
        rule.onNodeWithTag("dialog.neutral").assertDoesNotExist()
        val title = rule.onNodeWithTag("dialog.title").fetchSemanticsNode().config
        assertTrue(title.contains(SemanticsProperties.Heading))
    }

    @Test
    fun confirmAndDismissReportSeparately() {
        setConfirm()
        rule.onNodeWithTag("dialog.confirm").performClick()
        rule.onNodeWithTag("dialog.dismiss").performClick()
        assertEquals(listOf("confirm", "dismiss"), events)
    }

    @Test
    fun backEqualsTheDismissButton() {
        setConfirm()
        pressBack()
        rule.waitForIdle()
        assertEquals(listOf("dismiss"), events)
    }

    @Test
    fun dismissIsBeforeConfirmOnOneRow() {
        setConfirm()
        val confirm = rule.onNodeWithTag("dialog.confirm").fetchSemanticsNode().boundsInRoot
        val dismiss = rule.onNodeWithTag("dialog.dismiss").fetchSemanticsNode().boundsInRoot
        assertTrue("dismiss comes first", dismiss.right <= confirm.left)
        assertEquals(dismiss.center.y, confirm.center.y, 1f)
    }

    @Test
    fun threeButtonsAreStackedWithConfirmOnTop() {
        setConfirm(confirmLabel = "Create Encrypted Library", neutralLabel = "Plain Text Instead…")
        val confirm = rule.onNodeWithTag("dialog.confirm").fetchSemanticsNode().boundsInRoot
        val neutral = rule.onNodeWithTag("dialog.neutral").fetchSemanticsNode().boundsInRoot
        val dismiss = rule.onNodeWithTag("dialog.dismiss").fetchSemanticsNode().boundsInRoot
        assertTrue(confirm.bottom <= neutral.top)
        assertTrue(neutral.bottom <= dismiss.top)
        assertEquals(confirm.right, dismiss.right, 1f)
        rule.onNodeWithTag("dialog.neutral").performClick()
        assertEquals(listOf("neutral"), events)
    }

    @Test
    fun longLabelsStackInsteadOfTruncating() {
        rule.setThemedContent {
            ConfirmDialog(
                tag = "dialog.git-hostkey-changed",
                title = "The Host Key Changed",
                paragraphs = listOf("Nothing was sent."),
                dismissLabel = "Keep the Trusted Host Key for Now",
                onDismiss = {},
                confirmLabel = "Trust the New Host Key and Continue",
                onConfirm = {},
            )
        }
        val confirm = rule.onNodeWithTag("dialog.confirm").fetchSemanticsNode()
        val dismiss = rule.onNodeWithTag("dialog.dismiss").fetchSemanticsNode()
        assertTrue(confirm.boundsInRoot.bottom <= dismiss.boundsInRoot.top)
        val labels = (confirm.children + dismiss.children + confirm + dismiss).flatMap { it.textLayouts() }
        assertTrue(labels.isNotEmpty())
        labels.forEach { assertTrue(it.measurements(), it.isFullyShown()) }
    }

    @Test
    fun informationalDialogHasOnlyTheDismissButton() {
        setConfirm(confirmLabel = null, paragraphs = listOf("Turn off sync first."))
        rule.onNodeWithTag("dialog.confirm").assertDoesNotExist()
        rule.onNodeWithTag("dialog.dismiss").assertTextEquals("Cancel").performClick()
        assertEquals(listOf("dismiss"), events)
    }

    @Test
    fun paragraphsAreAllInTheMessage() {
        setConfirm(paragraphs = listOf("First paragraph.", "Second paragraph."))
        rule.onNodeWithTag("dialog.message").assertTextEquals("First paragraph.", "Second paragraph.")
    }

    @Test
    fun errorDialogHasOkAndAnOptionalRecovery() {
        rule.setThemedContent {
            ErrorDialog(
                title = "Couldn’t Set Up Secure Snippets",
                message = "Secure snippets are not set up for your Git library on this device yet.",
                onDismiss = { events += "ok" },
                recoveryLabel = "Open Git Repository",
                onRecovery = { events += "recovery" },
            )
        }
        rule.onNodeWithTag("dialog.error").assertIsDisplayed()
        rule.onNodeWithTag("dialog.dismiss").assertTextEquals("OK").performClick()
        rule.onNodeWithTag("dialog.confirm").assertTextEquals("Open Git Repository").performClick()
        assertEquals(listOf("ok", "recovery"), events)
    }

    @Test
    fun secretLeaveDialogUsesTheScreensButtonTitle() {
        rule.setThemedContent {
            SecretLeaveDialog(
                message = "Snippets can’t show this recovery code again.",
                leaveLabel = "Done, I’ve Saved It",
                onGoBack = { events += "back" },
                onLeave = { events += "leave" },
            )
        }
        rule.onNodeWithTag("dialog.secret-leave").assertIsDisplayed()
        rule.onNodeWithTag("dialog.title").assertTextEquals("Have You Saved It?")
        rule.onNodeWithTag("dialog.dismiss").assertTextEquals("Go Back").performClick()
        rule.onNodeWithTag("dialog.confirm").assertTextEquals("Done, I’ve Saved It").performClick()
        assertEquals(listOf("back", "leave"), events)
    }

    @Test
    fun progressDialogIgnoresBack() {
        var shown by mutableStateOf(true)
        rule.setThemedContent {
            if (shown) {
                ProgressDialog(tag = "dialog.switch-progress", title = "Switching Sync") {
                    SnippetsButton("Finish", onClick = { shown = false })
                }
            }
        }
        rule.onNodeWithTag("dialog.switch-progress").assertIsDisplayed()
        pressBack()
        rule.waitForIdle()
        rule.onNodeWithTag("dialog.switch-progress").assertIsDisplayed()
        rule.onNodeWithTag("dialog.confirm").assertDoesNotExist()
        rule.onNodeWithTag("dialog.dismiss").assertDoesNotExist()
        rule.onNodeWithText("Finish").performClick()
        rule.onNodeWithTag("dialog.switch-progress").assertDoesNotExist()
    }

    // Full-screen templates

    private fun secret(copied: Boolean = false, hidden: Boolean = false, canClose: Boolean = true) = SecretScreenUi(
        routeTag = "secure.recovery-key",
        title = "Recovery Key",
        heading = "Save Your Recovery Key",
        body = "Store this somewhere safe.",
        code = "7K2M9QXD4FTRHV3NP8WC6YJAB5G",
        doneTitle = "I’ve Saved It",
        copiedMessage = if (copied) "Copied. It clears from the clipboard in 5 minutes." else null,
        canClose = canClose,
        isHidden = hidden,
    )

    @Test
    fun secretScreenShowsTheCodeOnceAndCopyDoesNotAdvance() {
        var ui by mutableStateOf(secret())
        rule.setThemedContent {
            SecretScreen(
                ui = ui,
                onCopy = {
                    events += "copy"
                    ui = secret(copied = true)
                },
                onDone = { events += "done" },
                onClose = { events += "close" },
                compact = true,
            )
        }
        rule.onNodeWithTag("secret.screen").assertExists()
        rule.onNodeWithTag("topbar.title").assertTextEquals("Recovery Key")
        rule.onNodeWithTag("secret.heading").assertTextEquals("Save Your Recovery Key")
        val code = rule.onNodeWithTag("secret.code").fetchSemanticsNode().config
        assertEquals("7K2M-9QXD-4FTR-HV3N-P8WC-6YJA-B5G", code[SemanticsProperties.Text].single().text)
        assertEquals(
            "7 K 2 M, 9 Q X D, 4 F T R, H V 3 N, P 8 W C, 6 Y J A, B 5 G",
            code[SemanticsProperties.ContentDescription].single(),
        )
        rule.onNodeWithTag("secret.copied").assertDoesNotExist()
        rule.onNodeWithTag("secret.copy").assertTextEquals("Copy").performClick()
        rule.onNodeWithTag("secret.copied").assertTextEquals("Copied. It clears from the clipboard in 5 minutes.")
        assertEquals(listOf("copy"), events)
        rule.onNodeWithTag("secret.done").assertTextEquals("I’ve Saved It").performClick()
        rule.onNodeWithTag("secret.close").performClick()
        assertEquals(listOf("copy", "done", "close"), events)
    }

    @Test
    fun secretScreenHidesEverythingWhileTheAppIsAway() {
        rule.setThemedContent {
            SecretScreen(ui = secret(hidden = true), onCopy = {}, onDone = {}, onClose = {}, compact = true)
        }
        rule.onNodeWithTag("secret.hidden").assertExists()
        rule.onNodeWithText("Hidden while Snippets is in the background.").assertExists()
        rule.onNodeWithTag("secret.code").assertDoesNotExist()
        rule.onNodeWithTag("secret.copy").assertDoesNotExist()
        rule.onNodeWithTag("secret.done").assertDoesNotExist()
        rule.onNodeWithTag("topbar.title").assertExists()
    }

    @Test
    fun secretScreenWithoutCancelHasNoCloseButton() {
        rule.setThemedContent {
            SecretScreen(ui = secret(canClose = false), onCopy = {}, onDone = {}, onClose = {}, compact = false)
        }
        rule.onNodeWithTag("secret.close").assertDoesNotExist()
        rule.onNodeWithTag("secret.done").assertExists()
    }

    private fun review(running: Boolean = false, confirmTitle: String? = "Apply Deletions") = ReviewUi(
        title = "Sync Stopped",
        heading = "Apply These Deletions?",
        happened = "Stopped because an unusually large deletion arrived.",
        explanation = "These deletions did not include proof of intent.",
        onDevice = "128 snippets. Nothing has been changed on this device yet.",
        code = "mass_deletion",
        confirmTitle = confirmTitle,
        isDestructive = true,
        isRunning = running,
    )

    @Test
    fun reviewScreenConfirmsDismissesAndRevealsTheCode() {
        rule.setThemedContent {
            ReviewScreen(
                ui = review(),
                onConfirm = { events += "confirm" },
                onDismiss = { events += "dismiss" },
                onCopyCode = { events += "copy" },
                compact = true,
            )
        }
        rule.onNodeWithTag("review.screen").assertExists()
        rule.onNodeWithTag("review.heading").assertTextEquals("Apply These Deletions?")
        rule.onNodeWithTag("review.happened").assertExists()
        rule.onNodeWithTag("review.explanation").assertExists()
        rule.onNodeWithTag("review.device").assertExists()
        rule.onNodeWithTag("review.code").assertDoesNotExist()
        rule.onNodeWithTag("review.details").performClick()
        rule.onNodeWithTag("review.code").assertTextEquals("Code: mass_deletion")
        rule.onNodeWithTag("review.code-copy").performClick()
        rule.onNodeWithTag("review.confirm").assertTextEquals("Apply Deletions").performClick()
        rule.onNodeWithTag("review.dismiss").assertTextEquals("Not Now").performClick()
        rule.onNodeWithTag("topbar.close").performClick()
        assertEquals(listOf("copy", "confirm", "dismiss", "dismiss"), events)
    }

    @Test
    fun reviewScreenDisablesItsButtonsWhileRunning() {
        rule.setThemedContent {
            ReviewScreen(ui = review(running = true), onConfirm = {}, onDismiss = {}, onCopyCode = {}, compact = true)
        }
        rule.onNodeWithTag("review.confirm").assertIsNotEnabled()
        rule.onNodeWithTag("review.dismiss").assertIsNotEnabled()
        rule.onNodeWithTag("topbar.close").assertIsNotEnabled()
    }

    @Test
    fun reviewScreenWithoutAnActionOnlyCloses() {
        rule.setThemedContent {
            ReviewScreen(
                ui = review(confirmTitle = null),
                onConfirm = {},
                onDismiss = { events += "dismiss" },
                onCopyCode = {},
                compact = false,
            )
        }
        rule.onNodeWithTag("review.confirm").assertDoesNotExist()
        rule.onNodeWithTag("review.dismiss").assertIsEnabled().assertTextEquals("Close").performClick()
        assertEquals(listOf("dismiss"), events)
    }
}
