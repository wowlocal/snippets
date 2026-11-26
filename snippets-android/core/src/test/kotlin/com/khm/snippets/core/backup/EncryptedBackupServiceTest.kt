package com.khm.snippets.core.backup

import com.khm.snippets.core.crypto.MacPbkdf2HmacSha512
import com.khm.snippets.core.crypto.Pbkdf2HmacSha512
import com.khm.snippets.core.crypto.filled
import com.khm.snippets.core.vault.Components
import com.khm.snippets.core.vault.KeyPresence
import com.khm.snippets.core.vault.RealVault
import com.khm.snippets.core.vault.SecureSnippetStore
import com.khm.snippets.core.vault.VaultAuthenticationReason
import com.khm.snippets.core.vault.VaultAuthenticationResult
import com.khm.snippets.core.vault.VaultKeyStoreException
import com.khm.snippets.core.vault.VaultSession
import com.khm.snippets.core.vault.id
import com.khm.snippets.core.vault.snippet
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.Executors
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Backups against the live library: `makeEncryptedBackup`, `prepareEncryptedBackupImport`
 * and `importPreparedEncryptedBackup` of `SecureSnippetStore.swift`, with
 * `testEncryptedBackupKDFYieldsMainActorAndStillRoundTrips` and
 * `testEncryptedBackupExportStaysBlockedButExplicitImportRecoversQuarantine` of
 * `SecureRemediationTests.swift`, and the import tests of
 * `snippets-linux/src/backup_import_tests.rs` as far as the rules are Swift's.
 */
class EncryptedBackupServiceTest {

    private val password = "correct horse battery staple".toCharArray()
    private val fastIterations = 2_000L

    private class Host(private val components: Components) : OrdinaryLibraryHost {
        override var isLibraryQuarantined = false
        val calls = ArrayList<String>()

        override fun flushPendingWrites() {
            calls.add("flush")
        }

        override fun reloadAfterExternalWrite() {
            calls.add("reload")
        }
    }

    private class Device(label: String) {
        val c = Components(label)
        val host = Host(c)
        val service = EncryptedBackupService(c.store, host, EmptyCoroutineContext, EmptyCoroutineContext)

        suspend fun addSecure(name: String, keyword: String, body: String) = c.run {
            session.unlock(reveal).fill(0)
            store.addSecure(name, keyword, body.toByteArray(), emptyList(), true, false).also { session.lock() }
        }
    }

    private fun devices(vararg labels: String, block: suspend (List<Device>) -> Unit) = runTest {
        val all = labels.map { Device(it) }
        try {
            block(all)
        } finally {
            all.forEach { it.c.destroy() }
        }
    }

    // Export

    /** `testEncryptedBackupKDFYieldsMainActorAndStillRoundTrips` */
    @Test fun aBackupOfBothHalvesRoundTripsOntoAFreshDevice() = devices("export", "fresh") { (source, fresh) ->
        source.c.createVault()
        source.c.writeLibrary(snippet(1, content = "ordinary body"))
        val secureId = source.addSecure("Bank", "bank", "SECURE-BODY-9134")
        val authenticationsBefore = source.c.owner.count.get()

        val export = source.service.makeEncryptedBackup(password, fastIterations)

        assertEquals(listOf(1, 1, 2), listOf(export.ordinaryCount, export.secureCount, export.totalCount))
        assertEquals(authenticationsBefore + 1, source.c.owner.count.get(), "a backup with secure records asks the owner afresh")
        assertEquals(VaultAuthenticationReason.ExportBackup, source.c.owner.reasons.last())
        assertEquals(VaultSession.State.LOCKED, source.c.session.state.value, "the export is a one-use authentication")
        assertTrue(source.host.calls.contains("flush"), "pending ordinary edits must be on disk before the snapshot")
        assertTrue(EncryptedBackup.isEncryptedBackup(export.data))
        val text = String(export.data, Charsets.UTF_8)
        for (secret in listOf("SECURE-BODY-9134", "ordinary body", "Bank", source.c.store.document!!.kid)) assertFalse(text.contains(secret))

        // A device that has never had a vault: the key is stored first, the document installed, nobody is asked.
        val order = ArrayList<String>()
        fresh.c.keys.onStore = { order.add("key") }
        fresh.c.io.afterWrite = { order.add("file:${it.name}") }
        val prepared = fresh.service.prepareImport(export.data, password)
        assertEquals(listOf(1, 1, 2), listOf(prepared.ordinaryCount, prepared.secureCount, prepared.totalCount))
        assertFalse(fresh.c.scratch.vault.exists(), "preparing an import writes nothing")
        assertEquals(emptyList(), order)

        val result = fresh.service.importPrepared(prepared)
        prepared.close()

        assertEquals(EncryptedBackupService.ImportResult(1, 1), result)
        assertEquals("key", order.first(), "the backup's key must be stored before the vault that names it")
        assertEquals(0, fresh.c.owner.count.get())
        assertEquals(listOf(id(1)), fresh.c.library().map { it.id })
        assertEquals(source.c.store.document, fresh.c.store.document)
        assertEquals(listOf("flush", "reload"), fresh.host.calls)
        assertEquals(VaultSession.State.LOCKED, fresh.c.session.state.value)
        fresh.c.session.unlock(fresh.c.reveal).fill(0)
        assertEquals("SECURE-BODY-9134", fresh.c.store.content(secureId))
    }

    /**
     * The other half of `testEncryptedBackupKDFYieldsMainActorAndStillRoundTrips`: every
     * password derivation of an export and of an import runs in the KDF context, never on
     * the caller's thread, and the result still round-trips.
     */
    @Test fun thePasswordDerivationRunsInTheKdfContextOnly() = runTest {
        val executor = Executors.newSingleThreadExecutor { Thread(it, "test-kdf-thread") }
        val c = Components("kdf-context")
        try {
            val derivations = ArrayList<String>()
            val recording = Pbkdf2HmacSha512 { passwordBytes, salt, iterations, count ->
                synchronized(derivations) { derivations.add(Thread.currentThread().name) }
                MacPbkdf2HmacSha512.derive(passwordBytes, salt, iterations, count)
            }
            val service = EncryptedBackupService(
                c.store, Host(c), executor.asCoroutineDispatcher(), EmptyCoroutineContext, recording,
            )
            c.writeLibrary(snippet(1))
            val caller = Thread.currentThread().name

            val export = service.makeEncryptedBackup(password, fastIterations)
            service.prepareImport(export.data, password).use { assertEquals(1, it.ordinaryCount) }

            assertEquals(listOf("test-kdf-thread", "test-kdf-thread"), derivations)
            assertNotEquals("test-kdf-thread", caller)
        } finally {
            c.destroy()
            executor.shutdownNow()
        }
    }

    @Test fun anOrdinaryOnlyBackupAsksNobodyAndAnEmptyVaultIsOmitted() = devices("ordinary-only") { (device) ->
        device.c.writeLibrary(snippet(1), snippet(2))
        // A vault with no records holds nothing worth exporting: no key is needed for it.
        device.c.createVault()

        val export = device.service.makeEncryptedBackup(password, fastIterations)

        assertEquals(0, device.c.owner.count.get())
        assertEquals(listOf(2, 0), listOf(export.ordinaryCount, export.secureCount))
        EncryptedBackup.open(export.data, password).use { opened ->
            assertNull(opened.vault)
            assertNull(opened.vaultKey())
            assertEquals(listOf(id(1), id(2)), opened.snippets.map { it.id })
        }
    }

    @Test fun anExportThatTheOwnerDeclinesProducesNothing() = devices("export-declined") { (device) ->
        device.c.createVault()
        device.addSecure("Bank", "bank", "body")
        device.c.owner.result = VaultAuthenticationResult.CANCELLED

        val failure = assertFailsWith<VaultSession.Failure.Authentication> { device.service.makeEncryptedBackup(password, fastIterations) }
        assertEquals(VaultAuthenticationResult.CANCELLED, failure.result)
        assertEquals(VaultSession.State.LOCKED, device.c.session.state.value)

        // A vault whose key is gone cannot be exported with its secure half; nothing partial is written.
        device.c.owner.result = VaultAuthenticationResult.SUCCESS
        device.c.keys.inner.delete(device.c.store.document!!.kid)
        assertFailsWith<VaultSession.Failure.NoKey> { device.service.makeEncryptedBackup(password, fastIterations) }
    }

    @Test fun deviceLocalConflictReceiptsNeverLeaveInABackup() = devices("receipts", "target") { (source, target) ->
        source.c.createVault()
        source.addSecure("Bank", "bank", "body")
        val withReceipts = source.c.store.document!!.recordingLocalConflictInstallReceiptHashes(mapOf(id(90) to "ab".repeat(32)))
        source.c.scratch.vaultFile().write(withReceipts)
        source.c.store.reload()

        val export = source.service.makeEncryptedBackup(password, fastIterations)
        EncryptedBackup.open(export.data, password).use { opened ->
            assertEquals(emptyMap(), opened.vault!!.localConflictInstallReceipts)
        }
        // And one that arrives in a foreign backup is dropped on the way in.
        val foreign = EncryptedBackup.seal(emptyList(), withReceipts, source.c.keys.inner.load(withReceipts.kid), password, fastIterations)
        target.service.importEncryptedBackup(foreign, password)
        assertEquals(emptyMap(), target.c.store.document!!.localConflictInstallReceipts)
    }

    // Import into an existing vault

    @Test fun importingIntoTheSameVaultAsksTheOwnerComparesTheKeysAndMerges() = devices("same-vault") { (device) ->
        device.c.createVault()
        device.c.writeLibrary(snippet(1, content = "old"))
        val kept = device.addSecure("Kept", "kept", "kept body")
        val export = device.service.makeEncryptedBackup(password, fastIterations)

        // Things change after the backup.
        device.c.writeLibrary(snippet(1, content = "edited later"), snippet(2))
        val later = device.addSecure("Later", "later", "later body")
        device.c.store.updateMetadata(kept, name = "Renamed later")
        val authenticationsBefore = device.c.owner.count.get()
        device.c.now = device.c.now + 500

        val result = device.service.importEncryptedBackup(export.data, password)

        assertEquals(EncryptedBackupService.ImportResult(1, 1), result)
        assertEquals(authenticationsBefore + 1, device.c.owner.count.get())
        assertEquals(VaultAuthenticationReason.ImportBackup, device.c.owner.reasons.last())
        assertEquals(VaultSession.State.LOCKED, device.c.session.state.value)
        // The backup's ordinary snippet replaces its id; the one made later stays.
        assertEquals(mapOf(id(1) to "old", id(2) to "body 2"), device.c.library().associate { it.id to it.content })
        // The backup's secure record replaces the renamed one, stamped now; the later record stays.
        val records = device.c.store.document!!.records
        assertEquals(listOf(kept, later), records.map { it.id })
        assertEquals("Kept", records[0].name)
        assertEquals(device.c.now, records[0].updatedAt)
        assertEquals(com.khm.snippets.core.vault.THIS_DEVICE, records[0].hlc.device)
        device.c.session.unlock(device.c.reveal).fill(0)
        assertEquals("later body", device.c.store.content(later))
        assertEquals("kept body", device.c.store.content(kept))
    }

    @Test fun aBackupWhoseKeyDiffersFromTheStoredOneIsRefusedAndNothingChanges() = devices("mismatch") { (device) ->
        // Two vaults that claim the same kid and salt but were sealed under different keys.
        val honest = RealVault("k-shared-kid", id(1) to "honest body")
        device.c.keys.inner.store(filled(0x5A, 32), honest.document.kid)
        device.c.scratch.vaultFile().write(honest.document)
        device.c.store.reload()
        device.c.writeLibrary(snippet(5))
        val backup = EncryptedBackup.seal(listOf(snippet(6)), honest.document, honest.key, password, fastIterations)
        val vaultBefore = device.c.scratch.bytes()
        val libraryBefore = Files.readAllBytes(device.c.scratch.library.toPath())

        assertFailsWith<BackupImportFailure.VaultKeyMismatch> { device.service.importEncryptedBackup(backup, password) }

        assertContentEquals(vaultBefore, device.c.scratch.bytes())
        assertContentEquals(libraryBefore, Files.readAllBytes(device.c.scratch.library.toPath()))
        assertContentEquals(filled(0x5A, 32), device.c.keys.inner.load(honest.document.kid), "the stored key must never be overwritten by a backup")
        assertEquals(VaultSession.State.LOCKED, device.c.session.state.value)

        // The owner declining is the same non-event.
        device.c.owner.result = VaultAuthenticationResult.CANCELLED
        assertFailsWith<VaultSession.Failure.Authentication> { device.service.importEncryptedBackup(backup, password) }
        assertContentEquals(vaultBefore, device.c.scratch.bytes())
    }

    /** The legitimate way to restore a lost key: the same vault, its key missing, a backup that holds it. */
    @Test fun aBackupRestoresALostKeyOfTheSameVault() = devices("lost-key") { (device) ->
        device.c.createVault()
        val secureId = device.addSecure("Bank", "bank", "body")
        val export = device.service.makeEncryptedBackup(password, fastIterations)
        val kid = device.c.store.document!!.kid
        device.c.keys.inner.delete(kid)
        device.c.store.reload()
        assertEquals(SecureSnippetStore.VaultStatus.KEY_MISSING, device.c.store.status().vault)
        val authenticationsBefore = device.c.owner.count.get()

        device.service.importEncryptedBackup(export.data, password)

        assertEquals(KeyPresence.PRESENT, device.c.keys.presence(kid))
        assertEquals(authenticationsBefore, device.c.owner.count.get(), "there was no stored key to compare against, so nobody is asked")
        assertEquals(SecureSnippetStore.VaultStatus.LOCKED, device.c.store.status().vault)
        device.c.session.unlock(device.c.reveal).fill(0)
        assertEquals("body", device.c.store.content(secureId))
    }

    @Test fun aRivalVaultIsRefusedBeforeItsKeyIsStored() = devices("rival-source", "rival-target") { (source, target) ->
        source.c.createVault()
        source.addSecure("Theirs", "theirs", "their body")
        source.c.writeLibrary(snippet(7))
        val export = source.service.makeEncryptedBackup(password, fastIterations)

        target.c.createVault()
        target.addSecure("Mine", "mine", "my body")
        val vaultBefore = target.c.scratch.bytes()
        val keysBefore = target.c.keys.inner.storedKeyIds

        assertFailsWith<BackupImportFailure.IncompatibleVault> { target.service.importEncryptedBackup(export.data, password) }

        assertContentEquals(vaultBefore, target.c.scratch.bytes())
        assertEquals(keysBefore, target.c.keys.inner.storedKeyIds, "a refused vault's key must not be stored")
        assertEquals(emptyList(), target.c.library(), "not even the ordinary half is imported")
        assertEquals(VaultSession.State.LOCKED, target.c.session.state.value, "the session still addresses this device's own vault")
        target.c.session.unlock(target.c.reveal).fill(0)
    }

    @Test fun aConflictImportsNothingAndLeavesAFreshDeviceWithoutAVault() = devices("conflict-source", "conflict-target") { (source, target) ->
        source.c.createVault()
        source.addSecure("Bank", "wanted", "body")
        val export = source.service.makeEncryptedBackup(password, fastIterations)

        // The target already uses the secure record's keyword for an ordinary snippet.
        target.c.writeLibrary(snippet(1, name = "Mine", keyword = "wanted"))
        val libraryBefore = Files.readAllBytes(target.c.scratch.library.toPath())

        val failure = assertFailsWith<BackupImportFailure.Conflicts> { target.service.importEncryptedBackup(export.data, password) }
        assertEquals(listOf(BackupMerge.Conflict.SecureKeywordIsOrdinary("wanted", "Mine")), failure.conflicts)

        assertFalse(target.c.scratch.vault.exists())
        assertContentEquals(libraryBefore, Files.readAllBytes(target.c.scratch.library.toPath()))
        assertFalse(target.c.store.hasVault)
        assertEquals(VaultSession.State.NO_KEY, target.c.session.state.value, "no vault was installed, so the session must not address its key")
        // The key was stored before the merge was attempted; an orphaned key is harmless and is never rolled back.
        assertEquals(1, target.c.keys.inner.storedKeyIds.size)
    }

    @Test fun aFailureWhileWritingLeavesBothFilesAsTheyWere() = devices("write-source", "write-target") { (source, target) ->
        source.c.createVault()
        source.addSecure("Bank", "bank", "body")
        source.c.writeLibrary(snippet(1))
        val export = source.service.makeEncryptedBackup(password, fastIterations)
        target.c.writeLibrary(snippet(2))
        val libraryBefore = Files.readAllBytes(target.c.scratch.library.toPath())

        target.c.io.beforeWrite = { _, _ -> throw IOException("disk full") }
        assertFailsWith<SecureSnippetStore.Failure.Transaction> { target.service.importEncryptedBackup(export.data, password) }
        assertFalse(target.c.scratch.vault.exists())
        assertContentEquals(libraryBefore, Files.readAllBytes(target.c.scratch.library.toPath()))
        assertFalse(target.c.store.hasVault)

        // A key store that refuses the key: nothing is written at all.
        target.c.io.beforeWrite = { _, _ -> }
        target.c.keys.inner.delete(source.c.store.document!!.kid)
        target.c.keys.failStore = VaultKeyStoreException.Unavailable("refused")
        assertFailsWith<VaultKeyStoreException.Unavailable> { target.service.importEncryptedBackup(export.data, password) }
        assertFalse(target.c.scratch.vault.exists())
        assertEquals(emptyList(), target.c.io.log)

        target.c.keys.failStore = null
        target.service.importEncryptedBackup(export.data, password)
        assertEquals(setOf(id(1), id(2)), target.c.library().map { it.id }.toSet())
        assertEquals(1, target.c.store.count)
    }

    // The quarantined ordinary library

    /** `testEncryptedBackupExportStaysBlockedButExplicitImportRecoversQuarantine` */
    @Test fun testEncryptedBackupExportStaysBlockedButExplicitImportRecoversQuarantine() = devices("q-source", "q-target") { (source, target) ->
        source.c.createVault()
        source.addSecure("Bank", "bank", "body")
        source.c.writeLibrary(snippet(1), snippet(2))
        val export = source.service.makeEncryptedBackup(password, fastIterations)

        // The target's ordinary library was unreadable and has been moved aside; what is there now is not trusted.
        target.c.writeLibrary(snippet(8, name = "Leftover"))
        target.host.isLibraryQuarantined = true

        assertFailsWith<BackupImportFailure.LibraryRecoveryRequired> { target.service.makeEncryptedBackup(password, fastIterations) }
        val prepared = target.service.prepareImport(export.data, password)
        // An ordinary import is not legal while quarantined; only the explicit recovery is.
        assertFailsWith<BackupImportFailure.LibraryRecoveryRequired> { target.service.importPrepared(prepared) }
        assertEquals(listOf(id(8)), target.c.library().map { it.id })

        val result = target.service.importPrepared(prepared, authoritativeRecovery = true)
        prepared.close()

        assertEquals(EncryptedBackupService.ImportResult(2, 1), result)
        assertEquals(setOf(id(1), id(2)), target.c.library().map { it.id }.toSet(), "the recovery replaces the ordinary half")
        assertEquals(1, target.c.store.count)

        // And an explicit recovery is refused for a library that is not quarantined.
        target.host.isLibraryQuarantined = false
        target.service.prepareImport(export.data, password).use { again ->
            assertFailsWith<BackupImportFailure.LibraryRecoveryRequired> { target.service.importPrepared(again, authoritativeRecovery = true) }
        }
    }

    @Test fun aPreparedImportHoldsTheKeyOnlyUntilItIsClosed() = devices("prepared-source", "prepared-target") { (source, target) ->
        source.c.createVault()
        source.addSecure("Bank", "bank", "body")
        val export = source.service.makeEncryptedBackup(password, fastIterations)

        val prepared = target.service.prepareImport(export.data, password)
        prepared.close()
        // A closed ticket has no key any more: the import is refused rather than installing a vault without one.
        assertFailsWith<EncryptedBackup.Failure.DamagedBackup> { target.service.importPrepared(prepared) }
        assertFalse(target.c.scratch.vault.exists())

        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { target.service.prepareImport(export.data, "wrong".toCharArray()) }
        assertNotNull(password)
    }
}
