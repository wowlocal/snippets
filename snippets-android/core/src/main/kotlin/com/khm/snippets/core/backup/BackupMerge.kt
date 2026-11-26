package com.khm.snippets.core.backup

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.vault.KeyPresence
import com.khm.snippets.core.vault.VaultDocument
import com.khm.snippets.core.vault.VaultRecord
import java.util.UUID

/**
 * Why a backup could not be created from, or merged into, this device's library
 * (`SecureSnippetStore.EncryptedBackupFailure`). Nothing was written.
 */
sealed class BackupImportFailure(message: String) : Exception(message) {

    /** The backup belongs to a different vault: another `kid`, or the same `kid` with another salt or schema. No re-encryption across vaults. */
    class IncompatibleVault : BackupImportFailure("the backup belongs to a different secure-snippet vault")

    /** The backup and this device hold different keys for the same vault. */
    class VaultKeyMismatch : BackupImportFailure("the backup and this device have different keys for the same vault")

    /**
     * The ordinary library is quarantined: no new backup can be made from it, and an
     * import is only the explicit recovery; or a recovery import was asked for a library
     * that is not quarantined.
     */
    class LibraryRecoveryRequired : BackupImportFailure("the ordinary snippet library is unreadable")

    /** At most [BackupMerge.MAXIMUM_REPORTED_CONFLICTS] of the records that stand in the way. The message names none of them. */
    class Conflicts(val conflicts: List<BackupMerge.Conflict>) :
        BackupImportFailure("the import conflicts with ${conflicts.size} existing snippet(s)")
}

/**
 * The restore semantics of an encrypted backup, as pure functions
 * (`mergeEncryptedBackup` and `importPreparedEncryptedBackup` in
 * `SecureSnippetStore.swift`). A restore is a merge, never a blind replace.
 *
 * [keyStep] says what has to happen to the vault key before any file changes; [plan]
 * computes both files' new contents from their current contents. The caller applies the
 * plan inside one transaction over both files, so any failure leaves both untouched.
 */
object BackupMerge {

    /** How many conflicts an import reports before it stops listing them. */
    const val MAXIMUM_REPORTED_CONFLICTS = 8

    /** What an import does about the vault key before it merges. */
    enum class KeyStep {
        /** The backup has no vault: only ordinary snippets merge. */
        NONE,

        /**
         * A key for the backup's vault is on this device (or the key store cannot say):
         * authenticate the owner afresh and require the stored key to equal the backup's
         * key byte for byte, else [BackupImportFailure.VaultKeyMismatch].
         */
        VERIFY_STORED_KEY,

        /**
         * No key for the backup's vault is here: store the backup's key first, then merge.
         * An orphaned key is harmless; a vault without its key is not. This is also the
         * legitimate way to restore a lost key.
         */
        STORE_KEY,
    }

    /**
     * @param currentVault this device's vault as loaded, or `null`.
     * @param keyPresence the key store's answer for the incoming vault's `kid`.
     * @throws BackupImportFailure.IncompatibleVault when this device has a vault with another `kid`.
     * @throws EncryptedBackup.Failure.DamagedBackup when the backup has a vault and no key for it.
     */
    @Throws(BackupImportFailure::class, EncryptedBackup.Failure::class)
    fun keyStep(
        currentVault: VaultDocument?,
        incomingVault: VaultDocument?,
        hasIncomingKey: Boolean,
        keyPresence: KeyPresence,
    ): KeyStep {
        if (incomingVault == null) return KeyStep.NONE
        if (!hasIncomingKey) throw EncryptedBackup.Failure.DamagedBackup()
        if (currentVault != null && currentVault.kid != incomingVault.kid) throw BackupImportFailure.IncompatibleVault()
        return if (keyPresence == KeyPresence.ABSENT) KeyStep.STORE_KEY else KeyStep.VERIFY_STORED_KEY
    }

    /** A record of the library that stands in the way of an import. [text] is the sentence the Apple apps show. */
    sealed class Conflict {
        abstract val text: String

        data class OrdinaryIdIsSecure(val incomingName: String, val secureName: String) : Conflict() {
            override val text get() = "$incomingName has the same ID as secure snippet $secureName."
        }

        data class OrdinaryKeywordIsSecure(val keyword: String, val secureName: String) : Conflict() {
            override val text get() = "Keyword \\$keyword belongs to secure snippet $secureName."
        }

        data class OrdinaryIdMatchesButKeywordIsTaken(
            val incomingName: String,
            val idMatchName: String,
            val keyword: String,
            val keywordOwnerName: String,
        ) : Conflict() {
            override val text
                get() = "$incomingName matches existing ID $idMatchName, but keyword \\$keyword belongs to $keywordOwnerName."
        }

        data class SecureIdIsOrdinary(val incomingName: String, val ordinaryName: String) : Conflict() {
            override val text get() = "$incomingName has the same ID as ordinary snippet $ordinaryName."
        }

        data class SecureKeywordIsOrdinary(val keyword: String, val ordinaryName: String) : Conflict() {
            override val text get() = "Keyword \\$keyword belongs to ordinary snippet $ordinaryName."
        }

        data class SecureKeywordIsTaken(val incomingName: String, val keyword: String, val ownerName: String) : Conflict() {
            override val text get() = "Secure snippet $incomingName uses keyword \\$keyword, which belongs to $ownerName."
        }

        /** A conflict names snippets: [text] is for the screen. This, for a log, names none. */
        final override fun toString(): String = javaClass.simpleName
    }

    /** The two files after the import, and the counts for the result. */
    class Plan internal constructor(
        val snippets: List<Snippet>,
        val vault: VaultDocument?,
        /** How many ordinary snippets the backup held. */
        val ordinaryCount: Int,
        /** How many secure records the backup held. */
        val secureCount: Int,
    )

    /**
     * The clock each incoming secure record gets if it is installed over or beside an
     * existing vault: fresh, local, and at least as late as both the import and the
     * record's own clock. Issued in record order, before the transaction.
     *
     * @param sendAtLeast the store's clock (`HlcGenerator.sendAtLeast`).
     */
    fun importedClocks(incomingVault: VaultDocument?, importDate: Double, sendAtLeast: (Long) -> Hlc): Map<UUID, Hlc> {
        val importWallMs = maxOf(0.0, AppleTime.unixSeconds(importDate) * 1000.0).toLong()
        val clocks = LinkedHashMap<UUID, Hlc>()
        for (record in incomingVault?.records.orEmpty()) {
            clocks[record.id] = sendAtLeast(maxOf(record.hlc.wallMs, importWallMs))
        }
        return clocks
    }

    /**
     * Merges a backup into the current contents of both files.
     *
     * - Conflicts are collected first and abort the whole import: an incoming ordinary id
     *   that is a secure id here or the reverse; a keyword that belongs to a record of
     *   the other kind; an id match whose keyword belongs to a different local record.
     * - Ordinary snippets are normalized, then: the same id replaces; otherwise the same
     *   keyword replaces, keeping the local id and creation time; otherwise the snippet
     *   is inserted at the front.
     * - With no vault here, the backup's vault document is installed as it is. With the
     *   same vault here, its records merge: one that is identical apart from merge clocks
     *   is skipped; any other replaces its match or is appended, with
     *   `updatedAt = max(importDate, its own)` and its clock from [importedClocks]. Local
     *   records that are not in the backup stay.
     * - The local recovery wrap is kept and filled from the backup only when absent.
     *   `wrapPass` and `wrapCLI` are never imported. Unknown document keys are filled
     *   only when absent. Device-local conflict receipts in the backup are dropped.
     *
     * @param authoritativeOrdinaryRecovery the explicit recovery of a quarantined ordinary
     *   library: the backup's ordinary snippets replace [currentSnippets]. The vault half
     *   follows the rules above regardless.
     * @param importDate seconds since 2001.
     * @throws BackupImportFailure.IncompatibleVault when both sides have a vault and they
     *   differ in schema version, `kid` or salt.
     * @throws BackupImportFailure.Conflicts
     */
    @Throws(BackupImportFailure::class)
    fun plan(
        currentSnippets: List<Snippet>,
        currentVault: VaultDocument?,
        incomingSnippets: List<Snippet>,
        incomingVault: VaultDocument?,
        importDate: Double,
        importedClocks: Map<UUID, Hlc>,
        authoritativeOrdinaryRecovery: Boolean = false,
    ): Plan {
        val incomingPlain = incomingSnippets.map(::normalizedBackupSnippet)
        val incoming = incomingVault?.removingLocalConflictInstallReceipts()
        val existingPlain = if (authoritativeOrdinaryRecovery) emptyList() else currentSnippets
        val existingSecure = currentVault?.records.orEmpty()

        if (incoming != null && currentVault != null) {
            if (currentVault.schemaVersion != incoming.schemaVersion ||
                currentVault.kid != incoming.kid ||
                currentVault.vaultSalt != incoming.vaultSalt
            ) {
                throw BackupImportFailure.IncompatibleVault()
            }
        }

        val conflicts = ArrayList<Conflict>()
        for (snippet in incomingPlain) {
            val secureById = existingSecure.firstOrNull { it.id == snippet.id }
            if (secureById != null) {
                conflicts.add(Conflict.OrdinaryIdIsSecure(snippet.displayName, displayName(secureById)))
                continue
            }
            val key = keywordKey(snippet.keyword)
            val secureByKeyword = if (key.isEmpty()) null else existingSecure.firstOrNull { keywordKey(it.keyword) == key }
            if (secureByKeyword != null) {
                conflicts.add(Conflict.OrdinaryKeywordIsSecure(snippet.normalizedKeyword, displayName(secureByKeyword)))
                continue
            }
            val idMatch = existingPlain.firstOrNull { it.id == snippet.id }
            if (idMatch != null && key.isNotEmpty()) {
                val keywordMatch = existingPlain.firstOrNull { it.id != snippet.id && keywordKey(it.keyword) == key }
                if (keywordMatch != null) {
                    conflicts.add(
                        Conflict.OrdinaryIdMatchesButKeywordIsTaken(
                            snippet.displayName, idMatch.displayName, snippet.normalizedKeyword, keywordMatch.displayName,
                        ),
                    )
                }
            }
        }
        for (record in incoming?.records.orEmpty()) {
            val ordinaryById = existingPlain.firstOrNull { it.id == record.id }
            if (ordinaryById != null) {
                conflicts.add(Conflict.SecureIdIsOrdinary(displayName(record), ordinaryById.displayName))
                continue
            }
            val key = keywordKey(record.keyword)
            if (key.isEmpty()) continue
            val keyword = Snippet.sanitizedKeyword(record.keyword)
            val ordinaryByKeyword = existingPlain.firstOrNull { keywordKey(it.keyword) == key }
            if (ordinaryByKeyword != null) {
                conflicts.add(Conflict.SecureKeywordIsOrdinary(keyword, ordinaryByKeyword.displayName))
                continue
            }
            val keywordMatch = existingSecure.firstOrNull { it.id != record.id && keywordKey(it.keyword) == key }
            if (keywordMatch != null) {
                conflicts.add(Conflict.SecureKeywordIsTaken(displayName(record), keyword, displayName(keywordMatch)))
            }
        }
        if (conflicts.isNotEmpty()) throw BackupImportFailure.Conflicts(conflicts.take(MAXIMUM_REPORTED_CONFLICTS))

        val mergedPlain = ArrayList(existingPlain)
        for (snippet in incomingPlain) upsertBackupSnippet(snippet, mergedPlain)

        val mergedVault = when {
            incoming == null -> currentVault
            currentVault == null -> incoming
            else -> mergeVault(currentVault, incoming, importDate, importedClocks)
        }
        return Plan(mergedPlain, mergedVault, incomingPlain.size, incoming?.records?.size ?: 0)
    }

    private fun mergeVault(
        current: VaultDocument,
        incoming: VaultDocument,
        importDate: Double,
        importedClocks: Map<UUID, Hlc>,
    ): VaultDocument {
        val records = ArrayList(current.records)
        for (record in incoming.records) {
            val index = records.indexOfFirst { it.id == record.id }
            if (index >= 0 && sameBackupRecord(records[index], record)) continue
            val installed = record.copy(
                updatedAt = maxOf(importDate, record.updatedAt),
                hlc = importedClocks[record.id] ?: record.hlc,
            )
            if (index >= 0) records[index] = installed else records.add(installed)
        }
        return current.copy(
            // This device's doors stay. The recovery wrap is portable and safe to fill;
            // passphrase and CLI wraps belong to the device that made them.
            wrapRecovery = current.wrapRecovery ?: incoming.wrapRecovery,
            x = incoming.x.filterKeys { it !in current.x } + current.x,
            records = records,
        )
    }

    private fun normalizedBackupSnippet(snippet: Snippet): Snippet = snippet.copy(
        keyword = snippet.normalizedKeyword,
        tags = SnippetTagging.normalizedTags(snippet.tags),
        updatedAt = if (snippet.updatedAt < snippet.createdAt) snippet.createdAt else snippet.updatedAt,
    )

    private fun upsertBackupSnippet(incoming: Snippet, merged: MutableList<Snippet>) {
        val sameId = merged.indexOfFirst { it.id == incoming.id }
        if (sameId >= 0) {
            merged[sameId] = incoming
            return
        }
        val key = keywordKey(incoming.keyword)
        val sameKeyword = if (key.isEmpty()) -1 else merged.indexOfFirst { keywordKey(it.keyword) == key }
        if (sameKeyword >= 0) {
            merged[sameKeyword] = incoming.copy(id = merged[sameKeyword].id, createdAt = merged[sameKeyword].createdAt)
            return
        }
        merged.add(0, incoming)
    }

    private fun keywordKey(keyword: String): String = SnippetTagging.filterKey(Snippet.sanitizedKeyword(keyword))

    private fun displayName(record: VaultRecord): String =
        FoundationText.trimWhitespaceAndNewlines(record.name).ifEmpty { "Untitled Snippet" }

    /**
     * Everything but the merge clocks, which the first import stamps locally. The exact
     * ciphertext counts, so importing a good backup can repair a record whose `sealed`
     * was damaged even when its stored hash survived.
     */
    private fun sameBackupRecord(first: VaultRecord, second: VaultRecord): Boolean =
        first.copy(updatedAt = second.updatedAt, hlc = second.hlc) == second
}
