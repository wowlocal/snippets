package com.khm.snippets.core.git.review

import com.khm.snippets.core.git.GitHttpEngine
import com.khm.snippets.core.git.GitHttpRequest
import com.khm.snippets.core.git.GitHttpResponse
import com.khm.snippets.core.git.GitRemote
import com.khm.snippets.core.git.GitRemoteFailure
import com.khm.snippets.core.git.GitService
import com.khm.snippets.core.git.GitSmartHttpClient
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Review: the redirect guard decides with its own URL parser (`HttpUrlParts`) and
 * `java.net.URI`, but the request is then made by OkHttp, which parses the address
 * again with different rules. If the two ever disagreed about the host, the Basic
 * credential would go to a host the guard never approved.
 *
 * These tests ask OkHttp's parser where each followed redirect would really connect.
 * They pass: no disagreement was found.
 */
class RedirectDifferentialTest {
    private class Recorder(private val location: String) : GitHttpEngine {
        val requests = CopyOnWriteArrayList<GitHttpRequest>()
        override suspend fun execute(request: GitHttpRequest, maximumResponseBytes: Long): GitHttpResponse {
            requests.add(request)
            return if (requests.size == 1) GitHttpResponse(302, mapOf("Location" to location), ByteArray(0))
            else GitHttpResponse(404, emptyMap(), ByteArray(0))
        }
    }

    private val remote = GitRemote.https("https://bitbucket.example/owner/repo", "main", "user", "secret-token")

    private var followed = 0

    /** Follows one redirect to `location` (or not) and checks every request made. */
    private fun check(location: String) {
        val engine = Recorder(location)
        val failure = runCatching { runBlocking { GitSmartHttpClient(remote, engine).discover(GitService.UPLOAD_PACK) } }.exceptionOrNull()
        assertTrue(failure is GitRemoteFailure, "${printable(location)}: $failure")
        for (request in engine.requests.drop(1)) {
            followed += 1
            // What OkHttp would do with the address the client asked for.
            val url = request.url.toHttpUrlOrNull()
            if (url == null) continue // OkHttp refuses it: `network_-1000`, nothing is sent.
            assertEquals("https", url.scheme, printable(location))
            assertEquals("bitbucket.example", url.host, printable(location))
            assertEquals(443, url.port, printable(location))
            assertEquals("", url.username, printable(location))
            assertEquals("", url.password, printable(location))
        }
    }

    private fun printable(text: String): String =
        text.map { if (it.code in 0x20..0x7e) it.toString() else "\\u%04x".format(it.code) }.joinToString("")

    @Test fun handPickedParserConfusionsNeverReachAnotherHost() {
        val host = "bitbucket.example"
        for (location in listOf(
            "https://$host@evil.example/x", "https://$host:443@evil.example/x", "https://evil.example#@$host/x",
            "https://$host#@evil.example/x", "https://$host?@evil.example/x", "https://$host\\@evil.example/x",
            "https://evil.example\\.$host/x", "https://$host\\.evil.example/x", "https:\\\\evil.example/x",
            "https:/\\evil.example/x", "/\\evil.example/x", "\\\\evil.example/x", "//evil.example/x", "///evil.example/x",
            "////evil.example/x", "https:evil.example/x", "https:/evil.example/x", "https:///evil.example/x",
            "https://$host.evil.example/x", "https://evil.example/$host", "https://$host%2eevil.example/x",
            "https://$host%00.evil.example/x", "https://$host\u0000.evil.example/x", "https://$host\t.evil.example/x",
            "https://$host\n.evil.example/x", "https://$host .evil.example/x", "https://$host。evil.example/x",
            "https://$host．evil.example/x", "https://$host․evil.example/x", "https://evil.example⁄$host/x",
            "https://evil.example／$host/x", "https://evil.example∕@$host/x", "https://$host:443/x", "https://$host:0443/x",
            "https://$host:8443/x", "https://$host:/x", "https://$host:+443/x", "https://$host:443:8443/x", "https://$host:65536/x",
            "https://$host:٤٤٣/x", "http://$host/x", "HTTP://$host/x", "hTtPs://evil.example/x", "ftp://$host/x",
            "https://[::1]/x", "https://[$host]/x", "https://$host]/x", "https://[$host/x", "https://bitbucKet.example/x",
            "https://BITBUCKET.EXAMPLE/x", "https://bıtbucket.example/x", "https://bitbucket.exаmple/x",
            "https://bitbucket.example./x", "https://.bitbucket.example/x", "https://xn--bitbucket.example/x",
            "https://user:pw@$host/x", "https://:@$host/x", "https://@$host/x", "https://$host/x@evil.example",
            "https://$host/\r\nHost: evil.example", "https://$host/x\r\nAuthorization: Basic eA==", " https://evil.example/x",
            "https://evil.example/x ", "javascript:alert(1)", "data:text/plain,x", "file:///etc/passwd", "", "?", "#", ".", "..",
            "../../../../x", "x", "https://", "https:", "://", "https://$host", "https://${host}evil.example",
        )) {
            check(location)
        }
        assertTrue(followed in 5..40, "followed $followed of the hand-picked redirects")
    }

    @Test fun randomLocationsNeverReachAnotherHost() {
        val random = Random(20261125)
        val pieces = listOf(
            "https://", "http://", "//", "/", "\\", ":", "@", "#", "?", "%", "%2e", "%2f", "%40", "%5c", "%00", ".", "..", "[", "]",
            "bitbucket.example", "evil.example", "BITBUCKET.EXAMPLE", "bitbucKet.example", "443", "8443", "0", "user", "x",
            "。", "／", "＠", "⁄", "\t", " ", "\u0000", " ", "​", "\ud83d", "\udc00", "\r\n",
        )
        repeat(20_000) {
            val location = (0 until 1 + random.nextInt(7)).joinToString("") { pieces[random.nextInt(pieces.size)] }
            check(location)
        }
        // Not vacuous: plenty of the random locations are same-origin and were followed.
        assertTrue(followed > 500, "followed $followed")
    }
}
