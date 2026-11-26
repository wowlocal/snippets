package com.khm.snippets.core.library

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.state.FaultInjectingIo
import com.khm.snippets.core.state.Halt
import com.khm.snippets.core.state.HaltDetail
import com.khm.snippets.core.state.HaltReason
import com.khm.snippets.core.state.SimulatedCrash
import com.khm.snippets.core.state.StateSandbox
import com.khm.snippets.core.state.SyncState
import com.khm.snippets.core.state.SyncStateFile
import com.khm.snippets.core.state.TEST_DEVICE
import com.khm.snippets.core.state.fileIdentity
import com.khm.snippets.core.state.sandbox
import com.khm.snippets.core.state.seedState
import com.khm.snippets.core.state.testId
import com.khm.snippets.core.state.testSnippet
import com.khm.snippets.core.state.utf8
import com.khm.snippets.core.vault.VaultDocument
import com.khm.snippets.core.vault.VaultFile
import com.khm.snippets.core.vault.VaultKdfParameters
import com.khm.snippets.core.vault.VaultRecord
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The two-file critical section (`LibraryTransactionTests.swift`), with failures and
 * crashes injected at each write instead of read-only directories, plus a crash at every
 * step of every plan.
 *
 * The guarantee under test: **an interrupted move leaves the record in both files, never
 * in neither**, and the marker resolves that duplicate the way the user asked.
 */
class LibraryTransactionTest {

    private val promotingMarker = { id: UUID -> LibraryTransaction.CrashMarker.Promoting(id) }

    private fun vaultDocument(vararg records: VaultRecord) = VaultDocument(
        kid = "k-test",
        vaultSalt = "AAAAAAAAAAAAAAAAAAAAAA",
        kdf = VaultKdfParameters(PassphraseKdf.ALGORITHM, PassphraseKdf.ITERATIONS, "AAAAAAAAAAAAAAAAAAAAAA"),
        records = records.toList(),
    )

    private fun record(id: UUID, name: String) = VaultRecord(
        id = id, name = name, keyword = name, createdAt = 1.0, updatedAt = 1.0,
        hlc = Hlc.of(1, 0, "aaaaaaa1"), contentHash = "00", sealed = "v1.AAAA.AAAA",
    )

    private fun snippet(name: String, id: UUID) = Snippet(id, name, name, "body-$name", createdAt = 1.0, updatedAt = 1.0)

    private class Fixture(val sandbox: StateSandbox, val io: FaultInjectingIo = FaultInjectingIo()) {
        val transaction = LibraryTransaction(sandbox.locations, io, io)
        val vault = VaultFile(sandbox.locations)
        val stateFile = SyncStateFile(sandbox.locations)

        fun putLibrary(snippets: List<Snippet>) = Files.write(sandbox.library.toPath(), SnippetLibraryCodec.encode(snippets))
        fun putVault(document: VaultDocument) = vault.write(document)
        fun libraryIds(): List<UUID> = SnippetLibraryCodec.decode(Files.readAllBytes(sandbox.library.toPath())).map { it.id }
        fun vaultIds(): List<UUID>? = vault.load().valueOrNull?.records?.map { it.id }
        fun marker() = transaction.pendingMarker()
        fun seedState() = seedState(sandbox, SyncState(TEST_DEVICE))
    }

    private fun fixture(label: String, block: (Fixture) -> Unit) = sandbox(label) { block(Fixture(it)) }

    // The move itself

    @Test
    fun aPromotionWritesBothFilesAndLeavesNoMarker() = fixture("promote") { f ->
        val id = testId(1)
        f.putLibrary(listOf(snippet("a", id)))
        f.seedState()
        val outcome = f.transaction.perform(2_000) { contents ->
            contents.change(
                snippets = contents.snippets.filter { it.id != id },
                vault = vaultDocument(record(id, "a")),
                marker = promotingMarker(id),
            )
        }
        assertTrue(outcome.wroteLibrary && outcome.wroteVault)
        assertEquals(emptyList(), f.libraryIds())
        assertEquals(listOf(id), f.vaultIds())
        assertSame(LibraryTransaction.CrashMarker.None, f.marker(), "a completed move must not leave a marker for reconcile to act on")
        assertEquals(
            listOf("write:snippets.json", "write:state.json", "write:vault.json", "write:snippets.json", "write:state.json"),
            f.io.log,
            "the duplicate stage, the marker, the vault, the final library, the cleared marker",
        )
    }

    @Test
    fun whenPromotionDestinationWriteFailsOriginalStateRemainsWithoutMarker() = fixture("promote-fail-first") { f ->
        val id = testId(1)
        f.putLibrary(listOf(snippet("a", id)))
        f.seedState()
        f.io.fail = { _, file -> file.name == "snippets.json" }
        val failure = assertFailsWith<LibraryTransaction.Failure.WriteFailed> {
            f.transaction.perform(2_000) { contents ->
                contents.change(snippets = emptyList(), vault = vaultDocument(record(id, "a")), marker = promotingMarker(id))
            }
        }
        assertEquals(LibraryTransaction.Failure.WriteFailed.Step.WRITE_LIBRARY, failure.step)
        assertEquals(listOf(id), f.libraryIds(), "the original plaintext source remains the sole durable owner")
        assertTrue(!f.vault.file.exists(), "the vault destination never became visible")
        assertSame(LibraryTransaction.CrashMarker.None, f.marker(), "reconcile is not told that a move started")
    }

    @Test
    fun whenTheDemoteDestinationWriteFailsTheVaultSourceAndNoMarkerRemain() = fixture("demote-fail-first") { f ->
        val id = testId(1)
        f.putVault(vaultDocument(record(id, "a")))
        f.putLibrary(emptyList())
        f.seedState()
        f.io.fail = { _, file -> file.name == "snippets.json" }
        assertFailsWith<LibraryTransaction.Failure.WriteFailed> {
            f.transaction.perform(2_000) { contents ->
                val vault = contents.vault!!
                contents.change(
                    snippets = contents.snippets + snippet("a", id),
                    vault = vault.copy(records = vault.records.filter { it.id != id }),
                    marker = LibraryTransaction.CrashMarker.Demoting(id),
                )
            }
        }
        assertEquals(emptyList(), f.libraryIds(), "a refused destination must remain unchanged")
        assertEquals(listOf(id), f.vaultIds(), "the source must not be removed until its destination exists")
        assertSame(LibraryTransaction.CrashMarker.None, f.marker(), "a marker is published only after the destination write lands")
    }

    @Test
    fun whenTheDemoteVaultWriteFailsBothCopiesAndTheMarkerRemain() = fixture("demote-fail-vault") { f ->
        val id = testId(1)
        f.putLibrary(emptyList())
        f.putVault(vaultDocument(record(id, "a")))
        f.seedState()
        f.io.fail = { _, file -> file.name == "vault.json" }
        val failure = assertFailsWith<LibraryTransaction.Failure.WriteFailed> {
            f.transaction.perform(2_000) { contents ->
                contents.change(
                    snippets = contents.snippets + snippet("a", id),
                    vault = contents.vault!!.copy(records = emptyList()),
                    marker = LibraryTransaction.CrashMarker.Demoting(id),
                )
            }
        }
        assertEquals(LibraryTransaction.Failure.WriteFailed.Step.WRITE_VAULT, failure.step)
        assertEquals(listOf(id), f.libraryIds(), "the plaintext destination must land before vault removal is attempted")
        assertEquals(listOf(id), f.vaultIds(), "a failed source removal leaves the old ciphertext copy")
        assertEquals(LibraryTransaction.CrashMarker.Demoting(id), f.marker(), "reconcile must be told to prefer the new plaintext copy")
    }

    @Test
    fun aMixedDirectionBatchStagesDuplicatesBeforeChangingTheVault() = fixture("mixed") { f ->
        val promoting = testId(1)
        val demoting = testId(2)
        f.putLibrary(listOf(snippet("promoting", promoting)))
        f.putVault(vaultDocument(record(demoting, "demoting")))
        f.seedState()
        f.io.fail = { _, file -> file.name == "vault.json" }
        assertFailsWith<LibraryTransaction.Failure.WriteFailed> {
            f.transaction.perform(2_000) { contents ->
                contents.change(
                    snippets = listOf(snippet("demoting", demoting)),
                    vault = contents.vault!!.copy(records = listOf(record(promoting, "promoting"))),
                )
            }
        }
        assertEquals(setOf(promoting, demoting), f.libraryIds().toSet(), "the intermediate library retains one source and installs the other destination")
        assertEquals(listOf(demoting), f.vaultIds())
    }

    @Test
    fun aTransactionThatChangesNothingWritesNothing() = fixture("no-op") { f ->
        val id = testId(1)
        f.putLibrary(listOf(snippet("a", id)))
        f.putVault(vaultDocument())
        f.seedState()
        val before = fileIdentity(f.sandbox.library)
        val outcome = f.transaction.perform(2_000) { contents ->
            // Intent without a data change is not an in-flight move.
            contents.change(marker = LibraryTransaction.CrashMarker.Demoting(id))
        }
        assertTrue(!outcome.wroteLibrary && !outcome.wroteVault)
        assertSame(LibraryTransaction.CrashMarker.None, f.marker())
        assertEquals(before, fileIdentity(f.sandbox.library))
        assertEquals(emptyList(), f.io.log)
        assertEquals(1, outcome.attempts)
    }

    // Compare-and-swap

    @Test
    fun aConcurrentLibraryWriteForcesARetryAndIsFoldedIn() = fixture("cas-library") { f ->
        val mine = snippet("mine", testId(1))
        val theirs = snippet("theirs", testId(2))
        f.putLibrary(emptyList())
        var injected = false
        val outcome = f.transaction.perform(2_000) { contents ->
            if (!injected) {
                injected = true
                f.putLibrary(listOf(theirs))
            }
            contents.change(snippets = contents.snippets + mine)
        }
        assertTrue(outcome.attempts > 1)
        assertEquals(setOf(mine.id, theirs.id), f.libraryIds().toSet(), "the concurrent record must survive")
    }

    @Test
    fun aConcurrentVaultWriteForcesARetryAndIsFoldedIn() = fixture("cas-vault") { f ->
        f.putLibrary(emptyList())
        f.putVault(vaultDocument())
        var injected = false
        val outcome = f.transaction.perform(2_000) { contents ->
            if (!injected) {
                injected = true
                f.putVault(vaultDocument(record(testId(2), "theirs")))
            }
            val vault = contents.vault ?: vaultDocument()
            contents.change(vault = vault.copy(records = vault.records + record(testId(1), "mine")))
        }
        assertTrue(outcome.attempts > 1)
        assertEquals(setOf(testId(1), testId(2)), f.vaultIds()!!.toSet(), "the concurrent secure record must survive")
    }

    @Test
    fun filesThatChangeUnderEveryAttemptEndInBusyWithNothingWritten() = fixture("cas-busy") { f ->
        f.putLibrary(emptyList())
        var round = 0
        assertFailsWith<LibraryTransaction.Failure.Busy> {
            f.transaction.perform(2_000) { contents ->
                round += 1
                f.putLibrary(listOf(snippet("other$round", testId(100 + round))))
                contents.change(snippets = contents.snippets + snippet("mine", testId(1)))
            }
        }
        assertEquals(LibraryTransaction.MAXIMUM_ATTEMPTS, round)
        assertEquals(emptyList(), f.io.log)
    }

    // Refusals

    @Test
    fun anUnreadableVaultAbortsWithoutTouchingTheLibrary() = fixture("vault-unreadable") { f ->
        f.putLibrary(listOf(snippet("a", testId(1))))
        Files.write(f.vault.file.toPath(), utf8("not json"))
        var ran = false
        val failure = assertFailsWith<LibraryTransaction.Failure.VaultUnreadable> {
            f.transaction.perform(2_000) { ran = true; it.change(snippets = it.snippets + snippet("b", testId(2))) }
        }
        assertEquals(LibraryTransaction.Failure.VaultUnreadable.Reason.CORRUPT, failure.reason)
        assertTrue(!ran)
        assertEquals(listOf(testId(1)), f.libraryIds())
        assertEquals("not json", String(Files.readAllBytes(f.vault.file.toPath())))
    }

    @Test
    fun aVaultFromANewerBuildIsNeverWrittenOver() = fixture("vault-too-new") { f ->
        f.putLibrary(emptyList())
        Files.write(f.vault.file.toPath(), utf8("{\"schemaVersion\":99}"))
        val failure = assertFailsWith<LibraryTransaction.Failure.VaultUnreadable> { f.transaction.perform(2_000) { it.keep(Unit) } }
        assertEquals(LibraryTransaction.Failure.VaultUnreadable.Reason.TOO_NEW, failure.reason)
        assertEquals(99L, failure.version)
    }

    @Test
    fun anUndecodableLibraryAbortsBeforeTheBody() = fixture("library-unreadable") { f ->
        Files.write(f.sandbox.library.toPath(), utf8("{broken"))
        val failure = assertFailsWith<LibraryTransaction.Failure.LibraryUnreadable> { f.transaction.perform(2_000) { it.keep(Unit) } }
        assertEquals(LibraryWriter.Failure.Unreadable.Reason.UNDECODABLE, failure.reason)
        assertEquals("{broken", String(Files.readAllBytes(f.sandbox.library.toPath())))
    }

    @Test
    fun aVanishedLibraryIsReportedAsMissingToTheBody() = fixture("vanished") { f ->
        var sawExisted = true
        f.transaction.perform(2_000) { contents ->
            sawExisted = contents.libraryExisted
            contents.change(snippets = contents.snippets + snippet("recreated", testId(1)))
        }
        assertTrue(!sawExisted)
        assertEquals(listOf(testId(1)), f.libraryIds())
    }

    @Test
    fun aBodyThatThrowsWritesNothing() = fixture("body-throws") { f ->
        f.putLibrary(emptyList())
        assertFailsWith<IllegalStateException> { f.transaction.perform<Unit>(2_000) { error("refused") } }
        assertEquals(emptyList(), f.io.log)
        assertTrue(!f.sandbox.locations.guard.isHeld)
    }

    @Test
    fun aBusyGuardRunsNothing() = fixture("busy") { f ->
        val held = f.sandbox.locations.guard.acquire(1_000)!!
        try {
            var ran = false
            assertFailsWith<LibraryTransaction.Failure.Busy> { f.transaction.perform(20) { ran = true; it.keep(Unit) } }
            assertTrue(!ran)
        } finally {
            held.close()
        }
    }

    @Test
    fun theVaultFileIsRemovedOnlyWhenItHoldsNothing() = fixture("vault-removal") { f ->
        f.putLibrary(emptyList())
        f.putVault(vaultDocument(record(testId(1), "a")))
        val refused = assertFailsWith<LibraryTransaction.Failure.WriteFailed> {
            f.transaction.perform(2_000) { it.change(vault = null) }
        }
        assertEquals(LibraryTransaction.Failure.WriteFailed.Step.VAULT_REMOVAL_REFUSED, refused.step)
        assertEquals(listOf(testId(1)), f.vaultIds(), "deleting secrets by omission is refused before any write")
        assertEquals(emptyList(), f.io.log)

        f.putVault(vaultDocument())
        val removed = f.transaction.perform(2_000) { it.change(vault = null) }
        assertTrue(removed.wroteVault)
        assertTrue(!f.vault.file.exists())
        assertEquals(listOf("remove:vault.json"), f.io.log)
    }

    // Marker semantics

    @Test
    fun theMarkerDistinguishesAnInterruptedPromoteFromAnInterruptedDemote() = fixture("marker") { f ->
        f.seedState()
        f.putLibrary(emptyList())
        val id = testId(1)
        f.transaction.perform(2_000) { it.change(snippets = it.snippets + snippet("x", id), marker = LibraryTransaction.CrashMarker.Demoting(id)) }
        assertSame(LibraryTransaction.CrashMarker.None, f.marker())

        seedState(f.sandbox, SyncState(TEST_DEVICE, demoting = id))
        assertEquals(LibraryTransaction.CrashMarker.Demoting(id), f.marker())
        seedState(f.sandbox, SyncState(TEST_DEVICE, promoting = id))
        assertEquals(LibraryTransaction.CrashMarker.Promoting(id), f.marker())
    }

    @Test
    fun withoutAStateFileTheMoveStillCompletesAndNoStateIsCreated() = fixture("marker-no-state") { f ->
        val id = testId(1)
        f.putLibrary(listOf(snippet("a", id)))
        f.transaction.perform(2_000) {
            it.change(snippets = emptyList(), vault = vaultDocument(record(id, "a")), marker = promotingMarker(id))
        }
        assertEquals(listOf(id), f.vaultIds())
        assertTrue(!f.sandbox.stateFile.exists(), "the marker is best effort and never mints an identity")
    }

    @Test
    fun theMarkerKeepsTheHaltAndTheRestOfTheState() = fixture("marker-halt") { f ->
        val halt = Halt(HaltReason.REMOTE_DATA_RESET, HaltDetail.of("r"), 2.0)
        seedState(f.sandbox, SyncState(TEST_DEVICE, generation = 9, halt = halt))
        val id = testId(1)
        f.putLibrary(listOf(snippet("a", id)))
        f.transaction.perform(2_000) {
            it.change(snippets = emptyList(), vault = vaultDocument(record(id, "a")), marker = promotingMarker(id))
        }
        assertEquals(SyncState(TEST_DEVICE, generation = 9, halt = halt), f.stateFile.load().loadedState)
    }

    // A crash at every step of every plan

    private class Scenario(
        val label: String,
        val library: List<Snippet>,
        val vault: VaultDocument?,
        val body: (LibraryTransaction.Contents) -> LibraryTransaction.Change<Unit>,
    )

    /** `SecureSnippetStore.reconcileAfterCrash`: a duplicate goes to the vault, unless its id is the one being demoted. */
    private fun reconciled(libraryIds: Set<UUID>, vaultIds: Set<UUID>, marker: LibraryTransaction.CrashMarker): Pair<Set<UUID>, Set<UUID>> {
        val library = HashSet(libraryIds)
        val vault = HashSet(vaultIds)
        for (id in libraryIds intersect vaultIds) {
            if (marker == LibraryTransaction.CrashMarker.Demoting(id)) vault.remove(id) else library.remove(id)
        }
        return library to vault
    }

    @Test
    fun aCrashAtEveryStepLeavesTheOriginalOrADuplicateThatReconcilesExactlyAsSwiftDoes() {
        val a = testId(1)
        val b = testId(2)
        val c = testId(3)
        val scenarios = listOf(
            Scenario("promote", listOf(snippet("a", a), snippet("c", c)), vaultDocument()) {
                it.change(snippets = it.snippets.filter { s -> s.id != a }, vault = it.vault!!.copy(records = listOf(record(a, "a"))), marker = promotingMarker(a))
            },
            Scenario("promote into a new vault", listOf(snippet("a", a)), null) {
                it.change(snippets = emptyList(), vault = vaultDocument(record(a, "a")), marker = promotingMarker(a))
            },
            Scenario("promote with a generated plaintext copy", listOf(snippet("a", a)), vaultDocument()) {
                it.change(snippets = listOf(snippet("copy", c)), vault = vaultDocument(record(a, "a")), marker = promotingMarker(a))
            },
            Scenario("demote", listOf(snippet("c", c)), vaultDocument(record(b, "b"))) {
                it.change(snippets = it.snippets + snippet("b", b), vault = it.vault!!.copy(records = emptyList()), marker = LibraryTransaction.CrashMarker.Demoting(b))
            },
            Scenario("demote without a marker", emptyList(), vaultDocument(record(b, "b"))) {
                it.change(snippets = listOf(snippet("b", b)), vault = it.vault!!.copy(records = emptyList()))
            },
            Scenario("mixed", listOf(snippet("a", a)), vaultDocument(record(b, "b"))) {
                it.change(snippets = listOf(snippet("b", b)), vault = it.vault!!.copy(records = listOf(record(a, "a"))))
            },
            Scenario("library only", listOf(snippet("a", a)), vaultDocument(record(b, "b"))) {
                it.change(snippets = it.snippets + snippet("c", c))
            },
            Scenario("vault only", listOf(snippet("a", a)), vaultDocument(record(b, "b"))) {
                it.change(vault = it.vault!!.copy(records = it.vault!!.records + record(c, "c")))
            },
        )
        for (scenario in scenarios) sandbox("crash-matrix") { s ->
            fun prepare(): Fixture {
                val f = Fixture(s)
                s.library.delete()
                f.vault.file.delete()
                f.putLibrary(scenario.library)
                scenario.vault?.let(f::putVault)
                f.seedState()
                return f
            }
            val clean = prepare()
            clean.transaction.perform(2_000, scenario.body)
            val steps = clean.io.mutations
            assertTrue(steps > 0, "${scenario.label} wrote nothing")
            val after = clean.libraryIds().toSet() to (clean.vaultIds()?.toSet() ?: emptySet())
            val before = scenario.library.map { it.id }.toSet() to (scenario.vault?.records?.map { it.id }?.toSet() ?: emptySet())
            val everyone = before.first + before.second + after.first + after.second

            for (step in 1..steps) for (crashAfter in listOf(false, true)) {
                val f = prepare()
                if (crashAfter) f.io.crashAfter = step else f.io.crashBefore = step
                val label = "${scenario.label}: crash ${if (crashAfter) "after" else "before"} step $step of $steps"
                assertFailsWith<SimulatedCrash>(label) { f.transaction.perform(2_000, scenario.body) }
                assertTrue(!s.locations.guard.isHeld, label)

                val libraryIds = f.libraryIds().toSet()
                val vaultIds = f.vaultIds()?.toSet() ?: emptySet()
                // Nothing that existed before is in neither file.
                for (id in before.first + before.second) {
                    assertTrue(id in libraryIds || id in vaultIds, "$label lost a record")
                }

                val vaultLanded = vaultIds != before.second
                val marker = f.marker()
                val (library, vault) = reconciled(libraryIds, vaultIds, marker)
                fun place(id: UUID, ids: Pair<Set<UUID>, Set<UUID>>) = (if (id in ids.first) "L" else "") + (if (id in ids.second) "V" else "")
                for (id in everyone) {
                    val now = place(id, library to vault)
                    val was = place(id, before)
                    val will = place(id, after)
                    assertTrue(now == was || now == will, "$label: $id is at '$now', neither '$was' nor '$will'")
                    if (was.isNotEmpty() && will.isNotEmpty() && was != will) {
                        // A moved record: the vault copy wins once it exists, a marked demotion's plaintext copy once it exists.
                        val completed = vaultLanded || (marker == LibraryTransaction.CrashMarker.Demoting(id) && id in libraryIds)
                        assertEquals(if (completed) will else was, now, "$label: $id")
                    }
                }
            }
        }
    }

    // Concurrency

    @Test
    fun concurrentTransactionsAndLibraryWritesThroughTheGuardLoseNothing() = sandbox("concurrent") { s ->
        Files.write(s.library.toPath(), SnippetLibraryCodec.encode(emptyList()))
        VaultFile(s.locations).write(vaultDocument())
        seedState(s, SyncState(TEST_DEVICE))
        val perThread = 12
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(4)
        fun <T> retrying(block: () -> T): T {
            while (true) {
                try {
                    return block()
                } catch (_: LibraryTransaction.Failure.Busy) {
                } catch (_: LibraryWriter.Failure.Busy) {
                }
            }
        }
        try {
            val futures = listOf(
                pool.submit<Unit> {
                    start.await()
                    repeat(perThread) { index ->
                        val id = testId(1_000 + index)
                        retrying { LibraryTransaction(s.locations).perform(50) { it.change(vault = it.vault!!.copy(records = it.vault!!.records + record(id, "v$index"))) } }
                    }
                },
                pool.submit<Unit> {
                    start.await()
                    repeat(perThread) { index ->
                        val id = testId(2_000 + index)
                        retrying { LibraryTransaction(s.locations).perform(50) { it.change(snippets = it.snippets + snippet("t$index", id)) } }
                    }
                },
                pool.submit<Unit> {
                    start.await()
                    repeat(perThread) { index ->
                        val id = testId(3_000 + index)
                        retrying { LibraryWriter(s.locations).update(50, null) { it.snippets + snippet("w$index", id) } }
                    }
                },
                pool.submit<Unit> {
                    start.await()
                    repeat(perThread) { index ->
                        val id = testId(4_000 + index)
                        // A promotion of a record this thread first creates.
                        retrying { LibraryWriter(s.locations).update(50, null) { it.snippets + snippet("p$index", id) } }
                        retrying {
                            LibraryTransaction(s.locations).perform(50) {
                                it.change(
                                    snippets = it.snippets.filter { snippet -> snippet.id != id },
                                    vault = it.vault!!.copy(records = it.vault!!.records + record(id, "p$index")),
                                    marker = promotingMarker(id),
                                )
                            }
                        }
                    }
                },
            )
            start.countDown()
            futures.forEach { it.get(120, TimeUnit.SECONDS) }
        } finally {
            pool.shutdownNow()
        }
        val library = SnippetLibraryCodec.decode(Files.readAllBytes(s.library.toPath())).map { it.id }.toSet()
        val vault = VaultFile(s.locations).load().valueOrNull!!.records.map { it.id }.toSet()
        assertEquals(((0 until perThread).map { testId(2_000 + it) } + (0 until perThread).map { testId(3_000 + it) }).toSet(), library)
        assertEquals(((0 until perThread).map { testId(1_000 + it) } + (0 until perThread).map { testId(4_000 + it) }).toSet(), vault)
        assertSame(LibraryTransaction.CrashMarker.None, LibraryTransaction(s.locations).pendingMarker())
        assertNull(SyncStateFile(s.locations).load().loadedState?.halt)
        assertContentEquals(Files.readAllBytes(s.library.toPath()), SnippetLibraryCodec.encode(SnippetLibraryCodec.decode(Files.readAllBytes(s.library.toPath()))))
    }
}
