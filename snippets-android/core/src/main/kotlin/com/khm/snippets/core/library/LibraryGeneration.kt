package com.khm.snippets.core.library

import com.khm.snippets.core.state.SyncState

/**
 * The library generation counter in `Sync/state.json` (`bumpGeneration` in
 * `LibraryGeneration.swift`), as pure functions over [SyncState].
 *
 * Every write of `snippets.json` through [LibraryWriter] advances
 * [SyncState.generation] and records the digest of the bytes it wrote in
 * [SyncState.librarySha256]. A later write that finds other bytes on disk than the
 * recorded ones knows that somebody wrote the file outside the writer, and records that
 * as a gap: the generation moves by two.
 *
 * ## What it is and is not for
 *
 * Swift keeps this for diagnostics; nothing in production reads it. On Android the
 * writer is the only path to `snippets.json` and the store and the engine detect a
 * library that changed under them by digest compare-and-swap instead:
 * [LibraryWriter.Outcome.foldedInForeignWrite] against the digest the caller expected,
 * and the bridge's expected-primary check. [changedOutsideWriter] is the same predicate
 * for a caller that holds only the state and a digest.
 *
 * The bookkeeping is best effort by design: a failure to record it never fails a library
 * write that has already landed, because the library is the user's data and
 * `state.json` is not. It is recorded only into a state that already exists; it never
 * creates one, so it can never stand in for a lost device identity.
 */
object LibraryGeneration {

    /**
     * [state] after a write of the bytes with digest [written] over bytes with digest
     * [observedOnDisk] (`""` for a missing file).
     *
     * `+1`, plus another `+1` first when [changedOutsideWriter]. Swift's counter is a
     * `UInt64` incremented with wrapping `&+=`; this one is a non-negative `Long` and
     * wraps from [Long.MAX_VALUE] to `0`.
     */
    fun advanced(state: SyncState, written: String, observedOnDisk: String): SyncState {
        var generation = state.generation
        if (changedOutsideWriter(state, observedOnDisk)) generation = increment(generation)
        generation = increment(generation)
        return state.copy(generation = generation, librarySha256 = written)
    }

    /**
     * Whether [observedOnDisk] (the digest of the library bytes found before writing) is
     * not what the writer recorded last: some other writer was there. A missing file
     * (`""`) and a state that has recorded nothing yet never count.
     */
    fun changedOutsideWriter(state: SyncState, observedOnDisk: String): Boolean {
        val known = state.librarySha256 ?: return false
        return observedOnDisk.isNotEmpty() && known != observedOnDisk
    }

    private fun increment(generation: Long): Long = if (generation == Long.MAX_VALUE) 0 else generation + 1
}
