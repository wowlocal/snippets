package com.khm.snippets.core.git

import java.io.IOException
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * The client's own decisions (credential, redirects, status handling), with the HTTP
 * engine replaced by a scripted one. No socket, no git.
 */
class GitSmartHttpClientPolicyTest {
    private class ScriptedEngine(private val answer: (GitHttpRequest) -> GitHttpResponse) : GitHttpEngine {
        val requests = CopyOnWriteArrayList<GitHttpRequest>()
        val limits = CopyOnWriteArrayList<Long>()

        override suspend fun execute(request: GitHttpRequest, maximumResponseBytes: Long): GitHttpResponse {
            requests.add(request)
            limits.add(maximumResponseBytes)
            return answer(request)
        }
    }

    private val remote = GitRemote.https("https://git.example/owner/repo", "main", "user name", "tökén:with:colons")
    private val head = GitObjectId.hash(GitObjectType.BLOB, "head".toByteArray())

    private fun advertisementBody(service: GitService, vararg capabilities: String): ByteArray =
        GitPktLine.line("# service=${service.serviceName}") + GitPktLine.flush +
            GitPktLine.encode("${head.hex} refs/heads/main".toByteArray() + 0.toByte() + (capabilities.joinToString(" ") + "\n").toByteArray()) +
            GitPktLine.flush

    private fun advertisement(service: GitService, vararg capabilities: String) = GitHttpResponse(
        200, mapOf("Content-Type" to "application/x-${service.serviceName}-advertisement"), advertisementBody(service, *capabilities),
    )

    private fun redirect(status: Int, location: String?) =
        GitHttpResponse(status, if (location == null) emptyMap() else mapOf("Location" to location), ByteArray(0))

    private fun <T> blocking(block: suspend () -> T): T = runBlocking { block() }

    @Test fun everyRequestCarriesTheBasicCredentialPreemptively() {
        val engine = ScriptedEngine { request ->
            when (request.method) {
                "GET" -> advertisement(GitService.UPLOAD_PACK, "side-band-64k")
                else -> GitHttpResponse(
                    200, mapOf("content-type" to "application/x-git-upload-pack-result"),
                    GitPktLine.line("NAK") + GitPktLine.encode(byteArrayOf(1) + "PACK".toByteArray()) + GitPktLine.flush,
                )
            }
        }
        val client = GitSmartHttpClient(remote, engine)
        blocking {
            val advertisement = client.discover(GitService.UPLOAD_PACK)
            assertEquals("PACK", client.fetchPack(head, emptyList(), advertisement).toString(Charsets.UTF_8))
        }
        // UTF-8, standard base64 with padding; the same on every host.
        val expected = "Basic " + Base64.getEncoder().encodeToString("user name:tökén:with:colons".toByteArray(Charsets.UTF_8))
        assertEquals(2, engine.requests.size)
        for (request in engine.requests) {
            assertEquals(
                listOf("Authorization" to expected, "User-Agent" to "git/2.0 (Snippets)", "Pragma" to "no-cache", "Cache-Control" to "no-cache"),
                request.headers.take(4),
            )
        }
        assertEquals("https://git.example/owner/repo/info/refs?service=git-upload-pack", engine.requests[0].url)
        assertEquals(listOf("Accept" to "*/*"), engine.requests[0].headers.drop(4))
        assertNull(engine.requests[0].body)
        assertEquals("https://git.example/owner/repo/git-upload-pack", engine.requests[1].url)
        assertEquals(
            listOf("Content-Type" to "application/x-git-upload-pack-request", "Accept" to "application/x-git-upload-pack-result"),
            engine.requests[1].headers.drop(4),
        )
        // 8 MiB for an advertisement, the pack limit for a pack.
        assertEquals(listOf(8L * 1024 * 1024, 128L * 1024 * 1024), engine.limits.toList())
        // Nothing about a request or a remote prints the credential or the address.
        for (text in listOf(engine.requests[0].toString(), remote.toString())) {
            assertTrue(!text.contains("tökén") && !text.contains(expected), text)
        }
        assertTrue(!engine.requests[0].toString().contains("git.example"))
    }

    @Test fun aPushReportIsLimitedLikeAnAdvertisement() {
        val engine = ScriptedEngine { request ->
            when (request.method) {
                "GET" -> advertisement(GitService.RECEIVE_PACK, "report-status")
                else -> GitHttpResponse(
                    200, mapOf("Content-Type" to "application/x-git-receive-pack-result"),
                    GitPktLine.line("unpack ok") + GitPktLine.line("ok refs/heads/main") + GitPktLine.flush,
                )
            }
        }
        val client = GitSmartHttpClient(remote, engine)
        val pack = "PACK".toByteArray()
        blocking { assertEquals(GitPushResult.UPDATED, client.push(head, head, pack, client.discover(GitService.RECEIVE_PACK))) }
        assertEquals(listOf(8L * 1024 * 1024, 8L * 1024 * 1024), engine.limits.toList())
        assertEquals("https://git.example/owner/repo/git-receive-pack", engine.requests[1].url)
        val body = engine.requests[1].body!!.toByteArray()
        assertTrue(body.toString(Charsets.ISO_8859_1).endsWith("0000PACK"))
    }

    @Test fun sameOriginRedirectsAreFollowedForDiscoveryAndRebaseTheService() {
        for ((location, expectedUrl) in listOf(
            "https://git.example/owner/repo.git/info/refs?service=git-upload-pack" to "https://git.example/owner/repo.git/info/refs?service=git-upload-pack",
            "/owner/repo.git/info/refs?service=git-upload-pack" to "https://git.example/owner/repo.git/info/refs?service=git-upload-pack",
            "../../repo.git/info/refs?service=git-upload-pack" to "https://git.example/owner/repo.git/info/refs?service=git-upload-pack",
            "https://GIT.example/owner/repo.git/info/refs?service=git-upload-pack" to "https://GIT.example/owner/repo.git/info/refs?service=git-upload-pack",
        )) {
            for (status in listOf(301, 302, 303, 307, 308)) {
                val engine = ScriptedEngine { request ->
                    if (request.url.contains("/repo/")) redirect(status, location) else advertisement(GitService.UPLOAD_PACK)
                }
                val advertisement = blocking { GitSmartHttpClient(remote, engine).discover(GitService.UPLOAD_PACK) }
                assertEquals(listOf("https://git.example/owner/repo/info/refs?service=git-upload-pack", expectedUrl), engine.requests.map { it.url })
                assertEquals("https://git.example/owner/repo.git", advertisement.serviceUrl?.lowercase())
                // The redirected request is the same request: same method, same headers.
                assertEquals(engine.requests[0].headers, engine.requests[1].headers)
                assertEquals("GET", engine.requests[1].method)
            }
        }
    }

    @Test fun redirectsElsewhereSurfaceAsTheirStatusAndAreNeverRequested() {
        for (location in listOf(
            "https://evil.example/owner/repo/info/refs",
            "http://git.example/owner/repo/info/refs",
            "https://git.example:8443/owner/repo/info/refs",
            // An explicit default port is another origin as Swift compares them.
            "https://git.example:443/owner/repo/info/refs",
            "//evil.example/owner/repo/info/refs",
            "https://git.example@evil.example/owner/repo/info/refs",
            "ssh://git.example/owner/repo",
            "not a url at all",
            null,
        )) {
            val engine = ScriptedEngine { redirect(302, location) }
            val failure = assertFailsWith<GitRemoteFailure>(location) { blocking { GitSmartHttpClient(remote, engine).discover(GitService.UPLOAD_PACK) } }
            assertEquals(GitRemoteFailure.ProtocolViolation("http_302"), failure, location)
            assertEquals(1, engine.requests.size, location)
        }
    }

    @Test fun aRedirectLoopEndsLikeUrlSessions() {
        val engine = ScriptedEngine { request -> redirect(301, request.url) }
        val failure = assertFailsWith<GitRemoteFailure> { blocking { GitSmartHttpClient(remote, engine).discover(GitService.UPLOAD_PACK) } }
        assertEquals(GitRemoteFailure.Unreachable("network_-1007"), failure)
        assertEquals(17, engine.requests.size)
    }

    @Test fun postsGoToTheRedirectedBaseAndNeverFollowARedirectThemselves() {
        val engine = ScriptedEngine { request ->
            if (request.method == "POST") redirect(308, "https://git.example/elsewhere") else advertisement(GitService.UPLOAD_PACK)
        }
        val client = GitSmartHttpClient(remote, engine)
        val redirected = GitRefAdvertisement(emptyMap(), emptyMap(), serviceUrl = "https://git.example/owner/repo.git")
        assertEquals(
            GitRemoteFailure.ProtocolViolation("http_308"),
            assertFailsWith<GitRemoteFailure> { blocking { client.fetchPack(head, emptyList(), redirected) } },
        )
        assertEquals(listOf("https://git.example/owner/repo.git/git-upload-pack"), engine.requests.map { it.url })
        // An advertisement without a service address (one made over SSH) uses the configured one.
        engine.requests.clear()
        assertFailsWith<GitRemoteFailure> { blocking { client.fetchPack(head, emptyList(), GitRefAdvertisement(emptyMap(), emptyMap())) } }
        assertEquals(listOf("https://git.example/owner/repo/git-upload-pack"), engine.requests.map { it.url })
        // One naming another origin never came from this client's discovery.
        engine.requests.clear()
        val foreign = GitRefAdvertisement(emptyMap(), mapOf("report-status" to null), serviceUrl = "https://evil.example/owner/repo")
        assertFailsWith<IllegalArgumentException> { blocking { client.fetchPack(head, emptyList(), foreign) } }
        assertFailsWith<IllegalArgumentException> { blocking { client.push(head, head, ByteArray(4), foreign) } }
        assertTrue(engine.requests.isEmpty())
    }

    @Test fun serviceUrlIsTheDiscoveryAddressWithoutItsSuffix() {
        assertEquals("https://h/o/r.git", GitSmartHttpClient.serviceUrl("https://h/o/r.git/info/refs?service=git-upload-pack"))
        assertEquals("https://h:8443/o/r", GitSmartHttpClient.serviceUrl("https://h:8443/o/r/info/refs"))
        assertEquals("http://[::1]:8080/r", GitSmartHttpClient.serviceUrl("http://[::1]:8080/r/info/refs?service=x"))
        assertNull(GitSmartHttpClient.serviceUrl("https://h/info/refs"))
        assertNull(GitSmartHttpClient.serviceUrl("https://h/o/r.git/info/refs/extra"))
        assertNull(GitSmartHttpClient.serviceUrl("https://h/o/r.git"))
        assertNull(GitSmartHttpClient.serviceUrl(null))
    }

    @Test fun retryAfterIsSecondsWithADefaultAndBounds() {
        assertEquals(30.0, GitSmartHttpClient.retryAfter(null))
        assertEquals(30.0, GitSmartHttpClient.retryAfter(""))
        assertEquals(30.0, GitSmartHttpClient.retryAfter("soon"))
        assertEquals(30.0, GitSmartHttpClient.retryAfter("NaN"))
        assertEquals(30.0, GitSmartHttpClient.retryAfter("Infinity"))
        assertEquals(30.0, GitSmartHttpClient.retryAfter("12f"))
        assertEquals(12.0, GitSmartHttpClient.retryAfter("12"))
        assertEquals(2.5, GitSmartHttpClient.retryAfter("2.5"))
        assertEquals(1.0, GitSmartHttpClient.retryAfter("-5"))
        assertEquals(1.0, GitSmartHttpClient.retryAfter("0.25"))
        assertEquals(3_600.0, GitSmartHttpClient.retryAfter("1e9"))
    }

    @Test fun engineFailuresStayClosedAndCancellationStaysCancellation() {
        fun failing(error: Exception) = GitSmartHttpClient(remote, ScriptedEngine { throw error })
        assertEquals(
            GitRemoteFailure.Unreachable("network"),
            assertFailsWith<GitRemoteFailure> { blocking { failing(IOException("connect to git.example failed")).discover(GitService.UPLOAD_PACK) } },
        )
        assertEquals(
            GitRemoteFailure.Unreachable("network_-1001"),
            assertFailsWith<GitRemoteFailure> { blocking { failing(GitRemoteFailure.Unreachable("network_-1001")).discover(GitService.UPLOAD_PACK) } },
        )
        assertEquals(
            GitRemoteFailure.ResponseTooLarge(),
            assertFailsWith<GitRemoteFailure> { blocking { failing(GitRemoteFailure.ResponseTooLarge()).discover(GitService.UPLOAD_PACK) } },
        )
        assertFailsWith<CancellationException> { blocking { failing(CancellationException("stop")).discover(GitService.UPLOAD_PACK) } }
    }

    @Test fun anSshRemoteHasNoHttpClient() {
        val ssh = GitRemote.ssh(GitSshLocation("git", "h", null, "r", scpStyle = true), "main")
        assertFailsWith<IllegalArgumentException> { GitSmartHttpClient(ssh, ScriptedEngine { redirect(500, null) }) }
    }
}
