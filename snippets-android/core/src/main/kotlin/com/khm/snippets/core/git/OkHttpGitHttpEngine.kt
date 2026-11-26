package com.khm.snippets.core.git

import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import java.net.UnknownServiceException
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionSpec
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink

/**
 * [GitHttpEngine] on OkHttp, configured so that OkHttp decides as little as it can:
 * no redirects, no cache, cookie jar or authenticator, TLS 1.2 or newer.
 *
 * Two things it does on its own, both invisible to the server's state. It replaces a
 * pooled connection that turns out to be dead (a host that closed an idle connection
 * must not fail every other poll). And it never sends a request body twice: the body
 * is one-shot, so a POST that has begun is not replayed by any of OkHttp's retry or
 * follow-up paths, and the answers OkHttp would otherwise act on by itself (408, and
 * 503 with `Retry-After: 0`) are handed to the caller unanswered.
 *
 * `allowsInsecureLoopback` is the **test seam** of [GitRemote.normalizedUrl]. Left
 * false (production), the engine has no cleartext connection spec and refuses every
 * address that is not `https`. Set true, it also talks plain `http` to a loopback
 * host and to nothing else.
 *
 * The timeouts mirror `URLSession`: `idleTimeoutMillis` is the time one connect, read
 * or write may stall; `requestTimeoutMillis` caps the whole exchange.
 *
 * Main-safe: all network I/O, including closing sockets on cancellation and in
 * [close], runs on OkHttp's own threads.
 */
class OkHttpGitHttpEngine internal constructor(
    private val allowsInsecureLoopback: Boolean,
    idleTimeoutMillis: Long,
    requestTimeoutMillis: Long,
    /** Test seam: trust for a test certificate, an instrumented socket factory. */
    configure: (OkHttpClient.Builder) -> Unit,
) : GitHttpEngine, Closeable {
    constructor(
        allowsInsecureLoopback: Boolean = false,
        idleTimeoutMillis: Long = 60_000,
        requestTimeoutMillis: Long = 600_000,
    ) : this(allowsInsecureLoopback, idleTimeoutMillis, requestTimeoutMillis, {})

    private val client: OkHttpClient = OkHttpClient.Builder()
        .apply(configure)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(true)
        .cache(null)
        .connectionSpecs(
            if (allowsInsecureLoopback) listOf(ConnectionSpec.MODERN_TLS, ConnectionSpec.CLEARTEXT)
            else listOf(ConnectionSpec.MODERN_TLS),
        )
        .connectTimeout(idleTimeoutMillis, TimeUnit.MILLISECONDS)
        .readTimeout(idleTimeoutMillis, TimeUnit.MILLISECONDS)
        .writeTimeout(idleTimeoutMillis, TimeUnit.MILLISECONDS)
        .callTimeout(requestTimeoutMillis, TimeUnit.MILLISECONDS)
        .addInterceptor(ClosedFailures)
        .addNetworkInterceptor(NoFollowUp)
        .build()

    override suspend fun execute(request: GitHttpRequest, maximumResponseBytes: Long): GitHttpResponse {
        val call = client.newCall(buildRequest(request))
        return suspendCancellableCoroutine { continuation ->
            // Cancelling closes the socket, which must not happen on the caller's thread.
            continuation.invokeOnCancellation { offTheCallersThread { call.cancel() } }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWithException(closed(e))
                }

                // Nothing may leave this callback: it runs on OkHttp's dispatcher
                // thread, where an exception would be uncaught (and, on Android, end
                // the process) while the caller waited for ever.
                override fun onResponse(call: Call, response: Response) {
                    val result = try {
                        response.use { read(call, it, maximumResponseBytes) }
                    } catch (error: Throwable) {
                        continuation.resumeWithException(closed(error))
                        if (error is VirtualMachineError || error is LinkageError) throw error
                        return
                    }
                    continuation.resume(result)
                }
            })
        }
    }

    /** Stops accepting requests; cancels the ones in flight and drops idle connections. */
    override fun close() {
        val executor = client.dispatcher.executorService
        offTheCallersThread {
            client.dispatcher.cancelAll()
            client.connectionPool.evictAll()
        }
        executor.shutdown()
    }

    private fun offTheCallersThread(work: () -> Unit) {
        try {
            client.dispatcher.executorService.execute(work)
        } catch (_: RejectedExecutionException) {
            // Closed already: its last task cancels every call and empties the pool.
        }
    }

    private fun buildRequest(request: GitHttpRequest): Request {
        val parts = HttpUrlParts.parse(request.url)
        val permitted = parts != null && (
            parts.scheme == "https" ||
                (parts.scheme == "http" && allowsInsecureLoopback && GitUrlNormalizer.isLoopbackHost(parts.host))
            )
        // -1022 is URLSession's "a secure connection is required", -1000 its "bad URL".
        if (!permitted) throw GitRemoteFailure.Unreachable("network_-1022")
        try {
            val builder = Request.Builder().url(request.url)
            for ((name, value) in request.headers) builder.header(name, value)
            val body = request.body
            builder.method(request.method, if (body != null) WireRequestBody(body) else null)
            return builder.build()
        } catch (_: IllegalArgumentException) {
            // An address, a method or a header value OkHttp will not send.
            throw GitRemoteFailure.Unreachable("network_-1000")
        }
    }

    private fun read(call: Call, response: Response, maximumBytes: Long): GitHttpResponse {
        val headers = LinkedHashMap<String, String>()
        for ((name, value) in response.headers) headers.putIfAbsent(name.lowercase(), value)
        NoFollowUp.restore(response.code, headers)
        // Only a successful answer is worth its body; an error page is never buffered.
        if (response.code != 200) return GitHttpResponse(response.code, headers, ByteArray(0))
        val limit = minOf(maximumBytes, MAXIMUM_ARRAY_BYTES)
        val body = response.body
        val declared = body.contentLength()
        if (declared > limit) {
            call.cancel()
            throw GitRemoteFailure.ResponseTooLarge()
        }
        // `source()` yields the bytes after OkHttp's transparent gzip decoding, so the
        // limit applies to what would be held in memory, not to what crossed the wire.
        val source = body.source()
        if (declared >= 0) {
            // The usual case for a push report: one buffer of the exact size.
            val bytes = ByteArray(declared.toInt())
            try {
                source.readFully(bytes)
            } catch (_: EOFException) {
                throw GitRemoteFailure.Unreachable("network_-1005")
            }
            return GitHttpResponse(response.code, headers, bytes)
        }
        // No declared length (a pack is sent chunked): gathered in blocks and joined
        // once, each block released as it is copied.
        val accumulator = ByteAccumulator()
        val chunk = ByteArray(READ_CHUNK)
        while (true) {
            val count = source.read(chunk)
            if (count < 0) break
            accumulator.append(chunk, 0, count)
            if (accumulator.size > limit) {
                call.cancel()
                throw GitRemoteFailure.ResponseTooLarge()
            }
        }
        return GitHttpResponse(response.code, headers, accumulator.drain())
    }

    /**
     * A fixed-length body written straight from the request's parts. One-shot: once
     * its first byte may have left, OkHttp must not send it again, whatever went
     * wrong and whatever the server answered.
     */
    private class WireRequestBody(private val body: GitWireBody) : RequestBody() {
        // The request's own `Content-Type` header is sent as given.
        override fun contentType(): MediaType? = null
        override fun contentLength(): Long = body.size
        override fun isOneShot(): Boolean = true
        override fun writeTo(sink: BufferedSink) = body.writeTo(sink.outputStream())
    }

    /**
     * Outermost in the chain. OkHttp reports an `IOException` to the callback, but
     * anything else thrown while it works (by its own code on a malformed answer, or
     * by a request body) it rethrows on its dispatcher thread after telling the
     * callback, which on Android ends the process. Turned into an I/O failure here,
     * it ends as the closed `network` failure and nothing more.
     */
    private object ClosedFailures : Interceptor {
        class StackFailure : IOException("http stack failure")

        override fun intercept(chain: Interceptor.Chain): Response = try {
            chain.proceed(chain.request())
        } catch (failure: IOException) {
            throw failure
        } catch (_: RuntimeException) {
            // No cause attached: its message may quote the server.
            throw StackFailure()
        }
    }

    /**
     * OkHttp re-sends a request by itself when the answer is 408, or 503 with
     * `Retry-After: 0`. Retrying is the sync engine's decision (and one request per
     * poll is an invariant), so those two answers reach OkHttp's follow-up logic with
     * a `Retry-After` it does not act on, and the real value is put back afterwards.
     */
    private object NoFollowUp : Interceptor {
        private const val STASH = "x-snippets-retry-after"

        override fun intercept(chain: Interceptor.Chain): Response {
            val response = chain.proceed(chain.request())
            if (response.code != 408 && response.code != 503) return response
            val original = response.header("Retry-After")
            val builder = response.newBuilder().removeHeader(STASH).header("Retry-After", "1")
            if (original != null) builder.header(STASH, original)
            return builder.build()
        }

        fun restore(status: Int, headers: MutableMap<String, String>) {
            if (status != 408 && status != 503) return
            val original = headers.remove(STASH)
            if (original != null) headers["retry-after"] = original else headers.remove("retry-after")
        }
    }

    private companion object {
        const val READ_CHUNK = 64 * 1024

        /** No response can be larger than one array; the limits asked for are far below this. */
        const val MAXIMUM_ARRAY_BYTES = Int.MAX_VALUE - 64L

        /**
         * Closed codes only. The numbers are `URLError` codes, so one network problem
         * reads the same in every platform's status: -1001 timed out, -1003 host not
         * found, -1004 cannot connect, -1200 TLS failure, -1022 cleartext refused,
         * -1005 connection lost. Anything that is not an I/O failure (a response
         * OkHttp itself trips over) is the bare `network`.
         */
        fun closed(error: Throwable): GitRemoteFailure = when {
            error is GitRemoteFailure -> error
            // OkHttp tries every address of a host and reports the first failure with
            // the others attached. A host that was reached and failed TLS is the one
            // to report, not a sibling address that refused the connection.
            error is SSLException || error.suppressed.any { it is SSLException } -> GitRemoteFailure.Unreachable("network_-1200")
            else -> closedByType(error)
        }

        private fun closedByType(error: Throwable): GitRemoteFailure = when (error) {
            is InterruptedIOException -> GitRemoteFailure.Unreachable("network_-1001")
            is UnknownHostException -> GitRemoteFailure.Unreachable("network_-1003")
            is ConnectException, is NoRouteToHostException -> GitRemoteFailure.Unreachable("network_-1004")
            is UnknownServiceException -> GitRemoteFailure.Unreachable("network_-1022")
            is ClosedFailures.StackFailure -> GitRemoteFailure.Unreachable("network")
            is IOException -> GitRemoteFailure.Unreachable("network_-1005")
            else -> GitRemoteFailure.Unreachable("network")
        }
    }
}
