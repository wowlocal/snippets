package com.khm.snippets.core.git

import java.net.IDN
import java.util.Locale

/**
 * One SSH destination, as git understands it.
 *
 * `scpStyle` keeps `user@host:path` (a path relative to the server account) distinct
 * from `ssh://user@host[:port]/path` (an absolute path); hosted services accept both,
 * but a plain sshd does not treat them the same.
 *
 * The character sets are conservative: these values reach an SSH exec request and a
 * remote shell, so nothing that could become an option or a metacharacter passes.
 * Construction throws [GitRemoteConfigurationException] (`INVALID_URL`) otherwise.
 */
data class GitSshLocation(
    val user: String?,
    /** Host name, alias, or IP literal (no brackets). */
    val host: String,
    val port: Int?,
    val path: String,
    val scpStyle: Boolean,
) {
    init {
        val valid = (user == null || (allowed(user, "._-") && !user.startsWith("-"))) &&
            allowed(host, ".-_:") && !host.startsWith("-") && !host.startsWith(".") &&
            (port == null || port in 1..65_535) &&
            path.utf8Size() in 1..1_024 && !path.startsWith("-") &&
            path.allScalars { it > 0x20 && it != 0x7f && (it > 0x7f || FORBIDDEN_IN_PATH.indexOf(it.toChar()) < 0) } &&
            path.split('/').none { it == ".." }
        if (!valid) throw GitRemoteConfigurationException(GitRemote.Failure.INVALID_URL)
    }

    /** `user@host` or `host`. */
    val destination: String get() = if (user != null) "$user@$host" else host

    /** The normalized text stored in preferences and shown in forms. */
    val spec: String
        get() {
            if (scpStyle) return "$destination:$path"
            val hostPart = if (host.contains(':')) "[$host]" else host
            val userPart = if (user != null) "$user@" else ""
            val portPart = if (port != null) ":$port" else ""
            return "ssh://$userPart$hostPart$portPart$path"
        }

    private companion object {
        /** `%` is refused because the saved address would decode differently when read back. */
        const val FORBIDDEN_IN_PATH = "'\\\"`$;&|<>(){}*?[]!#%"

        fun allowed(text: String, extra: String): Boolean =
            text.isNotEmpty() && text.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || extra.indexOf(it) >= 0 }
    }
}

/**
 * A normalized smart-HTTP address: lowercase scheme and host, no credentials, query,
 * fragment or trailing slash.
 *
 * The scheme is `https`. Plain `http` exists only as the loopback test seam of
 * [GitRemote.normalizedUrl].
 */
class GitHttpsUrl internal constructor(
    val scheme: String,
    /** Lowercase; an IPv6 literal has no brackets. */
    val host: String,
    /** The port as written; null when the address names none. */
    val port: Int?,
    /** Percent-encoded, starts with `/`, never ends with one. */
    val encodedPath: String,
) {
    /** The percent-decoded path, as Foundation's `URL.path` reports it. */
    val path: String get() = percentDecoded(encodedPath)

    internal val authority: String
        get() = (if (host.contains(':')) "[$host]" else host) + (if (port != null) ":$port" else "")

    override fun toString(): String = "$scheme://$authority$encodedPath"
    override fun equals(other: Any?): Boolean = other is GitHttpsUrl && toString() == other.toString()
    override fun hashCode(): Int = toString().hashCode()
}

/** Where a repository lives: an HTTPS URL or an SSH destination. */
sealed class GitRepositoryLocation {
    data class Https(val url: GitHttpsUrl) : GitRepositoryLocation()
    data class Ssh(val location: GitSshLocation) : GitRepositoryLocation()

    val isSsh: Boolean get() = this is Ssh

    /** The normalized text stored in preferences and shown in forms. */
    val spec: String
        get() = when (this) {
            is Https -> url.toString()
            is Ssh -> location.spec
        }

    /**
     * `host/path`: lowercase host; no scheme, user, port, leading `/` or `.git`.
     * `git@github.com:me/lib.git` and `https://github.com/me/lib` are one repository,
     * so one library key and one local sync state serve both access methods.
     *
     * Shared byte for byte with the Apple and Linux apps: it feeds key scopes and the
     * account and dataset digests.
     */
    val canonicalIdentity: String
        get() {
            val host: String
            var path: String
            when (this) {
                is Https -> {
                    host = url.host
                    path = url.path
                }
                is Ssh -> {
                    host = location.host.lowercase(Locale.ROOT)
                    path = location.path
                }
            }
            path = path.trimStart('/')
            if (path.endsWith(".git")) path = path.dropLast(4)
            path = path.trimEnd('/')
            return "$host/$path"
        }

    /**
     * One repository reached two ways. The shared identity (host and path) lets a
     * device move between HTTPS and SSH; between two SSH addresses the account and
     * port must also match, because on a self-hosted server they select a different
     * home directory or daemon. Between two HTTPS addresses the port must match.
     */
    fun sameEndpoint(other: GitRepositoryLocation): Boolean {
        if (canonicalIdentity != other.canonicalIdentity) return false
        return when {
            this is Ssh && other is Ssh ->
                (location.user ?: "") == (other.location.user ?: "") &&
                    (location.port ?: 22) == (other.location.port ?: 22)
            this is Https && other is Https -> (url.port ?: 443) == (other.url.port ?: 443)
            else -> true
        }
    }

    companion object {
        /**
         * Accepts `https://…`, `ssh://[user@]host[:port]/path` (also `git+ssh://`) and
         * scp-like `[user@]host:path`. A bare `host/path` is read as HTTPS.
         *
         * `allowsInsecureLoopback` is a test seam; see [GitRemote.normalizedUrl].
         */
        fun parse(raw: String, allowsInsecureLoopback: Boolean = false): GitRepositoryLocation {
            val text = raw.trimFoundationWhitespace()
            if (text.isEmpty() || !text.allScalars { it > 0x20 && it != 0x7f }) invalidUrl()
            val lowered = text.lowercase(Locale.ROOT)
            for (scheme in arrayOf("ssh://", "git+ssh://")) {
                if (lowered.startsWith(scheme)) return Ssh(parseSshUrl(text.substring(scheme.length)))
            }
            if (text.contains("://")) return Https(GitRemote.normalizedUrl(text, allowsInsecureLoopback))
            // scp-like: the first ':' comes before any '/'.
            val colon = text.indexOf(':')
            if (colon >= 0 && text.lastIndexOf('/', colon) < 0) {
                val destination = text.substring(0, colon)
                val path = text.substring(colon + 1)
                val at = destination.lastIndexOf('@')
                val user = if (at >= 0) destination.substring(0, at) else null
                val host = if (at >= 0) destination.substring(at + 1) else destination
                return Ssh(GitSshLocation(user, host, port = null, path = path, scpStyle = true))
            }
            return Https(GitRemote.normalizedUrl("https://$text", allowsInsecureLoopback))
        }

        /** What follows `ssh://`: `[user@]host[:port]/path`, no password, query or fragment. */
        private fun parseSshUrl(tail: String): GitSshLocation {
            if (tail.contains('?') || tail.contains('#')) invalidUrl()
            val slash = tail.indexOf('/')
            if (slash < 0) invalidUrl()
            val authority = tail.substring(0, slash)
            val at = authority.lastIndexOf('@')
            val userInfo = if (at >= 0) authority.substring(0, at) else null
            if (userInfo != null && userInfo.contains(':')) invalidUrl()
            val hostPort = HostPort.split(authority.substring(at + 1)) ?: invalidUrl()
            return GitSshLocation(
                user = userInfo?.let(::percentDecoded),
                host = percentDecoded(hostPort.host),
                port = hostPort.port,
                // One decoding pass; `GitSshLocation` then refuses any `%` left over.
                path = percentDecoded(tail.substring(slash)),
                scpStyle = false,
            )
        }

        private fun invalidUrl(): Nothing = throw GitRemoteConfigurationException(GitRemote.Failure.INVALID_URL)
    }
}

/** `host`, `host:port`, `[v6]` or `[v6]:port`, split without interpreting the host. */
internal class HostPort(val host: String, val port: Int?, val bracketed: Boolean) {
    companion object {
        fun split(text: String): HostPort? {
            if (text.startsWith("[")) {
                val close = text.indexOf(']')
                if (close < 0) return null
                val rest = text.substring(close + 1)
                val port = when {
                    rest.isEmpty() -> null
                    rest.startsWith(":") -> parsePort(rest.substring(1)) ?: return null
                    else -> return null
                }
                return HostPort(text.substring(1, close), port, bracketed = true)
            }
            val colon = text.lastIndexOf(':')
            if (colon < 0) return HostPort(text, null, bracketed = false)
            val port = parsePort(text.substring(colon + 1)) ?: return null
            return HostPort(text.substring(0, colon), port, bracketed = false)
        }

        private fun parsePort(text: String): Int? {
            if (text.isEmpty() || text.length > 5 || !text.all { it in '0'..'9' }) return null
            return text.toInt().takeIf { it in 1..65_535 }
        }
    }
}

/** The pieces of an absolute `http(s)` URL, as far as this client needs them. */
internal class HttpUrlParts(
    val scheme: String,
    val host: String,
    val port: Int?,
    val bracketed: Boolean,
    val encodedPath: String,
    val query: String?,
) {
    val authority: String get() = (if (bracketed) "[$host]" else host) + (if (port != null) ":$port" else "")

    fun withPath(path: String, query: String?): String =
        "$scheme://$authority$path" + (if (query != null) "?$query" else "")

    override fun toString(): String = withPath(encodedPath, query)

    companion object {
        /** Null for anything that is not `scheme://host[:port][/path][?query]` without user info. */
        fun parse(text: String): HttpUrlParts? {
            val schemeEnd = text.indexOf("://")
            if (schemeEnd <= 0) return null
            val scheme = text.substring(0, schemeEnd)
            if (!scheme[0].isAsciiLetter() || !scheme.all { it.isAsciiLetter() || it in '0'..'9' || it in "+-." }) {
                return null
            }
            var rest = text.substring(schemeEnd + 3)
            val fragment = rest.indexOf('#')
            if (fragment >= 0) rest = rest.substring(0, fragment)
            val queryStart = rest.indexOf('?')
            val query = if (queryStart >= 0) rest.substring(queryStart + 1) else null
            if (queryStart >= 0) rest = rest.substring(0, queryStart)
            val slash = rest.indexOf('/')
            val authority = if (slash >= 0) rest.substring(0, slash) else rest
            if (authority.contains('@')) return null
            val hostPort = HostPort.split(authority) ?: return null
            if (hostPort.host.isEmpty()) return null
            return HttpUrlParts(
                scheme = scheme.lowercase(Locale.ROOT),
                host = hostPort.host.lowercase(Locale.ROOT),
                port = hostPort.port,
                bracketed = hostPort.bracketed,
                encodedPath = if (slash >= 0) rest.substring(slash) else "",
                query = query,
            )
        }

        private fun Char.isAsciiLetter(): Boolean = this in 'a'..'z' || this in 'A'..'Z'
    }
}

internal object GitUrlNormalizer {
    private const val UNRESERVED_AND_DELIMITERS = "-._~!$&'()*+,;=:@/"

    fun isLoopbackHost(host: String): Boolean =
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.endsWith(".localhost")

    /** See [GitRemote.normalizedUrl]. */
    fun normalize(text: String, allowsInsecureLoopback: Boolean): GitHttpsUrl? {
        if (!text.allScalars { it > 0x20 && it != 0x7f }) return null
        // Foundation would escape a backslash and OkHttp would read it as a slash.
        if (text.contains('\\') || text.contains('?') || text.contains('#')) return null
        val parts = HttpUrlParts.parse(text) ?: return null
        val host = normalizedHost(parts) ?: return null
        val secure = parts.scheme == "https"
        if (!secure && !(parts.scheme == "http" && allowsInsecureLoopback && isLoopbackHost(host))) return null
        val path = normalizedPath(parts.encodedPath.trimEnd('/')) ?: return null
        if (path.isEmpty()) return null
        return GitHttpsUrl(parts.scheme, host, parts.port, path)
    }

    private fun normalizedHost(parts: HttpUrlParts): String? {
        if (parts.bracketed) {
            val literal = parts.host
            return literal.takeIf { it.contains(':') && it.all { c -> c in '0'..'9' || c in 'a'..'f' || c == ':' || c == '.' } }
        }
        val ascii = if (parts.host.all { it.code < 0x80 }) {
            parts.host
        } else {
            try {
                IDN.toASCII(parts.host, IDN.ALLOW_UNASSIGNED).lowercase(Locale.ROOT)
            } catch (_: IllegalArgumentException) {
                return null
            }
        }
        return ascii.takeIf { it.isNotEmpty() && it.all { c -> c in 'a'..'z' || c in '0'..'9' || c == '.' || c == '-' || c == '_' } }
    }

    /**
     * Keeps valid escapes and URL-safe characters, escapes the rest as UTF-8.
     * Refuses a stray `%` and `.`/`..` segments: an HTTP client would silently
     * rewrite them, and the address requested would no longer be the one saved.
     */
    private fun normalizedPath(path: String): String? {
        val out = StringBuilder(path.length)
        val bytes = path.toByteArray(Charsets.UTF_8)
        var index = 0
        while (index < bytes.size) {
            val value = bytes[index].toInt() and 0xff
            val character = value.toChar()
            when {
                character == '%' -> {
                    if (index + 2 >= bytes.size || hexValue(bytes[index + 1].toInt()) < 0 || hexValue(bytes[index + 2].toInt()) < 0) {
                        return null
                    }
                    out.append(character).append(bytes[index + 1].toInt().toChar()).append(bytes[index + 2].toInt().toChar())
                    index += 2
                }
                value < 0x80 && (character.isLetterOrDigit() || UNRESERVED_AND_DELIMITERS.indexOf(character) >= 0) ->
                    out.append(character)
                else -> out.append('%').append("0123456789ABCDEF"[value ushr 4]).append("0123456789ABCDEF"[value and 0x0f])
            }
            index += 1
        }
        val normalized = out.toString()
        val dotSegment = normalized.split('/').any {
            val segment = it.replace("%2e", ".", ignoreCase = true)
            segment == "." || segment == ".."
        }
        return if (dotSegment) null else normalized
    }
}
