package com.khm.snippets.android.data

import kotlinx.coroutines.flow.StateFlow

/** The provider that is set up on this device. */
sealed interface SyncProvider {
    /** @param location Host and path, for example `github.com/me/library`. */
    data class Git(val location: String, val branch: String, val isPlainText: Boolean = false) : SyncProvider

    data class SnippetsCloud(val libraryId: String) : SyncProvider
}

/** A closed failure code of the sync layer (`git_http_401`, `quota_exceeded`, …). The UI phrases it. */
@JvmInline
value class SyncFailureCode(val value: String)

/** Why sync cannot start. */
enum class SyncStartIssue {
    NewerLocalState,
    CheckpointUnreadable,
    GitKeyRequired,
    GitTokenMissing,
    GitNotConnected,
    GitKeyUnverified,
}

/** Why sync waits for the vault. */
enum class VaultWait {
    /** A secure snippet changed on two devices and the key is here: unlock, then sync. */
    SecureConflict,

    /** The Git library's vault is not set up on this device. */
    GitVaultNotSetUp,
    Other,
}

/** Why sync halted (screens-settings-data.md §6). [code] is shown under Details. */
enum class SyncHaltReason(val code: String) {
    MassDeletion("mass_deletion"),
    AccountChanged("account_changed"),
    CheckpointUnreadable("checkpoint_unreadable"),
    RemoteDataReset("remote_data_reset"),
    BackendRefused("backend_refused"),
    LocalLibraryQuarantined("local_library_quarantined"),
    VaultUnreadable("vault_unreadable"),
    ManifestIntegrityFailed("manifest_integrity_failed"),
    SchemaTooNew("schema_too_new"),
}

/** The numbers of a deletion batch that stopped sync. */
data class DeletionReview(val deleting: Int, val total: Int, val keeps: Int, val allowedWithoutConfirmation: Int)

/** The engine state behind the status sentence. Times are seconds since 2001 (`AppleTime`). */
sealed interface SyncState {
    data object Off : SyncState
    data class CannotStart(val issue: SyncStartIssue) : SyncState
    data object Starting : SyncState
    data class Idle(val lastSyncedAt: Double?) : SyncState
    data object Syncing : SyncState
    data class Offline(val retryAt: Double?) : SyncState
    data class NeedsAuthentication(val code: SyncFailureCode) : SyncState
    data class NeedsAttention(val code: SyncFailureCode) : SyncState
    data class WaitingForVault(val wait: VaultWait) : SyncState
    data class Halted(val reason: SyncHaltReason, val deletion: DeletionReview? = null) : SyncState
}

/** What the user can do about a stopped sync. */
enum class SyncRecoveryAction(val needsConfirmation: Boolean) {
    ApplyRemoteDeletions(true),
    RefreshDeletionReview(false),
    UseCurrentAccount(true),
    RepairCheckpoint(false),
    RestoreCloudFromThisDevice(true),
    ReclaimRecovery(true),
    RetrySync(false),
    CheckAgain(false),
}

/**
 * Everything the UI shows about sync.
 *
 * @param isEnabled The `Sync This Library` preference. "Local only" is this being false.
 * @param provider Null on a fresh install: nothing is set up.
 * @param hasFetchedLibrary True once one round ended idle with a sync date; until then an empty
 *   library shows the first-fetch state instead of the empty state.
 * @param recoveryAction The action a halt or start issue offers, or null.
 */
data class SyncStatus(
    val isEnabled: Boolean = false,
    val provider: SyncProvider? = null,
    val state: SyncState = SyncState.Off,
    val hasFetchedLibrary: Boolean = false,
    val recoveryAction: SyncRecoveryAction? = null,
) {
    /** Sync Now is offered while sync runs normally. */
    val canSyncManually: Boolean
        get() = isEnabled && recoveryAction == null &&
            (state is SyncState.Starting || state is SyncState.Idle || state is SyncState.Syncing || state is SyncState.Offline)

    val needsAttention: Boolean
        get() = state is SyncState.NeedsAuthentication || state is SyncState.NeedsAttention ||
            state is SyncState.CannotStart || state is SyncState.WaitingForVault || state is SyncState.Halted
}

sealed interface SyncError {
    /** Sync is off or no provider is set up. */
    data object NotEnabled : SyncError

    /** The round ended in the state [SyncController.status] now shows. */
    data object RoundFailed : SyncError

    /** The recovery action no longer applies. */
    data object ActionUnavailable : SyncError
}

/** Sync as the library and Settings drive it. The library never waits for any of this. */
interface SyncController {
    val status: StateFlow<SyncStatus>

    /** One manual round (Sync Now, pull to refresh): not paced, returns when the round ends. */
    suspend fun syncNow(): Outcome<Unit, SyncError>

    /** Runs a recovery action the user chose (and confirmed where it needs confirmation). */
    suspend fun performRecovery(action: SyncRecoveryAction): Outcome<Unit, SyncError>

    /**
     * The opt-in: turns `Sync This Library` on (merging the local library with the provider's)
     * or off. Turning it on needs a provider.
     */
    suspend fun setEnabled(enabled: Boolean): Outcome<Unit, SyncError>
}
