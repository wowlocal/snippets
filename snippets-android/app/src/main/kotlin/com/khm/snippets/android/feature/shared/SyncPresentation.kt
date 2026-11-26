package com.khm.snippets.android.feature.shared

import androidx.annotation.StringRes
import androidx.compose.runtime.Immutable
import com.khm.snippets.android.R
import com.khm.snippets.android.data.DeletionReview
import com.khm.snippets.android.data.SyncFailureCode
import com.khm.snippets.android.data.SyncHaltReason
import com.khm.snippets.android.data.SyncProvider
import com.khm.snippets.android.data.SyncRecoveryAction
import com.khm.snippets.android.data.SyncStartIssue
import com.khm.snippets.android.data.SyncState
import com.khm.snippets.android.data.SyncStatus
import com.khm.snippets.android.data.VaultWait
import com.khm.snippets.android.platform.TimeFormatter
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.SyncReviewKind

/** What the button of a Review card does. */
@Immutable
sealed interface SyncCardAction {
    @Immutable
    data class Recovery(val action: SyncRecoveryAction) : SyncCardAction

    @Immutable
    data object OpenSyncSettings : SyncCardAction
}

/** The library's sync status: nothing, the quiet row, or the Review card (components.md §7). */
@Immutable
sealed interface LibrarySyncUi {
    @Immutable
    data object Hidden : LibrarySyncUi

    @Immutable
    data class Quiet(val glyph: SyncGlyph, val text: UiText) : LibrarySyncUi

    /** @param isHalt A tap on the card body opens the Review screen; otherwise Sync settings. */
    @Immutable
    data class Card(
        val kind: SyncReviewKind,
        val glyph: SyncGlyph,
        val text: UiText,
        val action: SyncCardAction?,
        val isHalt: Boolean,
    ) : LibrarySyncUi
}

/** The sync item of the library's More menu, first match (screens-library-editor.md §3). */
@Immutable
sealed interface SyncMenuAction {
    @Immutable
    data class Recovery(val action: SyncRecoveryAction) : SyncMenuAction

    @Immutable
    data object OpenSyncSettings : SyncMenuAction

    @Immutable
    data object SyncNow : SyncMenuAction

    @Immutable
    data class TurnOn(val provider: UiText) : SyncMenuAction

    @Immutable
    data object SetUp : SyncMenuAction
}

/**
 * The one place that phrases sync: the status sentence (screens-settings-data.md §4), the
 * library row's short forms (screens-library-editor.md §2.6) and the action titles. Pure: it
 * returns [UiText], which composables resolve.
 */
object SyncPresentation {
    fun providerName(provider: SyncProvider?): UiText = when (provider) {
        is SyncProvider.SnippetsCloud -> uiText(R.string.sync_provider_cloud)
        is SyncProvider.Git, null -> uiText(R.string.sync_provider_git)
    }

    /** `Git · github.com/me/library (main)`, for the sync sheet. */
    fun providerLine(provider: SyncProvider?): UiText = when (provider) {
        is SyncProvider.Git -> uiText(R.string.sync_sheet_provider_git, provider.location, provider.branch)
        is SyncProvider.SnippetsCloud -> uiText(R.string.sync_sheet_provider_cloud, provider.libraryId)
        null -> uiText(R.string.sync_sheet_provider_none)
    }

    /** Where a library goes when sync starts: `github.com/me/library (main)`. */
    fun destination(provider: SyncProvider): UiText = when (provider) {
        is SyncProvider.Git -> uiText(R.string.sync_destination_git, provider.location, provider.branch)
        is SyncProvider.SnippetsCloud -> uiText(R.string.sync_destination_cloud, provider.libraryId)
    }

    @StringRes
    fun recoveryTitle(action: SyncRecoveryAction): Int = when (action) {
        SyncRecoveryAction.ApplyRemoteDeletions -> R.string.sync_recovery_confirm_deletions
        SyncRecoveryAction.RefreshDeletionReview -> R.string.sync_recovery_refresh_deletions
        SyncRecoveryAction.UseCurrentAccount -> R.string.sync_recovery_review_account
        SyncRecoveryAction.RepairCheckpoint -> R.string.sync_recovery_repair
        SyncRecoveryAction.RestoreCloudFromThisDevice -> R.string.sync_recovery_restore_cloud
        SyncRecoveryAction.ReclaimRecovery -> R.string.sync_recovery_take_over
        SyncRecoveryAction.RetrySync -> R.string.sync_recovery_try_again
        SyncRecoveryAction.CheckAgain -> R.string.sync_recovery_check_again
    }

    fun menuAction(status: SyncStatus): SyncMenuAction {
        val recovery = status.recoveryAction
        return when {
            recovery != null -> SyncMenuAction.Recovery(recovery)
            status.isEnabled && status.needsAttention -> SyncMenuAction.OpenSyncSettings
            status.isEnabled -> SyncMenuAction.SyncNow
            status.provider != null -> SyncMenuAction.TurnOn(providerName(status.provider))
            else -> SyncMenuAction.SetUp
        }
    }

    /** The full status sentence, the same everywhere it is shown. */
    fun sentence(status: SyncStatus, time: TimeFormatter): UiText {
        val provider = providerName(status.provider)
        if (!status.isEnabled && status.recoveryAction == null) return uiText(R.string.sync_sentence_off)
        return when (val state = status.state) {
            SyncState.Off -> uiText(R.string.sync_sentence_off)
            is SyncState.CannotStart -> uiText(R.string.sync_sentence_cannot_start, uiText(startIssue(state.issue)))
            SyncState.Starting -> uiText(R.string.sync_sentence_starting)
            is SyncState.Idle -> {
                val last = state.lastSyncedAt
                when {
                    last == null -> uiText(R.string.sync_sentence_never)
                    time.isToday(last) -> uiText(R.string.sync_sentence_synced_today, time.shortTime(last))
                    else -> uiText(R.string.sync_sentence_synced_earlier, dateAndTime(last, time))
                }
            }
            SyncState.Syncing -> uiText(R.string.sync_sentence_syncing)
            is SyncState.Offline -> state.retryAt?.let { uiText(R.string.sync_sentence_offline, provider, time.shortTime(it)) }
                ?: uiText(R.string.sync_sentence_offline_no_retry, provider)
            is SyncState.NeedsAuthentication -> uiText(R.string.sync_sentence_needs_authentication, provider, uiText(authenticationDetail(state.code)))
            is SyncState.NeedsAttention -> attentionSentence(state.code, status.provider)
            is SyncState.WaitingForVault -> when (state.wait) {
                VaultWait.SecureConflict -> uiText(R.string.sync_sentence_waiting_conflict)
                VaultWait.GitVaultNotSetUp -> uiText(R.string.sync_sentence_waiting_git_vault)
                VaultWait.Other -> uiText(R.string.sync_sentence_waiting_other)
            }
            is SyncState.Halted -> haltSentence(state, status.provider)
        }
    }

    /**
     * The library's row or card.
     *
     * @param libraryIsEmpty With no first fetch yet, an empty library uses the first-fetch
     *   wording.
     */
    fun libraryRow(status: SyncStatus, libraryIsEmpty: Boolean, time: TimeFormatter): LibrarySyncUi {
        if (!status.isEnabled && status.recoveryAction == null) return LibrarySyncUi.Hidden
        val firstFetch = !status.hasFetchedLibrary && libraryIsEmpty
        val provider = providerName(status.provider)
        return when (val state = status.state) {
            SyncState.Off -> LibrarySyncUi.Hidden
            SyncState.Starting -> LibrarySyncUi.Quiet(
                SyncGlyph.Preparing,
                uiText(if (firstFetch) R.string.sync_row_preparing_first else R.string.sync_row_preparing),
            )
            SyncState.Syncing -> LibrarySyncUi.Quiet(
                SyncGlyph.Syncing,
                uiText(if (firstFetch) R.string.sync_row_fetching else R.string.sync_row_syncing),
            )
            is SyncState.Idle -> {
                val last = state.lastSyncedAt
                when {
                    last != null -> LibrarySyncUi.Quiet(
                        SyncGlyph.Synced,
                        uiText(R.string.sync_row_synced, if (time.isToday(last)) time.shortTime(last) else dateAndTime(last, time)),
                    )
                    firstFetch -> LibrarySyncUi.Quiet(SyncGlyph.WaitingForFirstFetch, uiText(R.string.sync_row_waiting))
                    else -> LibrarySyncUi.Quiet(SyncGlyph.Synced, uiText(R.string.sync_row_not_synced, provider))
                }
            }
            is SyncState.Offline -> LibrarySyncUi.Quiet(
                SyncGlyph.Offline,
                if (firstFetch) uiText(R.string.sync_row_first_paused) else uiText(R.string.sync_row_unavailable, provider),
            )
            is SyncState.NeedsAuthentication ->
                card(SyncReviewKind.NeedsAttention, SyncGlyph.NeedsAuthentication, sentence(status, time), status)
            is SyncState.NeedsAttention -> card(
                SyncReviewKind.NeedsAttention,
                SyncGlyph.NeedsAttention,
                sentence(status, time),
                status,
                hasButton = state.code.value != CODE_INCOMPATIBLE_VERSION,
            )
            is SyncState.CannotStart -> card(SyncReviewKind.NeedsAttention, SyncGlyph.NeedsAttention, sentence(status, time), status)
            is SyncState.WaitingForVault -> card(SyncReviewKind.WaitingForVault, SyncGlyph.WaitingForVault, sentence(status, time), status)
            is SyncState.Halted -> when {
                state.reason == SyncHaltReason.SchemaTooNew -> LibrarySyncUi.Card(
                    kind = SyncReviewKind.Halted,
                    glyph = SyncGlyph.UpdateRequired,
                    text = uiText(R.string.sync_row_update_required),
                    action = null,
                    isHalt = true,
                )
                state.reason.risksData -> card(SyncReviewKind.HaltedDataAtRisk, SyncGlyph.HaltedDataAtRisk, sentence(status, time), status, isHalt = true)
                else -> card(SyncReviewKind.Halted, SyncGlyph.Halted, sentence(status, time), status, isHalt = true)
            }
        }
    }

    private fun card(
        kind: SyncReviewKind,
        glyph: SyncGlyph,
        text: UiText,
        status: SyncStatus,
        isHalt: Boolean = false,
        hasButton: Boolean = true,
    ): LibrarySyncUi.Card = LibrarySyncUi.Card(
        kind = kind,
        glyph = glyph,
        text = text,
        action = when {
            status.recoveryAction != null -> SyncCardAction.Recovery(status.recoveryAction)
            hasButton -> SyncCardAction.OpenSyncSettings
            else -> null
        },
        isHalt = isHalt,
    )

    private val SyncHaltReason.risksData: Boolean
        get() = this == SyncHaltReason.MassDeletion || this == SyncHaltReason.RemoteDataReset || this == SyncHaltReason.ManifestIntegrityFailed

    private fun dateAndTime(appleSeconds: Double, time: TimeFormatter): UiText =
        uiText(R.string.time_date_and_time, time.mediumDate(appleSeconds), time.shortTime(appleSeconds))

    private fun attentionSentence(code: SyncFailureCode, provider: SyncProvider?): UiText {
        val detail = uiText(R.string.sync_sentence_needs_attention, uiText(attentionDetail(code, provider)))
        // Git details already say what to do; the others get the generic next step.
        return if (code.value.startsWith(GIT_CODE_PREFIX)) detail else UiText.Sentences(listOf(detail, uiText(R.string.sync_sentence_fix_condition)))
    }

    private fun haltSentence(state: SyncState.Halted, provider: SyncProvider?): UiText {
        val isGit = provider is SyncProvider.Git
        val reason = uiText(haltReason(state.reason, isGit))
        val stopped = state.deletion?.let { uiText(R.string.sync_sentence_halted_detail, reason, deletionDetail(it, isGit)) }
            ?: uiText(R.string.sync_sentence_halted, reason)
        val guidance = haltGuidance(state.reason) ?: return stopped
        return UiText.Sentences(listOf(stopped, uiText(guidance)))
    }

    private fun deletionDetail(review: DeletionReview, isGit: Boolean): UiText = uiText(
        if (isGit) R.string.sync_halt_detail_deletion_git else R.string.sync_halt_detail_deletion,
        review.deleting,
        review.total,
        review.keeps,
        review.allowedWithoutConfirmation,
    )

    @StringRes
    private fun startIssue(issue: SyncStartIssue): Int = when (issue) {
        SyncStartIssue.NewerLocalState -> R.string.sync_start_newer_state
        SyncStartIssue.CheckpointUnreadable -> R.string.sync_start_checkpoint_unreadable
        SyncStartIssue.GitKeyRequired -> R.string.sync_start_git_key_required
        SyncStartIssue.GitTokenMissing -> R.string.sync_start_git_token_missing
        SyncStartIssue.GitNotConnected -> R.string.sync_start_git_not_connected
        SyncStartIssue.GitKeyUnverified -> R.string.sync_start_git_key_unverified
    }

    @StringRes
    private fun authenticationDetail(code: SyncFailureCode): Int = gitDetail(code) ?: when (code.value) {
        "sign_in_required" -> R.string.sync_auth_sign_in
        "sign_in_expired" -> R.string.sync_auth_expired
        else -> R.string.sync_auth_sign_in_again
    }

    @StringRes
    private fun attentionDetail(code: SyncFailureCode, provider: SyncProvider?): Int = gitDetail(code) ?: when (code.value) {
        // Git's limit is its own record size; the cloud names no number.
        "record_too_large" -> if (provider is SyncProvider.Git) R.string.sync_git_record_too_large else R.string.sync_attention_too_large
        "payload_too_large" -> R.string.sync_attention_too_large
        "quota_exceeded" -> R.string.sync_attention_quota
        "forbidden" -> R.string.sync_attention_forbidden
        CODE_INCOMPATIBLE_VERSION -> R.string.sync_attention_incompatible
        "startup_prerequisite_unavailable" -> R.string.sync_attention_prerequisite
        "cloud_key_required" -> R.string.sync_attention_cloud_key
        "sync_key_unreadable" -> R.string.sync_attention_key_unreadable
        "not_found" -> R.string.sync_attention_not_found
        "internal_error" -> R.string.sync_attention_internal
        else -> R.string.sync_attention_rejected
    }

    /** The detail of a Git failure code (screens-git.md §10), or null for a non-Git code. */
    @StringRes
    private fun gitDetail(code: SyncFailureCode): Int? {
        val value = code.value
        if (!value.startsWith(GIT_CODE_PREFIX)) return null
        return when (value) {
            "git_http_401", "git_http_403" -> R.string.sync_git_token_refused
            "git_credential_required" -> R.string.sync_git_token_missing
            "git_ssh_host_key_unknown" -> R.string.sync_git_host_key_unknown
            "git_ssh_host_key_changed" -> R.string.sync_git_host_key_changed
            "git_ssh_permission_denied" -> R.string.sync_git_permission_denied
            "git_repository_not_found" -> R.string.sync_git_not_found
            "git_key_required" -> R.string.sync_git_key_required
            "git_configuration_required" -> R.string.sync_git_configuration_required
            "git_library_replaced" -> R.string.sync_git_library_replaced
            "git_repository_not_initialized" -> R.string.sync_git_not_initialized
            "git_branch_not_snippets_library" -> R.string.sync_git_foreign_branch
            "git_sync_schema_unsupported" -> R.string.sync_git_schema_unsupported
            "git_push_rejected" -> R.string.sync_git_push_rejected
            "git_response_too_large" -> R.string.sync_git_response_too_large
            "git_library_mode_changed" -> R.string.sync_git_mode_changed
            "git_push_too_large" -> R.string.sync_git_push_too_large
            "git_unsupported_ssh_algorithms", "git_unsupported_ssh_handshake" -> R.string.sync_git_ssh_algorithms
            "git_unsupported_ssh_no_git", "git_unsupported_ssh_exec" -> R.string.sync_git_ssh_no_git
            "git_unsupported_ssh_unavailable", "git_unsupported_ssh" -> R.string.sync_git_ssh_unavailable
            else -> if (value.startsWith(GIT_UNSUPPORTED_PREFIX)) R.string.sync_git_not_usable else R.string.sync_git_rejected
        }
    }

    @StringRes
    private fun haltReason(reason: SyncHaltReason, isGit: Boolean): Int = when (reason) {
        SyncHaltReason.MassDeletion -> R.string.sync_halt_reason_mass_deletion
        SyncHaltReason.AccountChanged -> R.string.sync_halt_reason_account_changed
        SyncHaltReason.CheckpointUnreadable -> R.string.sync_halt_reason_checkpoint
        SyncHaltReason.RemoteDataReset -> if (isGit) R.string.sync_halt_reason_remote_reset_git else R.string.sync_halt_reason_remote_reset
        SyncHaltReason.BackendRefused -> R.string.sync_halt_reason_backend_refused
        SyncHaltReason.LocalLibraryQuarantined -> R.string.sync_halt_reason_quarantined
        SyncHaltReason.VaultUnreadable -> R.string.sync_halt_reason_vault_unreadable
        SyncHaltReason.ManifestIntegrityFailed -> R.string.sync_halt_reason_integrity
        SyncHaltReason.SchemaTooNew -> R.string.sync_halt_reason_schema_too_new
    }

    @StringRes
    private fun haltGuidance(reason: SyncHaltReason): Int? = when (reason) {
        SyncHaltReason.MassDeletion -> R.string.sync_halt_guidance_mass_deletion
        SyncHaltReason.AccountChanged -> R.string.sync_halt_guidance_account_changed
        SyncHaltReason.CheckpointUnreadable -> R.string.sync_halt_guidance_checkpoint
        SyncHaltReason.RemoteDataReset -> R.string.sync_halt_guidance_remote_reset
        SyncHaltReason.BackendRefused -> R.string.sync_halt_guidance_backend_refused
        SyncHaltReason.LocalLibraryQuarantined -> R.string.sync_halt_guidance_quarantined
        SyncHaltReason.VaultUnreadable -> R.string.sync_halt_guidance_vault_unreadable
        SyncHaltReason.ManifestIntegrityFailed -> null
        SyncHaltReason.SchemaTooNew -> R.string.sync_halt_guidance_schema_too_new
    }

    private const val GIT_CODE_PREFIX = "git_"
    private const val GIT_UNSUPPORTED_PREFIX = "git_unsupported_"
    private const val CODE_INCOMPATIBLE_VERSION = "incompatible_version"
}
