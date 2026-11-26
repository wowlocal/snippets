package com.khm.snippets.core.git.review

import com.khm.snippets.core.git.GitFormatException
import com.khm.snippets.core.git.GitObject
import com.khm.snippets.core.git.GitObjectId
import com.khm.snippets.core.git.GitObjectType
import com.khm.snippets.core.git.GitPack
import com.khm.snippets.core.git.GitPktLine
import com.khm.snippets.core.git.GitPushResult
import com.khm.snippets.core.git.GitRefAdvertisement
import com.khm.snippets.core.git.GitRemote
import com.khm.snippets.core.git.GitRemoteFailure
import com.khm.snippets.core.git.GitService
import com.khm.snippets.core.git.GitSshClient
import com.khm.snippets.core.git.GitSshConnector
import com.khm.snippets.core.git.GitSshLocation
import com.khm.snippets.core.git.testing.FakeSshConnector
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * Review: `GitSshExchangeRunner` and `GitSshClient` against a service that stops,
 * lies or floods at every possible point. Each exchange must end promptly, with a
 * value or one of the closed errors, and must release its channel.
 *
 * All of these pass: no defect was found in the exchange framing.
 */
class SshExchangeAdversarialTest {
    private val location = GitSshLocation(user = "git", host = "h", port = null, path = "r.git", scpStyle = true)
    private val remote = GitRemote.ssh(location, "main")
    private val blob = GitObject(GitObjectType.BLOB, ByteArray(3_000).also { Random(5).nextBytes(it) })
    private val head = blob.id
    private val next = GitObjectId.hash(GitObjectType.BLOB, "next".toByteArray())
    private val pack = GitPack.build(listOf(blob))

    private fun advertisement(vararg capabilities: String): ByteArray =
        GitPktLine.encode("${head.hex} refs/heads/main".toByteArray() + 0.toByte() + (capabilities.joinToString(" ") + "\n").toByteArray()) +
            GitPktLine.line("${head.hex} refs/heads/other") + GitPktLine.flush

    private fun sideBand(band: Int, payload: ByteArray, frame: Int = 1_000): ByteArray {
        var out = ByteArray(0)
        var offset = 0
        while (offset < payload.size) {
            val count = minOf(frame, payload.size - offset)
            out += GitPktLine.encode(byteArrayOf(band.toByte()) + payload.copyOfRange(offset, offset + count))
            offset += count
        }
        return out
    }

    private fun client(connector: GitSshConnector, idleTimeoutMillis: Long = 20_000) =
        GitSshClient(remote, location, connector, idleTimeoutMillis = idleTimeoutMillis)

    private fun <T> outcome(block: suspend () -> T): Result<T> = runCatching { runBlocking { withTimeout(30_000) { block() } } }

    private fun assertClosed(error: Throwable?, context: String) {
        if (error !is GitRemoteFailure && error !is GitFormatException) fail("$context: not a closed error: $error")
    }

    /**
     * The service's whole output for a fetch, cut after every byte, ending with exit
     * status 0, a failing status, or no status at all (the connection went away).
     */
    @Test fun aFetchCutAnywhereEndsWithThePackOrAClosedError() {
        val full = advertisement("side-band-64k", "ofs-delta") + GitPktLine.line("NAK") +
            sideBand(2, "progress".toByteArray()) + sideBand(1, pack) + GitPktLine.flush
        val statuses = listOf<Int?>(0, 128, null)
        var delivered = 0
        for (cut in 0..full.size) {
            val status = statuses[cut % statuses.size]
            val connector = FakeSshConnector { server ->
                // In two writes, so the cut also moves across the reader's chunk boundaries.
                server.send(full.copyOfRange(0, cut / 2))
                server.send(full.copyOfRange(cut / 2, cut))
                status
            }
            val result = outcome { client(connector).fetchPack(head, emptyList(), GitRefAdvertisement(emptyMap(), emptyMap())) }
            val bytes = result.getOrNull()
            if (bytes != null) {
                // A status-less or clean end is accepted when the advertisement was whole;
                // what was cut is then caught by the pack's own checksum.
                assertTrue(status == 0 || status == null, "cut $cut: a pack from a failed service")
                val parsed = runCatching { GitPack.parse(bytes) }
                if (parsed.isSuccess) {
                    delivered += 1
                    assertContentEquals(pack, bytes, "cut $cut")
                } else {
                    assertIs<GitFormatException>(parsed.exceptionOrNull(), "cut $cut")
                }
            } else {
                assertClosed(result.exceptionOrNull(), "cut $cut, status $status")
            }
            assertEquals(connector.channelsOpened, connector.channelsClosed, "cut $cut")
        }
        assertTrue(delivered >= 1, "the uncut exchange delivers the pack")
    }

    /** The same for a push: it is `UPDATED` only when the report really said so. */
    @Test fun aPushReportCutAnywhereIsNeverTakenForSuccess() {
        val report = GitPktLine.line("unpack ok") + GitPktLine.line("ok refs/heads/main") + GitPktLine.flush
        val full = advertisement("report-status", "side-band-64k") + sideBand(1, report, frame = 7) + GitPktLine.flush
        val okLineEnd = advertisement("report-status", "side-band-64k").size // everything after is the report
        var updated = 0
        for (cut in 0..full.size) {
            val status: Int? = if (cut % 2 == 0) 0 else null
            val connector = FakeSshConnector { server ->
                server.send(full.copyOfRange(0, cut))
                status
            }
            val result = outcome { client(connector).push(head, next, pack, GitRefAdvertisement(emptyMap(), emptyMap())) }
            if (result.isSuccess) {
                assertEquals(GitPushResult.UPDATED, result.getOrNull(), "cut $cut")
                // Band-1 frames of 7 bytes: the `ok` line is complete only near the very end.
                val demultiplexed = runCatching {
                    com.khm.snippets.core.git.GitWire.demultiplex(GitPktLine.Reader(full.copyOfRange(okLineEnd, cut)))
                }.getOrNull()?.toString(Charsets.UTF_8) ?: ""
                assertTrue(demultiplexed.contains("ok refs/heads/main\n"), "cut $cut: UPDATED without the server's word for it")
                updated += 1
            } else {
                assertClosed(result.exceptionOrNull(), "cut $cut")
            }
            assertEquals(connector.channelsOpened, connector.channelsClosed, "cut $cut")
        }
        assertTrue(updated >= 1)
    }

    @Test fun sideBandMisuseIsAClosedViolation() {
        fun fetch(response: ByteArray): Throwable? {
            val connector = FakeSshConnector { server ->
                server.send(advertisement("side-band-64k"))
                server.readRequest()
                server.send(response)
                0
            }
            return outcome { client(connector).fetchPack(head, emptyList(), GitRefAdvertisement(emptyMap(), emptyMap())) }.exceptionOrNull()
        }
        val nak = GitPktLine.line("NAK")
        assertEquals(GitRemoteFailure.ProtocolViolation("remote_error"), fetch(nak + sideBand(1, pack) + sideBand(3, "fatal: secret-path".toByteArray())))
        assertEquals(GitRemoteFailure.ProtocolViolation("side_band"), fetch(nak + sideBand(4, pack)))
        assertEquals(GitRemoteFailure.ProtocolViolation("side_band"), fetch(nak + sideBand(0, pack)))
        assertEquals(GitRemoteFailure.ProtocolViolation("side_band"), fetch(nak + sideBand(255, pack)))
        assertEquals(GitRemoteFailure.ProtocolViolation("side_band"), fetch(nak + "0004".toByteArray()))
        assertEquals(GitRemoteFailure.ProtocolViolation("side_band"), fetch(nak + sideBand(1, pack) + "0001".toByteArray()))
        assertEquals(GitRemoteFailure.ProtocolViolation("side_band"), fetch(nak + sideBand(1, pack) + "0002".toByteArray()))
        assertEquals(GitFormatException.invalidPktLine(), fetch(nak + sideBand(1, pack) + "0003".toByteArray()))
        assertEquals(GitFormatException.invalidPktLine(), fetch(nak + sideBand(1, pack) + "fff0".toByteArray()))
        assertEquals(GitRemoteFailure.ProtocolViolation("upload_pack_error"), fetch(GitPktLine.line("ERR access denied to secret-path")))
        assertEquals(GitRemoteFailure.ProtocolViolation("acknowledgement"), fetch(GitPktLine.flush))
        assertEquals(GitRemoteFailure.ProtocolViolation("acknowledgement"), fetch(ByteArray(0)))
        // The raw pack sent although side-band was negotiated.
        assertIs<GitFormatException>(fetch(nak + pack))
        // Bytes after the closing flush are not part of the pack.
        val trailing = outcome {
            client(FakeSshConnector { server ->
                server.send(advertisement("side-band-64k"))
                server.readRequest()
                server.send(nak + sideBand(1, pack) + GitPktLine.flush + sideBand(1, "junk".toByteArray()))
                0
            }).fetchPack(head, emptyList(), GitRefAdvertisement(emptyMap(), emptyMap()))
        }
        assertContentEquals(pack, trailing.getOrThrow())
    }

    /** A megabyte of diagnostics per exchange is drained, capped and never returned. */
    @Test fun aFloodOfDiagnosticsNeitherBlocksNorLeaks() {
        val noise = ByteArray(4 * 1024 * 1024) { 'x'.code.toByte() }
        val connector = FakeSshConnector(pipeCapacity = 32 * 1024) { server ->
            val flood = thread { runCatching { server.errors.write(noise) } }
            server.send(advertisement("side-band-64k"))
            server.readRequest()
            flood.join()
            server.errors.write("fatal: repository not found: secret-path\n".toByteArray())
            128
        }
        val failure = outcome { client(connector).discover(GitService.UPLOAD_PACK) }.exceptionOrNull()
        // Only the first 64 KiB are looked at, so the last line is not what decides.
        assertEquals(GitRemoteFailure.Unreachable("ssh_remote_failed"), failure)
        assertTrue(!failure.toString().contains("secret-path") && !failure!!.stackTraceToString().contains("secret-path"))
        assertEquals(1, connector.channelsClosed)
    }

    @Test fun manyExchangesAtOnceAllComplete() {
        val served = AtomicInteger()
        val connector = FakeSshConnector { server ->
            server.send(advertisement("side-band-64k"))
            server.readRequest()
            served.incrementAndGet()
            0
        }
        val results = runBlocking {
            withTimeout(60_000) {
                (0 until 16).map { async(Dispatchers.Default) { client(connector).discover(GitService.UPLOAD_PACK) } }.awaitAll()
            }
        }
        assertEquals(16, results.size)
        assertEquals(16, served.get())
        assertEquals(16, connector.channelsClosed)
    }
}
