package com.khm.snippets.core.git

import com.khm.snippets.core.git.testing.FakeSshConnector
import com.khm.snippets.core.git.testing.GitCommandFailed
import com.khm.snippets.core.git.testing.GitFixture
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * `GitSshClient` and the exchange framing, first against a scripted service, then
 * against the real `git-upload-pack`/`git-receive-pack` run as local processes (the
 * same byte stream an SSH exec channel carries).
 *
 * Maps the connector-contract tests of `GitSSHTransportTests`
 * (Tests/Core/GitSSHTests.swift) that do not need the sync transport.
 */
class GitSshClientTest {
    private fun utf8(text: String) = text.toByteArray(Charsets.UTF_8)

    private val location = GitSshLocation(user = "git", host = "h", port = null, path = "r.git", scpStyle = true)
    private val remote = GitRemote.ssh(location, "main")
    private val head = GitObjectId.hash(GitObjectType.BLOB, utf8("head"))
    private val other = GitObjectId.hash(GitObjectType.BLOB, utf8("other"))

    private fun advertisement(head: GitObjectId?, vararg capabilities: String): ByteArray {
        val caps = capabilities.joinToString(" ") + "\n"
        val first = if (head == null) "${"0".repeat(40)} capabilities^{}" else "${head.hex} refs/heads/main"
        return GitPktLine.encode(utf8(first) + 0.toByte() + utf8(caps)) + GitPktLine.flush
    }

    private fun client(connector: GitSshConnector, idleTimeoutMillis: Long = 30_000) =
        GitSshClient(remote, location, connector, idleTimeoutMillis = idleTimeoutMillis)

    private fun <T> blocking(block: suspend () -> T): T = runBlocking { withTimeout(60_000) { block() } }

    // MARK: Scripted service

    @Test fun discoverAnswersTheAdvertisementWithALoneFlush() {
        val requests = CopyOnWriteArrayList<ByteArray>()
        val connector = FakeSshConnector { server ->
            server.send(advertisement(head, "side-band-64k", "shallow", "agent=git/2"))
            requests.add(server.readRequest())
            0
        }
        val discovered = blocking { client(connector).discover(GitService.UPLOAD_PACK) }
        assertEquals(mapOf("refs/heads/main" to head), discovered.refs)
        assertTrue(discovered.supports("shallow"))
        assertEquals(listOf("git-upload-pack 'r.git'"), connector.commands)
        assertContentEquals(GitPktLine.flush, requests.single())
        assertEquals(1, connector.channelsClosed)
    }

    /** Swift: `aStalePushIsRefusedWithoutUploadingThePack`. */
    @Test fun aStalePushIsRefusedWithoutUploadingThePack() {
        val requests = CopyOnWriteArrayList<ByteArray>()
        val connector = FakeSshConnector { server ->
            // The branch moved since this device's discovery: the live head is `other`.
            server.send(advertisement(other, "report-status", "side-band-64k"))
            requests.add(server.readRequest())
            0
        }
        val stale = GitRefAdvertisement(mapOf("refs/heads/main" to head), mapOf("report-status" to null))
        val pack = ByteArray(1024 * 1024) { 1 }
        val result = blocking { client(connector).push(old = head, new = other, pack = pack, advertisement = stale) }
        assertEquals(GitPushResult.REJECTED, result)
        assertContentEquals(GitPktLine.flush, requests.single(), "only a flush may be sent, never the pack")
        assertEquals(listOf("git-receive-pack 'r.git'"), connector.commands)
    }

    @Test fun aPushUsesTheLiveAdvertisementNotTheOneGiven() {
        val requests = CopyOnWriteArrayList<ByteArray>()
        val connector = FakeSshConnector { server ->
            server.send(advertisement(head, "report-status", "quiet"))
            requests.add(server.readRequest())
            server.send(GitPktLine.line("unpack ok") + GitPktLine.line("ok refs/heads/main") + GitPktLine.flush)
            0
        }
        // The caller's copy claims side-band; the live service does not offer it.
        val given = GitRefAdvertisement(mapOf("refs/heads/main" to head), mapOf("report-status" to null, "side-band-64k" to null))
        val pack = utf8("PACK-bytes")
        assertEquals(GitPushResult.UPDATED, blocking { client(connector).push(head, other, pack, given) })
        val expected = GitPktLine.encode(
            utf8("${head.hex} ${other.hex} refs/heads/main") + 0.toByte() + utf8("report-status agent=snippets/1 quiet\n"),
        ) + GitPktLine.flush + pack
        assertContentEquals(expected, requests.single())
    }

    @Test fun aFetchOfAMovedRefSendsOnlyAFlush() {
        val requests = CopyOnWriteArrayList<ByteArray>()
        val connector = FakeSshConnector { server ->
            server.send(advertisement(other, "side-band-64k"))
            requests.add(server.readRequest())
            0
        }
        val given = GitRefAdvertisement(mapOf("refs/heads/main" to head), emptyMap())
        val failure = assertFailsWith<GitRemoteFailure> { blocking { client(connector).fetchPack(head, emptyList(), given) } }
        assertEquals(GitRemoteFailure.Unreachable("ref_moved"), failure)
        assertContentEquals(GitPktLine.flush, requests.single())
    }

    @Test fun aFetchAsksWithTheLiveCapabilitiesAndReturnsThePack() {
        val requests = CopyOnWriteArrayList<ByteArray>()
        val connector = FakeSshConnector { server ->
            server.send(advertisement(head, "side-band-64k", "ofs-delta", "shallow"))
            requests.add(server.readRequest())
            server.send(
                GitPktLine.line("shallow ${head.hex}") + GitPktLine.flush + GitPktLine.line("NAK") +
                    GitPktLine.encode(byteArrayOf(1) + utf8("PACK")) + GitPktLine.flush,
            )
            0
        }
        val pack = blocking { client(connector).fetchPack(head, emptyList(), GitRefAdvertisement(emptyMap(), emptyMap())) }
        assertContentEquals(utf8("PACK"), pack)
        val request = requests.single().toString(Charsets.UTF_8)
        assertTrue(request.contains("want ${head.hex} ofs-delta agent=snippets/1 side-band-64k shallow\n"), request)
        assertTrue(request.contains("deepen 1"))
    }

    /**
     * The service may answer while the request is still being written. A client that
     * wrote the pack on its reader thread would deadlock here: both pipes are full.
     */
    @Test fun writingALargeRequestNeverBlocksReading() {
        val received = CopyOnWriteArrayList<Int>()
        val chatter = ByteArray(1024 * 1024) { 2 }
        val connector = FakeSshConnector(pipeCapacity = 16 * 1024) { server ->
            server.send(advertisement(head, "report-status", "side-band-64k"))
            // Progress on band 2 before a single request byte is read.
            var offset = 0
            while (offset < chatter.size) {
                val count = minOf(60_000, chatter.size - offset)
                server.send(GitPktLine.encode(byteArrayOf(2) + chatter.copyOfRange(offset, offset + count)))
                offset += count
            }
            received.add(server.readRequest().size)
            val report = GitPktLine.line("unpack ok") + GitPktLine.line("ok refs/heads/main") + GitPktLine.flush
            server.send(GitPktLine.encode(byteArrayOf(1) + report) + GitPktLine.flush)
            0
        }
        val pack = ByteArray(4 * 1024 * 1024) { 3 }
        val given = GitRefAdvertisement(mapOf("refs/heads/main" to head), emptyMap())
        assertEquals(GitPushResult.UPDATED, blocking { client(connector).push(head, other, pack, given) })
        assertTrue(received.single() > pack.size)
    }

    /**
     * Swift: `aServiceThatEndsEarlyNeverCrashesTheWriter`. The service ends right after
     * its advertisement; the request writer must cope with its input disappearing.
     */
    @Test fun aServiceThatEndsEarlyNeverCrashesTheWriter() {
        val connector = FakeSshConnector(pipeCapacity = 4096) { server ->
            server.send("0000")
            0
        }
        val pack = ByteArray(4 * 1024 * 1024)
        repeat(40) {
            val exchange = blocking {
                GitSshExchangeRunner.exchange(connector, "git-receive-pack 'r.git'", location, maximumBytes = 1L shl 20) {
                    GitWireBody.of(pack)
                }
            }
            assertContentEquals(utf8("0000"), exchange.advertisement)
            assertEquals(0, exchange.response.size)
        }
        assertEquals(40, connector.channelsClosed)
    }

    /** Swift: `cancellationIsReportedAsCancellation`. */
    @Test fun cancellationIsReportedAsCancellation() {
        val connector = FakeSshConnector { server ->
            Thread.sleep(30_000)
            0
        }
        runBlocking {
            val task = async(Dispatchers.Default) { client(connector).discover(GitService.UPLOAD_PACK) }
            delay(300)
            val started = System.nanoTime()
            task.cancel()
            assertFailsWith<CancellationException> { task.await() }
            task.join()
            assertTrue(System.nanoTime() - started < 5_000_000_000)
        }
        assertEquals(1, connector.channelsClosed)
    }

    /** Swift: `aStalledExchangeTimesOutButAMovingOneDoesNot`. */
    @Test fun aStalledExchangeTimesOutButAMovingOneDoesNot() {
        val stalled = FakeSshConnector { server ->
            Thread.sleep(30_000)
            0
        }
        val started = System.nanoTime()
        val failure = assertFailsWith<GitRemoteFailure> { blocking { client(stalled, idleTimeoutMillis = 400).discover(GitService.UPLOAD_PACK) } }
        assertEquals(GitRemoteFailure.Unreachable("ssh_timeout"), failure)
        assertTrue(System.nanoTime() - started < 5_000_000_000)

        // Slower in total than the timeout, but never idle for that long.
        val moving = FakeSshConnector { server ->
            repeat(12) {
                Thread.sleep(100)
                server.send(GitPktLine.line("${head.hex} refs/heads/b$it"))
            }
            server.send("0000")
            server.readRequest()
            0
        }
        assertEquals(12, blocking { client(moving, idleTimeoutMillis = 400).discover(GitService.UPLOAD_PACK) }.refs.size)
    }

    /** Swift: `sshFailuresSurfaceAsActionableCodes`, at the level of the wire client. */
    @Test fun serviceFailuresSurfaceAsClosedCodes() {
        fun failing(status: Int?, stderr: String, advertise: Boolean = false) = FakeSshConnector { server ->
            if (advertise) {
                server.send(advertisement(head))
                server.readRequest()
            }
            server.errors.write(utf8(stderr))
            status
        }
        fun failure(status: Int?, stderr: String, advertise: Boolean = false): GitRemoteFailure =
            assertFailsWith<GitRemoteFailure> { blocking { client(failing(status, stderr, advertise)).discover(GitService.UPLOAD_PACK) } }

        assertEquals(GitRemoteFailure.RepositoryNotFound(), failure(128, "ERROR: Repository not found."))
        assertEquals(GitRemoteFailure.SshPermissionDenied(), failure(128, "ERROR: Permission to me/lib.git denied to deploy key"))
        assertEquals(GitRemoteFailure.UnsupportedServer("ssh_no_git"), failure(127, "sh: git-upload-pack: command not found"))
        assertEquals(GitRemoteFailure.Unreachable("ssh_remote_temporary"), failure(1, "Please try again later."))
        assertEquals(GitRemoteFailure.Unreachable("ssh_remote_failed"), failure(1, "something else"))
        // A complete advertisement is not success when the service then fails.
        assertEquals(GitRemoteFailure.Unreachable("ssh_remote_failed"), failure(1, "", advertise = true))
        // No advertisement, clean exit, nothing said.
        assertEquals(GitRemoteFailure.Unreachable("ssh_remote_failed"), failure(0, ""))
        // No exit status and nothing said: the connection went away.
        assertEquals(GitRemoteFailure.Unreachable("ssh_connection"), failure(null, ""))
        assertEquals(GitRemoteFailure.RepositoryNotFound(), failure(null, "fatal: not a git repository"))
        // No exit status after a complete exchange counts as success, as on iOS.
        val quiet = FakeSshConnector { server ->
            server.send(advertisement(head))
            server.readRequest()
            null
        }
        assertEquals(1, blocking { client(quiet).discover(GitService.UPLOAD_PACK) }.refs.size)
    }

    @Test fun serverTextNeverReachesAFailure() {
        val connector = FakeSshConnector { server ->
            server.errors.write(utf8("fatal: '/srv/private/owner/secret-repo.git' does not appear to be a git repository"))
            128
        }
        val failure = assertFailsWith<GitRemoteFailure> { blocking { client(connector).discover(GitService.UPLOAD_PACK) } }
        assertEquals("repository_not_found", failure.code)
        for (text in listOf(failure.toString(), failure.message.orEmpty(), failure.stackTraceToString())) {
            assertTrue(!text.contains("secret-repo") && !text.contains("/srv/"), text)
        }
    }

    /** Swift: `aLingeringSSHMasterDoesNotStallTheExchange`. */
    @Test fun aLingeringHolderOfStderrDoesNotStallTheExchange() {
        val connector = FakeSshConnector { server ->
            server.holdsErrorsOpen = true
            server.send(advertisement(null, "report-status"))
            server.readRequest()
            0
        }
        val started = System.nanoTime()
        assertTrue(blocking { client(connector).discover(GitService.RECEIVE_PACK) }.refs.isEmpty())
        assertTrue(System.nanoTime() - started < 5_000_000_000)
    }

    @Test fun oversizedOutputIsRefusedWhileItArrives() {
        val line = GitPktLine.line("${head.hex} refs/heads/" + "b".repeat(60_000))
        val endless = FakeSshConnector(pipeCapacity = 1 shl 20) { server ->
            // An advertisement that never reaches its flush.
            repeat(400) { server.send(line) }
            0
        }
        assertEquals(
            GitRemoteFailure.ResponseTooLarge(),
            assertFailsWith<GitRemoteFailure> { blocking { client(endless).discover(GitService.UPLOAD_PACK) } },
        )
        val chatty = FakeSshConnector(pipeCapacity = 1 shl 20) { server ->
            server.send(advertisement(head))
            repeat(400) { server.send(line) }
            0
        }
        val failure = assertFailsWith<GitRemoteFailure> {
            blocking {
                GitSshExchangeRunner.exchange(chatty, "git-upload-pack 'r.git'", location, maximumBytes = 1024) { null }
            }
        }
        assertEquals(GitRemoteFailure.ResponseTooLarge(), failure)
        assertEquals(1, chatty.channelsClosed)
    }

    @Test fun aMalformedAdvertisementEndsTheServicePolitelyAndFails() {
        val requests = CopyOnWriteArrayList<ByteArray>()
        val connector = FakeSshConnector { server ->
            server.send("-005 not a pkt-line")
            requests.add(server.readRequest())
            0
        }
        val failure = assertFailsWith<GitFormatException> { blocking { client(connector).discover(GitService.UPLOAD_PACK) } }
        assertEquals(GitFormatException.invalidPktLine(), failure)
        assertContentEquals(GitPktLine.flush, requests.single())
    }

    @Test fun aRequestThatCannotBeBuiltEndsTheServicePolitelyAndFails() {
        val requests = CopyOnWriteArrayList<ByteArray>()
        val connector = FakeSshConnector { server ->
            // No `report-status`: this client cannot push to such a server.
            server.send(advertisement(head, "side-band-64k"))
            requests.add(server.readRequest())
            0
        }
        val given = GitRefAdvertisement(mapOf("refs/heads/main" to head), mapOf("report-status" to null))
        val failure = assertFailsWith<GitRemoteFailure> { blocking { client(connector).push(head, other, utf8("PACK"), given) } }
        assertEquals(GitRemoteFailure.UnsupportedServer("report_status"), failure)
        assertContentEquals(GitPktLine.flush, requests.single())
    }

    @Test fun anUnavailableConnectorIsAClosedCode() {
        val failure = assertFailsWith<GitRemoteFailure> { blocking { client(GitUnavailableSshConnector()).discover(GitService.UPLOAD_PACK) } }
        assertEquals(GitRemoteFailure.UnsupportedServer("ssh"), failure)
    }

    // MARK: Real git services

    private fun commit(tree: List<GitObject>, root: GitObject, parent: GitObjectId?, seconds: Long): List<GitObject> {
        val commit = GitObject(
            GitObjectType.COMMIT,
            GitCommit.serialize(root.id, listOfNotNull(parent), epochSeconds = seconds, message = "Sync 1 record"),
        )
        return tree + root + commit
    }

    private fun snapshot(text: String, parent: GitObjectId?, seconds: Long): List<GitObject> {
        val blob = GitObject(GitObjectType.BLOB, utf8(text))
        val root = GitObject(GitObjectType.TREE, GitTree.serialize(listOf(GitTreeEntry.blob("file.txt", blob.id))))
        return commit(listOf(blob), root, parent, seconds)
    }

    @Test fun pushAndFetchThroughTheRealGitServices() {
        GitFixture().use { fixture ->
            val client = fixture.sshClient()
            blocking {
                val empty = client.discover(GitService.RECEIVE_PACK)
                assertTrue(empty.refs.isEmpty())
                assertTrue(empty.supports("report-status"))

                val first = snapshot("one\n", parent = null, seconds = 1_700_000_000)
                assertEquals(GitPushResult.UPDATED, client.push(GitObjectId.ZERO, first.last().id, GitPack.build(first), empty))
                assertEquals(first.last().id, fixture.head())
                fixture.bareGit("fsck", "--strict")

                val second = snapshot("two\n", parent = first.last().id, seconds = 1_700_000_100)
                val live = client.discover(GitService.RECEIVE_PACK)
                assertEquals(GitPushResult.UPDATED, client.push(first.last().id, second.last().id, GitPack.build(second), live))
                assertEquals(second.last().id, fixture.head())
                fixture.bareGit("fsck", "--strict")

                val advertised = client.discover(GitService.UPLOAD_PACK)
                assertEquals(second.last().id, advertised.refs["refs/heads/main"])
                // The tip alone: an empty cache asks for `deepen 1`.
                val tip = GitPack.parse(client.fetchPack(second.last().id, emptyList(), advertised))
                assertEquals(second.map { it.id }.toSet(), tip.keys)
                for (obj in second) assertEquals(obj, tip[obj.id])
                // With the first snapshot held, only the difference travels.
                val delta = GitPack.parse(client.fetchPack(second.last().id, listOf(first.last().id), advertised))
                assertTrue(delta.keys.containsAll(second.map { it.id }))
                assertTrue(first.none { it.id in delta.keys })
            }
            assertEquals(
                listOf("git-receive-pack 'repo.git'", "git-upload-pack 'repo.git'"),
                fixture.sshConnector.commands.distinct(),
            )
        }
    }

    @Test fun aLostRaceIsRejectedByTheRealService() {
        GitFixture().use { fixture ->
            val client = fixture.sshClient()
            blocking {
                val first = snapshot("one\n", parent = null, seconds = 1_700_000_000)
                val empty = client.discover(GitService.RECEIVE_PACK)
                assertEquals(GitPushResult.UPDATED, client.push(GitObjectId.ZERO, first.last().id, GitPack.build(first), empty))
                val stale = client.discover(GitService.RECEIVE_PACK)
                // Another writer moves the branch between this device's discovery and push.
                fixture.commitAsAnotherWriter { work -> File(work, "other.txt").writeText("theirs\n") }
                val theirs = fixture.head()
                val mine = snapshot("mine\n", parent = first.last().id, seconds = 1_700_000_200)
                assertEquals(GitPushResult.REJECTED, client.push(first.last().id, mine.last().id, GitPack.build(mine), stale))
                assertEquals(theirs, fixture.head())
                // The refused pack was never uploaded: its objects are not in the repository.
                assertFailsWith<GitCommandFailed> {
                    fixture.bareGit("cat-file", "-e", mine.last().id.hex)
                }
                // A fetch for the tip this device still believes in is a race, not a failure of the host.
                val oldView = GitRefAdvertisement(mapOf("refs/heads/main" to first.last().id), emptyMap())
                assertEquals(
                    GitRemoteFailure.Unreachable("ref_moved"),
                    assertFailsWith<GitRemoteFailure> { client.fetchPack(first.last().id, emptyList(), oldView) },
                )
            }
        }
    }

    @Test fun theRealServicesFailuresAreClassified() {
        GitFixture().use { fixture ->
            val missing = GitSshLocation(user = "git", host = "h", port = null, path = "nope.git", scpStyle = true)
            val client = GitSshClient(GitRemote.ssh(missing, "main"), missing, fixture.sshConnector)
            assertEquals(
                GitRemoteFailure.RepositoryNotFound(),
                assertFailsWith<GitRemoteFailure> { blocking { client.discover(GitService.UPLOAD_PACK) } },
            )
            // A host without git: the shell cannot find the service program.
            fixture.sshConnector.searchPath = "/nonexistent"
            assertEquals(
                GitRemoteFailure.UnsupportedServer("ssh_no_git"),
                assertFailsWith<GitRemoteFailure> { blocking { fixture.sshClient().discover(GitService.UPLOAD_PACK) } },
            )
            fixture.sshConnector.searchPath = null
            for ((status, text, expected) in listOf(
                Triple(255, "Host key verification failed.", GitRemoteFailure.SshHostKeyUnknown()),
                Triple(255, "git@x: Permission denied (publickey).", GitRemoteFailure.SshPermissionDenied()),
                Triple(128, "ERROR: Repository not found.", GitRemoteFailure.RepositoryNotFound()),
                Triple(255, "ssh: connect to host x port 22: Connection refused", GitRemoteFailure.Unreachable("ssh_connection")),
            )) {
                fixture.sshConnector.failure = status to text
                assertEquals(expected, assertFailsWith<GitRemoteFailure> { blocking { fixture.sshClient().discover(GitService.UPLOAD_PACK) } })
            }
            fixture.sshConnector.failure = null
            assertTrue(blocking { fixture.sshClient().discover(GitService.UPLOAD_PACK) }.refs.isEmpty())
        }
    }

    @Test fun aRealProcessIsStoppedByCancellationAndByTheIdleTimeout() {
        GitFixture().use { fixture ->
            fixture.sshConnector.script = "exec sleep 30"
            runBlocking {
                val task = async(Dispatchers.Default) { fixture.sshClient().discover(GitService.UPLOAD_PACK) }
                delay(300)
                val started = System.nanoTime()
                task.cancel()
                assertFailsWith<CancellationException> { task.await() }
                task.join()
                assertTrue(System.nanoTime() - started < 5_000_000_000)
            }
            val failure = assertFailsWith<GitRemoteFailure> {
                blocking { fixture.sshClient(idleTimeoutMillis = 500).discover(GitService.UPLOAD_PACK) }
            }
            assertEquals(GitRemoteFailure.Unreachable("ssh_timeout"), failure)
            // A service that ends right after its advertisement, with a large request on its way.
            fixture.sshConnector.script = "printf '0000'; exit 0"
            val pack = ByteArray(4 * 1024 * 1024)
            repeat(10) {
                val exchange = blocking {
                    GitSshExchangeRunner.exchange(fixture.sshConnector, "git-receive-pack 'r.git'", location, 1L shl 20) {
                        GitWireBody.of(pack)
                    }
                }
                assertNotNull(exchange)
                assertContentEquals(utf8("0000"), exchange.advertisement)
            }
        }
    }
}
