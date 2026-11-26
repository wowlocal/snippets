package com.khm.snippets.core.git

import java.net.URI
import java.util.Base64
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The two smart-HTTP services, using protocol v0/v1 framing. Every host still speaks
 * it, and `git-receive-pack` has no protocol-v2 equivalent, so one code path covers
 * both directions.
 *
 * Authentication is the same for every host: HTTP Basic with the remote's user name
 * and token, sent pre-emptively on every request.
 *
 * Main-safe: the engine does the network I/O on its own threads, and requests are
 * built and responses parsed on `cpuDispatcher`. Constructing it for an SSH remote
 * throws [GitRemoteConfigurationException].
 */
class GitSmartHttpClient(
    val remote: GitRemote,
    private val engine: GitHttpEngine,
    private val maximumPackBytes: Long = GitPack.Limits.current().maximumPackBytes,
    private val cpuDispatcher: CoroutineDispatcher = Dispatchers.Default,
) : GitWireClient {
    private val baseUrl: GitHttpsUrl =
        remote.url ?: throw GitRemoteConfigurationException(GitRemote.Failure.INVALID_URL)

    private class Sent(val response: GitHttpResponse, val finalUrl: String)

    // MARK: Discovery

    override suspend fun discover(service: GitService): GitRefAdvertisement {
        val sent = send(
            method = "GET",
            url = "$baseUrl/info/refs?service=${service.serviceName}",
            headers = listOf("Accept" to "*/*"),
            body = null,
            maximumBytes = GitWire.MAXIMUM_ADVERTISEMENT_BYTES,
        )
        if (mediaType(sent.response) != "application/x-${service.serviceName}-advertisement") {
            // A "dumb" HTTP server, a login page, or a proxy error document.
            throw GitRemoteFailure.UnsupportedServer("not_smart_http")
        }
        return withContext(cpuDispatcher) {
            GitWire.parseAdvertisement(sent.response.body, service)
                .copy(serviceUrl = serviceUrl(sent.finalUrl) ?: baseUrl.toString())
        }
    }

    // MARK: Fetch

    override suspend fun fetchPack(
        want: GitObjectId,
        haves: List<GitObjectId>,
        advertisement: GitRefAdvertisement,
    ): ByteArray {
        val request = withContext(cpuDispatcher) { GitWire.uploadRequest(want, haves, advertisement) }
        val sent = send(
            method = "POST",
            url = serviceBase(advertisement) + "/git-upload-pack",
            headers = listOf(
                "Content-Type" to "application/x-git-upload-pack-request",
                "Accept" to "application/x-git-upload-pack-result",
            ),
            body = request.body,
            maximumBytes = maximumPackBytes,
        )
        if (mediaType(sent.response) != "application/x-git-upload-pack-result") {
            throw GitRemoteFailure.ProtocolViolation("upload_pack_content_type")
        }
        return withContext(cpuDispatcher) { GitWire.extractPack(sent.response.body, request.shallow, request.sideBand) }
    }

    // MARK: Push

    override suspend fun push(
        old: GitObjectId,
        new: GitObjectId,
        pack: ByteArray,
        advertisement: GitRefAdvertisement,
    ): GitPushResult {
        val request = withContext(cpuDispatcher) { GitWire.pushRequest(old, new, remote.refName, pack, advertisement) }
        val sent = send(
            method = "POST",
            url = serviceBase(advertisement) + "/git-receive-pack",
            headers = listOf(
                "Content-Type" to "application/x-git-receive-pack-request",
                "Accept" to "application/x-git-receive-pack-result",
            ),
            body = request.body,
            maximumBytes = GitWire.MAXIMUM_ADVERTISEMENT_BYTES,
        )
        if (mediaType(sent.response) != "application/x-git-receive-pack-result") {
            throw GitRemoteFailure.ProtocolViolation("receive_pack_content_type")
        }
        return withContext(cpuDispatcher) { GitWire.parseReportStatus(sent.response.body, remote.refName, request.sideBand) }
    }

    // MARK: HTTP

    /**
     * The advertisement's redirected base, or the configured URL. The redirect guard
     * pinned scheme, host and port when discovery ran; an advertisement that names
     * another origin did not come from this client's discovery, and using it would
     * send the credential there: `ProtocolViolation("service_url")`.
     */
    private fun serviceBase(advertisement: GitRefAdvertisement): String {
        val service = advertisement.serviceUrl ?: return baseUrl.toString()
        val source = HttpUrlParts.parse(baseUrl.toString())
        val target = HttpUrlParts.parse(service)
        if (source == null || target == null || !sameOrigin(source, target)) {
            throw GitRemoteFailure.ProtocolViolation("service_url")
        }
        return service
    }

    private suspend fun send(
        method: String,
        url: String,
        headers: List<Pair<String, String>>,
        body: GitWireBody?,
        maximumBytes: Long,
    ): Sent {
        val credential = Base64.getEncoder()
            .encodeToString("${remote.username}:${remote.password}".toByteArray(Charsets.UTF_8))
        val allHeaders = listOf(
            "Authorization" to "Basic $credential",
            "User-Agent" to USER_AGENT,
            "Pragma" to "no-cache",
            "Cache-Control" to "no-cache",
        ) + headers
        var current = url
        var redirects = 0
        while (true) {
            val response = try {
                engine.execute(GitHttpRequest(method, current, allHeaders, body), maximumBytes)
            } catch (failure: GitRemoteFailure) {
                throw failure
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Exception) {
                throw GitRemoteFailure.Unreachable("network")
            }
            val target = redirectTarget(method, url, current, response)
            if (target != null) {
                redirects += 1
                // URLSession gives up the same way (`NSURLErrorHTTPTooManyRedirects`).
                if (redirects > MAXIMUM_REDIRECTS) throw GitRemoteFailure.Unreachable("network_-1007")
                current = target
                continue
            }
            when (response.status) {
                200 -> return Sent(response, current)
                401, 403 -> throw GitRemoteFailure.AuthenticationRequired(response.status)
                // GitHub and GitLab answer 404 for a private repository the token cannot see.
                404 -> throw GitRemoteFailure.RepositoryNotFound()
                413 -> throw GitRemoteFailure.RequestTooLarge()
                429, 503 -> throw GitRemoteFailure.RateLimited(retryAfter(response.header("Retry-After")))
                in 500..599 -> throw GitRemoteFailure.ServerError(response.status)
                else -> throw GitRemoteFailure.ProtocolViolation("http_${response.status}")
            }
        }
    }

    companion object {
        const val USER_AGENT = "git/2.0 (Snippets)"

        private const val MAXIMUM_REDIRECTS = 16
        private val REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)
        private val DECIMAL = Regex("""[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?""")

        /**
         * Where discovery ended up, without `/info/refs` and the query; null when the
         * final address is not a discovery address.
         */
        fun serviceUrl(finalUrl: String?): String? {
            val parts = finalUrl?.let(HttpUrlParts::parse) ?: return null
            if (!parts.encodedPath.endsWith("/info/refs")) return null
            val path = parts.encodedPath.dropLast("/info/refs".length)
            if (path.isEmpty()) return null
            return parts.withPath(path, query = null)
        }

        /**
         * Whether a redirect from `sourceUrl` (the request as first made) to
         * `targetUrl` may be followed: only a GET, and only to the same scheme, host
         * and port. Anything else would carry the explicit `Authorization` header to
         * wherever a compromised or misconfigured server points it.
         */
        fun permitsRedirect(method: String, sourceUrl: String, targetUrl: String): Boolean {
            if (method != "GET") return false
            val source = HttpUrlParts.parse(sourceUrl) ?: return false
            val target = HttpUrlParts.parse(targetUrl) ?: return false
            return sameOrigin(source, target)
        }

        /** Ports are compared as written, as Swift compares `URL.port`: `:443` is not "no port". */
        private fun sameOrigin(source: HttpUrlParts, target: HttpUrlParts): Boolean =
            source.scheme == target.scheme && source.host == target.host && source.port == target.port

        /** The address to request next, or null when the response is to be judged by its status. */
        private fun redirectTarget(method: String, original: String, current: String, response: GitHttpResponse): String? {
            if (response.status !in REDIRECT_STATUSES) return null
            val location = response.header("Location") ?: return null
            val resolved = try {
                URI(current).resolve(URI(location)).toString()
            } catch (_: Exception) {
                // Not an address `java.net.URI` reads (`URISyntaxException` and friends).
                return null
            }
            return resolved.takeIf { permitsRedirect(method, original, it) }
        }

        private fun mediaType(response: GitHttpResponse): String? =
            response.header("Content-Type")?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)

        /** Seconds only (an HTTP date falls back to the default), default 30, clamped to 1...3600. */
        internal fun retryAfter(header: String?): Double {
            val seconds = header?.trim()?.takeIf(DECIMAL::matches)?.toDoubleOrNull()?.takeIf { it.isFinite() } ?: 30.0
            return seconds.coerceIn(1.0, 3_600.0)
        }
    }
}
