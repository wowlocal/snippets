package com.khm.snippets.core.vault

import com.khm.snippets.core.crypto.SnippetCrypto
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.coroutines.CoroutineContext

/**
 * Owns "is the vault open right now", and the library key while it is
 * (`VaultSession.swift`).
 *
 * An unlock lasts five minutes from the last use and never more than thirty minutes from
 * the authentication. The window exists so that a secret is not readable for the rest of
 * the day after one fingerprint, and so that revealing is a deliberate act.
 *
 * **The deadline is the authority, not a timer.** Every key access compares the stored
 * deadline with the clock and locks when it has passed, so a late timer or a frozen
 * process cannot leave the key usable. The optional timer ([expiryScope]) exists only so
 * that revealed text is hidden when the deadline arrives without anybody asking for the
 * key.
 *
 * The app calls [lock] when it enters the background (`ProcessLifecycleOwner` `ON_STOP`),
 * and must not call it on a mere loss of focus: the system authentication sheet and the
 * share sheet take focus too.
 *
 * Thread-safe. Swift confines the session to the main actor; here one reentrant lock
 * guards the state and is never held while suspended. Pre-lock hooks and state listeners
 * run on the thread that changed the state, under that lock, so they must not wait for
 * another thread that needs this session.
 *
 * Key bytes: every `ByteArray` this class returns is a copy the caller owns and wipes.
 * The session's own copy is zeroed on [lock]. The JVM may have moved it before that, and
 * a `SecretKeySpec` made from it elsewhere is not reachable from here; "we do not keep it
 * around" is the honest claim, as in Swift.
 *
 * @param clock monotonic; see [MonotonicClock].
 * @param idleWindowMillis how long an unlock lasts without use. Tests shorten it.
 * @param expiryScope when given, a coroutine in it locks the session at the deadline.
 * @param keyStoreContext where the blocking [VaultKeyStore.load] of an unlock runs.
 */
class VaultSession(
    private val keyStore: VaultKeyStore,
    private val authenticator: VaultAuthenticator,
    private val clock: MonotonicClock = MonotonicClock.System,
    private val idleWindowMillis: Long = DEFAULT_IDLE_WINDOW_MILLIS,
    private val expiryScope: CoroutineScope? = null,
    private val keyStoreContext: CoroutineContext = Dispatchers.IO,
) {

    enum class State {
        /** No key for this vault on this device: never set up here, or lost. Only a recovery key, a backup or the library's setup brings it back. */
        NO_KEY,
        LOCKED,
        UNLOCKED,
    }

    sealed class Failure(message: String, cause: Throwable? = null) : Exception(message, cause) {

        class Locked : Failure("the vault is locked")

        class NoKey : Failure("no vault key is available on this device")

        /** The owner check did not succeed. [result] is never [VaultAuthenticationResult.SUCCESS]; a cancelled prompt is silent in the UI. */
        class Authentication(val result: VaultAuthenticationResult) : Failure("authentication did not complete: $result")

        /** The key store failed after a successful authentication. Not "no key". */
        class KeyStore(cause: VaultKeyStoreException) : Failure("the key store could not provide the vault key", cause)
    }

    private val lock = ReentrantLock()
    private val mutableState = MutableStateFlow(State.LOCKED)
    private val preLockHooks = CopyOnWriteArrayList<() -> Unit>()
    private val stateListeners = CopyOnWriteArrayList<(State) -> Unit>()

    private var keyId: String? = null
    private var libraryKey: ByteArray? = null

    /** When the owner last proved presence. The ceiling is measured from here; it does not slide. */
    private var authenticatedAt: Long? = null
    private var deadline: Long? = null
    private var expiryJob: Job? = null
    private var isLocking = false
    private var isDeliveringPreLock = false

    /** The authentication that is in flight or that opened the current session. [lock] drops it, which is what stops a late prompt from opening anything. */
    private var attempt: Any? = null

    /**
     * Lock state for the UI. A sliding deadline is not a state change and is not
     * published: announcing it would make every secure read ask the editor to rebind,
     * whose read would renew the deadline again.
     */
    val state: StateFlow<State> get() = mutableState

    val isUnlocked: Boolean get() = mutableState.value == State.UNLOCKED

    /** The current deadline on [clock], or `null` while not unlocked. For display and tests. */
    val deadlineMillis: Long? get() = lock.withLock { if (isUnlocked) deadline else null }

    /** Whether this device can hold a vault key; see [VaultKeyStore.availability]. */
    val keyStorageAvailability: KeyStorageAvailability get() = keyStore.availability()

    // Observation

    /**
     * Registers a hook that runs inside [lock] while the key is still usable, so that an
     * open editor can save a pending edit synchronously; without it the last edit before
     * backgrounding would be lost. The hook runs only when an open session is being
     * closed. During it [currentKey] works even past the deadline. What it throws is
     * ignored. Close the returned handle to unregister.
     */
    fun addPreLockHook(hook: () -> Unit): AutoCloseable {
        preLockHooks.add(hook)
        return AutoCloseable { preLockHooks.remove(hook) }
    }

    /**
     * Registers a listener that is called synchronously after every change of [state],
     * when the key is already gone for a lock. This is what hides revealed text before
     * [lock] returns; [state] reaches collectors only on their dispatcher's next turn.
     */
    fun addStateListener(listener: (State) -> Unit): AutoCloseable {
        stateListeners.add(listener)
        return AutoCloseable { stateListeners.remove(listener) }
    }

    // Lifecycle

    /**
     * Points the session at a vault. Call whenever the vault is created, reloaded or
     * replaced. A changed or missing key id locks; the same id with its key present
     * leaves an open session and an authentication in flight alone, because a reload on
     * returning to the foreground races the prompt that just finished.
     *
     * Blocks on [VaultKeyStore.presence]. A store that cannot answer counts as holding
     * the key: the state becomes [State.LOCKED], never [State.NO_KEY].
     */
    fun adopt(keyId: String?) {
        lock.withLock {
            if (this.keyId == keyId && keyId != null && keyStore.mayHoldKey(keyId)) {
                // The same vault whose key was just restored is no longer keyless.
                if (mutableState.value == State.NO_KEY) transition(State.LOCKED)
            } else {
                this.keyId = keyId
                lockNow()
                refreshAvailability()
            }
        }
    }

    /**
     * Records what a caller has just learned from the key store about this session's
     * key. An open session is left alone: its key is in memory whatever the store says.
     */
    fun keyAvailabilityKnown(available: Boolean, keyId: String) {
        lock.withLock {
            if (this.keyId == keyId && !isUnlocked) transition(if (available) State.LOCKED else State.NO_KEY)
        }
    }

    private fun refreshAvailability() {
        val id = keyId
        if (id == null || !keyStore.mayHoldKey(id)) {
            transition(State.NO_KEY)
            return
        }
        if (!isUnlocked) transition(State.LOCKED)
    }

    // Unlocking

    /**
     * Opens the vault, asking the device owner unless a session is already open, and
     * returns the key (a copy the caller wipes).
     *
     * @throws Failure.NoKey when no vault is adopted or its key is not on this device.
     * @throws Failure.Locked when another authentication is in flight, or the session
     *   was locked or pointed at another vault while this one was.
     * @throws Failure.Authentication when the owner check did not succeed.
     * @throws Failure.KeyStore when the key could not be read afterwards.
     */
    @Throws(Failure::class, CancellationException::class)
    suspend fun unlock(reason: VaultAuthenticationReason): ByteArray {
        val token = Any()
        val id = lock.withLock {
            val adopted = keyId ?: throw Failure.NoKey()
            val key = libraryKey
            val until = deadline
            if (isUnlocked && key != null && until != null) {
                val now = clock.nowMillis()
                if (until > now) {
                    if (!extendWindow(now)) throw Failure.Locked()
                    return key.copyOf()
                }
                // The deadline, not delivery of a timer, is the authority.
                lockNow()
            }
            // Never stack two system prompts.
            if (attempt != null) throw Failure.Locked()
            attempt = token
            adopted
        }

        val result = try {
            authenticator.authenticate(reason)
        } catch (cancellation: CancellationException) {
            abandon(token)
            throw cancellation
        } catch (_: Exception) {
            VaultAuthenticationResult.FAILED
        }
        lock.withLock {
            if (result != VaultAuthenticationResult.SUCCESS) {
                if (attempt === token) attempt = null
                throw Failure.Authentication(result)
            }
            if (attempt !== token) throw Failure.Locked()
        }

        val data = try {
            withContext(keyStoreContext) { keyStore.load(id) }
        } catch (_: VaultKeyStoreException.NotFound) {
            lock.withLock {
                if (attempt === token) {
                    attempt = null
                    transition(State.NO_KEY)
                }
            }
            throw Failure.NoKey()
        } catch (failure: VaultKeyStoreException) {
            abandon(token)
            throw Failure.KeyStore(failure)
        } catch (cancellation: CancellationException) {
            abandon(token)
            throw cancellation
        }

        lock.withLock {
            // Swift cannot be interrupted between the prompt and here; a lock that arrived meanwhile wins.
            if (attempt !== token) {
                data.fill(0)
                throw Failure.Locked()
            }
            if (data.size != SnippetCrypto.KEY_BYTE_COUNT) {
                val count = data.size
                data.fill(0)
                attempt = null
                throw Failure.KeyStore(VaultKeyStoreException.InvalidKeyLength(count))
            }
            libraryKey = data
            // Set before the window is computed, which reads it for the ceiling. A fresh
            // authentication is the one thing that restarts the half hour.
            val now = clock.nowMillis()
            authenticatedAt = now
            if (!extendWindow(now)) throw Failure.Locked()
            return data.copyOf()
        }
    }

    private fun abandon(token: Any) {
        lock.withLock {
            if (attempt === token) attempt = null
        }
    }

    /**
     * Authenticates and exposes the unlocked vault to one synchronous operation only.
     *
     * Unlike [unlock] this ignores the open window: copying a secret, exporting a backup
     * and similar actions are new disclosures and ask every time. Any open session is
     * locked first (so a revealed body is hidden), and the vault is locked again on every
     * exit: success, failure or cancellation.
     *
     * @param operation runs on the calling thread right after the key is loaded. It reads
     *   the key through [currentKey] or [keyring].
     */
    @Throws(Failure::class, CancellationException::class)
    suspend fun <T> withOneUseAuthentication(reason: VaultAuthenticationReason, operation: () -> T): T {
        lock.withLock {
            // An attempt while still locked is somebody else's visible prompt: leave it alone.
            if (attempt != null && !isUnlocked) throw Failure.Locked()
        }
        lock()
        try {
            unlock(reason).fill(0)
            return operation()
        } finally {
            lock()
        }
    }

    /**
     * The key, if the vault is already open. Never prompts. Counts as use: it slides the
     * idle deadline, up to the ceiling. For user-facing reads and changes.
     */
    @Throws(Failure.Locked::class)
    fun currentKey(): ByteArray = checkedCurrentKey(extendingIdleDeadline = true)

    /**
     * The key, if the vault is already open, without treating the read as user activity.
     * For background work (sync materializing a secure conflict copy): it never prompts,
     * still enforces the deadline, and cannot keep an unattended vault open.
     */
    @Throws(Failure.Locked::class)
    fun currentKeyWithoutExtendingSession(): ByteArray = checkedCurrentKey(extendingIdleDeadline = false)

    private fun checkedCurrentKey(extendingIdleDeadline: Boolean): ByteArray = lock.withLock {
        val key = libraryKey
        val until = deadline
        if (!isUnlocked || key == null || until == null) throw Failure.Locked()
        // A pre-lock hook gets its one chance even when the lock is the expiry itself.
        if (isDeliveringPreLock) return key.copyOf()
        val now = clock.nowMillis()
        if (until <= now) {
            lockNow()
            throw Failure.Locked()
        }
        if (extendingIdleDeadline && !extendWindow(now)) throw Failure.Locked()
        key.copyOf()
    }

    /** A keyring for the vault, valid only while unlocked. Close it when done. */
    @Throws(Failure.Locked::class)
    fun keyring(vaultSalt: ByteArray): SnippetCrypto.Keyring = keyring(currentKey(), vaultSalt)

    @Throws(Failure.Locked::class)
    fun keyringWithoutExtendingSession(vaultSalt: ByteArray): SnippetCrypto.Keyring =
        keyring(currentKeyWithoutExtendingSession(), vaultSalt)

    private fun keyring(key: ByteArray, vaultSalt: ByteArray): SnippetCrypto.Keyring = try {
        SnippetCrypto.Keyring(key, vaultSalt)
    } finally {
        key.fill(0)
    }

    // Locking

    /**
     * Closes the session: runs the pre-lock hooks while the key is still usable, then
     * destroys the key, cancels an authentication in flight, and announces the new state.
     * Idempotent, and safe to call from a hook or a listener.
     */
    fun lock() {
        lock.withLock { lockNow() }
    }

    /**
     * The app went to the background (`ProcessLifecycleOwner` `ON_STOP`, Swift's
     * `didEnterBackgroundNotification`): lock now, pre-lock saves first. Not for a loss
     * of focus or `ON_PAUSE`: the system authentication sheet and the share sheet cause
     * those, and locking then would close the vault the user just opened.
     */
    fun appDidEnterBackground() = lock()

    private fun lockNow() {
        if (isLocking) return
        isLocking = true
        try {
            // Only for a session that is really open: adoption and the first half of a
            // one-use authentication must not trigger a spurious save.
            if (isUnlocked && libraryKey != null) {
                isDeliveringPreLock = true
                try {
                    for (hook in preLockHooks) {
                        try {
                            hook()
                        } catch (_: Exception) {
                            // A failing editor must not keep the vault open.
                        }
                    }
                } finally {
                    isDeliveringPreLock = false
                }
            }

            expiryJob?.cancel()
            expiryJob = null
            libraryKey?.fill(0)
            libraryKey = null
            // Cleared with the key: the next unlock is a new authentication and gets a new half hour.
            authenticatedAt = null
            deadline = null
            attempt = null

            if (mutableState.value == State.NO_KEY) return
            transition(State.LOCKED)
        } finally {
            isDeliveringPreLock = false
            isLocking = false
        }
    }

    /**
     * `deadline = min(now + idle, authenticatedAt + 30 min)`. Without the ceiling a
     * session that is merely active would never expire.
     */
    private fun extendWindow(now: Long): Boolean {
        val ceiling = (authenticatedAt ?: now) + MAXIMUM_WINDOW_MILLIS
        val until = minOf(now + idleWindowMillis, ceiling)
        val remaining = until - now

        expiryJob?.cancel()
        expiryJob = null
        if (remaining <= 0) {
            // The ceiling has passed; authenticating again is the only way forward.
            lockNow()
            return false
        }

        deadline = until
        scheduleExpiry(remaining)
        if (!isUnlocked) transition(State.UNLOCKED)
        return true
    }

    private fun scheduleExpiry(remainingMillis: Long) {
        val scope = expiryScope ?: return
        expiryJob = scope.launch {
            delay(remainingMillis)
            expireIfDue()
        }
    }

    // The timer's clock and the deadline's clock need not agree; the deadline decides.
    private fun expireIfDue() {
        lock.withLock {
            val until = deadline
            if (until != null && isUnlocked) {
                val remaining = until - clock.nowMillis()
                if (remaining <= 0) lockNow() else scheduleExpiry(remaining)
            }
        }
    }

    private fun transition(newState: State) {
        if (mutableState.value == newState) return
        mutableState.value = newState
        for (listener in stateListeners) {
            try {
                listener(newState)
            } catch (_: Exception) {
                // An observer cannot veto a state change.
            }
        }
    }

    companion object {
        /** How long an unlock lasts without use: five minutes. */
        const val DEFAULT_IDLE_WINDOW_MILLIS: Long = 5 * 60 * 1000

        /** The longest the vault stays open on one authentication, however much it is used: thirty minutes. */
        const val MAXIMUM_WINDOW_MILLIS: Long = 30 * 60 * 1000
    }
}
