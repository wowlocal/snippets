package com.khm.snippets.core.git

import java.io.Closeable
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import java.net.UnknownServiceException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionSpec
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.Buffer
import okio.BufferedSink

/**
 * [GitHttpEngine] on OkHttp, configured so that OkHttp itself decides nothing:
 * redirects and connection retries are off, there is no cache, cookie jar or
 * authenticator, and TLS is 1.2 or newer.
 *
 * `allowsInsecureLoopback` is the **test seam** of [GitRemote.normalizedUrl]. Left
 * false (production), the engine has no cleartext connection spec and refuses every
 * address that is not `https`. Set true, it also talks plain `http` to a loopback
 * host and to nothing else.
 *
 * The timeouts mirror `URLSession`: `idleTimeoutMillis` is the time one connect, read
 * or write may stall; `requestTimeoutMillis` caps the whole exchange.
 */
class OkHttpGitHttpEngine(
    private val allowsInsecureLoopback: Boolean = false,
    idleTimeoutMillis: Long = 60_000,
    requestTimeoutMillis: Long = 600_000,
) : GitHttpEngine, Closeable {
    private val client: OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .cache(null)
        .connectionSpecs(
            if (allowsInsecureLoopback) listOf(ConnectionSpec.MODERN_TLS, ConnectionSpec.CLEARTEXT)
            else listOf(ConnectionSpec.MODERN_TLS),
        )
        .connectTimeout(idleTimeoutMillis, TimeUnit.MILLISECONDS)
        .readTimeout(idleTimeoutMillis, TimeUnit.MILLISECONDS)
        .writeTimeout(idleTimeoutMillis, TimeUnit.MILLISECONDS)
        .callTimeout(requestTimeoutMillis, TimeUnit.MILLISECONDS)
        .build()

    override suspend fun execute(request: GitHttpRequest, maximumResponseBytes: Long): GitHttpResponse {
        val call = client.newCall(buildRequest(request))
        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWithException(mapped(e))
                }

                override fun onResponse(call: Call, response: Response) {
                    val result = try {
                        response.use { read(call, it, maximumResponseBytes) }
                    } catch (failure: GitRemoteFailure) {
                        continuation.resumeWithException(failure)
                        return
                    } catch (e: IOException) {
                        continuation.resumeWithException(mapped(e))
                        return
                    }
                    continuation.resume(result)
                }
            })
        }
    }

    /** Releases idle connections and the dispatcher's threads. In-flight calls are cancelled. */
    override fun close() {
        client.dispatcher.cancelAll()
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }

    private fun buildRequest(request: GitHttpRequest): Request {
        val parts = HttpUrlParts.parse(request.url)
        val permitted = parts != null && (
            parts.scheme == "https" ||
                (parts.scheme == "http" && allowsInsecureLoopback && GitUrlNormalizer.isLoopbackHost(parts.host))
            )
        // -1022 is URLSession's "a secure connection is required", -1000 its "bad URL".
        if (!permitted) throw GitRemoteFailure.Unreachable("network_-1022")
        val builder = try {
            Request.Builder().url(request.url)
        } catch (_: IllegalArgumentException) {
            throw GitRemoteFailure.Unreachable("network_-1000")
        }
        for ((name, value) in request.headers) builder.header(name, value)
        val body = request.body
        builder.method(request.method, if (body != null) WireRequestBody(body) else null)
        return builder.build()
    }

    private fun read(call: Call, response: Response, maximumBytes: Long): GitHttpResponse {
        val headers = LinkedHashMap<String, String>()
        for ((name, value) in response.headers) headers.putIfAbsent(name.lowercase(), value)
        // Only a successful answer is worth its body; an error page is never buffered.
        if (response.code != 200) return GitHttpResponse(response.code, headers, ByteArray(0))
        val body = response.body
        if (body.contentLength() > maximumBytes) {
            call.cancel()
            throw GitRemoteFailure.ResponseTooLarge()
        }
        // `source()` yields the bytes after OkHttp's transparent gzip decoding, so the
        // limit applies to what would be held in memory, not to what crossed the wire.
        val source = body.source()
        val buffer = Buffer()
        while (source.read(buffer, READ_CHUNK) != -1L) {
            if (buffer.size > maximumBytes) {
                call.cancel()
                throw GitRemoteFailure.ResponseTooLarge()
            }
        }
        return GitHttpResponse(response.code, headers, buffer.readByteArray())
    }

    /** A fixed-length body written straight from the request's parts. */
    private class WireRequestBody(private val body: GitWireBody) : RequestBody() {
        // The request's own `Content-Type` header is sent as given.
        override fun contentType(): MediaType? = null
        override fun contentLength(): Long = body.size
        override fun writeTo(sink: BufferedSink) = body.writeTo(sink.outputStream())
    }

    private companion object {
        const val READ_CHUNK = 64L * 1024

        /**
         * Closed codes only. The numbers are `URLError` codes, so one network problem
         * reads the same in every platform's status: -1001 timed out, -1003 host not
         * found, -1004 cannot connect, -1200 TLS failure, -1022 cleartext refused,
         * -1005 connection lost.
         */
        fun mapped(error: IOException): GitRemoteFailure = GitRemoteFailure.Unreachable(
            when (error) {
                is InterruptedIOException -> "network_-1001"
                is UnknownHostException -> "network_-1003"
                is ConnectException, is NoRouteToHostException -> "network_-1004"
                is SSLException -> "network_-1200"
                is UnknownServiceException -> "network_-1022"
                else -> "network_-1005"
            },
        )
    }
}
