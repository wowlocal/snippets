package com.khm.snippets.core.git.review

import com.khm.snippets.core.git.GitHttpRequest
import com.khm.snippets.core.git.GitObjectId
import com.khm.snippets.core.git.GitObjectType
import com.khm.snippets.core.git.GitPktLine
import com.khm.snippets.core.git.GitRefAdvertisement
import com.khm.snippets.core.git.GitRemote
import com.khm.snippets.core.git.GitRemoteFailure
import com.khm.snippets.core.git.GitService
import com.khm.snippets.core.git.GitSmartHttpClient
import com.khm.snippets.core.git.OkHttpGitHttpEngine
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * Review: `OkHttpGitHttpEngine` and `GitSmartHttpClient` against a server that does
 * not play by the rules. The engine's contract (`GitHttpEngine`) is that every
 * exchange ends, with a closed `GitRemoteFailure` when it fails, and that the HTTP
 * stack retries nothing on its own.
 *
 * Tests marked "failed before the fix" demonstrated a defect of the reviewed code; they
 * pass now and guard the fix.
 */
class HttpEngineHostileServerTest {
    private val advertisementType = "application/x-git-upload-pack-advertisement"

    private fun remote(server: RawHttpServer) =
        GitRemote.https("${server.origin}/repo.git", "main", "user", "token-value", allowsInsecureLoopback = true)

    /** Runs `block`, recording anything that dies on another thread while it runs. */
    private fun <T> watchingOtherThreads(block: (List<Pair<String, Throwable>>) -> T): T {
        val uncaught = CopyOnWriteArrayList<Pair<String, Throwable>>()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error -> uncaught.add(thread.name to error) }
        try {
            return block(uncaught)
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(previous)
        }
    }

    /**
     * Failed before the fix.
     *
     * A 200 answer with `Content-Length: -5`. OkHttp builds a fixed-length source with
     * a negative length and okio then throws `IllegalArgumentException("byteCount < 0")`
     * from `source.read`. `OkHttpGitHttpEngine.onResponse` catches only
     * `GitRemoteFailure` and `IOException` (OkHttpGitHttpEngine.kt:69-77), so the
     * exception leaves the callback: the continuation is never resumed (the caller
     * waits for ever, or until it is cancelled) and the exception is uncaught on the
     * "OkHttp Dispatcher" thread, which on Android ends the process.
     *
     * The status does not matter: for 401, 404, 302 and 503 the same exception comes
     * out of `response.use { }` when the unread body is closed.
     */
    @Test fun aNegativeContentLengthIsAClosedFailureNotAHangAndADeadDispatcherThread() {
        val problems = ArrayList<String>()
        for (status in listOf("200 OK", "404 Not Found", "302 Found")) {
            RawHttpServer { RawHttpServer.Answer("HTTP/1.1 $status\r\nContent-Type: $advertisementType\r\nContent-Length: -5\r\n\r\n0000", 500) }.use { server ->
                OkHttpGitHttpEngine(allowsInsecureLoopback = true, idleTimeoutMillis = 3_000).use { engine ->
                    watchingOtherThreads { uncaught ->
                        val outcome = runCatching {
                            runBlocking { withTimeout(3_000) { GitSmartHttpClient(remote(server), engine).discover(GitService.UPLOAD_PACK) } }
                        }
                        val died = uncaught.joinToString { "${it.second.javaClass.simpleName} on thread \"${it.first}\"" }
                        val error = outcome.exceptionOrNull()
                        when {
                            error is TimeoutCancellationException ->
                                problems.add("$status: discover() never completed (cancelled by the test after 3 s); uncaught meanwhile: [$died]")
                            uncaught.isNotEmpty() -> problems.add("$status: uncaught: [$died]")
                            // Reading it as an unknown length, or refusing it, are both acceptable.
                            error != null && error !is GitRemoteFailure -> problems.add("$status: $error")
                        }
                    }
                }
            }
        }
        assertTrue(problems.isEmpty(), problems.joinToString("\n", prefix = "\n"))
    }

    /**
     * Failed before the fix.
     *
     * The engine sets `retryOnConnectionFailure(false)` (OkHttpGitHttpEngine.kt:47),
     * which also turns off OkHttp's recovery from a stale pooled connection. OkHttp
     * keeps an idle HTTP/1.1 connection for five minutes and reuses it for a GET
     * without probing it (a POST is probed only after ten idle seconds). A host that
     * closes idle connections sooner (nginx: 75 s, Apache: 5 s, most load balancers:
     * 60 s) therefore makes the next discovery fail with `network_-1005` although the
     * host is up; the failure evicts the connection, so with a poll slower than the
     * host's keep-alive every second round fails. HTTP/2 hosts are not affected: they
     * announce the close. `URLSession` re-sends an idempotent request that dies on a
     * reused connection before any answer.
     */
    @Test fun aStalePooledConnectionDoesNotFailTheNextDiscovery() {
        val body = RawHttpServer.ok(advertisementType, GitPktLine.flush, "Connection: keep-alive\r\n")
        // The host answers, keeps the connection for 150 ms, then closes it.
        RawHttpServer { RawHttpServer.Answer(body, closeAfterMillis = 150) }.use { server ->
            OkHttpGitHttpEngine(allowsInsecureLoopback = true).use { engine ->
                val client = GitSmartHttpClient(remote(server), engine)
                runBlocking { withTimeout(10_000) { client.discover(GitService.UPLOAD_PACK) } }
                Thread.sleep(700)
                val second = runCatching { runBlocking { withTimeout(10_000) { client.discover(GitService.UPLOAD_PACK) } } }
                assertTrue(
                    second.isSuccess,
                    "second discovery: ${second.exceptionOrNull()} " +
                        "(connections accepted: ${server.connections}, requests that reached the host: ${server.requests.size})",
                )
            }
        }
    }

    /**
     * Failed before the fix.
     *
     * `GitHttpEngine` promises "no redirect following, no retry", and the porting
     * brief (hazard 13) says "never let the client retry a POST". OkHttp's
     * `RetryAndFollowUpInterceptor` re-sends a request answered with 503 and
     * `Retry-After: 0` once, whatever `retryOnConnectionFailure` says, and
     * `WireRequestBody` is replayable, so a push is uploaded twice.
     */
    @Test fun aPostAnsweredWith503AndRetryAfterZeroIsSentOnce() {
        RawHttpServer { RawHttpServer.Answer("HTTP/1.1 503 Busy\r\nRetry-After: 0\r\nContent-Length: 0\r\n\r\n") }.use { server ->
            OkHttpGitHttpEngine(allowsInsecureLoopback = true).use { engine ->
                val client = GitSmartHttpClient(remote(server), engine)
                val head = GitObjectId.hash(GitObjectType.BLOB, "x".toByteArray())
                val advertisement = GitRefAdvertisement(mapOf("refs/heads/main" to head), mapOf("report-status" to null))
                val failure = runCatching {
                    runBlocking { withTimeout(10_000) { client.push(head, head, "PACK-BYTES".toByteArray(), advertisement) } }
                }.exceptionOrNull()
                assertEquals(GitRemoteFailure.RateLimited(1.0), failure)
                val posts = server.requests.filter { it.method == "POST" }
                assertEquals(1, posts.size, "git-receive-pack requests that reached the host (each carried the pack)")
            }
        }
    }

    /** Everything else a broken host can send ends as a closed failure, promptly. */
    @Test fun malformedResponsesEndAsClosedFailuresAndNeverHang() {
        val cases = listOf(
            "bad status line" to "HTTP/1.1 abc OK\r\n\r\n",
            "not http" to "\u0000\u0001\u0002garbage\r\n\r\n",
            "bare body" to "0000",
            "status 1" to "HTTP/1.1 1 X\r\nContent-Length: 0\r\n\r\n",
            "negative status" to "HTTP/1.1 -200 X\r\nContent-Length: 0\r\n\r\n",
            "bad chunk size" to "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n",
            "chunk size overflow" to "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffffff\r\nhello\r\n0\r\n\r\n",
            "negative chunk size" to "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n",
            "body shorter than declared" to "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nhello",
            "not gzip" to "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello",
            "204 with a body" to "HTTP/1.1 204 No\r\nContent-Length: 5\r\n\r\nhello",
            "407 without a proxy" to "HTTP/1.1 407 Proxy\r\nProxy-Authenticate: Basic realm=x\r\nContent-Length: 0\r\n\r\n",
        )
        for ((name, response) in cases) {
            RawHttpServer { RawHttpServer.Answer(response, closeAfterMillis = 200) }.use { server ->
                OkHttpGitHttpEngine(allowsInsecureLoopback = true, idleTimeoutMillis = 3_000).use { engine ->
                    watchingOtherThreads { uncaught ->
                        val request = GitHttpRequest("GET", "${server.origin}/repo.git/info/refs", listOf("Authorization" to "Basic eA=="))
                        val failure = runCatching { runBlocking { withTimeout(8_000) { engine.execute(request, 1024) } } }.exceptionOrNull()
                        assertIs<GitRemoteFailure.Unreachable>(failure, name)
                        assertTrue(failure.detail.startsWith("network"), "$name: ${failure.detail}")
                        assertTrue(uncaught.isEmpty(), "$name: $uncaught")
                    }
                }
            }
        }
        // Lengths OkHttp cannot read are treated as unknown: the body runs to the end of the connection.
        for (header in listOf("Content-Length: 99999999999999999999999", "Content-Length: 4\r\nContent-Length: 5")) {
            RawHttpServer { RawHttpServer.Answer("HTTP/1.1 200 OK\r\n$header\r\n\r\n0000X", closeAfterMillis = 200) }.use { server ->
                OkHttpGitHttpEngine(allowsInsecureLoopback = true, idleTimeoutMillis = 3_000).use { engine ->
                    val request = GitHttpRequest("GET", "${server.origin}/repo.git/info/refs", emptyList())
                    val response = runBlocking { withTimeout(8_000) { engine.execute(request, 1024) } }
                    assertEquals("0000X", response.body.toString(Charsets.ISO_8859_1), header)
                }
            }
        }
    }
}
