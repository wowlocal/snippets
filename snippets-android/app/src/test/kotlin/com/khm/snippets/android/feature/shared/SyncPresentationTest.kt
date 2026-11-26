package com.khm.snippets.android.feature.shared

import com.khm.snippets.android.R
import com.khm.snippets.android.data.DeletionReview
import com.khm.snippets.android.data.SyncFailureCode
import com.khm.snippets.android.data.SyncHaltReason
import com.khm.snippets.android.data.SyncProvider
import com.khm.snippets.android.data.SyncRecoveryAction
import com.khm.snippets.android.data.SyncState
import com.khm.snippets.android.data.SyncStatus
import com.khm.snippets.android.data.VaultWait
import com.khm.snippets.android.testing.FakeTimeFormatter
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.SyncReviewKind
import org.junit.Assert.assertEquals
import org.junit.Test

class SyncPresentationTest {
    private val time = FakeTimeFormatter()
    private val git = SyncProvider.Git("github.com/me/library", "main")
    private val gitName = uiText(R.string.sync_provider_git)

    private fun on(state: SyncState, fetched: Boolean = true, recovery: SyncRecoveryAction? = null) =
        SyncStatus(isEnabled = true, provider = git, state = state, hasFetchedLibrary = fetched, recoveryAction = recovery)

    @Test
    fun sentencesForTheEverydayStates() {
        assertEquals(uiText(R.string.sync_sentence_off), SyncPresentation.sentence(SyncStatus(), time))
        assertEquals(uiText(R.string.sync_sentence_starting), SyncPresentation.sentence(on(SyncState.Starting), time))
        assertEquals(uiText(R.string.sync_sentence_never), SyncPresentation.sentence(on(SyncState.Idle(null)), time))
        assertEquals(uiText(R.string.sync_sentence_synced_today, "t:5"), SyncPresentation.sentence(on(SyncState.Idle(5.0)), time))
        assertEquals(uiText(R.string.sync_sentence_syncing), SyncPresentation.sentence(on(SyncState.Syncing), time))
        assertEquals(uiText(R.string.sync_sentence_offline, gitName, "t:9"), SyncPresentation.sentence(on(SyncState.Offline(9.0)), time))
    }

    @Test
    fun anEarlierSyncShowsDateAndTime() {
        time.today = false
        assertEquals(
            uiText(R.string.sync_sentence_synced_earlier, uiText(R.string.time_date_and_time, "d:5", "t:5")),
            SyncPresentation.sentence(on(SyncState.Idle(5.0)), time),
        )
    }

    @Test
    fun gitDetailsNeedNoGenericNextStep() {
        assertEquals(
            uiText(R.string.sync_sentence_needs_attention, uiText(R.string.sync_git_token_refused)),
            SyncPresentation.sentence(on(SyncState.NeedsAttention(SyncFailureCode("git_http_401"))), time),
        )
        assertEquals(
            uiText(R.string.sync_sentence_needs_attention, uiText(R.string.sync_git_not_usable)),
            SyncPresentation.sentence(on(SyncState.NeedsAttention(SyncFailureCode("git_unsupported_object_format"))), time),
        )
        assertEquals(
            UiText.Sentences(listOf(uiText(R.string.sync_sentence_needs_attention, uiText(R.string.sync_attention_quota)), uiText(R.string.sync_sentence_fix_condition))),
            SyncPresentation.sentence(on(SyncState.NeedsAttention(SyncFailureCode("quota_exceeded"))), time),
        )
        assertEquals(
            uiText(R.string.sync_sentence_needs_authentication, gitName, uiText(R.string.sync_git_token_missing)),
            SyncPresentation.sentence(on(SyncState.NeedsAuthentication(SyncFailureCode("git_credential_required"))), time),
        )
    }

    @Test
    fun aMassDeletionHaltCarriesItsNumbersAndGuidance() {
        val review = DeletionReview(deleting = 40, total = 50, keeps = 10, allowedWithoutConfirmation = 10)
        assertEquals(
            UiText.Sentences(
                listOf(
                    uiText(
                        R.string.sync_sentence_halted_detail,
                        uiText(R.string.sync_halt_reason_mass_deletion),
                        uiText(R.string.sync_halt_detail_deletion_git, 40, 50, 10, 10),
                    ),
                    uiText(R.string.sync_halt_guidance_mass_deletion),
                ),
            ),
            SyncPresentation.sentence(on(SyncState.Halted(SyncHaltReason.MassDeletion, review)), time),
        )
    }

    @Test
    fun libraryRowShortForms() {
        assertEquals(LibrarySyncUi.Hidden, SyncPresentation.libraryRow(SyncStatus(), libraryIsEmpty = true, time))
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.Preparing, uiText(R.string.sync_row_preparing_first)),
            SyncPresentation.libraryRow(on(SyncState.Starting, fetched = false), libraryIsEmpty = true, time),
        )
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.Preparing, uiText(R.string.sync_row_preparing)),
            SyncPresentation.libraryRow(on(SyncState.Starting), libraryIsEmpty = false, time),
        )
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.Syncing, uiText(R.string.sync_row_fetching)),
            SyncPresentation.libraryRow(on(SyncState.Syncing, fetched = false), libraryIsEmpty = true, time),
        )
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.Syncing, uiText(R.string.sync_row_syncing)),
            SyncPresentation.libraryRow(on(SyncState.Syncing), libraryIsEmpty = false, time),
        )
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.Synced, uiText(R.string.sync_row_synced, "t:3")),
            SyncPresentation.libraryRow(on(SyncState.Idle(3.0)), libraryIsEmpty = false, time),
        )
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.WaitingForFirstFetch, uiText(R.string.sync_row_waiting)),
            SyncPresentation.libraryRow(on(SyncState.Idle(null), fetched = false), libraryIsEmpty = true, time),
        )
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.Synced, uiText(R.string.sync_row_not_synced, gitName)),
            SyncPresentation.libraryRow(on(SyncState.Idle(null)), libraryIsEmpty = false, time),
        )
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.Offline, uiText(R.string.sync_row_first_paused)),
            SyncPresentation.libraryRow(on(SyncState.Offline(null), fetched = false), libraryIsEmpty = true, time),
        )
        assertEquals(
            LibrarySyncUi.Quiet(SyncGlyph.Offline, uiText(R.string.sync_row_unavailable, gitName)),
            SyncPresentation.libraryRow(on(SyncState.Offline(null)), libraryIsEmpty = false, time),
        )
    }

    @Test
    fun cardsReplaceTheRowWhenSyncNeedsTheUser() {
        val auth = SyncPresentation.libraryRow(on(SyncState.NeedsAuthentication(SyncFailureCode("git_http_401"))), false, time) as LibrarySyncUi.Card
        assertEquals(SyncReviewKind.NeedsAttention, auth.kind)
        assertEquals(SyncCardAction.OpenSyncSettings, auth.action)

        val incompatible = SyncPresentation.libraryRow(on(SyncState.NeedsAttention(SyncFailureCode("incompatible_version"))), false, time) as LibrarySyncUi.Card
        assertEquals(null, incompatible.action)

        val waiting = SyncPresentation.libraryRow(on(SyncState.WaitingForVault(VaultWait.SecureConflict)), false, time) as LibrarySyncUi.Card
        assertEquals(SyncReviewKind.WaitingForVault, waiting.kind)

        val schema = SyncPresentation.libraryRow(on(SyncState.Halted(SyncHaltReason.SchemaTooNew)), false, time) as LibrarySyncUi.Card
        assertEquals(LibrarySyncUi.Card(SyncReviewKind.Halted, SyncGlyph.UpdateRequired, uiText(R.string.sync_row_update_required), null, true), schema)

        val mass = SyncPresentation.libraryRow(
            on(SyncState.Halted(SyncHaltReason.MassDeletion), recovery = SyncRecoveryAction.ApplyRemoteDeletions),
            false,
            time,
        ) as LibrarySyncUi.Card
        assertEquals(SyncReviewKind.HaltedDataAtRisk, mass.kind)
        assertEquals(SyncCardAction.Recovery(SyncRecoveryAction.ApplyRemoteDeletions), mass.action)
        assertEquals(true, mass.isHalt)
    }

    @Test
    fun aPendingRecoveryShowsEvenWithSyncOff() {
        val status = SyncStatus(isEnabled = false, provider = git, state = SyncState.Halted(SyncHaltReason.LocalLibraryQuarantined), recoveryAction = SyncRecoveryAction.CheckAgain)
        val card = SyncPresentation.libraryRow(status, false, time) as LibrarySyncUi.Card
        assertEquals(SyncCardAction.Recovery(SyncRecoveryAction.CheckAgain), card.action)
    }

    @Test
    fun menuActionFirstMatch() {
        assertEquals(
            SyncMenuAction.Recovery(SyncRecoveryAction.RepairCheckpoint),
            SyncPresentation.menuAction(on(SyncState.Halted(SyncHaltReason.CheckpointUnreadable), recovery = SyncRecoveryAction.RepairCheckpoint)),
        )
        assertEquals(SyncMenuAction.OpenSyncSettings, SyncPresentation.menuAction(on(SyncState.NeedsAttention(SyncFailureCode("forbidden")))))
        assertEquals(SyncMenuAction.SyncNow, SyncPresentation.menuAction(on(SyncState.Idle(1.0))))
        assertEquals(SyncMenuAction.TurnOn(gitName), SyncPresentation.menuAction(SyncStatus(provider = git)))
        assertEquals(SyncMenuAction.SetUp, SyncPresentation.menuAction(SyncStatus()))
    }

    @Test
    fun providerTexts() {
        assertEquals(uiText(R.string.sync_sheet_provider_git, "github.com/me/library", "main"), SyncPresentation.providerLine(git))
        assertEquals(uiText(R.string.sync_sheet_provider_none), SyncPresentation.providerLine(null))
        assertEquals(uiText(R.string.sync_provider_cloud), SyncPresentation.providerName(SyncProvider.SnippetsCloud("L1")))
    }
}
