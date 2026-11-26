package com.khm.snippets.android.data

import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

/** Who owns the vault's key material. */
enum class VaultOwner {
    /** A local vault: restored with its recovery key. */
    Device,

    /** The vault of a Git library: opened with the library's recovery code, managed in Sync. */
    GitLibrary,
}

/** Why the session locked. Only the automatic causes are explained to the user. */
enum class VaultLockCause { Manual, IdleTimeout, SessionExpired, LeftApp, OneUseAuthentication }

/** @param hasRecoveryKey False for an older local vault that can still add one. */
data class VaultDetails(val owner: VaultOwner = VaultOwner.Device, val hasRecoveryKey: Boolean = true)

/** The vault as the UI observes it. */
sealed interface VaultState {
    /** No vault yet. Making a snippet secure creates one (not while Git is the provider). */
    data object NoVault : VaultState

    /** A vault exists and its key is on this device; bodies stay encrypted until authentication. */
    data class Locked(val details: VaultDetails = VaultDetails(), val lastLock: VaultLockCause? = null) : VaultState

    /**
     * A session is open: reveal needs no prompt.
     *
     * @param deadlineMillis When the session locks if nothing extends it, on the [MonotonicClock].
     */
    data class Unlocked(val details: VaultDetails = VaultDetails(), val deadlineMillis: Long) : VaultState

    /** A vault exists but this device has no key for it. Secure entries stay listed and synced. */
    data class KeyMissing(val owner: VaultOwner) : VaultState

    data class Unavailable(val cause: VaultUnavailableCause) : VaultState
}

enum class VaultUnavailableCause {
    /** The device has no screen lock, so nothing can authenticate its owner. */
    NoScreenLock,

    /** `vault.json` could not be read or was written by a newer version. */
    Unreadable,
}

/** Why a vault operation failed. The UI phrases each case (screens-secure.md §9). */
sealed interface VaultError {
    data object Locked : VaultError
    data object NoKey : VaultError

    /** The key for this vault has not reached this device. */
    data object KeyNotOnDevice : VaultError

    /** Git is the provider and its library vault is not set up on this device. */
    data object GitVaultSetupRequired : VaultError
    data object ScreenLockRequired : VaultError

    /** The prompt ended without approval (not a cancellation). */
    data object AuthenticationNotApproved : VaultError

    /**
     * Lockout, timeout or missing hardware. [systemMessage] is the platform's own, already
     * localised sentence and is shown as it is; it is the one text that crosses this boundary.
     */
    data class AuthenticationBlocked(val systemMessage: String) : VaultError

    /** The record carries metadata from a newer version and cannot be made ordinary here. */
    data object NewerMetadata : VaultError
    data object KeywordExists : VaultError
    data object SnippetMissing : VaultError

    /** The decrypted body is not valid text. */
    data object InvalidText : VaultError

    /** The vault changed while its setup was on screen. */
    data object SetupChanged : VaultError
    data object RecoveryKeyTypo : VaultError
    data class RecoveryKeyInvalidCharacter(val character: String) : VaultError
    data class RecoveryKeyWrongLength(val expected: Int, val actual: Int) : VaultError
    data object NoRecoveryKey : VaultError

    /** Well-formed, but it does not open this vault. */
    data object RecoveryKeyMismatch : VaultError

    /** Removing the vault is refused while sync is on. */
    data object SyncIsOn : VaultError
    data object Unknown : VaultError
}

/** The result of an operation behind authentication. A cancelled prompt is not an error. */
sealed interface VaultResult<out T> {
    data class Success<out T>(val value: T) : VaultResult<T>

    /** The user dismissed the prompt. Show nothing (DESIGN.md D15). */
    data object Cancelled : VaultResult<Nothing>

    data class Failure(val error: VaultError) : VaultResult<Nothing>
}

/**
 * A recovery key that was generated but not stored yet. It is shown once and must never reach
 * saved state, a log or the clipboard without the sensitive flag.
 *
 * @param symbols The raw symbols, without separators.
 */
class PendingRecoveryKey(val symbols: String, val groupSize: Int = 4) {
    override fun toString(): String = "PendingRecoveryKey(<hidden>)"
}

/**
 * Secure snippets: the vault, its session and the operations that need the body.
 *
 * Authentication is the vault's business: an implementation prompts through the platform
 * authenticator and reports a dismissed prompt as [VaultResult.Cancelled]. A session opens on
 * [reveal] and [makeSecure], lasts 5 minutes without secure use and 30 minutes at most, and ends
 * when the app leaves the foreground. Listing, renaming, tagging, pinning, enabling and deleting
 * secure entries go through [LibraryRepository] and need no key.
 */
interface SecureVault {
    val state: StateFlow<VaultState>

    /** The body of [id] for the editor. Prompts unless a session is open; opens or extends one. */
    suspend fun reveal(id: UUID): VaultResult<String>

    /**
     * Authenticates freshly (every time, ending any open session) and hands the body to [use]
     * for one copy or insertion. The plaintext must not outlive [use].
     */
    suspend fun <T> withBodyOnce(id: UUID, purpose: BodyPurpose, use: suspend (body: String) -> T): VaultResult<T>

    /** Saves an edited body. Needs the open session, which it extends; never prompts. */
    suspend fun updateBody(id: UUID, body: String): VaultResult<Unit>

    /**
     * Moves an ordinary entry into the vault as one transaction, keeping its id. Prompts and
     * opens a session. Needs a vault: see [prepareVaultSetup].
     */
    suspend fun makeSecure(id: UUID): VaultResult<Unit>

    /** Decrypts a secure entry into the ordinary library. Authenticates freshly every time. */
    suspend fun makeOrdinary(id: UUID): VaultResult<Unit>

    /**
     * First step of making a snippet secure. Returns null when a usable vault exists; otherwise
     * the recovery key of a vault that is created only by [commitVaultSetup].
     */
    suspend fun prepareVaultSetup(): VaultResult<PendingRecoveryKey?>

    /** Creates the vault after the user acknowledged its recovery key. */
    suspend fun commitVaultSetup(pending: PendingRecoveryKey): VaultResult<Unit>

    /** Adds a recovery key to a vault without one: authenticates, then returns the key to show. */
    suspend fun prepareRecoveryKey(): VaultResult<PendingRecoveryKey>

    suspend fun commitRecoveryKey(pending: PendingRecoveryKey): VaultResult<Unit>

    /** Forgets a prepared setup or key; nothing was stored. */
    fun discard(pending: PendingRecoveryKey)

    /** Restores the vault key from the recovery key the user typed (any grouping or case). */
    suspend fun restoreKey(recoveryKey: String): VaultResult<Unit>

    /** Removes every secure snippet and the vault key from this device. Refused while sync is on. */
    suspend fun removeVault(): VaultResult<Unit>

    /**
     * Ends the session. Pre-lock hooks run first, while the key is still usable, so an editor
     * can save a pending edit.
     */
    suspend fun lock(cause: VaultLockCause = VaultLockCause.Manual)

    /** Registers work to run right before every lock. Close the handle to unregister. */
    fun addPreLockHook(hook: suspend () -> Unit): AutoCloseable
}

/** What a one-use body is for; selects the authentication prompt. */
enum class BodyPurpose { Copy, Insert }
