package com.khm.snippets.core.vault

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.io.AtomicFileWriter
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.LibraryGuard
import com.khm.snippets.core.io.StorageLocations
import java.io.File
import java.io.IOException
import java.nio.file.Files

/**
 * The file operations the vault and the two-file transaction perform, as a seam so that
 * a test can fail any one of them. [Default] is the real file system.
 */
interface VaultFileIo {

    /** The file's bytes, or why there are none. A missing file and an unreadable one must stay apart. */
    fun read(file: File): FileRead

    /** Replaces [destination] atomically and durably, at mode 0600, staging in [temporaryDirectory]. */
    @Throws(IOException::class)
    fun writeAtomically(data: ByteArray, destination: File, temporaryDirectory: File)

    /** Removes [file] and makes its absence durable. A file that is already gone is success. */
    @Throws(IOException::class)
    fun removeDurably(file: File)

    object Default : VaultFileIo {
        override fun read(file: File): FileRead = FileRead.read(file)

        override fun writeAtomically(data: ByteArray, destination: File, temporaryDirectory: File) {
            AtomicFileWriter.write(data, destination, temporaryDirectory)
        }

        override fun removeDurably(file: File) {
            AtomicFileWriter.removeDurablyIfPresent(file)
        }
    }
}

/** Why a vault file operation did not happen (`VaultFileError`). Details name paths and causes, never contents. */
sealed class VaultFileError(message: String) : Exception(message) {

    /** The bytes could not be read at all. Not corruption: the file may be fine. */
    class Unreadable(val path: String, val detail: String) :
        VaultFileError("the vault at '$path' could not be read: $detail")

    /** Bytes were read and are not a vault. The quarantine case. */
    class Undecodable(val path: String, val detail: String) :
        VaultFileError("the vault at '$path' could not be understood: $detail")

    class WriteRefused(val detail: String) : VaultFileError(detail)

    class WriteFailed(val detail: String) : VaultFileError(detail)

    class QuarantineFailed(val detail: String) : VaultFileError(detail)
}

/**
 * The result of trying to load a vault (`VaultLoadOutcome`).
 *
 * There is deliberately no "fresh" outcome. A vault holds the only copy of things that
 * exist nowhere else, so a vault that cannot be read says why, and nothing ever
 * synthesizes an empty one in its place.
 */
sealed class VaultLoadOutcome<out T> {

    class Loaded<T>(val value: T) : VaultLoadOutcome<T>()

    /** No vault exists yet. The only outcome in which creating one is allowed. */
    object Missing : VaultLoadOutcome<Nothing>()

    /** Written by a newer build. Display it, never write it back. */
    class TooNew(val version: Long) : VaultLoadOutcome<Nothing>()

    /** Could not be read. Change nothing and try again later. */
    class Unreadable(val error: VaultFileError) : VaultLoadOutcome<Nothing>()

    /** Read, but not a vault. Quarantine; never overwrite. */
    class Corrupt(val error: VaultFileError) : VaultLoadOutcome<Nothing>()

    val valueOrNull: T? get() = (this as? Loaded<T>)?.value

    val tooNewVersion: Long? get() = (this as? TooNew)?.version

    val isCorrupt: Boolean get() = this is Corrupt

    val isMissing: Boolean get() = this === Missing

    /** The error behind [Unreadable] or [Corrupt]. */
    val failure: VaultFileError?
        get() = when (this) {
            is Unreadable -> error
            is Corrupt -> error
            else -> null
        }
}

/**
 * Loading, writing and quarantining `Vault/vault.json` (`VaultFile` in
 * `VaultDocument.swift`).
 *
 * Every change to an existing vault goes through [update]: under the library lock, the
 * file is read again, a side-effect-free transform is applied, and the write is a
 * compare-and-swap on the file's bytes that is verified by reading them back. The lock is
 * the library's, shared with `snippets.json`, because promoting a snippet moves it
 * between the two files.
 *
 * All calls block on file I/O.
 */
class VaultFile(
    val file: File,
    private val guard: LibraryGuard,
    private val temporaryDirectory: File,
    private val io: VaultFileIo = VaultFileIo.Default,
) {

    constructor(locations: StorageLocations, io: VaultFileIo = VaultFileIo.Default) :
        this(locations.vaultFile, locations.guard, locations.tmpFolder, io)

    // Load

    /**
     * Full load: version probe first, then decode. The probe comes first so that a file
     * from a newer build lands in [VaultLoadOutcome.TooNew] and not in "damaged", even
     * when the rest of it is unintelligible to this build.
     */
    fun load(): VaultLoadOutcome<VaultDocument> = when (val read = io.read(file)) {
        is FileRead.Missing -> VaultLoadOutcome.Missing
        is FileRead.Unreadable -> VaultLoadOutcome.Unreadable(unreadable(read.cause))
        is FileRead.Bytes -> {
            val version = probeSchemaVersion(read.data)
            if (version != null && version > VaultDocument.CURRENT_SCHEMA_VERSION) {
                VaultLoadOutcome.TooNew(version)
            } else {
                try {
                    VaultLoadOutcome.Loaded(decode(read.data))
                } catch (failure: VaultDecodeException) {
                    VaultLoadOutcome.Corrupt(undecodable(failure))
                }
            }
        }
    }

    /** Metadata-only load. Never touches `kdf` or the wraps and never refuses a newer file. */
    fun loadMetadata(): VaultLoadOutcome<VaultMetadata> = when (val read = io.read(file)) {
        is FileRead.Missing -> VaultLoadOutcome.Missing
        is FileRead.Unreadable -> VaultLoadOutcome.Unreadable(unreadable(read.cause))
        is FileRead.Bytes -> try {
            VaultLoadOutcome.Loaded(VaultDocumentCodec.decodeMetadata(read.data))
        } catch (failure: VaultDecodeException) {
            VaultLoadOutcome.Corrupt(undecodable(failure))
        }
    }

    // The exception class says what kind of I/O failure it was; its message may hold a path, which `path` already does.
    private fun unreadable(cause: IOException) = VaultFileError.Unreadable(file.path, cause.javaClass.simpleName)

    private fun undecodable(failure: VaultDecodeException) =
        VaultFileError.Undecodable(file.path, "${failure.kind}: ${failure.message}")

    // Write

    /**
     * Locked read-modify-write. Use this, not [write], for anything that changes an
     * existing vault.
     *
     * [transform] receives the vault as it is on disk now (`null` when there is none),
     * may run up to eight times and must have no side effects. What it throws propagates.
     *
     * @throws VaultFileError.WriteFailed when the lock is busy, the write fails, or the
     *   file changed under every attempt.
     * @throws VaultFileError.WriteRefused when the vault on disk is unreadable, corrupt
     *   or from a newer build, or the transform returned a newer schema.
     */
    @Throws(VaultFileError::class)
    fun update(lockTimeoutMillis: Long, transform: (VaultDocument?) -> VaultDocument): VaultDocument {
        val held = guard.acquire(lockTimeoutMillis)
            ?: throw VaultFileError.WriteFailed("another writer holds the vault; try again")
        try {
            repeat(MAXIMUM_ATTEMPTS) {
                // Read inside the lock: a caller's copy from a moment ago may be stale.
                val bytesAtRead = bytesOrNull()
                val before = currentDocument()
                val updated = transform(before)
                // The transform can mint a document of its own, so the schema guard runs after it.
                requireWritableSchema(updated)
                val data = try {
                    encode(updated)
                } catch (failure: VaultEncodeException) {
                    throw VaultFileError.WriteFailed("could not encode the vault: ${failure.message}")
                }
                createParentDirectory()

                // Compare against the bytes this attempt read, not the file against itself.
                if (!sameBytes(bytesOrNull(), bytesAtRead)) return@repeat

                try {
                    io.writeAtomically(data, file, temporaryDirectory)
                } catch (failure: IOException) {
                    throw VaultFileError.WriteFailed("could not save the vault: ${failure.javaClass.simpleName}")
                }

                // Confirm ours is what survived, so a writer that raced is folded in on the next attempt.
                if (!sameBytes(bytesOrNull(), data)) return@repeat
                return updated
            }
            throw VaultFileError.WriteFailed("the vault changed under every write attempt; try again")
        } finally {
            held.close()
        }
    }

    /**
     * Unlocked whole-document write. Only for creating a vault that does not exist yet,
     * for restoring one inside a critical section that already holds the lock, and for
     * tests.
     */
    @Throws(VaultFileError::class)
    fun write(document: VaultDocument) {
        requireWritableSchema(document)
        val data = try {
            encode(document)
        } catch (failure: VaultEncodeException) {
            throw VaultFileError.WriteFailed("could not encode the vault: ${failure.message}")
        }
        createParentDirectory()
        try {
            io.writeAtomically(data, file, temporaryDirectory)
        } catch (failure: IOException) {
            throw VaultFileError.WriteFailed("could not save the vault: ${failure.javaClass.simpleName}")
        }
    }

    // An older build must never write a newer vault: the one rule this format exists to enforce.
    private fun requireWritableSchema(document: VaultDocument) {
        if (document.schemaVersion > VaultDocument.CURRENT_SCHEMA_VERSION) {
            throw VaultFileError.WriteRefused(
                "refusing to write vault schemaVersion ${document.schemaVersion}; " +
                    "this build understands ${VaultDocument.CURRENT_SCHEMA_VERSION}",
            )
        }
    }

    /** The vault on disk now, or `null` without one. An unreadable vault is never "no vault". */
    private fun currentDocument(): VaultDocument? = when (val outcome = load()) {
        is VaultLoadOutcome.Loaded -> outcome.value
        is VaultLoadOutcome.Missing -> null
        is VaultLoadOutcome.TooNew -> throw VaultFileError.WriteRefused(
            "vault is schemaVersion ${outcome.version}; this build understands ${VaultDocument.CURRENT_SCHEMA_VERSION}",
        )
        is VaultLoadOutcome.Unreadable ->
            throw VaultFileError.WriteRefused("refusing to overwrite an unreadable vault: ${outcome.error.message}")
        is VaultLoadOutcome.Corrupt ->
            throw VaultFileError.WriteRefused("refusing to overwrite a corrupt vault: ${outcome.error.message}")
    }

    /** `try? Data(contentsOf:)`: the bytes, or `null` for a missing or unreadable file. */
    internal fun bytesOrNull(): ByteArray? = (io.read(file) as? FileRead.Bytes)?.data

    private fun createParentDirectory() {
        try {
            file.absoluteFile.parentFile?.let { Files.createDirectories(it.toPath()) }
        } catch (_: IOException) {
            // As in Swift: the write that follows reports the problem.
        }
    }

    // Quarantine

    /** Where a damaged vault is moved: a sibling folder, so the move is one rename. */
    val quarantineFolder: File get() = File(file.absoluteFile.parentFile, "Quarantine")

    /**
     * Moves an unreadable vault aside with its bytes intact: never a delete, never an
     * overwrite, and a move rather than a copy so the damaged file stops failing on every
     * launch. Afterwards [load] reports [VaultLoadOutcome.Missing].
     *
     * The destination is `vault-<yyyyMMdd-HHmmss>.json` in UTC, then `-2`, `-3`, … so a
     * second quarantine never overwrites the first. A note explaining the file is written
     * beside it, best effort.
     *
     * @param reason a description for the note. It must not contain secrets.
     * @param now seconds since 2001.
     */
    @Throws(VaultFileError.QuarantineFailed::class)
    fun quarantine(reason: String, now: Double = AppleTime.now()): File {
        if (!Files.exists(file.toPath())) {
            throw VaultFileError.QuarantineFailed("nothing to quarantine at '${file.path}'")
        }
        val folder = quarantineFolder
        try {
            Files.createDirectories(folder.toPath())
        } catch (failure: IOException) {
            throw VaultFileError.QuarantineFailed("could not create '${folder.path}': ${failure.javaClass.simpleName}")
        }

        val name = file.name
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0 && dot < name.length - 1) name.substring(dot + 1) else "json"
        val destination = uniqueFile(folder, "$stem-${VaultTimestamp.compactStamp(now)}", extension)

        try {
            Files.move(file.toPath(), destination.toPath())
        } catch (failure: IOException) {
            throw VaultFileError.QuarantineFailed(
                "could not move '${file.path}' to '${destination.path}': ${failure.javaClass.simpleName}",
            )
        }

        val note = "Snippets moved this file aside on ${VaultTimestamp.string(now)}.\n\n" +
            "Reason: $reason\n\n" +
            "It was NOT modified and NOT deleted. Its contents are the encrypted vault\n" +
            "exactly as they were found. Nothing overwrote it."
        try {
            val noteName = destination.name.substring(0, destination.name.length - extension.length) + "txt"
            Files.write(File(folder, noteName).toPath(), note.toByteArray(Charsets.UTF_8))
        } catch (_: IOException) {
            // Best effort: the quarantine itself succeeded.
        }
        return destination
    }

    private fun uniqueFile(folder: File, stem: String, extension: String): File {
        var candidate = File(folder, "$stem.$extension")
        var suffix = 2
        while (Files.exists(candidate.toPath())) {
            candidate = File(folder, "$stem-$suffix.$extension")
            suffix += 1
        }
        return candidate
    }

    companion object {

        private const val MAXIMUM_ATTEMPTS = 8

        /** The bytes of `vault.json`: pretty-printed, keys sorted, timestamps as ISO-8601 with milliseconds. */
        @Throws(VaultEncodeException::class)
        fun encode(document: VaultDocument): ByteArray =
            VaultDocumentCodec.encode(document, VaultDocumentCodec.Dates.ISO_8601)

        @Throws(VaultDecodeException::class)
        fun decode(data: ByteArray): VaultDocument =
            VaultDocumentCodec.decode(data, VaultDocumentCodec.Dates.ISO_8601)

        /** `schemaVersion` alone. `null` when the bytes are not a JSON object or it is absent. */
        fun probeSchemaVersion(data: ByteArray): Long? = VaultDocumentCodec.probeSchemaVersion(data)

        internal fun sameBytes(first: ByteArray?, second: ByteArray?): Boolean =
            if (first == null || second == null) first === second else first.contentEquals(second)
    }
}
