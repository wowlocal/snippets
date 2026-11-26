package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.BodyPurpose
import com.khm.snippets.android.data.VaultDetails
import com.khm.snippets.android.data.VaultError
import com.khm.snippets.android.data.VaultLockCause
import com.khm.snippets.android.data.VaultOwner
import com.khm.snippets.android.data.VaultResult
import com.khm.snippets.android.data.VaultState
import com.khm.snippets.android.data.VaultUnavailableCause
import com.khm.snippets.android.platform.AuthReason
import com.khm.snippets.android.platform.AuthResult
import com.khm.snippets.android.platform.FakeDeviceAuthenticator
import com.khm.snippets.android.testing.id
import com.khm.snippets.android.testing.monotonicClock
import com.khm.snippets.android.testing.seed
import com.khm.snippets.android.testing.snippet
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FakeSecureVaultTest {
    private val store = FakeLibraryStore()
    private val authenticator = FakeDeviceAuthenticator()

    private fun TestScope.vault(): FakeSecureVault =
        FakeSecureVault(store, authenticator, testScheduler.monotonicClock(), backgroundScope)

    private fun TestScope.seededVault(): FakeSecureVault {
        store.seed(listOf(seed(snippet(1, name = "Token"), secureBody = "s3cret"), seed(snippet(2, name = "Plain", content = "plain body"))))
        return vault().also { it.setVault(exists = true) }
    }

    @Test
    fun statesFollowTheDevice() = runTest {
        val vault = vault()
        assertEquals(VaultState.NoVault, vault.state.value)
        vault.setVault(exists = true)
        assertEquals(VaultState.Locked(), vault.state.value)
        vault.setVault(exists = true, details = VaultDetails(owner = VaultOwner.GitLibrary), keyOnDevice = false)
        assertEquals(VaultState.KeyMissing(VaultOwner.GitLibrary), vault.state.value)
        authenticator.isDeviceSecure = false
        vault.refresh()
        assertEquals(VaultState.Unavailable(VaultUnavailableCause.NoScreenLock), vault.state.value)
        vault.setUnreadable(true)
        assertEquals(VaultState.Unavailable(VaultUnavailableCause.Unreadable), vault.state.value)
    }

    @Test
    fun revealOpensASessionThatNeedsNoSecondPrompt() = runTest {
        val vault = seededVault()
        assertEquals(VaultResult.Success("s3cret"), vault.reveal(id(1)))
        val state = vault.state.value as VaultState.Unlocked
        assertEquals(testScheduler.currentTime + FakeSecureVault.IDLE_WINDOW_MILLIS, state.deadlineMillis)
        vault.reveal(id(1))
        assertEquals(listOf<AuthReason>(AuthReason.RevealSnippet("Token")), authenticator.requests)
    }

    @Test
    fun theSessionLocksAfterFiveIdleMinutes() = runTest {
        val vault = seededVault()
        vault.reveal(id(1))
        advanceTimeBy(FakeSecureVault.IDLE_WINDOW_MILLIS - 1)
        runCurrent()
        assertTrue(vault.state.value is VaultState.Unlocked)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(VaultState.Locked(lastLock = VaultLockCause.IdleTimeout), vault.state.value)
    }

    @Test
    fun theSessionEndsAfterThirtyMinutesWhateverTheUse() = runTest {
        val vault = seededVault()
        vault.reveal(id(1))
        repeat(7) {
            advanceTimeBy(4 * 60_000L)
            runCurrent()
            vault.updateBody(id(1), "edit $it")
        }
        advanceTimeBy(FakeSecureVault.MAXIMUM_WINDOW_MILLIS - testScheduler.currentTime)
        runCurrent()
        assertEquals(VaultState.Locked(lastLock = VaultLockCause.SessionExpired), vault.state.value)
    }

    @Test
    fun aOneUseBodyAuthenticatesEveryTimeAndEndsTheSession() = runTest {
        val vault = seededVault()
        vault.reveal(id(1))
        val result = vault.withBodyOnce(id(1), BodyPurpose.Copy) { it.length }
        assertEquals(VaultResult.Success(6), result)
        assertEquals(AuthReason.CopySnippet("Token"), authenticator.requests.last())
        assertEquals(VaultState.Locked(lastLock = VaultLockCause.OneUseAuthentication), vault.state.value)
        vault.withBodyOnce(id(1), BodyPurpose.Copy) { }
        assertEquals(3, authenticator.requests.size)
    }

    @Test
    fun aCancelledPromptIsNotAFailure() = runTest {
        val vault = seededVault()
        authenticator.answer = AuthResult.Cancelled
        assertEquals(VaultResult.Cancelled, vault.reveal(id(1)))
        assertEquals(VaultResult.Cancelled, vault.withBodyOnce(id(1), BodyPurpose.Copy) { })
        authenticator.answer = AuthResult.NotApproved
        assertEquals(VaultResult.Failure(VaultError.AuthenticationNotApproved), vault.reveal(id(1)))
        authenticator.answer = AuthResult.Blocked("Too many attempts")
        assertEquals(VaultResult.Failure(VaultError.AuthenticationBlocked("Too many attempts")), vault.reveal(id(1)))
    }

    @Test
    fun updateBodyNeedsAnOpenSession() = runTest {
        val vault = seededVault()
        assertEquals(VaultResult.Failure(VaultError.Locked), vault.updateBody(id(1), "x"))
        vault.reveal(id(1))
        assertEquals(VaultResult.Success(Unit), vault.updateBody(id(1), "x"))
        assertEquals("x", store.read { secure.getValue(id(1)).body })
    }

    @Test
    fun preLockHooksRunWhileTheKeyIsStillUsable() = runTest {
        val vault = seededVault()
        vault.reveal(id(1))
        var stateInHook: VaultState? = null
        val handle = vault.addPreLockHook {
            stateInHook = vault.state.value
            vault.updateBody(id(1), "saved by hook")
        }
        vault.lock(VaultLockCause.Manual)
        assertTrue(stateInHook is VaultState.Unlocked)
        assertEquals("saved by hook", store.read { secure.getValue(id(1)).body })
        assertEquals(VaultState.Locked(lastLock = VaultLockCause.Manual), vault.state.value)
        handle.close()
    }

    @Test
    fun makeSecureAndMakeOrdinaryKeepTheId() = runTest {
        val vault = seededVault()
        assertEquals(VaultResult.Success(Unit), vault.makeSecure(id(2)))
        val shell = store.snapshot.value.entry(id(2))!!
        assertTrue(shell.isSecure)
        assertEquals("", shell.snippet.content)
        assertEquals("plain body", store.read { secure.getValue(id(2)).body })
        assertEquals(VaultResult.Success(Unit), vault.makeOrdinary(id(2)))
        val ordinary = store.snapshot.value.entry(id(2))!!
        assertFalse(ordinary.isSecure)
        assertEquals("plain body", ordinary.snippet.content)
    }

    @Test
    fun makeSecureWithoutAVaultNeedsSetup() = runTest {
        store.seed(listOf(seed(snippet(2, content = "body"))))
        val vault = vault()
        assertEquals(VaultResult.Failure(VaultError.NoKey), vault.makeSecure(id(2)))
        vault.gitVaultSetupRequired = true
        assertEquals(VaultResult.Failure(VaultError.GitVaultSetupRequired), vault.prepareVaultSetup())
    }

    @Test
    fun vaultSetupIsPreparedThenCommitted() = runTest {
        val vault = vault()
        val pending = (vault.prepareVaultSetup() as VaultResult.Success).value
        assertNotNull(pending)
        assertEquals(VaultState.NoVault, vault.state.value)
        assertEquals(VaultResult.Success(Unit), vault.commitVaultSetup(pending!!))
        assertEquals(VaultState.Locked(), vault.state.value)
        assertNull((vault.prepareVaultSetup() as VaultResult.Success).value)
    }

    @Test
    fun aDiscardedSetupCannotBeCommitted() = runTest {
        val vault = vault()
        val pending = (vault.prepareVaultSetup() as VaultResult.Success).value!!
        vault.discard(pending)
        assertEquals(VaultResult.Failure(VaultError.SetupChanged), vault.commitVaultSetup(pending))
    }

    @Test
    fun withoutAScreenLockNothingPrompts() = runTest {
        val vault = seededVault()
        authenticator.isDeviceSecure = false
        assertEquals(VaultResult.Failure(VaultError.ScreenLockRequired), vault.reveal(id(1)))
        assertEquals(VaultResult.Failure(VaultError.ScreenLockRequired), vault.prepareVaultSetup())
        assertTrue(authenticator.requests.isEmpty())
    }

    @Test
    fun restoreKeyChecksTheTypedKey() = runTest {
        store.seed(emptyList())
        val vault = vault()
        vault.setVault(exists = true, keyOnDevice = false)
        assertEquals(VaultResult.Failure(VaultError.RecoveryKeyWrongLength(27, 3)), vault.restoreKey("abc"))
        assertEquals(VaultResult.Failure(VaultError.RecoveryKeyMismatch), vault.restoreKey("A".repeat(27)))
        assertEquals(VaultResult.Success(Unit), vault.restoreKey("7k2m-9qxd-4ftr-hv3n-p8wc-6yja-b5g"))
        assertEquals(VaultState.Locked(), vault.state.value)
    }
}
