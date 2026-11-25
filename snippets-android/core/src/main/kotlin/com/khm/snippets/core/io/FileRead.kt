package com.khm.snippets.core.io

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.NoSuchFileException

/**
 * The three things reading a library file can mean. They must stay apart: a missing
 * file is an empty library, while a file that exists and cannot be read must never
 * present as one, because the next thing that happens to an empty library is that it is
 * saved.
 */
sealed class FileRead {

    /** No such file (ENOENT, also through a dangling link or a missing parent folder). */
    object Missing : FileRead()

    /** The file's complete contents. */
    class Bytes(val data: ByteArray) : FileRead()

    /** The file is there, or may be, and could not be read: permissions, a directory, an I/O error. */
    class Unreadable(val cause: IOException) : FileRead()

    companion object {

        /**
         * `java.io.FileNotFoundException` covers both a missing file and a refused one,
         * so this reads through `java.nio.file`, which tells them apart the way
         * `NSError.isFileNotFound` does in Swift.
         */
        fun read(file: File): FileRead = try {
            Bytes(Files.readAllBytes(file.toPath()))
        } catch (_: NoSuchFileException) {
            Missing
        } catch (failure: IOException) {
            Unreadable(failure)
        }
    }
}
