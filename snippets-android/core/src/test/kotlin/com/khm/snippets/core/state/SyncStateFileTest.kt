package com.khm.snippets.core.state

import com.khm.snippets.core.io.LibraryGuard
import java.nio.file.Files
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.fail

/** `ClockAndStateTests.StateFile` ("Sync state file"), adapted to this app's own schema. */
class SyncStateFileTest {

    private val sentinel = SyncState("ffffffff")

    private fun sampleState(): SyncState = SyncState(
        deviceId = TEST_DEVICE,
        generation = 42,
        librarySha256 = "ab".repeat(32),
        halt = Halt(
            reason = HaltReason.MASS_DELETION,
            detail = HaltDetail.of("remote_mass_deletion", mapOf("requested" to "91", "live" to "93")),
            at = 790_692_600.0,
        ),
        promoting = UUID.fromString("1f1e1d1c-0b0a-4908-8706-050403020100"),
    )

    private fun StateSandbox.file(io: DurableFileIo = DurableFileIo.Default) = SyncStateFile(locations, io)

    private fun <T> StateSandbox.holding(block: (LibraryGuard.Held) -> T): T {
        val held = locations.guard.acquire(1_000) ?: fail("guard busy")
        try {
            return block(held)
        } finally {
            held.close()
        }
    }

    @Test
    fun syncStateRoundTripsThroughWriteAndLoad() = sandbox("roundtrip") { s ->
        val state = sampleState()
        val staging = s.tmp
        s.holding { s.file().write(it, state) }

        assertTrue(staging.isDirectory)
        assertEquals(emptyList(), entriesOf(staging), "a staged temporary file survived a successful state write")
        assertEquals(listOf("state.json"), entriesOf(s.locations.syncFolder).filter { it.startsWith("state.json") })

        val text = String(Files.readAllBytes(s.stateFile.toPath()), Charsets.UTF_8)
        // The halt time is the double itself, not an ISO-8601 date that drops the fraction.
        assertTrue(text.contains("\"at\" : 790692600"), text)
        assertTrue(text.contains("\"reason\" : \"massDeletion\""), text)
        assertTrue(text.contains("\"schemaVersion\" : 5"), text)

        val reloaded = s.file().load { sentinel }
        assertIs<SyncStateLoad.Loaded>(reloaded)
        assertEquals(state, reloaded.state)
        assertEquals(state.halt?.at, reloaded.state.halt?.at)
        assertEquals(HaltReason.MASS_DELETION, reloaded.state.halt?.reason)
        assertEquals(state.promoting, reloaded.state.promoting)
        assertNull(reloaded.state.demoting)
    }

    @Test
    fun aFileFromANewerSchemaIsUnsupportedEvenWhenTheRestOfItIsGarbage() = sandbox("too-new-garbage") { s ->
        Files.write(
            s.stateFile.toPath(),
            utf8(
                """
                {
                  "schemaVersion" : 99,
                  "deviceID" : ["not", "a", "string"],
                  "generation" : "definitely not a number",
                  "somethingThisBuildHasNeverHeardOf" : { "nested" : [1, 2, 3] }
                }
                """.trimIndent(),
            ),
        )
        assertIs<SyncStateCodec.ReadResult.Unsupported>(SyncStateCodec.read(Files.readAllBytes(s.stateFile.toPath())))

        val outcome = s.file().load { fail("load fell through to fresh, which would overwrite a newer state") }
        assertEquals(99L, outcome.unsupportedVersion)
        assertTrue((outcome as SyncStateLoad.Unsupported).isNewer)
        assertNull(outcome.loadedState)
        assertNull(outcome.freshState)
    }

    @Test
    fun aFileFromANewerSchemaIsUnsupportedEvenWhenItWouldDecodeCleanly() = sandbox("too-new-valid") { s ->
        val current = String(SyncStateCodec.encode(sampleState()), Charsets.UTF_8)
        Files.write(s.stateFile.toPath(), utf8(current.replace("\"schemaVersion\" : 5", "\"schemaVersion\" : 6")))

        val outcome = s.file().load { sentinel }
        assertEquals(SyncState.CURRENT_SCHEMA_VERSION + 1, outcome.unsupportedVersion)
        assertNull(outcome.loadedState)
        // The halt that corresponds to this outcome is the one that never auto-heals.
        assertNull(HaltReason.SCHEMA_TOO_NEW.recoveryAction)
    }

    /** Owner decision: no migrations. An older number is refused the same way, never read as empty. */
    @Test
    fun aFileFromAnOlderSchemaIsUnsupportedNotFresh() = sandbox("too-old") { s ->
        for (version in listOf(0, 1, 2, 3, 4, -1)) {
            val current = String(SyncStateCodec.encode(sampleState()), Charsets.UTF_8)
            Files.write(s.stateFile.toPath(), utf8(current.replace("\"schemaVersion\" : 5", "\"schemaVersion\" : $version")))
            val outcome = s.file().load { fail("version $version fell through to fresh") }
            assertEquals(version.toLong(), outcome.unsupportedVersion)
            assertTrue(!(outcome as SyncStateLoad.Unsupported).isNewer)
        }
    }

    /**
     * No halt reason may stop decoding: an undecodable `state.json` is started fresh,
     * and a fresh state has no halt, so a dropped case would silently clear a sticky stop.
     */
    @Test
    fun aHaltFromAnOlderBuildStillDecodes() = sandbox("legacy-halt") { s ->
        for (reason in HaltReason.entries) {
            val state = sampleState().copy(halt = Halt(reason, HaltDetail.of("legacy"), at = 0.0))
            seedState(s, state)
            val outcome = s.file().load { fail("a decodable $reason halt fell through to fresh, clearing a sticky stop") }
            assertEquals(reason, outcome.loadedState?.halt?.reason)
        }
        assertEquals(HaltReason.MANIFEST_INTEGRITY_FAILED, HaltReason.fromRawValue("manifestIntegrityFailed"))
        assertEquals(9, HaltReason.entries.size, "every Swift halt reason is a distinct case")
    }

    @Test
    fun aLegacyBackendRefusalOffersRetry() {
        assertEquals(SyncRecoveryAction.RETRY_SYNC, HaltReason.BACKEND_REFUSED.recoveryAction)
        assertEquals("backendRefused", HaltReason.BACKEND_REFUSED.rawValue)
    }

    @Test
    fun safetyHaltsKeepTheirRecoveryPoliciesDistinct() {
        assertEquals(5L, SyncState.CURRENT_SCHEMA_VERSION, "review claims and primary quarantine require a downgrade fence")
        assertEquals(SyncRecoveryAction.RESTORE_CLOUD_FROM_THIS_DEVICE, HaltReason.REMOTE_DATA_RESET.recoveryAction)
        assertEquals(SyncRecoveryAction.REPAIR_CHECKPOINT, HaltReason.CHECKPOINT_UNREADABLE.recoveryAction)
        assertEquals(SyncRecoveryAction.APPLY_REMOTE_DELETIONS, HaltReason.MASS_DELETION.recoveryAction)
        assertEquals(SyncRecoveryAction.USE_CURRENT_ACCOUNT, HaltReason.ACCOUNT_CHANGED.recoveryAction)

        for (reason in listOf(HaltReason.REMOTE_DATA_RESET, HaltReason.CHECKPOINT_UNREADABLE)) {
            val state = sampleState().copy(halt = Halt(reason, HaltDetail.of("bounded_typed_safety_detail"), at = 0.0))
            assertEquals(state, SyncStateCodec.decode(SyncStateCodec.encode(state)))
        }

        val deletion = sampleState().copy(
            halt = Halt(
                HaltReason.MASS_DELETION, HaltDetail.of("mass_deletion"), at = 0.0,
                recoveryContext = RecoveryContext.MassDeletion(117, 49, "a".repeat(64)),
            ),
        )
        assertEquals(deletion, SyncStateCodec.decode(SyncStateCodec.encode(deletion)))

        val quarantine = sampleState().copy(
            halt = Halt(
                HaltReason.LOCAL_LIBRARY_QUARANTINED, HaltDetail.of("primary_library_preserved"), at = 0.0,
                recoveryContext = RecoveryContext.LocalLibraryQuarantine,
            ),
        )
        assertEquals(quarantine, SyncStateCodec.decode(SyncStateCodec.encode(quarantine)))
        val text = String(SyncStateCodec.encode(quarantine), Charsets.UTF_8)
        assertTrue(text.contains("\"localLibraryQuarantine\" : {"), text)
    }

    @Test
    fun aFileAtTheCurrentSchemaVersionLoadsNormally() = sandbox("current") { s ->
        val state = sampleState()
        seedState(s, state)
        assertEquals(state, s.file().load { fail("a current-version file must not land in fresh") }.loadedState)
    }

    @Test
    fun aMissingFileYieldsAFreshStateWithADistinctRandomDeviceIdentityEachTime() = sandbox("missing") { s ->
        val first = s.file().load()
        val second = s.file().load()
        assertIs<SyncStateLoad.Fresh>(first)
        assertIs<SyncStateLoad.Fresh>(second)
        assertSame(SyncStateLoad.Fresh.Cause.Missing, first.cause)
        assertNotEquals(first.state.deviceId, second.state.deviceId)
        for (state in listOf(first.state, second.state)) {
            assertEquals(8, state.deviceId.length)
            assertTrue(state.deviceId.all { it in '0'..'9' || it in 'a'..'f' })
            assertEquals(0L, state.generation)
            assertNull(state.librarySha256)
            assertNull(state.halt)
            assertNull(state.promoting)
            assertNull(state.demoting)
        }
        assertTrue(!s.stateFile.exists(), "loading never writes")
    }

    /** It holds no user data: the cost of starting over is one device identity and one full reconcile. */
    @Test
    fun anUnreadableFileYieldsAFreshStateBecauseItHoldsNoUserData() = sandbox("corrupt") { s ->
        val cases = listOf(
            "empty" to ByteArray(0),
            "truncated mid-write" to utf8("{\"schemaVersion\" : 5, \"deviceID\" : \"a1b2"),
            "binary" to byteArrayOf(0xFF.toByte(), 0x00, 0x1B, 0x7F, 0xC3.toByte(), 0x28),
            "json, but not a state" to utf8("{\"hello\":\"world\"}"),
            "a bare array" to utf8("[]"),
            "a bare number" to utf8("17"),
            "current version with a malformed device id" to utf8(
                """{ "schemaVersion" : 5, "deviceID" : "A1B2C3D4", "generation" : 0 }""",
            ),
        )
        for ((label, bytes) in cases) {
            Files.write(s.stateFile.toPath(), bytes)
            val outcome = s.file().load { sentinel }
            assertSame(sentinel, outcome.freshState, "$label should start fresh")
            assertIs<SyncStateLoad.Fresh.Cause.Undecodable>((outcome as SyncStateLoad.Fresh).cause, label)
            assertNull(outcome.loadedState, label)
            assertNull(outcome.unsupportedVersion, label)
        }
        // A directory where the file should be cannot be read at all.
        s.stateFile.delete()
        s.stateFile.mkdirs()
        val unreadable = s.file().load { sentinel }
        assertSame(SyncStateLoad.Fresh.Cause.Unreadable, (unreadable as SyncStateLoad.Fresh).cause)
    }

    // Writers

    @Test
    fun loadOrCreatePersistsAFreshIdentityOnceAndThenKeepsIt() = sandbox("adopt") { s ->
        val created = s.file().loadOrCreate(1_000) { SyncState(TEST_DEVICE) }
        assertIs<SyncStateLoad.Fresh>(created)
        val adopted = s.file().loadOrCreate(1_000) { fail("an existing identity was replaced") }
        assertEquals(TEST_DEVICE, adopted.loadedState?.deviceId)
    }

    @Test
    fun loadOrCreateNeverWritesOverAnotherSchema() = sandbox("adopt-unsupported") { s ->
        Files.write(s.stateFile.toPath(), utf8("""{"schemaVersion":9,"anything":true}"""))
        val before = Files.readAllBytes(s.stateFile.toPath())
        assertEquals(9L, s.file().loadOrCreate(1_000).unsupportedVersion)
        kotlin.test.assertContentEquals(before, Files.readAllBytes(s.stateFile.toPath()))
    }

    @Test
    fun updateWithoutAFreshStateNeverCreatesOne() = sandbox("update-existing-only") { s ->
        var ran = false
        val result = s.file().update(1_000, makeFresh = null) { ran = true; it.copy(generation = 1) }
        assertIs<SyncStateUpdate.NotLoaded>(result)
        assertTrue(!ran)
        assertTrue(!s.stateFile.exists())
    }

    @Test
    fun updateWritesOnlyAChangeAndPublishesWhatIsDurable() = sandbox("update") { s ->
        seedState(s, SyncState(TEST_DEVICE))
        val io = FaultInjectingIo()
        val unchanged = s.file(io).update(1_000, makeFresh = null) { it }
        assertIs<SyncStateUpdate.Unchanged>(unchanged)
        assertEquals(0, io.mutations)

        val written = s.file(io).update(1_000, makeFresh = null) { it.copy(generation = 3) }
        assertEquals(3L, (written as SyncStateUpdate.Written).state.generation)
        assertEquals(3L, s.file().load().loadedState?.generation)

        io.fail = { _, _ -> true }
        val failed = s.file(io).update(1_000, makeFresh = null) { it.copy(generation = 4) }
        assertIs<SyncStateUpdate.WriteFailed>(failed)
        assertNull(failed.stateOrNull, "a state that is not durable is never returned")
        assertEquals(3L, s.file().load().loadedState?.generation)
    }

    @Test
    fun updateIsBusyWhileTheGuardIsHeldAndRunsNothing() = sandbox("busy") { s ->
        seedState(s, SyncState(TEST_DEVICE))
        s.holding {
            var ran = false
            assertSame(SyncStateUpdate.Busy, s.file().update(20, makeFresh = null) { ran = true; it })
            assertTrue(!ran)
            assertEquals(
                HaltUpdateResult.Failed(HaltUpdateResult.Failed.Reason.LOCK_BUSY),
                s.file().updateHalt(20, Halt(HaltReason.VAULT_UNREADABLE, HaltDetail.of("x"), 0.0), null) { SyncState(TEST_DEVICE) },
            )
        }
    }

    @Test
    fun theHoldingFormsRefuseACallerThatHoldsNoGuard() = sandbox("not-held") { s ->
        val other = LibraryGuard.forRoot(s.root)
        val held = other.acquire(1_000)!!
        held.close()
        assertFailsWith<IllegalArgumentException> { s.file().updateWhileHolding(held, null) { it } }
        assertFailsWith<IllegalArgumentException> { s.file().write(held, SyncState(TEST_DEVICE)) }
    }
}
