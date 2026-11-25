package com.khm.snippets.core.io

import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermission
import java.nio.file.attribute.PosixFilePermissions
import java.util.EnumSet

/**
 * Writes a file atomically and durably (`AtomicFileWriter.swift`): the bytes go to a
 * temporary file, are forced to storage, and are renamed over the destination; then the
 * destination's directory is forced too. A reader sees the old contents or the new
 * ones, never a mixture and never an empty file.
 *
 * Both forces are protocol fences, not tidiness. The sync journal must be durable before
 * anything is sent, and the base before an acknowledgement: without the first force a
 * power loss can leave a renamed file with missing blocks, without the second it can
 * roll the rename back.
 */
object AtomicFileWriter {

    /** `rw-------`, the mode every library file is written with. */
    const val OWNER_READ_WRITE: Int = 384 // 0600

    // The JVM does not expose errno, so each failure carries the I/O exception instead.
    sealed class Failure(message: String, cause: Throwable?) : IOException(message, cause) {

        class CannotCreateTemporary(val directory: String, cause: Throwable?) :
            Failure("could not create a temporary file in $directory", cause)

        class WriteFailed(cause: Throwable?) : Failure("could not write the temporary file", cause)

        class RenameFailed(val destination: String, cause: Throwable?) :
            Failure("could not move the temporary file onto $destination", cause)

        class RemoveFailed(val path: String, cause: Throwable?) : Failure("could not remove $path", cause)

        /** The rename or removal has already happened; only its durability is unconfirmed. */
        class DirectorySyncFailed(val path: String, cause: Throwable?) :
            Failure("could not make the directory change durable at $path", cause)
    }

    /**
     * Replaces [destination] with [data].
     *
     * @param temporaryDirectory where the temporary file is staged; created if missing.
     *   It must be on the same filesystem as [destination]. If it turns out not to be,
     *   the write is staged beside the destination instead.
     * @param permissions POSIX mode bits of the result, also over an existing wider file.
     * @param directorySync test seam for the final directory force. A failure it throws
     *   propagates although the new contents are already in place.
     */
    @Throws(Failure::class)
    fun write(
        data: ByteArray,
        destination: File,
        temporaryDirectory: File,
        permissions: Int = OWNER_READ_WRITE,
        directorySync: ((File) -> Unit)? = null,
    ) {
        val target = destination.toPath()
        val staging = temporaryDirectory.toPath()
        try {
            Files.createDirectories(staging)
        } catch (_: IOException) {
            // As in Swift: creating the temporary file reports the problem.
        }

        val temporary = try {
            createTemporary(staging, destination.name)
        } catch (failure: IOException) {
            throw Failure.CannotCreateTemporary(temporaryDirectory.path, failure)
        } catch (failure: UnsupportedOperationException) {
            throw Failure.CannotCreateTemporary(temporaryDirectory.path, failure)
        }

        val parent = parentOf(destination)
        var renamed = false
        var stageBesideDestination = false
        try {
            applyPermissions(temporary, permissions)
            try {
                FileChannel.open(temporary, StandardOpenOption.WRITE).use { channel ->
                    val buffer = ByteBuffer.wrap(data)
                    while (buffer.hasRemaining()) channel.write(buffer)
                    // The bytes must be on stable storage before the rename publishes them.
                    channel.force(true)
                }
            } catch (failure: IOException) {
                throw Failure.WriteFailed(failure)
            }

            try {
                Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                renamed = true
            } catch (failure: AtomicMoveNotSupportedException) {
                // The staging directory is on another filesystem (EXDEV in Swift): stage
                // beside the destination instead, keeping both durability fences.
                if (sameDirectory(temporaryDirectory, parent)) throw Failure.RenameFailed(destination.path, failure)
                stageBesideDestination = true
            } catch (failure: IOException) {
                throw Failure.RenameFailed(destination.path, failure)
            }
        } finally {
            // Any failure past the creation must not leave a stray temporary file behind.
            if (!renamed) {
                try {
                    Files.deleteIfExists(temporary)
                } catch (_: IOException) {
                }
            }
        }
        if (stageBesideDestination) {
            write(data, destination, parent, permissions, directorySync)
            return
        }

        // The file's contents are durable; the directory entry pointing at them is not yet.
        (directorySync ?: ::synchronizeDirectory)(parent)
    }

    /**
     * Removes [file] and makes its absence durable. A file that is already gone is
     * success, and its directory is still forced: an earlier attempt may have removed
     * the file and failed before the force.
     */
    @Throws(Failure::class)
    fun removeDurablyIfPresent(file: File) {
        try {
            Files.delete(file.toPath())
        } catch (_: NoSuchFileException) {
            // Already the requested state.
        } catch (failure: IOException) {
            throw Failure.RemoveFailed(file.path, failure)
        }
        synchronizeDirectory(parentOf(file))
    }

    /** Forces a directory's entries to storage, the fence after a rename or a removal. */
    @Throws(Failure.DirectorySyncFailed::class)
    fun synchronizeDirectory(directory: File) {
        try {
            FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
        } catch (failure: IOException) {
            throw Failure.DirectorySyncFailed(directory.path, failure)
        }
    }

    private fun parentOf(file: File): File = file.absoluteFile.parentFile ?: file.absoluteFile

    private fun sameDirectory(first: File, second: File): Boolean =
        first.absoluteFile.toPath().normalize() == second.absoluteFile.toPath().normalize()

    private fun createTemporary(directory: Path, name: String): Path {
        // `mkstemp("<name>.XXXXXX")`: a new file with a unique name, owner-only from the start.
        return if (supportsPosix(directory)) {
            val ownerOnly = PosixFilePermissions.asFileAttribute(
                EnumSet.of(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
            )
            Files.createTempFile(directory, "$name.", "", ownerOnly)
        } else {
            Files.createTempFile(directory, "$name.", "")
        }
    }

    private fun supportsPosix(path: Path): Boolean =
        path.fileSystem.supportedFileAttributeViews().contains("posix")

    // `fchmod`, whose result Swift ignores as well: the file was created owner-only.
    private fun applyPermissions(file: Path, mode: Int) {
        if (!supportsPosix(file)) return
        try {
            Files.setPosixFilePermissions(file, posixPermissions(mode))
        } catch (_: IOException) {
        }
    }

    internal fun posixPermissions(mode: Int): Set<PosixFilePermission> {
        val result = EnumSet.noneOf(PosixFilePermission::class.java)
        val bits = arrayOf(
            PosixFilePermission.OTHERS_EXECUTE, PosixFilePermission.OTHERS_WRITE, PosixFilePermission.OTHERS_READ,
            PosixFilePermission.GROUP_EXECUTE, PosixFilePermission.GROUP_WRITE, PosixFilePermission.GROUP_READ,
            PosixFilePermission.OWNER_EXECUTE, PosixFilePermission.OWNER_WRITE, PosixFilePermission.OWNER_READ,
        )
        for (bit in bits.indices) {
            if (mode and (1 shl bit) != 0) result.add(bits[bit])
        }
        return result
    }
}
