package com.khm.snippets.core.git

/** Thrown for a repository address, branch or credential this client refuses to use. */
class GitRemoteConfigurationException(val failure: GitRemote.Failure) : IllegalArgumentException(failure.name) {
    override fun equals(other: Any?): Boolean = other is GitRemoteConfigurationException && failure == other.failure
    override fun hashCode(): Int = failure.hashCode()
}

/**
 * Where and as whom to talk to a hosted repository.
 *
 * HTTPS uses an HTTP Basic pair: every mainstream host (GitHub, GitLab, Gitea/Forgejo,
 * GitVerse, Bitbucket) accepts a personal access token as the password for its
 * smart-HTTP endpoint. SSH authenticates outside this type, with a per-device key.
 *
 * Deliberately not a data class: a generated `toString` would print the token.
 */
class GitRemote private constructor(
    val location: GitRepositoryLocation,
    val branch: String,
    /** HTTPS only; empty for SSH. */
    val username: String,
    /** HTTPS only; empty for SSH. */
    val password: String,
) {
    enum class Failure { INVALID_URL, INVALID_BRANCH, INVALID_CREDENTIAL }

    /** The HTTPS endpoint, null for an SSH remote. (Swift returns `about:blank` there; nothing reads it.) */
    val url: GitHttpsUrl? get() = (location as? GitRepositoryLocation.Https)?.url

    val refName: String get() = "refs/heads/$branch"

    /** Scheme-independent repository identity; see [GitRepositoryLocation.canonicalIdentity]. */
    val canonicalLocation: String get() = location.canonicalIdentity

    /** Never prints the token. */
    override fun toString(): String = "GitRemote(${location.spec}, $refName)"

    override fun equals(other: Any?): Boolean =
        other is GitRemote && location == other.location && branch == other.branch &&
            username == other.username && password == other.password

    override fun hashCode(): Int = 31 * (31 * location.hashCode() + branch.hashCode()) + username.hashCode()

    companion object {
        /**
         * An HTTPS remote with a token.
         *
         * `allowsInsecureLoopback` is a test seam; see [normalizedUrl].
         */
        fun https(
            url: String,
            branch: String,
            username: String,
            password: String,
            allowsInsecureLoopback: Boolean = false,
        ): GitRemote {
            val normalized = normalizedUrl(url, allowsInsecureLoopback)
            if (!isValidBranch(branch)) throw GitRemoteConfigurationException(Failure.INVALID_BRANCH)
            if (!isValidUsername(username) || !isValidToken(password)) {
                throw GitRemoteConfigurationException(Failure.INVALID_CREDENTIAL)
            }
            return GitRemote(GitRepositoryLocation.Https(normalized), branch, username, password)
        }

        /** An SSH remote; authentication is the connection's business. */
        fun ssh(location: GitSshLocation, branch: String): GitRemote {
            if (!isValidBranch(branch)) throw GitRemoteConfigurationException(Failure.INVALID_BRANCH)
            return GitRemote(GitRepositoryLocation.Ssh(location), branch, username = "", password = "")
        }

        fun canonicalLocation(normalizedUrl: GitHttpsUrl): String =
            GitRepositoryLocation.Https(normalizedUrl).canonicalIdentity

        /**
         * Lowercase scheme and host, no credentials, query, fragment or trailing slash.
         * HTTPS only.
         *
         * `allowsInsecureLoopback` is a **test seam**: when true, plain `http://` is
         * also accepted, and only for a loopback host (`localhost`, `127.0.0.1`, `::1`,
         * `*.localhost`). Production code must leave it false; the app may pass true
         * only from a debug build behind an explicit flag, and tests pass it to reach
         * a local `git http-backend`.
         */
        fun normalizedUrl(url: String, allowsInsecureLoopback: Boolean = false): GitHttpsUrl =
            GitUrlNormalizer.normalize(url, allowsInsecureLoopback)
                ?: throw GitRemoteConfigurationException(Failure.INVALID_URL)

        fun isValidUsername(username: String): Boolean =
            username.utf8Size() in 1..256 && !username.contains(':') &&
                username.allScalars { it >= 0x20 && it != 0x7f }

        fun isValidToken(token: String): Boolean =
            token.utf8Size() in 1..4_096 && token.allScalars { it >= 0x20 && it != 0x7f }

        /** A conservative subset of `git check-ref-format`. */
        fun isValidBranch(branch: String): Boolean {
            if (branch.length !in 1..200) return false
            if (!branch.all { it in '0'..'9' || it in 'A'..'Z' || it in 'a'..'z' || it == '-' || it == '_' || it == '.' || it == '/' }) {
                return false
            }
            if (branch.startsWith("-") || branch.startsWith("/") || branch.endsWith("/") ||
                branch.endsWith(".") || branch.endsWith(".lock") ||
                branch.contains("..") || branch.contains("//") || branch == "HEAD"
            ) {
                return false
            }
            return branch.split('/').none { it.startsWith(".") }
        }
    }
}

/**
 * A failure talking to the host. Cases carry only status codes and fixed reasons;
 * server-provided text (which may echo the repository path) is never retained.
 *
 * Two failures are equal when they are the same case with the same values.
 */
sealed class GitRemoteFailure(code: String) : Exception(code) {
    class AuthenticationRequired(val status: Int) : GitRemoteFailure("authentication_required:$status")
    class RepositoryNotFound : GitRemoteFailure("repository_not_found")
    class RateLimited(val retryAfterSeconds: Double) : GitRemoteFailure("rate_limited:$retryAfterSeconds")
    class Unreachable(val detail: String) : GitRemoteFailure("unreachable:$detail")
    class UnsupportedServer(val detail: String) : GitRemoteFailure("unsupported_server:$detail")
    class ProtocolViolation(val detail: String) : GitRemoteFailure("protocol_violation:$detail")
    class ServerError(val status: Int) : GitRemoteFailure("server_error:$status")
    class ResponseTooLarge : GitRemoteFailure("response_too_large")

    /** SSH: the host's key is not yet trusted on this device. */
    class SshHostKeyUnknown : GitRemoteFailure("ssh_host_key_unknown")

    /** SSH: the host presented a different key than the one trusted before. */
    class SshHostKeyChanged : GitRemoteFailure("ssh_host_key_changed")

    /** SSH: no offered key was accepted. */
    class SshPermissionDenied : GitRemoteFailure("ssh_permission_denied")

    /** HTTP 413: the host or a proxy in front of it refused the request body. */
    class RequestTooLarge : GitRemoteFailure("request_too_large")

    /** The case and its values as one closed token; never contains server text. */
    val code: String get() = message!!

    override fun equals(other: Any?): Boolean = other is GitRemoteFailure && code == other.code
    override fun hashCode(): Int = code.hashCode()
    override fun toString(): String = "GitRemoteFailure($code)"
}
