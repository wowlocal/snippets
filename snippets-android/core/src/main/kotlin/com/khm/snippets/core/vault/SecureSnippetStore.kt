package com.khm.snippets.core.vault

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.clock.HlcGenerator
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.NonceSource
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.RecoveryKey
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.io.LibraryGuard
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/**
 * Owns `Vault/vault.json`: the secure snippets, and the moves in and out of it
 * (`SecureSnippetStore.swift`).
 *
 * **Metadata works while locked, content does not.** A secure record's name, keyword,
 * tags and flags are plaintext in the vault file, so renaming, retagging, enabling,
 * pinning and deleting need no key. Reading or changing the body needs an open
 * [VaultSession].
 *
 * **Moving between the two files** (promote, demote, backup import) goes through
 * [LibraryVaultTransaction]: one lock over both files, each destination written before
 * its source is removed.
 *
 * **Threading.** Swift confines this type to the main actor. Here every function may be
 * called from any thread; functions that are not `suspend` block on file and key-store
 * I/O, so call them off the main thread. They stay plain functions because the session's
 * pre-lock hook has to save a pending edit synchronously. The functions that ask the
 * device owner are `suspend`.
 *
 * **Changes** are announced through [revision]. The store has no file observer: whoever
 * writes the vault underneath it (the sync bridge) calls [reload].
 *
 * Not ported, because they do not exist on Android: the iCloud Keychain vault identity
 * (`VaultIdentityStore`: adoption of a shared vault, republishing) and the repair of
 * plaintext sidecar entries left by old Mac builds (`healLegacyPlainSyncMetadata`). Every
 * key is device-only here, so removing the vault or replacing its key deletes the old key.
 *
 * @param deviceId the device id of this install, for the clocks of secure records.
 * @param now seconds since 2001; injected so tests drive timestamps.
 */
class SecureSnippetStore(
    private val session: VaultSession,
    private val keyStore: VaultKeyStore,
    private val vaultFile: VaultFile,
    private val transaction: LibraryVaultTransaction,
    private val guard: LibraryGuard,
    deviceId: String,
    private val policy: VaultProviderPolicy = VaultProviderPolicy.LocalOnly,
    private val sync: SecureSyncBookkeeping = SecureSyncBookkeeping.None,
    private val io: VaultFileIo = VaultFileIo.Default,
    private val lockTimeoutMillis: Long = DEFAULT_LOCK_TIMEOUT_MILLIS,
    private val now: () -> Double = AppleTime::now,
    clock: HlcGenerator? = null,
) : SecureSnippetProviding {

    constructor(
        session: VaultSession,
        keyStore: VaultKeyStore,
        locations: StorageLocations,
        deviceId: String,
        policy: VaultProviderPolicy = VaultProviderPolicy.LocalOnly,
        sync: SecureSyncBookkeeping = SecureSyncBookkeeping.None,
        markers: MoveMarkerStore = MoveMarkerStore.None,
        io: VaultFileIo = VaultFileIo.Default,
        now: () -> Double = AppleTime::now,
    ) : this(
        session, keyStore, VaultFile(locations, io), LibraryVaultTransaction(locations, io, markers),
        locations.guard, deviceId, policy, sync, io, DEFAULT_LOCK_TIMEOUT_MILLIS, now,
    )

    /** Closed failures of the store (`SecureSnippetStore.Failure`). The app phrases them; [message] is for logs. */
    sealed class Failure(message: String) : Exception(message) {
        /** The vault on disk cannot be read, is damaged, or is from a newer build. Everything that writes refuses. */
        class VaultUnreadable(val detail: String) : Failure(detail)
        class NoSuchRecord : Failure("no such snippet")
        class NotSecure : Failure("that snippet is not secure")
        class AlreadySecure : Failure("that snippet is already secure")
        class SetupCancelled : Failure("secure-snippet setup was cancelled")

        /** The vault changed while its recovery key was being shown, or while a body was being sealed. Try again. */
        class SetupChanged : Failure("the vault changed while its recovery key was being shown; try again")
        class InvalidSetupTicket : Failure("that secure-snippet setup has already finished")
        class RecoveryUnavailable : Failure("this vault has no recovery key")
        class InvalidUtf8 : Failure("the secure snippet is not valid UTF-8")
        class Transaction(val detail: String) : Failure(detail)

        /** The vault is here and its key is not (Swift: `sharedVaultKeyMissing`). Restore it with the recovery key or a backup. */
        class VaultKeyMissing : Failure("the secure-snippets key is not on this device")

        /** The selected provider's library owns the vault and it is not set up on this device. Nothing may mint one. */
        class LibraryVaultSetupRequired : Failure("secure snippets are not set up for this library on this device yet")
        class ForgetRequiresSyncOff : Failure("turn off sync before removing secure snippets from this device")
        class ForgetWaitForSync : Failure("sync is still finishing a round; try again in a moment")
    }

    /** Failures of the library-vault operations a Git library's setup calls (`LibraryVaultFailure`). */
    sealed class LibraryVaultFailure(message: String) : Exception(message) {
        /** This device's vault is not the library's, and it is in use. */
        class DifferentVault(val secureCount: Int) : LibraryVaultFailure("this device uses a different secure-snippet vault")

        /** The vault is here but its key is not. */
        class KeyUnavailable : LibraryVaultFailure("the vault key is not on this device")

        /** Device-owner authentication did not complete. */
        class Authentication : LibraryVaultFailure("authentication did not complete")

        /** The recovery code does not open the published vault key. */
        class IncorrectRecoveryCode : LibraryVaultFailure("the recovery code does not open the library's vault")
        class Unreadable : LibraryVaultFailure("the vault could not be read or written")

        /** The library's vault key is not on this device and no code was given for it. */
        class RecoveryCodeRequired : LibraryVaultFailure("the library's recovery code is required")

        /** A losing side of a secure sync conflict is still ciphertext under the current key. */
        class PendingConflicts : LibraryVaultFailure("a secure sync conflict is still pending")
    }

    enum class LibraryVaultAvailability {
        /** No vault on this device. */
        NONE,

        /** The vault and its key are here. */
        READY,

        /** The vault is here, its key is not. */
        KEY_MISSING,
    }

    /**
     * A first-vault recovery key that has been generated and shown but has changed
     * neither the key store nor the file system. The UI commits it only on an explicit
     * acknowledgement; [cancel] leaves nothing behind.
     */
    class PendingVaultCreation internal constructor(recoveryKey: ByteArray, recoveryKeyText: String) {
        /** The printable key, shown once. Empty once committed or cancelled. Never log it. */
        var recoveryKeyText: String = recoveryKeyText
            private set
        private var recoveryKey: ByteArray? = recoveryKey

        @Synchronized
        fun cancel() {
            recoveryKey?.fill(0)
            recoveryKey = null
            recoveryKeyText = ""
        }

        /** A copy the caller wipes, or `null` once the ticket is spent. */
        @Synchronized
        internal fun recoveryKeyCopy(): ByteArray? = recoveryKey?.copyOf()

        override fun toString(): String = "PendingVaultCreation(redacted)"
    }

    /**
     * A recovery wrap waiting for the user to confirm that the printable key was saved.
     * It holds ciphertext, not the vault key, so the authentication that created it may
     * end before the key is shown.
     */
    class PendingRecoveryKeyAddition internal constructor(
        recoveryKeyText: String,
        internal val kid: String,
        internal val vaultSalt: String,
        internal val envelope: String,
    ) {
        var recoveryKeyText: String = recoveryKeyText
            private set
        internal var isActive: Boolean = true
            private set

        @Synchronized
        fun cancel() {
            isActive = false
            recoveryKeyText = ""
        }

        override fun toString(): String = "PendingRecoveryKeyAddition(redacted)"
    }

    class PreparedLibraryVault internal constructor(
        val identity: LibraryVaultIdentity,
        /** True when the key was created by this call and no vault document exists for it yet. */
        val minted: Boolean,
    )

    /** A prepared key replacement: the new key is stored, nothing on disk has changed yet. */
    class PendingVaultRotation internal constructor(
        /** The new vault as the library publishes it. */
        val identity: LibraryVaultIdentity,
        internal val sourceKid: String?,
        internal val sourceVaultSalt: String?,
        private var oldKey: ByteArray?,
        private var newKey: ByteArray?,
    ) {
        /** True when preparing it unlocked this device's vault, which asked the device owner. */
        val authenticatedOwner: Boolean get() = sourceKid != null

        @Synchronized
        internal fun oldKeyCopy(): ByteArray? = oldKey?.copyOf()

        @Synchronized
        internal fun newKeyCopy(): ByteArray? = newKey?.copyOf()

        @Synchronized
        internal fun finish() {
            oldKey?.fill(0)
            newKey?.fill(0)
            oldKey = null
            newKey = null
        }

        override fun toString(): String = "PendingVaultRotation(redacted)"
    }

    /** How the vault presents in Settings. */
    enum class VaultStatus {
        /** No vault. Making a snippet secure creates one. */
        NOT_SET_UP,
        LOCKED,
        UNLOCKED,

        /** The vault is here and its key is not; see [Status.keyMissingRemediation]. */
        KEY_MISSING,

        /** Written by a newer build: listed nowhere, never written. */
        TOO_NEW,

        /** The file could not be read. Nothing is changed; try again. */
        UNREADABLE,

        /** The file is not a vault. It can be quarantined; it is never overwritten. */
        CORRUPT,
    }

    /** What can bring a missing vault key back. */
    enum class KeyMissingRemediation {
        /** The vault has a recovery wrap: [restoreKey]. */
        RECOVERY_KEY,

        /** The provider's library owns the vault: its setup, with the library's recovery code. */
        LIBRARY_SETUP,

        /** No recovery wrap exists. Only an encrypted backup that contains this vault restores the key. */
        BACKUP_ONLY,
    }

    data class Status(
        val vault: VaultStatus,
        val secureCount: Int,
        val hasRecoveryKey: Boolean,
        val keyStorage: KeyStorageAvailability,
        /** Set only for [VaultStatus.KEY_MISSING]. */
        val keyMissingRemediation: KeyMissingRemediation?,
        /** Set only for [VaultStatus.TOO_NEW]. */
        val newerSchemaVersion: Long?,
    )

    private class Loaded(val document: VaultDocument?, val isUnreadable: Boolean, val problem: VaultLoadOutcome<VaultDocument>?)

    private val loaded = AtomicReference(Loaded(null, false, null))
    private val mutableRevision = MutableStateFlow(0L)
    private val clockLock = Any()

    /** Issues the clocks of secure records. Replaceable so tests can freeze it. Guarded internally. */
    var clock: HlcGenerator = clock ?: HlcGenerator(deviceId)

    init {
        reload(notifyChange = false)
    }

    // State

    /** The vault as last read or written by this store. */
    val document: VaultDocument? get() = loaded.get().document

    /**
     * True when the vault on disk could not be read, is damaged or is from a newer build.
     * Everything that writes refuses while this is true: an unreadable vault is not an
     * absent one, and a fresh document over it would destroy secrets.
     */
    val isUnreadable: Boolean get() = loaded.get().isUnreadable

    /** Increases whenever the secure library changed or was reloaded. Observe it and read again. */
    val revision: StateFlow<Long> get() = mutableRevision

    private fun notifyChanged() {
        mutableRevision.value += 1
    }

    private fun setDocument(document: VaultDocument?) {
        loaded.set(Loaded(document, false, null))
    }

    /** Reads the vault from disk and points the session at it. */
    fun reload(notifyChange: Boolean = true) {
        when (val outcome = vaultFile.load()) {
            is VaultLoadOutcome.Loaded -> {
                loaded.set(Loaded(outcome.value, false, null))
                session.adopt(outcome.value.kid)
            }
            is VaultLoadOutcome.Missing -> {
                loaded.set(Loaded(null, false, null))
                session.adopt(null)
            }
            // A newer build owns the file, or it cannot be read: show what can be shown, never write.
            is VaultLoadOutcome.TooNew, is VaultLoadOutcome.Unreadable, is VaultLoadOutcome.Corrupt -> {
                loaded.set(Loaded(null, true, outcome))
                session.adopt(null)
            }
        }
        if (notifyChange) notifyChanged()
    }

    /** For Settings: vault state, key storage and what to offer when the key is missing. Blocks on the key store. */
    fun status(): Status {
        val state = loaded.get()
        val document = state.document
        val vault = when {
            state.problem is VaultLoadOutcome.TooNew -> VaultStatus.TOO_NEW
            state.problem is VaultLoadOutcome.Corrupt -> VaultStatus.CORRUPT
            state.isUnreadable -> VaultStatus.UNREADABLE
            document == null -> VaultStatus.NOT_SET_UP
            else -> when (session.state.value) {
                VaultSession.State.NO_KEY -> VaultStatus.KEY_MISSING
                VaultSession.State.LOCKED -> VaultStatus.LOCKED
                VaultSession.State.UNLOCKED -> VaultStatus.UNLOCKED
            }
        }
        val remediation = if (vault != VaultStatus.KEY_MISSING || document == null) {
            null
        } else if (policy.libraryOwnsVault) {
            KeyMissingRemediation.LIBRARY_SETUP
        } else if (document.wrapRecovery != null) {
            KeyMissingRemediation.RECOVERY_KEY
        } else {
            KeyMissingRemediation.BACKUP_ONLY
        }
        return Status(
            vault = vault,
            secureCount = document?.records?.size ?: 0,
            hasRecoveryKey = document?.wrapRecovery != null,
            keyStorage = keyStore.availability(),
            keyMissingRemediation = remediation,
            newerSchemaVersion = (state.problem as? VaultLoadOutcome.TooNew)?.version,
        )
    }

    /**
     * Moves a vault that is not a vault ([VaultStatus.CORRUPT]) aside, bytes intact, and
     * reloads. Afterwards there is no vault and one may be created. The key stays in the
     * key store.
     */
    @Throws(VaultFileError.QuarantineFailed::class, Failure::class)
    fun quarantineCorruptVault(reason: String): File {
        if (loaded.get().problem !is VaultLoadOutcome.Corrupt) {
            throw Failure.VaultUnreadable("only a vault that could not be decoded is quarantined")
        }
        val held = guard.acquire(lockTimeoutMillis) ?: throw Failure.Transaction("another writer holds the vault; try again")
        val moved = try {
            if (!vaultFile.load().isCorrupt) throw Failure.Transaction("the vault changed; try again")
            vaultFile.quarantine(reason, now())
        } finally {
            held.close()
        }
        reload()
        return moved
    }

    // Metadata, available while locked

    /** Content-free [Snippet] values for display and for keyword-uniqueness checks. */
    val shells: List<Snippet> get() = document?.shells ?: emptyList()

    val isEmpty: Boolean get() = document?.records?.isEmpty() ?: true

    /** An existing vault with no records still owns a key, a salt and a recovery wrap; it is not first-run state. */
    val hasVault: Boolean get() = document != null

    val count: Int get() = document?.records?.size ?: 0

    val hasRecoveryKey: Boolean get() = document?.wrapRecovery != null

    override fun isSecure(id: UUID): Boolean = document?.record(id) != null

    override fun secureShellsForDisplay(): List<Snippet> = shells

    fun record(id: UUID): VaultRecord? = document?.record(id)

    /**
     * Enabled secure shells, for a picker. Deliberately separate from the ordinary
     * library's enabled list: secure records must never reach automatic expansion.
     */
    fun enabledShellsForDisplay(): List<Snippet> = shells.filter { it.isEnabled }

    // Creating the vault

    /** Refuses an operation that needs to write a secret when the key is not here. A store that cannot answer passes. */
    private fun requireUsableKey(document: VaultDocument) {
        if (keyStore.mayHoldKey(document.kid)) return
        // With a library-owned vault the key comes from the library's recovery code.
        if (policy.libraryOwnsVault) throw Failure.LibraryVaultSetupRequired()
        throw Failure.VaultKeyMissing()
    }

    private fun existingVaultForCreation(): VaultDocument? {
        document?.let { return it }
        if (isUnreadable) throw Failure.VaultUnreadable("refusing to create a vault over an unreadable one")
        // A library that owns its vault: minting one here would be a second crypto scope.
        if (policy.libraryOwnsVault) throw Failure.LibraryVaultSetupRequired()
        return null
    }

    /**
     * Starts first-vault setup without storing a key, a wrap or a document. `null` means
     * a vault already exists and its key is here: promotion can go ahead.
     *
     * @throws Failure.LibraryVaultSetupRequired when the provider's library owns the vault.
     * @throws Failure.VaultKeyMissing when a vault exists and its key is not on this device.
     */
    @Throws(Failure::class)
    fun prepareVaultCreationIfNeeded(): PendingVaultCreation? {
        existingVaultForCreation()?.let {
            requireUsableKey(it)
            return null
        }
        val recoveryKey = RecoveryKey.generate()
        return PendingVaultCreation(recoveryKey, RecoveryKey.formatted(recoveryKey))
    }

    /**
     * Completes a prepared setup after the UI acknowledged the displayed recovery key.
     * If a vault appeared meanwhile, the ticket is cancelled and [Failure.SetupChanged]
     * is thrown: the displayed key was made for a vault that will now never exist.
     */
    @Throws(Failure::class, VaultKeyStoreException::class, VaultFileError::class)
    fun commitVaultCreation(pending: PendingVaultCreation): VaultDocument {
        val recoveryKey = pending.recoveryKeyCopy() ?: throw Failure.InvalidSetupTicket()
        try {
            existingVaultForCreation()?.let {
                requireUsableKey(it)
                pending.cancel()
                throw Failure.SetupChanged()
            }
            val created = try {
                createVault(recoveryKey)
            } catch (changed: Failure.SetupChanged) {
                pending.cancel()
                throw changed
            }
            pending.cancel()
            return created
        } finally {
            recoveryKey.fill(0)
        }
    }

    /** [prepareVaultCreationIfNeeded] and [commitVaultCreation] around one synchronous confirmation. */
    @Throws(Failure::class, VaultKeyStoreException::class, VaultFileError::class)
    fun createVaultIfNeeded(confirmRecoveryKey: (String) -> Boolean): VaultDocument {
        val pending = prepareVaultCreationIfNeeded() ?: return requireDocument()
        if (!confirmRecoveryKey(pending.recoveryKeyText)) {
            pending.cancel()
            throw Failure.SetupCancelled()
        }
        return commitVaultCreation(pending)
    }

    private fun createVault(recoveryKey: ByteArray): VaultDocument {
        val keyring = SnippetCrypto.Keyring.generate()
        val libraryKey = keyring.libraryKey()
        try {
            val salt = keyring.salt()
            val kid = newVaultKeyId()
            val recoveryWrap = KeyWrap.wrap(libraryKey, recoveryKey, KeyWrap.Purpose.RECOVERY, kid, salt)

            // The key goes into the key store before the document exists on disk. The
            // other order can leave a file full of records nothing can ever open.
            keyStore.store(libraryKey, kid)

            val created = VaultDocument(
                kid = kid,
                vaultSalt = Base64Url.encode(salt),
                kdf = newPassphraseKdfParameters(),
                wrapRecovery = recoveryWrap,
            )
            try {
                // Swift writes unlocked on its single actor. Here a second thread may be
                // creating too, so the write is conditional on there still being no vault.
                vaultFile.update(lockTimeoutMillis) { existing ->
                    if (existing != null) throw Failure.SetupChanged()
                    created
                }
            } catch (failure: Exception) {
                try {
                    keyStore.delete(kid)
                } catch (_: VaultKeyStoreException) {
                    // An orphaned key is harmless; the failure being reported is the write.
                }
                if (failure is Failure.SetupChanged) reload(notifyChange = false)
                throw failure
            }
            setDocument(created)
            session.adopt(kid)
            notifyChanged()
            return created
        } finally {
            libraryKey.fill(0)
            keyring.close()
        }
    }

    /** Adds the recovery key to a vault that has none. The vault must be unlocked; cancelling writes nothing. */
    @Throws(Failure::class, VaultSession.Failure::class)
    fun addRecoveryKeyIfNeeded(confirmRecoveryKey: (String) -> Boolean): Boolean {
        val pending = prepareRecoveryKeyAddition() ?: return false
        if (!confirmRecoveryKey(pending.recoveryKeyText)) {
            pending.cancel()
            throw Failure.SetupCancelled()
        }
        return commitRecoveryKeyAddition(pending)
    }

    /**
     * Builds a recovery wrap while the vault is open, without persisting it. Meant to run
     * inside [VaultSession.withOneUseAuthentication]. `null` when the vault already has a
     * recovery key.
     */
    @Throws(Failure::class, VaultSession.Failure::class)
    fun prepareRecoveryKeyAddition(): PendingRecoveryKeyAddition? {
        val document = document ?: throw Failure.NoSuchRecord()
        if (document.wrapRecovery != null) return null
        val salt = document.vaultSaltBytes ?: throw Failure.VaultUnreadable("the vault's salt could not be decoded")
        val libraryKey = session.currentKey()
        val recoveryKey = RecoveryKey.generate()
        try {
            val envelope = KeyWrap.wrap(libraryKey, recoveryKey, KeyWrap.Purpose.RECOVERY, document.kid, salt)
            return PendingRecoveryKeyAddition(RecoveryKey.formatted(recoveryKey), document.kid, document.vaultSalt, envelope)
        } finally {
            libraryKey.fill(0)
            recoveryKey.fill(0)
        }
    }

    /** Persists a prepared recovery wrap after the key was displayed and acknowledged. `false` when the vault got one meanwhile. */
    @Throws(Failure::class)
    fun commitRecoveryKeyAddition(pending: PendingRecoveryKeyAddition): Boolean {
        if (!pending.isActive) throw Failure.InvalidSetupTicket()
        val document = document ?: throw Failure.NoSuchRecord()
        if (document.kid != pending.kid || document.vaultSalt != pending.vaultSalt) throw Failure.InvalidSetupTicket()
        if (document.wrapRecovery != null) {
            pending.cancel()
            return false
        }
        mutateVault { vault ->
            if (vault.kid != pending.kid || vault.vaultSalt != pending.vaultSalt) throw Failure.InvalidSetupTicket()
            if (vault.wrapRecovery == null) vault.copy(wrapRecovery = pending.envelope) else vault
        }
        pending.cancel()
        return true
    }

    /**
     * Restores a missing key from the printable recovery key. The wrap authenticates the
     * recovered bytes against this vault's `kid` before anything is stored, so a typo can
     * never replace a good key.
     *
     * @throws RecoveryKey.Failure for a mistyped key (five distinct cases).
     * @throws KeyWrap.Failure.WrongKey for a well-formed key that is not this vault's.
     */
    @Throws(Failure::class, RecoveryKey.Failure::class, KeyWrap.Failure::class, SnippetCrypto.Failure::class, VaultKeyStoreException::class)
    fun restoreKey(recoveryKeyText: CharSequence) {
        val document = requireDocument()
        val envelope = document.wrapRecovery ?: throw Failure.RecoveryUnavailable()
        val salt = document.vaultSaltBytes ?: throw Failure.VaultUnreadable("the vault's salt could not be decoded")
        val recoveryKey = RecoveryKey.decode(recoveryKeyText)
        try {
            val libraryKey = KeyWrap.unwrap(envelope, recoveryKey, KeyWrap.Purpose.RECOVERY, document.kid, salt)
            try {
                keyStore.store(libraryKey, document.kid)
            } finally {
                libraryKey.fill(0)
            }
        } finally {
            recoveryKey.fill(0)
        }
        session.adopt(document.kid)
        notifyChanged()
    }

    // A library's vault
    //
    // A Git library owns its vault: `keys/vault.json` names it and carries its key under
    // the library's recovery code. These are the local halves of that arrangement; nothing
    // here talks to a repository.

    /** Reads the key store. For decisions inside a setup step, not for drawing. */
    val libraryVaultAvailability: LibraryVaultAvailability
        get() {
            val document = document ?: return LibraryVaultAvailability.NONE
            return if (keyStore.mayHoldKey(document.kid)) LibraryVaultAvailability.READY else LibraryVaultAvailability.KEY_MISSING
        }

    /** The same answer from state the session already holds, for status lines. */
    val libraryVaultDisplayAvailability: LibraryVaultAvailability
        get() {
            if (document == null) return LibraryVaultAvailability.NONE
            return if (session.state.value == VaultSession.State.NO_KEY) {
                LibraryVaultAvailability.KEY_MISSING
            } else {
                LibraryVaultAvailability.READY
            }
        }

    /**
     * The vault a new library should publish, its key wrapped under the library's
     * [recoveryKey]: this device's vault when it has one, otherwise a freshly minted key.
     * An existing vault asks the device owner every time, because the result lets whoever
     * holds the code open every secure snippet.
     */
    @Throws(LibraryVaultFailure::class, VaultKeyStoreException::class, CancellationException::class)
    suspend fun prepareLibraryVault(recoveryKey: ByteArray, reason: VaultAuthenticationReason): PreparedLibraryVault {
        if (isUnreadable) throw LibraryVaultFailure.Unreadable()
        // No vault, or an unused one whose key is not here: the library gets a fresh one.
        val unusedWithoutKey = document?.let { !keyStore.mayHoldKey(it.kid) && isUnusedVault(it) } ?: true
        if (unusedWithoutKey) {
            val minted = mintLibraryVault(recoveryKey)
            minted.second.fill(0)
            return PreparedLibraryVault(minted.first, minted = true)
        }
        return PreparedLibraryVault(libraryVaultIdentity(recoveryKey, reason), minted = false)
    }

    /** This device's vault as a library publishes it. Always authenticates. */
    @Throws(LibraryVaultFailure::class, CancellationException::class)
    suspend fun libraryVaultIdentity(recoveryKey: ByteArray, reason: VaultAuthenticationReason): LibraryVaultIdentity {
        val document = document
        val salt = document?.vaultSaltBytes
        if (isUnreadable || document == null || salt == null) throw LibraryVaultFailure.Unreadable()
        if (!keyStore.mayHoldKey(document.kid)) throw LibraryVaultFailure.KeyUnavailable()
        return mappingSessionFailures {
            session.withOneUseAuthentication(reason) {
                val key = session.currentKey()
                try {
                    val wrap = KeyWrap.wrap(key, recoveryKey, KeyWrap.Purpose.RECOVERY, document.kid, salt)
                    LibraryVaultIdentity(document.kid, document.vaultSalt, identityKdf(document.kdf), wrap)
                } finally {
                    key.fill(0)
                }
            }
        }
    }

    private inline fun <T> mappingSessionFailures(block: () -> T): T = try {
        block()
    } catch (cancellation: CancellationException) {
        throw cancellation
    } catch (_: VaultSession.Failure.NoKey) {
        throw LibraryVaultFailure.KeyUnavailable()
    } catch (_: VaultSession.Failure) {
        throw LibraryVaultFailure.Authentication()
    } catch (failure: LibraryVaultFailure) {
        throw failure
    } catch (_: Exception) {
        throw LibraryVaultFailure.Unreadable()
    }

    /**
     * Mints the key of a library's vault and stores it. No document is written: the key
     * exists before the library that names it. The caller wipes the returned key.
     */
    private fun mintLibraryVault(recoveryKey: ByteArray): Pair<LibraryVaultIdentity, ByteArray> {
        val keyring = SnippetCrypto.Keyring.generate()
        val libraryKey = keyring.libraryKey()
        try {
            val salt = keyring.salt()
            val kid = newVaultKeyId()
            val wrap = KeyWrap.wrap(libraryKey, recoveryKey, KeyWrap.Purpose.RECOVERY, kid, salt)
            keyStore.store(libraryKey, kid)
            val identity = LibraryVaultIdentity(kid, Base64Url.encode(salt), newPassphraseKdfParameters(), wrap)
            return identity to libraryKey.copyOf()
        } finally {
            libraryKey.fill(0)
            keyring.close()
        }
    }

    /** Removes a minted key whose library provably was never created. */
    fun discardMintedLibraryVault(prepared: PreparedLibraryVault) {
        if (!prepared.minted || document?.kid == prepared.identity.kid) return
        deleteKeyQuietly(prepared.identity.kid)
    }

    /** Refuses a library whose vault is not this device's, before anything is saved. An unused vault is not in the way. */
    @Throws(LibraryVaultFailure::class)
    fun checkCanJoinLibraryVault(identity: LibraryVaultIdentity) {
        if (isUnreadable) throw LibraryVaultFailure.Unreadable()
        val document = document ?: return
        if (!isSameVault(document, identity) && !isUnusedVault(document)) {
            throw LibraryVaultFailure.DifferentVault(document.records.size)
        }
    }

    /**
     * A vault that never held anything: no records, and no secure snippet this device has
     * ever synced or deleted. Its `kid` is in no ciphertext and no tombstone, so replacing
     * the document loses nothing.
     */
    private fun isUnusedVault(document: VaultDocument): Boolean =
        document.records.isEmpty() && !sync.hasSecureSyncHistory()

    /**
     * Points this device at the library's vault.
     *
     * With no vault here (or an unused one), writes a records-free `vault.json` naming
     * the library's `kid`, so incoming secure records have somewhere to go and nothing
     * can mint a rival. [recoveryKey] (the library's recovery code as bytes) restores the
     * vault key when it is not in the key store; it is authenticated against the `kid`
     * first, and stored before the document is written. A vault that is already here must
     * be the same one, and keeps its own recovery wrap.
     */
    @Throws(LibraryVaultFailure::class, VaultKeyStoreException::class)
    fun joinLibraryVault(identity: LibraryVaultIdentity, recoveryKey: ByteArray? = null): LibraryVaultAvailability {
        checkCanJoinLibraryVault(identity)
        val salt = identity.vaultSaltBytes ?: throw LibraryVaultFailure.Unreadable()
        if (recoveryKey != null && !keyStore.mayHoldKey(identity.kid)) {
            val key = try {
                KeyWrap.unwrap(identity.wrapRecovery, recoveryKey, KeyWrap.Purpose.RECOVERY, identity.kid, salt)
            } catch (_: Exception) {
                throw LibraryVaultFailure.IncorrectRecoveryCode()
            }
            // The key first: a document whose key was never stored is a vault nothing can open.
            try {
                keyStore.store(key, identity.kid)
            } finally {
                key.fill(0)
            }
        }
        val joined = try {
            vaultFile.update(lockTimeoutMillis) { existing ->
                // Read under the lock: another writer may have written since.
                if (existing != null && isSameVault(existing, identity)) {
                    if (existing.wrapRecovery == null) existing.copy(wrapRecovery = identity.wrapRecovery) else existing
                } else {
                    if (existing != null && !isUnusedVault(existing)) {
                        throw LibraryVaultFailure.DifferentVault(existing.records.size)
                    }
                    // No vault, or an unused one. Its key stays in the key store untouched.
                    VaultDocument(
                        kid = identity.kid,
                        vaultSalt = identity.vaultSalt,
                        kdf = identityKdf(identity.kdf),
                        wrapRecovery = identity.wrapRecovery,
                    )
                }
            }
        } catch (failure: LibraryVaultFailure) {
            throw failure
        } catch (_: Exception) {
            throw LibraryVaultFailure.Unreadable()
        }
        val changed = joined != document
        setDocument(joined)
        session.adopt(joined.kid)
        val available = keyStore.mayHoldKey(joined.kid)
        session.keyAvailabilityKnown(available, joined.kid)
        if (changed) notifyChanged()
        return if (available) LibraryVaultAvailability.READY else LibraryVaultAvailability.KEY_MISSING
    }

    // Replacing the vault key
    //
    // A vault key is replaced only by re-sealing: every record is opened under the old key
    // and sealed under the new one, with the new `kid` in its associated data, in one write
    // of `vault.json`. The content hash is keyed, so it is recomputed too.

    /**
     * Mints the vault key of a rotated library, wrapped under the new [recoveryKey], and
     * stores it. Nothing on disk changes yet. A vault that is already here is unlocked
     * (device-owner authentication) and every record is opened once, so a record that
     * cannot be re-sealed stops the rotation before anything is replaced.
     */
    @Throws(LibraryVaultFailure::class, VaultKeyStoreException::class, CancellationException::class)
    suspend fun prepareVaultRotation(recoveryKey: ByteArray, reason: VaultAuthenticationReason): PendingVaultRotation {
        if (isUnreadable) throw LibraryVaultFailure.Unreadable()
        var sourceKid: String? = null
        var sourceSalt: String? = null
        var oldKey: ByteArray? = null
        try {
            val existing = document
            // An unused vault whose key is not here protects nothing: the rotated library gets a fresh one.
            if (existing != null && !(isUnusedVault(existing) && !keyStore.mayHoldKey(existing.kid))) {
                if (!keyStore.mayHoldKey(existing.kid)) throw LibraryVaultFailure.KeyUnavailable()
                val key = authenticatedVaultKey(reason)
                oldKey = key
                // Unlocking lets an open editor save first; validate what is on disk now.
                val current = document
                if (current == null || current.kid != existing.kid) throw LibraryVaultFailure.Unreadable()
                checkCanReseal(current, key)
                sourceKid = current.kid
                sourceSalt = current.vaultSalt
            }
            // The key before the library that names it.
            val minted = mintLibraryVault(recoveryKey)
            val pending = PendingVaultRotation(minted.first, sourceKid, sourceSalt, oldKey, minted.second)
            oldKey = null
            return pending
        } finally {
            oldKey?.fill(0)
        }
    }

    /**
     * Checks a prepared rotation against the vault as it is now. Call it with sync
     * stopped, right before the library is replaced, so that a record or a conflict that
     * arrived since [prepareVaultRotation] stops the rotation while the old library exists.
     */
    @Throws(LibraryVaultFailure::class)
    fun checkVaultRotation(pending: PendingVaultRotation) {
        if (isUnreadable) throw LibraryVaultFailure.Unreadable()
        val sourceKid = pending.sourceKid
        if (sourceKid == null) {
            // Nothing was to be re-sealed; a vault in use that appeared since would be.
            checkCanJoinLibraryVault(pending.identity)
            return
        }
        val current = document
        val key = pending.oldKeyCopy()
        try {
            if (current == null || current.kid != sourceKid || current.vaultSalt != pending.sourceVaultSalt || key == null) {
                throw LibraryVaultFailure.Unreadable()
            }
            checkCanReseal(current, key)
        } finally {
            key?.fill(0)
        }
    }

    /** Throws unless every record opens under [key] and no secure conflict is pending. */
    private fun checkCanReseal(current: VaultDocument, key: ByteArray) {
        val salt = current.vaultSaltBytes ?: throw LibraryVaultFailure.Unreadable()
        if (hasUnresolvedSecureConflicts(current)) throw LibraryVaultFailure.PendingConflicts()
        SnippetCrypto.Keyring(key, salt).use { keyring ->
            for (record in current.records) {
                try {
                    SnippetCrypto.open(record.sealed, context(record.id, current), keyring).fill(0)
                } catch (_: SnippetCrypto.Failure) {
                    throw LibraryVaultFailure.Unreadable()
                }
            }
        }
    }

    /** Moves this device's vault to the prepared key. Call once the library names it. */
    @Throws(LibraryVaultFailure::class, VaultKeyStoreException::class)
    fun commitVaultRotation(pending: PendingVaultRotation) {
        val newKey = pending.newKeyCopy()
        val oldKey = pending.oldKeyCopy()
        try {
            if (newKey == null) throw LibraryVaultFailure.Unreadable()
            val sourceKid = pending.sourceKid
            val sourceSalt = pending.sourceVaultSalt
            if (sourceKid == null || sourceSalt == null || oldKey == null) {
                joinLibraryVault(pending.identity)
                return
            }
            resealVault(sourceKid, sourceSalt, oldKey, pending.identity, newKey)
        } finally {
            newKey?.fill(0)
            oldKey?.fill(0)
            pending.finish()
        }
    }

    /** Forgets a prepared key whose library provably was never written. */
    fun discardVaultRotation(pending: PendingVaultRotation) {
        pending.finish()
        if (document?.kid == pending.identity.kid) return
        deleteKeyQuietly(pending.identity.kid)
    }

    /** True when this device's vault is not the library's and holds or has synced secure snippets, so joining means re-sealing them. */
    fun libraryVaultNeedsReseal(identity: LibraryVaultIdentity): Boolean {
        val document = document
        if (isUnreadable || document == null) return false
        return !isSameVault(document, identity) && !isUnusedVault(document)
    }

    /** Refuses, before anything is saved, a re-seal that cannot succeed. */
    @Throws(LibraryVaultFailure::class)
    fun checkCanResealIntoLibraryVault(identity: LibraryVaultIdentity) {
        if (isUnreadable) throw LibraryVaultFailure.Unreadable()
        val document = document
        if (!libraryVaultNeedsReseal(identity) || document == null) return
        if (document.records.isNotEmpty() && !keyStore.mayHoldKey(document.kid)) {
            throw LibraryVaultFailure.DifferentVault(document.records.size)
        }
        if (hasUnresolvedSecureConflicts(document)) throw LibraryVaultFailure.PendingConflicts()
    }

    /**
     * Moves this device's secure snippets under the library's vault key and adopts that
     * vault. The library's key comes from the key store or from [recoveryKey] (the
     * library's recovery code as bytes); this device's own key takes device-owner
     * authentication. Nothing changes unless every record re-seals.
     *
     * Call this only when the device follows the library it was syncing to that library's
     * replacement; any other vault in use may be shared with another provider's devices.
     */
    @Throws(LibraryVaultFailure::class, VaultKeyStoreException::class, CancellationException::class)
    suspend fun resealIntoLibraryVault(
        identity: LibraryVaultIdentity,
        recoveryKey: ByteArray? = null,
        reason: VaultAuthenticationReason,
    ) {
        checkCanResealIntoLibraryVault(identity)
        val existing = document
        if (!libraryVaultNeedsReseal(identity) || existing == null) {
            joinLibraryVault(identity, recoveryKey)
            return
        }
        val salt = identity.vaultSaltBytes ?: throw LibraryVaultFailure.Unreadable()
        val stored = keyStore.mayHoldKey(identity.kid)
        var unwrapped: ByteArray? = null
        var oldKey: ByteArray? = null
        var newKey: ByteArray? = null
        try {
            if (!stored) {
                if (recoveryKey == null) throw LibraryVaultFailure.RecoveryCodeRequired()
                unwrapped = try {
                    KeyWrap.unwrap(identity.wrapRecovery, recoveryKey, KeyWrap.Purpose.RECOVERY, identity.kid, salt)
                } catch (_: Exception) {
                    throw LibraryVaultFailure.IncorrectRecoveryCode()
                }
            }
            // No records means nothing to open: the old key is not needed, or asked for.
            oldKey = if (existing.records.isEmpty()) null else authenticatedVaultKey(reason)
            newKey = if (unwrapped != null) {
                keyStore.store(unwrapped, identity.kid)
                unwrapped.copyOf()
            } else {
                try {
                    keyStore.load(identity.kid)
                } catch (_: VaultKeyStoreException) {
                    throw LibraryVaultFailure.KeyUnavailable()
                }
            }
            resealVault(existing.kid, existing.vaultSalt, oldKey, identity, newKey)
        } finally {
            unwrapped?.fill(0)
            oldKey?.fill(0)
            newKey?.fill(0)
        }
    }

    /** Unlocks this device's vault for one operation and returns its key to the caller, who wipes it. */
    private suspend fun authenticatedVaultKey(reason: VaultAuthenticationReason): ByteArray = mappingSessionFailures {
        session.withOneUseAuthentication(reason) { session.currentKey() }
    }

    /**
     * A losing secure version that has not become a record of its own yet: in a vault
     * record's passthrough bag, in the projection sidecar, or waiting in the journal.
     */
    private fun hasUnresolvedSecureConflicts(document: VaultDocument): Boolean {
        val inRecords = document.records.any { record ->
            record.x.keys.any { it.startsWith(CONTENT_CONFLICT_OPAQUE_CARRIER_PREFIX) || it.startsWith(CONTENT_CONFLICT_PREFIX) }
        }
        return inRecords || sync.hasPendingSecureConflicts()
    }

    /** The one write that replaces the vault key. [oldKey] may be `null` only for a vault without records. */
    private fun resealVault(
        sourceKid: String,
        sourceVaultSalt: String,
        oldKey: ByteArray?,
        identity: LibraryVaultIdentity,
        newKey: ByteArray,
    ) {
        val newSalt = identity.vaultSaltBytes ?: throw LibraryVaultFailure.Unreadable()
        val updated = try {
            SnippetCrypto.Keyring(newKey, newSalt).use { new ->
                vaultFile.update(lockTimeoutMillis) { existing ->
                    val vault = existing ?: throw LibraryVaultFailure.Unreadable()
                    // Already there: a retry after the write landed.
                    if (isSameVault(vault, identity)) return@update vault
                    // Read under the lock: another writer may have replaced the vault since.
                    val oldSalt = vault.vaultSaltBytes
                    if (vault.kid != sourceKid || vault.vaultSalt != sourceVaultSalt || oldSalt == null) {
                        throw LibraryVaultFailure.Unreadable()
                    }
                    val records = if (vault.records.isEmpty()) {
                        vault.records
                    } else {
                        if (oldKey == null) throw LibraryVaultFailure.KeyUnavailable()
                        SnippetCrypto.Keyring(oldKey, oldSalt).use { old ->
                            vault.records.map { record ->
                                val plaintext = try {
                                    SnippetCrypto.open(record.sealed, SnippetCrypto.RecordContext(sourceKid, record.id), old)
                                } catch (_: SnippetCrypto.Failure) {
                                    throw LibraryVaultFailure.Unreadable()
                                }
                                try {
                                    record.copy(
                                        sealed = SnippetCrypto.seal(
                                            plaintext, SnippetCrypto.RecordContext(identity.kid, record.id), new,
                                        ),
                                        contentHash = SnippetCrypto.contentHash(plaintext, new),
                                    )
                                } finally {
                                    plaintext.fill(0)
                                }
                            }
                        }
                    }
                    vault.copy(
                        kid = identity.kid,
                        vaultSalt = identity.vaultSalt,
                        kdf = identityKdf(identity.kdf),
                        // Wraps of the old key open nothing in this vault any more.
                        wrapPass = null,
                        wrapCLI = null,
                        wrapRecovery = identity.wrapRecovery,
                        records = records,
                        // Receipts describe conflict copies of the library this vault is leaving.
                    ).removingLocalConflictInstallReceipts()
                }
            }
        } catch (failure: LibraryVaultFailure) {
            throw failure
        } catch (_: Exception) {
            throw LibraryVaultFailure.Unreadable()
        }
        val changed = updated != document
        setDocument(updated)
        session.adopt(updated.kid)
        session.keyAvailabilityKnown(keyStore.mayHoldKey(updated.kid), updated.kid)
        // The old key is done here. Android keys are device-only, so nothing else needs it.
        if (updated.kid != sourceKid) deleteKeyQuietly(sourceKid)
        if (changed) notifyChanged()
    }

    // Content, requires an unlocked vault

    /** The decrypted body. The caller owns the array and wipes it (or hands it to a [SecurePlaintextLease]). */
    @Throws(Failure::class, VaultSession.Failure::class, SnippetCrypto.Failure::class)
    fun contentData(id: UUID): ByteArray {
        val document = requireDocument()
        val record = document.record(id) ?: throw Failure.NoSuchRecord()
        return keyring(document).use { SnippetCrypto.open(record.sealed, context(id, document), it) }
    }

    /** The body as a `String`, which cannot be wiped: the last hop before it is shown. */
    @Throws(Failure::class, VaultSession.Failure::class, SnippetCrypto.Failure::class)
    fun content(id: UUID): String {
        val plaintext = contentData(id)
        try {
            return SnippetCrypto.plaintextString(plaintext) ?: throw Failure.InvalidUtf8()
        } finally {
            plaintext.fill(0)
        }
    }

    /**
     * The body for one authenticated action such as copying: asks the device owner afresh
     * (always, even inside an open session, which it ends), decrypts, and locks again
     * before returning. The plaintext is in the returned lease and nowhere else; wipe it
     * (`use { }`) as soon as the action is done.
     *
     * @throws VaultSession.Failure.Authentication when the owner check did not succeed;
     *   a cancelled prompt is silent in the UI.
     */
    @Throws(Failure::class, VaultSession.Failure::class, SnippetCrypto.Failure::class, CancellationException::class)
    suspend fun leaseContent(id: UUID, reason: VaultAuthenticationReason): SecurePlaintextLease =
        session.withOneUseAuthentication(reason) { SecurePlaintextLease.consuming(contentData(id)) }

    /**
     * Creates a secure snippet directly as ciphertext; the body never enters the ordinary
     * library. Keyword uniqueness is checked against both files under their shared lock.
     *
     * @param body UTF-8. Not modified; the caller wipes it.
     * @throws Failure.InvalidUtf8 when the keyword is empty after sanitizing or [body] is not UTF-8.
     */
    @Throws(Failure::class, VaultSession.Failure::class)
    fun addSecure(
        name: String,
        keyword: String,
        body: ByteArray,
        tags: List<String>,
        isEnabled: Boolean,
        isPinned: Boolean,
    ): UUID {
        val document = requireDocument()
        val sanitized = Snippet.sanitizedKeyword(keyword)
        if (sanitized.isEmpty() || Utf8.decodeStrict(body) == null) throw Failure.InvalidUtf8()
        val id = UUID.randomUUID()
        // Read before the file lock is taken, not inside it as on Swift's single actor:
        // a pre-lock hook on another thread would otherwise wait on this transaction.
        val key = session.currentKey()
        val outcome = try {
            runTransaction { contents ->
                val vault = contents.vault
                if (vault == null || vault.kid != document.kid || vault.vaultSalt != document.vaultSalt) {
                    throw Failure.SetupChanged()
                }
                val folded = SnippetTagging.filterKey(sanitized)
                val taken = (contents.snippets + vault.shells).any {
                    SnippetTagging.filterKey(it.normalizedKeyword) == folded
                }
                if (taken) throw Failure.Transaction("keyword already exists")
                keyring(key, vault).use { ring ->
                    val timestamp = now()
                    val record = VaultRecord(
                        id = id, name = name, keyword = sanitized,
                        tags = SnippetTagging.normalizedTags(tags), isEnabled = isEnabled, isPinned = isPinned,
                        createdAt = timestamp, updatedAt = timestamp, hlc = nextClock(),
                        contentHash = SnippetCrypto.contentHash(body, ring),
                        sealed = SnippetCrypto.seal(body, context(id, vault), ring),
                    )
                    contents.vault = vault.copy(records = vault.records + record)
                }
            }
        } finally {
            key.fill(0)
        }
        adopt(outcome.vault, notifyChange = true)
        return id
    }

    /** Replaces the body. Updates `sealed`, `contentHash`, `updatedAt` and the clock together. */
    @Throws(Failure::class, VaultSession.Failure::class)
    fun setContent(content: String, id: UUID) {
        val plaintext = Utf8.encode(content)
        try {
            setContent(plaintext, id)
        } finally {
            plaintext.fill(0)
        }
    }

    /** As [setContent] for a body that never became a `String`. [plaintext] is not modified; the caller wipes it. */
    @Throws(Failure::class, VaultSession.Failure::class)
    fun setContent(plaintext: ByteArray, id: UUID) {
        val document = requireDocument()
        if (document.record(id) == null) throw Failure.NoSuchRecord()
        val (sealed, hash) = keyring(document).use { ring ->
            SnippetCrypto.seal(plaintext, context(id, document), ring) to SnippetCrypto.contentHash(plaintext, ring)
        }
        mutateVault { vault ->
            // Sealed under `document`'s key and kid. Swift cannot be interleaved between the
            // seal and this write; here another thread can replace the vault in between, and
            // that vault must not receive ciphertext no device can open.
            if (vault.kid != document.kid || vault.vaultSalt != document.vaultSalt) throw Failure.SetupChanged()
            vault.copy(
                records = vault.records.map { record ->
                    if (record.id != id) {
                        record
                    } else {
                        record.copy(sealed = sealed, contentHash = hash, updatedAt = now(), hlc = nextClock())
                    }
                },
            )
        }
    }

    /** Renames, retags, enables, pins. No key required. A `null` argument leaves that field alone. */
    @Throws(Failure::class)
    fun updateMetadata(
        id: UUID,
        name: String? = null,
        keyword: String? = null,
        tags: List<String>? = null,
        isEnabled: Boolean? = null,
        isPinned: Boolean? = null,
    ) {
        mutateVault { vault ->
            vault.copy(
                records = vault.records.map { record ->
                    if (record.id != id) {
                        record
                    } else {
                        record.copy(
                            name = name ?: record.name,
                            keyword = keyword?.let(Snippet::sanitizedKeyword) ?: record.keyword,
                            tags = tags?.let(SnippetTagging::normalizedTags) ?: record.tags,
                            isEnabled = isEnabled ?: record.isEnabled,
                            isPinned = isPinned ?: record.isPinned,
                            updatedAt = now(),
                            hlc = nextClock(),
                        )
                    }
                },
            )
        }
    }

    /** Deletes a secure snippet. No key required: destroying ciphertext does not need the ability to read it. */
    @Throws(Failure::class)
    fun delete(id: UUID) {
        mutateVault { vault -> vault.copy(records = vault.records.filter { it.id != id }) }
    }

    // Moving between the two files

    /**
     * Makes an ordinary snippet secure: seals it into the vault and removes it from
     * `snippets.json`. Requires an unlocked vault.
     *
     * The record keeps the snippet's id, creation time, tags and flags. Its name is the
     * explicit name only, never the display name, which falls back to the first content
     * line and would put secure content into plaintext metadata.
     *
     * @param notifyChange `false` when the caller reloads the ordinary store too and
     *   announces one change afterwards with [coordinatedMoveDidFinish].
     */
    @Throws(Failure::class, VaultSession.Failure::class)
    fun promote(snippetId: UUID, notifyChange: Boolean = true) {
        val document = requireDocument()
        val key = session.currentKey()
        val outcome = try {
            runTransaction { contents ->
                val index = contents.snippets.indexOfFirst { it.id == snippetId }
                if (index < 0) throw Failure.NoSuchRecord()
                val vault = contents.vault ?: document
                // The session's key belongs to `document`. Sealing into a vault that was
                // replaced meanwhile would create ciphertext no device can open.
                if (vault.kid != document.kid || vault.vaultSalt != document.vaultSalt) throw Failure.SetupChanged()
                if (vault.record(snippetId) != null) throw Failure.AlreadySecure()

                val snippet = contents.snippets[index]
                val plaintext = Utf8.encode(snippet.content)
                val record = try {
                    keyring(key, vault).use { ring ->
                        val timestamp = now()
                        val sealed = SnippetCrypto.seal(plaintext, context(snippet.id, vault), ring)
                        val contentHash = SnippetCrypto.contentHash(plaintext, ring)
                        val prepared = sync.prepareMove(contents.snippets, vault.records, vault.kid, snippet.id)
                        val destination = VaultRecord(
                            id = snippet.id,
                            name = snippet.name,
                            keyword = snippet.normalizedKeyword,
                            tags = SnippetTagging.normalizedTags(snippet.tags),
                            isEnabled = snippet.isEnabled,
                            isPinned = snippet.isPinned,
                            createdAt = snippet.createdAt,
                            updatedAt = timestamp,
                            hlc = stampClock(timestamp, prepared.sourceHlc),
                            contentHash = contentHash,
                            sealed = sealed,
                        )
                        // The sidecar gets the ciphertext destination before the primary files move.
                        prepared.persistPromotionDestination(destination, clockDevice())
                    }
                } finally {
                    plaintext.fill(0)
                }

                contents.vault = vault.copy(records = vault.records + record)
                contents.snippets = contents.snippets.filterIndexed { position, _ -> position != index }
                // Only matters after a crash between the two writes.
                contents.marker = MoveMarker.Promoting(snippetId)
            }
        } finally {
            key.fill(0)
        }
        adopt(outcome.vault, notifyChange)
    }

    /**
     * Turns a secure snippet back into an ordinary one, inserted at the front of the
     * library. Requires an unlocked vault. Refused when the record carries metadata this
     * build does not understand.
     */
    @Throws(Failure::class, VaultSession.Failure::class)
    fun demote(recordId: UUID, notifyChange: Boolean = true) {
        requireDocument()
        val key = session.currentKey()
        val outcome = try {
            runTransaction { contents ->
                val vault = contents.vault ?: throw Failure.NotSecure()
                val index = vault.records.indexOfFirst { it.id == recordId }
                if (index < 0) throw Failure.NotSecure()
                val record = vault.records[index]
                if (!supportsDemotion(record.x)) {
                    throw Failure.Transaction(
                        "this secure snippet contains metadata from a newer build; update " +
                            "Snippets before making it non-secure",
                    )
                }
                // Decrypt the locked snapshot that is about to be removed, not the copy in
                // memory: that one may predate a concurrent edit of the body.
                val plaintext = keyring(key, vault).use { ring ->
                    SnippetCrypto.open(record.sealed, context(recordId, vault), ring)
                }
                val content = try {
                    SnippetCrypto.plaintextString(plaintext) ?: throw Failure.InvalidUtf8()
                } finally {
                    plaintext.fill(0)
                }
                val snippet = Snippet(
                    record.id, record.name, record.keyword, content, record.tags,
                    record.isEnabled, record.isPinned, record.createdAt, now(),
                )
                // Never the decrypted destination: the sidecar gets the secure source.
                sync.prepareMove(contents.snippets, vault.records, vault.kid, record.id).persistDemotionSource()

                contents.vault = vault.copy(records = vault.records.filterIndexed { position, _ -> position != index })
                contents.snippets = listOf(snippet) + contents.snippets
                contents.marker = MoveMarker.Demoting(recordId)
            }
        } finally {
            key.fill(0)
        }
        adopt(outcome.vault, notifyChange)
    }

    /** Announces a move whose notification was deferred until both stores had been reloaded. */
    fun coordinatedMoveDidFinish() {
        notifyChanged()
    }

    /**
     * Removes every secure snippet from this device, with the vault key.
     *
     * Order: the sync bookkeeping is pruned first, then the vault file is removed
     * durably, then the key is deleted, last. A failure at any step restores what the
     * earlier steps changed, so the operation stays retryable. This cannot prove another
     * copy of the ciphertext exists; the confirmation must say so.
     *
     * @param syncIsQuiescent whether no sync round is running.
     */
    @Throws(Failure::class)
    fun forgetEverything(syncIsQuiescent: Boolean) {
        if (isUnreadable) throw Failure.VaultUnreadable("the vault could not be read; refusing to remove it")
        // With sync running, the next fetch would bring the records back.
        if (policy.syncIsEnabled) throw Failure.ForgetRequiresSyncOff()
        if (!syncIsQuiescent) throw Failure.ForgetWaitForSync()

        val held = guard.acquire(lockTimeoutMillis)
            ?: throw Failure.Transaction("another writer holds the vault; try again")
        try {
            val onDisk = when (val outcome = vaultFile.load()) {
                is VaultLoadOutcome.Loaded -> outcome.value
                is VaultLoadOutcome.Missing -> null
                is VaultLoadOutcome.TooNew -> throw Failure.VaultUnreadable(
                    "vault schemaVersion ${outcome.version} is newer than this build; refusing to remove it",
                )
                is VaultLoadOutcome.Unreadable, is VaultLoadOutcome.Corrupt ->
                    throw Failure.VaultUnreadable("the vault could not be read; refusing to remove it")
            }
            val rollbackDocument = onDisk ?: document
            val kid = rollbackDocument?.kid
            val records = rollbackDocument?.records ?: emptyList()

            val prepared = try {
                sync.prepareForget(records.mapTo(HashSet()) { it.id }, records, kid)
            } catch (refused: SecureForgetRefused) {
                throw Failure.Transaction(refused.detail)
            }

            // The post-forget protocol state lands before the ciphertext or its key go.
            try {
                prepared.writePrunedState()
            } catch (refused: SecureForgetRefused) {
                val rollback = rollbackForget(null, prepared)
                throw Failure.Transaction(
                    "could not durably preserve ordinary sync state before forgetting the vault: ${refused.detail}$rollback",
                )
            }

            try {
                // Durable: the removal must survive a crash before the key is deleted.
                io.removeDurably(vaultFile.file)
            } catch (failure: IOException) {
                val rollback = rollbackForget(rollbackDocument, prepared)
                throw Failure.Transaction("could not durably delete the vault: ${failure.javaClass.simpleName}$rollback")
            }

            if (kid != null) {
                try {
                    keyStore.delete(kid)
                } catch (_: VaultKeyStoreException) {
                    // A refusal is a failed transaction: restore the vault and the exact protocol state.
                    val rollback = rollbackForget(rollbackDocument, prepared)
                    throw Failure.Transaction("the key store kept the vault key; the vault was restored$rollback")
                }
            }

            setDocument(null)
        } finally {
            held.close()
        }
        // After the lock is released, unlike Swift: adopting locks an open session, and its
        // pre-lock hooks save pending edits through this same lock, which is not reentrant.
        // Under the lock each save would wait out the full timeout first.
        session.adopt(null)
        notifyChanged()
    }

    /** Best-effort rollback: the vault first, so secure journal intent is never exposed without its ciphertext. */
    private fun rollbackForget(vault: VaultDocument?, prepared: PreparedSecureForget): String {
        val failures = ArrayList<String>()
        if (vault != null) {
            try {
                vaultFile.write(vault)
                setDocument(vault)
            } catch (failure: VaultFileError) {
                failures.add("vault restore failed: ${failure.message}")
            }
        }
        failures.addAll(prepared.rollback())
        return if (failures.isEmpty()) {
            "; original state was restored"
        } else {
            "; rollback incomplete (${failures.joinToString("; ")})"
        }
    }

    // Crash recovery

    /**
     * Finishes a move that a crash interrupted. The transaction writes a move's
     * destination before it removes the source, so an interrupted move leaves the record
     * in both files. An interrupted promotion keeps the vault copy; an interrupted
     * demotion (known only from the marker) keeps the plaintext copy. With no marker the
     * vault wins, because plaintext of a secret left in `snippets.json` is the worse
     * mistake.
     *
     * @return how many duplicated records were resolved.
     */
    fun reconcileInterruptedMove(): Int {
        if (isUnreadable) return 0
        val marker = transaction.pendingMarker()
        val outcome = try {
            runTransaction { contents ->
                val vault = contents.vault ?: return@runTransaction 0
                val secureIds = vault.records.mapTo(HashSet()) { it.id }
                val duplicated = contents.snippets.filter { it.id in secureIds }
                if (duplicated.isEmpty()) return@runTransaction 0

                var resolved = 0
                for (snippet in duplicated) {
                    if (marker is MoveMarker.Demoting && marker.id == snippet.id) {
                        // The plaintext copy is the intended outcome.
                        contents.vault = vault.copy(records = vault.records.filter { it.id != marker.id })
                    } else {
                        contents.snippets = contents.snippets.filter { it.id != snippet.id }
                    }
                    resolved += 1
                }
                contents.marker = MoveMarker.None
                resolved
            }
        } catch (_: Exception) {
            return 0
        }
        if (outcome.value > 0) adopt(outcome.vault, notifyChange = true)
        return outcome.value
    }

    // For sync

    /**
     * A keyring for sync to materialize an encrypted conflict copy, only while the user
     * has already unlocked the vault. Never prompts and does not slide the idle deadline:
     * background traffic must not keep an unattended vault open. Close it when done.
     */
    @Throws(Failure::class, VaultSession.Failure::class)
    fun unlockedKeyringForSync(): SnippetCrypto.Keyring {
        val document = requireDocument()
        val salt = document.vaultSaltBytes ?: throw Failure.VaultUnreadable("the vault's salt could not be decoded")
        return session.keyringWithoutExtendingSession(salt)
    }

    // Plumbing

    @Throws(Failure::class)
    private fun requireDocument(): VaultDocument {
        if (isUnreadable) throw Failure.VaultUnreadable("the vault could not be read")
        return document ?: throw Failure.NoSuchRecord()
    }

    private fun keyring(document: VaultDocument): SnippetCrypto.Keyring {
        val salt = document.vaultSaltBytes ?: throw Failure.VaultUnreadable("the vault's salt could not be decoded")
        return session.keyring(salt)
    }

    private fun keyring(key: ByteArray, document: VaultDocument): SnippetCrypto.Keyring {
        val salt = document.vaultSaltBytes ?: throw Failure.VaultUnreadable("the vault's salt could not be decoded")
        return SnippetCrypto.Keyring(key, salt)
    }

    /** The crypto scope is the vault's own `kid`, never anything from sync state. */
    private fun context(id: UUID, document: VaultDocument) = SnippetCrypto.RecordContext(document.kid, id)

    private fun nextClock(): Hlc = synchronized(clockLock) { clock.send() }

    private fun stampClock(updatedAt: Double, baseHlc: Hlc): Hlc = synchronized(clockLock) { clock.stamp(updatedAt, baseHlc) }

    private fun clockDevice(): String = synchronized(clockLock) { clock.device }

    /** `clock.send(atLeast:)`, for records taken from a backup. */
    internal fun clockAtLeast(wallMs: Long): Hlc = synchronized(clockLock) { clock.sendAtLeast(wallMs) }

    internal fun nowSeconds(): Double = now()

    internal val vaultSession: VaultSession get() = session

    internal val vaultKeyStore: VaultKeyStore get() = keyStore

    private fun deleteKeyQuietly(kid: String) {
        try {
            keyStore.delete(kid)
        } catch (_: VaultKeyStoreException) {
            // An orphaned key opens nothing.
        }
    }

    /** A vault-only change. Takes the shared lock, because a concurrent promotion touches this file too. */
    private fun mutateVault(change: (VaultDocument) -> VaultDocument) {
        if (isUnreadable) throw Failure.VaultUnreadable("the vault could not be read")
        val updated = try {
            vaultFile.update(lockTimeoutMillis) { current -> change(current ?: throw Failure.NoSuchRecord()) }
        } catch (failure: VaultFileError) {
            throw Failure.Transaction(failure.message ?: "the vault could not be written")
        }
        // Only a real change is announced: on the content path this runs on every keystroke.
        val changed = updated != document
        setDocument(updated)
        if (changed) notifyChanged()
    }

    /**
     * Runs [body] in the two-file transaction. File and crypto failures become
     * [Failure.Transaction]; what [body] throws otherwise propagates unchanged.
     */
    internal fun <T> runTransaction(body: (LibraryVaultTransaction.Contents) -> T): LibraryVaultTransaction.Outcome<T> =
        try {
            transaction.perform(lockTimeoutMillis, body)
        } catch (failure: LibraryVaultTransaction.Failure) {
            throw Failure.Transaction(failure.message ?: "the library could not be written")
        } catch (failure: SnippetCrypto.Failure) {
            throw Failure.Transaction(failure.message ?: "the secure snippet could not be read")
        } catch (refused: SecureMoveRefused) {
            throw Failure.Transaction(refused.detail)
        }

    /** Takes over the vault a transaction left on disk. */
    internal fun adopt(vault: VaultDocument?, notifyChange: Boolean) {
        setDocument(vault)
        if (notifyChange) notifyChanged()
    }

    companion object {

        /** How long a write waits for the library lock: two seconds. */
        const val DEFAULT_LOCK_TIMEOUT_MILLIS: Long = 2_000

        // `SyncMerge`'s extension names, which are format: a vault record's bag may carry them.
        internal const val CONTENT_CONFLICT_PREFIX = "contentConflict."
        internal const val CONTENT_CONFLICT_OPAQUE_CARRIER_PREFIX = "contentConflictOpaque.v1."
        internal const val PLAIN_CONFLICT_COPY_KEY = "conflictCopy.v1"

        /** `k-` and the first twelve characters of a lowercase UUID, for example `k-7f3a91c0-1b2`. */
        internal fun newVaultKeyId(): String = "k-" + UUID.randomUUID().toString().substring(0, 12)

        private fun newPassphraseKdfParameters() = VaultKdfParameters(
            alg = PassphraseKdf.ALGORITHM,
            iterations = PassphraseKdf.ITERATIONS,
            saltP = Base64Url.encode(Bytes.random(PassphraseKdf.SALT_BYTE_COUNT)),
        )

        // Only `alg`, `iterations` and `saltP` belong to a vault's identity; a `kdf` bag stays where it is.
        private fun identityKdf(kdf: VaultKdfParameters) = VaultKdfParameters(kdf.alg, kdf.iterations, kdf.saltP)

        private fun isSameVault(document: VaultDocument, identity: LibraryVaultIdentity): Boolean =
            document.kid == identity.kid && document.vaultSalt == identity.vaultSalt

        /** A record goes back to the ordinary library only when everything in its bag is understood. */
        private fun supportsDemotion(values: Map<String, *>): Boolean = values.keys.all { key ->
            key == PLAIN_CONFLICT_COPY_KEY ||
                key.startsWith(CONTENT_CONFLICT_OPAQUE_CARRIER_PREFIX) ||
                key.startsWith(CONTENT_CONFLICT_PREFIX)
        }

        /**
         * Opens a sealed body under [sourceId] and seals it again under [targetId] in the
         * same vault: what materializing a secure conflict copy needs. When
         * [expectedContentHash] is given, the keyed hash of the body must equal it.
         *
         * @return the new envelope text and the keyed content hash of the body, or `null`
         *   when the hash did not match.
         * @throws SnippetCrypto.Failure when the body does not open under this vault's key.
         */
        @Throws(SnippetCrypto.Failure::class)
        fun resealUnderAnotherId(
            sealed: String,
            vaultKid: String,
            sourceId: UUID,
            targetId: UUID,
            keyring: SnippetCrypto.Keyring,
            expectedContentHash: String? = null,
            nonces: NonceSource = NonceSource.System,
        ): Pair<String, String>? {
            val plaintext = SnippetCrypto.open(sealed, SnippetCrypto.RecordContext(vaultKid, sourceId), keyring)
            try {
                val hash = SnippetCrypto.contentHash(plaintext, keyring)
                if (expectedContentHash != null && hash != expectedContentHash) return null
                return SnippetCrypto.seal(plaintext, SnippetCrypto.RecordContext(vaultKid, targetId), keyring, nonces) to hash
            } finally {
                plaintext.fill(0)
            }
        }

        /**
         * Whether [sealed] opens as record [recordId] of the vault [vaultKid] and its keyed
         * content hash is [expectedContentHash]: how the conflict materializer checks a
         * copy that is already in the vault before it trusts it. The plaintext is wiped
         * before this returns.
         *
         * @throws SnippetCrypto.Failure when the body does not open under this key and id.
         */
        @Throws(SnippetCrypto.Failure::class)
        fun authenticateSealed(
            sealed: String,
            vaultKid: String,
            recordId: UUID,
            expectedContentHash: String,
            keyring: SnippetCrypto.Keyring,
        ): Boolean {
            val plaintext = SnippetCrypto.open(sealed, SnippetCrypto.RecordContext(vaultKid, recordId), keyring)
            try {
                return SnippetCrypto.contentHash(plaintext, keyring) == expectedContentHash
            } finally {
                plaintext.fill(0)
            }
        }
    }
}
