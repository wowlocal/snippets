package com.khm.snippets.core.backup

import com.khm.snippets.core.crypto.MacPbkdf2HmacSha512
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.Pbkdf2HmacSha512
import com.khm.snippets.core.vault.Components
import com.khm.snippets.core.vault.snippet
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Cancelling an export or an import stops its password derivation within a few thousand
 * rounds, not after the 600 000 (or the 20 million a hostile file may ask for).
 */
class EncryptedBackupCancellationTest {

    private val password = "correct horse battery staple".toCharArray()

    private class NoLibraryHost : OrdinaryLibraryHost {
        override val isLibraryQuarantined = false
        override fun flushPendingWrites() {}
        override fun reloadAfterExternalWrite() {}
    }

    /** The shipping PBKDF2, counting the cancellation checks it is handed and saying when the second one ran. */
    private class Counting : Pbkdf2HmacSha512 {
        val checks = AtomicInteger()
        val derivations = AtomicInteger()
        @Volatile var running = CompletableDeferred<Unit>()

        override fun derive(password: ByteArray, salt: ByteArray, iterations: Int, derivedKeyByteCount: Int): ByteArray =
            MacPbkdf2HmacSha512.derive(password, salt, iterations, derivedKeyByteCount)

        override fun derive(
            password: ByteArray, salt: ByteArray, iterations: Int, derivedKeyByteCount: Int, checkCancelled: () -> Unit,
        ): ByteArray {
            derivations.incrementAndGet()
            return MacPbkdf2HmacSha512.derive(password, salt, iterations, derivedKeyByteCount) {
                // The second check comes after the first 4 096 rounds.
                if (checks.incrementAndGet() == 2) running.complete(Unit)
                checkCancelled()
            }
        }

        fun reset() {
            checks.set(0)
            running = CompletableDeferred()
        }
    }

    private val maximumChecks = (PassphraseKdf.ITERATIONS / Pbkdf2HmacSha512.CANCELLATION_INTERVAL).toInt()

    @Test fun cancellingAnExportOrAnImportStopsTheDerivationPromptly() = runBlocking {
        val c = Components("kdf-cancel")
        try {
            c.writeLibrary(snippet(1))
            val kdf = Counting()
            // A real background dispatcher: the KDF must stop on its own thread, not be abandoned.
            val service = EncryptedBackupService(c.store, NoLibraryHost(), Dispatchers.Default, EmptyCoroutineContext, kdf)

            val export = async { service.makeEncryptedBackup(password, PassphraseKdf.MAXIMUM_ITERATIONS) }
            withTimeout(10_000) { kdf.running.await() }
            withTimeout(5_000) { export.cancelAndJoin() }
            assertFailsWith<CancellationException> { export.await() }
            val exportChecks = kdf.checks.get()
            assertTrue(exportChecks < 20, "the export ran $exportChecks × 4 096 rounds after its cancellation")

            // A complete export to import, at the shipping count.
            kdf.reset()
            val data = service.makeEncryptedBackup(password).data
            assertEquals(maximumChecks + 1, kdf.checks.get(), "an uncancelled derivation checks before it starts and every 4 096 rounds")

            kdf.reset()
            val import = async { service.prepareImport(data, password) }
            withTimeout(10_000) { kdf.running.await() }
            withTimeout(5_000) { import.cancelAndJoin() }
            assertFailsWith<CancellationException> { import.await() }
            val importChecks = kdf.checks.get()
            assertTrue(importChecks < 20, "the import ran $importChecks × 4 096 of 600 000 rounds after its cancellation")
            assertTrue(importChecks < maximumChecks / 4)

            // And an import that is left alone still opens the backup.
            service.prepareImport(data, password).use { assertEquals(1, it.ordinaryCount) }
        } finally {
            c.destroy()
        }
    }
}
