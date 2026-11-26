package com.khm.snippets.core.vault

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.RecoveryKey
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.filled
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The store: vault creation and its ordering, the recovery key, content operations, the
 * moves between the two files and what a failure or a crash at each step leaves behind,
 * removal, and status. Ports the store tests of
 * `snippets-ios-tests/SecureRemediationTests.swift` (Swift names kept) and the Android
 * meaning of `SecureVaultProviderIsolationTests.swift` (no vault is ever minted where a
 * library owns it); the rest are the ordering and rollback rules of
 * `SecureSnippetStore.swift` and `LibraryTransaction.swift`, each with a fault injected.
 */
class SecureSnippetStoreTest {

    private fun withComponents(label: String, block: suspend (Components) -> Unit) = runTest {
        val components = Components(label)
        try {
            block(components)
        } finally {
            components.destroy()
        }
    }

    // Creating the vault

    /** `testPreparedVaultCreationWritesNothingUntilAcknowledgedAndCancelIsFinal` */
    @Test fun testPreparedVaultCreationWritesNothingUntilAcknowledgedAndCancelIsFinal() = withComponents("prepare") { c ->
        val cancelled = assertNotNull(c.store.prepareVaultCreationIfNeeded())
        assertFalse(c.store.hasVault)
        assertFalse(c.scratch.vault.exists())
        assertEquals(emptyList(), c.keys.inner.storedKeyIds, "showing the recovery key must store nothing")
        assertEquals(33, cancelled.recoveryKeyText.length, "the key is shown grouped: 27 symbols and 6 dashes")

        cancelled.cancel()
        assertEquals("", cancelled.recoveryKeyText)
        assertFailsWith<SecureSnippetStore.Failure.InvalidSetupTicket> { c.store.commitVaultCreation(cancelled) }
        assertFalse(c.store.hasVault)
        assertFalse(c.scratch.vault.exists())

        val acknowledged = assertNotNull(c.store.prepareVaultCreationIfNeeded())
        val document = c.store.commitVaultCreation(acknowledged)

        assertTrue(c.store.hasVault)
        assertTrue(c.store.hasRecoveryKey)
        assertEquals(KeyPresence.PRESENT, c.keys.presence(document.kid))
        assertTrue(c.scratch.vault.exists())
        assertEquals("", acknowledged.recoveryKeyText, "a spent ticket no longer holds the key")
        assertFailsWith<SecureSnippetStore.Failure.InvalidSetupTicket> { c.store.commitVaultCreation(acknowledged) }
        // An existing vault with its key: nothing more to set up.
        assertNull(c.store.prepareVaultCreationIfNeeded())
    }

    @Test fun aNewVaultHasTheDocumentedShapeAndItsRecoveryKeyOpensItsKey() = withComponents("shape") { c ->
        val recoveryText = c.createVault()
        val document = assertNotNull(c.vaultOnDisk())

        assertEquals(document, c.store.document)
        assertTrue(Regex("k-[0-9a-f]{8}-[0-9a-f]{3}").matches(document.kid), document.kid)
        assertEquals(32, assertNotNull(document.vaultSaltBytes).size)
        assertEquals("pbkdf2-hmac-sha512", document.kdf.alg)
        assertEquals(600_000L, document.kdf.iterations)
        assertEquals(16, assertNotNull(com.khm.snippets.core.crypto.Base64Url.decode(document.kdf.saltP)).size)
        assertNull(document.wrapPass)
        assertNull(document.wrapCLI)
        assertEquals(emptyList(), document.records)
        assertTrue(c.vaultText().contains("\"wrapPass\" : null") && c.vaultText().contains("\"wrapCLI\" : null"))

        val fromRecovery = KeyWrap.unwrap(
            assertNotNull(document.wrapRecovery), RecoveryKey.decode(recoveryText),
            KeyWrap.Purpose.RECOVERY, document.kid, document.vaultSaltBytes!!,
        )
        assertContentEquals(c.keys.inner.load(document.kid), fromRecovery)
        assertEquals(VaultSession.State.LOCKED, c.session.state.value)
        assertFalse(c.vaultText().contains(recoveryText.replace("-", "")), "the recovery key is shown once and never stored")
    }

    /** The key goes into the key store before the document that names it exists on disk. */
    @Test fun theKeyIsStoredBeforeTheDocumentThatNamesIt() = withComponents("order") { c ->
        val order = ArrayList<String>()
        c.keys.onStore = { order.add("key") }
        c.io.afterWrite = { order.add("file:${it.name}") }

        c.createVault()

        assertEquals(listOf("key", "file:vault.json"), order)
    }

    /** Key stored, file write fails: the key is rolled back, nothing names it, and the same ticket can try again. */
    @Test fun aFailedFileWriteRollsTheStoredKeyBack() = withComponents("rollback") { c ->
        val pending = assertNotNull(c.store.prepareVaultCreationIfNeeded())
        c.io.beforeWrite = { _, _ -> throw IOException("disk full") }

        assertFailsWith<VaultFileError.WriteFailed> { c.store.commitVaultCreation(pending) }

        assertEquals(1, c.keys.log.count { it.startsWith("store:") }, "the key was stored first")
        assertEquals(1, c.keys.log.count { it.startsWith("delete:") }, "and deleted again")
        assertEquals(emptyList(), c.keys.inner.storedKeyIds)
        assertFalse(c.scratch.vault.exists())
        assertFalse(c.store.hasVault)
        assertEquals(VaultSession.State.NO_KEY, c.session.state.value)

        // The user saw one recovery key; the retry must make the vault that key recovers.
        val shown = pending.recoveryKeyText
        c.io.beforeWrite = { _, _ -> }
        val document = c.store.commitVaultCreation(pending)
        assertContentEquals(
            c.keys.inner.load(document.kid),
            KeyWrap.unwrap(document.wrapRecovery!!, RecoveryKey.decode(shown), KeyWrap.Purpose.RECOVERY, document.kid, document.vaultSaltBytes!!),
        )
        assertEquals(listOf(document.kid), c.keys.inner.storedKeyIds)
    }

    @Test fun aKeyStoreThatRefusesTheKeyLeavesNoDocument() = withComponents("store-fails") { c ->
        val pending = assertNotNull(c.store.prepareVaultCreationIfNeeded())
        c.keys.failStore = VaultKeyStoreException.Unavailable("no secure lock screen")

        assertFailsWith<VaultKeyStoreException.Unavailable> { c.store.commitVaultCreation(pending) }

        assertFalse(c.scratch.vault.exists(), "a document must never name a key that was not stored")
        assertEquals(emptyList(), c.io.log)
        assertFalse(c.store.hasVault)
    }

    /**
     * A crash between the two steps. Whatever the moment, the next launch finds either
     * nothing (plus, at worst, a harmless orphaned key) or a complete vault whose key is
     * stored: never a document naming a missing key, and never two vaults.
     */
    @Test fun aCrashBetweenTheStepsLeavesARecoverableState() = withComponents("crash") { c ->
        // Crash after the key is stored, before the file is written.
        c.io.beforeWrite = { _, _ -> throw SimulatedCrash() }
        assertFailsWith<SimulatedCrash> { c.createVault() }
        val orphan = c.keys.inner.storedKeyIds.single()

        val afterCrash = c.restarted("after-crash-1")
        assertFalse(afterCrash.store.hasVault)
        assertFalse(afterCrash.scratch.vault.exists())
        assertEquals(SecureSnippetStore.VaultStatus.NOT_SET_UP, afterCrash.store.status().vault)

        // Setting up again works and yields exactly one vault, under a new key id.
        afterCrash.createVault()
        val document = assertNotNull(afterCrash.vaultOnDisk())
        assertNotEquals(orphan, document.kid)
        assertEquals(KeyPresence.PRESENT, afterCrash.keys.presence(document.kid))
        assertEquals(listOf("vault.json"), entries(afterCrash.scratch.locations.vaultFolder))

        // Crash right after the file landed, before the store adopted it in memory.
        val second = Components("crash-2")
        try {
            second.io.afterWrite = { throw SimulatedCrash() }
            assertFailsWith<SimulatedCrash> { second.createVault() }
            val restarted = second.restarted("after-crash-2")
            val landed = assertNotNull(restarted.store.document)
            assertEquals(KeyPresence.PRESENT, restarted.keys.presence(landed.kid), "the document's key was stored before it")
            assertEquals(VaultSession.State.LOCKED, restarted.session.state.value)
            assertNull(restarted.store.prepareVaultCreationIfNeeded(), "the vault that landed is the vault; no second one")
        } finally {
            second.destroy()
        }
    }

    /** A vault that appeared while the recovery key was on screen wins; the displayed key is void. */
    @Test fun aVaultThatAppearedMeanwhileWinsAndTheDisplayedKeyIsVoid() = withComponents("appeared") { c ->
        val pending = assertNotNull(c.store.prepareVaultCreationIfNeeded())

        // Another writer (the sync bridge joining a library) lands a vault; this store has not reloaded.
        val other = RealVault("k-other-writer")
        c.keys.inner.store(other.key, other.document.kid)
        c.scratch.vaultFile().write(other.document)

        assertFailsWith<SecureSnippetStore.Failure.SetupChanged> { c.store.commitVaultCreation(pending) }

        assertEquals(other.document, c.vaultOnDisk(), "the existing vault was overwritten by a rival")
        assertEquals(listOf("k-other-writer"), c.keys.inner.storedKeyIds, "the rival key must not be left behind")
        assertEquals("", pending.recoveryKeyText)
        assertFailsWith<SecureSnippetStore.Failure.InvalidSetupTicket> { c.store.commitVaultCreation(pending) }
        assertEquals(other.document, c.store.document, "the store now sees the vault that won")

        // And setup now finds a vault with its key: there is nothing left to create.
        assertNull(c.store.prepareVaultCreationIfNeeded())
    }

    @Test fun twoSetupsAtTheSameMomentCreateExactlyOneVault() {
        val first = Components("race")
        val second = first.restarted("race-2")
        try {
            val pendings = listOf(first, second).map { it to assertNotNull(it.store.prepareVaultCreationIfNeeded()) }
            val start = CountDownLatch(1)
            val pool = Executors.newFixedThreadPool(2)
            val results = pendings.map { (components, pending) ->
                pool.submit<Result<VaultDocument>> {
                    start.await()
                    runCatching { components.store.commitVaultCreation(pending) }
                }
            }
            start.countDown()
            val outcomes = results.map { it.get(30, TimeUnit.SECONDS) }
            pool.shutdown()

            assertEquals(1, outcomes.count { it.isSuccess }, "exactly one setup may win")
            assertIs<SecureSnippetStore.Failure.SetupChanged>(outcomes.single { it.isFailure }.exceptionOrNull())
            val winner = outcomes.single { it.isSuccess }.getOrThrow()
            assertEquals(winner, first.vaultOnDisk())
            assertEquals(listOf(winner.kid), first.keys.inner.storedKeyIds, "the loser's key must be gone")
        } finally {
            first.destroy()
        }
    }

    /** With a library that owns its vault, nothing here may mint one: a second `kid` is a second crypto scope. */
    @Test fun aLibraryOwnedVaultIsNeverMintedOnThisDevice() = withComponents("git") { c ->
        c.policy.libraryOwnsVault = true

        assertFailsWith<SecureSnippetStore.Failure.LibraryVaultSetupRequired> { c.store.prepareVaultCreationIfNeeded() }
        assertFailsWith<SecureSnippetStore.Failure.LibraryVaultSetupRequired> { c.store.createVaultIfNeeded { true } }
        assertFalse(c.scratch.vault.exists())
        assertEquals(emptyList(), c.keys.log)

        // A ticket prepared before the provider changed must not slip through either.
        c.policy.libraryOwnsVault = false
        val pending = assertNotNull(c.store.prepareVaultCreationIfNeeded())
        c.policy.libraryOwnsVault = true
        assertFailsWith<SecureSnippetStore.Failure.LibraryVaultSetupRequired> { c.store.commitVaultCreation(pending) }
        assertFalse(c.scratch.vault.exists())
        assertEquals(emptyList(), c.keys.log)
    }

    /** A vault whose key is missing: the remedy depends on who owns the vault, and it is never a new vault. */
    @Test fun aVaultWithoutItsKeyIsNeverReplacedByANewOne() = withComponents("key-missing") { c ->
        c.createVault()
        val kid = c.store.document!!.kid
        c.keys.inner.delete(kid)
        c.store.reload()

        assertEquals(VaultSession.State.NO_KEY, c.session.state.value)
        assertFailsWith<SecureSnippetStore.Failure.VaultKeyMissing> { c.store.prepareVaultCreationIfNeeded() }
        assertEquals(SecureSnippetStore.KeyMissingRemediation.RECOVERY_KEY, c.store.status().keyMissingRemediation)

        c.policy.libraryOwnsVault = true
        assertFailsWith<SecureSnippetStore.Failure.LibraryVaultSetupRequired> { c.store.prepareVaultCreationIfNeeded() }
        assertEquals(SecureSnippetStore.KeyMissingRemediation.LIBRARY_SETUP, c.store.status().keyMissingRemediation)

        assertEquals(kid, c.vaultOnDisk()!!.kid)
        assertEquals(emptyList(), c.keys.inner.storedKeyIds, "no new key may be minted for a vault that is waiting for its own")
    }

    /** A key store that cannot answer is not "no key": setup neither mints nor reports the key missing. */
    @Test fun aKeyStoreErrorNeverLeadsIntoVaultCreationOrKeyMissing() = withComponents("store-error") { c ->
        c.createVault()
        val before = c.scratch.bytes()
        c.keys.presenceOverride = KeyPresence.UNKNOWN
        c.keys.failLoad = VaultKeyStoreException.Unavailable("locked")
        c.store.reload()

        assertEquals(VaultSession.State.LOCKED, c.session.state.value)
        assertEquals(SecureSnippetStore.VaultStatus.LOCKED, c.store.status().vault)
        assertNull(c.store.status().keyMissingRemediation)
        assertNull(c.store.prepareVaultCreationIfNeeded(), "an unanswerable store must not look like a missing key")
        assertIs<VaultSession.Failure.KeyStore>(runCatching { c.session.unlock(c.reveal) }.exceptionOrNull())
        assertContentEquals(before, c.scratch.bytes())
        assertEquals(1, c.keys.inner.storedKeyIds.size)
    }

    @Test fun createVaultIfNeededConfirmsOnceAndCancellingLeavesNothing() = withComponents("confirm") { c ->
        var shown: String? = null
        assertFailsWith<SecureSnippetStore.Failure.SetupCancelled> {
            c.store.createVaultIfNeeded {
                shown = it
                false
            }
        }
        assertNotNull(shown)
        assertFalse(c.scratch.vault.exists())
        assertEquals(emptyList(), c.keys.log)

        val created = c.store.createVaultIfNeeded { true }
        var asked = false
        assertEquals(created, c.store.createVaultIfNeeded { asked = true; true })
        assertFalse(asked, "an existing vault needs no recovery key confirmation")
    }

    // An unreadable vault

    @Test fun anUnreadableCorruptOrNewerVaultBlocksEveryWrite() = withComponents("unreadable") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("n", "kw", "body".toByteArray(), emptyList(), true, false)

        for ((label, bytes, status) in listOf(
            Triple("corrupt", "{ not a vault", SecureSnippetStore.VaultStatus.CORRUPT),
            Triple("newer", """{"schemaVersion": 5, "future": true}""", SecureSnippetStore.VaultStatus.TOO_NEW),
        )) {
            c.scratch.put(bytes)
            val onDisk = c.scratch.bytes()
            c.store.reload()

            assertTrue(c.store.isUnreadable, label)
            assertFalse(c.store.hasVault, label)
            assertEquals(emptyList(), c.store.shells, label)
            assertEquals(status, c.store.status().vault, label)
            assertEquals(VaultSession.State.NO_KEY, c.session.state.value, label)

            assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable>(label) { c.store.prepareVaultCreationIfNeeded() }
            assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable>(label) { c.store.updateMetadata(id, name = "x") }
            assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable>(label) { c.store.delete(id) }
            assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable>(label) { c.store.contentData(id) }
            assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable>(label) { c.store.setContent("x", id) }
            assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable>(label) { c.store.forgetEverything(true) }
            assertFailsWith<SecureSnippetStore.LibraryVaultFailure.Unreadable>(label) {
                c.store.joinLibraryVault(LibraryVaultIdentity("k", "IiIi", VaultKdfParameters("a", 1, "VVVV"), "v1.a.b"))
            }
            assertEquals(0, c.store.reconcileInterruptedMove(), label)
            assertContentEquals(onDisk, c.scratch.bytes(), "$label: an unreadable vault was written")
        }
        assertEquals(5L, c.store.status().newerSchemaVersion)

        // Only a vault that is not a vault can be moved aside; a newer one is somebody else's to write.
        assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable> { c.store.quarantineCorruptVault("test") }
        c.scratch.put("{ not a vault")
        c.store.reload()
        val moved = c.store.quarantineCorruptVault("could not be decoded")
        assertEquals("{ not a vault", String(Files.readAllBytes(moved.toPath())))
        assertEquals(SecureSnippetStore.VaultStatus.NOT_SET_UP, c.store.status().vault)
        assertFalse(c.store.isUnreadable)
    }

    @Test fun anIoErrorIsUnreadableNotCorruptAndNothingIsQuarantined() = withComponents("io-error") { c ->
        c.createVault()
        c.io.beforeRead = { if (it == c.scratch.vault) throw IOException("permission denied") }
        c.store.reload()

        assertEquals(SecureSnippetStore.VaultStatus.UNREADABLE, c.store.status().vault)
        assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable> { c.store.quarantineCorruptVault("x") }
        assertFailsWith<SecureSnippetStore.Failure.VaultUnreadable> { c.store.prepareVaultCreationIfNeeded() }

        c.io.beforeRead = {}
        c.store.reload()
        assertEquals(SecureSnippetStore.VaultStatus.LOCKED, c.store.status().vault)
    }

    // The recovery key

    /** `testRecoveryAdditionIsFreshlyAuthenticatedButNotCommittedBeforeAcknowledgement` */
    @Test fun testRecoveryAdditionIsFreshlyAuthenticatedButNotCommittedBeforeAcknowledgement() = withComponents("add-recovery") { c ->
        // A vault from a build that did not create a recovery key yet.
        val vault = RealVault("k-no-recovery")
        c.keys.inner.store(vault.key, vault.document.kid)
        c.scratch.vaultFile().write(vault.document)
        c.store.reload()
        assertFalse(c.store.hasRecoveryKey)

        val cancelled = assertNotNull(
            c.session.withOneUseAuthentication(VaultAuthenticationReason.CreateRecoveryKey) { c.store.prepareRecoveryKeyAddition() },
        )
        assertFalse(c.store.hasRecoveryKey)
        assertEquals(VaultSession.State.LOCKED, c.session.state.value, "the ticket holds ciphertext; the vault may close before the key is shown")
        assertNull(c.vaultOnDisk()!!.wrapRecovery)

        cancelled.cancel()
        assertFailsWith<SecureSnippetStore.Failure.InvalidSetupTicket> { c.store.commitRecoveryKeyAddition(cancelled) }
        assertFalse(c.store.hasRecoveryKey)

        val acknowledged = assertNotNull(
            c.session.withOneUseAuthentication(VaultAuthenticationReason.CreateRecoveryKey) { c.store.prepareRecoveryKeyAddition() },
        )
        val shown = acknowledged.recoveryKeyText
        assertFalse(c.store.hasRecoveryKey)
        assertTrue(c.store.commitRecoveryKeyAddition(acknowledged))

        assertEquals(2, c.owner.count.get())
        assertTrue(c.store.hasRecoveryKey)
        assertFailsWith<SecureSnippetStore.Failure.InvalidSetupTicket> { c.store.commitRecoveryKeyAddition(acknowledged) }

        val document = c.vaultOnDisk()!!
        assertContentEquals(
            vault.key,
            KeyWrap.unwrap(document.wrapRecovery!!, RecoveryKey.decode(shown), KeyWrap.Purpose.RECOVERY, document.kid, document.vaultSaltBytes!!),
        )
        // Nothing to add any more, and a locked vault cannot prepare one.
        assertNull(c.session.withOneUseAuthentication(VaultAuthenticationReason.CreateRecoveryKey) { c.store.prepareRecoveryKeyAddition() })
    }

    @Test fun preparingARecoveryKeyNeedsAnOpenVault() = withComponents("add-recovery-locked") { c ->
        val vault = RealVault("k-no-recovery")
        c.keys.inner.store(vault.key, vault.document.kid)
        c.scratch.vaultFile().write(vault.document)
        c.store.reload()

        assertFailsWith<VaultSession.Failure.Locked> { c.store.prepareRecoveryKeyAddition() }
        assertFailsWith<VaultSession.Failure.Locked> { c.store.addRecoveryKeyIfNeeded { true } }
        assertNull(c.vaultOnDisk()!!.wrapRecovery)
    }

    /** A missing key comes back from the printable recovery key; a typo can never replace a good key. */
    @Test fun theRecoveryKeyRestoresAMissingKeyAndATypoStoresNothing() = withComponents("restore") { c ->
        val recoveryText = c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("Bank", "bank", "1234-5678".toByteArray(), emptyList(), true, false)
        val kid = c.store.document!!.kid
        val original = c.keys.inner.load(kid)

        // The key is lost (a new phone, an invalidated Keystore key).
        c.session.lock()
        c.keys.inner.delete(kid)
        c.store.reload()
        assertEquals(SecureSnippetStore.VaultStatus.KEY_MISSING, c.store.status().vault)
        assertEquals(SecureSnippetStore.KeyMissingRemediation.RECOVERY_KEY, c.store.status().keyMissingRemediation)
        // Metadata still works without the key.
        assertEquals(listOf("Bank"), c.store.shells.map { it.name })
        c.store.updateMetadata(id, name = "Bank PIN")

        // Typos: reported as typos, and nothing is stored.
        val wrongCheck = recoveryText.dropLast(1) + (if (recoveryText.last() == '0') '1' else '0')
        assertFailsWith<RecoveryKey.Failure> { c.store.restoreKey(wrongCheck) }
        assertFailsWith<RecoveryKey.Failure.WrongLength> { c.store.restoreKey(recoveryText.dropLast(2)) }
        // A well-formed key of another vault.
        assertFailsWith<KeyWrap.Failure.WrongKey> { c.store.restoreKey(RecoveryKey.formatted(RecoveryKey.generate())) }
        assertEquals(emptyList(), c.keys.inner.storedKeyIds)
        assertEquals(VaultSession.State.NO_KEY, c.session.state.value)

        // The real one, as a person types it: lowercase, spaces instead of dashes.
        c.store.restoreKey(recoveryText.lowercase().replace('-', ' '))
        assertContentEquals(original, c.keys.inner.load(kid))
        assertEquals(VaultSession.State.LOCKED, c.session.state.value)
        assertEquals(SecureSnippetStore.VaultStatus.LOCKED, c.store.status().vault)

        c.session.unlock(c.reveal).fill(0)
        assertEquals("1234-5678", c.store.content(id))
    }

    @Test fun aVaultWithoutARecoveryWrapOffersOnlyABackup() = withComponents("no-recovery") { c ->
        val vault = RealVault("k-no-recovery")
        c.scratch.vaultFile().write(vault.document)
        c.store.reload()

        assertEquals(SecureSnippetStore.VaultStatus.KEY_MISSING, c.store.status().vault)
        assertEquals(SecureSnippetStore.KeyMissingRemediation.BACKUP_ONLY, c.store.status().keyMissingRemediation)
        assertFailsWith<SecureSnippetStore.Failure.RecoveryUnavailable> { c.store.restoreKey("M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ") }
    }

    // Content

    @Test fun contentNeedsTheKeyAndMetadataDoesNot() = withComponents("content") { c ->
        c.createVault()
        c.writeLibrary(snippet(1, keyword = "taken"))

        // Locked: no body can be written or read.
        assertFailsWith<VaultSession.Failure.Locked> {
            c.store.addSecure("AWS root", "awsroot", "hunter2".toByteArray(), listOf("Work", "work"), true, false)
        }
        assertEquals(0, c.store.count)

        c.session.unlock(c.reveal).fill(0)
        c.now = at(2000.0)
        val body = "hunter2".toByteArray()
        val id = c.store.addSecure("AWS root", "  \\awsroot ", body, listOf("Work", "work", " prod "), true, true)
        assertContentEquals("hunter2".toByteArray(), body, "the caller's body must not be modified")

        val record = assertNotNull(c.store.record(id))
        assertEquals("AWS root", record.name)
        assertEquals("awsroot", record.keyword, "the keyword is stored sanitized")
        assertEquals(listOf("Work", "prod"), record.tags)
        assertTrue(record.isPinned)
        assertEquals(at(2000.0), record.createdAt)
        assertEquals(at(2000.0), record.updatedAt)
        assertEquals(THIS_DEVICE, record.hlc.device)
        assertTrue(c.store.isSecure(id))
        assertEquals(listOf(""), c.store.secureShellsForDisplay().map { it.content })
        assertEquals(c.store.document, c.vaultOnDisk())

        // The body is ciphertext on disk, and the hash is the keyed one.
        assertFalse(c.vaultText().contains("hunter2"))
        val document = c.store.document!!
        SnippetCrypto.Keyring(c.keys.inner.load(document.kid), document.vaultSaltBytes!!).use { keyring ->
            assertEquals(SnippetCrypto.contentHash("hunter2".toByteArray(), keyring), record.contentHash)
            assertEquals(32, record.contentHash.length)
        }
        assertContentEquals("hunter2".toByteArray(), c.store.contentData(id))
        assertEquals("hunter2", c.store.content(id))

        // A new body updates sealed, hash, time and clock together.
        c.now = at(3000.0)
        c.store.setContent("correct horse", id)
        val edited = c.store.record(id)!!
        assertNotEquals(record.sealed, edited.sealed)
        assertNotEquals(record.contentHash, edited.contentHash)
        assertEquals(at(3000.0), edited.updatedAt)
        assertEquals(at(2000.0), edited.createdAt)
        assertTrue(edited.hlc > record.hlc)
        assertEquals("correct horse", c.store.content(id))

        // Locked again: the body is closed, the metadata is not.
        c.session.lock()
        assertFailsWith<VaultSession.Failure.Locked> { c.store.contentData(id) }
        assertFailsWith<VaultSession.Failure.Locked> { c.store.setContent("x", id) }
        c.now = at(4000.0)
        c.store.updateMetadata(id, name = "AWS", keyword = " \\aws ", tags = listOf("Prod", "prod"), isEnabled = false, isPinned = false)
        val renamed = c.store.record(id)!!
        assertEquals(listOf("AWS", "aws", listOf("Prod"), false, false), listOf(renamed.name, renamed.keyword, renamed.tags, renamed.isEnabled, renamed.isPinned))
        assertEquals(edited.sealed, renamed.sealed, "a metadata change must not touch the ciphertext")
        assertEquals(edited.contentHash, renamed.contentHash)
        assertEquals(at(4000.0), renamed.updatedAt)
        assertTrue(renamed.hlc > edited.hlc)
        assertEquals(emptyList(), c.store.enabledShellsForDisplay())

        // Deleting needs no key either.
        c.store.delete(id)
        assertEquals(0, c.store.count)
        assertFalse(c.store.isSecure(id))
        assertEquals(emptyList(), c.vaultOnDisk()!!.records)
        assertFailsWith<SecureSnippetStore.Failure.NoSuchRecord> { c.store.contentData(id) }
        assertEquals(listOf(id(1)), c.library().map { it.id }, "the ordinary library is not this store's to change")
    }

    @Test fun addSecureChecksKeywordsAcrossBothFilesAndRefusesWhatCannotBeASecureSnippet() = withComponents("add") { c ->
        c.createVault()
        c.writeLibrary(snippet(1, keyword = "Café"))
        c.session.unlock(c.reveal).fill(0)
        c.store.addSecure("first", "bank", "a".toByteArray(), emptyList(), true, false)

        fun add(keyword: String, body: ByteArray = "b".toByteArray()) = c.store.addSecure("n", keyword, body, emptyList(), true, false)

        // The same keyword in the ordinary library, folded for case and diacritics; and in the vault.
        assertFailsWith<SecureSnippetStore.Failure.Transaction> { add("cafe") }
        assertFailsWith<SecureSnippetStore.Failure.Transaction> { add("BANK") }
        // A secure snippet needs a keyword, and a body that is text.
        assertFailsWith<SecureSnippetStore.Failure.InvalidUtf8> { add("  \\  ") }
        assertFailsWith<SecureSnippetStore.Failure.InvalidUtf8> { add("ok", byteArrayOf(0xC3.toByte(), 0x28)) }
        assertEquals(1, c.store.count)
        assertEquals(1, c.vaultOnDisk()!!.records.size)

        // The vault was replaced underneath: sealing with the session's key would make ciphertext nobody can open.
        val other = RealVault("k-replaced")
        c.scratch.vaultFile().write(other.document)
        assertFailsWith<SecureSnippetStore.Failure.SetupChanged> { add("fresh") }
        assertEquals(other.document, c.vaultOnDisk())
    }

    @Test fun onlyARealChangeIsAnnounced() = withComponents("revision") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("n", "kw", "body".toByteArray(), emptyList(), true, false)
        val before = c.store.revision.value

        // A record that is not there: the file is rewritten unchanged, nobody is told.
        c.store.updateMetadata(id(99), name = "ghost")
        c.store.delete(id(99))
        assertEquals(before, c.store.revision.value)

        c.store.updateMetadata(id, name = "renamed")
        assertEquals(before + 1, c.store.revision.value)
        c.store.reload(notifyChange = false)
        assertEquals(before + 1, c.store.revision.value)
        c.store.reload()
        assertEquals(before + 2, c.store.revision.value)
    }

    /** `testVaultWillLockHookCanUseKeyAfterDeadlineBeforeKeyIsDestroyed`, with the store doing the save. */
    @Test fun aPendingEditIsFlushedByThePreLockHookEvenPastTheDeadline() = runTest {
        val c = Components("prelock", idleWindowMillis = 1000)
        try {
            c.createVault()
            c.writeLibrary(snippet(1, content = "initial"))
            c.session.unlock(c.reveal).fill(0)
            c.store.promote(id(1))
            c.time.advance(2000) // the timer is late

            var flushSucceeded = false
            var revealedText = "PRELOCK-FLUSH-SENTINEL"
            c.session.addPreLockHook {
                c.store.setContent("PRELOCK-FLUSH-SENTINEL", id(1))
                flushSucceeded = true
            }
            c.session.addStateListener { if (it != VaultSession.State.UNLOCKED) revealedText = "" }

            c.session.lock()

            assertTrue(flushSucceeded, "the last edit before the lock was lost")
            assertEquals("", revealedText)
            assertFailsWith<VaultSession.Failure.Locked> { c.session.currentKey() }

            c.session.unlock(c.reveal).fill(0)
            assertEquals("PRELOCK-FLUSH-SENTINEL", c.store.content(id(1)))
        } finally {
            c.destroy()
        }
    }

    /** Secure copy (`SnippetActionService.copySecure`): a fresh prompt every time, the body only in a lease, nothing left open. */
    @Test fun aSecureCopyAlwaysAsksAndLeavesOnlyALease() = withComponents("copy") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("AWS root", "awsroot", "hunter2".toByteArray(), emptyList(), true, false)
        val copy = VaultAuthenticationReason.Copy("AWS root")
        assertTrue(c.session.isUnlocked, "an open reveal session does not excuse the prompt")

        val lease = c.store.leaseContent(id, copy)

        assertEquals(2, c.owner.count.get())
        assertEquals(copy, c.owner.reasons.last())
        assertEquals(VaultSession.State.LOCKED, c.session.state.value, "a copy ends the reveal session and leaves nothing open")
        lease.use { assertEquals("hunter2", it.makeUtf8String()) }
        assertTrue(lease.isWiped)
        assertNull(lease.makeUtf8String())

        c.store.leaseContent(id, copy).wipe()
        assertEquals(3, c.owner.count.get(), "every copy is a new disclosure")

        c.owner.result = VaultAuthenticationResult.CANCELLED
        assertEquals(
            VaultAuthenticationResult.CANCELLED,
            assertFailsWith<VaultSession.Failure.Authentication> { c.store.leaseContent(id, copy) }.result,
        )
        c.owner.result = VaultAuthenticationResult.SUCCESS
        assertFailsWith<SecureSnippetStore.Failure.NoSuchRecord> { c.store.leaseContent(id(404), copy) }
        assertEquals(VaultSession.State.LOCKED, c.session.state.value)
    }

    /** `fresh_open_neither_authors_a_vault_nor_creates_an_identity` (snippets-linux/src/vault.rs) */
    @Test fun aFreshStoreWritesNothingAndStoresNoKey() = withComponents("fresh") { c ->
        assertFalse(c.store.hasVault)
        assertTrue(c.store.isEmpty)
        assertEquals(emptyList(), c.store.shells)
        assertFalse(c.store.isUnreadable)
        c.store.reload()
        assertEquals(0, c.store.reconcileInterruptedMove())

        assertFalse(c.scratch.vault.exists())
        assertFalse(c.scratch.library.exists())
        assertEquals(emptyList(), c.io.log)
        assertEquals(emptyList(), c.keys.log)
        assertEquals(VaultSession.State.NO_KEY, c.session.state.value)
        assertFailsWith<SecureSnippetStore.Failure.NoSuchRecord> { c.store.contentData(id(1)) }
        assertFailsWith<SecureSnippetStore.Failure.NoSuchRecord> { c.store.updateMetadata(id(1), name = "x") }
        assertFailsWith<SecureSnippetStore.Failure.NoSuchRecord> { c.store.promote(id(1)) }
        assertFalse(c.scratch.vault.exists(), "a write to a vault that does not exist must not create one")
    }

    /** `metadata_changes_do_not_erase_a_session_but_key_changes_and_corruption_do` (snippets-linux/src/vault.rs) */
    @Test fun metadataChangesAndReloadsKeepTheSessionButAnotherVaultOrCorruptionEndsIt() = withComponents("session-kept") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("n", "kw", "body".toByteArray(), emptyList(), true, false)

        c.store.updateMetadata(id, name = "renamed", isPinned = true)
        c.store.reload()
        c.store.reload(notifyChange = false)
        assertTrue(c.session.isUnlocked, "a reload of the same vault must not close the session")
        assertEquals("body", c.store.content(id))
        assertEquals(1, c.owner.count.get())

        // Another vault lands on disk: the key in memory is not its key.
        val other = RealVault("k-other-vault", id(5) to "other")
        c.keys.inner.store(other.key, other.document.kid)
        c.scratch.vaultFile().write(other.document)
        c.store.reload()
        assertEquals(VaultSession.State.LOCKED, c.session.state.value)
        assertFailsWith<VaultSession.Failure.Locked> { c.store.content(id(5)) }

        c.session.unlock(c.reveal).fill(0)
        assertEquals("other", c.store.content(id(5)))
        c.scratch.put("{ damaged")
        c.store.reload()
        assertFalse(c.session.isUnlocked, "a vault that cannot be read ends the session")
        assertFailsWith<VaultSession.Failure.Locked> { c.session.currentKey() }
    }

    // Moving between the two files

    /** `testPromoteAndDemoteReloadBothStoresWithoutPlaintextResurrection` */
    @Test fun testPromoteAndDemoteMoveTheSnippetWithoutPlaintextResurrection() = withComponents("moves") { c ->
        c.createVault()
        c.writeLibrary(snippet(1, content = "ordinary"), snippet(2, name = "Token", keyword = " \\tok ", content = "MOVE-SENTINEL-9134"))
        c.session.unlock(c.reveal).fill(0)
        c.now = at(5000.0)

        c.store.promote(id(2))

        assertEquals(listOf(id(1)), c.library().map { it.id })
        assertFalse(c.libraryText().contains("MOVE-SENTINEL-9134"), "the plaintext stayed in snippets.json")
        assertFalse(c.vaultText().contains("MOVE-SENTINEL-9134"))
        val record = assertNotNull(c.store.record(id(2)))
        assertEquals(c.store.document, c.vaultOnDisk())
        assertEquals("Token", record.name)
        assertEquals("tok", record.keyword)
        assertEquals(listOf("tag"), record.tags)
        assertEquals(at(2.0), record.createdAt, "creation time is kept")
        assertEquals(at(5000.0), record.updatedAt)
        assertEquals("MOVE-SENTINEL-9134", c.store.content(id(2)))
        assertFailsWith<SecureSnippetStore.Failure.NoSuchRecord> { c.store.promote(id(2)) }
        assertFailsWith<SecureSnippetStore.Failure.NoSuchRecord> { c.store.promote(id(99)) }

        c.now = at(6000.0)
        c.store.demote(id(2))

        assertEquals(listOf(id(2), id(1)), c.library().map { it.id }, "a demoted snippet goes to the front")
        val back = c.library().first()
        assertEquals("MOVE-SENTINEL-9134", back.content)
        assertEquals(listOf("Token", "tok"), listOf(back.name, back.keyword))
        assertEquals(at(2.0), back.createdAt)
        assertEquals(at(6000.0), back.updatedAt)
        assertFalse(c.store.isSecure(id(2)))
        assertEquals(emptyList(), c.vaultOnDisk()!!.records)
        assertFailsWith<SecureSnippetStore.Failure.NotSecure> { c.store.demote(id(2)) }
        assertEquals(MoveMarker.None, c.markers.current)
    }

    /** `testPromotionDoesNotCopyUnnamedSnippetBodyIntoPlaintextNameMetadata` */
    @Test fun testPromotionDoesNotCopyUnnamedSnippetBodyIntoPlaintextNameMetadata() = withComponents("unnamed") { c ->
        c.createVault()
        val unnamed = snippet(1, name = "", content = "FIRST-LINE-IS-THE-SECRET\nsecond line")
        assertEquals("FIRST-LINE-IS-THE-SECRET", unnamed.displayName, "the display name falls back to the content")
        c.writeLibrary(unnamed)
        c.session.unlock(c.reveal).fill(0)

        c.store.promote(id(1))

        assertEquals("", c.store.record(id(1))!!.name)
        assertFalse(c.vaultText().contains("FIRST-LINE-IS-THE-SECRET"), "secure content leaked into plaintext metadata")
        assertEquals("FIRST-LINE-IS-THE-SECRET", c.sync.lastDestination!!.let { c.store.content(it.id) }.lines().first())
    }

    /** Destination before source, with the marker in between: the window can duplicate, never lose. */
    @Test fun aMoveWritesItsDestinationBeforeItRemovesItsSource() = withComponents("ordering") { c ->
        c.createVault()
        c.writeLibrary(snippet(1), snippet(2))
        c.session.unlock(c.reveal).fill(0)
        val events = ArrayList<String>()
        c.io.afterWrite = { events.add("file:${it.name}") }
        c.sync.onEvent = { events.add("sidecar:${it.substringBefore(':')}") }
        val markersBefore = c.markers.written.size

        c.store.promote(id(2))
        assertEquals(
            listOf(
                "sidecar:move", "sidecar:promotion", // the ciphertext sidecar entry, before any primary file moves
                "file:snippets.json", // the intermediate library, which still holds the source
                "file:vault.json", // the destination
                "file:snippets.json", // the source goes last
            ),
            events,
        )
        assertEquals(listOf(MoveMarker.Promoting(id(2)), MoveMarker.None), c.markers.written.drop(markersBefore))

        events.clear()
        val markersMid = c.markers.written.size
        c.store.demote(id(2))
        assertEquals(listOf("sidecar:move", "sidecar:demotion", "file:snippets.json", "file:vault.json"), events)
        assertEquals(listOf(MoveMarker.Demoting(id(2)), MoveMarker.None), c.markers.written.drop(markersMid))
    }

    /** Each failure point of a promotion: the snippet is in at least one file afterwards, and reconcile completes it. */
    @Test fun aPromotionThatFailsAtAnyWriteNeverLosesTheSnippet() {
        for (failingWrite in 1..3) {
            val c = Components("promote-fail-$failingWrite")
            try {
                c.createVault()
                c.writeLibrary(snippet(1), snippet(2, content = "PROMOTE-BODY"))
                kotlinx.coroutines.runBlocking { c.session.unlock(c.reveal) }.fill(0)
                var writes = 0
                c.io.beforeWrite = { _, _ -> if (++writes == failingWrite) throw IOException("write $failingWrite failed") }

                assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.promote(id(2)) }
                c.io.beforeWrite = { _, _ -> }

                val inLibrary = c.library().any { it.id == id(2) }
                val inVault = c.vaultOnDisk()!!.records.any { it.id == id(2) }
                assertTrue(inLibrary || inVault, "write $failingWrite: the snippet is in neither file")
                when (failingWrite) {
                    // Nothing landed, or only the intermediate library (which equals the original set): still ordinary.
                    1, 2 -> {
                        assertTrue(inLibrary && !inVault, "write $failingWrite")
                        assertEquals("PROMOTE-BODY", c.library().single { it.id == id(2) }.content)
                    }
                    // The vault landed, the source was not removed: a duplicate with a marker.
                    else -> {
                        assertTrue(inLibrary && inVault, "write $failingWrite")
                        assertEquals(MoveMarker.Promoting(id(2)), c.markers.current)
                    }
                }

                // The next launch finishes the job.
                val restarted = c.restarted("promote-restart-$failingWrite")
                val resolved = restarted.store.reconcileInterruptedMove()
                assertEquals(if (failingWrite == 3) 1 else 0, resolved)
                val libraryIds = restarted.library().map { it.id }
                val vaultIds = restarted.vaultOnDisk()!!.records.map { it.id }
                assertEquals(1, (libraryIds + vaultIds).count { it == id(2) }, "write $failingWrite: not exactly one copy after reconcile")
                if (failingWrite == 3) {
                    assertEquals(listOf(id(2)), vaultIds, "an interrupted promotion completes: the vault copy wins")
                    assertFalse(restarted.libraryText().contains("PROMOTE-BODY"))
                    kotlinx.coroutines.runBlocking { restarted.session.unlock(restarted.reveal) }.fill(0)
                    assertEquals("PROMOTE-BODY", restarted.store.content(id(2)))
                }
                if (failingWrite == 3) assertEquals(MoveMarker.None, restarted.markers.current)
            } finally {
                c.destroy()
            }
        }
    }

    /** A demotion interrupted after the plaintext landed: the marker is what keeps reconcile from undoing it. */
    @Test fun aDemotionThatFailsAfterThePlaintextLandedIsCompletedFromItsMarker() = withComponents("demote-fail") { c ->
        c.createVault()
        c.writeLibrary(snippet(1), snippet(2, content = "DEMOTE-BODY"))
        c.session.unlock(c.reveal).fill(0)
        c.store.promote(id(2))

        // The library write (the destination) lands; the vault write (removing the source) fails.
        c.io.beforeWrite = { file, _ -> if (file == c.scratch.vault) throw IOException("vault write failed") }
        assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.demote(id(2)) }
        c.io.beforeWrite = { _, _ -> }

        assertTrue(c.library().any { it.id == id(2) } && c.vaultOnDisk()!!.records.any { it.id == id(2) }, "a duplicate, never a loss")
        assertEquals(MoveMarker.Demoting(id(2)), c.markers.current)

        val restarted = c.restarted("demote-restart")
        assertEquals(1, restarted.store.reconcileInterruptedMove())
        assertEquals("DEMOTE-BODY", restarted.library().single { it.id == id(2) }.content, "the user asked for an ordinary snippet")
        assertEquals(emptyList(), restarted.vaultOnDisk()!!.records)
        assertFalse(restarted.store.isSecure(id(2)))
        assertEquals(MoveMarker.None, restarted.markers.current)
        assertEquals(0, restarted.store.reconcileInterruptedMove(), "reconcile is idempotent")
    }

    /** With no marker at all the vault wins: plaintext of a secret left in snippets.json is the worse mistake. */
    @Test fun aDuplicateWithoutAMarkerIsResolvedInFavourOfTheVault() = withComponents("no-marker") { c ->
        c.createVault()
        c.writeLibrary(snippet(1), snippet(2, content = "DUPLICATE-BODY"))
        c.session.unlock(c.reveal).fill(0)
        c.store.promote(id(2))
        // The plaintext copy reappears (an old backup of snippets.json restored over the file).
        c.writeLibrary(snippet(1), snippet(2, content = "DUPLICATE-BODY"))
        c.markers.current = MoveMarker.None

        assertEquals(1, c.store.reconcileInterruptedMove())

        assertEquals(listOf(id(1)), c.library().map { it.id })
        assertTrue(c.store.isSecure(id(2)))
        assertEquals("DUPLICATE-BODY", c.store.content(id(2)))
    }

    @Test fun aFailedDemotionBeforeAnyWriteChangesNothing() = withComponents("demote-first-write") { c ->
        c.createVault()
        c.writeLibrary(snippet(2, content = "body"))
        c.session.unlock(c.reveal).fill(0)
        c.store.promote(id(2))
        val vaultBefore = c.scratch.bytes()
        val libraryBefore = Files.readAllBytes(c.scratch.library.toPath())

        c.io.beforeWrite = { _, _ -> throw IOException("no space") }
        assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.demote(id(2)) }

        assertContentEquals(vaultBefore, c.scratch.bytes())
        assertContentEquals(libraryBefore, Files.readAllBytes(c.scratch.library.toPath()))
        assertTrue(c.store.isSecure(id(2)))
    }

    @Test fun movesNeedAnOpenVaultAndAVaultThatIsStillTheSame() = withComponents("move-locked") { c ->
        c.createVault()
        c.writeLibrary(snippet(1))
        val libraryBefore = Files.readAllBytes(c.scratch.library.toPath())

        assertFailsWith<VaultSession.Failure.Locked> { c.store.promote(id(1)) }
        assertContentEquals(libraryBefore, Files.readAllBytes(c.scratch.library.toPath()))
        assertEquals(emptyList(), c.sync.events, "a locked vault must not even touch the sidecar")

        c.session.unlock(c.reveal).fill(0)
        c.store.promote(id(1))
        c.session.lock()
        assertFailsWith<VaultSession.Failure.Locked> { c.store.demote(id(1)) }
        assertTrue(c.store.isSecure(id(1)))

        // The vault on disk is no longer the one the session's key belongs to.
        c.writeLibrary(snippet(3))
        c.session.unlock(c.reveal).fill(0)
        c.scratch.vaultFile().write(RealVault("k-replaced").document)
        assertFailsWith<SecureSnippetStore.Failure.SetupChanged> { c.store.promote(id(3)) }
        assertEquals(listOf(id(3)), c.library().map { it.id })
    }

    /** The sidecar is written with ciphertext only, before the files move; a refusal there stops the move. */
    @Test fun theSyncSidecarSeesCiphertextOnlyAndCanStopAMove() = withComponents("sidecar") { c ->
        c.createVault()
        c.writeLibrary(snippet(1, content = "SIDECAR-PLAINTEXT"))
        c.session.unlock(c.reveal).fill(0)
        c.now = at(9000.0)
        c.sync.sourceHlc = clock(1_785_312_000_000L + 10_000_000, 7)

        c.sync.refuseMove = "sync metadata could not be read"
        val refused = assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.promote(id(1)) }
        assertEquals("sync metadata could not be read", refused.detail)
        c.sync.refuseMove = null
        c.sync.refusePersist = "could not preserve sync metadata before moving snippet"
        assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.promote(id(1)) }
        c.sync.refusePersist = null
        assertEquals(listOf(id(1)), c.library().map { it.id })
        assertEquals(emptyList(), c.vaultOnDisk()!!.records)
        assertEquals(listOf("write:vault.json"), c.io.log, "a refused move must write no primary file (the one write is the vault's creation)")

        c.store.promote(id(1))
        val destination = assertNotNull(c.sync.lastDestination)
        assertFalse(destination.sealed.contains("SIDECAR-PLAINTEXT"))
        assertEquals(c.store.record(id(1)), destination)
        // Stamped strictly above the envelope it replaces, whatever the wall clock says.
        assertTrue(destination.hlc.wallMs > c.sync.sourceHlc.wallMs)
        assertEquals(THIS_DEVICE, destination.hlc.device)
        assertEquals(listOf(id(1)), c.sync.lastSnippetsSeen.map { it.id }, "the hook sees the locked snapshot")

        // Demotion: the hook is told to persist the secure source; it is never handed the plaintext.
        c.sync.events.clear()
        c.sync.refusePersist = "could not preserve sync metadata before moving snippet"
        assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.demote(id(1)) }
        assertTrue(c.store.isSecure(id(1)))
        c.sync.refusePersist = null
        c.store.demote(id(1))
        assertEquals(listOf("move:${id(1)}", "move:${id(1)}", "demotion:${id(1)}"), c.sync.events)
    }

    /** A record carrying metadata this build does not understand cannot go back to nine plaintext keys. */
    @Test fun aRecordWithUnknownMetadataCannotBeDemoted() = withComponents("demote-unknown") { c ->
        val known = id(1)
        val unknown = id(2)
        val vault = RealVault("k-demote", known to "known body", unknown to "unknown body")
        val carriers = mapOf(
            "conflictCopy.v1" to JsonValue.obj("version" to JsonValue.of(1L)),
            "contentConflictOpaque.v1.${"ab".repeat(32)}" to JsonValue.of("b64"),
            "contentConflict.v1.${"cd".repeat(32)}" to JsonValue.obj(),
        )
        val document = vault.document.copy(
            records = listOf(
                vault.document.records[0].copy(x = carriers),
                vault.document.records[1].copy(x = mapOf("expiresAt" to JsonValue.of("2027-01-01T00:00:00.000Z"))),
            ),
        )
        c.keys.inner.store(vault.key, document.kid)
        c.scratch.vaultFile().write(document)
        c.store.reload()
        c.session.unlock(c.reveal).fill(0)

        val refused = assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.demote(unknown) }
        assertTrue(refused.detail.contains("newer build"))
        assertTrue(c.store.isSecure(unknown))

        c.store.demote(known)
        assertEquals("known body", c.library().single().content)
    }

    /** `testCoordinatedMovesPublishOnceOnlyAfterBothCachesAgreeOnOwnership` */
    @Test fun testCoordinatedMovesPublishOnceAfterTheCallerReloadedBothStores() = withComponents("coordinated") { c ->
        c.createVault()
        c.writeLibrary(snippet(1))
        c.session.unlock(c.reveal).fill(0)
        val before = c.store.revision.value

        c.store.promote(id(1), notifyChange = false)
        assertEquals(before, c.store.revision.value, "the move must not be announced before the ordinary store reloaded")
        assertTrue(c.store.isSecure(id(1)), "but the secure store already agrees with the disk")

        c.store.coordinatedMoveDidFinish()
        assertEquals(before + 1, c.store.revision.value)

        c.store.demote(id(1), notifyChange = false)
        assertEquals(before + 1, c.store.revision.value)
        c.store.coordinatedMoveDidFinish()
        assertEquals(before + 2, c.store.revision.value)
    }

    // A library's vault

    private fun identityOf(vault: RealVault, code: ByteArray): LibraryVaultIdentity = LibraryVaultIdentity(
        kid = vault.document.kid,
        vaultSalt = vault.document.vaultSalt,
        kdf = VaultKdfParameters(vault.document.kdf.alg, vault.document.kdf.iterations, vault.document.kdf.saltP),
        wrapRecovery = KeyWrap.wrap(vault.key, code, KeyWrap.Purpose.RECOVERY, vault.document.kid, vault.keyring.salt()),
    )

    @Test fun joiningALibraryVaultStoresTheKeyFirstAndWritesARecordsFreeDocument() = withComponents("join") { c ->
        c.policy.libraryOwnsVault = true
        val code = RecoveryKey.generate()
        val library = RealVault("k-library")
        val identity = identityOf(library, code)
        val order = ArrayList<String>()
        c.keys.onStore = { order.add("key") }
        c.io.afterWrite = { order.add("file:${it.name}") }

        // A code that does not open the published key: nothing is stored and nothing is written.
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.IncorrectRecoveryCode> {
            c.store.joinLibraryVault(identity, RecoveryKey.generate())
        }
        assertEquals(emptyList(), order)
        assertFalse(c.scratch.vault.exists())

        assertEquals(SecureSnippetStore.LibraryVaultAvailability.READY, c.store.joinLibraryVault(identity, code))
        assertEquals(listOf("key", "file:vault.json"), order)
        val joined = assertNotNull(c.vaultOnDisk())
        assertEquals(listOf(identity.kid, identity.vaultSalt, identity.wrapRecovery), listOf(joined.kid, joined.vaultSalt, joined.wrapRecovery))
        assertEquals(emptyList(), joined.records)
        assertContentEquals(library.key, c.keys.inner.load(identity.kid))
        assertEquals(VaultSession.State.LOCKED, c.session.state.value)
        assertEquals(SecureSnippetStore.LibraryVaultAvailability.READY, c.store.libraryVaultAvailability)
        assertEquals(SecureSnippetStore.LibraryVaultAvailability.READY, c.store.libraryVaultDisplayAvailability)

        // Joining again changes nothing and announces nothing.
        val revision = c.store.revision.value
        assertEquals(SecureSnippetStore.LibraryVaultAvailability.READY, c.store.joinLibraryVault(identity, code))
        assertEquals(revision, c.store.revision.value)
        assertEquals(1, c.keys.log.count { it.startsWith("store:") })
    }

    /** A code that opens the library but not the vault wrap still joins; secure snippets then wait for the key. */
    @Test fun joiningWithoutTheKeyLeavesAVaultThatWaitsForIt() = withComponents("join-keyless") { c ->
        c.policy.libraryOwnsVault = true
        val identity = identityOf(RealVault("k-library"), RecoveryKey.generate())

        assertEquals(SecureSnippetStore.LibraryVaultAvailability.KEY_MISSING, c.store.joinLibraryVault(identity))

        assertEquals(identity.kid, c.vaultOnDisk()!!.kid)
        assertEquals(VaultSession.State.NO_KEY, c.session.state.value)
        assertEquals(SecureSnippetStore.LibraryVaultAvailability.KEY_MISSING, c.store.libraryVaultDisplayAvailability)
        assertEquals(SecureSnippetStore.KeyMissingRemediation.LIBRARY_SETUP, c.store.status().keyMissingRemediation)
        assertFailsWith<SecureSnippetStore.Failure.LibraryVaultSetupRequired> { c.store.prepareVaultCreationIfNeeded() }
        assertEquals(emptyList(), c.keys.inner.storedKeyIds, "nothing may mint a rival key for a library's vault")
    }

    @Test fun aDifferentVaultInUseIsRefusedAndAnUnusedOneIsReplaced() = withComponents("join-different") { c ->
        val code = RecoveryKey.generate()
        val identity = identityOf(RealVault("k-library"), code)

        // An unused local vault (no records, never synced) is not in the way.
        c.createVault()
        val unusedKid = c.store.document!!.kid
        c.store.checkCanJoinLibraryVault(identity)
        assertFalse(c.store.libraryVaultNeedsReseal(identity))
        assertEquals(SecureSnippetStore.LibraryVaultAvailability.READY, c.store.joinLibraryVault(identity, code))
        assertEquals(identity.kid, c.vaultOnDisk()!!.kid)
        assertEquals(KeyPresence.PRESENT, c.keys.presence(unusedKid), "the unused vault's key stays in the key store untouched")

        // A vault that holds records is another vault: nothing is written.
        val other = identityOf(RealVault("k-another-library"), code)
        c.session.unlock(c.reveal).fill(0)
        c.store.addSecure("n", "kw", "body".toByteArray(), emptyList(), true, false)
        val before = c.scratch.bytes()
        val refused = assertFailsWith<SecureSnippetStore.LibraryVaultFailure.DifferentVault> { c.store.joinLibraryVault(other, code) }
        assertEquals(1, refused.secureCount)
        assertTrue(c.store.libraryVaultNeedsReseal(other))
        assertContentEquals(before, c.scratch.bytes())
        assertEquals(KeyPresence.ABSENT, c.keys.presence(other.kid), "a refused join must not store the other vault's key")

        // So is an empty vault whose kid has ever reached sync: tombstones would upload under it.
        c.store.delete(c.store.shells.single().id)
        c.sync.secureHistory = true
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.DifferentVault> { c.store.joinLibraryVault(other, code) }
        c.sync.secureHistory = false
        assertEquals(SecureSnippetStore.LibraryVaultAvailability.READY, c.store.joinLibraryVault(other, code))
    }

    @Test fun theSameVaultKeepsItsOwnRecoveryWrapAndGetsOneOnlyWhenItHasNone() = withComponents("join-same") { c ->
        val code = RecoveryKey.generate()
        val recoveryText = c.createVault()
        val own = c.store.document!!
        val key = c.keys.inner.load(own.kid)
        val asLibrary = LibraryVaultIdentity(
            own.kid, own.vaultSalt, own.kdf,
            KeyWrap.wrap(key, code, KeyWrap.Purpose.RECOVERY, own.kid, own.vaultSaltBytes!!),
        )

        c.store.joinLibraryVault(asLibrary, code)
        assertEquals(own.wrapRecovery, c.vaultOnDisk()!!.wrapRecovery, "the key the user saved earlier must keep working")
        assertNotNull(recoveryText)

        c.scratch.vaultFile().write(own.copy(wrapRecovery = null))
        c.store.reload()
        c.store.joinLibraryVault(asLibrary, code)
        assertEquals(asLibrary.wrapRecovery, c.vaultOnDisk()!!.wrapRecovery)
    }

    @Test fun publishingAVaultMintsOneOnlyWhenThereIsNoneAndAlwaysAsksTheOwnerOtherwise() = withComponents("publish") { c ->
        val code = RecoveryKey.generate()
        val publish = VaultAuthenticationReason.Other("Publish secure snippets to the library")

        // No vault: a key is minted and stored, no document is written, and nobody is asked.
        val minted = c.store.prepareLibraryVault(code, publish)
        assertTrue(minted.minted)
        assertEquals(0, c.owner.count.get())
        assertFalse(c.scratch.vault.exists())
        assertEquals(listOf(minted.identity.kid), c.keys.inner.storedKeyIds)
        assertContentEquals(
            c.keys.inner.load(minted.identity.kid),
            KeyWrap.unwrap(minted.identity.wrapRecovery, code, KeyWrap.Purpose.RECOVERY, minted.identity.kid, minted.identity.vaultSaltBytes!!),
        )
        // The library was never created: the key goes again.
        c.store.discardMintedLibraryVault(minted)
        assertEquals(emptyList(), c.keys.inner.storedKeyIds)

        // A vault with its key: the owner is asked every time, and the wrap opens to this vault's key.
        c.createVault()
        val own = c.store.document!!
        val published = c.store.prepareLibraryVault(code, publish)
        assertFalse(published.minted)
        assertEquals(1, c.owner.count.get())
        assertEquals(listOf<VaultAuthenticationReason>(publish), c.owner.reasons.toList())
        assertEquals(own.kid, published.identity.kid)
        assertContentEquals(
            c.keys.inner.load(own.kid),
            KeyWrap.unwrap(published.identity.wrapRecovery, code, KeyWrap.Purpose.RECOVERY, own.kid, own.vaultSaltBytes!!),
        )
        assertEquals(VaultSession.State.LOCKED, c.session.state.value, "publishing is a one-use authentication")
        c.store.discardMintedLibraryVault(published)
        assertEquals(listOf(own.kid), c.keys.inner.storedKeyIds, "an existing vault's key is never discarded")

        c.owner.result = VaultAuthenticationResult.CANCELLED
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.Authentication> { c.store.libraryVaultIdentity(code, publish) }

        // A vault in use whose key is not here cannot be published.
        c.owner.result = VaultAuthenticationResult.SUCCESS
        c.session.unlock(c.reveal).fill(0)
        c.store.addSecure("n", "kw", "b".toByteArray(), emptyList(), true, false)
        c.session.lock()
        c.keys.inner.delete(own.kid)
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.KeyUnavailable> { c.store.prepareLibraryVault(code, publish) }
    }

    /** Replacing the key re-seals every record in one write; nothing changes unless all of them re-seal. */
    @Test fun rotationResealsEveryRecordInOneWriteAndDeletesTheOldKeyLast() = withComponents("rotate") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val first = c.store.addSecure("one", "one", "body one".toByteArray(), emptyList(), true, false)
        val second = c.store.addSecure("two", "two", "body two ☕".toByteArray(), emptyList(), true, false)
        c.session.lock()
        val old = c.store.document!!
        val oldKey = c.keys.inner.load(old.kid)
        // Leftovers that belong to the old key and the old library.
        c.scratch.vaultFile().write(
            old.copy(wrapPass = "v1.old.pass", wrapCLI = "v1.old.cli")
                .recordingLocalConflictInstallReceiptHashes(mapOf(id(50) to "ab".repeat(32))),
        )
        c.store.reload()

        val newCode = RecoveryKey.generate()
        val rotate = VaultAuthenticationReason.Other("Replace the library's keys")
        val authenticationsBefore = c.owner.count.get()
        val pending = c.store.prepareVaultRotation(newCode, rotate)

        assertTrue(pending.authenticatedOwner)
        assertEquals(authenticationsBefore + 1, c.owner.count.get())
        assertNotEquals(old.kid, pending.identity.kid)
        assertEquals(setOf(old.kid, pending.identity.kid), c.keys.inner.storedKeyIds.toSet(), "the new key is stored before the library names it")
        assertEquals(old.kid, c.vaultOnDisk()!!.kid, "preparing changes nothing on disk")
        c.store.checkVaultRotation(pending)

        val writesBefore = c.io.log.size
        c.store.commitVaultRotation(pending)

        assertEquals(listOf("write:vault.json"), c.io.log.drop(writesBefore), "one write replaces the key")
        val rotated = c.vaultOnDisk()!!
        assertEquals(rotated, c.store.document)
        assertEquals(listOf(pending.identity.kid, pending.identity.vaultSalt, pending.identity.wrapRecovery), listOf(rotated.kid, rotated.vaultSalt, rotated.wrapRecovery))
        assertNull(rotated.wrapPass)
        assertNull(rotated.wrapCLI)
        assertEquals(emptyMap(), rotated.localConflictInstallReceipts)
        assertEquals(listOf(first, second), rotated.records.map { it.id })
        assertEquals(listOf(pending.identity.kid), c.keys.inner.storedKeyIds, "the old key is deleted once the vault has moved")

        // Every record opens under the new key and the new kid, with a recomputed keyed hash; the old key opens nothing.
        val newKey = KeyWrap.unwrap(rotated.wrapRecovery!!, newCode, KeyWrap.Purpose.RECOVERY, rotated.kid, rotated.vaultSaltBytes!!)
        SnippetCrypto.Keyring(newKey, rotated.vaultSaltBytes!!).use { keyring ->
            for ((record, body) in rotated.records.zip(listOf("body one", "body two ☕"))) {
                val opened = SnippetCrypto.open(record.sealed, SnippetCrypto.RecordContext(rotated.kid, record.id), keyring)
                assertEquals(body, String(opened, Charsets.UTF_8))
                assertEquals(SnippetCrypto.contentHash(opened, keyring), record.contentHash)
                assertNotEquals(old.record(record.id)!!.contentHash, record.contentHash)
            }
        }
        SnippetCrypto.Keyring(oldKey, old.vaultSaltBytes!!).use { keyring ->
            assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
                SnippetCrypto.open(rotated.records[0].sealed, SnippetCrypto.RecordContext(old.kid, first), keyring)
            }
        }
        c.session.unlock(c.reveal).fill(0)
        assertEquals("body two ☕", c.store.content(second))
    }

    @Test fun aRotationThatCannotResealEverythingChangesNothing() = withComponents("rotate-refused") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        c.store.addSecure("one", "one", "body".toByteArray(), emptyList(), true, false)
        c.session.lock()
        val rotate = VaultAuthenticationReason.Other("Replace the library's keys")
        val code = RecoveryKey.generate()
        val before = c.scratch.bytes()
        val kid = c.store.document!!.kid

        // A pending secure conflict is ciphertext under the current key.
        c.sync.pendingConflicts = true
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.PendingConflicts> { c.store.prepareVaultRotation(code, rotate) }
        c.sync.pendingConflicts = false

        // A record that does not open under the key.
        val document = c.store.document!!
        c.scratch.vaultFile().write(document.copy(records = listOf(document.records[0].copy(sealed = RealVault("k-x", id(9) to "x").document.records[0].sealed))))
        c.store.reload()
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.Unreadable> { c.store.prepareVaultRotation(code, rotate) }
        c.scratch.put(before!!)
        c.store.reload()

        // The owner says no.
        c.owner.result = VaultAuthenticationResult.CANCELLED
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.Authentication> { c.store.prepareVaultRotation(code, rotate) }
        c.owner.result = VaultAuthenticationResult.SUCCESS

        assertEquals(listOf(kid), c.keys.inner.storedKeyIds, "a refused rotation must not leave a minted key")
        assertContentEquals(before, c.scratch.bytes())

        // A conflict that arrives between prepare and commit is caught by the last check; discarding forgets the new key.
        val pending = c.store.prepareVaultRotation(code, rotate)
        val withCarrier = c.store.document!!.let { vault ->
            vault.copy(records = listOf(vault.records[0].copy(x = mapOf("contentConflictOpaque.v1.${"ab".repeat(32)}" to JsonValue.of("b64")))))
        }
        c.scratch.vaultFile().write(withCarrier)
        c.store.reload()
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.PendingConflicts> { c.store.checkVaultRotation(pending) }
        c.store.discardVaultRotation(pending)
        assertEquals(listOf(kid), c.keys.inner.storedKeyIds)
        assertEquals(kid, c.vaultOnDisk()!!.kid)
    }

    @Test fun aDeviceFollowsItsLibraryToTheReplacementByResealing() = withComponents("reseal-into") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("one", "one", "follow me".toByteArray(), emptyList(), true, false)
        c.session.lock()
        val oldKid = c.store.document!!.kid

        val code = RecoveryKey.generate()
        val replacement = RealVault("k-replacement")
        val identity = identityOf(replacement, code)
        val reason = VaultAuthenticationReason.Other("Move secure snippets to the library's new key")
        assertTrue(c.store.libraryVaultNeedsReseal(identity))
        c.store.checkCanResealIntoLibraryVault(identity)

        // The library's key is not here and no code was given; then a wrong code. Nothing changes.
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.RecoveryCodeRequired> { c.store.resealIntoLibraryVault(identity, null, reason) }
        assertFailsWith<SecureSnippetStore.LibraryVaultFailure.IncorrectRecoveryCode> {
            c.store.resealIntoLibraryVault(identity, RecoveryKey.generate(), reason)
        }
        assertEquals(oldKid, c.vaultOnDisk()!!.kid)
        assertEquals(listOf(oldKid), c.keys.inner.storedKeyIds)
        assertEquals(1, c.owner.count.get(), "the owner is not asked before the code is known to work")

        c.store.resealIntoLibraryVault(identity, code, reason)

        val moved = c.vaultOnDisk()!!
        assertEquals(identity.kid, moved.kid)
        assertEquals(listOf(identity.kid), c.keys.inner.storedKeyIds)
        assertContentEquals(replacement.key, c.keys.inner.load(identity.kid))
        c.session.unlock(c.reveal).fill(0)
        assertEquals("follow me", c.store.content(id))

        // Already there: nothing to do, and nothing asked.
        val asked = c.owner.count.get()
        c.store.resealIntoLibraryVault(identity, code, reason)
        assertEquals(asked, c.owner.count.get())
    }

    @Test fun secureSnippetsWhoseKeyIsGoneCannotBeMovedUnderAnotherKey() = withComponents("reseal-keyless") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        c.store.addSecure("one", "one", "body".toByteArray(), emptyList(), true, false)
        c.session.lock()
        c.keys.inner.delete(c.store.document!!.kid)
        val identity = identityOf(RealVault("k-replacement"), RecoveryKey.generate())

        val refused = assertFailsWith<SecureSnippetStore.LibraryVaultFailure.DifferentVault> { c.store.checkCanResealIntoLibraryVault(identity) }
        assertEquals(1, refused.secureCount)
    }

    // Removing the vault from this device

    @Test fun forgettingRemovesTheVaultThenTheKeyAndPrunesSyncStateFirst() = withComponents("forget") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        c.store.addSecure("n", "kw", "body".toByteArray(), emptyList(), true, false)
        val kid = c.store.document!!.kid
        c.writeLibrary(snippet(1))
        val order = ArrayList<String>()
        c.sync.onEvent = { order.add("sync:$it") }
        c.io.beforeRemove = { order.add("remove:${it.name}") }
        c.keys.log.clear()

        // Refused while sync is on, and while a round is running.
        c.policy.syncIsEnabled = true
        assertFailsWith<SecureSnippetStore.Failure.ForgetRequiresSyncOff> { c.store.forgetEverything(syncIsQuiescent = true) }
        c.policy.syncIsEnabled = false
        assertFailsWith<SecureSnippetStore.Failure.ForgetWaitForSync> { c.store.forgetEverything(syncIsQuiescent = false) }
        assertTrue(c.scratch.vault.exists())
        assertEquals(emptyList(), order)

        c.io.beforeRemove = {
            order.add("remove:${it.name}")
            assertEquals(KeyPresence.PRESENT, c.keys.presence(kid), "the key must outlive the file")
        }
        c.store.forgetEverything(syncIsQuiescent = true)

        assertEquals(listOf("sync:forget:1", "sync:pruned", "remove:vault.json"), order)
        assertEquals(listOf("delete:$kid"), c.keys.log, "the key goes last, after the file")
        assertFalse(c.scratch.vault.exists())
        assertEquals(emptyList(), c.keys.inner.storedKeyIds)
        assertFalse(c.store.hasVault)
        assertEquals(VaultSession.State.NO_KEY, c.session.state.value)
        assertEquals(SecureSnippetStore.VaultStatus.NOT_SET_UP, c.store.status().vault)
        assertFailsWith<VaultSession.Failure.Locked> { c.session.currentKey() }
        assertEquals(listOf(id(1)), c.library().map { it.id }, "ordinary snippets are untouched")

        // Nothing to forget is not an error, and a new vault can be set up afterwards.
        c.io.beforeRemove = {}
        c.store.forgetEverything(syncIsQuiescent = true)
        c.createVault()
        assertNotEquals(kid, c.store.document!!.kid)
    }

    /** `testForgetRollbackAfterKeychainRefusalRestoresExactVaultBaseAndJournal` */
    @Test fun testForgetRollbackAfterKeyStoreRefusalRestoresTheExactVault() = withComponents("forget-key") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("n", "kw", "body".toByteArray(), emptyList(), true, false)
        c.session.lock()
        val before = c.scratch.bytes()
        val kid = c.store.document!!.kid

        c.keys.failDelete = VaultKeyStoreException.Unavailable("refused")
        val failure = assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.forgetEverything(true) }

        assertTrue(failure.detail.contains("original state was restored"), failure.detail)
        assertContentEquals(before, c.scratch.bytes(), "the vault must be restored byte for byte")
        assertEquals(listOf("forget:1", "pruned", "rollback"), c.sync.events)
        assertEquals(KeyPresence.PRESENT, c.keys.presence(kid))
        assertTrue(c.store.isSecure(id))

        // The operation stays retryable, and the body is still readable in between.
        c.session.unlock(c.reveal).fill(0)
        assertEquals("body", c.store.content(id))
        c.session.lock()
        c.keys.failDelete = null
        c.store.forgetEverything(true)
        assertFalse(c.scratch.vault.exists())
        assertEquals(emptyList(), c.keys.inner.storedKeyIds)
    }

    /** `testForgetRollbackAfterPostUnlinkFailureRestoresExactVaultAndProtocolState` and the pruning failure before it. */
    @Test fun testForgetRollbackAfterAFailedRemovalOrAFailedPruneLeavesTheVaultAndItsKey() = withComponents("forget-file") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        c.store.addSecure("n", "kw", "body".toByteArray(), emptyList(), true, false)
        c.session.lock()
        val before = c.scratch.bytes()
        val kid = c.store.document!!.kid

        // The bookkeeping cannot be read at all: nothing is even attempted.
        c.sync.refuseForget = "sync bookkeeping could not be read"
        assertEquals("sync bookkeeping could not be read", assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.forgetEverything(true) }.detail)
        assertEquals(emptyList(), c.sync.events)
        c.sync.refuseForget = null

        // The pruned state cannot be written: rolled back, the vault never touched.
        c.sync.failPrunedWrite = "journal write failed"
        c.sync.rollbackFailures = listOf("sync base restore failed")
        val pruneFailure = assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.forgetEverything(true) }
        assertTrue(pruneFailure.detail.contains("rollback incomplete (sync base restore failed)"), pruneFailure.detail)
        assertEquals(emptyList(), c.io.log.filter { it.startsWith("remove:") })
        c.sync.failPrunedWrite = null
        c.sync.rollbackFailures = emptyList()
        c.sync.events.clear()

        // The file removal fails (or fails to become durable after the unlink): the vault is written back.
        c.io.beforeRemove = { throw IOException("directory sync failed") }
        val removal = assertFailsWith<SecureSnippetStore.Failure.Transaction> { c.store.forgetEverything(true) }
        assertTrue(removal.detail.contains("original state was restored"), removal.detail)
        assertEquals(listOf("forget:1", "pruned", "rollback"), c.sync.events)

        assertContentEquals(before, c.scratch.bytes())
        assertEquals(KeyPresence.PRESENT, c.keys.presence(kid), "the key is deleted last, so it is still here")
        assertEquals(emptyList(), c.keys.log.filter { it.startsWith("delete:") })
        assertTrue(c.store.hasVault)
    }

    // For sync

    @Test fun syncBorrowsTheKeyWithoutPromptingOrExtendingAndCanResealForAConflictCopy() = withComponents("sync") { c ->
        c.createVault()
        assertFailsWith<VaultSession.Failure.Locked> { c.store.unlockedKeyringForSync() }
        assertEquals(0, c.owner.count.get())

        c.session.unlock(c.reveal).fill(0)
        val source = c.store.addSecure("n", "kw", "conflict loser".toByteArray(), emptyList(), true, false)
        val deadline = c.session.deadlineMillis
        c.time.advance(60_000)
        val record = c.store.record(source)!!
        val kid = c.store.document!!.kid
        val copy = id(77)

        c.store.unlockedKeyringForSync().use { keyring ->
            assertEquals(deadline, c.session.deadlineMillis, "sync must not slide the idle deadline")
            val (sealed, hash) = assertNotNull(
                SecureSnippetStore.resealUnderAnotherId(record.sealed, kid, source, copy, keyring, record.contentHash),
            )
            assertEquals(record.contentHash, hash)
            assertNotEquals(record.sealed, sealed)
            // Bound to the copy's id: it opens there and nowhere else.
            assertEquals("conflict loser", String(SnippetCrypto.open(sealed, SnippetCrypto.RecordContext(kid, copy), keyring)))
            assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
                SnippetCrypto.open(sealed, SnippetCrypto.RecordContext(kid, source), keyring)
            }
            // A carried hash that does not match the body is reported, not papered over.
            assertNull(SecureSnippetStore.resealUnderAnotherId(record.sealed, kid, source, copy, keyring, "00".repeat(16)))
            // A body of another vault does not open.
            assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
                SecureSnippetStore.resealUnderAnotherId(record.sealed, "k-other", source, copy, keyring)
            }
        }
        assertEquals(1, c.owner.count.get())

        c.time.advance(VaultSession.DEFAULT_IDLE_WINDOW_MILLIS)
        assertFailsWith<VaultSession.Failure.Locked> { c.store.unlockedKeyringForSync() }
    }

    // Status

    @Test fun statusFollowsTheVaultAndTheSession() = withComponents("status") { c ->
        val empty = c.store.status()
        assertEquals(SecureSnippetStore.VaultStatus.NOT_SET_UP, empty.vault)
        assertEquals(0, empty.secureCount)
        assertFalse(empty.hasRecoveryKey)
        assertEquals(KeyStorageAvailability.AVAILABLE, empty.keyStorage)
        assertNull(empty.keyMissingRemediation)

        c.createVault()
        assertEquals(SecureSnippetStore.VaultStatus.LOCKED, c.store.status().vault)
        assertTrue(c.store.status().hasRecoveryKey)

        c.session.unlock(c.reveal).fill(0)
        c.store.addSecure("n", "kw", "b".toByteArray(), emptyList(), true, false)
        assertEquals(SecureSnippetStore.VaultStatus.UNLOCKED, c.store.status().vault)
        assertEquals(1, c.store.status().secureCount)

        c.session.lock()
        assertEquals(SecureSnippetStore.VaultStatus.LOCKED, c.store.status().vault)

        c.keys.inner.failEveryOperation(VaultKeyStoreException.Unavailable("no secure lock screen"))
        assertEquals(KeyStorageAvailability.UNAVAILABLE, c.store.status().keyStorage)
        assertEquals(SecureSnippetStore.VaultStatus.LOCKED, c.store.status().vault, "a failing key store is not a missing key")
    }

    @Test fun nothingSecretReachesAStringForm() = withComponents("strings") { c ->
        val pending = assertNotNull(c.store.prepareVaultCreationIfNeeded())
        assertFalse(pending.toString().contains(pending.recoveryKeyText))
        val identity = LibraryVaultIdentity("k-secret-id", "IiIi", VaultKdfParameters("a", 1, "VVVV"), "v1.wrap.text")
        assertFalse(identity.toString().contains("wrap"))
        assertFalse(identity.toString().contains("k-secret-id"))
        assertEquals(32, filled(1, 32).size)
    }
}
