package com.khm.snippets.core.sync.base

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.state.FaultInjectingIo
import com.khm.snippets.core.state.SimulatedCrash
import com.khm.snippets.core.state.StateSandbox
import com.khm.snippets.core.state.StrictDecodeFailure
import com.khm.snippets.core.state.entriesOf
import com.khm.snippets.core.state.sandbox
import com.khm.snippets.core.state.testEnvelope
import com.khm.snippets.core.state.testId
import com.khm.snippets.core.state.testTombstone
import com.khm.snippets.core.state.utf8
import com.khm.snippets.core.sync.transport.SyncAccountIdentity
import com.khm.snippets.core.sync.transport.SyncCursor
import com.khm.snippets.core.sync.transport.SyncDatasetIdentity
import com.khm.snippets.core.sync.transport.SyncRecordVersion
import com.khm.snippets.core.wire.SyncEnvelope
import java.nio.file.Files
import java.util.Random
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** `SyncBaseFile`: load outcomes, durable writes, crash points, identity properties and size. */
class SyncBaseFileTest {

    private fun StateSandbox.baseFile(io: FaultInjectingIo? = null): SyncBaseFile {
        val provider = locations.protocolLocations("0123456789abcdef0123456789abcdef")!!
        provider.createDirectories()
        return if (io == null) SyncBaseFile(locations, provider) else SyncBaseFile(locations, provider, io)
    }

    @Test
    fun loadTellsMissingUnreadableUnsupportedAndLoadedApart() = sandbox("base-load") { s ->
        val file = s.baseFile()
        assertSame(SyncBaseLoad.Missing, file.load())

        Files.write(file.file.toPath(), utf8("{\"schemaVersion\":8,\"anything\":[]}"))
        assertEquals(SyncBaseLoad.Unsupported(8), file.load())
        assertTrue((file.load() as SyncBaseLoad.Unsupported).isNewer)

        Files.write(file.file.toPath(), utf8("{\"schemaVersion\":7}"))
        val undecodable = file.load()
        assertIs<SyncBaseLoad.Unreadable>(undecodable)
        assertEquals(
            StrictDecodeFailure.Kind.MISSING_KEY,
            (undecodable.cause as SyncBaseLoad.Unreadable.Cause.Undecodable).failure.kind,
        )
        // Left exactly as it is: no quarantine, no regeneration.
        assertEquals("{\"schemaVersion\":7}", String(Files.readAllBytes(file.file.toPath())))

        Files.delete(file.file.toPath())
        file.file.mkdirs()
        assertIs<SyncBaseLoad.Unreadable.Cause.Io>((file.load() as SyncBaseLoad.Unreadable).cause)
        file.file.delete()

        val base = SyncBase(envelopes = mapOf(testId(1) to testEnvelope(1)), journalEstablished = true)
        assertIs<SyncBaseWrite.Written>(file.write(base, 1_000))
        assertEquals(base, file.load().loadedBase)
        // Read and decode separately, as a round does across threads.
        val bytes = file.read()
        assertIs<FileRead.Bytes>(bytes)
        assertEquals(base, SyncBaseFile.decode(bytes).loadedBase)
        assertEquals(emptyList(), entriesOf(s.tmp), "a staged temporary file survived")
    }

    /** `theAgreedBaseSurvivesARestart`, at the file layer. */
    @Test
    fun theAgreedBaseSurvivesAReloadFromANewInstance() = sandbox("base-restart") { s ->
        val base = SyncBase(
            envelopes = mapOf(testId(1) to testEnvelope(1), testId(2) to testTombstone(2)),
            recordVersions = mapOf(testId(1) to SyncRecordVersion(utf8("memory-1"))),
            cursor = SyncCursor("41"),
            journalEstablished = true,
            accountIdentity = SyncAccountIdentity(utf8("acct")),
            datasetIdentity = SyncDatasetIdentity(utf8("ds")),
        )
        s.baseFile().write(base, 1_000)
        assertEquals(base, s.baseFile().load().loadedBase)
    }

    @Test
    fun aWriteThatIsNotDurableIsNotPublished() = sandbox("base-failed") { s ->
        val old = SyncBase(journalEstablished = true)
        s.baseFile().write(old, 1_000)
        val io = FaultInjectingIo().apply { fail = { _, _ -> true } }
        val result = s.baseFile(io).write(old.adoptingCursor(SyncCursor("2"), null), 1_000)
        assertIs<SyncBaseWrite.Failed>(result)
        assertEquals(old, s.baseFile().load().loadedBase)

        val notEncodable = s.baseFile().write(SyncBase(recordVersions = mapOf(testId(1) to SyncRecordVersion(ByteArray(SyncRecordVersion.MAXIMUM_DATA_BYTES + 1)))), 1_000)
        assertIs<SyncBaseWrite.NotEncodable>(notEncodable)
        assertEquals(old, s.baseFile().load().loadedBase)
    }

    @Test
    fun aWriteWaitsForTheGuardAndReportsBusy() = sandbox("base-busy") { s ->
        val held = s.locations.guard.acquire(1_000)!!
        try {
            assertSame(SyncBaseWrite.Busy, s.baseFile().write(SyncBase(), 20))
            assertIs<SyncBaseWrite.Written>(s.baseFile().writeWhileHolding(held, SyncBase()))
        } finally {
            held.close()
        }
        assertFailsWith<IllegalArgumentException> { s.baseFile().writeWhileHolding(held, SyncBase()) }
    }

    @Test
    fun aCrashAroundTheWriteLeavesTheOldOrTheNewBase() = sandbox("base-crash") { s ->
        val old = SyncBase(envelopes = mapOf(testId(1) to testEnvelope(1)), cursor = SyncCursor("1"), journalEstablished = true)
        val new = old.recordingConfirmed(testEnvelope(2), SyncRecordVersion(utf8("g"))).adoptingCursor(SyncCursor("2"), null)
        for (after in listOf(false, true)) {
            s.baseFile().write(old, 1_000)
            val io = FaultInjectingIo().apply { if (after) crashAfter = 1 else crashBefore = 1 }
            assertFailsWith<SimulatedCrash> { s.baseFile(io).write(new, 1_000) }
            assertTrue(!s.locations.guard.isHeld)
            assertEquals(if (after) new else old, s.baseFile().load().loadedBase, "crash ${if (after) "after" else "before"}")
            assertEquals(emptyList(), entriesOf(s.tmp))
        }
    }

    // Properties

    @Test
    fun opaqueTokensOfEveryAllowedSizeRoundTrip() {
        for (size in 1..SyncAccountIdentity.MAXIMUM_DATA_BYTES) {
            val data = ByteArray(size) { (it * 31 + size).toByte() }
            val base = SyncBase(accountIdentity = SyncAccountIdentity(data), datasetIdentity = SyncDatasetIdentity(data.reversedArray()))
            assertEquals(base, SyncBaseCodec.decode(SyncBaseCodec.encode(base)), "identity of $size bytes")
        }
        val versionSizes = (0..1_100) + listOf(4_095, 4_096, 65_536, 1_000_000, SyncRecordVersion.MAXIMUM_DATA_BYTES - 1, SyncRecordVersion.MAXIMUM_DATA_BYTES)
        for (size in versionSizes) {
            val data = ByteArray(size) { (it xor size).toByte() }
            val base = SyncBase(recordVersions = mapOf(testId(size) to SyncRecordVersion(data)))
            assertEquals(base, SyncBaseCodec.decode(SyncBaseCodec.encode(base)), "record version of $size bytes")
        }
        for (cursor in listOf("", "0", "a/b\\c\"d", "\u0000\u001f", "😀".repeat(1_000), "x".repeat(200_000), "é vs é")) {
            val base = SyncBase(cursor = SyncCursor(cursor))
            assertEquals(cursor, SyncBaseCodec.decode(SyncBaseCodec.encode(base)).cursor?.rawValue)
        }
    }

    @Test
    fun randomBasesRoundTripExactly() {
        val random = Random(0xBA5E_0007L)
        repeat(150) { iteration ->
            val count = if (iteration == 0) 0 else random.nextInt(40)
            val envelopes = (0 until count).associate { index ->
                val envelope = randomEnvelope(random, index)
                envelope.id to envelope
            }
            val versions = envelopes.keys.filter { random.nextBoolean() }.associateWith { SyncRecordVersion(randomBytes(random, random.nextInt(64))) } +
                (if (random.nextBoolean()) mapOf(UUID(random.nextLong(), random.nextLong()) to SyncRecordVersion(ByteArray(0))) else emptyMap())
            val fence = random.nextInt(3)
            val reviewed = fence == 2
            val base = SyncBase(
                envelopes = envelopes,
                recordVersions = versions,
                cursor = if (random.nextBoolean()) SyncCursor(randomText(random)) else null,
                journalEstablished = random.nextBoolean(),
                accountIdentity = if (random.nextBoolean()) SyncAccountIdentity(randomBytes(random, 1 + random.nextInt(1_024))) else null,
                datasetIdentity = if (random.nextBoolean()) SyncDatasetIdentity(randomBytes(random, 1 + random.nextInt(1_024))) else null,
                requiresTransportFullResync = random.nextBoolean(),
                requiresNonDestructiveLibraryMerge = fence > 0,
                nonDestructiveMergeMode = when (fence) {
                    1 -> SyncBase.NonDestructiveMergeMode.INCOMPLETE_PRIMARY
                    2 -> SyncBase.NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT
                    else -> null
                },
                preRecoveryConfirmedEnvelopes = if (reviewed && random.nextBoolean()) envelopes.filterKeys { random.nextBoolean() } else null,
                nonDestructiveReviewId = if (reviewed) UUID(random.nextLong(), random.nextLong()) else null,
            )
            val bytes = SyncBaseCodec.encode(base)
            val decoded = SyncBaseCodec.decode(bytes)
            assertEquals(base, decoded, "iteration $iteration")
            assertEquals(base.nonDestructiveReviewFingerprint(), decoded.nonDestructiveReviewFingerprint())
            assertContentEquals(bytes, SyncBaseCodec.encode(decoded))
        }
    }

    /** Encode/decode cost of a large confirmed ancestor. Prints its numbers; the bound is generous on purpose. */
    @Test
    fun aBaseOfTenThousandRecordsEncodesAndDecodesQuickly() {
        for (count in listOf(10_000, 20_000)) {
            val envelopes = (0 until count).associate { index ->
                val envelope = SyncEnvelope.plain(
                    Snippet(
                        id = UUID(0x0123_4567_89AB_4CDEL, 0x8000_0000_0000_0000UL.toLong() or index.toLong()),
                        name = "Snippet number $index", keyword = "kw$index",
                        content = "A realistic body for snippet $index, with some text.\nSecond line ✅",
                        tags = listOf("Work", "Tag ${index % 17}"), createdAt = 700_000_000.0 + index, updatedAt = 700_100_000.5 + index,
                    ),
                    Hlc.of(1_785_312_000_000 + index, index % 3, "a1b2c3d4"), "a1b2c3d4",
                )
                envelope.id to envelope
            }
            val versions = envelopes.keys.associateWith { SyncRecordVersion(utf8("git-blob-${it.leastSignificantBits}")) }
            val base = SyncBase(envelopes = envelopes, recordVersions = versions, cursor = SyncCursor("dataset:commit"), journalEstablished = true)

            SyncBaseCodec.decode(SyncBaseCodec.encode(base)) // warm up
            val coldStart = System.nanoTime()
            val bytes = SyncBaseCodec.encode(SyncBase(envelopes = envelopes, recordVersions = versions, cursor = SyncCursor("dataset:commit"), journalEstablished = true))
            val coldEncode = System.nanoTime() - coldStart
            val warmStart = System.nanoTime()
            SyncBaseCodec.encode(base)
            val warmEncode = System.nanoTime() - warmStart
            val decodeStart = System.nanoTime()
            val decoded = SyncBaseCodec.decode(bytes)
            val decode = System.nanoTime() - decodeStart
            assertEquals(count, decoded.envelopes.size)
            println(
                "SyncBase $count records, ${bytes.size / 1024} KiB: encode ${coldEncode / 1_000_000} ms " +
                    "(re-encode of a written base ${warmEncode / 1_000_000} ms), decode ${decode / 1_000_000} ms",
            )
            assertTrue(coldEncode < 20_000_000_000L && decode < 20_000_000_000L, "pathologically slow")
        }
    }

    private fun randomEnvelope(random: Random, index: Int): SyncEnvelope {
        val id = UUID(random.nextLong(), random.nextLong())
        val hlc = Hlc.of(random.nextLong() and 0xFFFF_FFFF_FFFFL, random.nextInt(65_536), "a1b2c3d4")
        if (random.nextInt(4) == 0) return SyncEnvelope.tombstone(id, random.nextBoolean(), hlc, "a1b2c3d4")
        val extremes = doubleArrayOf(0.0, -0.0, Double.MIN_VALUE, Double.MAX_VALUE, -1e300, 1e16, 0.1, 807_004_800.0)
        val time = if (random.nextBoolean()) extremes[random.nextInt(extremes.size)] else random.nextDouble() * 1e9
        return SyncEnvelope.plain(
            Snippet(id, randomText(random), "kw$index", randomText(random), listOf(randomText(random)).filter { it.isNotBlank() }, random.nextBoolean(), random.nextBoolean(), time, time + 1),
            hlc, "a1b2c3d4",
        )
    }

    private fun randomBytes(random: Random, size: Int): ByteArray = ByteArray(size).also(random::nextBytes)

    private fun randomText(random: Random): String {
        val pool = listOf("", "plain", "slash/back\\", "quote\"", "line\nbreak", "Café", "é", "😀", "日本語", "\u0001")
        return pool[random.nextInt(pool.size)] + pool[random.nextInt(pool.size)]
    }
}
