package com.khm.snippets.core.git

import com.khm.snippets.core.git.testing.GitTestObjects
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Assume

/**
 * `GitObjectCache` on its own. (In Swift the cache is covered through
 * `GitSyncTransportTests`: cache loss, a corrupt cache, pinned bases.)
 */
class GitObjectCacheTest {
    private val root: File = Files.createTempDirectory("git-cache-").toFile()
    private val directory = File(root, "nested/cache")
    private val scope = "ab".repeat(32)

    @AfterTest fun cleanUp() {
        root.deleteRecursively()
    }

    private fun cache(scope: String = this.scope) = GitObjectCache(directory, scope)

    private fun snapshot(vararg files: Pair<String, String>, parent: GitObjectId? = null) =
        GitTestObjects.snapshot(files.associate { it.first to it.second.toByteArray() }, parent)

    /** Stores a snapshot children first, as the transport's install does. */
    private fun GitObjectCache.install(snapshot: GitTestObjects.Snapshot) {
        for (obj in snapshot.objects) store(obj, obj.id)
        retain(snapshot.id, snapshot.tree)
    }

    private fun objectFile(id: GitObjectId) = File(directory, "objects/${id.hex.take(2)}/${id.hex.drop(2)}")

    private fun storedIds(): Set<String> =
        File(directory, "objects").listFiles().orEmpty().flatMap { fanout -> fanout.listFiles().orEmpty().map { fanout.name + it.name } }.toSet()

    @Test fun objectsAreStoredAsTheBytesGitHashesAndReadBackVerified() {
        val cache = cache()
        val blob = GitObject(GitObjectType.BLOB, "hello\n".toByteArray())
        assertNull(cache.get(blob.id))
        assertFalse(cache.contains(blob.id))
        cache.store(blob, blob.id)
        assertTrue(cache.contains(blob.id))
        assertEquals(blob, cache.get(blob.id))
        assertEquals("ce/013625030ba8dba906f756967f9e9ca394464a", objectFile(blob.id).relativeTo(File(directory, "objects")).path)
        assertContentEquals("blob 6\u0000hello\n".toByteArray(), objectFile(blob.id).readBytes())
        // Every object type, and an empty object.
        for (type in GitObjectType.entries) {
            val obj = GitObject(type, if (type == GitObjectType.TREE) ByteArray(0) else "x".toByteArray())
            cache.store(obj, obj.id)
            assertEquals(obj, cache.get(obj.id))
        }
        // No temporary file is left next to the objects.
        assertTrue(storedIds().all { it.length == 40 })
    }

    @Test fun aCorruptObjectIsAMissAndIsReplacedByTheNextStore() {
        val cache = cache()
        val blob = GitObject(GitObjectType.BLOB, "some record ciphertext".toByteArray())
        cache.store(blob, blob.id)
        val file = objectFile(blob.id)

        // A flipped content byte: the hash no longer matches, the file is removed.
        file.writeBytes(file.readBytes().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() })
        assertNull(cache.get(blob.id))
        assertFalse(file.exists())
        cache.store(blob, blob.id)
        assertEquals(blob, cache.get(blob.id))

        // Truncated, a wrong size, an unknown type, no header at all.
        for (damaged in listOf(
            file.readBytes().copyOf(file.length().toInt() - 3),
            "blob 5\u0000some record ciphertext".toByteArray(),
            "note 22\u0000some record ciphertext".toByteArray(),
            "blob22\u0000some record ciphertext".toByteArray(),
            "no header".toByteArray(),
            ByteArray(0),
        )) {
            file.writeBytes(damaged)
            assertNull(cache.get(blob.id))
            // `contains` only says a file is there; `store` checks before trusting it.
            cache.store(blob, blob.id)
            assertEquals(blob, cache.get(blob.id))
        }
        // The right bytes under the wrong name are not that object either.
        val other = GitObject(GitObjectType.BLOB, "other".toByteArray())
        objectFile(other.id).apply { parentFile.mkdirs() }.writeBytes(file.readBytes())
        assertNull(cache.get(other.id))
    }

    @Test fun stateSurvivesReopeningAndIsWrittenWithSortedKeys() {
        val first = snapshot("a" to "1")
        val second = snapshot("a" to "2", parent = first.id)
        cache().apply {
            install(first)
            install(second)
            pin(listOf(second.id to second.tree, first.id to first.tree))
        }
        assertEquals(
            """{"pinned":[{"commit":"${second.id.hex}","tree":"${second.tree.hex}"},{"commit":"${first.id.hex}","tree":"${first.tree.hex}"}],""" +
                """"retained":[{"commit":"${second.id.hex}","tree":"${second.tree.hex}"},{"commit":"${first.id.hex}","tree":"${first.tree.hex}"}],""" +
                """"schemaVersion":1,"scope":"$scope"}""",
            File(directory, "state.json").readText(),
        )
        val reopened = cache()
        assertEquals(listOf(second.id, first.id), reopened.snapshotCommits)
        assertEquals(second.tree, reopened.retainedTree(second.id))
        assertEquals(first.commit, reopened.get(first.id))
        // Only the two documented entries exist: nothing else is ever written here.
        assertEquals(setOf("objects", "state.json"), directory.list().orEmpty().toSet())
    }

    @Test fun aCacheOfAnotherScopeOrSchemaIsDiscardedNotInterpreted() {
        val snapshot = snapshot("a" to "1")
        cache().install(snapshot)
        assertTrue(storedIds().isNotEmpty())

        val other = cache(scope = "cd".repeat(32))
        assertTrue(other.snapshotCommits.isEmpty())
        assertNull(other.get(snapshot.id))
        assertTrue(storedIds().isEmpty())
        assertTrue(directory.isDirectory)

        for (state in listOf(
            """{"pinned":[],"retained":[],"schemaVersion":2,"scope":"$scope"}""",
            """{"pinned":[],"retained":[],"scope":"$scope"}""",
            """{"pinned":[],"retained":[{"commit":7}],"schemaVersion":1,"scope":"$scope"}""",
            """{"pinned":[],"retained":"all","schemaVersion":1,"scope":"$scope"}""",
            """{"retained":[],"schemaVersion":1,"scope":"$scope"}""",
            """{"pinned":[],"retained":[],"schemaVersion":"1","scope":"$scope"}""",
            "[]", "not json", "",
        )) {
            cache().install(snapshot)
            File(directory, "state.json").writeText(state)
            val reopened = cache()
            assertTrue(reopened.snapshotCommits.isEmpty(), state)
            assertTrue(storedIds().isEmpty(), state)
        }
        // Unknown keys are tolerated, as Swift's decoder tolerates them.
        cache().install(snapshot)
        val stateFile = File(directory, "state.json")
        stateFile.writeText(stateFile.readText().replace("{\"pinned\"", "{\"future\":true,\"pinned\""))
        assertEquals(listOf(snapshot.id), cache().snapshotCommits)
    }

    @Test fun theFourMostRecentSnapshotsAreRetainedAndTheRestPruned() {
        val cache = cache()
        val snapshots = ArrayList<GitTestObjects.Snapshot>()
        for (index in 0 until 6) {
            snapshots.add(snapshot("shared" to "same", "file" to "version $index", parent = snapshots.lastOrNull()?.id))
            cache.install(snapshots.last())
        }
        assertEquals(snapshots.takeLast(4).reversed().map { it.id }, cache.snapshotCommits)
        assertEquals(4, cache.retained.size)
        val kept = snapshots.takeLast(4).flatMap { it.objects }.map { it.id.hex }.toSet()
        assertEquals(kept, storedIds())
        // The blob every snapshot shares is still there; the first two versions are gone.
        assertNotNull(cache.get(GitObjectId.hash(GitObjectType.BLOB, "same".toByteArray())))
        assertNull(cache.get(snapshots[0].id))
        assertNull(cache.get(GitObjectId.hash(GitObjectType.BLOB, "version 1".toByteArray())))
        assertNull(cache.retainedTree(snapshots[0].id))
        // Retaining again moves a snapshot to the front without duplicating it.
        cache.retain(snapshots[2].id, snapshots[2].tree)
        assertEquals(listOf(2, 5, 4, 3).map { snapshots[it].id }, cache.snapshotCommits)
    }

    @Test fun pinnedSnapshotsSurviveEvictionUntilTheNextPin() {
        val cache = cache()
        val base = snapshot("file" to "base")
        cache.install(base)
        cache.pin(listOf(base.id to base.tree, base.id to base.tree))
        var parent = base.id
        repeat(5) { index ->
            val next = snapshot("file" to "submit $index", parent = parent)
            cache.install(next)
            parent = next.id
        }
        // Evicted from `retained`, still held and still offered as a have.
        assertFalse(cache.retained.any { it.commit == base.id.hex })
        assertEquals(base.tree, cache.retainedTree(base.id))
        assertEquals(base.commit, cache.get(base.id))
        assertEquals(base.id, cache.snapshotCommits.last())
        assertEquals(5, cache.snapshotCommits.size)
        assertEquals(base.objects.map { it.id }.toSet(), setOf(base.id) + assertNotNull(cache.reachableObjects(base.tree)))

        // A new pin replaces the old one wholesale; the unshared objects go.
        val head = snapshot("file" to "head", parent = parent)
        cache.install(head)
        cache.pin(listOf(head.id to head.tree))
        assertNull(cache.retainedTree(base.id))
        assertNull(cache.get(base.id))
        assertNull(cache.get(GitObjectId.hash(GitObjectType.BLOB, "base".toByteArray())))
    }

    @Test fun anIncompleteSnapshotIsReleasedByPrune() {
        val cache = cache()
        val whole = snapshot("dir/a" to "1", "b" to "2")
        val damaged = snapshot("dir/a" to "1", "c" to "3", parent = whole.id)
        cache.install(whole)
        cache.install(damaged)
        assertEquals(whole.objects.map { it.id }.toSet() - whole.id, cache.reachableObjects(whole.tree))

        objectFile(GitObjectId.hash(GitObjectType.BLOB, "3".toByteArray())).delete()
        assertNull(cache.reachableObjects(damaged.tree))
        cache.prune()
        assertEquals(listOf(whole.id), cache.snapshotCommits)
        assertEquals(whole.objects.map { it.id.hex }.toSet(), storedIds())
        // Stray files in the object store are not ours to keep.
        File(directory, "objects/zz").mkdirs()
        File(directory, "objects/zz/junk").writeText("x")
        cache.prune()
        assertFalse(File(directory, "objects/zz/junk").exists())
        // A reopened cache agrees.
        assertEquals(listOf(whole.id), cache().snapshotCommits)
    }

    @Test fun releaseAndRemoveAllForgetSnapshotsButKeepTheDirectory() {
        val cache = cache()
        val first = snapshot("a" to "1")
        val second = snapshot("a" to "2", parent = first.id)
        cache.install(first)
        cache.install(second)
        cache.pin(listOf(first.id to first.tree))
        cache.release(first.id)
        assertEquals(listOf(second.id), cache.snapshotCommits)
        assertNull(cache.get(first.id))
        cache.release(first.id)

        cache.removeAll()
        assertTrue(cache.snapshotCommits.isEmpty())
        assertNull(cache.get(second.id))
        assertTrue(directory.isDirectory)
        assertFalse(File(directory, "objects").exists())
        assertFalse(File(directory, "state.json").exists())
        // And it is usable again at once.
        cache.install(second)
        assertEquals(listOf(second.id), cache().snapshotCommits)
    }

    @Test fun directoriesArePrivateToTheOwner() {
        val cache = cache()
        val view = Files.getFileAttributeView(directory.toPath(), java.nio.file.attribute.PosixFileAttributeView::class.java)
        Assume.assumeTrue("the file system has no POSIX modes", view != null)
        val blob = GitObject(GitObjectType.BLOB, "x".toByteArray())
        cache.store(blob, blob.id)
        val ownerOnly = setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE, PosixFilePermission.OWNER_EXECUTE)
        for (created in listOf(directory, directory.parentFile, File(directory, "objects"), objectFile(blob.id).parentFile)) {
            assertEquals(ownerOnly, Files.getPosixFilePermissions(created.toPath()), created.path)
        }
        // Files are not readable by anyone else either.
        val file = Files.getPosixFilePermissions(objectFile(blob.id).toPath())
        assertTrue(file.none { it.name.startsWith("GROUP_") || it.name.startsWith("OTHERS_") }, file.toString())
    }
}
