package com.khm.snippets.core.git

import java.util.Locale

/**
 * One HTTP request. Not a data class on purpose: `headers` carries the credential,
 * and neither it nor the address may end up in a log through `toString`.
 */
class GitHttpRequest(
    val method: String,
    val url: String,
    val headers: List<Pair<String, String>>,
    val body: GitWireBody? = null,
) {
    override fun toString(): String = "GitHttpRequest($method)"
}

class GitHttpResponse(val status: Int, headers: Map<String, String>, val body: ByteArray) {
    private val headers: Map<String, String> = headers.mapKeys { it.key.lowercase(Locale.ROOT) }

    /** Case-insensitive; the first value when a header repeats. */
    fun header(name: String): String? = headers[name.lowercase(Locale.ROOT)]

    override fun toString(): String = "GitHttpResponse($status, ${body.size} bytes)"
}

/**
 * Performs exactly one HTTP exchange for [GitSmartHttpClient], which owns every
 * policy decision (credentials, redirects, status handling).
 *
 * An implementation must:
 * - send the request as given: no redirect following, no retry, and no header added
 *   to or removed from it that concerns credentials or caching (`Authorization` is
 *   sent exactly when the request carries it; no cookies, no cache);
 * - send the body with a declared length, written from [GitWireBody] without
 *   buffering a second copy;
 * - read a response body **only for status 200**, counting the decoded bytes (after
 *   any transparent `gzip`) while they arrive and failing with
 *   [GitRemoteFailure.ResponseTooLarge] as soon as they exceed
 *   `maximumResponseBytes`, or at once when a declared length already does; for any
 *   other status the body is discarded unread and [GitHttpResponse.body] is empty;
 * - fail an exchange that is idle for 60 s, and any exchange after 600 s in total: a
 *   large first upload must not be cut off by a short whole-request timeout;
 * - report transport failures as [GitRemoteFailure.Unreachable] with a closed
 *   `network…` detail, and cancellation as `CancellationException`;
 * - never log the address, a header or any server text.
 */
interface GitHttpEngine {
    suspend fun execute(request: GitHttpRequest, maximumResponseBytes: Long): GitHttpResponse
}
