package com.khm.snippets.core.git

import com.khm.snippets.core.git.testing.GitBinary
import com.khm.snippets.core.git.testing.GitFixture
import java.io.File
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Port of `GitPrimitivesTests` (Tests/Core/GitPrimitivesTests.swift); same test names. */
class GitPrimitivesTest {
    private fun utf8(text: String) = text.toByteArray(Charsets.UTF_8)

    @Test fun objectIDsMatchGit() {
        assertEquals("ce013625030ba8dba906f756967f9e9ca394464a", GitObjectId.hash(GitObjectType.BLOB, utf8("hello\n")).hex)
        assertEquals("4b825dc642cb6eb9a060e54bf8d69288fbee4904", GitObjectId.hash(GitObjectType.TREE, ByteArray(0)).hex)
        val id = assertNotNull(GitObjectId.fromHex("ce013625030ba8dba906f756967f9e9ca394464a"))
        assertEquals("ce013625030ba8dba906f756967f9e9ca394464a", id.hex)
        assertNull(GitObjectId.fromHex("CE013625030BA8DBA906F756967F9E9CA394464A"))
        assertNull(GitObjectId.fromHex("ce01"))
        assertTrue(GitObjectId.ZERO.isZero)
    }

    @Test fun treeSerializationUsesGitOrderAndMatchesGitMktree() {
        GitFixture().use { fixture ->
            val blob = GitObjectId.hash(GitObjectType.BLOB, utf8("x"))
            val subtree = GitObjectId.hash(GitObjectType.TREE, ByteArray(0))
            val entries = listOf(
                GitTreeEntry.tree("a", subtree), GitTreeEntry.blob("a.b", blob),
                GitTreeEntry.blob("a-b", blob), GitTreeEntry.blob("B", blob),
            )
            val content = GitTree.serialize(entries)
            val names = GitTree.parse(content).map { it.name.toString(Charsets.UTF_8) }
            // "a" sorts as "a/", after "a.b" and "a-b".
            assertEquals(listOf("B", "a-b", "a.b", "a"), names)

            val listing = """
                040000 tree ${subtree.hex}${'\t'}a
                100644 blob ${blob.hex}${'\t'}a.b
                100644 blob ${blob.hex}${'\t'}a-b
                100644 blob ${blob.hex}${'\t'}B
            """.trimIndent()
            val gitId = fixture.bareGit("mktree", "--missing", input = utf8(listing + "\n"))
            assertEquals(gitId, GitObjectId.hash(GitObjectType.TREE, content).hex)
        }
    }

    @Test fun commitParsingReadsTreeAndParents() {
        val tree = GitObjectId.hash(GitObjectType.TREE, ByteArray(0))
        val parent = GitObjectId.hash(GitObjectType.BLOB, utf8("p"))
        val data = GitCommit.serialize(tree, listOf(parent), epochSeconds = 1_700_000_000, message = "Sync 1 record")
        val commit = GitCommit.parse(data)
        assertEquals(tree, commit.tree)
        assertEquals(listOf(parent), commit.parents)
        val text = data.toString(Charsets.UTF_8)
        assertTrue(text.contains("author Snippets Sync <sync@snippets.invalid> 1700000000 +0000"))
    }

    @Test fun packRoundTripsUndeltifiedObjects() {
        val objects = listOf(
            GitObject(GitObjectType.BLOB, ByteArray(0)),
            GitObject(GitObjectType.BLOB, ByteArray(70_000) { 7 }),
            GitObject(
                GitObjectType.TREE,
                GitTree.serialize(listOf(GitTreeEntry.blob("x", GitObjectId.hash(GitObjectType.BLOB, ByteArray(0))))),
            ),
        )
        val parsed = GitPack.parse(GitPack.build(objects))
        assertEquals(3, parsed.size)
        for (obj in objects) assertEquals(obj, parsed[obj.id])
    }

    @Test fun packRejectsCorruption() {
        val pack = GitPack.build(listOf(GitObject(GitObjectType.BLOB, utf8("abc"))))
        pack[pack.size - 25] = (pack[pack.size - 25].toInt() xor 0xff).toByte()
        assertFailsWith<GitFormatException> { GitPack.parse(pack) }
        assertFailsWith<GitFormatException> { GitPack.parse(utf8("PACK")) }
    }

    /**
     * Real packs are deltified. Git's own `pack-objects` emits offset deltas with
     * `--delta-base-offset` and reference deltas without it.
     */
    @Test fun parsesDeltifiedPacksProducedByGit() {
        GitFixture().use { fixture ->
            val work = File(fixture.root, "work")
            fixture.git("init", "--quiet", work.path)
            var text = (0 until 4_000).joinToString("") { "line $it of a long, repetitive file\n" }
            for (revision in 0 until 12) {
                text = text.replace("line ${revision * 100} ", "edited $revision ")
                File(work, "file.txt").writeText(text)
                fixture.git("-C", work.path, "add", "-A")
                fixture.git("-C", work.path, "commit", "--quiet", "-m", "r$revision")
            }
            // Offset deltas, then reference deltas (pack-objects without --delta-base-offset).
            for (useOffsets in listOf(true, false)) {
                val ids = fixture.git("-C", work.path, "rev-list", "--objects", "--all")
                    .lines().joinToString("\n") { it.take(40) } + "\n"
                val pack = packObjects(fixture, work, ids, useOffsets)

                val objects = GitPack.parse(pack)
                val expected = ids.lines().filter { it.isNotEmpty() }.toSet()
                assertEquals(expected, objects.keys.map { it.hex }.toSet())
                val headId = assertNotNull(GitObjectId.fromHex(fixture.git("-C", work.path, "rev-parse", "HEAD:file.txt")))
                val blob = assertNotNull(objects[headId])
                assertEquals(text, blob.content.toString(Charsets.UTF_8))
                // A delta-compressed pack is far smaller than twelve copies of the file.
                assertTrue(pack.size < utf8(text).size * 3)
            }
        }
    }

    private fun packObjects(fixture: GitFixture, work: File, ids: String, useOffsets: Boolean): ByteArray {
        val command = listOf(
            GitBinary.path!!, "-C", work.path, "pack-objects", "--stdout", "--window=50", "--depth=50", "--no-reuse-delta",
        ) + (if (useOffsets) listOf("--delta-base-offset") else emptyList())
        val builder = ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.DISCARD)
        builder.environment().clear()
        builder.environment().putAll(GitBinary.isolatedEnvironment(fixture.root))
        val process = builder.start()
        val writer = thread { process.outputStream.use { it.write(utf8(ids)) } }
        val pack = process.inputStream.readBytes()
        writer.join()
        assertEquals(0, process.waitFor())
        return pack
    }

    @Test fun deltaApplicationValidatesEveryBound() {
        val base = utf8("hello world")
        fun delta(vararg bytes: Int) = ByteArray(bytes.size) { bytes[it].toByte() }
        // source 11, target 5, copy offset 6 size 5
        assertContentEquals(utf8("world"), GitDelta.apply(delta(11, 5, 0x91, 6, 5), base, maximumSize = 100))
        assertEquals(
            GitFormatException.invalidDelta(),
            assertFailsWith<GitFormatException> { GitDelta.apply(delta(12, 5, 0x91, 6, 5), base, maximumSize = 100) },
        )
        assertEquals(
            GitFormatException.invalidDelta(),
            assertFailsWith<GitFormatException> { GitDelta.apply(delta(11, 5, 0x91, 8, 5), base, maximumSize = 100) },
        )
        assertEquals(
            GitFormatException.invalidDelta(),
            assertFailsWith<GitFormatException> { GitDelta.apply(delta(11, 1, 0), base, maximumSize = 100) },
        )
        assertEquals(
            GitFormatException.limitExceeded("delta_target"),
            assertFailsWith<GitFormatException> { GitDelta.apply(delta(11, 50, 1, 65), base, maximumSize = 10) },
        )
    }

    @Test fun zlibInflateReportsExactConsumption() {
        val payload = ByteArray(10_000) { (it % 251).toByte() }
        val compressed = GitZlib.deflate(payload)
        val stream = compressed + byteArrayOf(1, 2, 3, 4)
        val inflated = GitZlib.inflate(stream, offset = 0, expectedSize = payload.size)
        assertContentEquals(payload, inflated.content)
        assertEquals(compressed.size, inflated.consumed)
        assertEquals(
            GitFormatException.compression(),
            assertFailsWith<GitFormatException> { GitZlib.inflate(stream, offset = 0, expectedSize = payload.size - 1) },
        )
    }

    @Test fun pktLineFramingRoundTrips() {
        val data = GitPktLine.line("hello") + GitPktLine.flush + utf8("0001")
        val reader = GitPktLine.Reader(data)
        assertEquals(GitPktLine.Packet.Data(utf8("hello\n")), reader.next())
        assertEquals(GitPktLine.Packet.Flush, reader.next())
        assertEquals(GitPktLine.Packet.Delimiter, reader.next())
        assertNull(reader.next())
        assertEquals(
            GitFormatException.invalidPktLine(),
            assertFailsWith<GitFormatException> { GitPktLine.Reader(utf8("zz12")).next() },
        )
        // `toInt(16)` accepts a sign; a hostile "-005" length must not trap.
        for (hostile in listOf("-005", "+005", " 005", "-0001234")) {
            assertEquals(
                GitFormatException.invalidPktLine(),
                assertFailsWith<GitFormatException>(hostile) { GitPktLine.Reader(utf8(hostile)).next() },
            )
        }
        assertEquals(
            GitFormatException.invalidPktLine(),
            assertFailsWith<GitFormatException> { GitPktLine.encode(ByteArray(GitPktLine.MAXIMUM_PAYLOAD + 1)) },
        )
    }

    @Test fun advertisementParsingHandlesEmptyAndPopulatedRepositories() {
        val zero = "0".repeat(40)
        val empty = GitPktLine.line("# service=git-receive-pack") + GitPktLine.flush +
            GitPktLine.encode(
                utf8("$zero capabilities^{}") + 0.toByte() +
                    utf8("report-status side-band-64k object-format=sha1 agent=git/2\n"),
            ) + GitPktLine.flush
        val parsedEmpty = GitWire.parseAdvertisement(empty, GitService.RECEIVE_PACK)
        assertTrue(parsedEmpty.refs.isEmpty())
        assertTrue(parsedEmpty.supports("report-status"))
        assertEquals("git/2", parsedEmpty.capabilities["agent"])

        val id = "ce013625030ba8dba906f756967f9e9ca394464a"
        val populated = GitPktLine.line("# service=git-upload-pack") + GitPktLine.flush +
            GitPktLine.encode(utf8("$id HEAD") + 0.toByte() + utf8("shallow side-band-64k symref=HEAD:refs/heads/main\n")) +
            GitPktLine.line("$id refs/heads/main") +
            GitPktLine.line("$id refs/tags/v1^{}") +
            GitPktLine.flush
        val parsed = GitWire.parseAdvertisement(populated, GitService.UPLOAD_PACK)
        assertEquals(id, parsed.refs["refs/heads/main"]?.hex)
        assertNull(parsed.refs["refs/tags/v1^{}"])
        assertFailsWith<GitRemoteFailure> { GitWire.parseAdvertisement(populated, GitService.RECEIVE_PACK) }

        val sha256 = GitPktLine.line("# service=git-upload-pack") + GitPktLine.flush +
            GitPktLine.encode(utf8("$zero capabilities^{}") + 0.toByte() + utf8("object-format=sha256\n")) +
            GitPktLine.flush
        assertEquals(
            GitRemoteFailure.UnsupportedServer("object_format"),
            assertFailsWith<GitRemoteFailure> { GitWire.parseAdvertisement(sha256, GitService.UPLOAD_PACK) },
        )
    }

    @Test fun zeroPaddedTreeModeIsStillATree() {
        val entry = GitTreeEntry(utf8("040000"), utf8("records"), GitObjectId.hash(GitObjectType.TREE, ByteArray(0)))
        assertTrue(entry.isTree)
        assertFalse(GitTreeEntry.blob("x", GitObjectId.ZERO).isTree)
    }

    @Test fun remoteNeverPrintsItsToken() {
        val remote = GitRemote.https("https://github.com/me/library", "main", "me", "secret-token-value")
        // Swift checks `String(describing:)`, `String(reflecting:)`, `dump` and
        // interpolation; here every way a value turns into text goes through `toString`.
        val texts = listOf(
            remote.toString(), "$remote", listOf(remote).toString(), mapOf("remote" to remote).toString(),
            remote.location.toString(), remote.url.toString(), IllegalStateException("failed for $remote").toString(),
        )
        for (text in texts) assertFalse(text.contains("secret-token-value"), text)
    }

    @Test fun remoteValidationRejectsUnsafeConfiguration() {
        val https = "https://GitHub.com/me/library/"
        val remote = GitRemote.https(https, "main", "me", "token")
        assertEquals("https://github.com/me/library", remote.url.toString())
        val dotGit = GitRemote.https("https://github.com/me/library.git", "main", "x", "y")
        assertEquals(remote.canonicalLocation, dotGit.canonicalLocation)

        for (raw in listOf(
            "http://github.com/me/r", "https://me:pw@github.com/me/r",
            "https://github.com/me/r?x=1", "https://github.com", "ssh://git@github.com/me/r",
        )) {
            val failure = assertFailsWith<GitRemoteConfigurationException>(raw) { GitRemote.https(raw, "main", "u", "p") }
            assertEquals(GitRemote.Failure.INVALID_URL, failure.failure, raw)
        }
        for (branch in listOf("", "-x", "a..b", "a/", ".hidden", "a/.b", "x.lock", "has space", "HEAD")) {
            assertFalse(GitRemote.isValidBranch(branch), branch)
        }
        assertTrue(GitRemote.isValidBranch("snippets/sync-v1"))
        assertEquals(
            GitRemote.Failure.INVALID_CREDENTIAL,
            assertFailsWith<GitRemoteConfigurationException> { GitRemote.https(https, "main", "a:b", "p") }.failure,
        )
        assertEquals(
            GitRemote.Failure.INVALID_CREDENTIAL,
            assertFailsWith<GitRemoteConfigurationException> { GitRemote.https(https, "main", "u", "line\nbreak") }.failure,
        )
        assertEquals(
            GitRemote.Failure.INVALID_URL,
            assertFailsWith<GitRemoteConfigurationException> {
                GitRemote.https("http://example.com/r", "main", "u", "p", allowsInsecureLoopback = true)
            }.failure,
        )
    }
}
