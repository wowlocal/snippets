package com.khm.snippets.android.feature.library

import androidx.lifecycle.SavedStateHandle
import com.khm.snippets.android.R
import com.khm.snippets.android.data.LibraryAvailability
import com.khm.snippets.android.data.SyncFailureCode
import com.khm.snippets.android.data.SyncProvider
import com.khm.snippets.android.data.SyncRecoveryAction
import com.khm.snippets.android.data.SyncState
import com.khm.snippets.android.data.SyncStatus
import com.khm.snippets.android.data.core.CoreLibraryQueryEngine
import com.khm.snippets.android.data.fake.FakeBackends
import com.khm.snippets.android.data.fake.SeedEntry
import com.khm.snippets.android.feature.shared.AppDialog
import com.khm.snippets.android.feature.shared.RecoveryKeyPresenter
import com.khm.snippets.android.feature.shared.SnackbarRequest
import com.khm.snippets.android.feature.shared.SnippetOperations
import com.khm.snippets.android.feature.shared.SyncMenuAction
import com.khm.snippets.android.feature.shared.SyncOptIn
import com.khm.snippets.android.feature.shared.SyncPresentation
import com.khm.snippets.android.feature.shared.uiText
import com.khm.snippets.android.nav.SyncReviewRoute
import com.khm.snippets.android.platform.AuthResult
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
import com.khm.snippets.android.ui.components.SnackbarKind
import com.khm.snippets.android.ui.components.SnippetsHaptic
import com.khm.snippets.android.ui.model.SnippetRowAction
import com.khm.snippets.android.ui.model.TagUi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
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

class LibraryViewModelTest {
    @get:Rule val main = MainDispatcherRule()

    private val git = SyncProvider.Git("github.com/me/library", "main")
    private val gitName = uiText(R.string.sync_provider_git)

    private class Harness(val scope: TestScope, sdk: Int) {
        val clock = scope.testScheduler.monotonicClock()
        val fakes = FakeBackends(scope.backgroundScope, clock)
        val clipboard = FakeClipboard()
        val service = ClipboardService(clipboard, clock, scope.backgroundScope, RecordingScheduler(), PlatformInfo(sdk))
        val operations = SnippetOperations(fakes.library, fakes.vault, resolver(), service, RecoveryKeyPresenter(), scope.backgroundScope)
        val effects = mutableListOf<LibraryEffect>()

        fun library(savedState: SavedStateHandle = SavedStateHandle()): LibraryViewModel {
            val dispatcher = StandardTestDispatcher(scope.testScheduler)
            val viewModel = LibraryViewModel(
                savedState = savedState,
                library = fakes.library,
                queryEngine = CoreLibraryQueryEngine(dispatcher),
                sync = fakes.sync,
                settings = fakes.settings,
                operations = operations,
                clipboard = service,
                time = FakeTimeFormatter(),
                defaultDispatcher = dispatcher,
            )
            scope.backgroundScope.launch(UnconfinedTestDispatcher(scope.testScheduler)) { viewModel.effects.collect { effects += it } }
            scope.runCurrent()
            return viewModel
        }

        fun snackbars() = effects.filterIsInstance<LibraryEffect.ShowSnackbar>().map { it.request }
    }

    private fun TestScope.harness(vararg entries: SeedEntry, sdk: Int = 35): Harness =
        Harness(this, sdk).also { it.fakes.seed(entries.toList()) }

    private fun LibraryViewModel.empty(): LibraryEmptyUi? = (uiState.value.content as? LibraryContent.Empty)?.reason

    private val mail = seed(snippet(1, name = "Mail", keyword = "mail", content = "hello", tags = listOf("a", "b")))
    private val notes = seed(snippet(2, name = "Notes", content = "notes body", tags = listOf("a")))
    private val token = seed(snippet(3, name = "Token", keyword = "tok"), secureBody = "s3cret")

    // region States (screens-library-editor.md §2.4)

    @Test
    fun theSpinnerAppearsOnlyAfter300Milliseconds() = runTest {
        val h = harness()
        h.fakes.store.setAvailability(LibraryAvailability.Loading)
        val library = h.library()
        assertEquals(LibraryContent.Loading(showSpinner = false), library.uiState.value.content)
        advanceTimeBy(299)
        runCurrent()
        assertEquals(LibraryContent.Loading(showSpinner = false), library.uiState.value.content)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(LibraryContent.Loading(showSpinner = true), library.uiState.value.content)
        assertFalse(library.uiState.value.showFab)
    }

    @Test
    fun anEmptyLibraryWithSyncOffIsTheFirstRun() = runTest {
        val library = harness().library()
        assertEquals(LibraryEmptyUi.FirstRun(SyncMenuAction.SetUp), library.empty())
        assertFalse(library.uiState.value.showFab)
        assertFalse(library.uiState.value.showFilterRow)
    }

    @Test
    fun anEmptyLibraryWithAProviderOffersToTurnItOn() = runTest {
        val h = harness()
        h.fakes.sync.connect(git, enabled = false)
        assertEquals(LibraryEmptyUi.FirstRun(SyncMenuAction.TurnOn(gitName)), h.library().empty())
    }

    @Test
    fun anEmptySyncedLibrary() = runTest {
        val h = harness()
        h.fakes.sync.connect(git)
        val library = h.library()
        assertTrue(library.empty() is LibraryEmptyUi.SyncedEmpty)
        assertTrue(library.uiState.value.showFab)
    }

    @Test
    fun theFirstFetch() = runTest {
        val h = harness()
        h.fakes.sync.setStatus(SyncStatus(isEnabled = true, provider = git, state = SyncState.Syncing))
        val library = h.library()
        assertEquals(LibraryEmptyUi.FirstFetchRunning(gitName, started = true), library.empty())
        h.fakes.sync.setStatus(SyncStatus(isEnabled = true, provider = git, state = SyncState.Starting))
        runCurrent()
        assertEquals(LibraryEmptyUi.FirstFetchRunning(gitName, started = false), library.empty())
    }

    @Test
    fun aStalledFirstFetchOffersOneAction() = runTest {
        val h = harness()
        h.fakes.sync.setStatus(SyncStatus(isEnabled = true, provider = git, state = SyncState.Offline(null)))
        val library = h.library()
        assertEquals(StalledAction.TryAgain, (library.empty() as LibraryEmptyUi.FirstFetchStalled).action)
        h.fakes.sync.setStatus(SyncStatus(isEnabled = true, provider = git, state = SyncState.NeedsAttention(SyncFailureCode("forbidden"))))
        runCurrent()
        assertEquals(StalledAction.OpenSyncSettings, (library.empty() as LibraryEmptyUi.FirstFetchStalled).action)
        h.fakes.sync.setStatus(
            SyncStatus(isEnabled = true, provider = git, state = SyncState.Offline(null), recoveryAction = SyncRecoveryAction.RetrySync),
        )
        runCurrent()
        assertEquals(StalledAction.Recovery(SyncRecoveryAction.RetrySync), (library.empty() as LibraryEmptyUi.FirstFetchStalled).action)
    }

    @Test
    fun aQuarantinedLibrary() = runTest {
        val h = harness(mail)
        h.fakes.store.setAvailability(LibraryAvailability.Quarantined)
        val library = h.library()
        assertEquals(LibraryEmptyUi.Quarantined(uiText(R.string.sync_sentence_off)), library.empty())
        assertFalse(library.uiState.value.showFab)
    }

    @Test
    fun noResultsWithAndWithoutFilters() = runTest {
        val library = harness(mail, notes).library()
        library.onQueryChange("zzz")
        runCurrent()
        assertEquals(LibraryEmptyUi.NoResults(hasFilters = false), library.empty())
        library.onToggleTag(TagUi("a", "a"))
        runCurrent()
        assertEquals(LibraryEmptyUi.NoResults(hasFilters = true), library.empty())
    }

    @Test
    fun filtersThatMatchNothing() = runTest {
        val library = harness(mail, notes, seed(snippet(4, tags = listOf("c")))).library()
        library.onToggleTag(TagUi("b", "b"))
        library.onToggleTag(TagUi("c", "c"))
        runCurrent()
        assertEquals(LibraryEmptyUi.NoFilterMatch, library.empty())
        library.onEmptyAction(0)
        runCurrent()
        assertEquals(LibraryContent.Rows, library.uiState.value.content)
    }

    // endregion

    @Test
    fun rowsArePinnedFirstAndCounted() = runTest {
        val library = harness(mail, notes, seed(snippet(5, name = "Pinned", pinned = true))).library()
        val state = library.uiState.value
        assertEquals(listOf(id(5).toString()), state.pinned.map { it.id })
        assertEquals(listOf(id(2).toString(), id(1).toString()), state.others.map { it.id })
        assertEquals(3, state.totalCount)
        assertFalse(state.isFiltering)
    }

    @Test
    fun aCopyShowsTheCopiedStateFor1500Milliseconds() = runTest {
        val h = harness(mail)
        val library = h.library()
        library.onCopy(id(1).toString(), swipeTipEligible = false)
        runCurrent()
        assertEquals("hello", h.clipboard.text)
        assertEquals(id(1).toString(), library.uiState.value.copiedId)
        assertEquals(listOf<LibraryEffect>(LibraryEffect.Haptic(SnippetsHaptic.CopySucceeded)), h.effects)
        advanceTimeBy(1_500)
        runCurrent()
        assertNull(library.uiState.value.copiedId)
    }

    @Test
    fun belowAndroid13ACopyShowsASnackbar() = runTest {
        val h = harness(mail, sdk = 30)
        h.library().onCopy(id(1).toString(), swipeTipEligible = false)
        runCurrent()
        assertEquals(listOf(SnackbarRequest(uiText(R.string.snackbar_copied, "Mail"))), h.snackbars())
    }

    @Test
    fun nothingToCopy() = runTest {
        val h = harness(seed(snippet(6, name = "Empty")))
        h.library().onCopy(id(6).toString(), swipeTipEligible = false)
        runCurrent()
        assertEquals(listOf(SnackbarRequest(uiText(R.string.snackbar_nothing_to_copy, "Empty"))), h.snackbars())
        assertTrue(LibraryEffect.Haptic(SnippetsHaptic.Rejected) in h.effects)
    }

    @Test
    fun aCancelledSecureCopyIsSilent() = runTest {
        val h = harness(token)
        h.fakes.authenticator.answer = AuthResult.Cancelled
        val library = h.library()
        library.onCopy(id(3).toString(), swipeTipEligible = false)
        runCurrent()
        assertTrue(h.effects.isEmpty())
        assertNull(library.uiState.value.dialog)
        assertNull(library.uiState.value.copiedId)
    }

    @Test
    fun aSecureCopyStartsTheCountdown() = runTest {
        val h = harness(token)
        val library = h.library()
        library.onCopy(id(3).toString(), swipeTipEligible = false)
        runCurrent()
        assertNotNull(library.countdown.value)
        library.onClearClipboardNow()
        runCurrent()
        assertNull(h.clipboard.text)
    }

    @Test
    fun theSwipeTipFollowsTheFirstCopyOnce() = runTest {
        val h = harness(mail)
        val library = h.library()
        library.onCopy(id(1).toString(), swipeTipEligible = true)
        advanceTimeBy(2_399)
        runCurrent()
        assertTrue(h.snackbars().isEmpty())
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(SnackbarRequest(uiText(R.string.snackbar_swipe_tip), SnackbarKind.Tip)), h.snackbars())
        library.onCopy(id(1).toString(), swipeTipEligible = true)
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(1, h.snackbars().size)
    }

    @Test
    fun deletingOffersUndo() = runTest {
        val h = harness(mail, notes)
        val library = h.library()
        library.onRowAction(id(1).toString(), SnippetRowAction.Delete)
        runCurrent()
        val request = h.snackbars().single()
        assertEquals(uiText(R.string.snackbar_deleted, "Mail"), request.message)
        assertNotNull(request.undo)
        assertTrue(LibraryEffect.Haptic(SnippetsHaptic.Deleted) in h.effects)
        assertEquals(1, library.uiState.value.totalCount)
        h.operations.undoDelete(request.undo!!)
        runCurrent()
        assertEquals(2, library.uiState.value.totalCount)
    }

    @Test
    fun deletingASecureEntryAsksAndHasNoUndo() = runTest {
        val h = harness(token)
        val library = h.library()
        library.onRowAction(id(3).toString(), SnippetRowAction.Delete)
        runCurrent()
        val dialog = library.uiState.value.dialog
        assertEquals(AppDialog.DeleteSecure(id(3).toString(), "Token"), dialog)
        library.onConfirmDialog(dialog!!)
        runCurrent()
        assertEquals(listOf(SnackbarRequest(uiText(R.string.snackbar_secure_deleted))), h.snackbars())
        assertNull(library.uiState.value.dialog)
    }

    @Test
    fun duplicateOpensTheCopy() = runTest {
        val h = harness(mail)
        val library = h.library()
        library.onRowAction(id(1).toString(), SnippetRowAction.Duplicate)
        runCurrent()
        val open = h.effects.filterIsInstance<LibraryEffect.OpenEditor>().single()
        val copy = h.fakes.library.snapshot.value.entry(java.util.UUID.fromString(open.id))!!.snippet
        assertFalse(copy.isEnabled)
    }

    @Test
    fun pinningGivesToggleHaptics() = runTest {
        val h = harness(mail)
        val library = h.library()
        library.onRowAction(id(1).toString(), SnippetRowAction.TogglePin)
        runCurrent()
        assertEquals(listOf(id(1).toString()), library.uiState.value.pinned.map { it.id })
        library.onRowAction(id(1).toString(), SnippetRowAction.TogglePin)
        runCurrent()
        assertEquals(
            listOf<LibraryEffect>(LibraryEffect.Haptic(SnippetsHaptic.ToggledOn), LibraryEffect.Haptic(SnippetsHaptic.ToggledOff)),
            h.effects,
        )
    }

    @Test
    fun editOpensTheEditor() = runTest {
        val h = harness(mail)
        h.library().onRowAction(id(1).toString(), SnippetRowAction.Edit)
        assertEquals(listOf<LibraryEffect>(LibraryEffect.OpenEditor(id(1).toString())), h.effects)
    }

    @Test
    fun newSnippetCreatesABlankDraftWithTheBodyFocused() = runTest {
        val h = harness(mail)
        h.library().onNewSnippet()
        runCurrent()
        val open = h.effects.single() as LibraryEffect.OpenEditor
        assertTrue(open.focusBody)
    }

    @Test
    fun newFromAnEmptyClipboardExplains() = runTest {
        val h = harness(mail)
        val library = h.library()
        h.clipboard.text = "  "
        library.onNewFromClipboard()
        assertEquals(AppDialog.ClipboardEmpty, library.uiState.value.dialog)
        h.clipboard.text = "pasted"
        library.onNewFromClipboard()
        runCurrent()
        val open = h.effects.single() as LibraryEffect.OpenEditor
        assertEquals("pasted", h.fakes.library.snapshot.value.entry(java.util.UUID.fromString(open.id))!!.snippet.content)
    }

    @Test
    fun filtersCombineWithAndAndAreSaved() = runTest {
        val saved = SavedStateHandle()
        val library = harness(mail, notes).library(saved)
        library.onToggleTag(TagUi("a", "a"))
        runCurrent()
        assertEquals(2, library.uiState.value.visibleCount)
        library.onToggleTag(TagUi("b", "b"))
        runCurrent()
        assertEquals(listOf(id(1).toString()), library.uiState.value.others.map { it.id })
        assertEquals(listOf("a", "b"), saved.get<ArrayList<String>>("library.filters"))
        assertEquals(listOf("a", "b"), library.uiState.value.filterChips.take(2).map { it.tag.folded })
        assertEquals(2, library.uiState.value.activeFilterCount)
        assertTrue(library.uiState.value.isFiltering)
    }

    @Test
    fun aFilterForAVanishedTagDropsSilently() = runTest {
        val saved = SavedStateHandle()
        val h = harness(mail, notes)
        val library = h.library(saved)
        library.onToggleTag(TagUi("b", "b"))
        runCurrent()
        h.fakes.library.toggleTag(id(1), "b")
        runCurrent()
        assertEquals(0, library.uiState.value.activeFilterCount)
        assertEquals(emptyList<String>(), saved.get<ArrayList<String>>("library.filters"))
    }

    @Test
    fun theQueryIsSavedAndRestored() = runTest {
        val saved = SavedStateHandle()
        val h = harness(mail, notes)
        val library = h.library(saved)
        library.onQueryChange("note")
        runCurrent()
        assertEquals("note", saved.get<String>("library.query"))
        assertEquals(listOf(id(2).toString()), library.uiState.value.others.map { it.id })
        val restored = h.library(SavedStateHandle(mapOf("library.query" to "note")))
        assertEquals("note", restored.query)
        assertEquals(1, restored.uiState.value.visibleCount)
    }

    @Test
    fun pullToRefreshWithNothingSetUpOffersSetup() = runTest {
        val library = harness(mail).library()
        library.onRefresh()
        assertEquals(AppDialog.SyncOptInPrompt(SyncOptIn.NothingSetUp), library.uiState.value.dialog)
        assertFalse(library.uiState.value.isRefreshing)
    }

    @Test
    fun pullToRefreshWithAProviderOffersToTurnItOn() = runTest {
        val h = harness(mail)
        h.fakes.sync.connect(git, enabled = false)
        val library = h.library()
        library.onRefresh()
        assertEquals(AppDialog.SyncOptInPrompt(SyncOptIn.Encrypted(gitName)), library.uiState.value.dialog)
        h.fakes.sync.connect(git.copy(isPlainText = true), enabled = false)
        library.onRefresh()
        assertEquals(AppDialog.SyncOptInPrompt(SyncOptIn.PlainTextGit), library.uiState.value.dialog)
    }

    @Test
    fun pullToRefreshRunsOneManualRound() = runTest {
        val h = harness(mail)
        h.fakes.sync.connect(git)
        h.fakes.controls.latencyMillis = 1_000
        val library = h.library()
        library.onRefresh()
        runCurrent()
        assertTrue(library.uiState.value.isRefreshing)
        advanceUntilIdle()
        assertFalse(library.uiState.value.isRefreshing)
        assertEquals(1, h.fakes.sync.manualRounds)
    }

    @Test
    fun pullToRefreshWithARecoveryActsLikeTheCard() = runTest {
        val h = harness(mail)
        h.fakes.sync.setStatus(
            SyncStatus(isEnabled = true, provider = git, state = SyncState.Idle(1.0), recoveryAction = SyncRecoveryAction.ApplyRemoteDeletions),
        )
        val library = h.library()
        library.onRefresh()
        assertEquals(listOf<LibraryEffect>(LibraryEffect.Navigate(SyncReviewRoute)), h.effects)
        h.fakes.sync.setStatus(
            SyncStatus(isEnabled = true, provider = git, state = SyncState.Idle(1.0), recoveryAction = SyncRecoveryAction.RetrySync),
        )
        library.onRefresh()
        runCurrent()
        assertEquals(listOf(SyncRecoveryAction.RetrySync), h.fakes.sync.performedRecoveries)
    }

    @Test
    fun theSyncMenuItemFollowsTheState() = runTest {
        val h = harness(mail)
        h.fakes.sync.connect(git)
        val library = h.library()
        assertEquals(SyncMenuAction.SyncNow, library.uiState.value.syncMenu)
        library.onSyncMenuAction()
        runCurrent()
        assertEquals(listOf(SnackbarRequest(uiText(R.string.snackbar_syncing))), h.snackbars())
        assertEquals(1, h.fakes.sync.manualRounds)
    }

    @Test
    fun theSyncRowAndSheet() = runTest {
        val h = harness(mail, seed(snippet(7, tags = listOf("conflict"))))
        h.fakes.sync.connect(git)
        val library = h.library()
        val time = FakeTimeFormatter()
        assertEquals(SyncPresentation.libraryRow(h.fakes.sync.status.value, false, time), library.uiState.value.sync)
        library.onSyncRowClick()
        assertEquals(LibrarySheet.Sync, library.uiState.value.sheet)
        assertEquals(1, library.uiState.value.syncSheet!!.conflictCount)
        assertTrue(library.uiState.value.syncSheet!!.canSyncNow)
    }

    @Test
    fun reviewConflictsFiltersByTheConflictTag() = runTest {
        val library = harness(mail, seed(snippet(7, tags = listOf("conflict")))).library()
        library.onQueryChange("x")
        library.onSyncRowClick()
        library.onReviewConflicts()
        runCurrent()
        assertEquals("", library.query)
        assertNull(library.uiState.value.sheet)
        assertEquals(listOf(id(7).toString()), library.uiState.value.others.map { it.id })
    }

    @Test
    fun twoPaneSelectionMovesToTheNextRowThenThePrevious() = runTest {
        val h = harness(seed(snippet(1)), seed(snippet(2)), seed(snippet(3)))
        val library = h.library()
        library.onSelectionChanged(id(2).toString())
        library.onRowAction(id(2).toString(), SnippetRowAction.Delete)
        runCurrent()
        assertTrue(LibraryEffect.SelectAfterRemoval(id(1).toString()) in h.effects)
        library.onSelectionChanged(id(1).toString())
        library.onRowAction(id(1).toString(), SnippetRowAction.Delete)
        runCurrent()
        assertTrue(LibraryEffect.SelectAfterRemoval(id(3).toString()) in h.effects)
    }

    @Test
    fun theMoreMenuNavigates() = runTest {
        val h = harness(mail)
        val library = h.library()
        library.onImport()
        library.onOpenSettings()
        assertEquals(
            listOf(LibraryEffect.Navigate(com.khm.snippets.android.nav.ImportRoute), LibraryEffect.OpenSettings(null)),
            h.effects,
        )
    }
}
