package com.khm.snippets.core.crypto

/**
 * Where the 12 bytes of every GCM nonce come from.
 *
 * Injected so tests and vectors can assert on exact bytes. There is no `fixed(...)`
 * convenience and there must never be one: a reused nonce under a reused key leaks the
 * GCM authentication subkey. A test that wants a stationary nonce writes the lambda
 * itself, where the choice is visible.
 */
fun interface NonceSource {

    /** A new array each call; the caller may keep it. Any length other than 12 is refused by `seal`. */
    fun nextNonce(): ByteArray

    companion object {
        /** 12 bytes from the system CSPRNG for every seal. Never a counter, never derived. */
        val System: NonceSource = NonceSource { Bytes.random(AesGcm.NONCE_BYTES) }
    }
}
