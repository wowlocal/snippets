package com.khm.snippets.core.backup

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.clock.HlcGenerator
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.vault.KeyPresence
import com.khm.snippets.core.vault.VaultDocument
import com.khm.snippets.core.vault.VaultRecord
import com.khm.snippets.core.vault.at
import com.khm.snippets.core.vault.clock
import com.khm.snippets.core.vault.document
import com.khm.snippets.core.vault.id
import com.khm.snippets.core.vault.record
import org.junit.Test
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The restore semantics, one rule per test: `mergeEncryptedBackup` and the vault
 * compatibility table of `importPreparedEncryptedBackup` in `SecureSnippetStore.swift`.
 * A restore merges; it never blindly replaces, and any refusal changes nothing.
 */
class BackupMergeTest {

    private val importDate = at(10_000.0)

    private fun plain(index: Int, name: String = "Plain $index", keyword: String = "plain$index", content: String = "body $index") =
        Snippet(id(index), name, keyword, content, emptyList(), true, false, at(index.toDouble()), at(index + 1.0))

    private fun secure(index: Int, name: String = "Secure $index", keyword: String = "secure$index", sealed: String = "v1.sealed$index") =
        record(index, name = name, keyword = keyword, sealed = sealed)

    private fun vault(vararg records: VaultRecord, x: Map<String, JsonValue> = emptyMap()) =
        document(x = x, records = records.toList())

    private fun plan(
        currentSnippets: List<Snippet> = emptyList(),
        currentVault: VaultDocument? = null,
        incomingSnippets: List<Snippet> = emptyList(),
        incomingVault: VaultDocument? = null,
        clocks: Map<UUID, Hlc> = emptyMap(),
        authoritative: Boolean = false,
    ) = BackupMerge.plan(currentSnippets, currentVault, incomingSnippets, incomingVault, importDate, clocks, authoritative)

    private fun conflicts(block: () -> Unit): List<BackupMerge.Conflict> =
        assertFailsWith<BackupImportFailure.Conflicts> { block() }.conflicts

    // What happens to the key

    @Test fun theKeyStepFollowsTheVaultCompatibilityTable() {
        val incoming = vault(secure(1))
        val same = vault(secure(2))
        val other = same.copy(kid = "k-another-vault")

        // No vault in the backup: only ordinary snippets merge, whatever is here.
        assertEquals(BackupMerge.KeyStep.NONE, BackupMerge.keyStep(same, null, false, KeyPresence.PRESENT))
        assertEquals(BackupMerge.KeyStep.NONE, BackupMerge.keyStep(null, null, false, KeyPresence.ABSENT))

        // No local vault: the backup's key is stored first, then its vault is installed.
        assertEquals(BackupMerge.KeyStep.STORE_KEY, BackupMerge.keyStep(null, incoming, true, KeyPresence.ABSENT))
        // The same vault with its key missing: the backup restores the key, then merges.
        assertEquals(BackupMerge.KeyStep.STORE_KEY, BackupMerge.keyStep(same, incoming, true, KeyPresence.ABSENT))
        // The same vault with its key: fresh authentication, and the keys must be equal.
        assertEquals(BackupMerge.KeyStep.VERIFY_STORED_KEY, BackupMerge.keyStep(same, incoming, true, KeyPresence.PRESENT))
        // An orphaned key for the backup's vault with no document: still verified, never silently replaced.
        assertEquals(BackupMerge.KeyStep.VERIFY_STORED_KEY, BackupMerge.keyStep(null, incoming, true, KeyPresence.PRESENT))
        // A key store that cannot answer is not "no key": nothing is overwritten on its say-so.
        assertEquals(BackupMerge.KeyStep.VERIFY_STORED_KEY, BackupMerge.keyStep(same, incoming, true, KeyPresence.UNKNOWN))

        // Another vault: refused, whatever the key store holds. No re-encryption across vaults.
        for (presence in KeyPresence.values()) {
            assertFailsWith<BackupImportFailure.IncompatibleVault> { BackupMerge.keyStep(other, incoming, true, presence) }
        }
        // A vault without its key is not a backup this reader produced.
        assertFailsWith<EncryptedBackup.Failure.DamagedBackup> { BackupMerge.keyStep(null, incoming, false, KeyPresence.ABSENT) }
    }

    // Ordinary snippets

    @Test fun anIncomingSnippetWithAKnownIdReplacesItInPlace() {
        val result = plan(
            currentSnippets = listOf(plain(1), plain(2), plain(3)),
            incomingSnippets = listOf(plain(2, name = "From backup", content = "restored")),
        )
        assertEquals(listOf(id(1), id(2), id(3)), result.snippets.map { it.id })
        assertEquals(listOf("From backup", "restored"), result.snippets[1].let { listOf(it.name, it.content) })
        assertEquals(1, result.ordinaryCount)
        assertEquals(0, result.secureCount)
        assertNull(result.vault)
    }

    @Test fun anIncomingSnippetWithAKnownKeywordReplacesKeepingTheLocalIdAndCreationTime() {
        val local = plain(1, keyword = "Café")
        val incoming = plain(9, name = "From backup", keyword = "  \\cafe ", content = "restored")

        val result = plan(currentSnippets = listOf(plain(2), local), incomingSnippets = listOf(incoming))

        assertEquals(listOf(id(2), id(1)), result.snippets.map { it.id }, "the local id stays; no second record appears")
        val merged = result.snippets[1]
        assertEquals(local.createdAt, merged.createdAt)
        assertEquals(incoming.updatedAt, merged.updatedAt)
        assertEquals(listOf("From backup", "cafe", "restored"), listOf(merged.name, merged.keyword, merged.content))
    }

    @Test fun unknownSnippetsAreInsertedAtTheFront() {
        val result = plan(currentSnippets = listOf(plain(1)), incomingSnippets = listOf(plain(2), plain(3), plain(4, keyword = "")))
        // Each goes to the front in turn, as the import does.
        assertEquals(listOf(id(4), id(3), id(2), id(1)), result.snippets.map { it.id })
        assertEquals(3, result.ordinaryCount)

        // Empty keywords never match each other.
        val both = plan(currentSnippets = listOf(plain(1, keyword = "")), incomingSnippets = listOf(plain(2, keyword = " \\ ")))
        assertEquals(listOf(id(2), id(1)), both.snippets.map { it.id })
    }

    @Test fun incomingSnippetsAreNormalizedBeforeTheyMerge() {
        val messy = Snippet(id(5), "n", "  \\\\two words ", "c", listOf("Work", "work", " prod ", ""), true, false, at(50.0), at(10.0))
        val merged = plan(incomingSnippets = listOf(messy)).snippets.single()

        assertEquals("two-words", merged.keyword)
        assertEquals(listOf("Work", "prod"), merged.tags)
        assertEquals(at(50.0), merged.updatedAt, "updatedAt is never before createdAt")
        assertEquals(at(50.0), merged.createdAt)
    }

    // Conflicts

    @Test fun anOrdinaryIdThatIsSecureHereIsAConflictAndSoIsTheReverse() {
        val one = conflicts { plan(currentVault = vault(secure(1, name = " Bank PIN ")), incomingSnippets = listOf(plain(1, name = "Mine"))) }
        assertEquals(listOf(BackupMerge.Conflict.OrdinaryIdIsSecure("Mine", "Bank PIN")), one)
        assertEquals("Mine has the same ID as secure snippet Bank PIN.", one.single().text)

        val other = conflicts {
            plan(currentSnippets = listOf(plain(1, name = "Mine")), currentVault = vault(), incomingVault = vault(secure(1, name = "")))
        }
        assertEquals(listOf(BackupMerge.Conflict.SecureIdIsOrdinary("Untitled Snippet", "Mine")), other)
        assertEquals("Untitled Snippet has the same ID as ordinary snippet Mine.", other.single().text)
    }

    @Test fun aKeywordThatBelongsToARecordOfTheOtherKindIsAConflict() {
        val one = conflicts {
            plan(currentVault = vault(secure(1, name = "Bank", keyword = "Café")), incomingSnippets = listOf(plain(2, keyword = "\\CAFE")))
        }
        assertEquals(listOf(BackupMerge.Conflict.OrdinaryKeywordIsSecure("CAFE", "Bank")), one)
        assertEquals("Keyword \\CAFE belongs to secure snippet Bank.", one.single().text)

        val other = conflicts {
            plan(
                currentSnippets = listOf(plain(2, name = "Mine", keyword = "cafe")), currentVault = vault(),
                incomingVault = vault(secure(1, keyword = " Café ")),
            )
        }
        assertEquals(listOf(BackupMerge.Conflict.SecureKeywordIsOrdinary("Café", "Mine")), other)
        assertEquals("Keyword \\Café belongs to ordinary snippet Mine.", other.single().text)
    }

    @Test fun anIdMatchWhoseKeywordBelongsToAnotherRecordOfTheSameKindIsAConflict() {
        val ordinary = conflicts {
            plan(
                currentSnippets = listOf(plain(1, name = "Target", keyword = "old"), plain(2, name = "Owner", keyword = "wanted")),
                incomingSnippets = listOf(plain(1, name = "Incoming", keyword = "wanted")),
            )
        }
        assertEquals(listOf(BackupMerge.Conflict.OrdinaryIdMatchesButKeywordIsTaken("Incoming", "Target", "wanted", "Owner")), ordinary)
        assertEquals("Incoming matches existing ID Target, but keyword \\wanted belongs to Owner.", ordinary.single().text)

        // For secure records the keyword alone decides: a new id whose keyword another secure record owns conflicts too.
        val current = vault(secure(1, name = "Target", keyword = "old"), secure(2, name = "Owner", keyword = "wanted"))
        for (incomingId in listOf(1, 7)) {
            val secure = conflicts { plan(currentVault = current, incomingVault = vault(secure(incomingId, name = "Incoming", keyword = "wanted"))) }
            assertEquals(listOf(BackupMerge.Conflict.SecureKeywordIsTaken("Incoming", "wanted", "Owner")), secure)
            assertEquals("Secure snippet Incoming uses keyword \\wanted, which belongs to Owner.", secure.single().text)
        }
        // The record's own keyword is not a conflict with itself.
        plan(currentVault = current, incomingVault = vault(secure(2, name = "Owner", keyword = "WANTED")))
    }

    @Test fun conflictsAbortTheWholeImportAndAtMostEightAreReported() {
        val current = vault(*(1..12).map { secure(it) }.toTypedArray())
        val incoming = (1..12).map { plain(it) } + plain(50)

        val failure = assertFailsWith<BackupImportFailure.Conflicts> { plan(currentVault = current, incomingSnippets = incoming) }
        assertEquals(8, failure.conflicts.size)
        assertEquals(BackupMerge.MAXIMUM_REPORTED_CONFLICTS, failure.conflicts.size)
        assertFalse(failure.message!!.contains("Plain"), "an exception message must not name a snippet")
        assertFalse(failure.conflicts.first().toString().contains("Plain"))

        // One conflict among many good records still imports nothing: the plan is all or nothing.
        assertEquals(1, conflicts { plan(currentVault = vault(secure(1)), incomingSnippets = listOf(plain(60), plain(1), plain(61))) }.size)
    }

    // The vault

    @Test fun withNoVaultHereTheBackupsVaultIsInstalledAsItIs() {
        val incoming = vault(secure(1), secure(2), x = mapOf("future" to JsonValue.of(1L)))
            .recordingLocalConflictInstallReceiptHashes(mapOf(id(40) to "ab".repeat(32)))

        val result = plan(incomingVault = incoming, clocks = mapOf(id(1) to clock(9_999_999_999_999)))

        val installed = result.vault!!
        // The records keep their own clocks and times: this device has nothing they need to outrank.
        assertEquals(incoming.records, installed.records)
        assertEquals(incoming.wrapRecovery, installed.wrapRecovery)
        assertEquals(mapOf("future" to JsonValue.of(1L)), installed.x, "another device's conflict receipts must not be imported")
        assertEquals(2, result.secureCount)
    }

    @Test fun aRecordThatIsIdenticalApartFromItsClocksIsSkipped() {
        val local = secure(1)
        val fromBackup = local.copy(updatedAt = at(77.0), hlc = clock(42))
        val result = plan(currentVault = vault(local), incomingVault = vault(fromBackup), clocks = mapOf(id(1) to clock(9_999)))

        assertSame(local, result.vault!!.records.single(), "an unchanged record must keep its local clock and not sync again")
        assertEquals(1, result.secureCount, "the count is what the backup held, not what changed")
    }

    @Test fun aChangedRecordReplacesItsMatchAndANewOneIsAppendedWithFreshLocalClocks() {
        val kept = secure(1)
        val old = secure(2, name = "Old name")
        val newer = secure(2, name = "New name").copy(updatedAt = importDate + 500)
        val added = secure(3).copy(updatedAt = at(5.0))
        val clocks = mapOf(id(2) to clock(7_000_000_000_000, 1), id(3) to clock(7_000_000_000_000, 2))

        val result = plan(currentVault = vault(kept, old), incomingVault = vault(added, newer), clocks = clocks)

        val records = result.vault!!.records
        assertEquals(listOf(id(1), id(2), id(3)), records.map { it.id }, "a replacement stays in place; a new record goes to the end")
        assertSame(kept, records[0], "a local record the backup does not hold stays")
        assertEquals("New name", records[1].name)
        // Later of the import and the record's own time; never earlier than the import.
        assertEquals(importDate + 500, records[1].updatedAt)
        assertEquals(importDate, records[2].updatedAt)
        assertEquals(clocks[id(2)], records[1].hlc)
        assertEquals(clocks[id(3)], records[2].hlc)
        assertEquals(added.createdAt, records[2].createdAt)
    }

    /** Exact ciphertext counts: a good backup repairs a record whose `sealed` was damaged although its stored hash survived. */
    @Test fun aRecordWithTheSameHashAndDifferentCiphertextIsReplaced() {
        val damaged = secure(1, sealed = "v1.damaged")
        val good = secure(1, sealed = "v1.good")
        assertEquals(damaged.contentHash, good.contentHash)

        val result = plan(currentVault = vault(damaged), incomingVault = vault(good), clocks = mapOf(id(1) to clock(5)))
        assertEquals("v1.good", result.vault!!.records.single().sealed)

        // The same holds for any other field but the clocks.
        for (changed in listOf(
            good.copy(name = "x"), good.copy(keyword = "other"), good.copy(tags = listOf("t")), good.copy(isEnabled = false),
            good.copy(isPinned = true), good.copy(createdAt = at(3.0)), good.copy(contentHash = "ff"),
            good.copy(x = mapOf("future" to JsonValue.of(true))),
        )) {
            val replaced = plan(currentVault = vault(good), incomingVault = vault(changed), clocks = mapOf(id(1) to clock(5)))
            assertEquals(clock(5), replaced.vault!!.records.single().hlc, "a changed record must be stamped")
        }
    }

    @Test fun thisDevicesDoorsStayAndOnlyAMissingRecoveryWrapIsFilled() {
        val local = vault(secure(1), x = mapOf("shared" to JsonValue.of("local"), "localOnly" to JsonValue.of(1L)))
            .copy(wrapPass = "v1.local.pass", wrapCLI = "v1.local.cli", wrapRecovery = "v1.local.recovery")
            .recordingLocalConflictInstallReceiptHashes(mapOf(id(41) to "cd".repeat(32)))
        val incoming = vault(secure(1), x = mapOf("shared" to JsonValue.of("backup"), "backupOnly" to JsonValue.of(2L)))
            .copy(wrapPass = "v1.backup.pass", wrapCLI = "v1.backup.cli", wrapRecovery = "v1.backup.recovery")
            .recordingLocalConflictInstallReceiptHashes(mapOf(id(42) to "ef".repeat(32)))

        val merged = plan(currentVault = local, incomingVault = incoming).vault!!
        assertEquals(listOf("v1.local.pass", "v1.local.cli", "v1.local.recovery"), listOf(merged.wrapPass, merged.wrapCLI, merged.wrapRecovery))
        assertEquals(JsonValue.of("local"), merged.x["shared"], "an unknown key that exists here is not overwritten")
        assertEquals(JsonValue.of(1L), merged.x["localOnly"])
        assertEquals(JsonValue.of(2L), merged.x["backupOnly"], "an unknown key that is absent here is filled")
        assertEquals(mapOf(id(41) to "cd".repeat(32)), merged.localConflictInstallReceipts, "this device's receipts stay; the backup's never arrive")

        val withoutDoors = local.copy(wrapPass = null, wrapCLI = null, wrapRecovery = null)
        val filled = plan(currentVault = withoutDoors, incomingVault = incoming).vault!!
        assertEquals("v1.backup.recovery", filled.wrapRecovery, "the recovery wrap is portable and is filled when absent")
        assertNull(filled.wrapPass, "a passphrase wrap belongs to the device that made it")
        assertNull(filled.wrapCLI)
    }

    @Test fun aRivalVaultIsRefusedWhateverElseTheBackupHolds() {
        val local = vault(secure(1))
        for (rival in listOf(
            vault(secure(2)).copy(kid = "k-another"),
            vault(secure(2)).copy(vaultSalt = "AAAAAAAAAAAAAAAAAAAAAA"),
            vault(secure(2)).copy(schemaVersion = 0),
        )) {
            assertFailsWith<BackupImportFailure.IncompatibleVault> {
                plan(currentSnippets = listOf(plain(5)), currentVault = local, incomingSnippets = listOf(plain(6)), incomingVault = rival)
            }
        }
        // The check comes before conflict collection: an incompatible vault is not reported as a list of conflicts.
        assertFailsWith<BackupImportFailure.IncompatibleVault> {
            plan(currentVault = local, incomingSnippets = listOf(plain(1)), incomingVault = vault(secure(2)).copy(kid = "k-another"))
        }
    }

    @Test fun aBackupWithoutAVaultLeavesTheVaultExactlyAsItIs() {
        val local = vault(secure(1))
        val result = plan(currentSnippets = listOf(plain(2)), currentVault = local, incomingSnippets = listOf(plain(3)))
        assertSame(local, result.vault)
        assertEquals(listOf(id(3), id(2)), result.snippets.map { it.id })
    }

    /** The only replace mode: the explicit recovery of a quarantined ordinary library. The vault half is unaffected. */
    @Test fun authoritativeRecoveryReplacesTheOrdinaryHalfOnly() {
        val local = vault(secure(1, keyword = "bank"))
        val result = plan(
            currentSnippets = listOf(plain(2), plain(3)),
            currentVault = local,
            incomingSnippets = listOf(plain(4), plain(2, name = "restored")),
            incomingVault = vault(secure(5)),
            clocks = mapOf(id(5) to clock(8)),
            authoritative = true,
        )
        assertEquals(listOf(id(2), id(4)), result.snippets.map { it.id }, "the unreadable library's snippets are not merged in")
        assertEquals("restored", result.snippets[0].name)
        assertEquals(listOf(id(1), id(5)), result.vault!!.records.map { it.id }, "the vault still merges")

        // Secure records still guard their ids and keywords against the incoming ordinary half.
        assertEquals(
            listOf(BackupMerge.Conflict.OrdinaryKeywordIsSecure("bank", "Secure 1")),
            conflicts { plan(currentVault = local, incomingSnippets = listOf(plain(9, keyword = "bank")), authoritative = true) },
        )
        // And a snippet of the replaced library is no obstacle for an incoming secure record.
        plan(
            currentSnippets = listOf(plain(7, keyword = "taken")), currentVault = local,
            incomingVault = vault(secure(7, keyword = "taken")), clocks = mapOf(id(7) to clock(9)), authoritative = true,
        )
    }

    // Clocks

    @Test fun importedRecordsGetLocalClocksAtLeastAsLateAsTheImportAndTheirOwn() {
        val generator = HlcGenerator("aabbccdd", physicalNowMs = { 1_000L })
        val importWallMs = ((importDate + 978_307_200.0) * 1000).toLong()
        val early = secure(1).copy(hlc = Hlc.of(5, 0, "11111111"))
        val late = secure(2).copy(hlc = Hlc.of(importWallMs + 60_000, 3, "22222222"))

        val clocks = BackupMerge.importedClocks(vault(early, late), importDate, generator::sendAtLeast)

        assertEquals(listOf(id(1), id(2)), clocks.keys.toList(), "issued in record order")
        assertEquals(importWallMs, clocks.getValue(id(1)).wallMs, "an old record is stamped with the import")
        assertEquals(importWallMs + 60_000, clocks.getValue(id(2)).wallMs, "a record from the future keeps at least its own wall time")
        assertTrue(clocks.values.all { it.device == "aabbccdd" }, "the clock is this device's")
        assertTrue(clocks.getValue(id(2)) > clocks.getValue(id(1)), "and strictly after the one issued before it")

        assertEquals(emptyMap(), BackupMerge.importedClocks(null, importDate, generator::sendAtLeast))
        // An import date before 1970 clamps to zero instead of wrapping.
        val ancient = BackupMerge.importedClocks(vault(early), -2_000_000_000.0, generator::sendAtLeast)
        assertTrue(ancient.getValue(id(1)).wallMs >= importWallMs + 60_000, "the generator never goes backwards")
    }
}
