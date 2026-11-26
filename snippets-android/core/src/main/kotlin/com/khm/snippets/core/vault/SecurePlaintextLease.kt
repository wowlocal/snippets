package com.khm.snippets.core.vault

import com.khm.snippets.core.crypto.Utf8

/**
 * A one-owner, one-use plaintext buffer for an authenticated secure action such as
 * copying (`SecurePlaintextLease.swift`).
 *
 * [consuming] copies the decrypted bytes into an array only the lease holds and zeroes
 * the caller's array, so exactly one live copy of the body exists and [wipe] can end it.
 * Use it with `use { }`, or call [wipe] in a `finally`.
 *
 * What the JVM allows, stated plainly:
 *
 * - [wipe] zeroes the lease's array. A moving garbage collector may have copied the array
 *   before that and left the old bytes in freed heap until that memory is reused; nothing
 *   in Java can prevent or erase such a copy. Swift's lease owns a raw allocation and has
 *   no such gap.
 * - [makeUtf8String] creates a `String`, which is immutable and cannot be wiped at all.
 *   Create it at the last possible moment, hand it straight to the clipboard, and drop
 *   every reference. Android's clipboard takes a `CharSequence`, so one `String` is
 *   unavoidable.
 * - There is no deterministic destructor. The finalizer is a backstop for a lease that
 *   was dropped without [wipe]; it runs late or, at process exit, never.
 *
 * Not thread-safe: one owner creates, reads and wipes it.
 */
class SecurePlaintextLease private constructor(private var storage: ByteArray?) : AutoCloseable {

    var isWiped: Boolean = false
        private set

    /**
     * The only intended conversion to an unwipeable `String`; `null` once wiped or when
     * the bytes are not valid UTF-8.
     */
    fun makeUtf8String(): String? {
        val bytes = storage
        if (isWiped || bytes == null) return null
        return Utf8.decodeStrict(bytes)
    }

    /** Zeroes and drops the bytes. Idempotent, so an operation and its cleanup can both call it. */
    fun wipe() {
        storage?.fill(0)
        storage = null
        isWiped = true
    }

    override fun close() = wipe()

    @Suppress("unused")
    protected fun finalize() {
        wipe()
    }

    override fun toString(): String = "SecurePlaintextLease(${if (isWiped) "wiped" else "live"})"

    companion object {
        /** Takes over [plaintext]: copies it into the lease and zeroes the array that was passed in. */
        fun consuming(plaintext: ByteArray): SecurePlaintextLease {
            val lease = SecurePlaintextLease(plaintext.copyOf())
            plaintext.fill(0)
            return lease
        }
    }
}
