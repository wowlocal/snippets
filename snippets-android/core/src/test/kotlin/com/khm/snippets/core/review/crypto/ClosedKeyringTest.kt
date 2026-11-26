package com.khm.snippets.core.review.crypto

import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.SnippetCrypto
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith
import kotlin.test.fail

/**
 * DEFECT D3. These tests fail until a closed `Keyring` refuses to be used.
 *
 * `SnippetCrypto.Keyring.close()` (`SnippetCrypto.kt:99-102`) zeroes the root key and
 * leaves the object usable: every later `recordKey`, `contentHashKey` and `libraryKey`
 * answers from 32 zero bytes. A seal that races a lock, or a `use { }` block that leaks its
 * keyring, then writes ciphertext under `HKDF(zeros, vaultSalt, …)`. `vaultSalt` is stored
 * in the clear beside the ciphertext, so anyone holding the file can open that record;
 * every honest device, holding the real key, cannot. Swift has no such state: its keyring
 * is a value that cannot be emptied. A wiped key must fail closed.
 */
class ClosedKeyringTest {

    private val salt = ByteArray(32) { 0x22 }
    private val context = SnippetCrypto.RecordContext("0b9f6a52-0c1e-4c6b-9a55-000000000001", UUID.fromString("00000000-0000-4000-8000-000000000001"))
    private val secret = "public fixture: 4-digit PIN 0000".toByteArray()

    @Test fun sealingWithAClosedKeyringIsRefused() {
        val ring = SnippetCrypto.Keyring(ByteArray(32) { 0x11 }, salt)
        ring.close()

        val sealed = try {
            SnippetCrypto.seal(secret, context, ring)
        } catch (_: IllegalStateException) {
            return   // the fix: fail closed
        }
        // What happened instead: the record is readable with no secret at all.
        SnippetCrypto.Keyring(ByteArray(32), salt).use { nobody ->
            assertContentEquals(secret, SnippetCrypto.open(sealed, context, nobody))
        }
        fail("a closed keyring sealed a record under an all-zero root key; the vault salt is public, so the record is readable by anyone")
    }

    @Test fun aClosedKeyringHandsOutNoKeys() {
        val ring = SnippetCrypto.Keyring(ByteArray(32) { 0x11 }, salt)
        ring.close()
        assertFailsWith<IllegalStateException>("recordKey after close") { ring.recordKey(context.recordId) }
        assertFailsWith<IllegalStateException>("contentHashKey after close") { ring.contentHashKey() }
        assertFailsWith<IllegalStateException>("libraryKey after close") { ring.libraryKey() }
    }

    /** The same hole one layer up: the zero key wraps without complaint under a real recovery key. */
    @Test fun aClosedKeyringsKeyIsNotWrappedForRecovery() {
        val ring = SnippetCrypto.Keyring(ByteArray(32) { 0x11 }, salt)
        ring.close()
        val recovery = ByteArray(16) { 0x33 }
        val wrapped = try {
            KeyWrap.wrap(ring.libraryKey(), recovery, KeyWrap.Purpose.RECOVERY, "kid", salt)
        } catch (_: IllegalStateException) {
            return
        }
        assertContentEquals(ByteArray(32), KeyWrap.unwrap(wrapped, recovery, KeyWrap.Purpose.RECOVERY, "kid", salt))
        fail("the recovery wrap now holds 32 zero bytes: recovery would \"succeed\" and open nothing")
    }
}
