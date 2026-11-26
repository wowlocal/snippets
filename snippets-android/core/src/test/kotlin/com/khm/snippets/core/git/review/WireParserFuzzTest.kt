package com.khm.snippets.core.git.review

import com.khm.snippets.core.git.GitCommit
import com.khm.snippets.core.git.GitFormatException
import com.khm.snippets.core.git.GitObjectId
import com.khm.snippets.core.git.GitObjectType
import com.khm.snippets.core.git.GitPktLine
import com.khm.snippets.core.git.GitPushResult
import com.khm.snippets.core.git.GitRemoteFailure
import com.khm.snippets.core.git.GitService
import com.khm.snippets.core.git.GitTree
import com.khm.snippets.core.git.GitTreeEntry
import com.khm.snippets.core.git.GitWire
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Review: everything a server sends outside a pack (advertisements, shallow and
 * acknowledgement sections, side-band frames, push reports, trees, commits) parsed
 * from mutated and random bytes. The only acceptable ends are a value or one of the
 * two closed error types; an `IndexOutOfBounds`, `NumberFormat` or `NegativeArraySize`
 * would be a crash on hostile input.
 *
 * All of these pass. (`GitPackPropertyTest` already does the same for packs.)
 */
class WireParserFuzzTest {
    private val head = GitObjectId.hash(GitObjectType.BLOB, "head".toByteArray())

    private fun mutate(random: Random, original: ByteArray): ByteArray {
        var bytes = original.copyOf()
        repeat(1 + random.nextInt(3)) {
            val position = if (bytes.isEmpty()) 0 else random.nextInt(bytes.size)
            bytes = when (random.nextInt(9)) {
                0, 1 -> bytes.also { if (it.isNotEmpty()) it[position] = (it[position].toInt() xor (1 shl random.nextInt(8))).toByte() }
                2 -> bytes.also { if (it.isNotEmpty()) it[position] = random.nextInt(256).toByte() }
                3 -> bytes.copyOf(position)
                4 -> bytes.copyOfRange(0, position) + random.nextInt(256).toByte() + bytes.copyOfRange(position, bytes.size)
                5 -> bytes.copyOfRange(0, position) + bytes.copyOfRange(minOf(bytes.size, position + 1 + random.nextInt(6)), bytes.size)
                // A hostile length prefix, of either sign and any size.
                6 -> bytes.copyOfRange(0, position) + listOf("ffff", "fff0", "0000", "0001", "0002", "0003", "0004", "0005", "-001", "+00a", "FFFF", "00g0")
                    .random(random).toByteArray() + bytes.copyOfRange(position, bytes.size)
                7 -> bytes + bytes.copyOfRange(position, bytes.size)
                else -> bytes.copyOfRange(position, bytes.size) + bytes.copyOfRange(0, position)
            }
        }
        return bytes
    }

    private inline fun closed(context: () -> String, block: () -> Unit) {
        try {
            block()
        } catch (_: GitFormatException) {
        } catch (_: GitRemoteFailure) {
        } catch (error: Throwable) {
            fail("${context()}: ${error.javaClass.name}: ${error.message}")
        }
    }

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    @Test fun advertisementsNeverEscapeTheClosedErrors() {
        val seeds = listOf(
            GitPktLine.line("# service=git-upload-pack") + GitPktLine.flush +
                GitPktLine.encode("${head.hex} HEAD".toByteArray() + 0.toByte() + "multi_ack side-band-64k shallow object-format=sha1 agent=git/2.50 symref=HEAD:refs/heads/main\n".toByteArray()) +
                GitPktLine.line("${head.hex} refs/heads/main") + GitPktLine.line("${head.hex} refs/tags/v1^{}") + GitPktLine.flush,
            GitPktLine.encode("${"0".repeat(40)} capabilities^{}".toByteArray() + 0.toByte() + "report-status delete-refs quiet\n".toByteArray()) + GitPktLine.flush,
            GitPktLine.flush,
        )
        val random = Random(1)
        repeat(40_000) { round ->
            val bytes = if (round % 10 == 0) random.nextBytes(random.nextInt(64)) else mutate(random, seeds[round % seeds.size])
            for (service in GitService.entries) {
                closed({ "advertisement ${hex(bytes)}" }) {
                    val parsed = GitWire.parseAdvertisement(bytes, service)
                    // Whatever is accepted is usable for building both requests.
                    closed({ "upload request after ${hex(bytes)}" }) { GitWire.uploadRequest(head, listOf(head), parsed).body.toByteArray() }
                    closed({ "push request after ${hex(bytes)}" }) { GitWire.pushRequest(head, head, "refs/heads/main", ByteArray(4), parsed).body.toByteArray() }
                }
            }
            closed({ "advertisementEnd ${hex(bytes)}" }) {
                val end = GitPktLine.advertisementEnd(bytes)
                if (end != null) assertTrue(end in 4..bytes.size, "end $end of ${bytes.size}")
            }
            // Arriving one byte at a time gives the same answer as arriving at once.
            val whole = runCatching { GitPktLine.advertisementEnd(bytes) }
            var streamed: Result<Int?> = Result.success(null)
            for (length in 0..bytes.size) {
                streamed = runCatching { GitPktLine.advertisementEnd(bytes, length) }
                if (streamed.isFailure || streamed.getOrNull() != null) break
            }
            assertEquals(whole.isFailure, streamed.isFailure, hex(bytes))
            assertEquals(whole.getOrNull(), streamed.getOrNull(), hex(bytes))
        }
    }

    @Test fun uploadPackResponsesNeverEscapeTheClosedErrors() {
        val payload = Random(9).nextBytes(5_000)
        fun banded(frame: Int): ByteArray {
            var out = ByteArray(0)
            var offset = 0
            while (offset < payload.size) {
                val count = minOf(frame, payload.size - offset)
                out += GitPktLine.encode(byteArrayOf(1) + payload.copyOfRange(offset, offset + count))
                out += GitPktLine.encode(byteArrayOf(2) + "progress\n".toByteArray())
                offset += count
            }
            return out
        }
        val seeds = listOf(
            GitPktLine.line("NAK") + banded(700) + GitPktLine.flush,
            GitPktLine.line("shallow ${head.hex}") + GitPktLine.line("unshallow ${head.hex}") + GitPktLine.flush +
                GitPktLine.line("ACK ${head.hex}") + GitPktLine.line("ACK ${head.hex}") + GitPktLine.line("NAK") + banded(65_000) + GitPktLine.flush,
            GitPktLine.line("NAK") + payload,
        )
        val random = Random(2)
        var delivered = 0
        repeat(20_000) { round ->
            val bytes = mutate(random, seeds[round % seeds.size])
            for (shallow in listOf(false, true)) {
                for (sideBand in listOf(null, "side-band", "side-band-64k")) {
                    closed({ "extractPack(shallow=$shallow, sideBand=$sideBand) ${hex(bytes.copyOf(minOf(bytes.size, 80)))}" }) {
                        val pack = GitWire.extractPack(bytes, shallow, sideBand)
                        assertTrue(pack.size <= bytes.size)
                        delivered += 1
                    }
                }
            }
        }
        assertTrue(delivered > 0)
        // Unmutated, every seed yields exactly the payload.
        assertContentEquals(payload, GitWire.extractPack(seeds[0], false, "side-band-64k"))
        assertContentEquals(payload, GitWire.extractPack(seeds[1], true, "side-band-64k"))
        assertContentEquals(payload, GitWire.extractPack(seeds[2], false, null))
    }

    /** A push is `UPDATED` only on the server's `ok <ref>` after `unpack ok`, however the report is damaged. */
    @Test fun pushReportsNeverEscapeTheClosedErrorsNorInventSuccess() {
        val ref = "refs/heads/main"
        val plain = GitPktLine.line("unpack ok") + GitPktLine.line("ok $ref") + GitPktLine.flush
        val rejected = GitPktLine.line("unpack ok") + GitPktLine.line("ng $ref non-fast-forward") + GitPktLine.flush
        val seeds = listOf(
            plain, rejected, GitPktLine.encode(byteArrayOf(1) + plain) + GitPktLine.flush,
            GitPktLine.encode(byteArrayOf(2) + "remote: hello\n".toByteArray()) + GitPktLine.encode(byteArrayOf(1) + rejected) + GitPktLine.flush,
            GitPktLine.line("unpack index-pack failed") + GitPktLine.line("ng $ref unpacker error") + GitPktLine.flush,
        )
        val random = Random(3)
        repeat(60_000) { round ->
            val bytes = mutate(random, seeds[round % seeds.size])
            for (sideBand in listOf(false, true)) {
                closed({ "report(sideBand=$sideBand) ${hex(bytes)}" }) {
                    if (GitWire.parseReportStatus(bytes, ref, sideBand) == GitPushResult.UPDATED) {
                        val text = (if (sideBand) GitWire.demultiplex(GitPktLine.Reader(bytes)) else bytes).toString(Charsets.ISO_8859_1)
                        assertTrue(text.contains("unpack ok"), hex(bytes))
                        assertTrue(Regex("ok refs/heads/main(\\n|[0-9a-fA-F]{4}|$)").containsMatchIn(text), hex(bytes))
                    }
                }
            }
        }
        // Another ref's `ok`, or `ok` for a longer name, is not this ref's.
        for (line in listOf("ok refs/heads/main2", "ok refs/heads/mai", "OK $ref", "ok  $ref", "ok $ref ", "ok $ref\u0000", "okay $ref")) {
            val report = GitPktLine.line("unpack ok") + GitPktLine.line(line) + GitPktLine.flush
            assertEquals(
                GitRemoteFailure.ProtocolViolation("report_status"),
                runCatching { GitWire.parseReportStatus(report, ref, false) }.exceptionOrNull(),
                line,
            )
        }
    }

    @Test fun treesAndCommitsNeverEscapeTheClosedError() {
        val tree = GitTree.serialize(
            listOf(
                GitTreeEntry.tree("records", head), GitTreeEntry.blob("README.md", head),
                GitTreeEntry("100755".toByteArray(), byteArrayOf(0xff.toByte(), 0xfe.toByte()), head),
                GitTreeEntry("120000".toByteArray(), "link".toByteArray(), head),
            ),
        )
        val commit = GitCommit.serialize(head, listOf(head, head), 1_700_000_000, "Sync 2 records") +
            "\ntree ${head.hex}\nparent zz\n".toByteArray()
        val random = Random(4)
        repeat(60_000) { round ->
            val bytes = mutate(random, if (round % 2 == 0) tree else commit)
            try {
                val entries = GitTree.parse(bytes)
                // What parses is preserved byte for byte when it is written back in git's order.
                if (GitTree.sorted(entries) == entries) assertContentEquals(bytes, GitTree.serialize(entries), hex(bytes))
            } catch (_: GitFormatException) {
            } catch (error: Throwable) {
                fail("tree ${hex(bytes)}: $error")
            }
            try {
                GitCommit.parse(bytes)
            } catch (_: GitFormatException) {
            } catch (error: Throwable) {
                fail("commit ${hex(bytes)}: $error")
            }
        }
    }
}
