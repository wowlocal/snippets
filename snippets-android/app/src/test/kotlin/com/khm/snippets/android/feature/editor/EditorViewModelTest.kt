package com.khm.snippets.android.feature.editor

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.khm.snippets.android.R
import com.khm.snippets.android.data.LibraryError
import com.khm.snippets.android.data.NewSnippet
import com.khm.snippets.android.data.SnippetEdit
import com.khm.snippets.android.data.core.CoreKeywordAdvisor
import com.khm.snippets.android.data.fake.FakeBackends
import com.khm.snippets.android.data.fake.SeedEntry
import com.khm.snippets.android.data.valueOrNull
import com.khm.snippets.android.feature.shared.AppDialog
import com.khm.snippets.android.feature.shared.RecoveryKeyPresenter
import com.khm.snippets.android.feature.shared.SnackbarRequest
import com.khm.snippets.android.feature.shared.SnippetOperations
import com.khm.snippets.android.feature.shared.uiText
import com.khm.snippets.android.platform.AuthResult
import com.khm.snippets.android.platform.CaptureRisk
import com.khm.snippets.android.platform.ClipboardService
import com.khm.snippets.android.platform.PlatformInfo
import com.khm.snippets.android.testing.FakeClipboard
import com.khm.snippets.android.testing.FakeTimeFormatter
import com.khm.snippets.android.testing.MainDispatcherRule
import com.khm.snippets.android.testing.RecordingScheduler
import com.khm.snippets.android.testing.id
import com.khm.snippets.android.testing.monotonicClock
import com.khm.snippets.android.testing.resolver
import com.khm.snippets.android.testing.seed
import com.khm.snippets.android.testing.snippet
import com.khm.snippets.android.ui.components.SnippetsHaptic
import com.khm.snippets.android.ui.model.LockReason
import com.khm.snippets.android.ui.model.ProtectedCause
import com.khm.snippets.android.ui.model.SecurePanelState
import com.khm.snippets.android.ui.model.TextHighlight
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class EditorViewModelTest {
    @get:Rule val main = MainDispatcherRule()

    private class Harness(val scope: TestScope, sdk: Int) {
        val clock = scope.testScheduler.monotonicClock()
        val fakes = FakeBackends(scope.backgroundScope, clock)
        val clipboard = FakeClipboard()
        val service = ClipboardService(clipboard, clock, scope.backgroundScope, RecordingScheduler(), PlatformInfo(sdk))
        val presenter = RecoveryKeyPresenter()
        val operations = SnippetOperations(fakes.library, fakes.vault, resolver(), service, presenter, scope.backgroundScope)
        val capture = MutableStateFlow(CaptureRisk.None)
        val store = ViewModelStore()
        val effects = mutableListOf<EditorEffect>()

        fun editor(id: UUID): EditorViewModel {
            val factory = viewModelFactory {
                initializer {
                    EditorViewModel(
                        id = id,
                        library = fakes.library,
                        vault = fakes.vault,
                        resolver = resolver(),
                        advisor = CoreKeywordAdvisor(),
                        operations = operations,
                        clipboard = service,
                        time = FakeTimeFormatter(),
                        captureRisk = capture,
                        appScope = scope,
                        clipboardStandIn = "[Clipboard content]",
                        isPlainTextLibrary = { false },
                    )
                }
            }
            val viewModel = ViewModelProvider(store, factory)[EditorViewModel::class.java]
            scope.backgroundScope.launch(UnconfinedTestDispatcher(scope.testScheduler)) { viewModel.effects.collect { effects += it } }
            scope.runCurrent()
            return viewModel
        }

        fun stored(id: UUID) = fakes.library.snapshot.value.entry(id)?.snippet
        fun secureBody(id: UUID) = fakes.store.read { secure[id]?.body }
    }

    private fun TestScope.harness(vararg entries: SeedEntry, sdk: Int = 35): Harness =
        Harness(this, sdk).also { it.fakes.seed(entries.toList()) }

    private val ordinary = seed(snippet(1, name = "Mail", keyword = "mail", content = "hello", tags = listOf("work")))
    private val secure = seed(snippet(2, name = "Token", keyword = "tok"), secureBody = "s3cret")

    @Test
    fun loadsTheEntry() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        assertEquals("Mail", editor.name)
        assertEquals("hello", editor.body)
        assertEquals("mail", editor.keyword.text)
        val state = editor.uiState.value
        assertEquals(EditorStatus.Ready, state.status)
        assertEquals("Mail", state.title)
        assertEquals(listOf("work"), state.tags.map { it.name })
        assertEquals(uiText(R.string.editor_footer_saved, "d:1", "t:1"), state.savedAt)
    }

    @Test
    fun textIsSavedAfterExactly300MillisecondsOfQuiet() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onNameChange("Mailbox")
        advanceTimeBy(299)
        runCurrent()
        assertEquals("Mail", h.stored(id(1))!!.name)
        advanceTimeBy(1)
        runCurrent()
        assertEquals("Mailbox", h.stored(id(1))!!.name)
    }

    @Test
    fun keystrokesCoalesceIntoOneWrite() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        val before = h.fakes.library.snapshot.value.revision
        editor.onBodyChange("h")
        advanceTimeBy(100)
        editor.onBodyChange("hi")
        advanceTimeBy(100)
        editor.onBodyChange("hi!")
        advanceTimeBy(300)
        runCurrent()
        assertEquals(before + 1, h.fakes.library.snapshot.value.revision)
        assertEquals("hi!", h.stored(id(1))!!.content)
    }

    @Test
    fun tagsAndSwitchesAreWrittenAtOnce() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onTagInputChange("home,")
        runCurrent()
        assertEquals(listOf("work", "home"), h.stored(id(1))!!.tags)
        editor.onEnabledChange(false)
        runCurrent()
        assertFalse(h.stored(id(1))!!.isEnabled)
        editor.onTogglePin()
        runCurrent()
        assertTrue(h.stored(id(1))!!.isPinned)
        assertTrue(EditorEffect.Haptic(SnippetsHaptic.ToggledOff) in h.effects)
        assertTrue(EditorEffect.Haptic(SnippetsHaptic.ToggledOn) in h.effects)
    }

    @Test
    fun enterAcceptsTheFirstTagCompletionAndBackspaceRemovesTheLastTag() = runTest {
        val h = harness(ordinary, seed(snippet(3, tags = listOf("travel"))))
        val editor = h.editor(id(1))
        editor.onTagInputChange("tr")
        assertEquals(listOf("travel"), editor.uiState.value.tagCompletions.map { it.name })
        editor.onTagEnter()
        runCurrent()
        assertEquals(listOf("work", "travel"), h.stored(id(1))!!.tags)
        assertEquals("", editor.tagInput)
        editor.onRemoveLastTag()
        runCurrent()
        assertEquals(listOf("work"), h.stored(id(1))!!.tags)
    }

    @Test
    fun blurWritesAtOnce() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onFieldFocusChanged(EditorField.Name, true)
        editor.onNameChange("Blurred")
        editor.onFieldFocusChanged(EditorField.Name, false)
        runCurrent()
        assertEquals("Blurred", h.stored(id(1))!!.name)
    }

    @Test
    fun aSpaceAtTheEndCompletesTheKeywordAndPutsTheCaretAtTheEnd() = runTest {
        val h = harness(ordinary, seed(snippet(3, keyword = "git.push")), seed(snippet(4, keyword = "git.pull")))
        val editor = h.editor(id(1))
        editor.onKeywordChange(TextFieldValue("git", TextRange(3)))
        editor.onKeywordChange(TextFieldValue("git ", TextRange(4)))
        assertEquals(TextFieldValue("git.", TextRange(4)), editor.keyword)
        editor.onKeywordChange(TextFieldValue("gi t.", TextRange(3)))
        assertEquals("git.", editor.keyword.text)
        assertTrue(editor.onKeywordTab())
        assertEquals("git.pu", editor.keyword.text)
        advanceTimeBy(300)
        runCurrent()
        assertEquals("git.pu", h.stored(id(1))!!.keyword)
    }

    @Test
    fun aRemoteChangeSkipsTheFocusedFieldUntilItBlurs() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onFieldFocusChanged(EditorField.Name, true)
        h.fakes.library.update(id(1), SnippetEdit(name = "Remote", content = "Remote body"))
        runCurrent()
        assertEquals("Mail", editor.name)
        assertEquals("Remote body", editor.body)
        editor.onFieldFocusChanged(EditorField.Name, false)
        runCurrent()
        assertEquals("Remote", editor.name)
    }

    @Test
    fun aRemoteChangeDoesNotOverwriteAnUnsavedEdit() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onBodyChange("mine")
        h.fakes.library.update(id(1), SnippetEdit(content = "remote"))
        runCurrent()
        assertEquals("mine", editor.body)
        advanceTimeBy(300)
        runCurrent()
        assertEquals("mine", h.stored(id(1))!!.content)
    }

    @Test
    fun leavingDiscardsABlankNewDraft() = runTest {
        val h = harness(ordinary)
        val draft = h.fakes.library.create(NewSnippet()).valueOrNull()!!
        h.editor(draft)
        h.store.clear()
        advanceUntilIdle()
        assertNull(h.stored(draft))
    }

    @Test
    fun leavingFlushesAndKeepsANonBlankDraft() = runTest {
        val h = harness(ordinary)
        val draft = h.fakes.library.create(NewSnippet()).valueOrNull()!!
        val editor = h.editor(draft)
        editor.onNameChange("Kept")
        h.store.clear()
        advanceUntilIdle()
        assertEquals("Kept", h.stored(draft)!!.name)
    }

    @Test
    fun anOrdinaryCopyShowsTheCheckFor1500Milliseconds() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onCopy()
        runCurrent()
        assertEquals("hello", h.clipboard.text)
        assertTrue(editor.uiState.value.showsCopiedCheck)
        assertEquals(listOf<EditorEffect>(EditorEffect.Haptic(SnippetsHaptic.CopySucceeded)), h.effects)
        advanceTimeBy(1_500)
        runCurrent()
        assertFalse(editor.uiState.value.showsCopiedCheck)
    }

    @Test
    fun belowAndroid13ACopyAlsoShowsASnackbar() = runTest {
        val h = harness(ordinary, sdk = 30)
        val editor = h.editor(id(1))
        editor.onCopy()
        runCurrent()
        assertTrue(EditorEffect.ShowSnackbar(SnackbarRequest(uiText(R.string.snackbar_copied, "Mail"))) in h.effects)
    }

    @Test
    fun aCancelledSecureCopyIsSilent() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        h.fakes.authenticator.answer = AuthResult.Cancelled
        editor.onCopy()
        runCurrent()
        assertTrue(h.effects.isEmpty())
        assertNull(editor.uiState.value.dialog)
        assertNull(h.clipboard.text)
    }

    @Test
    fun aSecureEntryHasNoPreviewAndNoBodyText() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        assertTrue(editor.uiState.value.isSecure)
        assertEquals("", editor.body)
        assertNull(editor.uiState.value.preview)
        assertNull(editor.uiState.value.savedAt)
        assertEquals(SecurePanelState.Locked(), editor.securePanel)
    }

    @Test
    fun revealShowsTheBody() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        editor.onReveal()
        assertEquals(SecurePanelState.Unlocking, editor.securePanel)
        runCurrent()
        assertEquals(SecurePanelState.Revealed("s3cret"), editor.securePanel)
        assertTrue(EditorEffect.FocusSecureBody in h.effects)
    }

    @Test
    fun aCancelledRevealReturnsToLockedSilently() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        h.fakes.authenticator.answer = AuthResult.Cancelled
        editor.onReveal()
        runCurrent()
        assertEquals(SecurePanelState.Locked(), editor.securePanel)
        assertNull(editor.uiState.value.dialog)
        assertTrue(h.effects.isEmpty())
    }

    @Test
    fun aFailedRevealShowsTheErrorDialog() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        h.fakes.authenticator.answer = AuthResult.NotApproved
        editor.onReveal()
        runCurrent()
        assertEquals(SecurePanelState.Locked(), editor.securePanel)
        assertEquals(
            AppDialog.Error(uiText(R.string.error_title_reveal), uiText(R.string.error_auth_not_approved)),
            editor.uiState.value.dialog,
        )
        assertTrue(EditorEffect.Haptic(SnippetsHaptic.Rejected) in h.effects)
    }

    @Test
    fun anIdleSessionLocksWithItsReason() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        editor.onReveal()
        runCurrent()
        advanceTimeBy(5 * 60_000L + 1)
        runCurrent()
        assertEquals(SecurePanelState.Locked(LockReason.IdleTimeout), editor.securePanel)
    }

    @Test
    fun secureEditsAreSavedAfter300Milliseconds() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        editor.onReveal()
        runCurrent()
        editor.onSecureBodyChange("changed")
        advanceTimeBy(299)
        runCurrent()
        assertEquals("s3cret", h.secureBody(id(2)))
        advanceTimeBy(1)
        runCurrent()
        assertEquals("changed", h.secureBody(id(2)))
    }

    @Test
    fun aPendingSecureEditIsSavedBeforeTheVaultLocks() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        editor.onReveal()
        runCurrent()
        editor.onSecureBodyChange("last words")
        editor.onLock()
        runCurrent()
        assertEquals("last words", h.secureBody(id(2)))
        assertEquals(SecurePanelState.Locked(), editor.securePanel)
    }

    @Test
    fun aScreenRecordingHidesARevealedBody() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        editor.onReveal()
        runCurrent()
        h.capture.value = CaptureRisk.ScreenRecording
        runCurrent()
        assertEquals(SecurePanelState.Protected(ProtectedCause.ScreenRecording), editor.securePanel)
        h.capture.value = CaptureRisk.None
        runCurrent()
        assertEquals(SecurePanelState.Locked(), editor.securePanel)
    }

    @Test
    fun deletingAnOrdinaryEntryOffersUndoAndCloses() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onDelete()
        runCurrent()
        assertNull(h.stored(id(1)))
        val snackbar = h.effects.filterIsInstance<EditorEffect.ShowSnackbar>().single().request
        assertEquals(uiText(R.string.snackbar_deleted, "Mail"), snackbar.message)
        assertNotNull(snackbar.undo)
        assertEquals(EditorEffect.Close(EditorCloseReason.Deleted), h.effects.last())
        h.operations.undoDelete(snackbar.undo!!)
        runCurrent()
        assertNotNull(h.stored(id(1)))
    }

    @Test
    fun deletingASecureEntryAsksFirst() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        editor.onDelete()
        val dialog = editor.uiState.value.dialog
        assertEquals(AppDialog.DeleteSecure(id(2).toString(), "Token"), dialog)
        assertNotNull(h.stored(id(2)))
        editor.onConfirmDialog(dialog!!)
        runCurrent()
        assertNull(h.stored(id(2)))
        assertTrue(EditorEffect.ShowSnackbar(SnackbarRequest(uiText(R.string.snackbar_secure_deleted))) in h.effects)
        assertEquals(EditorEffect.Close(EditorCloseReason.Deleted), h.effects.last())
    }

    @Test
    fun anEntryDeletedElsewhereClosesWithASnackbar() = runTest {
        val h = harness(ordinary)
        h.editor(id(1))
        h.fakes.library.delete(id(1))
        runCurrent()
        assertEquals(
            listOf(
                EditorEffect.ShowSnackbar(SnackbarRequest(uiText(R.string.snackbar_deleted_elsewhere, "Mail"))),
                EditorEffect.Close(EditorCloseReason.DeletedElsewhere),
            ),
            h.effects,
        )
    }

    @Test
    fun aMissingEntryClosesSilently() = runTest {
        val h = harness(ordinary)
        h.editor(id(9))
        assertEquals(listOf<EditorEffect>(EditorEffect.Close(EditorCloseReason.Missing)), h.effects)
    }

    @Test
    fun makingSecureWithoutAVaultShowsTheRecoveryKeyFirst() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onSecureChange(true)
        runCurrent()
        val request = h.presenter.request.value
        assertNotNull(request)
        assertFalse(h.fakes.library.snapshot.value.entry(id(1))!!.isSecure)
        request!!.acknowledge()
        runCurrent()
        assertTrue(h.fakes.library.snapshot.value.entry(id(1))!!.isSecure)
        assertEquals("hello", h.secureBody(id(1)))
        assertTrue(editor.uiState.value.isSecure)
        assertEquals("", editor.body)
        assertTrue(EditorEffect.ShowSnackbar(SnackbarRequest(uiText(R.string.snackbar_made_secure))) in h.effects)
    }

    @Test
    fun cancellingTheRecoveryKeyChangesNothingSilently() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onSecureChange(true)
        runCurrent()
        h.presenter.request.value!!.cancel()
        runCurrent()
        assertFalse(h.fakes.library.snapshot.value.entry(id(1))!!.isSecure)
        assertEquals(listOf<EditorEffect>(EditorEffect.HideKeyboard), h.effects)
        assertNull(editor.uiState.value.dialog)
        assertFalse(editor.uiState.value.isConverting)
    }

    @Test
    fun makingOrdinaryAsksThenMoves() = runTest {
        val h = harness(secure)
        val editor = h.editor(id(2))
        editor.onSecureChange(false)
        val dialog = editor.uiState.value.dialog as AppDialog.MakeOrdinary
        editor.onConfirmDialog(dialog)
        runCurrent()
        assertFalse(editor.uiState.value.isSecure)
        assertEquals("s3cret", editor.body)
    }

    @Test
    fun aSaveFailureShowsUntilTheNextSuccess() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        h.fakes.controls.saveError = LibraryError.WriteFailed
        editor.onNameChange("X")
        advanceTimeBy(300)
        runCurrent()
        assertEquals(
            uiText(R.string.editor_save_error, uiText(R.string.error_library_write_failed)),
            editor.uiState.value.saveError,
        )
        h.fakes.controls.saveError = null
        editor.onNameChange("Y")
        advanceTimeBy(300)
        runCurrent()
        assertNull(editor.uiState.value.saveError)
    }

    @Test
    fun duplicateSwitchesToADisabledCopy() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onDuplicate()
        runCurrent()
        val open = h.effects.filterIsInstance<EditorEffect.OpenEditor>().single()
        val copy = h.stored(UUID.fromString(open.id))!!
        assertEquals("Mail Copy", copy.name)
        assertFalse(copy.isEnabled)
    }

    @Test
    fun placeholdersAreTintedAndPreviewed() = runTest {
        val h = harness(ordinary)
        val editor = h.editor(id(1))
        editor.onBodyChange("{date:yyyy} {clipboard}")
        val state = editor.uiState.value
        assertEquals(listOf(TextHighlight(0, 11), TextHighlight(12, 23)), state.bodyPlaceholders)
        assertEquals("2026 [Clipboard content]", state.preview)
    }

    @Test
    fun keywordMessagesAndSuggestions() = runTest {
        val h = harness(seed(snippet(1, name = "Meeting notes", content = "Agenda")), seed(snippet(3, keyword = "dup")))
        val editor = h.editor(id(1))
        assertEquals(KeywordMessage(uiText(R.string.editor_keyword_missing), false), editor.uiState.value.keywordMessage)
        assertTrue(editor.uiState.value.keywordSuggestions.isNotEmpty())
        editor.onKeywordChange(TextFieldValue("dup", TextRange(3)))
        val state = editor.uiState.value
        assertTrue(state.hasKeywordWarning)
        assertEquals(uiText(R.string.editor_keyword_duplicate, "dup", "Entry 3"), state.keywordMessage!!.text)
        assertTrue(state.keywordSuggestions.isEmpty())
    }
}
