package com.khm.snippets.core.vault

import com.khm.snippets.core.crypto.filled
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The key-store contract, on the in-memory implementation every other suite uses. The
 * Swift counterparts are the `SecretStore` suite of `VaultDocumentTests.swift` and the
 * behaviours of `KeychainSecretStore` its callers rely on.
 */
class VaultKeyStoreTest {

    private fun key(byte: Int) = filled(byte, 32)

    @Test fun keysRoundTripAndOverwrite() {
        val store = InMemoryVaultKeyStore()

        assertEquals(KeyPresence.ABSENT, store.presence("k-1"))
        assertFailsWith<VaultKeyStoreException.NotFound> { store.load("k-1") }

        store.store(key(0xAB), "k-1")
        assertEquals(KeyPresence.PRESENT, store.presence("k-1"))
        assertContentEquals(key(0xAB), store.load("k-1"))

        // Replacement in place: there is never a moment with neither value.
        store.store(key(0xCD), "k-1")
        assertContentEquals(key(0xCD), store.load("k-1"))
        assertEquals(listOf("k-1"), store.storedKeyIds)
    }

    /** Deleting something that is not there succeeds: the postcondition is "there is no key under this id". */
    @Test fun deletingIsIdempotent() {
        val store = InMemoryVaultKeyStore(mapOf("k-1" to key(1)))

        store.delete("k-1")
        store.delete("k-1")

        assertEquals(KeyPresence.ABSENT, store.presence("k-1"))
        assertEquals(emptyList(), store.storedKeyIds)
    }

    /** Checked at the store, not only at the reader: a 31-byte key written once is a vault that never opens again. */
    @Test fun aKeyThatIsNotThirtyTwoBytesIsRejected() {
        val store = InMemoryVaultKeyStore()
        for (count in listOf(0, 16, 31, 33, 64)) {
            assertEquals(count, assertFailsWith<VaultKeyStoreException.InvalidKeyLength> { store.store(ByteArray(count), "k-1") }.count)
            assertEquals(count, assertFailsWith<VaultKeyStoreException.InvalidKeyLength> { store.addIfAbsent(ByteArray(count), "k-1") }.count)
        }
        assertEquals(emptyList(), store.storedKeyIds, "a rejected key was stored anyway")
    }

    /** Two writers that could each mint a value get one winner: the loser adopts what is already there. */
    @Test fun addIfAbsentReturnsTheIncumbent() {
        val store = InMemoryVaultKeyStore()
        assertContentEquals(key(1), store.addIfAbsent(key(1), "k-1"))
        assertContentEquals(key(1), store.addIfAbsent(key(2), "k-1"))
        assertContentEquals(key(1), store.load("k-1"))
    }

    /** Nothing handed in is kept and nothing handed out is shared: a caller wiping its array wipes only that. */
    @Test fun arraysAreCopiedInBothDirections() {
        val original = key(7)
        val store = InMemoryVaultKeyStore()
        store.store(original, "k-1")
        original.fill(0)
        val loaded = store.load("k-1")
        assertContentEquals(key(7), loaded)
        loaded.fill(0)
        assertContentEquals(key(7), store.load("k-1"))
    }

    /**
     * The three-valued answer. A store that failed must never be read as "no key":
     * presence is UNKNOWN, reads throw something other than NotFound, and the
     * convenience every caller uses counts the key as possibly there.
     */
    @Test fun aFailingStoreIsNeitherPresentNorAbsent() {
        val store = InMemoryVaultKeyStore(mapOf("k-1" to key(3)))
        val unavailable = VaultKeyStoreException.Unavailable("keystore unavailable")
        store.failEveryOperation(unavailable)

        assertEquals(KeyPresence.UNKNOWN, store.presence("k-1"))
        assertEquals(KeyPresence.UNKNOWN, store.presence("k-never-stored"))
        assertTrue(store.mayHoldKey("k-never-stored"), "an unanswerable store must fail closed")
        assertSame(unavailable, assertFailsWith<VaultKeyStoreException.Unavailable> { store.load("k-1") })
        assertSame(unavailable, assertFailsWith<VaultKeyStoreException.Unavailable> { store.load("k-never-stored") })
        assertFailsWith<VaultKeyStoreException.Unavailable> { store.store(key(4), "k-1") }
        assertFailsWith<VaultKeyStoreException.Unavailable> { store.delete("k-1") }
        assertFailsWith<VaultKeyStoreException.Unavailable> { store.addIfAbsent(key(4), "k-2") }
        assertEquals(KeyStorageAvailability.UNAVAILABLE, store.availability())

        store.failEveryOperation(null)
        assertContentEquals(key(3), store.load("k-1"), "the stub must be reversible and must have changed nothing")
        assertEquals(KeyPresence.ABSENT, store.presence("k-never-stored"))
        assertFalse(store.mayHoldKey("k-never-stored"))
        assertEquals(KeyStorageAvailability.AVAILABLE, store.availability())
    }

    @Test fun nothingAboutAKeyReachesAMessage() {
        val store = InMemoryVaultKeyStore(mapOf("k-very-identifying" to key(0x41)))
        assertFalse(store.toString().contains("k-very-identifying"))
        assertFalse(VaultKeyStoreException.NotFound().message!!.contains("k-"))
        assertFalse(VaultKeyStoreException.InvalidKeyLength(31).message!!.contains("AAAA"))
    }
}
