package com.khm.snippets.core.git

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
    /** Lowercase ASCII (an international name in its `xn--` form); never with brackets. */
    val host: String,
    /** Whether the address writes the host in brackets, as an IPv6 literal is written. */
    internal val bracketed: Boolean,
    /** The port as written; null when the address names none. */
    val port: Int?,
    /** Percent-encoded, starts with `/`, never ends with one. Its escapes are valid UTF-8. */
    val encodedPath: String,
) {
    /** The percent-decoded path, as Foundation's `URL.path` reports it. */
    val path: String get() = percentDecoded(encodedPath)

    internal val authority: String
        get() = (if (bracketed) "[$host]" else host) + (if (port != null) ":$port" else "")

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
                    // Foundation's `URL.path` drops trailing slashes, escaped ones too.
                    path = url.path.trimEnd('/')
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
         * Whatever Swift's `GitRepositoryLocation.parse` refuses is refused here, and
         * what both accept has the same `spec` and `canonicalIdentity`. A few forms
         * Swift accepts are refused on purpose; each is marked where it is decided.
         *
         * `allowsInsecureLoopback` is a test seam; see [GitRemote.normalizedUrl].
         */
        fun parse(raw: String, allowsInsecureLoopback: Boolean = false): GitRepositoryLocation {
            val text = raw.trimFoundationWhitespace()
            if (text.isEmpty() || !text.allScalars { it > 0x20 && it != 0x7f }) invalidUrl()
            if (GitUrlNormalizer.hasDelimiterInsideACluster(text)) invalidUrl()
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
            val hostPort = Authority.split(authority.substring(at + 1)) ?: invalidUrl()
            val host = if (hostPort.bracketed) {
                // Swift drops the brackets; an escape inside them it refuses. It does
                // accept `[xn--…]`, but saves it without brackets as an address it
                // then refuses to read back, so that is refused here from the start.
                hostPort.host.takeIf { !it.contains('%') && !it.contains("xn--", ignoreCase = true) }
            } else {
                val decoded = percentDecoded(hostPort.host)
                // An escape next to a non-ASCII character: Foundation maps and
                // unescapes in an order of its own (`K%41` with a Kelvin sign is `kA`).
                if (hostPort.host.contains('%') && !decoded.all { it.code < 0x80 }) invalidUrl()
                GitHostNames.sshUrlHost(decoded)
            }
            val rawPath = tail.substring(slash)
            // Foundation escapes a path that holds a character no URL may carry, and
            // then escapes its `%` signs as well: the decoded path keeps them, and a
            // path with `%` is refused.
            if (rawPath.contains('%') && GitUrlNormalizer.needsEscaping(rawPath)) invalidUrl()
            // One decoding pass; `GitSshLocation` then refuses any `%` left over.
            val path = percentDecoded(rawPath)
            val user = userInfo?.let(::percentDecoded)
            if (GitUrlNormalizer.hasDelimiterInsideACluster(path) || (user != null && GitUrlNormalizer.hasDelimiterInsideACluster(user))) {
                invalidUrl()
            }
            return GitSshLocation(user, host ?: invalidUrl(), hostPort.port, path, scpStyle = false)
        }

        private fun invalidUrl(): Nothing = throw GitRemoteConfigurationException(GitRemote.Failure.INVALID_URL)
    }
}

/**
 * The host and port of a repository address: `host`, `host:port`, `[literal]` or
 * `[literal]:port`, split as Foundation splits them.
 *
 * An empty port (`host:`) is no port, and leading zeros are dropped, as in Swift.
 * Refused although Swift accepts them: port 0 and ports above 65535, including the
 * ones so long that Swift takes them for no port at all. Stacks disagree about what
 * such a number means (some keep the low sixteen bits), so the endpoint that would
 * receive the credential is not the one written.
 */
internal class Authority(val host: String, val port: Int?, val bracketed: Boolean, val emptyPort: Boolean) {
    companion object {
        fun split(text: String): Authority? {
            if (text.startsWith("[")) {
                val close = text.indexOf(']')
                if (close < 0) return null
                val rest = text.substring(close + 1)
                if (rest.isNotEmpty() && !rest.startsWith(":")) return null
                val portText = if (rest.isEmpty()) null else rest.substring(1)
                val port = if (portText.isNullOrEmpty()) null else parsePort(portText) ?: return null
                return Authority(text.substring(1, close), port, bracketed = true, emptyPort = portText == "")
            }
            val colon = text.indexOf(':')
            if (colon < 0) return Authority(text, null, bracketed = false, emptyPort = false)
            // A second colon is an IPv6 literal without its brackets: Swift refuses it
            // rather than take the last group for a port.
            if (text.indexOf(':', colon + 1) >= 0) return null
            val portText = text.substring(colon + 1)
            val port = if (portText.isEmpty()) null else parsePort(portText) ?: return null
            return Authority(text.substring(0, colon), port, bracketed = false, emptyPort = portText.isEmpty())
        }

        private fun parsePort(text: String): Int? {
            if (!text.all { it in '0'..'9' }) return null
            val digits = text.trimStart('0')
            if (digits.isEmpty() || digits.length > 5) return null
            return digits.toInt().takeIf { it in 1..65_535 }
        }
    }
}

/**
 * `host`, `host:port`, `[v6]` or `[v6]:port` of a request or redirect address, split
 * without interpreting the host. Stricter than [Authority]: a port that is written
 * is 1...65535 in at most five digits.
 */
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
            if (text.indexOf(':') != colon) return null
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
                // ASCII letters only: `lowercase()` would also turn a Kelvin sign into
                // `k`, and two hosts that merely look alike must not compare equal.
                host = asciiLowercase(hostPort.host),
                port = hostPort.port,
                bracketed = hostPort.bracketed,
                encodedPath = if (slash >= 0) rest.substring(slash) else "",
                query = query,
            )
        }

        private fun Char.isAsciiLetter(): Boolean = this in 'a'..'z' || this in 'A'..'Z'

        private fun asciiLowercase(text: String): String {
            val out = StringBuilder(text.length)
            for (character in text) out.append(if (character in 'A'..'Z') character + 32 else character)
            return out.toString()
        }
    }
}

internal object GitUrlNormalizer {
    private const val UNRESERVED_AND_DELIMITERS = "-._~!$&'()*+,;=:@/"

    fun isLoopbackHost(host: String): Boolean =
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.endsWith(".localhost")

    /**
     * Swift finds `://`, the first `:`, the last `@` and every `/` as whole
     * characters (grapheme clusters): a delimiter followed by a combining mark, or
     * preceded by a character that attaches to what follows, is not that delimiter to
     * Swift. It then reads the address differently (`https://` + U+0301 becomes an
     * scp-like address on a host named `https`) or derives another identity from it.
     * Such an address is refused here: there is no reading of it that every platform
     * shares.
     */
    fun hasDelimiterInsideACluster(text: String): Boolean {
        var index = 0
        var previous = -1
        while (index < text.length) {
            val scalar = text.codePointAt(index)
            val next = index + Character.charCount(scalar)
            if (scalar == '/'.code || scalar == ':'.code || scalar == '@'.code) {
                if (previous >= 0 && attachesToNext(previous)) return true
                if (next < text.length && attachesToPrevious(text.codePointAt(next))) return true
            } else if (scalar == '.'.code && previous >= 0 && attachesToNext(previous)) {
                // The `.` of a final `.git` that Swift would not recognize.
                return true
            }
            previous = scalar
            index = next
        }
        return false
    }

    /**
     * Marks, format characters (the joiners, tags), emoji modifiers, half-width
     * voicing marks, Thai and Lao SARA AM. A character this runtime does not know
     * counts too: a newer Unicode version may have made it a mark.
     */
    private fun attachesToPrevious(scalar: Int): Boolean {
        if (scalar < 0x80) return false
        return when (Character.getType(scalar).toByte()) {
            Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK,
            Character.FORMAT, Character.UNASSIGNED,
            -> true
            else -> scalar in 0x1f3fb..0x1f3ff || scalar == 0xff9e || scalar == 0xff9f || scalar == 0x0e33 || scalar == 0x0eb3
        }
    }

    /** The "prepend" characters: Arabic number signs and the like, and a few Indic letters. */
    private fun attachesToNext(scalar: Int): Boolean {
        if (scalar < 0x80) return false
        return when (Character.getType(scalar).toByte()) {
            Character.FORMAT, Character.UNASSIGNED -> true
            else -> scalar == 0x0d4e || scalar in 0x111c2..0x111c3 || scalar == 0x1193f || scalar == 0x11941 ||
                scalar == 0x11a3a || scalar in 0x11a84..0x11a89 || scalar == 0x11d46 || scalar == 0x11f02
        }
    }

    /** See [GitRemote.normalizedUrl]. */
    fun normalize(text: String, allowsInsecureLoopback: Boolean): GitHttpsUrl? {
        if (!text.allScalars { it > 0x20 && it != 0x7f }) return null
        if (hasDelimiterInsideACluster(text)) return null
        // Foundation would escape a backslash and OkHttp would read it as a slash.
        if (text.contains('\\') || text.contains('?') || text.contains('#')) return null
        val schemeEnd = text.indexOf("://")
        if (schemeEnd <= 0) return null
        val scheme = text.substring(0, schemeEnd).lowercase(Locale.ROOT)
        if (scheme != "https" && scheme != "http") return null
        val rest = text.substring(schemeEnd + 3)
        val slash = rest.indexOf('/')
        if (slash < 0) return null
        val authorityText = rest.substring(0, slash)
        if (authorityText.contains('@')) return null
        val authority = Authority.split(authorityText) ?: return null
        val host = (if (authority.bracketed) bracketedHost(authority) else GitHostNames.canonical(authority.host)) ?: return null
        if (scheme != "https" && !(allowsInsecureLoopback && isLoopbackHost(host))) return null
        val path = normalizedPath(rest.substring(slash).trimEnd('/')) ?: return null
        if (path.isEmpty()) return null
        // The identity is derived from the decoded path, where an escaped mark can
        // come to stand next to a slash.
        if (hasDelimiterInsideACluster(percentDecoded(path))) return null
        return GitHttpsUrl(scheme, host, authority.bracketed, authority.port, path)
    }

    /**
     * What stands between brackets, in lowercase. Foundation does not require an IPv6
     * literal there (`[h]` is a host to it, and stays in brackets), so neither does
     * this; the HTTP client then refuses to connect to anything but a literal.
     *
     * Refused although Swift accepts them: an empty host (`[]`), which is no host at
     * all; `[literal]:` with an empty port, whose colon Swift keeps in the saved
     * address; and a zone identifier (`[fe80::1%25en0]`), which Swift unescapes a
     * varying number of times and which names an interface of one device only.
     */
    private fun bracketedHost(authority: Authority): String? {
        if (authority.emptyPort) return null
        // ASCII only, checked before lowercasing: a Kelvin sign lowercases to `k`.
        val written = authority.host
        val valid = written.isNotEmpty() && !written.contains("xn--", ignoreCase = true) &&
            written.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '.' || it == ':' || it == '-' || it == '_' }
        return if (valid) written.lowercase(Locale.ROOT) else null
    }

    /** Whether a path holds a character that no URL may carry unescaped (or a malformed escape). */
    fun needsEscaping(path: String): Boolean {
        var index = 0
        while (index < path.length) {
            val character = path[index]
            if (character == '%') {
                if (index + 2 >= path.length || hexValue(path[index + 1].code) < 0 || hexValue(path[index + 2].code) < 0) return true
                index += 2
            } else if (!(character.code < 0x80 && (character.isLetterOrDigit() || UNRESERVED_AND_DELIMITERS.indexOf(character) >= 0))) {
                return true
            }
            index += 1
        }
        return false
    }

    /**
     * The path as Foundation saves it. A path made only of URL-safe characters and
     * well-formed escapes is kept. Any other path is escaped as a whole, **including
     * its `%` signs**: Swift reads `/%41/[x]` as `/%2541/%5Bx%5D`, a directory
     * literally named `%41`.
     *
     * Refused although Swift accepts them: a stray `%` and `.`/`..` segments (an
     * HTTP client would silently rewrite them, and the address requested would no
     * longer be the one saved), and escapes that are not UTF-8. For the last, Swift
     * derives the identity `host/` whatever the path is and Linux keeps the escaped
     * text; refusing the address keeps it out of both key scopes.
     */
    private fun normalizedPath(path: String): String? {
        val escapeEverything = needsEscaping(path)
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
                    out.append(if (escapeEverything) "%25" else "%")
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
        if (dotSegment) return null
        val decodes = !normalized.contains('%') || percentDecodedStrictly(normalized) != null
        return normalized.takeIf { decodes }
    }
}
