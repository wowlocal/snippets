package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.BodyPurpose
import com.khm.snippets.android.data.MonotonicClock
import com.khm.snippets.android.data.PendingRecoveryKey
import com.khm.snippets.android.data.SecureVault
import com.khm.snippets.android.data.VaultDetails
import com.khm.snippets.android.data.VaultError
import com.khm.snippets.android.data.VaultLockCause
import com.khm.snippets.android.data.VaultOwner
import com.khm.snippets.android.data.VaultResult
import com.khm.snippets.android.data.VaultState
import com.khm.snippets.android.data.VaultUnavailableCause
import com.khm.snippets.android.platform.AuthReason
import com.khm.snippets.android.platform.AuthResult
import com.khm.snippets.android.platform.DeviceAuthenticator
import com.khm.snippets.core.model.Snippet
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/**
 * [SecureVault] without cryptography: bodies sit in [FakeLibraryStore] in the clear, and the
 * session rules (5 minutes idle, 30 minutes at most, fresh authentication for one-use bodies,
 * pre-lock hooks) are the real ones, measured on [clock].
 *
 * @param scope Runs the session's lock timer.
 */
class FakeSecureVault(
    private val store: FakeLibraryStore,
    private val authenticator: DeviceAuthenticator,
    private val clock: MonotonicClock,
    private val scope: CoroutineScope,
    private val controls: FakeControls = FakeControls(),
) : SecureVault {
    private val mutex = Mutex()
    private val hooks = CopyOnWriteArrayList<suspend () -> Unit>()
    private val published = MutableStateFlow<VaultState>(VaultState.NoVault)
    private var vaultExists = false
    private var details = VaultDetails()
    private var keyOnDevice = true
    private var unreadable = false
    private var authenticatedAt = 0L
    private var sessionDeadline: Long? = null
    private var lockInProgress = false
    private var lastLock: VaultLockCause? = null
    private var timer: Job? = null
    private var prepared: PendingRecoveryKey? = null

    /** Git is the provider and its library vault is not set up here: nothing may mint a vault. */
    @Volatile var gitVaultSetupRequired: Boolean = false

    /** Sync is on: removing the vault is refused. */
    @Volatile var syncIsOn: Boolean = false

    /** Next recovery key handed out, so tests can assert on it. */
    @Volatile var nextRecoveryKey: String = "7K2M9QXD4FTRHV3NP8WC6YJAB5G"

    override val state: StateFlow<VaultState> = published.asStateFlow()

    init {
        refresh()
    }

    /** Declares the vault present (a seeded library with secure records) or absent. */
    fun setVault(exists: Boolean, details: VaultDetails = VaultDetails(), keyOnDevice: Boolean = true) {
        vaultExists = exists
        this.details = details
        this.keyOnDevice = keyOnDevice
        endSession(cause = null)
    }

    /** Makes `vault.json` unreadable or readable again. */
    fun setUnreadable(value: Boolean) {
        unreadable = value
        refresh()
    }

    /** Re-reads the device state (screen lock) into [state]. */
    fun refresh() {
        val deadline = sessionDeadline
        published.value = when {
            unreadable -> VaultState.Unavailable(VaultUnavailableCause.Unreadable)
            !vaultExists -> VaultState.NoVault
            !authenticator.isDeviceSecure -> VaultState.Unavailable(VaultUnavailableCause.NoScreenLock)
            !keyOnDevice -> VaultState.KeyMissing(details.owner)
            deadline != null -> VaultState.Unlocked(details, deadline)
            else -> VaultState.Locked(details, lastLock)
        }
    }

    override suspend fun reveal(id: UUID): VaultResult<String> = mutex.withLock {
        controls.pause()
        val record = store.read { secure[id] } ?: return VaultResult.Failure(VaultError.SnippetMissing)
        unavailability()?.let { return VaultResult.Failure(it) }
        if (!sessionIsOpen()) {
            authenticate(AuthReason.RevealSnippet(record.shell.displayName))?.let { return it }
            openSession()
        } else {
            extendSession()
        }
        VaultResult.Success(record.body)
    }

    override suspend fun <T> withBodyOnce(id: UUID, purpose: BodyPurpose, use: suspend (body: String) -> T): VaultResult<T> {
        val record = store.read { secure[id] } ?: return VaultResult.Failure(VaultError.SnippetMissing)
        unavailability()?.let { return VaultResult.Failure(it) }
        // A one-use authentication locks first, so it also ends an open reveal session.
        lock(VaultLockCause.OneUseAuthentication)
        return mutex.withLock {
            controls.pause()
            val name = record.shell.displayName
            val reason = if (purpose == BodyPurpose.Copy) AuthReason.CopySnippet(name) else AuthReason.InsertSnippet(name)
            authenticate(reason)?.let { return it }
            VaultResult.Success(use(record.body))
        }
    }

    override suspend fun updateBody(id: UUID, body: String): VaultResult<Unit> = mutex.withLock {
        controls.pause()
        if (!sessionIsOpen()) return VaultResult.Failure(VaultError.Locked)
        val updated = store.mutate {
            val record = secure[id] ?: return@mutate false
            if (record.body != body) {
                secure[id] = record.copy(shell = record.shell.copy(updatedAt = store.now()), body = body)
            }
            true
        }
        if (!updated) return VaultResult.Failure(VaultError.SnippetMissing)
        if (!lockInProgress) extendSession()
        VaultResult.Success(Unit)
    }

    override suspend fun makeSecure(id: UUID): VaultResult<Unit> = mutex.withLock {
        controls.pause()
        unavailability()?.let { return VaultResult.Failure(it) }
        if (!vaultExists) return VaultResult.Failure(if (gitVaultSetupRequired) VaultError.GitVaultSetupRequired else VaultError.NoKey)
        if (store.read { ordinaryIndex(id) } < 0) return VaultResult.Failure(VaultError.SnippetMissing)
        if (!sessionIsOpen()) {
            authenticate(AuthReason.MakeSecure)?.let { return it }
            openSession()
        } else {
            extendSession()
        }
        val moved = store.mutate {
            val index = ordinaryIndex(id)
            if (index < 0) return@mutate false
            val snippet = ordinary.removeAt(index)
            secure[id] = FakeSecureRecord(
                shell = snippet.copy(keyword = snippet.normalizedKeyword, content = "", updatedAt = store.now()),
                body = snippet.content,
            )
            true
        }
        if (moved) VaultResult.Success(Unit) else VaultResult.Failure(VaultError.SnippetMissing)
    }

    override suspend fun makeOrdinary(id: UUID): VaultResult<Unit> {
        if (store.read { secure[id] } == null) return VaultResult.Failure(VaultError.SnippetMissing)
        unavailability()?.let { return VaultResult.Failure(it) }
        lock(VaultLockCause.OneUseAuthentication)
        return mutex.withLock {
            controls.pause()
            authenticate(AuthReason.MakeOrdinary)?.let { return it }
            val moved = store.mutate {
                val record = secure.remove(id) ?: return@mutate false
                ordinary.add(0, record.shell.copy(content = record.body, updatedAt = store.now()))
                true
            }
            if (moved) VaultResult.Success(Unit) else VaultResult.Failure(VaultError.SnippetMissing)
        }
    }

    override suspend fun prepareVaultSetup(): VaultResult<PendingRecoveryKey?> = mutex.withLock {
        controls.pause()
        if (!authenticator.isDeviceSecure) return VaultResult.Failure(VaultError.ScreenLockRequired)
        if (unreadable) return VaultResult.Failure(VaultError.Unknown)
        if (vaultExists) {
            return if (keyOnDevice) VaultResult.Success(null) else VaultResult.Failure(keyMissingError())
        }
        if (gitVaultSetupRequired) return VaultResult.Failure(VaultError.GitVaultSetupRequired)
        VaultResult.Success(PendingRecoveryKey(nextRecoveryKey).also { prepared = it })
    }

    override suspend fun commitVaultSetup(pending: PendingRecoveryKey): VaultResult<Unit> = mutex.withLock {
        controls.pause()
        if (prepared !== pending || vaultExists) return VaultResult.Failure(VaultError.SetupChanged)
        prepared = null
        vaultExists = true
        details = VaultDetails(owner = VaultOwner.Device, hasRecoveryKey = true)
        keyOnDevice = true
        lastLock = null
        refresh()
        VaultResult.Success(Unit)
    }

    override suspend fun prepareRecoveryKey(): VaultResult<PendingRecoveryKey> {
        unavailability()?.let { return VaultResult.Failure(it) }
        if (!vaultExists) return VaultResult.Failure(VaultError.NoKey)
        lock(VaultLockCause.OneUseAuthentication)
        return mutex.withLock {
            authenticate(AuthReason.CreateRecoveryKey)?.let { return it }
            VaultResult.Success(PendingRecoveryKey(nextRecoveryKey).also { prepared = it })
        }
    }

    override suspend fun commitRecoveryKey(pending: PendingRecoveryKey): VaultResult<Unit> = mutex.withLock {
        if (prepared !== pending || !vaultExists) return VaultResult.Failure(VaultError.SetupChanged)
        prepared = null
        details = details.copy(hasRecoveryKey = true)
        refresh()
        VaultResult.Success(Unit)
    }

    override fun discard(pending: PendingRecoveryKey) {
        if (prepared === pending) prepared = null
    }

    override suspend fun restoreKey(recoveryKey: String): VaultResult<Unit> = mutex.withLock {
        controls.pause()
        if (!vaultExists) return VaultResult.Failure(VaultError.NoKey)
        if (!details.hasRecoveryKey) return VaultResult.Failure(VaultError.NoRecoveryKey)
        val symbols = recoveryKey.filterNot { it == '-' || it.isWhitespace() }.uppercase()
        symbols.firstOrNull { !it.isLetterOrDigit() }?.let {
            return VaultResult.Failure(VaultError.RecoveryKeyInvalidCharacter(it.toString()))
        }
        if (symbols.length != nextRecoveryKey.length) {
            return VaultResult.Failure(VaultError.RecoveryKeyWrongLength(nextRecoveryKey.length, symbols.length))
        }
        if (symbols != nextRecoveryKey) return VaultResult.Failure(VaultError.RecoveryKeyMismatch)
        keyOnDevice = true
        refresh()
        VaultResult.Success(Unit)
    }

    override suspend fun removeVault(): VaultResult<Unit> {
        if (syncIsOn) return VaultResult.Failure(VaultError.SyncIsOn)
        lock(VaultLockCause.Manual)
        return mutex.withLock {
            store.mutate { secure.clear() }
            vaultExists = false
            lastLock = null
            refresh()
            VaultResult.Success(Unit)
        }
    }

    override suspend fun lock(cause: VaultLockCause) {
        if (sessionDeadline == null) return
        // Hooks run outside the mutex, while the key is still usable: they save through updateBody.
        lockInProgress = true
        try {
            for (hook in hooks) hook()
        } finally {
            lockInProgress = false
            mutex.withLock { endSession(cause) }
        }
    }

    override fun addPreLockHook(hook: suspend () -> Unit): AutoCloseable {
        hooks += hook
        return AutoCloseable { hooks -= hook }
    }

    /** Adds a secure entry directly, as another device would have synced it. */
    fun addSecureEntry(shell: Snippet, body: String) {
        store.mutate { secure[shell.id] = FakeSecureRecord(shell.copy(content = ""), body) }
        if (!vaultExists) setVault(exists = true)
    }

    private fun unavailability(): VaultError? = when {
        unreadable -> VaultError.Unknown
        !authenticator.isDeviceSecure -> VaultError.ScreenLockRequired
        vaultExists && !keyOnDevice -> keyMissingError()
        else -> null
    }

    private fun keyMissingError(): VaultError =
        if (details.owner == VaultOwner.GitLibrary) VaultError.GitVaultSetupRequired else VaultError.KeyNotOnDevice

    /** Null on success; otherwise the result to return. */
    private suspend fun authenticate(reason: AuthReason): VaultResult<Nothing>? =
        when (val result = authenticator.authenticate(reason)) {
            AuthResult.Success -> null
            AuthResult.Cancelled -> VaultResult.Cancelled
            AuthResult.NotApproved -> VaultResult.Failure(VaultError.AuthenticationNotApproved)
            is AuthResult.Blocked -> VaultResult.Failure(VaultError.AuthenticationBlocked(result.systemMessage))
        }

    private fun sessionIsOpen(): Boolean {
        val deadline = sessionDeadline ?: return false
        if (lockInProgress || clock.nowMillis() < deadline) return true
        // A late timer: every access re-checks the stored deadline.
        endSession(expiryCause())
        return false
    }

    private fun openSession() {
        authenticatedAt = clock.nowMillis()
        lastLock = null
        extendSession()
    }

    private fun extendSession() {
        val now = clock.nowMillis()
        val deadline = minOf(now + IDLE_WINDOW_MILLIS, authenticatedAt + MAXIMUM_WINDOW_MILLIS)
        sessionDeadline = deadline
        refresh()
        timer?.cancel()
        timer = scope.launch {
            delay(deadline - now)
            lock(expiryCause())
        }
    }

    private fun expiryCause(): VaultLockCause =
        if (clock.nowMillis() >= authenticatedAt + MAXIMUM_WINDOW_MILLIS) VaultLockCause.SessionExpired else VaultLockCause.IdleTimeout

    private fun endSession(cause: VaultLockCause?) {
        timer?.cancel()
        timer = null
        sessionDeadline = null
        lastLock = cause
        refresh()
    }

    companion object {
        const val IDLE_WINDOW_MILLIS = 5 * 60_000L
        const val MAXIMUM_WINDOW_MILLIS = 30 * 60_000L
    }
}
