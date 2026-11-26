package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.Outcome
import com.khm.snippets.android.data.SyncController
import com.khm.snippets.android.data.SyncError
import com.khm.snippets.android.data.SyncProvider
import com.khm.snippets.android.data.SyncRecoveryAction
import com.khm.snippets.android.data.SyncState
import com.khm.snippets.android.data.SyncStatus
import com.khm.snippets.core.clock.AppleTime
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * [SyncController] that syncs nothing. A fresh one is "not set up"; tests and the debug launch
 * switch it to any state with [setStatus] or [connect].
 */
class FakeSyncController(
    private val controls: FakeControls = FakeControls(),
    private val now: () -> Double = AppleTime::now,
) : SyncController {
    private val current = MutableStateFlow(SyncStatus())

    /** What the next manual round ends in instead of `Idle(now)`; consumed by that round. */
    @Volatile var nextRoundState: SyncState? = null

    /** Number of manual rounds started, for assertions. */
    @Volatile var manualRounds: Int = 0
        private set

    /** Recovery actions performed, oldest first. */
    val performedRecoveries: MutableList<SyncRecoveryAction> = ArrayList()

    override val status: StateFlow<SyncStatus> = current.asStateFlow()

    fun setStatus(status: SyncStatus) {
        current.value = status
    }

    /** A provider is set up; [enabled] turns `Sync This Library` on with a finished first round. */
    fun connect(provider: SyncProvider, enabled: Boolean = true) {
        current.value = if (enabled) {
            SyncStatus(isEnabled = true, provider = provider, state = SyncState.Idle(now()), hasFetchedLibrary = true)
        } else {
            SyncStatus(isEnabled = false, provider = provider, state = SyncState.Off)
        }
    }

    override suspend fun syncNow(): Outcome<Unit, SyncError> {
        val before = current.value
        if (!before.isEnabled || before.provider == null) return Outcome.Failure(SyncError.NotEnabled)
        manualRounds += 1
        current.update { it.copy(state = SyncState.Syncing) }
        controls.pause()
        val end = nextRoundState ?: SyncState.Idle(now())
        nextRoundState = null
        current.update {
            it.copy(state = end, hasFetchedLibrary = it.hasFetchedLibrary || (end is SyncState.Idle && end.lastSyncedAt != null))
        }
        return if (end is SyncState.Idle) Outcome.Success(Unit) else Outcome.Failure(SyncError.RoundFailed)
    }

    override suspend fun performRecovery(action: SyncRecoveryAction): Outcome<Unit, SyncError> {
        if (current.value.recoveryAction != action) return Outcome.Failure(SyncError.ActionUnavailable)
        controls.pause()
        performedRecoveries += action
        current.update { it.copy(state = SyncState.Idle(now()), recoveryAction = null, hasFetchedLibrary = true) }
        return Outcome.Success(Unit)
    }

    override suspend fun setEnabled(enabled: Boolean): Outcome<Unit, SyncError> {
        val before = current.value
        if (!enabled) {
            current.value = before.copy(isEnabled = false, state = SyncState.Off, recoveryAction = null)
            return Outcome.Success(Unit)
        }
        if (before.provider == null) return Outcome.Failure(SyncError.NotEnabled)
        current.value = before.copy(isEnabled = true, state = SyncState.Starting)
        return syncNow()
    }
}
