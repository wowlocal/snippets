package com.khm.snippets.core.library

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.LibraryGuard
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.state.DurableFileIo
import com.khm.snippets.core.state.Halt
import com.khm.snippets.core.state.HaltDetail
import com.khm.snippets.core.state.HaltReason
import com.khm.snippets.core.state.HaltUpdateResult
import com.khm.snippets.core.state.LibraryQuarantineMarker
import com.khm.snippets.core.state.RecoveryContext
import com.khm.snippets.core.state.SyncState
import com.khm.snippets.core.state.SyncStateFile
import com.khm.snippets.core.state.SyncStateLoad
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * The unreadable-library rule (`SnippetStore.quarantineUnreadableLibrary` and the
 * quarantine checks of `SnippetStore.load`): a `snippets.json` that exists and cannot be
 * decoded is moved aside, never treated as empty, and sync is stopped before anything
 * could read its absence as "every record was deleted".
 *
 * ## The order is the contract
 *
 * Under the library guard:
 *
 * 1. The file is read again. A writer may have repaired it meanwhile; valid bytes are
 *    adopted ([Outcome.Repaired]) and nothing else happens.
 * 2. The [LibraryQuarantineMarker] is made durable. If that fails, the file stays where
 *    it is and the caller keeps its in-memory quarantine.
 * 3. A [HaltReason.LOCAL_LIBRARY_QUARANTINED] halt with
 *    [RecoveryContext.LocalLibraryQuarantine] is written to `state.json`, replacing any
 *    other halt. If that fails, the file stays where it is.
 * 4. Only then is the file moved to `snippets.json.corrupt-<yyyyMMdd-HHmmss>` beside it.
 *    A failed move leaves the file in place, which is conservative: the durable stop is
 *    already there.
 *
 * Each step that fails stops the sequence; a crash between any two leaves a state from
 * which the next launch repeats the rule or sees the quarantine. While the quarantine is
 * in effect ([isQuarantined]) every mutator of the store must refuse and nothing may be
 * persisted except an explicit authoritative recovery
 * ([LibraryWriter.replaceQuarantinedPrimary]).
 *
 * All calls block on file I/O.
 */
class LibraryQuarantine(
    private val libraryFile: File,
    private val marker: LibraryQuarantineMarker,
    private val stateFile: SyncStateFile,
    private val guard: LibraryGuard,
    private val io: DurableFileIo = DurableFileIo.Default,
) {

    constructor(locations: StorageLocations, io: DurableFileIo = DurableFileIo.Default) :
        this(locations.snippetsFile, LibraryQuarantineMarker(locations, io), SyncStateFile(locations, io), locations.guard, io)

    /** What [quarantineUnreadable] did. */
    sealed class Outcome {

        /** The file decodes now (someone repaired it). Adopt these; the quarantine holds only if [markerPresent]. */
        class Repaired(val snippets: List<Snippet>, data: ByteArray, val digest: String, val markerPresent: Boolean) : Outcome() {
            private val bytes = data.copyOf()
            val data: ByteArray get() = bytes.copyOf()
        }

        /**
         * The marker and the halt are durable. [preservedAs] is where the unreadable file
         * went, or `null` when it was gone already or could not be moved ([moveFailure]).
         */
        class Quarantined(val reviewId: UUID, val preservedAs: File?, val moveFailure: IOException?) : Outcome()

        /** The guard could not be taken in time. Nothing happened; keep the in-memory quarantine. */
        object Busy : Outcome()

        /** Step 2 failed. Nothing else happened. */
        class MarkerNotWritten(val cause: IOException) : Outcome()

        /** Step 3 found a `state.json` of another schema; it was not written and the file was not moved. */
        class StateUnsupported(val version: Long) : Outcome()

        /** Step 3 failed. The marker is durable; the file was not moved. */
        object HaltNotWritten : Outcome()
    }

    /**
     * Applies the rule to the library file.
     *
     * @param deviceId the device id the app uses, for a `state.json` that has to be created.
     * @param now seconds since 2001; the halt's time (floored to whole seconds, as Swift
     *   stores it) and the preserved file's name.
     * @param decode the store's reading of a library: `null` for bytes that are not one.
     *   The store loads through the import parser, which accepts more than
     *   [SnippetLibraryCodec]; the default is the codec.
     * @param zone the time zone of the preserved file's name (Swift uses the device's).
     */
    fun quarantineUnreadable(
        lockTimeoutMillis: Long,
        deviceId: String,
        now: Double = AppleTime.now(),
        decode: (ByteArray) -> List<Snippet>? = ::decodeWithCodec,
        zone: TimeZone = TimeZone.getDefault(),
    ): Outcome {
        val held = guard.acquire(lockTimeoutMillis) ?: return Outcome.Busy
        try {
            return quarantine(held, deviceId, now, decode, zone)
        } finally {
            held.close()
        }
    }

    private fun quarantine(
        held: LibraryGuard.Held,
        deviceId: String,
        now: Double,
        decode: (ByteArray) -> List<Snippet>?,
        zone: TimeZone,
    ): Outcome {
        val read = io.read(libraryFile)
        if (read is FileRead.Bytes) {
            decode(read.data)?.let { repaired ->
                return Outcome.Repaired(repaired, read.data, SnippetLibraryCodec.digest(read.data), marker.exists())
            }
        }

        val reviewId = try {
            marker.write()
        } catch (failure: IOException) {
            return Outcome.MarkerNotWritten(failure)
        }

        val halt = Halt(
            reason = HaltReason.LOCAL_LIBRARY_QUARANTINED,
            detail = HaltDetail.of(DETAIL_CODE),
            at = Math.floor(now),
            recoveryContext = RecoveryContext.LocalLibraryQuarantine,
        )
        when (val written = stateFile.replaceHaltWhileHolding(held, halt) { SyncState.fresh(deviceId) }) {
            is HaltUpdateResult.Written -> Unit
            is HaltUpdateResult.Unsupported -> return Outcome.StateUnsupported(written.version)
            else -> return Outcome.HaltNotWritten
        }

        if (!io.exists(libraryFile)) return Outcome.Quarantined(reviewId, null, null)
        val destination = preservedFile(now, zone)
        return try {
            io.moveAside(libraryFile, destination)
            Outcome.Quarantined(reviewId, destination, null)
        } catch (failure: IOException) {
            Outcome.Quarantined(reviewId, null, failure)
        }
    }

    /**
     * Whether the library is quarantined (`SnippetStore.load`): with a primary file, only
     * while the marker exists (a restored file is a recovery candidate until Check
     * Again retires the marker); without one, also when `state.json` holds a halt with
     * [RecoveryContext.LocalLibraryQuarantine] or is of another schema (which may hold
     * such a halt). A missing library is then never an empty one to seed or save over.
     */
    fun isQuarantined(): Boolean {
        val markerExists = marker.exists()
        if (io.exists(libraryFile)) return markerExists
        if (markerExists) return true
        return when (val loaded = stateFile.load()) {
            is SyncStateLoad.Loaded -> loaded.state.halt?.recoveryContext == RecoveryContext.LocalLibraryQuarantine
            is SyncStateLoad.Unsupported -> true
            is SyncStateLoad.Fresh -> false
        }
    }

    private fun preservedFile(now: Double, zone: TimeZone): File {
        val format = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
        format.timeZone = zone
        val stamp = format.format(Date(Math.floor(AppleTime.unixSeconds(now) * 1000.0).toLong()))
        val folder = libraryFile.absoluteFile.parentFile
        var candidate = File(folder, "$CORRUPT_PREFIX$stamp")
        var suffix = 2
        // Never over an earlier quarantine of the same second.
        while (io.exists(candidate)) {
            candidate = File(folder, "$CORRUPT_PREFIX$stamp-$suffix")
            suffix += 1
        }
        return candidate
    }

    companion object {

        /** The [HaltDetail.code] of the halt this rule writes. */
        const val DETAIL_CODE: String = "primary_library_preserved"

        /** The name prefix of a moved-aside unreadable library, beside `snippets.json`. */
        const val CORRUPT_PREFIX: String = "snippets.json.corrupt-"

        private fun decodeWithCodec(data: ByteArray): List<Snippet>? = try {
            SnippetLibraryCodec.decode(data)
        } catch (_: SnippetLibraryCodec.Unreadable) {
            null
        }
    }
}
