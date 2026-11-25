package com.khm.snippets.core.git

import java.io.OutputStream

/** The two git services, using protocol v0/v1 framing. */
enum class GitService(val serviceName: String) {
    UPLOAD_PACK("git-upload-pack"),
    RECEIVE_PACK("git-receive-pack"),
}

data class GitRefAdvertisement(
    val refs: Map<String, GitObjectId>,
    /** A capability without a value (`side-band-64k`) maps to null. */
    val capabilities: Map<String, String?>,
    /**
     * Where the service endpoints live (HTTP only). Equal to the configured URL unless
     * discovery was redirected (for example `/owner/repo` to `/owner/repo.git`); git
     * itself rebases later requests the same way, because POSTs cannot follow redirects.
     */
    val serviceUrl: String? = null,
) {
    fun supports(capability: String): Boolean = capabilities.containsKey(capability)
}

enum class GitPushResult {
    UPDATED,

    /**
     * The server refused the ref update. Most often the ref moved since discovery;
     * a protected branch or hook rejection looks the same on the wire.
     */
    REJECTED,
}

/**
 * A request body as the pieces it is made of, written one after another, so a push
 * does not need a second copy of its pack just to prepend a command line.
 */
class GitWireBody internal constructor(private val parts: List<ByteArray>) {
    val size: Long = parts.sumOf { it.size.toLong() }

    /** Writes every part in `chunkSize` pieces, calling `progress` after each. */
    fun writeTo(out: OutputStream, chunkSize: Int = 64 * 1024, progress: () -> Unit = {}) {
        for (part in parts) {
            var offset = 0
            while (offset < part.size) {
                val count = minOf(chunkSize, part.size - offset)
                out.write(part, offset, count)
                offset += count
                progress()
            }
        }
    }

    /** One contiguous copy, for tests and small requests. */
    fun toByteArray(): ByteArray {
        val out = ByteArray(Math.toIntExact(size))
        var position = 0
        for (part in parts) {
            System.arraycopy(part, 0, out, position, part.size)
            position += part.size
        }
        return out
    }

    override fun toString(): String = "GitWireBody($size bytes)"

    companion object {
        fun of(vararg parts: ByteArray): GitWireBody = GitWireBody(parts.filter { it.isNotEmpty() })
    }
}

class GitUploadRequest(val body: GitWireBody, val shallow: Boolean, val sideBand: String?)

class GitPushRequest(val body: GitWireBody, val sideBand: Boolean)

/**
 * The git wire protocol (v0/v1) over some byte transport. Smart HTTP and SSH carry
 * identical upload-pack and receive-pack requests; only the framing around them differs.
 */
interface GitWireClient {
    suspend fun discover(service: GitService): GitRefAdvertisement

    /**
     * Downloads a pack containing `want` and everything it needs that is not
     * reachable from `haves` (see [GitWire.uploadRequest] for how haves and `deepen`
     * combine).
     */
    suspend fun fetchPack(want: GitObjectId, haves: List<GitObjectId>, advertisement: GitRefAdvertisement): ByteArray

    /**
     * Atomically moves the remote's ref from `old` to `new`. The server checks `old`
     * under its ref lock, which makes this the compare-and-swap for the whole library.
     *
     * `new == GitObjectId.ZERO` deletes the ref; git then requires that no pack follows.
     */
    suspend fun push(old: GitObjectId, new: GitObjectId, pack: ByteArray, advertisement: GitRefAdvertisement): GitPushResult
}

/** The request and response formats, identical over HTTP and SSH. Pure functions. */
object GitWire {
    const val MAXIMUM_ADVERTISEMENT_BYTES: Long = 8L * 1024 * 1024

    /** The iOS value of the Swift implementation (macOS allows 512 MiB). */
    const val MAXIMUM_PACK_BYTES: Long = 128L * 1024 * 1024

    private const val AGENT = "agent=snippets/1"

    fun parseAdvertisement(data: ByteArray, service: GitService): GitRefAdvertisement {
        val reader = GitPktLine.Reader(data)
        var packet = reader.next()
        if (packet is GitPktLine.Packet.Data && GitPktLine.text(packet.payload).startsWith("# service=")) {
            if (GitPktLine.text(packet.payload) != "# service=${service.serviceName}" ||
                reader.next() != GitPktLine.Packet.Flush
            ) {
                throw GitRemoteFailure.ProtocolViolation("advertisement_header")
            }
            packet = reader.next()
        }
        val refs = LinkedHashMap<String, GitObjectId>()
        val capabilities = LinkedHashMap<String, String?>()
        var first = true
        while (packet is GitPktLine.Packet.Data) {
            val payload = packet.payload
            var end = if (payload.isNotEmpty() && payload.last() == '\n'.code.toByte()) payload.size - 1 else payload.size
            if (first) {
                val nul = payload.indexOfByte(0, 0, end)
                if (nul >= 0) {
                    for (token in payload.decodeUtf8Lossy(nul + 1, end).split(' ')) {
                        if (token.isEmpty()) continue
                        val equals = token.indexOf('=')
                        if (equals >= 0) {
                            capabilities[token.substring(0, equals)] = token.substring(equals + 1)
                        } else {
                            capabilities[token] = null
                        }
                    }
                    end = nul
                }
            }
            first = false
            val text = payload.decodeUtf8Lossy(0, end)
            val space = text.indexOf(' ')
            val id = if (space >= 0) GitObjectId.fromHex(text.substring(0, space)) else null
            if (id == null) throw GitRemoteFailure.ProtocolViolation("advertisement_ref")
            val name = text.substring(space + 1)
            if (name != "capabilities^{}" && !name.endsWith("^{}")) refs[name] = id
            packet = reader.next()
        }
        if (packet != GitPktLine.Packet.Flush && packet != null) {
            throw GitRemoteFailure.ProtocolViolation("advertisement_end")
        }
        // A bare `object-format` (no value) is refused too, as in Swift.
        if (capabilities.containsKey("object-format") && capabilities["object-format"] != "sha1") {
            throw GitRemoteFailure.UnsupportedServer("object_format")
        }
        return GitRefAdvertisement(refs, capabilities)
    }

    /**
     * The upload-pack request.
     *
     * A device with nothing cached asks for the tip alone (`deepen 1`): history would
     * only add superseded ciphertext. A device holding snapshots names them as plain
     * haves, so the server sends just what changed since. (Declaring them shallow
     * instead makes servers resend the whole snapshot.) If the server then leaves out
     * an object it assumed came with history this device never kept, the snapshot
     * install fails and the caller refetches with no haves.
     */
    fun uploadRequest(want: GitObjectId, haves: List<GitObjectId>, advertisement: GitRefAdvertisement): GitUploadRequest {
        val shallow = haves.isEmpty() && advertisement.supports("shallow")
        val sideBand = when {
            advertisement.supports("side-band-64k") -> "side-band-64k"
            advertisement.supports("side-band") -> "side-band"
            else -> null
        }
        val capabilities = buildList {
            add("ofs-delta")
            add("no-progress")
            add(AGENT)
            if (sideBand != null) add(sideBand)
            if (shallow) add("shallow")
        }.filter { it.startsWith("agent=") || advertisement.supports(it) }
        val parts = ArrayList<ByteArray>()
        parts.add(GitPktLine.line("want ${want.hex} ${capabilities.joinToString(" ")}"))
        if (shallow) parts.add(GitPktLine.line("deepen 1"))
        parts.add(GitPktLine.flush)
        for (have in haves) parts.add(GitPktLine.line("have ${have.hex}"))
        parts.add(GitPktLine.line("done"))
        return GitUploadRequest(GitWireBody(parts), shallow, sideBand)
    }

    fun extractPack(bytes: ByteArray, expectsShallowInfo: Boolean, sideBand: String?): ByteArray {
        var reader = GitPktLine.Reader(bytes)
        if (expectsShallowInfo) {
            while (true) {
                val packet = reader.next() ?: throw GitRemoteFailure.ProtocolViolation("shallow_info")
                if (packet == GitPktLine.Packet.Flush) break
                if (packet !is GitPktLine.Packet.Data) throw GitRemoteFailure.ProtocolViolation("shallow_info")
                val text = GitPktLine.text(packet.payload)
                if (text.startsWith("ERR ")) throw GitRemoteFailure.ProtocolViolation("upload_pack_error")
                if (!text.startsWith("shallow ") && !text.startsWith("unshallow ")) {
                    // Some servers skip the section when nothing is shallow; rewind.
                    reader = GitPktLine.Reader(bytes)
                    break
                }
            }
        }
        // Without multi_ack git sends one NAK or "ACK <id>"; GitHub acknowledges every
        // common have. Skip any further acknowledgements before the pack.
        val ack = reader.next() as? GitPktLine.Packet.Data
            ?: throw GitRemoteFailure.ProtocolViolation("acknowledgement")
        val ackText = GitPktLine.text(ack.payload)
        if (ackText.startsWith("ERR ")) throw GitRemoteFailure.ProtocolViolation("upload_pack_error")
        if (ackText != "NAK" && !ackText.startsWith("ACK ")) {
            throw GitRemoteFailure.ProtocolViolation("acknowledgement")
        }
        // Without side-band the pack follows raw, and is not a pkt-line.
        if (sideBand == null) return reader.remainder()
        while (true) {
            val probe = reader.copy()
            val next = try {
                probe.next() as? GitPktLine.Packet.Data
            } catch (_: GitFormatException) {
                null
            } ?: break
            val text = GitPktLine.text(next.payload)
            if (text != "NAK" && !text.startsWith("ACK ")) break
            reader = probe
        }
        return demultiplex(reader)
    }

    /** Band 1 is payload, band 2 progress, band 3 a fatal error from the server. */
    fun demultiplex(reader: GitPktLine.Reader): ByteArray = reader.demultiplex()

    /** The receive-pack request. */
    fun pushRequest(
        old: GitObjectId,
        new: GitObjectId,
        refName: String,
        pack: ByteArray,
        advertisement: GitRefAdvertisement,
    ): GitPushRequest {
        if (!advertisement.supports("report-status")) throw GitRemoteFailure.UnsupportedServer("report_status")
        if (new.isZero && (pack.isNotEmpty() || !advertisement.supports("delete-refs"))) {
            throw GitRemoteFailure.UnsupportedServer("delete_refs")
        }
        val sideBand = advertisement.supports("side-band-64k")
        val capabilities = buildList {
            add("report-status")
            add(AGENT)
            if (sideBand) add("side-band-64k")
            if (advertisement.supports("quiet")) add("quiet")
        }
        val command = "${old.hex} ${new.hex} $refName".toByteArray(Charsets.UTF_8) + 0.toByte() +
            (capabilities.joinToString(" ") + "\n").toByteArray(Charsets.UTF_8)
        return GitPushRequest(GitWireBody.of(GitPktLine.encode(command), GitPktLine.flush, pack), sideBand)
    }

    fun parseReportStatus(bytes: ByteArray, refName: String, sideBand: Boolean): GitPushResult {
        // Over side-band the report is itself pkt-lines inside band 1: unwrap first.
        val status = if (sideBand) demultiplex(GitPktLine.Reader(bytes)) else bytes
        val reader = GitPktLine.Reader(status)
        val unpack = reader.next() as? GitPktLine.Packet.Data
            ?: throw GitRemoteFailure.ProtocolViolation("report_status")
        val unpackText = GitPktLine.text(unpack.payload)
        if (!unpackText.startsWith("unpack ")) throw GitRemoteFailure.ProtocolViolation("report_status")
        if (unpackText != "unpack ok") throw GitRemoteFailure.ProtocolViolation("remote_unpack_failed")
        var result: GitPushResult? = null
        while (true) {
            val packet = reader.next() as? GitPktLine.Packet.Data ?: break
            val text = GitPktLine.text(packet.payload)
            if (text == "ok $refName") {
                result = GitPushResult.UPDATED
            } else if (text.startsWith("ng $refName ")) {
                result = GitPushResult.REJECTED
            }
        }
        return result ?: throw GitRemoteFailure.ProtocolViolation("report_status")
    }
}
