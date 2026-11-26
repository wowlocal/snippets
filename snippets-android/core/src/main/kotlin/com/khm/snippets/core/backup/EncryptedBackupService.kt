package com.khm.snippets.core.backup

import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.Pbkdf2HmacSha512
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.vault.KeyPresence
import com.khm.snippets.core.vault.SecureSnippetStore
import com.khm.snippets.core.vault.VaultAuthenticationReason
import com.khm.snippets.core.vault.VaultDocument
import com.khm.snippets.core.vault.VaultKeyStoreException
import com.khm.snippets.core.vault.VaultSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.coroutines.CoroutineContext

/**
 * What the backup flows need from the store of ordinary snippets. The library store
 * implements it.
 */
interface OrdinaryLibraryHost {

    /** True while `snippets.json` could not be read and was moved aside. */
    val isLibraryQuarantined: Boolean

    /** Writes any pending in-memory change to `snippets.json`, synchronously. */
    fun flushPendingWrites()

    /**
     * Re-reads `snippets.json` after a transaction wrote underneath the store. Called
     * right away rather than left to an observer, so a stale editor write cannot land on
     * top of an import.
     */
    fun reloadAfterExternalWrite()
}

/**
 * Creating and restoring encrypted backups against the live library
 * (`makeEncryptedBackup`, `prepareEncryptedBackupImport` and
 * `importPreparedEncryptedBackup` in `SecureSnippetStore.swift`).
 *
 * Restoring is two-phase: [prepareImport] authenticates and validates everything and
 * yields exact counts for a confirmation; nothing is written until [importPrepared]. The
 * two library files then change in one transaction.
 *
 * @param kdfContext where the password KDF runs (600 000 rounds).
 * @param ioContext where files and the key store are touched.
 * @param pbkdf2 the PBKDF2 implementation, for tests that count or time derivations.
 */
class EncryptedBackupService(
    private val secureStore: SecureSnippetStore,
    private val host: OrdinaryLibraryHost,
    private val kdfContext: CoroutineContext = Dispatchers.Default,
    private val ioContext: CoroutineContext = Dispatchers.IO,
    private val pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
) {

    class Export internal constructor(val data: ByteArray, val ordinaryCount: Int, val secureCount: Int) {
        val totalCount: Int get() = ordinaryCount + secureCount
    }

    /** An authenticated backup waiting for confirmation. It holds the vault key: [close] it when the import is done or abandoned. */
    class PreparedImport internal constructor(internal val opened: EncryptedBackup.Opened) : AutoCloseable {
        val ordinaryCount: Int get() = opened.ordinaryCount
        val secureCount: Int get() = opened.secureCount
        val totalCount: Int get() = opened.totalCount

        override fun close() = opened.close()
    }

    data class ImportResult(val ordinaryCount: Int, val secureCount: Int) {
        val totalCount: Int get() = ordinaryCount + secureCount
    }

    private class Snapshot(val snippets: List<Snippet>, val vault: VaultDocument?, val vaultKey: ByteArray?)

    /**
     * Creates the all-library backup: every ordinary snippet and, when the vault has at
     * least one record, the whole vault as ciphertext plus its key under the backup's
     * key. Secure bodies stay sealed throughout.
     *
     * A snapshot that contains secure records asks the device owner afresh, every time.
     *
     * @param passphrase not modified; the caller wipes it.
     * @throws BackupImportFailure.LibraryRecoveryRequired while the ordinary library is quarantined.
     * @throws VaultSession.Failure when the owner check did not succeed.
     */
    @Throws(
        BackupImportFailure::class, EncryptedBackup.Failure::class, SecureSnippetStore.Failure::class,
        VaultSession.Failure::class, PassphraseKdf.Failure::class, CancellationException::class,
    )
    suspend fun makeEncryptedBackup(passphrase: CharArray, iterations: Long = PassphraseKdf.ITERATIONS): Export {
        val snapshot = withContext(ioContext) {
            if (host.isLibraryQuarantined) throw BackupImportFailure.LibraryRecoveryRequired()
            host.flushPendingWrites()
            secureStore.reload(notifyChange = false)

            if (secureStore.document?.records?.isEmpty() == false) {
                secureStore.vaultSession.withOneUseAuthentication(VaultAuthenticationReason.ExportBackup) {
                    prepareSnapshot()
                }
            } else {
                prepareSnapshot()
            }
        }
        try {
            // The KDF is deliberately expensive; it runs on the immutable snapshot, away from the caller's thread.
            val data = withContext(kdfContext) {
                EncryptedBackup.seal(snapshot.snippets, snapshot.vault, snapshot.vaultKey, passphrase, iterations, pbkdf2 = pbkdf2)
            }
            return Export(data, snapshot.snippets.size, snapshot.vault?.records?.size ?: 0)
        } finally {
            snapshot.vaultKey?.fill(0)
        }
    }

    private fun prepareSnapshot(): Snapshot {
        val contents = secureStore.runTransaction { it.snippets to it.vault }.value
        // A vault without records holds nothing worth exporting, and omitting it avoids
        // asking for a key only to preserve an unused setup. Receipts describe this
        // device's own files and are not portable.
        val exportedVault = contents.second?.takeIf { it.records.isNotEmpty() }?.removingLocalConflictInstallReceipts()
        val libraryKey = if (exportedVault == null) {
            null
        } else {
            if (secureStore.document?.kid != exportedVault.kid) {
                throw SecureSnippetStore.Failure.Transaction("the vault changed while the backup was being prepared; try again")
            }
            secureStore.vaultSession.currentKey()
        }
        return Snapshot(contents.first, exportedVault, libraryKey)
    }

    /**
     * Authenticates and validates a backup without changing either file. The result
     * carries the exact counts for the confirmation.
     *
     * @param passphrase not modified; the caller wipes it.
     */
    @Throws(EncryptedBackup.Failure::class, CancellationException::class)
    suspend fun prepareImport(data: ByteArray, passphrase: CharArray): PreparedImport =
        PreparedImport(withContext(kdfContext) { EncryptedBackup.open(data, passphrase, pbkdf2) })

    /** [prepareImport] and [importPrepared] in one step, for callers that need no confirmation. */
    @Throws(
        BackupImportFailure::class, EncryptedBackup.Failure::class, SecureSnippetStore.Failure::class,
        VaultSession.Failure::class, VaultKeyStoreException::class, CancellationException::class,
    )
    suspend fun importEncryptedBackup(data: ByteArray, passphrase: CharArray): ImportResult =
        prepareImport(data, passphrase).use { importPrepared(it) }

    /**
     * Applies an authenticated backup: a merge, never a blind replace (see
     * [BackupMerge.plan]). A backup may join a fresh device to its vault or merge into
     * the same vault; a rival vault is refused.
     *
     * While the ordinary library is quarantined only the explicit
     * [authoritativeRecovery] is legal: the backup's ordinary half then replaces the
     * unreadable library, and the vault half follows the usual rules.
     *
     * The caller still owns [prepared] and closes it.
     *
     * @throws BackupImportFailure nothing was imported.
     * @throws VaultSession.Failure when this device already holds the vault's key and the owner check did not succeed.
     * @throws VaultKeyStoreException when the backup's key could not be stored.
     */
    @Throws(
        BackupImportFailure::class, EncryptedBackup.Failure::class, SecureSnippetStore.Failure::class,
        VaultSession.Failure::class, VaultKeyStoreException::class, CancellationException::class,
    )
    suspend fun importPrepared(prepared: PreparedImport, authoritativeRecovery: Boolean = false): ImportResult =
        withContext(ioContext) {
            val quarantined = host.isLibraryQuarantined
            if (quarantined != authoritativeRecovery) throw BackupImportFailure.LibraryRecoveryRequired()
            val opened = prepared.opened
            host.flushPendingWrites()
            secureStore.reload()

            val incomingVault = opened.vault
            val incomingKey = opened.vaultKey()
            try {
                val session = secureStore.vaultSession
                val keyStore = secureStore.vaultKeyStore
                val step = BackupMerge.keyStep(
                    currentVault = secureStore.document,
                    incomingVault = incomingVault,
                    hasIncomingKey = incomingKey != null,
                    keyPresence = incomingVault?.let { keyStore.presence(it.kid) } ?: KeyPresence.ABSENT,
                )
                if (step == BackupMerge.KeyStep.NONE || incomingVault == null || incomingKey == null) {
                    return@withContext merge(opened, authoritativeRecovery)
                }

                val previousKeyId = secureStore.document?.kid
                session.adopt(incomingVault.kid)
                try {
                    when (step) {
                        BackupMerge.KeyStep.VERIFY_STORED_KEY ->
                            session.withOneUseAuthentication(VaultAuthenticationReason.ImportBackup) {
                                val currentKey = session.currentKey()
                                val same = try {
                                    Bytes.constantTimeEquals(currentKey, incomingKey)
                                } finally {
                                    currentKey.fill(0)
                                }
                                if (!same) throw BackupImportFailure.VaultKeyMismatch()
                                merge(opened, authoritativeRecovery)
                            }
                        else -> {
                            // Restoring a missing key is safe before the files move: an
                            // orphaned key is harmless, a vault without its key is not.
                            keyStore.store(incomingKey, incomingVault.kid)
                            merge(opened, authoritativeRecovery)
                        }
                    }
                } catch (failure: Exception) {
                    // No vault was installed, so the session must not keep addressing a key without a document.
                    if (secureStore.document == null) session.adopt(previousKeyId)
                    throw failure
                }
            } finally {
                incomingKey?.fill(0)
            }
        }

    private fun merge(opened: EncryptedBackup.Opened, authoritativeOrdinaryRecovery: Boolean): ImportResult {
        val importDate = secureStore.nowSeconds()
        val importedClocks = BackupMerge.importedClocks(opened.vault, importDate, secureStore::clockAtLeast)
        val plan = secureStore.runTransaction { contents ->
            BackupMerge.plan(
                currentSnippets = contents.snippets,
                currentVault = contents.vault,
                incomingSnippets = opened.snippets,
                incomingVault = opened.vault,
                importDate = importDate,
                importedClocks = importedClocks,
                authoritativeOrdinaryRecovery = authoritativeOrdinaryRecovery,
            ).also {
                contents.snippets = it.snippets
                contents.vault = it.vault
            }
        }.value

        // The transaction wrote underneath both in-memory stores: adopt the disk result now.
        host.reloadAfterExternalWrite()
        secureStore.reload()
        return ImportResult(plan.ordinaryCount, plan.secureCount)
    }
}
