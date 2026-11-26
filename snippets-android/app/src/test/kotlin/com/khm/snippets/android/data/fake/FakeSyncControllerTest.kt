package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.SyncError
import com.khm.snippets.android.data.SyncProvider
import com.khm.snippets.android.data.SyncRecoveryAction
import com.khm.snippets.android.data.SyncState
import com.khm.snippets.android.data.SyncStatus
import com.khm.snippets.android.data.errorOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FakeSyncControllerTest {
    private val controls = FakeControls()
    private val sync = FakeSyncController(controls, now = { 42.0 })
    private val git = SyncProvider.Git("github.com/me/library", "main")

    @Test
    fun aFreshControllerIsNotSetUp() = runTest {
        assertEquals(SyncStatus(), sync.status.value)
        assertEquals(SyncError.NotEnabled, sync.syncNow().errorOrNull())
        assertEquals(SyncError.NotEnabled, sync.setEnabled(true).errorOrNull())
    }

    @Test
    fun aManualRoundSyncsThenIdles() = runTest {
        sync.connect(git)
        controls.latencyMillis = 1_000
        launch { sync.syncNow() }
        runCurrent()
        assertEquals(SyncState.Syncing, sync.status.value.state)
        advanceUntilIdle()
        assertEquals(SyncState.Idle(42.0), sync.status.value.state)
        assertEquals(1, sync.manualRounds)
    }

    @Test
    fun theNextRoundStateIsUsedOnce() = runTest {
        sync.connect(git)
        sync.nextRoundState = SyncState.Offline(null)
        assertEquals(SyncError.RoundFailed, sync.syncNow().errorOrNull())
        assertEquals(SyncState.Offline(null), sync.status.value.state)
        sync.syncNow()
        assertEquals(SyncState.Idle(42.0), sync.status.value.state)
    }

    @Test
    fun turningOnAndOff() = runTest {
        sync.connect(git, enabled = false)
        assertFalse(sync.status.value.isEnabled)
        sync.setEnabled(true)
        assertTrue(sync.status.value.isEnabled)
        assertTrue(sync.status.value.hasFetchedLibrary)
        sync.setEnabled(false)
        assertEquals(SyncState.Off, sync.status.value.state)
    }

    @Test
    fun onlyTheOfferedRecoveryRuns() = runTest {
        sync.setStatus(SyncStatus(isEnabled = true, provider = git, state = SyncState.Off, recoveryAction = SyncRecoveryAction.RetrySync))
        assertEquals(SyncError.ActionUnavailable, sync.performRecovery(SyncRecoveryAction.CheckAgain).errorOrNull())
        sync.performRecovery(SyncRecoveryAction.RetrySync)
        assertEquals(listOf(SyncRecoveryAction.RetrySync), sync.performedRecoveries)
        assertEquals(null, sync.status.value.recoveryAction)
    }
}
