package com.khm.snippets.core.git

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Port of `GitSSHFramingTests` (Tests/Core/GitSSHTests.swift), same test names, plus wire-format cases. */
class GitSshFramingTest {
    private fun utf8(text: String) = text.toByteArray(Charsets.UTF_8)

    private fun violation(detail: String) = GitRemoteFailure.ProtocolViolation(detail)

    // MARK: Swift

    /** GitHub acknowledges every common have, not just the first. */
    @Test fun extraAcknowledgementsBeforeThePackAreSkipped() {
        var bytes = ByteArray(0)
        for (line in listOf("ACK ${"a".repeat(40)}", "ACK ${"b".repeat(40)}", "NAK")) bytes += GitPktLine.line(line)
        bytes += GitPktLine.encode(byteArrayOf(1) + utf8("PACK"))
        bytes += GitPktLine.flush
        val pack = GitWire.extractPack(bytes, expectsShallowInfo = false, sideBand = "side-band-64k")
        assertContentEquals(utf8("PACK"), pack)
    }

    /** Without side-band the pack follows the acknowledgement raw; it is not a pkt-line. */
    @Test fun aPackWithoutSideBandIsReadRaw() {
        val raw = utf8("PACK\u0000\u0000\u0000\u0002rest")
        val pack = GitWire.extractPack(GitPktLine.line("NAK") + raw, expectsShallowInfo = false, sideBand = null)
        assertContentEquals(raw, pack)
    }

    @Test fun onlyAnEmptyCacheAsksForAShallowTip() {
        var advertisement = GitRefAdvertisement(emptyMap(), mapOf("shallow" to null, "side-band-64k" to null))
        val want = GitObjectId.hash(GitObjectType.BLOB, utf8("w"))
        val have = GitObjectId.hash(GitObjectType.BLOB, utf8("h"))
        val fresh = GitWire.uploadRequest(want, emptyList(), advertisement)
        assertTrue(fresh.shallow)
        assertTrue(fresh.body.toByteArray().toString(Charsets.UTF_8).contains("deepen 1"))
        val incremental = GitWire.uploadRequest(want, listOf(have), advertisement)
        assertFalse(incremental.shallow)
        val text = incremental.body.toByteArray().toString(Charsets.UTF_8)
        assertTrue(!text.contains("deepen") && !text.contains("shallow"))
        assertTrue(text.contains("have ${have.hex}"))
        advertisement = advertisement.copy(capabilities = advertisement.capabilities - "shallow")
        assertFalse(GitWire.uploadRequest(want, emptyList(), advertisement).shallow)
    }

    @Test fun advertisementEndIsTheFirstFlush() {
        var bytes = GitPktLine.line("abc") + GitPktLine.flush
        assertNull(GitPktLine.advertisementEnd(bytes.copyOf(3)))
        assertNull(GitPktLine.advertisementEnd(bytes.copyOf(bytes.size - 1)))
        assertEquals(bytes.size, GitPktLine.advertisementEnd(bytes))
        bytes += utf8("PACK")
        assertEquals(bytes.size - 4, GitPktLine.advertisementEnd(bytes))
        assertEquals(
            GitFormatException.invalidPktLine(),
            assertFailsWith<GitFormatException> { GitPktLine.advertisementEnd(utf8("-00a")) },
        )
        assertEquals(
            GitFormatException.invalidPktLine(),
            assertFailsWith<GitFormatException> { GitPktLine.advertisementEnd(utf8("0002")) },
        )
    }

    @Test fun sshFailuresBecomeClosedCodes() {
        fun code(text: String, status: Int = 255): GitRemoteFailure = GitSshDiagnosis.failure(utf8(text), status)
        assertEquals(GitRemoteFailure.SshHostKeyUnknown(), code("Host key verification failed."))
        assertEquals(
            GitRemoteFailure.SshHostKeyChanged(),
            code("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed."),
        )
        assertEquals(GitRemoteFailure.SshPermissionDenied(), code("git@github.com: Permission denied (publickey)."))
        assertEquals(GitRemoteFailure.SshPermissionDenied(), code("ERROR: Permission to me/lib.git denied to deploy key", 128))
        assertEquals(GitRemoteFailure.RepositoryNotFound(), code("ERROR: Repository not found.", 128))
        assertEquals(GitRemoteFailure.RepositoryNotFound(), code("fatal: '/x' does not appear to be a git repository", 128))
        assertEquals(
            GitRemoteFailure.Unreachable("ssh_connection"),
            code("ssh: Could not resolve hostname nope: nodename nor servname provided"),
        )
        assertEquals(
            GitRemoteFailure.UnsupportedServer("ssh_algorithms"),
            code("Unable to negotiate with 1.2.3.4 port 22: no matching host key type found"),
        )
        assertEquals(GitRemoteFailure.UnsupportedServer("ssh_no_git"), code("sh: git-upload-pack: command not found", 127))
        assertEquals(GitRemoteFailure.Unreachable("ssh_failed"), code("something else"))
        // A login script's noise on an ssh-level failure is not the remote git speaking.
        assertEquals(
            GitRemoteFailure.Unreachable("ssh_connection"),
            code("bash: brew: command not found\nclient_loop: send disconnect: Broken pipe"),
        )
        assertEquals(
            GitRemoteFailure.Unreachable("ssh_connection"),
            code(".profile: line 3: /opt/x: No such file or directory\nConnection to h closed by remote host."),
        )
        assertEquals(GitRemoteFailure.Unreachable("ssh_failed"), code("bash: brew: command not found", 255))
        assertEquals(
            GitRemoteFailure.Unreachable("ssh_remote_temporary"),
            code("The repository is temporarily read-only. Please try again later.", 1),
        )
        assertEquals(
            GitRemoteFailure.SshPermissionDenied(),
            code("ERROR: The key you are authenticating with has been marked as read only.", 1),
        )
    }

    // MARK: Request bytes

    private val want = GitObjectId.fromHex("ce013625030ba8dba906f756967f9e9ca394464a")!!
    private val have = GitObjectId.fromHex("4b825dc642cb6eb9a060e54bf8d69288fbee4904")!!

    private fun advertisement(vararg capabilities: String) =
        GitRefAdvertisement(emptyMap(), capabilities.associate { it to null })

    /** A pkt-line built without `GitPktLine`, so the expected bytes are independent of the code under test. */
    private fun pkt(text: String) = "%04x".format(text.toByteArray(Charsets.UTF_8).size + 4) + text

    @Test fun uploadRequestBytesAreExactlyThoseOfSwift() {
        val full = advertisement("multi_ack", "thin-pack", "side-band", "side-band-64k", "ofs-delta", "shallow", "no-progress", "agent")
        assertEquals(
            pkt("want ${want.hex} ofs-delta no-progress agent=snippets/1 side-band-64k shallow\n") +
                "000ddeepen 1\n" + "0000" + "0009done\n",
            GitWire.uploadRequest(want, emptyList(), full).body.toByteArray().toString(Charsets.UTF_8),
        )
        val incremental = GitWire.uploadRequest(want, listOf(have, want), full)
        assertEquals(
            pkt("want ${want.hex} ofs-delta no-progress agent=snippets/1 side-band-64k\n") + "0000" +
                "0032have ${have.hex}\n" + "0032have ${want.hex}\n" + "0009done\n",
            incremental.body.toByteArray().toString(Charsets.UTF_8),
        )
        assertEquals("side-band-64k", incremental.sideBand)
        // Only what the server advertises is requested, except the agent.
        val bare = GitWire.uploadRequest(want, emptyList(), advertisement())
        assertEquals(
            "0043want ${want.hex} agent=snippets/1\n" + "0000" + "0009done\n",
            bare.body.toByteArray().toString(Charsets.UTF_8),
        )
        assertNull(bare.sideBand)
        assertFalse(bare.shallow)
        assertEquals("side-band", GitWire.uploadRequest(want, emptyList(), advertisement("side-band")).sideBand)
    }

    @Test fun pushRequestBytesAreExactlyThoseOfSwift() {
        val pack = utf8("PACKDATA")
        val refName = "refs/heads/main"
        val full = advertisement("report-status", "delete-refs", "side-band-64k", "quiet", "atomic", "ofs-delta", "push-options")
        val request = GitWire.pushRequest(GitObjectId.ZERO, want, refName, pack, full)
        val command = "${"0".repeat(40)} ${want.hex} $refName\u0000report-status agent=snippets/1 side-band-64k quiet\n"
        assertEquals(pkt(command) + "0000" + "PACKDATA", request.body.toByteArray().toString(Charsets.UTF_8))
        assertTrue(request.sideBand)
        assertEquals(request.body.size, request.body.toByteArray().size.toLong())

        val plain = GitWire.pushRequest(have, want, refName, pack, advertisement("report-status"))
        val plainCommand = "${have.hex} ${want.hex} $refName\u0000report-status agent=snippets/1\n"
        assertEquals(pkt(plainCommand) + "0000" + "PACKDATA", plain.body.toByteArray().toString(Charsets.UTF_8))
        assertFalse(plain.sideBand)

        assertEquals(
            GitRemoteFailure.UnsupportedServer("report_status"),
            assertFailsWith<GitRemoteFailure> { GitWire.pushRequest(have, want, refName, pack, advertisement("side-band-64k")) },
        )
        // A delete carries no pack and needs `delete-refs`.
        assertEquals(
            GitRemoteFailure.UnsupportedServer("delete_refs"),
            assertFailsWith<GitRemoteFailure> { GitWire.pushRequest(have, GitObjectId.ZERO, refName, ByteArray(0), advertisement("report-status")) },
        )
        assertEquals(
            GitRemoteFailure.UnsupportedServer("delete_refs"),
            assertFailsWith<GitRemoteFailure> { GitWire.pushRequest(have, GitObjectId.ZERO, refName, pack, full) },
        )
        val delete = GitWire.pushRequest(have, GitObjectId.ZERO, refName, ByteArray(0), full)
        assertTrue(delete.body.toByteArray().toString(Charsets.UTF_8).endsWith("quiet\n0000"))
    }

    // MARK: Responses

    private fun band(band: Int, payload: ByteArray) = GitPktLine.encode(byteArrayOf(band.toByte()) + payload)

    @Test fun sideBandCarriesThePackInBandOne() {
        val response = GitPktLine.line("NAK") + band(2, utf8("progress")) + band(1, utf8("PA")) +
            band(2, utf8("more")) + band(1, utf8("CK")) + GitPktLine.flush + utf8("ignored")
        assertContentEquals(utf8("PACK"), GitWire.extractPack(response, false, "side-band-64k"))
        // The end of the data ends the stream as well as a flush does.
        assertContentEquals(utf8("PA"), GitWire.extractPack(GitPktLine.line("NAK") + band(1, utf8("PA")), false, "side-band"))
        assertEquals(
            violation("remote_error"),
            assertFailsWith<GitRemoteFailure> { GitWire.extractPack(GitPktLine.line("NAK") + band(3, utf8("fatal: x")), false, "side-band-64k") },
        )
        for (broken in listOf(band(4, utf8("x")), GitPktLine.encode(ByteArray(0)), utf8("0001"), utf8("0002"))) {
            assertEquals(
                violation("side_band"),
                assertFailsWith<GitRemoteFailure> { GitWire.extractPack(GitPktLine.line("NAK") + band(1, utf8("P")) + broken, false, "side-band-64k") },
            )
        }
        assertFailsWith<GitFormatException> { GitWire.extractPack(GitPktLine.line("NAK") + utf8("00"), false, "side-band-64k") }
    }

    @Test fun demultiplexingCopiesEveryBandOneByteOnce() {
        val random = java.util.Random(7)
        val expected = java.io.ByteArrayOutputStream()
        var stream = ByteArray(0)
        repeat(200) {
            val payload = ByteArray(random.nextInt(GitPktLine.MAXIMUM_PAYLOAD - 1) + 1).also(random::nextBytes)
            if (random.nextInt(4) == 0) {
                stream += band(2, payload.copyOf(minOf(payload.size, 100)))
            } else {
                stream += band(1, payload)
                expected.write(payload)
            }
        }
        val reader = GitPktLine.Reader(stream + GitPktLine.flush + GitPktLine.line("after"))
        assertContentEquals(expected.toByteArray(), GitWire.demultiplex(reader))
        assertEquals(GitPktLine.Packet.Data(utf8("after\n")), reader.next())
    }

    @Test fun shallowSectionIsReadOrRewoundWhenTheServerOmitsIt() {
        val pack = band(1, utf8("PACK")) + GitPktLine.flush
        val shallow = GitPktLine.line("shallow ${want.hex}") + GitPktLine.line("unshallow ${have.hex}") + GitPktLine.flush
        assertContentEquals(utf8("PACK"), GitWire.extractPack(shallow + GitPktLine.line("NAK") + pack, true, "side-band-64k"))
        // Some servers skip the section when nothing is shallow.
        assertContentEquals(utf8("PACK"), GitWire.extractPack(GitPktLine.line("NAK") + pack, true, "side-band-64k"))
        assertContentEquals(utf8("PACK"), GitWire.extractPack(GitPktLine.line("ACK ${have.hex}") + pack, true, "side-band-64k"))
        assertEquals(
            violation("shallow_info"),
            assertFailsWith<GitRemoteFailure> { GitWire.extractPack(ByteArray(0), true, null) },
        )
        assertEquals(
            violation("shallow_info"),
            assertFailsWith<GitRemoteFailure> { GitWire.extractPack(GitPktLine.line("shallow ${want.hex}"), true, null) },
        )
        assertEquals(
            violation("shallow_info"),
            assertFailsWith<GitRemoteFailure> { GitWire.extractPack(GitPktLine.line("shallow ${want.hex}") + utf8("0001"), true, null) },
        )
        // As in Swift, the rewind goes back to the very start: a section that begins
        // but is not closed by a flush is then read as a bad acknowledgement.
        assertEquals(
            violation("acknowledgement"),
            assertFailsWith<GitRemoteFailure> {
                GitWire.extractPack(GitPktLine.line("shallow ${want.hex}") + GitPktLine.line("NAK") + pack, true, "side-band-64k")
            },
        )
        for (expectsShallow in listOf(true, false)) {
            assertEquals(
                violation("upload_pack_error"),
                assertFailsWith<GitRemoteFailure> { GitWire.extractPack(GitPktLine.line("ERR access denied"), expectsShallow, null) },
            )
        }
    }

    @Test fun anythingButAnAcknowledgementBeforeThePackIsAViolation() {
        for (bytes in listOf(ByteArray(0), GitPktLine.flush, GitPktLine.line("hello"), GitPktLine.line("ACK"))) {
            assertEquals(
                violation("acknowledgement"),
                assertFailsWith<GitRemoteFailure> { GitWire.extractPack(bytes, false, "side-band-64k") },
            )
        }
        // Without side-band nothing after the first acknowledgement is interpreted.
        val raw = GitPktLine.line("ACK ${have.hex}") + GitPktLine.line("NAK") + utf8("PACK")
        assertContentEquals(GitPktLine.line("NAK") + utf8("PACK"), GitWire.extractPack(raw, false, null))
    }

    @Test fun reportStatusIsParsedInsideOrOutsideSideBand() {
        val refName = "refs/heads/main"
        val ok = GitPktLine.line("unpack ok") + GitPktLine.line("ok $refName") + GitPktLine.flush
        assertEquals(GitPushResult.UPDATED, GitWire.parseReportStatus(ok, refName, sideBand = false))
        // Over side-band the report is pkt-lines inside band 1, possibly split across frames.
        val wrapped = band(2, utf8("remote: hello")) + band(1, ok.copyOf(7)) + band(1, ok.copyOfRange(7, ok.size)) + GitPktLine.flush
        assertEquals(GitPushResult.UPDATED, GitWire.parseReportStatus(wrapped, refName, sideBand = true))

        val rejected = GitPktLine.line("unpack ok") + GitPktLine.line("ng $refName failed to update ref") + GitPktLine.flush
        assertEquals(GitPushResult.REJECTED, GitWire.parseReportStatus(rejected, refName, sideBand = false))
        assertEquals(GitPushResult.REJECTED, GitWire.parseReportStatus(band(1, rejected) + GitPktLine.flush, refName, sideBand = true))

        assertEquals(
            violation("remote_unpack_failed"),
            assertFailsWith<GitRemoteFailure> {
                GitWire.parseReportStatus(GitPktLine.line("unpack index-pack abnormal exit") + GitPktLine.flush, refName, false)
            },
        )
        val otherRef = GitPktLine.line("unpack ok") + GitPktLine.line("ok refs/heads/other") +
            GitPktLine.line("ng refs/heads/mainline nope") + GitPktLine.flush
        for (bytes in listOf(ByteArray(0), GitPktLine.flush, GitPktLine.line("hello"), GitPktLine.line("unpack ok"), otherRef)) {
            assertEquals(
                violation("report_status"),
                assertFailsWith<GitRemoteFailure> { GitWire.parseReportStatus(bytes, refName, false) },
            )
        }
        assertEquals(
            violation("remote_error"),
            assertFailsWith<GitRemoteFailure> { GitWire.parseReportStatus(band(3, utf8("fatal")), refName, true) },
        )
    }

    @Test fun advertisementViolationsHaveClosedCodes() {
        val id = want.hex
        fun parse(bytes: ByteArray, service: GitService = GitService.UPLOAD_PACK) = GitWire.parseAdvertisement(bytes, service)
        // SSH has no "# service=" header; the first ref line carries the capabilities.
        val ssh = GitPktLine.encode(utf8("$id HEAD") + 0.toByte() + utf8("side-band-64k  agent=git/2.54 symref=HEAD:refs/heads/main\n")) +
            GitPktLine.line("$id refs/heads/main") + GitPktLine.flush
        val parsed = parse(ssh)
        assertEquals(mapOf("HEAD" to want, "refs/heads/main" to want), parsed.refs)
        assertEquals(mapOf("side-band-64k" to null, "agent" to "git/2.54", "symref" to "HEAD:refs/heads/main"), parsed.capabilities)
        assertNull(parsed.serviceUrl)
        // An empty advertisement (no packets at all) is an empty repository.
        assertTrue(parse(ByteArray(0)).refs.isEmpty())
        assertTrue(parse(GitPktLine.flush).refs.isEmpty())

        assertEquals(
            violation("advertisement_header"),
            assertFailsWith<GitRemoteFailure> { parse(GitPktLine.line("# service=git-upload-pack") + GitPktLine.line("$id HEAD")) },
        )
        for (line in listOf("nonsense", "$id", "${id.uppercase()} HEAD", "${id.dropLast(1)} HEAD")) {
            assertEquals(
                violation("advertisement_ref"),
                assertFailsWith<GitRemoteFailure>(line) { parse(GitPktLine.line(line) + GitPktLine.flush) },
            )
        }
        assertEquals(
            violation("advertisement_end"),
            assertFailsWith<GitRemoteFailure> { parse(GitPktLine.line("$id HEAD") + utf8("0001")) },
        )
        // A bare `object-format` with no value is refused like any value but sha1.
        assertEquals(
            GitRemoteFailure.UnsupportedServer("object_format"),
            assertFailsWith<GitRemoteFailure> {
                parse(GitPktLine.encode(utf8("$id HEAD") + 0.toByte() + utf8("object-format\n")) + GitPktLine.flush)
            },
        )
        assertFailsWith<GitFormatException> { parse(utf8("00")) }
    }

    @Test fun pktLineReaderRejectsWhatGitWouldNotSend() {
        // Upper-case length digits are accepted; 0003 and a length past the data are not.
        assertEquals(GitPktLine.Packet.Data(ByteArray(6)), GitPktLine.Reader(utf8("000A") + ByteArray(6)).next())
        assertEquals(GitPktLine.Packet.ResponseEnd, GitPktLine.Reader(utf8("0002")).next())
        assertEquals(GitPktLine.Packet.Data(ByteArray(0)), GitPktLine.Reader(utf8("0004")).next())
        for (bad in listOf(utf8("0003"), utf8("000a") + ByteArray(5), utf8("fff5") + ByteArray(65_521), utf8("00"))) {
            assertFailsWith<GitFormatException> { GitPktLine.Reader(bad).next() }
        }
        val largest = GitPktLine.encode(ByteArray(GitPktLine.MAXIMUM_PAYLOAD))
        assertEquals("fff0", largest.copyOf(4).toString(Charsets.US_ASCII))
        assertEquals(GitPktLine.MAXIMUM_PAYLOAD, (GitPktLine.Reader(largest).next() as GitPktLine.Packet.Data).payload.size)
        assertEquals("abc", GitPktLine.text(utf8("abc\n")))
        assertEquals("abc\n", GitPktLine.text(utf8("abc\n\n")))
        assertEquals("abc", GitPktLine.text(utf8("abc")))
        val reader = GitPktLine.Reader(GitPktLine.line("a") + utf8("rest"))
        reader.next()
        assertContentEquals(utf8("rest"), reader.remainder())
        assertFalse(reader.isAtEnd)
    }
}
