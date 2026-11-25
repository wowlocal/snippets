package com.khm.snippets.core.git.testing

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * Serves smart HTTP from real bare repositories by running `git http-backend` as a
 * CGI program for every request, behind a loopback HTTP server. Tests therefore
 * exercise the server-side upload-pack/receive-pack implementation every host is
 * derived from, and the client's real HTTP engine.
 *
 * The Kotlin counterpart of `GitHTTPBackendProtocol` in `Tests/Core/GitTestServer.swift`
 * (and of `scripts/git-http-test-server.py`): the same Basic credential check, request
 * log, redirect rule, recorded `Authorization` headers and receive-pack hook, plus a
 * fault hook that answers a request without the backend.
 */
class GitTestServer(
    /** The directory containing the bare repositories. */
    private val projectRoot: File,
    val username: String,
    val password: String,
) : Closeable {
    class RecordedRequest(
        val method: String,
        val path: String,
        val query: String?,
        /** Lowercase names. */
        val headers: Map<String, List<String>>,
        val body: ByteArray,
    ) {
        fun header(name: String): String? = headers[name.lowercase()]?.firstOrNull()

        /** `"<METHOD> <last path component>[?<service>]"`, the form the Swift tests assert on. */
        val summary: String
            get() {
                val service = query?.split('&')?.firstOrNull { it.startsWith("service=") }?.removePrefix("service=")
                return "$method ${path.substringAfterLast('/')}" + (if (service != null) "?$service" else "")
            }
    }

    /**
     * Answers every request for a path outside `prefix` with `status` and a
     * `Location` of `base` + the same suffix, like a host that canonicalizes `.git`.
     */
    class Redirect(val prefix: String, val base: String, val status: Int = 301)

    /**
     * A canned answer. `delayMillis` passes before anything is sent; with
     * `trickleBytes > 0` the body goes out in pieces of that size, `trickleDelayMillis`
     * apart, without a declared length.
     */
    class Response(
        val status: Int,
        val headers: Map<String, String> = emptyMap(),
        val body: ByteArray = ByteArray(0),
        val delayMillis: Long = 0,
        val trickleBytes: Int = 0,
        val trickleDelayMillis: Long = 0,
        /** Declares this `Content-Length` whatever the body is. */
        val declaredLength: Long? = null,
    )

    private val server = HttpServer.create(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0)
    private val executor = Executors.newCachedThreadPool { task -> Thread(task, "git-test-server").apply { isDaemon = true } }
    private val log = CopyOnWriteArrayList<String>()
    private val recordedRequests = CopyOnWriteArrayList<RecordedRequest>()
    private val authorizations = CopyOnWriteArrayList<String>()
    private val receivePackHook = AtomicReference<(() -> Unit)?>(null)

    val port: Int get() = server.address.port

    /** `http://127.0.0.1:<port>`. */
    val origin: String get() = "http://127.0.0.1:$port"

    /** One line per request; a redirected request is logged as `REDIRECT <METHOD> <path>`. */
    val requests: List<String> get() = log.toList()

    /** Every request that was not redirected, with its headers and body. */
    val recorded: List<RecordedRequest> get() = recordedRequests.toList()

    /** The `Authorization` header of every request, redirected or not (empty when absent). */
    val authorizationHeaders: List<String> get() = authorizations.toList()

    @Volatile var redirect: Redirect? = null

    /** Fault hook: a non-null result is sent instead of asking the backend (and before the credential check). */
    @Volatile var intercept: ((RecordedRequest) -> Response?)? = null

    /** Fault hook: rewrites the backend's answer, for example to compress it. */
    @Volatile var transform: ((RecordedRequest, Response) -> Response)? = null

    init {
        server.executor = executor
        server.createContext("/") { exchange ->
            try {
                handle(exchange)
            } catch (_: IOException) {
                // The client went away (a cancelled or timed-out request).
            } finally {
                exchange.close()
            }
        }
        server.start()
    }

    /** Runs once, immediately before the next receive-pack request is handled. */
    fun beforeNextReceivePack(hook: () -> Unit) {
        receivePackHook.set(hook)
    }

    fun clearRequests() {
        log.clear()
        recordedRequests.clear()
        authorizations.clear()
    }

    override fun close() {
        server.stop(0)
        executor.shutdownNow()
    }

    private fun handle(exchange: HttpExchange) {
        val method = exchange.requestMethod
        val path = exchange.requestURI.rawPath
        val query = exchange.requestURI.rawQuery
        val headers = exchange.requestHeaders.entries.associate { it.key.lowercase() to it.value.toList() }
        authorizations.add(headers["authorization"]?.firstOrNull() ?: "")

        redirect?.let { rule ->
            if (!path.startsWith(rule.prefix)) {
                log.add("REDIRECT $method $path")
                val suffix = path.split('/').filter { it.isNotEmpty() }.drop(1).joinToString("/")
                val target = rule.base + "/" + suffix + (if (query != null) "?$query" else "")
                exchange.requestBody.readBytes()
                send(exchange, Response(rule.status, mapOf("Location" to target)))
                return
            }
        }

        val request = RecordedRequest(method, path, query, headers, exchange.requestBody.readBytes())
        log.add(request.summary)
        recordedRequests.add(request)
        val hook = if (method == "POST" && path.endsWith("/git-receive-pack")) receivePackHook.getAndSet(null) else null

        intercept?.invoke(request)?.let {
            send(exchange, it)
            return
        }

        val expected = "Basic " + Base64.getEncoder().encodeToString("$username:$password".toByteArray())
        if (request.header("Authorization") != expected) {
            send(
                exchange,
                Response(
                    401,
                    mapOf("WWW-Authenticate" to "Basic realm=\"test\"", "Content-Type" to "text/plain"),
                    "unauthorized".toByteArray(),
                ),
            )
            return
        }
        hook?.invoke()
        val answer = backend(request)
        send(exchange, transform?.invoke(request, answer) ?: answer)
    }

    /** One `git http-backend` run, exactly as a CGI host would start it. */
    private fun backend(request: RecordedRequest): Response {
        val scratch = Files.createTempDirectory("git-cgi-").toFile()
        try {
            val environment = GitBinary.isolatedEnvironment(scratch).toMutableMap()
            environment["GIT_PROJECT_ROOT"] = projectRoot.path
            environment["GIT_HTTP_EXPORT_ALL"] = "1"
            environment["PATH_INFO"] = request.path
            environment["QUERY_STRING"] = request.query ?: ""
            environment["REQUEST_METHOD"] = request.method
            // http-backend enables receive-pack only for an authenticated user.
            environment["REMOTE_USER"] = username
            environment["REMOTE_ADDR"] = "127.0.0.1"
            request.header("Content-Type")?.let { environment["CONTENT_TYPE"] = it }
            if (request.method == "POST") environment["CONTENT_LENGTH"] = request.body.size.toString()

            val input = File(scratch, "stdin").apply { writeBytes(request.body) }
            val builder = ProcessBuilder(GitBinary.path!!, "http-backend")
                .redirectInput(input)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
            builder.environment().clear()
            builder.environment().putAll(environment)
            val process = builder.start()
            val raw = process.inputStream.readBytes()
            process.waitFor()

            var separator = indexOf(raw, "\r\n\r\n".toByteArray())
            var skip = 4
            if (separator < 0) {
                separator = indexOf(raw, "\n\n".toByteArray())
                skip = 2
            }
            if (separator < 0) return Response(500, mapOf("Content-Type" to "text/plain"), "backend failed".toByteArray())
            var status = 200
            val headers = LinkedHashMap<String, String>()
            for (line in String(raw, 0, separator, Charsets.ISO_8859_1).lines()) {
                val colon = line.indexOf(':')
                if (colon <= 0) continue
                val name = line.substring(0, colon)
                val value = line.substring(colon + 1).trim()
                if (name.equals("Status", ignoreCase = true)) status = value.take(3).toIntOrNull() ?: 500 else headers[name] = value
            }
            return Response(status, headers, raw.copyOfRange(separator + skip, raw.size))
        } finally {
            scratch.deleteRecursively()
        }
    }

    private fun send(exchange: HttpExchange, response: Response) {
        if (response.delayMillis > 0) Thread.sleep(response.delayMillis)
        for ((name, value) in response.headers) {
            if (name.equals("Content-Length", ignoreCase = true) || name.equals("Transfer-Encoding", ignoreCase = true)) continue
            exchange.responseHeaders.add(name, value)
        }
        val body = response.body
        if (response.trickleBytes > 0) {
            exchange.sendResponseHeaders(response.status, 0)
            val out = exchange.responseBody
            var offset = 0
            while (offset < body.size) {
                val count = minOf(response.trickleBytes, body.size - offset)
                out.write(body, offset, count)
                out.flush()
                offset += count
                if (response.trickleDelayMillis > 0) Thread.sleep(response.trickleDelayMillis)
            }
            return
        }
        val declared = response.declaredLength ?: body.size.toLong()
        exchange.sendResponseHeaders(response.status, if (declared == 0L) -1 else declared)
        if (body.isNotEmpty()) exchange.responseBody.write(body)
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        outer@ for (start in 0..haystack.size - needle.size) {
            for (index in needle.indices) if (haystack[start + index] != needle[index]) continue@outer
            return start
        }
        return -1
    }
}
