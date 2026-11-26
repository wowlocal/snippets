package com.khm.snippets.core.vault

import com.khm.snippets.core.crypto.filled
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Test
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The session state machine, driven by a fake clock and a scripted device owner. Ports
 * the session tests of `snippets-ios-tests/SecureRemediationTests.swift` (Swift names
 * kept), the idea of `Tests/Harnesses/VaultSessionAutoLockTest.swift`, and
 * `idle_and_absolute_timeouts_expire_keys…` of `snippets-linux/src/vault.rs`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class VaultSessionTest {

    private val kid = "k-session-test"
    private val key = filled(0xA5, 32)
    private val reason = VaultAuthenticationReason.Reveal("a snippet")

    private val idle = VaultSession.DEFAULT_IDLE_WINDOW_MILLIS
    private val maximum = VaultSession.MAXIMUM_WINDOW_MILLIS
    private val minute = 60_000L

    private inner class Fixture(idleWindowMillis: Long = idle, expiryScope: CoroutineScope? = null, clock: MonotonicClock? = null) {
        val keys = FaultyKeyStore()
        val owner = FakeAuthenticator()
        val time = FakeClock()
        val session = VaultSession(keys, owner, clock ?: time, idleWindowMillis, expiryScope, EmptyCoroutineContext)

        init {
            keys.inner.store(key, kid)
            session.adopt(kid)
        }

        fun readsKey(): Boolean = try {
            session.currentKey().fill(0)
            true
        } catch (_: VaultSession.Failure.Locked) {
            false
        }
    }

    // Unlocking and the open window

    @Test fun unlockAuthenticatesOnceAndASecondUnlockInsideTheWindowDoesNotPrompt() = runTest {
        val f = Fixture()
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertNull(f.session.deadlineMillis)

        val first = f.session.unlock(reason)
        assertContentEquals(key, first)
        assertEquals(VaultSession.State.UNLOCKED, f.session.state.value)
        assertEquals(f.time.now + idle, f.session.deadlineMillis)

        f.time.advance(4 * minute)
        assertContentEquals(key, f.session.unlock(reason))
        assertEquals(1, f.owner.count.get())
        assertEquals(listOf("load:$kid"), f.keys.log)
        // A reveal inside the window is use: it slides the idle deadline.
        assertEquals(f.time.now + idle, f.session.deadlineMillis)
    }

    @Test fun everyKeyHandedOutIsACopyAndLockingWipesNothingTheCallerHolds() = runTest {
        val f = Fixture()
        val first = f.session.unlock(reason)
        first.fill(0)
        assertContentEquals(key, f.session.currentKey(), "wiping a returned copy must not damage the session's key")

        val held = f.session.currentKey()
        f.session.lock()
        assertContentEquals(key, held, "the caller owns its copy; only the session's own key is wiped")
        assertFailsWith<VaultSession.Failure.Locked> { f.session.keyring(filled(0x22, 32)) }
    }

    @Test fun aLockedSessionHandsOutNothing() = runTest {
        val f = Fixture()
        assertFailsWith<VaultSession.Failure.Locked> { f.session.currentKey() }
        assertFailsWith<VaultSession.Failure.Locked> { f.session.currentKeyWithoutExtendingSession() }
        assertFailsWith<VaultSession.Failure.Locked> { f.session.keyring(filled(0x22, 32)) }
        assertFailsWith<VaultSession.Failure.Locked> { f.session.keyringWithoutExtendingSession(filled(0x22, 32)) }
        assertEquals(0, f.owner.count.get(), "reading the current key must never prompt")
    }

    // Deadlines

    /** `testVaultUseSlidesFiveMinuteIdleDeadlineButNeverPastAuthenticationCap` */
    @Test fun testVaultUseSlidesFiveMinuteIdleDeadlineButNeverPastAuthenticationCap() = runTest {
        val f = Fixture()
        var unlockedTransitions = 0
        f.session.addStateListener { if (it == VaultSession.State.UNLOCKED) unlockedTransitions += 1 }

        val authenticatedAt = f.time.now
        f.session.unlock(reason).fill(0)
        assertEquals(1, f.owner.count.get())
        assertEquals(authenticatedAt + idle, f.session.deadlineMillis)
        assertEquals(1, unlockedTransitions)

        // Each access is before the current idle deadline. It slides the deadline without
        // announcing a state change, which would make the editor read again, recursively.
        for (elapsedMinutes in 4..28 step 4) {
            f.time.now = authenticatedAt + elapsedMinutes * minute
            f.session.currentKey().fill(0)
            assertEquals(minOf(f.time.now + idle, authenticatedAt + maximum), f.session.deadlineMillis)
        }

        f.time.now = authenticatedAt + maximum - 1000
        f.session.currentKey().fill(0)
        assertEquals(authenticatedAt + maximum, f.session.deadlineMillis)
        assertEquals(1, f.owner.count.get())
        assertEquals(1, unlockedTransitions)

        f.time.now = authenticatedAt + maximum
        assertFailsWith<VaultSession.Failure.Locked> { f.session.currentKey() }
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
    }

    @Test fun anIdleSessionExpiresAfterFiveMinutes() = runTest {
        val f = Fixture()
        val start = f.time.now
        f.session.unlock(reason).fill(0)

        f.time.now = start + idle - 1
        assertTrue(f.session.isUnlocked)
        // Nothing has asked for the key, so nothing has slid the deadline.
        assertEquals(start + idle, f.session.deadlineMillis)

        f.time.now = start + idle
        assertFalse(f.readsKey())
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertNull(f.session.deadlineMillis)
    }

    /** `testBackgroundKeyReadChecksButDoesNotSlideIdleDeadline` */
    @Test fun testBackgroundKeyReadChecksButDoesNotSlideIdleDeadline() = runTest {
        val f = Fixture()
        val authenticatedAt = f.time.now
        f.session.unlock(reason).fill(0)
        val originalDeadline = f.session.deadlineMillis

        f.time.now = authenticatedAt + 4 * minute
        assertContentEquals(key, f.session.currentKeyWithoutExtendingSession())
        f.session.keyringWithoutExtendingSession(filled(0x22, 32)).close()
        assertEquals(originalDeadline, f.session.deadlineMillis)

        f.time.now = originalDeadline!!
        assertFailsWith<VaultSession.Failure.Locked> { f.session.currentKeyWithoutExtendingSession() }
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertEquals(1, f.owner.count.get(), "background work must never prompt")
    }

    /** Busy background traffic alone cannot keep an unattended vault open. */
    @Test fun repeatedBackgroundReadsNeverKeepTheVaultOpen() = runTest {
        val f = Fixture()
        val start = f.time.now
        f.session.unlock(reason).fill(0)
        var reads = 0
        while (true) {
            f.time.advance(30_000)
            try {
                f.session.currentKeyWithoutExtendingSession().fill(0)
                reads += 1
            } catch (_: VaultSession.Failure.Locked) {
                break
            }
        }
        assertEquals(9, reads)
        assertEquals(start + idle, f.time.now)
    }

    /** `testExpiredDeadlineIsAuthoritativeWhenTimerDeliveryIsDelayed`: there is no timer here at all. */
    @Test fun testExpiredDeadlineIsAuthoritativeWhenTimerDeliveryIsDelayed() = runTest {
        val f = Fixture(idleWindowMillis = minute)
        val start = f.time.now
        f.session.unlock(reason).fill(0)

        f.time.now = start + minute
        // The published state still says unlocked: nothing has run. The access is what finds out.
        assertEquals(VaultSession.State.UNLOCKED, f.session.state.value)
        assertFailsWith<VaultSession.Failure.Locked> { f.session.currentKey() }
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
    }

    @Test fun anUnlockAfterTheDeadlinePromptsAgainAndStartsANewHalfHour() = runTest {
        val f = Fixture()
        val start = f.time.now
        f.session.unlock(reason).fill(0)
        for (elapsed in 4..28 step 4) {
            f.time.now = start + elapsed * minute
            f.session.currentKey().fill(0)
        }
        f.time.now = start + maximum + 1
        f.session.unlock(reason).fill(0)

        assertEquals(2, f.owner.count.get())
        // The ceiling is measured from the new authentication, not inherited from the exhausted one.
        assertEquals(f.time.now + idle, f.session.deadlineMillis)
        f.time.advance(4 * minute)
        f.session.currentKey().fill(0)
        assertEquals(f.time.now + idle, f.session.deadlineMillis)
    }

    /** With a scope, a coroutine locks at the deadline although nobody asked for the key. */
    @Test fun theOptionalTimerLocksAtTheDeadlineWithoutAnyAccess() = runTest {
        val scheduler = testScheduler
        val f = Fixture(expiryScope = backgroundScope, clock = MonotonicClock { scheduler.currentTime })
        val states = ArrayList<VaultSession.State>()
        f.session.addStateListener { states.add(it) }

        f.session.unlock(reason).fill(0)
        advanceTimeBy(idle - 1)
        runCurrent()
        assertTrue(f.session.isUnlocked)

        advanceTimeBy(1)
        runCurrent()
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertEquals(listOf(VaultSession.State.UNLOCKED, VaultSession.State.LOCKED), states)
    }

    @Test fun theTimerFollowsASlidingDeadlineAndStopsAtTheCeiling() = runTest {
        val scheduler = testScheduler
        val f = Fixture(expiryScope = backgroundScope, clock = MonotonicClock { scheduler.currentTime })
        f.session.unlock(reason).fill(0)
        val authenticatedAt = scheduler.currentTime

        repeat(7) {
            advanceTimeBy(4 * minute)
            runCurrent()
            f.session.currentKey().fill(0)
        }
        assertEquals(authenticatedAt + 28 * minute, scheduler.currentTime)
        assertEquals(authenticatedAt + maximum, f.session.deadlineMillis)

        advanceTimeBy(2 * minute - 1)
        runCurrent()
        assertTrue(f.session.isUnlocked)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
    }

    /** The timer's clock and the deadline's clock need not agree. The deadline decides, in both directions. */
    @Test fun aTimerThatFiresEarlyDoesNotLockAndOneThatFiresLateIsNotNeeded() = runTest {
        val f = Fixture(expiryScope = backgroundScope) // the fake clock, which the scheduler does not move
        val start = f.time.now
        f.session.unlock(reason).fill(0)

        // The timer fires; the deadline has not passed.
        advanceTimeBy(idle + 1)
        runCurrent()
        assertTrue(f.session.isUnlocked, "a timer must not lock before the deadline")
        assertTrue(f.readsKey())

        // The deadline passes; no timer fires. The access finds out.
        f.time.now = start + 6 * idle
        assertFalse(f.readsKey())
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
    }

    // Pre-lock flush

    /** `testVaultWillLockHookCanUseKeyAfterDeadlineBeforeKeyIsDestroyed` */
    @Test fun testVaultWillLockHookCanUseKeyAfterDeadlineBeforeKeyIsDestroyed() = runTest {
        val f = Fixture(idleWindowMillis = 1000)
        val events = ArrayList<String>()
        var keyWasReadableInHook = false
        var keyWasGoneAtPostLock = false
        f.session.addPreLockHook {
            events.add("pre-lock")
            keyWasReadableInHook = f.readsKey()
        }
        f.session.addStateListener { state ->
            if (state != VaultSession.State.UNLOCKED) {
                events.add("locked")
                keyWasGoneAtPostLock = !f.readsKey()
            }
        }

        f.session.unlock(reason).fill(0)
        f.time.advance(2000) // past the deadline: a late timer

        f.session.lock()

        assertEquals(listOf("pre-lock", "locked"), events, "the flush hook must run before the key is destroyed")
        assertTrue(keyWasReadableInHook, "an editor must get its one chance to save, even past the deadline")
        assertTrue(keyWasGoneAtPostLock)
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertFalse(f.readsKey())

        // Locking a locked session is not an occasion to save.
        f.session.lock()
        assertEquals(listOf("pre-lock", "locked"), events)
    }

    @Test fun theDeadlinesOwnLockAlsoGivesTheHookTheKey() = runTest {
        val f = Fixture(idleWindowMillis = 1000)
        var flushed = false
        f.session.addPreLockHook { flushed = f.readsKey() }
        f.session.unlock(reason).fill(0)
        f.time.advance(1000)

        assertFailsWith<VaultSession.Failure.Locked> { f.session.currentKey() }
        assertTrue(flushed, "the access that discovers the expiry must still let the editor save")
    }

    @Test fun aFailingHookCannotKeepTheVaultOpenAndAClosedHandleIsNotCalled() = runTest {
        val f = Fixture()
        var removedCalls = 0
        val handle = f.session.addPreLockHook { removedCalls += 1 }
        f.session.addPreLockHook { error("editor crashed") }
        var relock = 0
        f.session.addPreLockHook {
            relock += 1
            f.session.lock() // re-entrant: must neither recurse nor deadlock
        }
        handle.close()

        f.session.unlock(reason).fill(0)
        f.session.lock()

        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertEquals(0, removedCalls)
        assertEquals(1, relock)
    }

    @Test fun hooksDoNotRunWhenAdoptionOrTheFirstHalfOfAOneUseAuthenticationLocksAClosedSession() = runTest {
        val f = Fixture()
        var hookRuns = 0
        f.session.addPreLockHook { hookRuns += 1 }

        f.session.adopt(null)
        f.session.adopt(kid)
        f.session.withOneUseAuthentication(reason) { }
        assertEquals(1, hookRuns, "only the lock that ends the one-use window closes an open session")
    }

    // Lifecycle

    /** `testIOSResignActiveKeepsExpansionWindowButBackgroundLocksImmediately`: the app calls `lock()` on background only. */
    @Test fun testBackgroundLocksImmediatelyAndFocusLossIsNotALockTrigger() = runTest {
        val f = Fixture()
        f.session.unlock(reason).fill(0)

        // Focus loss (the system authentication sheet, the share sheet) has no entry point here by design.
        assertTrue(f.session.isUnlocked)
        assertTrue(f.readsKey())

        f.session.lock() // ProcessLifecycleOwner ON_STOP
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertFalse(f.readsKey())
    }

    /** `testSameVaultForegroundReloadPreservesAuthenticationAndUnlockedSession` */
    @Test fun testSameVaultForegroundReloadPreservesAuthenticationAndUnlockedSession() = runTest {
        val f = Fixture()
        f.owner.started = CompletableDeferred()
        f.owner.gate = CompletableDeferred()

        val unlock = async { f.session.unlock(reason) }
        f.owner.started!!.await()

        // A reload on returning to the foreground races the tail of the prompt.
        f.session.adopt(kid)
        f.owner.gate!!.complete(VaultAuthenticationResult.SUCCESS)
        assertContentEquals(key, unlock.await())
        assertTrue(f.session.isUnlocked)

        // And a second reload right after the prompt must not destroy the session it opened.
        f.session.adopt(kid)
        assertTrue(f.session.isUnlocked)
        assertTrue(f.readsKey())
    }

    /** `testBackgroundLockCancelsAuthenticationInFlightWithoutKeyResurrection` */
    @Test fun testBackgroundLockCancelsAuthenticationInFlightWithoutKeyResurrection() = runTest {
        val f = Fixture()
        f.owner.started = CompletableDeferred()
        f.owner.gate = CompletableDeferred()

        val unlock = async { runCatching { f.session.unlock(reason) } }
        f.owner.started!!.await()

        f.session.lock()
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)

        f.owner.gate!!.complete(VaultAuthenticationResult.SUCCESS)
        assertIs<VaultSession.Failure.Locked>(unlock.await().exceptionOrNull(), "a completed prompt must not reopen a session after a lock")
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertFalse(f.readsKey())
        assertEquals(emptyList(), f.keys.log, "the key must not even be read after the lock")
    }

    @Test fun adoptingAnotherVaultWhileAPromptIsUpInvalidatesThePrompt() = runTest {
        val f = Fixture()
        f.keys.inner.store(filled(0x5A, 32), "k-other")
        f.owner.started = CompletableDeferred()
        f.owner.gate = CompletableDeferred()

        val unlock = async { runCatching { f.session.unlock(reason) } }
        f.owner.started!!.await()
        f.session.adopt("k-other")
        f.owner.gate!!.complete(VaultAuthenticationResult.SUCCESS)

        assertIs<VaultSession.Failure.Locked>(unlock.await().exceptionOrNull())
        assertEquals(emptyList(), f.keys.log, "the old vault's key must not be loaded into a session that moved on")
    }

    @Test fun adoptingADifferentVaultLocksAnOpenSession() = runTest {
        val f = Fixture()
        f.keys.inner.store(filled(0x5A, 32), "k-other")
        f.session.unlock(reason).fill(0)

        f.session.adopt("k-other")
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertFalse(f.readsKey())

        assertContentEquals(filled(0x5A, 32), f.session.unlock(reason))
    }

    // Prompts are never stacked

    @Test fun aSecondCallerWhileAPromptIsUpGetsLockedAndTheFirstPromptSurvives() = runTest {
        val f = Fixture()
        f.owner.started = CompletableDeferred()
        f.owner.gate = CompletableDeferred()

        val first = async { f.session.unlock(reason) }
        f.owner.started!!.await()

        assertFailsWith<VaultSession.Failure.Locked> { f.session.unlock(reason) }
        // A one-use authentication must not cancel somebody else's visible prompt either.
        assertFailsWith<VaultSession.Failure.Locked> { f.session.withOneUseAuthentication(reason) { } }
        assertEquals(1, f.owner.count.get())

        f.owner.gate!!.complete(VaultAuthenticationResult.SUCCESS)
        assertContentEquals(key, first.await())
        assertTrue(f.session.isUnlocked)
    }

    @Test fun cancellingTheCallerDuringAPromptLeavesTheSessionLockedAndAbleToPromptAgain() = runTest {
        val f = Fixture()
        f.owner.started = CompletableDeferred()
        f.owner.gate = CompletableDeferred()

        val job = launch { f.session.unlock(reason) }
        f.owner.started!!.await()
        job.cancel()
        job.join()
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)

        f.owner.gate = null
        assertContentEquals(key, f.session.unlock(reason))
        assertEquals(2, f.owner.count.get())
    }

    // One-use authentication

    @Test fun oneUseAuthenticationAlwaysPromptsAndLocksBeforeAndAfter() = runTest {
        val f = Fixture()
        val states = ArrayList<VaultSession.State>()
        f.session.addStateListener { states.add(it) }

        // An open reveal session does not excuse the prompt, and is ended by it.
        f.session.unlock(reason).fill(0)
        var flushedBeforePrompt = false
        f.session.addPreLockHook { flushedBeforePrompt = true }
        val copied = f.session.withOneUseAuthentication(VaultAuthenticationReason.Copy("AWS")) {
            assertTrue(f.session.isUnlocked)
            f.session.currentKey()
        }

        assertContentEquals(key, copied)
        assertEquals(2, f.owner.count.get())
        assertTrue(flushedBeforePrompt, "ending the open session must let the editor save first")
        assertEquals(
            listOf(
                VaultSession.State.UNLOCKED, VaultSession.State.LOCKED,
                VaultSession.State.UNLOCKED, VaultSession.State.LOCKED,
            ),
            states,
        )
        assertFalse(f.readsKey(), "a one-use authentication must leave nothing open")

        // And it asks every single time.
        f.session.withOneUseAuthentication(VaultAuthenticationReason.Copy("AWS")) { }
        assertEquals(3, f.owner.count.get())
    }

    @Test fun oneUseAuthenticationLocksOnEveryExit() = runTest {
        val f = Fixture()

        assertFailsWith<IllegalStateException> {
            f.session.withOneUseAuthentication(reason) { error("the operation failed") }
        }
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)

        f.owner.result = VaultAuthenticationResult.CANCELLED
        var ran = false
        val failure = assertFailsWith<VaultSession.Failure.Authentication> {
            f.session.withOneUseAuthentication(reason) { ran = true }
        }
        assertEquals(VaultAuthenticationResult.CANCELLED, failure.result)
        assertFalse(ran)
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)

        // Cancelled while the prompt is up.
        f.owner.result = VaultAuthenticationResult.SUCCESS
        f.owner.started = CompletableDeferred()
        f.owner.gate = CompletableDeferred()
        val job = launch { f.session.withOneUseAuthentication(reason) { ran = true } }
        f.owner.started!!.await()
        job.cancel()
        job.join()
        assertFalse(ran)
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
    }

    // The device owner says no

    @Test fun everyRefusalIsATypedFailureAndTheKeyStoreIsNeverAsked() = runTest {
        for (result in VaultAuthenticationResult.values().filter { it != VaultAuthenticationResult.SUCCESS }) {
            val f = Fixture()
            f.owner.result = result
            val failure = assertFailsWith<VaultSession.Failure.Authentication> { f.session.unlock(reason) }
            assertEquals(result, failure.result)
            assertEquals(VaultSession.State.LOCKED, f.session.state.value)
            assertEquals(emptyList(), f.keys.log, "$result: the key was read without an authentication")

            // The refusal is over: the next attempt prompts again and can succeed.
            f.owner.result = VaultAuthenticationResult.SUCCESS
            assertContentEquals(key, f.session.unlock(reason))
        }
    }

    @Test fun anAuthenticatorThatThrowsCountsAsAFailedAttempt() = runTest {
        val f = Fixture()
        f.owner.throwing = IllegalStateException("the prompt could not be shown")
        val failure = assertFailsWith<VaultSession.Failure.Authentication> { f.session.unlock(reason) }
        assertEquals(VaultAuthenticationResult.FAILED, failure.result)
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)

        f.owner.throwing = CancellationException("the screen went away")
        assertFailsWith<CancellationException> { f.session.unlock(reason) }
        f.owner.throwing = null
        assertContentEquals(key, f.session.unlock(reason))
    }

    // No key, and a key store that cannot say

    @Test fun aVaultWithoutItsKeyIsNoKeyAndNeverPrompts() = runTest {
        val keys = FaultyKeyStore()
        val owner = FakeAuthenticator()
        val session = VaultSession(keys, owner, FakeClock(), keyStoreContext = EmptyCoroutineContext)

        assertFailsWith<VaultSession.Failure.NoKey> { session.unlock(reason) }

        session.adopt(null)
        assertEquals(VaultSession.State.NO_KEY, session.state.value)
        assertFailsWith<VaultSession.Failure.NoKey> { session.unlock(reason) }

        session.adopt(kid)
        assertEquals(VaultSession.State.NO_KEY, session.state.value)
        assertFailsWith<VaultSession.Failure.Locked> { session.currentKey() }
        assertEquals(0, owner.count.get())

        // The key comes back (a recovery key, a backup): the same vault is no longer keyless.
        keys.inner.store(key, kid)
        session.adopt(kid)
        assertEquals(VaultSession.State.LOCKED, session.state.value)
        assertContentEquals(key, session.unlock(reason))
    }

    @Test fun aKeyThatVanishedBetweenThePromptAndTheReadIsNoKey() = runTest {
        val f = Fixture()
        f.keys.inner.delete(kid)

        assertFailsWith<VaultSession.Failure.NoKey> { f.session.unlock(reason) }
        assertEquals(VaultSession.State.NO_KEY, f.session.state.value)
        assertEquals(1, f.owner.count.get())
    }

    /** A store that cannot answer must never look like "no key": that state leads to recovery and vault setup. */
    @Test fun aKeyStoreErrorIsNeverReportedAsNoKey() = runTest {
        val keys = FaultyKeyStore()
        keys.inner.store(key, kid)
        keys.presenceOverride = KeyPresence.UNKNOWN
        keys.failLoad = VaultKeyStoreException.Unavailable("the keystore daemon is not responding")
        val session = VaultSession(keys, FakeAuthenticator(), FakeClock(), keyStoreContext = EmptyCoroutineContext)

        session.adopt(kid)
        assertEquals(VaultSession.State.LOCKED, session.state.value, "an unanswerable store must read as locked, not keyless")

        val failure = assertFailsWith<VaultSession.Failure.KeyStore> { session.unlock(reason) }
        assertIs<VaultKeyStoreException.Unavailable>(failure.cause)
        assertEquals(VaultSession.State.LOCKED, session.state.value)

        // Even a store that is entirely down keeps the state at locked.
        keys.inner.failEveryOperation(VaultKeyStoreException.Unavailable("down"))
        keys.presenceOverride = null
        session.adopt(null)
        session.adopt(kid)
        assertEquals(VaultSession.State.LOCKED, session.state.value)

        // The store recovers; nothing was lost and nothing has to be set up again.
        keys.inner.failEveryOperation(null)
        keys.failLoad = null
        assertContentEquals(key, session.unlock(reason))
    }

    @Test fun aKeyStoreThatNeedsAnAuthenticationItDidNotGetIsReportedAsSuch() = runTest {
        val f = Fixture()
        f.keys.failLoad = VaultKeyStoreException.AuthenticationRequired()
        val failure = assertFailsWith<VaultSession.Failure.KeyStore> { f.session.unlock(reason) }
        assertIs<VaultKeyStoreException.AuthenticationRequired>(failure.cause)
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)
        assertFalse(f.readsKey())
    }

    @Test fun keyAvailabilityKnownUpdatesAClosedSessionAndLeavesAnOpenOneAlone() = runTest {
        val f = Fixture()
        f.session.keyAvailabilityKnown(false, kid)
        assertEquals(VaultSession.State.NO_KEY, f.session.state.value)
        f.session.keyAvailabilityKnown(true, "k-some-other-vault")
        assertEquals(VaultSession.State.NO_KEY, f.session.state.value)
        f.session.keyAvailabilityKnown(true, kid)
        assertEquals(VaultSession.State.LOCKED, f.session.state.value)

        f.session.unlock(reason).fill(0)
        f.session.keyAvailabilityKnown(false, kid)
        assertTrue(f.session.isUnlocked, "an open session holds its key in memory, whatever the store says")
    }

    @Test fun reasonsCarryTheSwiftWordingAndDoNotPrintIt() {
        assertEquals("Reveal “AWS root password”", VaultAuthenticationReason.Reveal("AWS root password").text)
        assertEquals("Copy AWS root password", VaultAuthenticationReason.Copy("AWS root password").text)
        assertEquals("Make this snippet secure", VaultAuthenticationReason.MakeSecure.text)
        assertEquals("Make this secure snippet ordinary", VaultAuthenticationReason.MakeOrdinary.text)
        assertEquals("Create and display a recovery key", VaultAuthenticationReason.CreateRecoveryKey.text)
        assertEquals("Export an encrypted backup including secure snippets", VaultAuthenticationReason.ExportBackup.text)
        assertEquals("Import secure snippets from an encrypted backup", VaultAuthenticationReason.ImportBackup.text)
        assertFalse(VaultAuthenticationReason.Reveal("AWS root password").toString().contains("AWS"))
    }

    @Test fun theWindowsAreFiveAndThirtyMinutes() {
        assertEquals(300_000L, VaultSession.DEFAULT_IDLE_WINDOW_MILLIS)
        assertEquals(1_800_000L, VaultSession.MAXIMUM_WINDOW_MILLIS)
    }
}
