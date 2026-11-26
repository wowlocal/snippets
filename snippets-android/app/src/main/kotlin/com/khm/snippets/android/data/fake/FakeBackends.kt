package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.MonotonicClock
import com.khm.snippets.android.platform.FakeDeviceAuthenticator
import com.khm.snippets.core.clock.AppleTime
import kotlinx.coroutines.CoroutineScope

/**
 * Every fake of one app, wired to each other: one library store behind the repository and the
 * vault, one set of [controls]. A test or a debug launch reaches them here to seed a library,
 * pick the authentication answer, add latency or failures, or move sync to any state.
 *
 * @param scope Runs the vault session timer.
 * @param clock The monotonic clock vault deadlines are measured on.
 * @param now Seconds since 2001, the clock of `createdAt` and `updatedAt`.
 */
class FakeBackends(
    scope: CoroutineScope,
    clock: MonotonicClock,
    now: () -> Double = AppleTime::now,
) {
    val controls = FakeControls()
    val authenticator = FakeDeviceAuthenticator()
    val store = FakeLibraryStore(now)
    val library = FakeLibraryRepository(store, controls)
    val vault = FakeSecureVault(store, authenticator, clock, scope, controls)
    val sync = FakeSyncController(controls, now)
    val settings = FakeAppSettings()

    /** Replaces the library with [entries]; a secure entry among them brings a locked vault. */
    fun seed(entries: List<SeedEntry>) {
        store.seed(entries)
        vault.setVault(exists = entries.any { it.secureBody != null })
    }
}
