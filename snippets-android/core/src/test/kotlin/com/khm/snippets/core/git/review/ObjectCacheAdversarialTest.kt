package com.khm.snippets.core.git.review

import com.khm.snippets.core.git.GitObject
import com.khm.snippets.core.git.GitObjectCache
import com.khm.snippets.core.git.GitObjectId
import com.khm.snippets.core.git.GitObjectType
import com.khm.snippets.core.git.GitTree
import com.khm.snippets.core.git.GitTreeEntry
import com.khm.snippets.core.git.testing.GitTestObjects
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CyclicBarrier
import kotlin.concurrent.thread
import kotlin.random.Random
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Review: `GitObjectCache` under concurrent use and with a damaged directory. The
 * cache is disposable, so the only acceptable outcomes are "a miss" and "the right
 * bytes".
 *
 * All of these pass.
 */
class ObjectCacheAdversarialTest {
    private val root: File = Files.createTempDirectory("git-cache-review-").toFile()
    private val directory = File(root, "cache")
    private val scope = "cd".repeat(32)

    @AfterTest fun cleanUp() {
        root.deleteRecursively()
    }

    private fun snapshot(seed: Int, parent: GitObjectId? = null) = GitTestObjects.snapshot(
        (0 until 6).associate { "records/${"%02x".format(it)}/file-$it.json" to "content $seed/$it".toByteArray() } +
            ("shared.txt" to "the same in every snapshot".toByteArray()),
        parent,
    )

    private fun objectFile(id: GitObjectId) = File(directory, "objects/${id.hex.take(2)}/${id.hex.drop(2)}")

    /**
     * Readers, writers, retainers and pruners on one instance. Whatever the
     * interleaving, a read returns the right object or nothing, nothing throws, and
     * every snapshot the cache still lists afterwards is complete.
     */
    @Test fun concurrentUseNeverReturnsWrongBytesOrThrows() {
        val cache = GitObjectCache(directory, scope)
        val snapshots = (0 until 12).map { snapshot(it) }
        val failures = ConcurrentLinkedQueue<Throwable>()
        val workers = 8
        val barrier = CyclicBarrier(workers)
        val threads = (0 until workers).map { worker ->
            thread(name = "cache-worker-$worker") {
                val random = Random(worker)
                try {
                    barrier.await()
                    repeat(300) {
                        val chosen = snapshots[random.nextInt(snapshots.size)]
                        when (random.nextInt(6)) {
                            0, 1 -> {
                                for (obj in chosen.objects) cache.store(obj, obj.id)
                                cache.retain(chosen.id, chosen.tree)
                            }
                            2 -> for (obj in chosen.objects) {
                                val found = cache.get(obj.id)
                                if (found != null) assertEquals(obj, found)
                            }
                            3 -> cache.pin(listOf(chosen.id to chosen.tree))
                            4 -> cache.release(chosen.id)
                            else -> {
                                cache.prune()
                                cache.snapshotCommits
                                cache.reachableObjects(chosen.tree)
                            }
                        }
                    }
                } catch (error: Throwable) {
                    failures.add(error)
                }
            }
        }
        threads.forEach { it.join(120_000) }
        assertTrue(failures.isEmpty(), failures.joinToString { it.stackTraceToString().take(600) })
        cache.prune()
        for (commit in cache.snapshotCommits) {
            val tree = assertNotNull(cache.retainedTree(commit))
            assertNotNull(cache.get(commit), "a listed snapshot has its commit")
            val reachable = assertNotNull(cache.reachableObjects(tree), "a listed snapshot is complete")
            for (id in reachable) assertNotNull(cache.get(id))
        }
        // Reopening reads the state the last writer left, whole.
        assertEquals(cache.snapshotCommits, GitObjectCache(directory, scope).snapshotCommits)
        // No temporary file survives.
        val stray = directory.walkTopDown().filter { it.isFile && it.name.startsWith(".tmp-") }.toList()
        assertTrue(stray.isEmpty(), stray.toString())
    }

    /** Whatever is found where an object should be, it is a miss, never an exception. */
    @Test fun aDamagedDirectoryIsOnlyEverAMiss() {
        val cache = GitObjectCache(directory, scope)
        val blob = GitObject(GitObjectType.BLOB, "payload".toByteArray())
        val file = objectFile(blob.id)
        file.parentFile.mkdirs()

        val damaged = listOf(
            ByteArray(0), "blob 7".toByteArray(), "blob 7\u0000".toByteArray(), "blob 8\u0000payload".toByteArray(),
            "blob -7\u0000payload".toByteArray(), "blob 99999999999999999999\u0000payload".toByteArray(),
            "blob  7\u0000payload!".toByteArray(), "tree 7\u0000payload".toByteArray(), "BLOB 7\u0000payload".toByteArray(),
            "blob 7 extra\u0000payload".toByteArray(), "\u0000blob 7\u0000payload".toByteArray(), "blob 0x7\u0000payload".toByteArray(),
            "blob 7\u0000payloaD".toByteArray(), ByteArray(4096) { 0xff.toByte() },
        )
        for (bytes in damaged) {
            file.writeBytes(bytes)
            assertNull(cache.get(blob.id), bytes.toString(Charsets.ISO_8859_1))
            // The next store repairs it.
            cache.store(blob, blob.id)
            assertEquals(blob, cache.get(blob.id))
        }
        // A directory where the object file should be.
        file.delete()
        file.mkdirs()
        assertNull(cache.get(blob.id))
        file.deleteRecursively()
        // A file where a fan-out directory should be, and strangers among the objects.
        File(directory, "objects/zz").writeText("not a directory")
        File(directory, "objects/ab").mkdirs()
        File(directory, "objects/ab/UPPERCASE").writeText("x")
        File(directory, "objects/ab/nested/deeper").mkdirs()
        File(directory, "objects/ab/nested/deeper/file").writeText("x")
        cache.prune()
        assertNull(cache.get(blob.id))

        // A tree whose bytes are not a tree, and one that names itself (impossible by
        // hash, so only reachable through a damaged file): neither is "complete".
        val notATree = GitObject(GitObjectType.TREE, "garbage".toByteArray())
        cache.store(notATree, notATree.id)
        assertNull(cache.reachableObjects(notATree.id))
        val missingChild = GitObject(GitObjectType.TREE, GitTree.serialize(listOf(GitTreeEntry.tree("sub", blob.id), GitTreeEntry.blob("f", blob.id))))
        cache.store(missingChild, missingChild.id)
        assertNull(cache.reachableObjects(missingChild.id))
    }

    /** A state file from anywhere is either this cache's own or nothing. */
    @Test fun aHostileStateFileEmptiesTheCacheAndNothingElse() {
        val first = snapshot(1)
        GitObjectCache(directory, scope).apply {
            for (obj in first.objects) store(obj, obj.id)
            retain(first.id, first.tree)
        }
        val state = File(directory, "state.json")
        val good = state.readText()
        val hostile = listOf(
            "", "null", "[]", "{", "\u0000", "{\"schemaVersion\":1}", good.replace("\"schemaVersion\":1", "\"schemaVersion\":\"1\""),
            good.replace("\"schemaVersion\":1", "\"schemaVersion\":2"),
            good.replace("\"retained\":[", "\"retained\":[7,"), good.replace("\"retained\":[", "\"retained\":[{\"commit\":1,\"tree\":2},"),
            good.replace(scope, scope.uppercase()), "[".repeat(100_000), "{\"a\":".repeat(50_000),
        )
        for ((index, text) in hostile.withIndex()) {
            state.writeText(text)
            val reopened = GitObjectCache(directory, scope)
            assertTrue(reopened.snapshotCommits.isEmpty(), "state $index")
            assertNull(reopened.get(first.id), "state $index")
            // Usable again at once.
            for (obj in first.objects) reopened.store(obj, obj.id)
            reopened.retain(first.id, first.tree)
            assertEquals(listOf(first.id), GitObjectCache(directory, scope).snapshotCommits)
        }
        // Well-formed state naming ids that are not ids is kept out of every answer.
        state.writeText(good.replace(first.id.hex, "../../../../etc/passwd").replace(first.tree.hex, "Z".repeat(40)))
        val odd = GitObjectCache(directory, scope)
        assertTrue(odd.snapshotCommits.isEmpty())
        odd.prune()
        assertTrue(odd.retained.isEmpty())
    }
}
