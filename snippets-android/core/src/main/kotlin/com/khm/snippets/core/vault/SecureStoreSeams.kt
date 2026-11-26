package com.khm.snippets.core.vault

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.model.Snippet
import java.util.UUID

/**
 * The narrow view the ordinary library store has of the vault
 * (`SecureSnippetProviding`). It can learn that secure records exist and what their
 * metadata is; it cannot reach a key, a ciphertext or a plaintext through this, which is
 * what keeps the type that owns export, undo and the write path unable to leak a secret.
 */
interface SecureSnippetProviding {
    /** Content-free shells: real ids, names, keywords and tags, with empty content. */
    fun secureShellsForDisplay(): List<Snippet>
    fun isSecure(id: UUID): Boolean
}

/**
 * What the selected sync provider means for the vault. The provider selection lives
 * outside `:core.vault`; its owner supplies this.
 */
interface VaultProviderPolicy {

    /**
     * `true` while the selected provider's library owns the vault: a Git library names
     * its vault in `keys/vault.json` and carries its key under the library's recovery
     * code. Then nothing on this device may mint a vault (a second `kid` is a second
     * crypto scope that every other device refuses), and a vault whose key is missing is
     * a matter for the library's setup, not for a recovery key.
     */
    val libraryOwnsVault: Boolean

    /** Whether sync is switched on. Removing the vault from this device is refused while it is. */
    val syncIsEnabled: Boolean

    /** A device with no provider: it creates and owns its vault. */
    object LocalOnly : VaultProviderPolicy {
        override val libraryOwnsVault: Boolean get() = false
        override val syncIsEnabled: Boolean get() = false
    }
}

/**
 * A library's vault as the library publishes it (`GitSyncVault.Identity`): the identity
 * every device of that library must share, and the vault key under the library's
 * recovery code. The Git key-file code converts to and from this; nothing here reads or
 * writes `keys/vault.json`.
 */
data class LibraryVaultIdentity(
    val kid: String,
    /** base64url, unpadded, as in [VaultDocument.vaultSalt]. */
    val vaultSalt: String,
    /** The passphrase-wrap parameters, so that devices sharing a vault keep one identity. Its `x` bag does not travel. */
    val kdf: VaultKdfParameters,
    /** The vault key under the library's recovery code (`KeyWrap`, purpose `recovery`). */
    val wrapRecovery: String,
) {
    val vaultSaltBytes: ByteArray? get() = com.khm.snippets.core.crypto.Base64Url.decode(vaultSalt)

    override fun toString(): String = "LibraryVaultIdentity(redacted)"
}

/** A promotion or demotion cannot go ahead because the sync bookkeeping could not be read or is malformed. */
class SecureMoveRefused(val detail: String) : Exception(detail)

/** Removing the vault cannot go ahead, or could not complete, because of the sync bookkeeping. */
class SecureForgetRefused(val detail: String) : Exception(detail)

/**
 * What the vault needs from the sync bookkeeping: the projection sidecar
 * (`Sync/library-metadata.json`) and the active provider's agreed base and journal. The
 * sync projection package implements it; `:core.vault` never reads those files itself.
 *
 * Every implementation is fail-closed: anything it cannot read counts as evidence.
 */
interface SecureSyncBookkeeping {

    /**
     * Whether this device's vault has ever been used for sync: any envelope in the
     * projection sidecar or the agreed base that is secure or carries a `vaultKID`. A
     * vault with no records and no such history is unused, and joining a library may
     * replace it. A file that is unreadable or from a newer build counts as `true`.
     */
    fun hasSecureSyncHistory(): Boolean

    /**
     * Whether a losing side of a secure sync conflict is still held as ciphertext under
     * the current vault key, in the projection sidecar or the journal (the store checks
     * the vault records' own bags itself). Replacing the key now would strand it.
     * Anything unreadable counts as `true`.
     */
    fun hasPendingSecureConflicts(): Boolean

    /**
     * Called inside the library transaction, on the locked snapshot, before a snippet
     * moves between the files (`transitionEnvelope`). Reads the sidecar, base and journal,
     * projects the current envelope of [id] and validates its conflict metadata.
     *
     * @param id the snippet (promotion) or secure record (demotion) that is about to move.
     * @throws SecureMoveRefused when any of that cannot be read, is from a newer build,
     *   is inconsistent (a journal without a base, an established journal that is
     *   missing) or carries malformed conflict metadata. The move does not happen.
     */
    @Throws(SecureMoveRefused::class)
    fun prepareMove(snippets: List<Snippet>, records: List<VaultRecord>, vaultKid: String, id: UUID): PreparedSecureMove

    /**
     * Called by `forgetEverything` under the library lock, before anything is removed.
     * Validates that the bookkeeping can be preserved and computes its state without the
     * forgotten secure records (ordinary pending intent survives; secure confirmations,
     * offers, conflict carriers and record versions owned only by the vault go).
     *
     * @param forgottenIds the ids of the secure records that are about to be removed.
     * @throws SecureForgetRefused when the bookkeeping cannot be read or is inconsistent.
     */
    @Throws(SecureForgetRefused::class)
    fun prepareForget(forgottenIds: Set<UUID>, records: List<VaultRecord>, vaultKid: String?): PreparedSecureForget

    /** A device that has never synced: no sidecar, no base, no journal, nothing to preserve. */
    object None : SecureSyncBookkeeping {
        override fun hasSecureSyncHistory(): Boolean = false
        override fun hasPendingSecureConflicts(): Boolean = false

        override fun prepareMove(
            snippets: List<Snippet>,
            records: List<VaultRecord>,
            vaultKid: String,
            id: UUID,
        ): PreparedSecureMove {
            val sourceHlc = records.firstOrNull { it.id == id }?.hlc
                ?: snippets.firstOrNull { it.id == id }?.let { Hlc.foreign(it.updatedAt) }
                ?: throw SecureMoveRefused("snippet changed while preparing its secure move")
            return object : PreparedSecureMove {
                override val sourceHlc: Hlc = sourceHlc
                override fun persistPromotionDestination(destination: VaultRecord, origin: String) = destination
                override fun persistDemotionSource() = Unit
            }
        }

        override fun prepareForget(
            forgottenIds: Set<UUID>,
            records: List<VaultRecord>,
            vaultKid: String?,
        ): PreparedSecureForget = object : PreparedSecureForget {
            override fun writePrunedState() = Unit
            override fun rollback(): List<String> = emptyList()
        }
    }
}

/** The projected envelope of a record that is about to move, and the sidecar writes that go with the move. */
interface PreparedSecureMove {

    /** The clock of the record's current envelope. A promotion is stamped strictly above it. */
    val sourceHlc: Hlc

    /**
     * Promotion. Builds the secure envelope of [destination] (ciphertext body,
     * `vaultContentHash`, `vaultKID`, the source envelope's other extensions), writes it
     * to the projection sidecar durably, and returns the record to install: [destination]
     * with the passthrough members the envelope's extensions project to (conflict
     * carriers, `conflictCopy.v1`).
     *
     * The sidecar is written before the primary files move and holds ciphertext only. If
     * the move then fails, the still-plain snippet stays authoritative and the sidecar
     * entry is treated as metadata.
     *
     * @param origin the device id of this store's clock, for the envelope.
     */
    @Throws(SecureMoveRefused::class)
    fun persistPromotionDestination(destination: VaultRecord, origin: String): VaultRecord

    /**
     * Demotion. Writes the secure **source** envelope to the projection sidecar. Never
     * the decrypted destination: a crash after that write would leave the plaintext body
     * in the sidecar while the vault still holds the record.
     */
    @Throws(SecureMoveRefused::class)
    fun persistDemotionSource()
}

/** The validated plan for the sync bookkeeping of a vault that is about to be removed. */
interface PreparedSecureForget {

    /**
     * Writes the pruned projection sidecar first, then base and journal (those two only
     * when at least one existed), all durably. On failure nothing more is attempted; the
     * caller calls [rollback].
     */
    @Throws(SecureForgetRefused::class)
    fun writePrunedState()

    /**
     * Restores the exact files from before [writePrunedState]: the journal before the
     * base, files that did not exist removed again. Every restoration is attempted; the
     * result describes each one that failed and is empty when all succeeded.
     */
    fun rollback(): List<String>
}
