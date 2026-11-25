package com.khm.snippets.core.git

import java.util.Locale

/**
 * The git services over SSH. The request bodies and response parsers are those of
 * smart HTTP; what differs is that each operation is one exec channel on which the
 * service speaks first, so capabilities and refs always come from that channel's own
 * advertisement, not from the one the caller passes in.
 */
class GitSshClient(
    val remote: GitRemote,
    val location: GitSshLocation,
    private val connector: GitSshConnector,
    private val maximumPackBytes: Long = GitWire.MAXIMUM_PACK_BYTES,
    private val idleTimeoutMillis: Long = GitSshExchangeRunner.DEFAULT_IDLE_TIMEOUT_MILLIS,
) : GitWireClient {

    private suspend fun exchange(
        service: GitService,
        maximumBytes: Long,
        request: (ByteArray) -> GitWireBody?,
    ): GitSshExchange = GitSshExchangeRunner.exchange(
        connector, remoteCommand(service, location), location, maximumBytes, idleTimeoutMillis, request,
    )

    override suspend fun discover(service: GitService): GitRefAdvertisement {
        val exchange = exchange(service, GitWire.MAXIMUM_ADVERTISEMENT_BYTES) { null }
        return GitWire.parseAdvertisement(exchange.advertisement, service)
    }

    override suspend fun fetchPack(
        want: GitObjectId,
        haves: List<GitObjectId>,
        advertisement: GitRefAdvertisement,
    ): ByteArray {
        // A stateful SSH upload-pack only serves advertised tips. The caller only asks
        // for tips, so a missing one means the branch moved since discovery: a race.
        val exchange = exchange(GitService.UPLOAD_PACK, maximumPackBytes) { bytes ->
            val live = GitWire.parseAdvertisement(bytes, GitService.UPLOAD_PACK)
            if (live.refs.containsValue(want)) GitWire.uploadRequest(want, haves, live).body else null
        }
        val live = GitWire.parseAdvertisement(exchange.advertisement, GitService.UPLOAD_PACK)
        if (!live.refs.containsValue(want)) throw GitRemoteFailure.Unreachable("ref_moved")
        val request = GitWire.uploadRequest(want, haves, live)
        return GitWire.extractPack(exchange.response, request.shallow, request.sideBand)
    }

    override suspend fun push(
        old: GitObjectId,
        new: GitObjectId,
        pack: ByteArray,
        advertisement: GitRefAdvertisement,
    ): GitPushResult {
        val refName = remote.refName
        fun current(live: GitRefAdvertisement): GitObjectId = live.refs[refName] ?: GitObjectId.ZERO
        val exchange = exchange(GitService.RECEIVE_PACK, GitWire.MAXIMUM_ADVERTISEMENT_BYTES) { bytes ->
            val live = GitWire.parseAdvertisement(bytes, GitService.RECEIVE_PACK)
            // The server would refuse the stale update anyway; don't upload the pack.
            if (current(live) == old) GitWire.pushRequest(old, new, refName, pack, live).body else null
        }
        val live = GitWire.parseAdvertisement(exchange.advertisement, GitService.RECEIVE_PACK)
        if (current(live) != old) return GitPushResult.REJECTED
        return GitWire.parseReportStatus(exchange.response, refName, live.supports("side-band-64k"))
    }

    companion object {
        /**
         * What git itself runs: the service name and the single-quoted path. The path's
         * character set was validated, so it needs no further escaping.
         */
        fun remoteCommand(service: GitService, location: GitSshLocation): String {
            var path = location.path
            // `ssh://host/~user/repo` names a home-relative path, as in git.
            if (!location.scpStyle && path.startsWith("/~")) path = path.substring(1)
            return "${service.serviceName} '$path'"
        }
    }
}

/**
 * Maps what `ssh` and a remote git service print on failure to closed codes. The text
 * itself is never kept.
 *
 * Exit status 255 is an OpenSSH client's own failure, so only ssh's own messages count
 * there: a login script's "command not found" or "No such file or directory" must not
 * turn a dropped connection into a permanent stop. Anything else is the remote git's
 * status. (A library connector reports connection and authentication failures itself
 * and reaches this only with the remote's status; the 255 branch is kept for parity
 * and for a connector that runs an `ssh` process.)
 */
object GitSshDiagnosis {
    fun failure(stderr: ByteArray, exitStatus: Int): GitRemoteFailure {
        val text = stderr.decodeUtf8Lossy(0, minOf(stderr.size, 65_536)).lowercase(Locale.ROOT)
        fun has(needle: String): Boolean = text.contains(needle)
        if (exitStatus == 255) {
            if (has("remote host identification has changed") || (has("host key for") && has("has changed"))) {
                return GitRemoteFailure.SshHostKeyChanged()
            }
            if (has("host key verification failed") || has("no ed25519 host key is known") ||
                has("no ecdsa host key is known") || has("host key is not trusted")
            ) {
                return GitRemoteFailure.SshHostKeyUnknown()
            }
            if (has("could not resolve hostname") || has("connection refused") || has("timed out") ||
                has("network is unreachable") || has("no route to host") || has("connection closed") ||
                has("connection reset") || has("broken pipe") || has("closed by remote host")
            ) {
                return GitRemoteFailure.Unreachable("ssh_connection")
            }
            if (has("no matching host key type") || has("no matching key exchange") ||
                has("no matching cipher") || has("no matching mac")
            ) {
                return GitRemoteFailure.UnsupportedServer("ssh_algorithms")
            }
            if (has("permission denied (") || has("too many authentication failures")) {
                return GitRemoteFailure.SshPermissionDenied()
            }
            return GitRemoteFailure.Unreachable("ssh_failed")
        }
        if (has("temporarily") || has("try again later") || has("maintenance")) {
            return GitRemoteFailure.Unreachable("ssh_remote_temporary")
        }
        if (exitStatus == 127 && (has("command not found") || has("not found"))) {
            return GitRemoteFailure.UnsupportedServer("ssh_no_git")
        }
        if (has("repository not found") || has("does not appear to be a git repository") ||
            has("could not be found") || has("not a git repository") || has("project not found")
        ) {
            return GitRemoteFailure.RepositoryNotFound()
        }
        if (has("permission denied") || has("not allowed to push") || has("denied to deploy key") ||
            has("you are not allowed") || has("access denied") || has("write access") ||
            has("marked as read only") || has("read-only key") || has("deploy key is read")
        ) {
            return GitRemoteFailure.SshPermissionDenied()
        }
        return GitRemoteFailure.Unreachable("ssh_remote_failed")
    }
}
