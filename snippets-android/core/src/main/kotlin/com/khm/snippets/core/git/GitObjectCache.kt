package com.khm.snippets.core.git

import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/**
 * Complete snapshots of a few recent commits, kept so a fetch can diff two trees
 * locally and tell the server which objects it already has.
 *
 * The cache is an optimization, never a source of truth. Objects are content
 * addressed and re-hashed on every read, so a corrupt or truncated file is simply a
 * miss; a missing cache degrades to a full snapshot fetch, which the engine already
 * treats as a snapshot rather than a delta. Nothing here is a credential or a cursor,
 * and nothing of that kind may ever be stored here.
 *
 * Each file is `"<type> <size>\0<content>"`, the exact bytes git hashes. Contents
 * are record ciphertext and tree listings that the host also holds.
 *
 * Directories are created private to the owner (mode 0700 where the file system has
 * modes). The cache must also stay out of backups: on Android the caller places
 * `directory` under `noBackupFilesDir`.
 *
 * `scope` names the repository and branch. A cache written for any other scope, or by
 * an unknown schema, is discarded rather than interpreted.
 *
 * **Threading.** Every function, the constructor included, does blocking file I/O
 * and hashing: the transport calls the cache from its I/O dispatcher, never from the
 * main thread. Calls are serialized by the cache's own lock, so each is atomic, but a
 * sequence of calls is not: a `pin`, `release` or `prune` from another thread may run
 * between two of them and remove objects no snapshot holds yet. A snapshot is
 * therefore added with [install], which stores and retains under one lock; [store]
 * followed by [retain] is safe only while nothing else uses the cache.
 *
 * **Failures.** Reading never throws: whatever is found on disk is the right object
 * or a miss. Writing throws `IOException` when the file system refuses (a full
 * disk); the cache stays consistent, and the caller may go on without it.
 */
class GitObjectCache(private val directory: File, private val scope: String) {
    data class Retained(val commit: String, val tree: String)

    private data class State(
        val schemaVersion: Int,
        val scope: String,
        val retained: List<Retained>,
        /**
         * The snapshots the next fetch may diff against: the head the last fetch
         * returned and the base it diffed from. Submit commits never evict them.
         */
        val pinned: List<Retained>,
    )

    private val objectsDirectory = File(directory, "objects")
    private val stateFile = File(directory, "state.json")
    private var state = emptyState()

    init {
        val saved = readState()
        if (saved != null && saved.schemaVersion == SCHEMA_VERSION && saved.scope == scope) {
            state = saved
        } else {
            try {
                removeAll()
            } catch (_: IOException) {
                // What could not be removed is re-hashed on read and pruned later.
            }
        }
        try {
            createDirectories(directory)
        } catch (_: IOException) {
            // The first write reports it; an unusable cache is only a slower fetch.
        }
    }

    // MARK: Objects

    @Synchronized
    fun get(id: GitObjectId): GitObject? {
        val file = file(id)
        if (file.length() > MAXIMUM_FILE_BYTES) return null
        val data = try {
            file.readBytes()
        } catch (_: IOException) {
            return null
        }
        val nul = data.indexOfByte(0)
        if (nul < 0) return null
        val parts = data.decodeUtf8Lossy(0, nul).split(' ').filter { it.isNotEmpty() }
        if (parts.size != 2) return null
        val type = GitObjectType.fromName(parts[0]) ?: return null
        if (parts[1].toIntOrNull() != data.size - nul - 1) return null
        val found = GitObject(type, data.copyOfRange(nul + 1, data.size))
        if (found.id != id) {
            file.delete()
            return null
        }
        return found
    }

    @Synchronized
    fun contains(id: GitObjectId): Boolean = file(id).exists()

    /**
     * Writes `obj` unless a valid copy is already present. [get] deletes a corrupt
     * copy, so a refetched object always replaces a damaged one.
     */
    @Synchronized
    fun store(obj: GitObject, id: GitObjectId) {
        val target = file(id)
        if (target.exists() && get(id) != null) return
        createDirectories(target.parentFile)
        writeAtomically(target, GitObjectType.header(obj.type, obj.content.size), obj.content)
    }

    /**
     * Adds a complete snapshot in one step: stores `objects` (children before
     * parents, as [store] would) and retains `commit`, with no other call able to
     * prune in between.
     *
     * Objects of the snapshot that are not in `objects` must already be cached.
     * That is checked here, under the same lock: when the commit or anything
     * reachable from `tree` is missing afterwards, nothing is retained and the
     * result is false (what was stored is unreferenced and goes with the next prune).
     */
    @Synchronized
    fun install(objects: List<GitObject>, commit: GitObjectId, tree: GitObjectId): Boolean {
        for (obj in objects) store(obj, obj.id)
        if (get(commit)?.type != GitObjectType.COMMIT || reachableObjects(tree) == null) return false
        retain(commit, tree)
        return true
    }

    // MARK: Retained snapshots

    val retained: List<Retained> @Synchronized get() = state.retained

    /** Every commit whose complete snapshot is held, most recently used first. */
    val snapshotCommits: List<GitObjectId>
        @Synchronized get() {
            val seen = HashSet<String>()
            return (state.retained + state.pinned)
                .filter { seen.add(it.commit) }
                .mapNotNull { GitObjectId.fromHex(it.commit) }
        }

    @Synchronized
    fun retainedTree(commit: GitObjectId): GitObjectId? =
        (state.retained + state.pinned).firstOrNull { it.commit == commit.hex }?.let { GitObjectId.fromHex(it.tree) }

    /**
     * Keeps these `(commit, tree)` snapshots until the next pin replaces them. Each
     * must already be stored, which every installed snapshot is.
     */
    @Synchronized
    fun pin(snapshots: List<Pair<GitObjectId, GitObjectId>>) {
        val seen = HashSet<String>()
        val entries = snapshots.map { Retained(it.first.hex, it.second.hex) }.filter { seen.add(it.commit) }
        if (state.pinned == entries) return
        persist(state.copy(pinned = entries))
        prune()
    }

    /**
     * Marks `commit` most recently used. The caller has already stored every object
     * reachable from `tree`. Older snapshots beyond the limit are released and their
     * unshared objects removed.
     */
    @Synchronized
    fun retain(commit: GitObjectId, tree: GitObjectId) {
        val retained = listOf(Retained(commit.hex, tree.hex)) + state.retained.filter { it.commit != commit.hex }
        val evicted = retained.size > MAXIMUM_RETAINED_COMMITS
        persist(state.copy(retained = retained.take(MAXIMUM_RETAINED_COMMITS)))
        if (evicted) prune()
    }

    @Synchronized
    fun release(commit: GitObjectId) {
        val next = state.copy(
            retained = state.retained.filter { it.commit != commit.hex },
            pinned = state.pinned.filter { it.commit != commit.hex },
        )
        if (next == state) return
        persist(next)
        prune()
    }

    /** Empties the cache but keeps its directory. */
    @Synchronized
    fun removeAll() {
        if (objectsDirectory.exists() && !objectsDirectory.deleteRecursively()) throw IOException("cache not removed")
        if (stateFile.exists() && !stateFile.delete()) throw IOException("cache not removed")
        state = emptyState()
    }

    /**
     * Deletes every stored object not reachable from a retained snapshot. A snapshot
     * whose own tree turns out to be incomplete is released as well, so `retained`
     * always means "complete".
     */
    @Synchronized
    fun prune() {
        val keep = HashSet<GitObjectId>()
        fun isComplete(entry: Retained): Boolean {
            val commit = GitObjectId.fromHex(entry.commit) ?: return false
            val tree = GitObjectId.fromHex(entry.tree) ?: return false
            if (!contains(commit)) return false
            val reachable = reachableObjects(tree) ?: return false
            keep.add(commit)
            keep.addAll(reachable)
            return true
        }
        val next = state.copy(retained = state.retained.filter(::isComplete), pinned = state.pinned.filter(::isComplete))
        if (next != state) {
            try {
                persist(next)
            } catch (_: IOException) {
                // Kept in memory as it was; the next prune tries again.
            }
        }
        for (fanout in objectsDirectory.listFiles().orEmpty()) {
            for (file in fanout.listFiles().orEmpty()) {
                val id = GitObjectId.fromHex(fanout.name + file.name)
                if (id != null && id in keep) continue
                file.delete()
            }
        }
    }

    /** Every tree and blob reachable from `tree`, or null if any is missing. */
    @Synchronized
    fun reachableObjects(tree: GitObjectId): Set<GitObjectId>? {
        val seen = HashSet<GitObjectId>()
        val stack = ArrayList<GitObjectId>()
        stack.add(tree)
        while (stack.isNotEmpty()) {
            val next = stack.removeAt(stack.lastIndex)
            if (!seen.add(next)) continue
            val found = get(next) ?: return null
            if (found.type != GitObjectType.TREE) continue
            val entries = try {
                GitTree.parse(found.content)
            } catch (_: GitFormatException) {
                return null
            }
            for (entry in entries) {
                if (entry.isTree) {
                    stack.add(entry.id)
                } else if (entry.isRegularFile && seen.add(entry.id) && !contains(entry.id)) {
                    return null
                }
            }
        }
        return seen
    }

    // MARK: Files

    private fun emptyState() = State(SCHEMA_VERSION, scope, retained = emptyList(), pinned = emptyList())

    private fun file(id: GitObjectId): File {
        val hex = id.hex
        return File(File(objectsDirectory, hex.substring(0, 2)), hex.substring(2))
    }

    private fun readState(): State? {
        return try {
            val root = Json.parseToJsonElement(stateFile.readText(Charsets.UTF_8)) as? JsonObject ?: return null
            State(
                schemaVersion = (root["schemaVersion"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: return null,
                scope = string(root["scope"]) ?: return null,
                retained = snapshots(root["retained"]) ?: return null,
                pinned = snapshots(root["pinned"]) ?: return null,
            )
        } catch (_: IOException) {
            null
        } catch (_: IllegalArgumentException) {
            // Not JSON (`SerializationException` is one of these).
            null
        }
    }

    private fun string(element: JsonElement?): String? = (element as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun snapshots(element: JsonElement?): List<Retained>? {
        val array = element as? JsonArray ?: return null
        return array.map {
            val entry = it as? JsonObject ?: return null
            Retained(string(entry["commit"]) ?: return null, string(entry["tree"]) ?: return null)
        }
    }

    /** Sorted keys, as the Swift cache writes them. */
    private fun persist(newState: State) {
        createDirectories(directory)
        fun snapshots(entries: List<Retained>) = JsonArray(
            entries.map { JsonObject(linkedMapOf("commit" to JsonPrimitive(it.commit), "tree" to JsonPrimitive(it.tree))) },
        )
        val root = JsonObject(
            linkedMapOf(
                "pinned" to snapshots(newState.pinned),
                "retained" to snapshots(newState.retained),
                "schemaVersion" to JsonPrimitive(newState.schemaVersion),
                "scope" to JsonPrimitive(newState.scope),
            ),
        )
        writeAtomically(stateFile, root.toString().toByteArray(Charsets.UTF_8))
        state = newState
    }

    private fun writeAtomically(target: File, vararg parts: ByteArray) {
        // `Files.createTempFile` makes the file readable by its owner only.
        val temporary = Files.createTempFile(target.parentFile.toPath(), ".tmp-", null)
        try {
            Files.newOutputStream(temporary).use { out -> for (part in parts) out.write(part) }
            try {
                Files.move(temporary, target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temporary, target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            Files.deleteIfExists(temporary)
        }
    }

    private fun createDirectories(target: File) {
        if (target.isDirectory) return
        try {
            Files.createDirectories(target.toPath(), PosixFilePermissions.asFileAttribute(OWNER_ONLY))
        } catch (_: UnsupportedOperationException) {
            // A file system without POSIX modes.
            Files.createDirectories(target.toPath())
        }
    }

    companion object {
        const val SCHEMA_VERSION = 1
        const val MAXIMUM_RETAINED_COMMITS = 4

        /** No object this client accepts from a pack is larger; a bigger file is not one of ours. */
        private const val MAXIMUM_FILE_BYTES = 64L * 1024 * 1024 + 64

        private val OWNER_ONLY = PosixFilePermissions.fromString("rwx------")
    }
}
