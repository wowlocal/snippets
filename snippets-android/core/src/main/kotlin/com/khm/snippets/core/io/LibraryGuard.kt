package com.khm.snippets.core.io

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The one lock over a storage root: `snippets.json`, `Vault/vault.json` and
 * `Sync/state.json` are all read, changed and written under it.
 *
 * Swift guards these files with `flock(2)` on `Sync/library.lock` because the Mac app,
 * its CLI and a debug build share one folder. The Android app is a single process with
 * private storage, so the lock is a mutex in memory and no lock file exists. If a
 * component is ever given its own `android:process`, this stops being enough.
 *
 * The contract is Swift's: acquiring waits up to a timeout and then reports busy; the
 * caller retries later and never runs its critical section unlocked or drops the write.
 * The lock is not reentrant, like a second `flock` on a new descriptor, and it may be
 * released from another thread than the one that took it.
 *
 * There is exactly one guard per root in the process: [forRoot] hands the same instance
 * to every caller, which is what makes independently built components exclude each other.
 */
class LibraryGuard private constructor() {

    private val permit = Semaphore(1, true)

    /** A held lock. Closing it more than once is harmless. */
    inner class Held internal constructor() : Closeable {
        private val released = AtomicBoolean(false)

        override fun close() {
            if (released.compareAndSet(false, true)) permit.release()
        }
    }

    /** Thrown by [withLock] when the lock could not be taken in time. Nothing ran. */
    class Busy : IOException("the library is busy")

    /** `true` while some caller holds the lock. For assertions and diagnostics only. */
    val isHeld: Boolean
        get() = permit.availablePermits() == 0

    /**
     * Waits up to [timeoutMillis] for the lock. `null` means busy. An interrupt while
     * waiting also gives `null`, with the thread's interrupt flag left set.
     */
    fun acquire(timeoutMillis: Long): Held? {
        val taken = try {
            permit.tryAcquire(maxOf(0L, timeoutMillis), TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        return if (taken) Held() else null
    }

    /** Runs [body] under the lock, or throws [Busy] without running it. */
    @Throws(Busy::class)
    inline fun <T> withLock(timeoutMillis: Long, body: () -> T): T {
        val held = acquire(timeoutMillis) ?: throw Busy()
        try {
            return body()
        } finally {
            held.close()
        }
    }

    companion object {

        private val guards = HashMap<String, LibraryGuard>()

        /** The guard of the storage root [root]. Two spellings of one folder give one guard. */
        fun forRoot(root: File): LibraryGuard {
            val key = try {
                root.canonicalPath
            } catch (_: IOException) {
                root.absoluteFile.toPath().normalize().toString()
            }
            synchronized(guards) {
                return guards.getOrPut(key) { LibraryGuard() }
            }
        }
    }
}
