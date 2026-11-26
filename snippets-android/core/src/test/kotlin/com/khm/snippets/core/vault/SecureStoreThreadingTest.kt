package com.khm.snippets.core.vault

import com.khm.snippets.core.crypto.SnippetCrypto
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * What Swift gets from running the store on one actor and Kotlin has to arrange itself:
 * a write sealed for one vault never lands in another, and the session's pre-lock saves
 * never wait on a lock the caller holds. Also the helpers the secure conflict
 * materializer and the app's lifecycle code call.
 */
class SecureStoreThreadingTest {

    private fun withComponents(label: String, block: suspend (Components) -> Unit) = runTest {
        val components = Components(label)
        try {
            block(components)
        } finally {
            components.destroy()
        }
    }

    /** A body sealed under the vault this store loaded is refused by a vault that replaced it underneath. */
    @Test fun aBodySealedForOneVaultNeverLandsInAVaultThatReplacedIt() = withComponents("replaced") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("Token", "token", "first".toByteArray(), emptyList(), true, false)

        // Another writer (the sync bridge, a backup import) puts a different vault in place without telling this store.
        val rival = RealVault("k-rival-vault", id to "rival body")
        c.scratch.vaultFile().write(rival.document)
        val before = Files.readAllBytes(c.scratch.vault.toPath())

        assertFailsWith<SecureSnippetStore.Failure.SetupChanged> { c.store.setContent("second", id) }
        assertContentEquals(before, Files.readAllBytes(c.scratch.vault.toPath()), "the rival vault is untouched")
        val onDisk = assertNotNull(c.vaultOnDisk())
        assertEquals("rival body", String(SnippetCrypto.open(onDisk.records.single().sealed, SnippetCrypto.RecordContext("k-rival-vault", id), rival.keyring)))
    }

    /**
     * Removing the vault locks an open session after it has released the library lock:
     * the editor's pre-lock save runs against the removed vault and fails at once, instead
     * of waiting out the lock timeout behind the removal that holds it.
     */
    @Test fun forgettingTheVaultLocksTheSessionOutsideTheLibraryLock() = withComponents("forget-hook") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("Token", "token", "body".toByteArray(), emptyList(), true, false)
        var guardHeldDuringHook: Boolean? = null
        var hookFailure: Exception? = null
        c.session.addPreLockHook {
            guardHeldDuringHook = c.scratch.locations.guard.isHeld
            try {
                c.store.setContent("pending edit", id)
            } catch (failure: Exception) {
                hookFailure = failure
            }
        }

        val started = System.nanoTime()
        c.store.forgetEverything(syncIsQuiescent = true)
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000

        assertEquals(false, guardHeldDuringHook, "the hook must not run under the lock it needs")
        assertIs<SecureSnippetStore.Failure.NoSuchRecord>(hookFailure, "the vault is gone; the save is refused, not timed out")
        assertTrue(elapsedMillis < SecureSnippetStore.DEFAULT_LOCK_TIMEOUT_MILLIS, "took $elapsedMillis ms")
        assertFalse(c.scratch.vault.exists())
        assertEquals(VaultSession.State.NO_KEY, c.session.state.value)
    }

    /** The lifecycle entry point for `ON_STOP`: pre-lock saves first, then the key is gone. */
    @Test fun enteringTheBackgroundLocksAfterThePreLockSave() = withComponents("background") { c ->
        c.createVault()
        c.session.unlock(c.reveal).fill(0)
        val id = c.store.addSecure("Token", "token", "typed so fa".toByteArray(), emptyList(), true, false)
        c.session.addPreLockHook { c.store.setContent("typed so far", id) }

        c.session.appDidEnterBackground()

        assertEquals(VaultSession.State.LOCKED, c.session.state.value)
        assertFailsWith<VaultSession.Failure.Locked> { c.session.currentKey() }
        c.session.unlock(c.reveal).fill(0)
        assertEquals("typed so far", c.store.content(id), "the last edit before backgrounding was saved")
    }

    /** What the materializer runs on a copy already in the vault before it trusts it. */
    @Test fun aSealedBodyIsAuthenticatedUnderItsOwnIdAndItsKeyedHash() {
        val vault = RealVault("k-authenticate", id(1) to "body")
        val record = vault.document.records.single()

        assertTrue(SecureSnippetStore.authenticateSealed(record.sealed, vault.document.kid, record.id, record.contentHash, vault.keyring))
        assertFalse(SecureSnippetStore.authenticateSealed(record.sealed, vault.document.kid, record.id, "00".repeat(16), vault.keyring))
        assertFailsWith<SnippetCrypto.Failure> {
            SecureSnippetStore.authenticateSealed(record.sealed, vault.document.kid, id(2), record.contentHash, vault.keyring)
        }
        assertFailsWith<SnippetCrypto.Failure> {
            SecureSnippetStore.authenticateSealed(record.sealed, "k-other", record.id, record.contentHash, vault.keyring)
        }

        // Re-sealed under a copy id, the copy authenticates under that id and keeps the hash.
        val (copySealed, hash) = assertNotNull(
            SecureSnippetStore.resealUnderAnotherId(record.sealed, vault.document.kid, record.id, id(9), vault.keyring, record.contentHash),
        )
        assertEquals(record.contentHash, hash)
        assertTrue(SecureSnippetStore.authenticateSealed(copySealed, vault.document.kid, id(9), hash, vault.keyring))
        assertNull(SecureSnippetStore.resealUnderAnotherId(record.sealed, vault.document.kid, record.id, id(9), vault.keyring, "ff".repeat(16)))
    }
}
