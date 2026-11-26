package com.khm.snippets.core.git

import com.khm.snippets.core.git.testing.GitCommandFailed
import com.khm.snippets.core.git.testing.GitFixture
import com.khm.snippets.core.git.testing.GitTestObjects
import com.khm.snippets.core.git.testing.GitTestServer
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.ServerSocket
import java.util.Base64
import java.util.Random
import java.util.zip.GZIPOutputStream
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * `GitSmartHttpClient` over the real OkHttp engine against the real
 * `git http-backend` (see `GitTestServer`). Where a Swift test exists for the same
 * behaviour at the transport level (`GitSyncTransportTests`), the name is kept.
 */
class GitSmartHttpClientTest {
    private fun utf8(text: String) = text.toByteArray(Charsets.UTF_8)

    private fun <T> blocking(block: suspend () -> T): T = runBlocking { withTimeout(120_000) { block() } }

    private inline fun <reified T : Throwable> failure(crossinline block: suspend () -> Unit): T =
        assertFailsWith<T> { blocking { block() } }

    private fun files(vararg pairs: Pair<String, String>): Map<String, ByteArray> =
        pairs.associate { it.first to utf8(it.second) }

    /** Creates the branch with one commit made by this client. Returns the snapshot pushed. */
    private fun GitFixture.seed(client: GitSmartHttpClient = client()): GitTestObjects.Snapshot {
        val snapshot = GitTestObjects.snapshot(
            files(
                "snippets-sync.json" to "{}\n",
                "README.md" to "A library.\n",
                "records/ab/ab000000-0000-4000-8000-000000000001.json" to "{\"blob\":\"AAAA\"}\n",
                "records/cd/cd000000-0000-4000-8000-000000000002.json" to "{\"blob\":\"BBBB\"}\n",
            ),
        )
        blocking {
            val advertisement = client.discover(GitService.RECEIVE_PACK)
            assertEquals(GitPushResult.UPDATED, client.push(GitObjectId.ZERO, snapshot.id, GitPack.build(snapshot.objects), advertisement))
        }
        return snapshot
    }

    // MARK: Discovery

    @Test fun discoveryOfAnEmptyRepositoryHasNoRefs() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val upload = blocking { client.discover(GitService.UPLOAD_PACK) }
            assertTrue(upload.refs.isEmpty())
            assertEquals(fixture.url, upload.serviceUrl)
            val receive = blocking { client.discover(GitService.RECEIVE_PACK) }
            assertTrue(receive.refs.isEmpty())
            assertTrue(receive.supports("report-status"))
            assertEquals(listOf("GET refs?git-upload-pack", "GET refs?git-receive-pack"), fixture.server.requests)
        }
    }

    @Test fun discoveryOfAPopulatedRepositoryListsItsBranch() {
        GitFixture().use { fixture ->
            fixture.commitAsAnotherWriter { work -> File(work, "a.txt").writeText("a\n") }
            val advertisement = blocking { fixture.client().discover(GitService.UPLOAD_PACK) }
            assertEquals(fixture.bareGit("rev-parse", "refs/heads/main"), advertisement.refs["refs/heads/main"]?.hex)
            assertTrue(advertisement.supports("shallow"))
            assertTrue(advertisement.supports("side-band-64k"))
            assertTrue(advertisement.supports("ofs-delta"))
            assertNotNull(advertisement.capabilities["agent"])
        }
    }

    /** The cost invariant the transport builds on: asking for the head is one request. */
    @Test fun anIdleRoundIsOneDiscoveryRequest() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            fixture.seed(client)
            fixture.server.clearRequests()
            blocking { client.discover(GitService.UPLOAD_PACK) }
            assertEquals(listOf("GET refs?git-upload-pack"), fixture.server.requests)
        }
    }

    @Test fun requestsCarryExactlyTheHeadersOfTheSwiftClient() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val snapshot = fixture.seed(client)
            val advertisement = blocking { client.discover(GitService.UPLOAD_PACK) }
            blocking { client.fetchPack(snapshot.id, emptyList(), advertisement) }
            val expectedAuthorization = "Basic " + Base64.getEncoder()
                .encodeToString("${fixture.username}:${fixture.password}".toByteArray())
            for (request in fixture.server.recorded) {
                assertEquals(expectedAuthorization, request.header("Authorization"), request.summary)
                assertEquals("git/2.0 (Snippets)", request.header("User-Agent"), request.summary)
                assertEquals("no-cache", request.header("Pragma"), request.summary)
                assertEquals("no-cache", request.header("Cache-Control"), request.summary)
                assertNull(request.header("Cookie"), request.summary)
                assertNull(request.header("Git-Protocol"), "protocol v0/v1 only")
                assertEquals(1, request.headers["authorization"]?.size)
            }
            val discovery = fixture.server.recorded.first { it.summary == "GET refs?git-upload-pack" }
            assertEquals("*/*", discovery.header("Accept"))
            assertEquals("/repo.git/info/refs", discovery.path)
            assertEquals("service=git-upload-pack", discovery.query)
            assertEquals(0, discovery.body.size)

            val fetch = fixture.server.recorded.first { it.summary == "POST git-upload-pack" }
            assertEquals("application/x-git-upload-pack-request", fetch.header("Content-Type"))
            assertEquals("application/x-git-upload-pack-result", fetch.header("Accept"))
            assertEquals("/repo.git/git-upload-pack", fetch.path)
            val expectedBody = GitWire.uploadRequest(snapshot.id, emptyList(), advertisement).body.toByteArray()
            assertContentEquals(expectedBody, fetch.body)
            assertEquals(expectedBody.size.toString(), fetch.header("Content-Length"), "a declared length, not chunked")
            assertTrue(fetch.body.toString(Charsets.UTF_8).contains("deepen 1"))

            val push = fixture.server.recorded.first { it.summary == "POST git-receive-pack" }
            assertEquals("application/x-git-receive-pack-request", push.header("Content-Type"))
            assertEquals("application/x-git-receive-pack-result", push.header("Accept"))
            assertEquals(push.body.size.toString(), push.header("Content-Length"))
            val command = push.body.toString(Charsets.ISO_8859_1)
            assertTrue(command.contains("${"0".repeat(40)} ${snapshot.id.hex} refs/heads/main\u0000report-status agent=snippets/1 side-band-64k"), command.take(200))
        }
    }

    // MARK: Fetch

    @Test fun aFullFetchParsesIntoTheObjectsGitHas() {
        GitFixture().use { fixture ->
            val big = ByteArray(300_000).also { Random(1).nextBytes(it) }
            fixture.commitAsAnotherWriter { work ->
                File(work, "README.md").writeText("hello\n")
                File(work, "empty").writeBytes(ByteArray(0))
                File(work, "records/ab").mkdirs()
                File(work, "records/ab/one.json").writeText("{\"n\":1}\n")
                File(work, "records/cd").mkdirs()
                File(work, "records/cd/two.bin").writeBytes(big)
            }
            fixture.commitAsAnotherWriter { work -> File(work, "README.md").writeText("hello again\n") }
            val client = fixture.client()
            val advertisement = blocking { client.discover(GitService.UPLOAD_PACK) }
            val head = assertNotNull(advertisement.refs["refs/heads/main"])
            assertEquals(fixture.bareGit("rev-parse", "HEAD"), head.hex)

            val objects = GitPack.parse(blocking { client.fetchPack(head, emptyList(), advertisement) })
            // `deepen 1`: the tip commit with its whole tree, and no history.
            val expected = fixture.bareGit("rev-list", "--objects", "--no-walk", head.hex).lines().map { it.take(40) }.toSet()
            assertEquals(expected, objects.keys.map { it.hex }.toSet())
            for ((id, obj) in objects) {
                assertEquals(fixture.bareGit("cat-file", "-t", id.hex), obj.type.typeName)
                assertContentEquals(fixture.bareGitBytes("cat-file", obj.type.typeName, id.hex), obj.content, id.hex)
            }
            val commit = GitCommit.parse(objects.getValue(head).content)
            assertEquals(fixture.bareGit("rev-parse", "HEAD^{tree}"), commit.tree.hex)
            assertEquals(listOf(fixture.bareGit("rev-parse", "HEAD~1")), commit.parents.map { it.hex })
            // Walk the tree as the transport will and find the file contents.
            val root = GitTree.parse(objects.getValue(commit.tree).content)
            assertEquals(listOf("README.md", "empty", "records"), root.map { it.nameString })
            val records = GitTree.parse(objects.getValue(root.first { it.isTree }.id).content)
            val cd = GitTree.parse(objects.getValue(records.first { it.nameString == "cd" }.id).content)
            assertContentEquals(big, objects.getValue(cd.single().id).content)
            assertEquals(listOf("GET refs?git-upload-pack", "POST git-upload-pack"), fixture.server.requests.takeLast(2))
        }
    }

    @Test fun anIncrementalFetchWithHavesBringsOnlyWhatChanged() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val first = fixture.seed(client)
            val second = GitTestObjects.snapshot(
                files(
                    "snippets-sync.json" to "{}\n",
                    "README.md" to "A library.\n",
                    "records/ab/ab000000-0000-4000-8000-000000000001.json" to "{\"blob\":\"CHANGED\"}\n",
                    "records/cd/cd000000-0000-4000-8000-000000000002.json" to "{\"blob\":\"BBBB\"}\n",
                ),
                parent = first.id, epochSeconds = 1_700_000_100,
            )
            blocking {
                val live = client.discover(GitService.RECEIVE_PACK)
                assertEquals(GitPushResult.UPDATED, client.push(first.id, second.id, GitPack.build(second.objects), live))
            }
            fixture.server.clearRequests()
            val advertisement = blocking { client.discover(GitService.UPLOAD_PACK) }
            val pack = blocking { client.fetchPack(second.id, listOf(first.id), advertisement) }
            val objects = GitPack.parse(pack) { id -> first.objects.firstOrNull { it.id == id } }
            val firstIds = first.objects.map { it.id }.toSet()
            val changed = second.objects.map { it.id }.filter { it !in firstIds }.toSet()
            // The commit, the three rewritten trees and the one new blob; nothing held already.
            assertEquals(5, changed.size)
            assertEquals(changed, objects.keys)
            val request = fixture.server.recorded.last().body.toString(Charsets.UTF_8)
            assertTrue(request.contains("have ${first.id.hex}\n"))
            assertFalse(request.contains("deepen") || request.contains("shallow"), "plain haves, never shallow")
        }
    }

    /**
     * History that git has repacked into delta chains, fetched whole. Offset deltas
     * when the client may ask for them, reference deltas when the server does not
     * offer `ofs-delta`.
     */
    @Test fun aFetchOfHistoryRepackedWithDeltasResolvesEveryObject() {
        GitFixture().use { fixture ->
            var text = (0 until 4_000).joinToString("") { "line $it of a long, repetitive file\n" }
            for (revision in 0 until 12) {
                text = text.replace("line ${revision * 100} ", "edited $revision ")
                val content = text
                fixture.commitAsAnotherWriter(message = "r$revision") { work -> File(work, "file.txt").writeText(content) }
            }
            fixture.bareGit("repack", "-a", "-d", "-f", "--depth=50", "--window=50")
            val expected = fixture.bareGit("rev-list", "--objects", "--all").lines().map { it.take(40) }.toSet()
            assertEquals(12 * 3, expected.size)

            val client = fixture.client()
            val advertised = blocking { client.discover(GitService.UPLOAD_PACK) }
            val head = assertNotNull(advertised.refs["refs/heads/main"])
            // Without `shallow` the client asks for the whole history, as it does from a
            // server that cannot serve a shallow tip.
            val withOffsets = advertised.copy(capabilities = advertised.capabilities - "shallow")
            val withReferences = withOffsets.copy(capabilities = withOffsets.capabilities - "ofs-delta")
            for (advertisement in listOf(withOffsets, withReferences)) {
                val pack = blocking { client.fetchPack(head, emptyList(), advertisement) }
                val objects = GitPack.parse(pack)
                assertEquals(expected, objects.keys.map { it.hex }.toSet())
                val blob = objects.getValue(assertNotNull(GitObjectId.fromHex(fixture.bareGit("rev-parse", "HEAD:file.txt"))))
                assertEquals(text, blob.content.toString(Charsets.UTF_8))
                for ((id, obj) in objects) assertEquals(id, GitObjectId.hash(obj.type, obj.content))
                // A delta-compressed pack is far smaller than twelve copies of the file.
                assertTrue(pack.size < utf8(text).size * 3, "pack of ${pack.size} bytes is not deltified")
                val deltas = deltaEntryTypes(pack)
                assertTrue(deltas.isNotEmpty(), "the pack holds no delta at all")
                assertEquals(setOf(if (advertisement.supports("ofs-delta")) 6 else 7), deltas)
            }
        }
    }

    /** The delta entry types (6 = offset, 7 = reference) a pack contains, read from its entry headers. */
    private fun deltaEntryTypes(pack: ByteArray): Set<Int> {
        val count = ((pack[8].toInt() and 0xff) shl 24) or ((pack[9].toInt() and 0xff) shl 16) or
            ((pack[10].toInt() and 0xff) shl 8) or (pack[11].toInt() and 0xff)
        val types = HashSet<Int>()
        var offset = 12
        repeat(count) {
            var byte = pack[offset++].toInt() and 0xff
            val type = (byte shr 4) and 7
            var size = (byte and 0x0f).toLong()
            var shift = 4
            while (byte and 0x80 != 0) {
                byte = pack[offset++].toInt() and 0xff
                size = size or ((byte and 0x7f).toLong() shl shift)
                shift += 7
            }
            if (type == 6) {
                types.add(type)
                while (pack[offset++].toInt() and 0x80 != 0) Unit
            } else if (type == 7) {
                types.add(type)
                offset += 20
            }
            offset += GitZlib.inflate(pack, offset, size.toInt()).consumed
        }
        return types
    }

    // MARK: Push

    @Test fun aPushOfAGeneratedPackIsAcceptedByGit() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val random = ByteArray(200_000).also { Random(2).nextBytes(it) }
            val files = mapOf(
                "snippets-sync.json" to utf8("{}\n"),
                "README.md" to utf8("A library.\n"),
                "empty" to ByteArray(0),
                "keys/recovery.json" to utf8("{\"k\":1}\n"),
                "records/00/a.json" to random,
                "records/ff/b.json" to utf8("b\n"),
                "a-b" to utf8("1"),
                "a.b" to utf8("2"),
                "a/c" to utf8("3"),
                "B" to utf8("4"),
            )
            val first = GitTestObjects.snapshot(files, message = "Create Snippets library")
            blocking {
                val advertisement = client.discover(GitService.RECEIVE_PACK)
                assertEquals(GitPushResult.UPDATED, client.push(GitObjectId.ZERO, first.id, GitPack.build(first.objects), advertisement))
            }
            // The server-side git agrees with every byte this client produced.
            fixture.bareGit("fsck", "--strict", "--no-dangling")
            assertEquals(first.id.hex, fixture.bareGit("rev-parse", "refs/heads/main"))
            assertEquals(first.tree.hex, fixture.bareGit("rev-parse", "refs/heads/main^{tree}"))
            assertContentEquals(first.commit.content, fixture.bareGitBytes("cat-file", "commit", first.id.hex))
            for ((path, content) in files) {
                assertContentEquals(content, fixture.bareGitBytes("cat-file", "blob", "${first.id.hex}:$path"), path)
            }
            assertEquals(
                "Snippets Sync <sync@snippets.invalid>|Snippets Sync <sync@snippets.invalid>|1700000000|Create Snippets library",
                fixture.bareGit("log", "-1", "--format=%an <%ae>|%cn <%ce>|%at|%s", first.id.hex),
            )

            // A second commit on top: only the new objects travel.
            val changed = files + ("records/ff/b.json" to utf8("b2\n"))
            val second = GitTestObjects.snapshot(changed, parent = first.id, epochSeconds = 1_700_000_050, message = "Sync 1 record")
            val firstIds = first.objects.map { it.id }.toSet()
            val delta = second.objects.filter { it.id !in firstIds }
            assertEquals(5, delta.size)
            blocking {
                val advertisement = client.discover(GitService.RECEIVE_PACK)
                assertEquals(first.id, advertisement.refs["refs/heads/main"])
                assertEquals(GitPushResult.UPDATED, client.push(first.id, second.id, GitPack.build(delta), advertisement))
            }
            fixture.bareGit("fsck", "--strict", "--no-dangling")
            assertEquals(second.id.hex, fixture.bareGit("rev-parse", "refs/heads/main"))
            assertEquals(first.id.hex, fixture.bareGit("rev-parse", "refs/heads/main~1"))
            assertContentEquals(utf8("b2\n"), fixture.bareGitBytes("cat-file", "blob", "refs/heads/main:records/ff/b.json"))
        }
    }

    /** Swift: the lost race of `GitSyncTransportTests`, staged with the same receive-pack hook. */
    @Test fun aPushThatLostTheRaceIsRejectedAndChangesNothing() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val first = fixture.seed(client)
            val mine = GitTestObjects.snapshot(files("mine.txt" to "mine\n"), parent = first.id, epochSeconds = 1_700_000_300)
            val advertisement = blocking { client.discover(GitService.RECEIVE_PACK) }
            // Another writer moves the branch between this device's discovery and push.
            fixture.server.beforeNextReceivePack {
                fixture.commitAsAnotherWriter { work -> File(work, "theirs.txt").writeText("theirs\n") }
            }
            val result = blocking { client.push(first.id, mine.id, GitPack.build(mine.objects), advertisement) }
            assertEquals(GitPushResult.REJECTED, result)
            val theirs = fixture.head()
            assertTrue(theirs != first.id && theirs != mine.id)
            assertEquals("theirs\n", fixture.bareGit("cat-file", "blob", "refs/heads/main:theirs.txt") + "\n")
            assertFailsWith<GitCommandFailed> { fixture.bareGit("cat-file", "-e", "refs/heads/main:mine.txt") }
        }
    }

    @Test fun aNonFastForwardPushIsRejected() {
        GitFixture().use { fixture ->
            fixture.bareGit("config", "receive.denyNonFastForwards", "true")
            val client = fixture.client()
            val first = fixture.seed(client)
            // The right `old`, but a commit that does not descend from it.
            val unrelated = GitTestObjects.snapshot(files("x.txt" to "x\n"), parent = null, epochSeconds = 1_700_000_400)
            val advertisement = blocking { client.discover(GitService.RECEIVE_PACK) }
            assertEquals(GitPushResult.REJECTED, blocking { client.push(first.id, unrelated.id, GitPack.build(unrelated.objects), advertisement) })
            assertEquals(first.id, fixture.head())
            // Creating a branch that already exists is refused the same way.
            assertEquals(GitPushResult.REJECTED, blocking { client.push(GitObjectId.ZERO, unrelated.id, GitPack.build(unrelated.objects), advertisement) })
            assertEquals(first.id, fixture.head())
        }
    }

    @Test fun aPackTheServerCannotUnpackIsAProtocolViolation() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val first = fixture.seed(client)
            val next = GitTestObjects.snapshot(files("x.txt" to "x\n"), parent = first.id)
            val advertisement = blocking { client.discover(GitService.RECEIVE_PACK) }
            // The commit without its tree and blob: git refuses to move the branch onto it.
            val incomplete = GitPack.build(listOf(next.commit))
            val outcome = runCatching { blocking { client.push(first.id, next.id, incomplete, advertisement) } }
            val failure = outcome.exceptionOrNull()
            assertTrue(
                outcome.getOrNull() == GitPushResult.REJECTED || failure == GitRemoteFailure.ProtocolViolation("remote_unpack_failed"),
                "an incomplete pack must not be reported as updated: $outcome",
            )
            assertEquals(first.id, fixture.head())
            // Bytes that are not a pack at all: the server says so in its report.
            val garbage = "PACK".toByteArray() + byteArrayOf(0, 0, 0, 2, 0, 0, 0, 1) + ByteArray(64) { 0x55 }
            assertEquals(
                GitRemoteFailure.ProtocolViolation("remote_unpack_failed"),
                failure<GitRemoteFailure> { client.push(first.id, next.id, garbage, advertisement) },
            )
            assertEquals(first.id, fixture.head())
        }
    }

    // MARK: Credentials

    /** Swift: `wrongCredentialRequiresAuthentication`. */
    @Test fun wrongCredentialRequiresAuthentication() {
        GitFixture().use { fixture ->
            val snapshot = fixture.seed()
            val advertisement = blocking { fixture.client().discover(GitService.RECEIVE_PACK) }
            val wrong = fixture.client(remote = fixture.remote(password = "not-the-token"))
            assertEquals(GitRemoteFailure.AuthenticationRequired(401), failure<GitRemoteFailure> { wrong.discover(GitService.UPLOAD_PACK) })
            assertEquals(GitRemoteFailure.AuthenticationRequired(401), failure<GitRemoteFailure> { wrong.fetchPack(snapshot.id, emptyList(), advertisement) })
            val next = GitTestObjects.snapshot(files("x" to "x"), parent = snapshot.id)
            assertEquals(
                GitRemoteFailure.AuthenticationRequired(401),
                failure<GitRemoteFailure> { wrong.push(snapshot.id, next.id, GitPack.build(next.objects), advertisement) },
            )
            assertEquals(snapshot.id, fixture.head())
            // The engine did not retry, with or without the credential: one request per call.
            assertEquals(
                listOf("GET refs?git-upload-pack", "POST git-upload-pack", "POST git-receive-pack"),
                fixture.server.requests.drop(3),
            )
            assertEquals(3, fixture.server.authorizationHeaders.drop(3).count { it.startsWith("Basic ") })
        }
    }

    // MARK: Redirects

    /**
     * Swift: `sameHostRedirectIsFollowedAndRebasesLaterRequests`. Hosts that
     * canonicalize `/owner/repo` to `/owner/repo.git` redirect discovery. POSTs cannot
     * follow redirects, so later requests must use the redirected base.
     */
    @Test fun sameHostRedirectIsFollowedAndRebasesLaterRequests() {
        GitFixture().use { fixture ->
            fixture.server.redirect = GitTestServer.Redirect(prefix = "/repo.git/", base = "${fixture.server.origin}/repo.git")
            val client = fixture.client(remote = fixture.remote(url = "${fixture.server.origin}/repo"))
            val snapshot = GitTestObjects.snapshot(files("a" to "a"))
            blocking {
                val advertisement = client.discover(GitService.RECEIVE_PACK)
                assertEquals("${fixture.server.origin}/repo.git", advertisement.serviceUrl)
                assertEquals(GitPushResult.UPDATED, client.push(GitObjectId.ZERO, snapshot.id, GitPack.build(snapshot.objects), advertisement))
                val upload = client.discover(GitService.UPLOAD_PACK)
                assertEquals(snapshot.objects.map { it.id }.toSet(), GitPack.parse(client.fetchPack(snapshot.id, emptyList(), upload)).keys)
            }
            val redirects = fixture.server.requests.filter { it.startsWith("REDIRECT") }
            assertTrue(redirects.isNotEmpty())
            assertTrue(redirects.all { it.startsWith("REDIRECT GET") }, fixture.server.requests.toString())
            assertTrue(fixture.server.requests.contains("POST git-receive-pack"))
            assertTrue(fixture.server.requests.contains("POST git-upload-pack"))
            assertEquals(snapshot.id, fixture.head())
        }
    }

    /** Swift: `crossHostRedirectNeverReceivesTheCredential`. */
    @Test fun crossHostRedirectNeverReceivesTheCredential() {
        GitFixture().use { fixture ->
            GitFixture().use { attacker ->
                // Another host name and another port.
                fixture.server.redirect = GitTestServer.Redirect(prefix = "/never/", base = "http://localhost:${attacker.server.port}/repo.git")
                assertEquals(
                    GitRemoteFailure.ProtocolViolation("http_301"),
                    failure<GitRemoteFailure> { fixture.client().discover(GitService.UPLOAD_PACK) },
                )
                assertTrue(attacker.server.authorizationHeaders.isEmpty())
                assertTrue(attacker.server.requests.isEmpty())
                // The same host on another port is another origin too.
                fixture.server.redirect = GitTestServer.Redirect(prefix = "/never/", base = "${attacker.server.origin}/repo.git", status = 302)
                assertEquals(
                    GitRemoteFailure.ProtocolViolation("http_302"),
                    failure<GitRemoteFailure> { fixture.client().discover(GitService.UPLOAD_PACK) },
                )
                assertTrue(attacker.server.authorizationHeaders.isEmpty())
            }
        }
        assertFalse(GitSmartHttpClient.permitsRedirect("GET", "https://a.example/x", "https://b.example/x"))
        assertFalse(GitSmartHttpClient.permitsRedirect("POST", "https://a.example/x", "https://a.example/y"))
        assertFalse(GitSmartHttpClient.permitsRedirect("GET", "https://a.example/x", "http://a.example/x"))
        assertTrue(GitSmartHttpClient.permitsRedirect("GET", "https://a.example/x", "https://A.example/x.git"))
    }

    @Test fun aRedirectedPostIsNeverFollowed() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val snapshot = fixture.seed(client)
            val advertisement = blocking { client.discover(GitService.UPLOAD_PACK) }
            fixture.server.clearRequests()
            fixture.server.intercept = { request ->
                if (request.method == "POST") {
                    GitTestServer.Response(307, mapOf("Location" to "${fixture.server.origin}/repo.git/git-upload-pack?again=1"))
                } else {
                    null
                }
            }
            assertEquals(
                GitRemoteFailure.ProtocolViolation("http_307"),
                failure<GitRemoteFailure> { client.fetchPack(snapshot.id, emptyList(), advertisement) },
            )
            assertEquals(listOf("POST git-upload-pack"), fixture.server.requests)
        }
    }

    // MARK: Limits

    @Test fun responsesOverTheLimitAreRefusedWhileTheyArrive() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val type = mapOf("Content-Type" to "application/x-git-upload-pack-advertisement")
            val limit = GitWire.MAXIMUM_ADVERTISEMENT_BYTES.toInt()

            // A declared length over the limit is refused before a byte is read.
            fixture.server.intercept = { GitTestServer.Response(200, type, ByteArray(16), declaredLength = limit + 1L) }
            assertEquals(GitRemoteFailure.ResponseTooLarge(), failure<GitRemoteFailure> { client.discover(GitService.UPLOAD_PACK) })

            // No declared length: counted as it streams.
            val oversized = ByteArray(limit + 1)
            fixture.server.intercept = { GitTestServer.Response(200, type, oversized, trickleBytes = 1 shl 20) }
            assertEquals(GitRemoteFailure.ResponseTooLarge(), failure<GitRemoteFailure> { client.discover(GitService.UPLOAD_PACK) })

            // Compressed in transit: what counts is the size once decoded.
            val compressed = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(oversized) } }.toByteArray()
            assertTrue(compressed.size < 64 * 1024)
            fixture.server.intercept = { request ->
                assertEquals("gzip", request.header("Accept-Encoding"))
                GitTestServer.Response(200, type + ("Content-Encoding" to "gzip"), compressed)
            }
            assertEquals(GitRemoteFailure.ResponseTooLarge(), failure<GitRemoteFailure> { client.discover(GitService.UPLOAD_PACK) })

            // Exactly at the limit is accepted (and then judged by its content).
            val atLimit = ByteArray(limit) { '0'.code.toByte() }
            fixture.server.intercept = { GitTestServer.Response(200, type, atLimit) }
            assertTrue(blocking { client.discover(GitService.UPLOAD_PACK) }.refs.isEmpty())
        }
    }

    @Test fun aCompressedAdvertisementIsDecodedTransparently() {
        GitFixture().use { fixture ->
            fixture.commitAsAnotherWriter { work -> File(work, "a.txt").writeText("a\n") }
            fixture.server.transform = { _, response ->
                val compressed = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(response.body) } }.toByteArray()
                GitTestServer.Response(response.status, response.headers + ("Content-Encoding" to "gzip"), compressed)
            }
            assertEquals(fixture.head(), blocking { fixture.client().discover(GitService.UPLOAD_PACK) }.refs["refs/heads/main"])
        }
    }

    @Test fun aPackOverTheClientsLimitIsRefused() {
        GitFixture().use { fixture ->
            val random = ByteArray(100_000).also { Random(3).nextBytes(it) }
            fixture.commitAsAnotherWriter { work -> File(work, "big.bin").writeBytes(random) }
            val small = fixture.client(maximumPackBytes = 50_000)
            val advertisement = blocking { small.discover(GitService.UPLOAD_PACK) }
            assertEquals(
                GitRemoteFailure.ResponseTooLarge(),
                failure<GitRemoteFailure> { small.fetchPack(fixture.head(), emptyList(), advertisement) },
            )
            val roomy = fixture.client(maximumPackBytes = 200_000)
            assertEquals(3, GitPack.parse(blocking { roomy.fetchPack(fixture.head(), emptyList(), advertisement) }).size)
        }
    }

    // MARK: Timeouts and cancellation

    @Test fun anIdleConnectionTimesOutButASlowMovingOneDoesNot() {
        GitFixture().use { fixture ->
            fixture.commitAsAnotherWriter { work -> File(work, "a.txt").writeText("a\n") }
            val client = fixture.client(engine = fixture.engine(idleTimeoutMillis = 400, requestTimeoutMillis = 30_000))
            // Nothing for longer than the idle timeout.
            fixture.server.intercept = { GitTestServer.Response(200, delayMillis = 3_000) }
            val started = System.nanoTime()
            assertEquals(GitRemoteFailure.Unreachable("network_-1001"), failure<GitRemoteFailure> { client.discover(GitService.UPLOAD_PACK) })
            assertTrue(System.nanoTime() - started < 2_500_000_000)

            // Slower in total than the idle timeout, but never idle for that long.
            fixture.server.intercept = null
            fixture.server.transform = { _, response ->
                GitTestServer.Response(response.status, response.headers, response.body, trickleBytes = response.body.size / 12 + 1, trickleDelayMillis = 100)
            }
            assertEquals(fixture.head(), blocking { client.discover(GitService.UPLOAD_PACK) }.refs["refs/heads/main"])
        }
    }

    @Test fun theWholeRequestIsCappedEvenWhileBytesKeepArriving() {
        GitFixture().use { fixture ->
            val client = fixture.client(engine = fixture.engine(idleTimeoutMillis = 5_000, requestTimeoutMillis = 600))
            val type = mapOf("Content-Type" to "application/x-git-upload-pack-advertisement")
            fixture.server.intercept = { GitTestServer.Response(200, type, ByteArray(400), trickleBytes = 10, trickleDelayMillis = 100) }
            val started = System.nanoTime()
            assertEquals(GitRemoteFailure.Unreachable("network_-1001"), failure<GitRemoteFailure> { client.discover(GitService.UPLOAD_PACK) })
            assertTrue(System.nanoTime() - started < 3_000_000_000)
        }
    }

    @Test fun cancellationIsReportedAsCancellation() {
        GitFixture().use { fixture ->
            fixture.server.intercept = { GitTestServer.Response(200, delayMillis = 10_000) }
            val client = fixture.client()
            runBlocking {
                val task = async(Dispatchers.Default) { client.discover(GitService.UPLOAD_PACK) }
                delay(300)
                val started = System.nanoTime()
                task.cancel()
                assertFailsWith<CancellationException> { task.await() }
                assertTrue(System.nanoTime() - started < 2_000_000_000)
            }
        }
    }

    // MARK: Status codes

    @Test fun statusCodesMapToTheClosedFailures() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            fun answer(status: Int, headers: Map<String, String> = emptyMap(), body: String = "<html>secret-path</html>"): GitRemoteFailure {
                fixture.server.intercept = { GitTestServer.Response(status, headers, utf8(body)) }
                fixture.server.clearRequests()
                val failure = failure<GitRemoteFailure> { client.discover(GitService.UPLOAD_PACK) }
                // Whatever the answer, the HTTP stack asked once: no retry, no follow-up of its own.
                assertEquals(listOf("GET refs?git-upload-pack"), fixture.server.requests, "status $status $headers")
                return failure
            }
            assertEquals(GitRemoteFailure.AuthenticationRequired(401), answer(401))
            assertEquals(GitRemoteFailure.AuthenticationRequired(403), answer(403))
            assertEquals(GitRemoteFailure.RepositoryNotFound(), answer(404))
            assertEquals(GitRemoteFailure.RequestTooLarge(), answer(413))
            assertEquals(GitRemoteFailure.RateLimited(30.0), answer(429))
            assertEquals(GitRemoteFailure.RateLimited(7.0), answer(429, mapOf("Retry-After" to "7")))
            assertEquals(GitRemoteFailure.RateLimited(1.5), answer(503, mapOf("Retry-After" to "1.5")))
            assertEquals(GitRemoteFailure.RateLimited(3_600.0), answer(503, mapOf("Retry-After" to "99999")))
            assertEquals(GitRemoteFailure.RateLimited(1.0), answer(503, mapOf("Retry-After" to "0")))
            assertEquals(GitRemoteFailure.RateLimited(30.0), answer(503, mapOf("Retry-After" to "Wed, 21 Oct 2026 07:28:00 GMT")))
            // The two answers OkHttp would re-send a request for by itself.
            assertEquals(GitRemoteFailure.RateLimited(1.0), answer(503, mapOf("Retry-After" to "0")))
            assertEquals(GitRemoteFailure.RateLimited(30.0), answer(503))
            assertEquals(GitRemoteFailure.ProtocolViolation("http_408"), answer(408))
            assertEquals(GitRemoteFailure.ProtocolViolation("http_408"), answer(408, mapOf("Retry-After" to "0")))
            assertEquals(GitRemoteFailure.ProtocolViolation("http_421"), answer(421))
            assertEquals(GitRemoteFailure.ServerError(500), answer(500))
            assertEquals(GitRemoteFailure.ServerError(502), answer(502))
            assertEquals(GitRemoteFailure.ProtocolViolation("http_418"), answer(418))
            assertEquals(GitRemoteFailure.ProtocolViolation("http_204"), answer(204, body = ""))
            assertEquals(GitRemoteFailure.ProtocolViolation("http_304"), answer(304, body = ""))
            // A 3xx without a usable Location is judged by its status.
            assertEquals(GitRemoteFailure.ProtocolViolation("http_301"), answer(301, body = ""))
            // A login page or a "dumb" server: 200, but not a smart-HTTP advertisement.
            val page = answer(200, mapOf("Content-Type" to "text/html; charset=utf-8"))
            assertEquals(GitRemoteFailure.UnsupportedServer("not_smart_http"), page)
            assertFalse(page.toString().contains("secret-path") || page.stackTraceToString().contains("secret-path"))
            // The media type is compared without parameters and without regard to case.
            fixture.server.intercept = {
                GitTestServer.Response(200, mapOf("Content-Type" to "Application/X-Git-Upload-Pack-Advertisement; charset=utf-8"), GitPktLine.flush)
            }
            assertTrue(blocking { client.discover(GitService.UPLOAD_PACK) }.refs.isEmpty())
        }
    }

    @Test fun aWrongResultTypeIsAProtocolViolation() {
        GitFixture().use { fixture ->
            val client = fixture.client()
            val snapshot = fixture.seed(client)
            val upload = blocking { client.discover(GitService.UPLOAD_PACK) }
            val receive = blocking { client.discover(GitService.RECEIVE_PACK) }
            fixture.server.intercept = { request ->
                if (request.method == "POST") GitTestServer.Response(200, mapOf("Content-Type" to "text/plain"), utf8("ok")) else null
            }
            assertEquals(
                GitRemoteFailure.ProtocolViolation("upload_pack_content_type"),
                failure<GitRemoteFailure> { client.fetchPack(snapshot.id, emptyList(), upload) },
            )
            assertEquals(
                GitRemoteFailure.ProtocolViolation("receive_pack_content_type"),
                failure<GitRemoteFailure> { client.push(snapshot.id, snapshot.id, ByteArray(0), receive) },
            )
        }
    }

    // MARK: The loopback seam

    @Test fun plainHttpIsRefusedWithoutTheExplicitTestSeam() {
        GitFixture().use { fixture ->
            // The remote: production code cannot even describe a plain-HTTP address.
            assertEquals(
                GitRemote.Failure.INVALID_URL,
                assertFailsWith<GitRemoteConfigurationException> {
                    GitRemote.https(fixture.url, "main", fixture.username, fixture.password)
                }.failure,
            )
            // The engine: without the seam it has no way to speak cleartext, whoever asks.
            OkHttpGitHttpEngine().use { production ->
                val client = GitSmartHttpClient(fixture.remote(), production)
                assertEquals(GitRemoteFailure.Unreachable("network_-1022"), failure<GitRemoteFailure> { client.discover(GitService.UPLOAD_PACK) })
            }
            assertTrue(fixture.server.requests.isEmpty())
            assertTrue(fixture.server.authorizationHeaders.isEmpty())
            // With the seam, cleartext still goes to loopback only.
            val request = GitHttpRequest("GET", "http://example.com/repo.git/info/refs", listOf("Authorization" to "Basic x"))
            assertEquals(
                GitRemoteFailure.Unreachable("network_-1022"),
                failure<GitRemoteFailure> { fixture.engine().execute(request, 1024) },
            )
        }
    }

    @Test fun anUnreachableHostIsAClosedNetworkCode() {
        GitFixture().use { fixture ->
            val closedPort = ServerSocket(0).use { it.localPort }
            val remote = fixture.remote(url = "http://127.0.0.1:$closedPort/repo.git")
            val failure = failure<GitRemoteFailure> { fixture.client(remote = remote).discover(GitService.UPLOAD_PACK) }
            assertEquals(GitRemoteFailure.Unreachable("network_-1004"), failure)
            assertFalse(failure.toString().contains(closedPort.toString()), "no address in a failure")
        }
    }
}
