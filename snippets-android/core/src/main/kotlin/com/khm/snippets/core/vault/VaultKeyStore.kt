package com.khm.snippets.core.vault

import com.khm.snippets.core.crypto.SnippetCrypto

/**
 * Whether a vault key is on this device. Three values, because the answer to "is there a
 * key" decides whether a vault may be created or recovery state overwritten, and a store
 * that failed to answer must never be read as "no key".
 */
enum class KeyPresence {
    PRESENT,

    /** The store answered, and there is no key under this id. */
    ABSENT,

    /** The store could not answer (locked, unavailable, I/O). Callers treat this as [PRESENT] and fail closed later. */
    UNKNOWN,
}

/** Whether this device can hold a vault key at all, for the Settings "Key Storage" line. */
enum class KeyStorageAvailability {
    /** Keys can be stored. On Android they never leave the device. */
    AVAILABLE,

    /** The device has no secure lock screen, so the hardware-backed wrapping key cannot exist. */
    NO_DEVICE_CREDENTIAL,

    /** The key store itself is not working. */
    UNAVAILABLE,
}

/** Why a key store operation failed (`KeychainSecretStore.Failure`). Never carries key bytes. */
sealed class VaultKeyStoreException(message: String, cause: Throwable? = null) : Exception(message, cause) {

    /** No key is stored under this id. Thrown by [VaultKeyStore.load] only. */
    class NotFound : VaultKeyStoreException("no vault key is stored on this device")

    /** A vault key is exactly 32 bytes. Checked on store as well as on load. */
    class InvalidKeyLength(val count: Int) :
        VaultKeyStoreException("a vault key must be ${SnippetCrypto.KEY_BYTE_COUNT} bytes; found $count")

    /**
     * The platform demands a device-owner authentication it has not had, or one that has
     * expired. Apple has no such case: there the gate is in `VaultSession` only.
     */
    class AuthenticationRequired(cause: Throwable? = null) :
        VaultKeyStoreException("the key store needs a device-owner authentication", cause)

    /** The store did not work. This is not "no key". */
    class Unavailable(val detail: String, cause: Throwable? = null) :
        VaultKeyStoreException("the key store refused the request: $detail", cause)
}

/**
 * Where the vault library key `K_lib` lives, by key id (the vault's `kid`). This is the
 * primary home of the key; the wraps in `vault.json` are escape hatches.
 *
 * The app implements this on the Android Keystore (the 32 bytes wrapped by a
 * non-exportable Keystore key, the ciphertext in app-private storage that is excluded
 * from backup). `:core` and its tests use [InMemoryVaultKeyStore].
 *
 * Contract:
 *
 * - **Device-owner authentication is not this store's job.** [VaultSession] asks its
 *   [VaultAuthenticator] first and calls [load] immediately afterwards. A Keystore key
 *   that requires user authentication must accept the authentication that just
 *   happened; if it does not, throw [VaultKeyStoreException.AuthenticationRequired].
 * - **A failure is never absence.** [load] throws [VaultKeyStoreException.NotFound] only
 *   when the store positively knows there is no key. [presence] answers
 *   [KeyPresence.UNKNOWN] for any failure. A key that the platform has permanently
 *   invalidated (for example after the lock screen was removed) is absent: it can only
 *   come back through the recovery key or a backup.
 * - **[store] replaces in place.** There is no window in which neither the old nor the
 *   new value is stored; when it throws, the previous value is still there.
 * - **Length is checked on [store], [addIfAbsent] and [load]:** anything but 32 bytes is
 *   [VaultKeyStoreException.InvalidKeyLength] and nothing is written.
 * - **[delete] is idempotent.** Deleting a key that is not there succeeds.
 * - Arrays passed in are neither kept nor modified. Arrays returned belong to the
 *   caller, who wipes them.
 * - All functions may block and are safe to call from any thread, concurrently.
 * - Nothing here may log, or include in an exception, key bytes or a key id.
 */
interface VaultKeyStore {

    /** Stores [key] under [keyId], replacing any existing value. */
    @Throws(VaultKeyStoreException::class)
    fun store(key: ByteArray, keyId: String)

    /** The 32 key bytes. Called right after the device owner authenticated. */
    @Throws(VaultKeyStoreException::class)
    fun load(keyId: String): ByteArray

    /** Whether a key exists, without reading it and without prompting. Never throws. */
    fun presence(keyId: String): KeyPresence

    /** Removes the key. The ciphertext in `vault.json` is untouched. */
    @Throws(VaultKeyStoreException::class)
    fun delete(keyId: String)

    /**
     * Stores [key] only when nothing is stored under [keyId], and returns whichever value
     * ends up stored, so that two writers racing on one id agree on a winner.
     */
    @Throws(VaultKeyStoreException::class)
    fun addIfAbsent(key: ByteArray, keyId: String): ByteArray

    /** Whether this device can hold a key at all. For display; never a reason to create or delete anything. */
    fun availability(): KeyStorageAvailability
}

/** `hasKey`: a store that cannot answer counts as holding the key, so nothing mints or overwrites on its say-so. */
internal fun VaultKeyStore.mayHoldKey(keyId: String): Boolean = presence(keyId) != KeyPresence.ABSENT

/**
 * A [VaultKeyStore] in memory, for tests. Nothing in the app may fall back to it: a key
 * that lives only in the process cannot open the vault after a restart.
 */
class InMemoryVaultKeyStore(initial: Map<String, ByteArray> = emptyMap()) : VaultKeyStore {

    private val lock = Any()
    private val keys = HashMap<String, ByteArray>()
    private var stubbedFailure: VaultKeyStoreException? = null

    init {
        for ((id, key) in initial) keys[id] = key.copyOf()
    }

    /** Makes every operation fail with [failure] (and [presence] answer [KeyPresence.UNKNOWN]) until called with `null`. */
    fun failEveryOperation(failure: VaultKeyStoreException?) {
        synchronized(lock) { stubbedFailure = failure }
    }

    /** The ids currently held, sorted. For assertions only. */
    val storedKeyIds: List<String>
        get() = synchronized(lock) { keys.keys.sorted() }

    override fun store(key: ByteArray, keyId: String) {
        validate(key)
        synchronized(lock) {
            stubbedFailure?.let { throw it }
            keys[keyId] = key.copyOf()
        }
    }

    override fun load(keyId: String): ByteArray = synchronized(lock) {
        stubbedFailure?.let { throw it }
        val key = keys[keyId] ?: throw VaultKeyStoreException.NotFound()
        validate(key)
        key.copyOf()
    }

    override fun presence(keyId: String): KeyPresence = synchronized(lock) {
        when {
            stubbedFailure != null -> KeyPresence.UNKNOWN
            keys.containsKey(keyId) -> KeyPresence.PRESENT
            else -> KeyPresence.ABSENT
        }
    }

    override fun delete(keyId: String) {
        synchronized(lock) {
            stubbedFailure?.let { throw it }
            keys.remove(keyId)?.fill(0)
        }
    }

    override fun addIfAbsent(key: ByteArray, keyId: String): ByteArray {
        validate(key)
        return synchronized(lock) {
            stubbedFailure?.let { throw it }
            keys.getOrPut(keyId) { key.copyOf() }.copyOf()
        }
    }

    override fun availability(): KeyStorageAvailability = synchronized(lock) {
        if (stubbedFailure != null) KeyStorageAvailability.UNAVAILABLE else KeyStorageAvailability.AVAILABLE
    }

    private fun validate(key: ByteArray) {
        if (key.size != SnippetCrypto.KEY_BYTE_COUNT) throw VaultKeyStoreException.InvalidKeyLength(key.size)
    }

    override fun toString(): String = "InMemoryVaultKeyStore(redacted)"
}
