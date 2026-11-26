package com.khm.snippets.core.state

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.io.AtomicFileWriter
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.vault.VaultFileIo
import com.khm.snippets.core.wire.SyncEnvelope
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID

// Shared by the core.state, core.sync.base and core.library tests. Nothing here may name
// the user's real support folder: every root is a fresh temporary directory.

/** A storage root of its own, laid out as the app lays it out. Call [destroy] in a `finally`. */
internal class StateSandbox(label: String) {
    val root: File = Files.createTempDirectory("snippets-state-$label-").toFile()
    val locations = StorageLocations(File(root, "SnippetsClone")).also { it.createAllDirectories() }

    val library: File get() = locations.snippetsFile
    val stateFile: File get() = locations.syncStateFile
    val tmp: File get() = locations.tmpFolder

    fun destroy() {
        root.deleteRecursively()
    }
}

/** Unit on purpose: a JUnit 4 test method written as `= sandbox(…) { … }` must return nothing. */
internal inline fun sandbox(label: String, block: (StateSandbox) -> Unit) {
    val sandbox = StateSandbox(label)
    try {
        block(sandbox)
    } finally {
        sandbox.destroy()
    }
}

/** A process death in the middle of a sequence of writes: nothing below catches it. */
internal class SimulatedCrash : RuntimeException("simulated crash")

/**
 * A file system that can be told to fail or to stop. Every mutating operation (an atomic
 * write, a durable removal, a move) is counted from 1 and logged as `write:<name>`,
 * `remove:<name>` or `move:<name>`, after it happened.
 *
 * - [crashBefore] `= n`: the n-th mutation throws [SimulatedCrash] and does not happen.
 * - [crashAfter] `= n`: the n-th mutation happens (durably), then [SimulatedCrash] is thrown.
 * - [fail]: a mutation for which it answers `true` throws an [IOException] and does not happen.
 * - [beforeMutation], [afterMutation]: run around each mutation, e.g. to let another writer in.
 *
 * It is both seams ([DurableFileIo] and [VaultFileIo]), so one counter orders the writes
 * of `snippets.json`, `vault.json` and `state.json` in a transaction.
 */
internal class FaultInjectingIo : DurableFileIo, VaultFileIo {
    @Volatile var crashBefore: Int? = null
    @Volatile var crashAfter: Int? = null
    @Volatile var fail: (kind: String, file: File) -> Boolean = { _, _ -> false }
    @Volatile var beforeMutation: (kind: String, file: File) -> Unit = { _, _ -> }
    @Volatile var afterMutation: (kind: String, file: File) -> Unit = { _, _ -> }

    private val entries = ArrayList<String>()
    private var count = 0

    val log: List<String> get() = synchronized(entries) { ArrayList(entries) }
    val mutations: Int get() = synchronized(entries) { count }

    fun reset() = synchronized(entries) {
        entries.clear()
        count = 0
        crashBefore = null
        crashAfter = null
    }

    override fun read(file: File): FileRead = FileRead.read(file)

    override fun writeAtomically(data: ByteArray, destination: File, temporaryDirectory: File) =
        mutate("write", destination) { AtomicFileWriter.write(data, destination, temporaryDirectory) }

    override fun removeDurably(file: File) = mutate("remove", file) { AtomicFileWriter.removeDurablyIfPresent(file) }

    override fun moveAside(source: File, destination: File) =
        mutate("move", source) { DurableFileIo.Default.moveAside(source, destination) }

    override fun exists(file: File): Boolean = DurableFileIo.Default.exists(file)

    private fun mutate(kind: String, file: File, action: () -> Unit) {
        beforeMutation(kind, file)
        val index = synchronized(entries) { ++count }
        if (crashBefore == index) throw SimulatedCrash()
        if (fail(kind, file)) throw IOException("injected failure: $kind ${file.name}")
        action()
        synchronized(entries) { entries.add("$kind:${file.name}") }
        if (crashAfter == index) throw SimulatedCrash()
        afterMutation(kind, file)
    }
}

/** An id whose text has letters, so its uppercase spelling differs from its lowercase one. */
internal val LETTERED_ID: java.util.UUID = java.util.UUID.fromString("abcdef12-1212-4212-8212-abcdef121212")

/** Fixed test ids: `00000000-0000-4000-8000-<index as 12 hex digits>`. */
internal fun testId(index: Int): UUID = UUID.fromString("00000000-0000-4000-8000-%012x".format(index))

internal const val TEST_DEVICE = "a1b2c3d4"

internal fun testSnippet(index: Int, name: String = "Snippet $index", content: String = "Body of snippet $index"): Snippet =
    Snippet(
        id = testId(index), name = name, keyword = "kw$index", content = content,
        createdAt = 700_000_000.0 + index, updatedAt = 700_100_000.0 + index,
    )

internal fun testEnvelope(index: Int, name: String = "Snippet $index", wallMs: Long = 1_000L + index): SyncEnvelope =
    SyncEnvelope.plain(testSnippet(index, name), Hlc.of(wallMs, 0, TEST_DEVICE), TEST_DEVICE)

internal fun testTombstone(index: Int, wallMs: Long = 9_000L + index): SyncEnvelope =
    SyncEnvelope.tombstone(testId(index), secure = false, hlc = Hlc.of(wallMs, 0, TEST_DEVICE), origin = TEST_DEVICE)

/** What tells "republished" from "left alone": the file key holds the inode, and the time catches an in-place rewrite. */
internal fun fileIdentity(file: File): Pair<Any?, Long>? = try {
    val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
    attributes.fileKey() to attributes.lastModifiedTime().toMillis()
} catch (_: IOException) {
    null
}

internal fun entriesOf(folder: File): List<String> = folder.list()?.sorted() ?: emptyList()

internal fun seedState(sandbox: StateSandbox, state: SyncState) {
    Files.write(sandbox.stateFile.toPath(), SyncStateCodec.encode(state))
}

internal fun utf8(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)
