package com.khm.snippets.core.vault

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.SeededRandom
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.FoundationJsonWriter
import org.junit.Test
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `Tests/Core/VaultDocumentTests.swift`, test for test, under the Swift names. Each test
 * names the loss it prevents.
 *
 * Not ported: the two `mergingSharedIdentity` tests (the iCloud Keychain vault identity
 * does not exist on Android), `shellsParticipateInKeywordCollisionResolution` (it tests
 * `SyncMerge`, which belongs to the merge package) and the `SecretStore` suite (the
 * 32-byte wrapping-secret store behind the reserved `wrapCLI`; `VaultKeyStoreTest` covers
 * the same contract for the store Android uses).
 */
class VaultDocumentTest {

    /** `BagRandom`: an arbitrary JSON value, with key names that look like fields this build knows. */
    private class BagRandom(seed: Long) {
        private val random = SeededRandom(seed)

        fun int(upperBound: Int): Int =
            if (upperBound <= 0) 0 else java.lang.Long.remainderUnsigned(random.next(), upperBound.toLong()).toInt()

        fun json(depth: Int): JsonValue = when (int(if (depth <= 0) 5 else 7)) {
            0 -> JsonValue.Null
            1 -> JsonValue.Bool(int(2) == 0)
            2 -> JsonValue.Integer(int(2_000_001).toLong() - 1_000_000)
            // Half-integral: exact in binary and never an integer.
            3 -> JsonValue.Real(int(100_000) + 0.5)
            4 -> JsonValue.Text(listOf("", "sealed", "ünïcode 🔐", "x", "a\nb", "\"quoted\"")[int(6)])
            5 -> JsonValue.Array((0 until int(4)).map { json(depth - 1) })
            else -> {
                val members = LinkedHashMap<String, JsonValue>()
                repeat(int(4)) { members[listOf("", "id", "future", "ü", "nested")[int(5)]] = json(depth - 1) }
                JsonValue.Object(members)
            }
        }

        fun bag(): Map<String, JsonValue> {
            val bag = LinkedHashMap<String, JsonValue>()
            val count = int(5)
            for (index in 0 until count) bag["future$index"] = json(3)
            return bag
        }
    }

    // Round trip

    @Test fun aDocumentSurvivesAnEncodeDecodeRoundTrip() {
        val original = document(wrapCLI = "v1.k-7f3a91c0.cli.bm9uY2U.d3JhcA")

        val decoded = VaultFile.decode(VaultFile.encode(original))

        assertEquals(original, decoded)
        assertEquals(original.kid, decoded.kid)
        assertEquals(original.vaultSalt, decoded.vaultSalt)
        assertEquals(original.kdf, decoded.kdf)
        assertEquals(original.wrapPass, decoded.wrapPass)
        assertEquals(original.wrapRecovery, decoded.wrapRecovery)
        assertEquals(original.wrapCLI, decoded.wrapCLI)
        assertEquals(original.records.map { it.id }, decoded.records.map { it.id })
        assertEquals(original.records.map { it.sealed }, decoded.records.map { it.sealed })
        assertEquals(original.records.map { it.hlc }, decoded.records.map { it.hlc })
    }

    /** The file is compare-and-swapped on its bytes: one document must always produce one file. */
    @Test fun theSameDocumentAlwaysProducesTheSameBytes() {
        val random = BagRandom(0xC0FFEE)
        val subject = document(
            x = random.bag(), kdfX = random.bag(),
            records = listOf(record(0, x = random.bag()), record(1, x = random.bag())),
        )

        val first = VaultFile.encode(subject)
        val second = VaultFile.encode(subject)
        val afterRoundTrip = VaultFile.encode(VaultFile.decode(first))

        assertContentEquals(first, second)
        assertContentEquals(first, afterRoundTrip, "a decode/encode cycle is not a fixed point")
    }

    /** `null` rather than an absent key: a key that vanishes looks like an older build stripping it. */
    @Test fun theCLIWrapIsWrittenAsAnExplicitNullWhenTheUserHasNotOptedIn() {
        val bytes = VaultFile.encode(document(wrapCLI = null))
        val text = String(bytes, Charsets.UTF_8)

        assertTrue(text.contains("\"wrapCLI\" : null"))
        assertNull(VaultFile.decode(bytes).wrapCLI)
    }

    /** All three wraps are written even when absent, and all three may be absent or null on read. */
    @Test fun allThreeWrapsAreExplicitNullsAndMayBeAbsentOnRead() {
        val none = document().copy(wrapPass = null, wrapRecovery = null, wrapCLI = null)
        val text = String(VaultFile.encode(none), Charsets.UTF_8)
        for (key in listOf("wrapPass", "wrapRecovery", "wrapCLI")) assertTrue(text.contains("\"$key\" : null"), key)

        val absent = """{"schemaVersion":1,"kid":"k","vaultSalt":"IiIi","kdf":{"alg":"a","iterations":1,"saltP":"VVVV"},"records":[]}"""
        val decoded = VaultFile.decode(absent.toByteArray())
        assertNull(decoded.wrapPass)
        assertNull(decoded.wrapRecovery)
        assertNull(decoded.wrapCLI)

        // A wrap of the wrong type is not "no wrap": the document cannot be trusted.
        val wrongType = absent.replace("\"records\"", "\"wrapRecovery\":42,\"records\"")
        assertEquals(
            VaultDecodeException.Kind.TYPE_MISMATCH,
            assertFailsWith<VaultDecodeException> { VaultFile.decode(wrongType.toByteArray()) }.kind,
        )
    }

    @Test fun timestampsKeepMillisecondResolution() {
        val odd = 1_785_312_000.123 - 978_307_200.0
        val subject = document(
            records = listOf(
                VaultRecord(
                    id = id(9), name = "n", keyword = "k", createdAt = odd, updatedAt = odd,
                    hlc = clock(1_785_312_000_123), contentHash = "h", sealed = "s",
                ),
            ),
        )

        val decoded = VaultFile.decode(VaultFile.encode(subject))
        val delta = Math.abs(decoded.records.first().updatedAt - odd)

        assertTrue(delta < 0.001, "millisecond resolution was lost; drift was ${delta}s")
        assertTrue(String(VaultFile.encode(subject), Charsets.UTF_8).contains("2026-07-29T08:00:00.123Z"))
    }

    // Unknown-key passthrough

    /** An older build that opens a newer file must write back what it did not understand. */
    @Test fun unknownKeysSurviveDecodeAndReEncode() {
        val json = """
            {
              "schemaVersion": 1,
              "kid": "k-7f3a91c0",
              "vaultSalt": "c2FsdA==",
              "kdf": {
                "alg": "argon2id",
                "iterations": 3,
                "saltP": "cGVwcGVy",
                "memoryKiB": 65536,
                "parallelism": 4
              },
              "wrapPass": "wp",
              "wrapRecovery": "wr",
              "wrapCLI": null,
              "teamScope": {"id": "t-1", "members": ["a", "b"], "quota": 12.5, "trial": null},
              "records": [
                {
                  "id": "00000000-0000-4000-8000-000000000000",
                  "name": "n",
                  "keyword": "k",
                  "tags": ["t"],
                  "isEnabled": true,
                  "isPinned": false,
                  "createdAt": "2026-07-29T20:00:00.000Z",
                  "updatedAt": "2026-07-29T20:00:00.500Z",
                  "hlc": "0000019a1b2c-0000-aabbccdd",
                  "contentHash": "h",
                  "sealed": "s",
                  "expiresAt": "2027-01-01T00:00:00.000Z",
                  "revealCount": 7,
                  "policy": {"requireTouchID": true, "maxAgeDays": 30}
                }
              ]
            }
        """.trimIndent()
        val decoded = VaultFile.decode(json.toByteArray())

        assertEquals(
            JsonValue.obj(
                "id" to JsonValue.of("t-1"),
                "members" to JsonValue.array(JsonValue.of("a"), JsonValue.of("b")),
                "quota" to JsonValue.of(12.5),
                "trial" to JsonValue.Null,
            ),
            decoded.x["teamScope"],
        )
        assertEquals(mapOf("memoryKiB" to JsonValue.of(65536L), "parallelism" to JsonValue.of(4L)), decoded.kdf.x)

        val onlyRecord = decoded.records.first()
        assertEquals(JsonValue.of("2027-01-01T00:00:00.000Z"), onlyRecord.x["expiresAt"])
        assertEquals(JsonValue.of(7L), onlyRecord.x["revealCount"])
        assertEquals(
            JsonValue.obj("requireTouchID" to JsonValue.of(true), "maxAgeDays" to JsonValue.of(30L)),
            onlyRecord.x["policy"],
        )

        val text = String(VaultFile.encode(decoded), Charsets.UTF_8)
        for (survivor in listOf(
            "teamScope", "memoryKiB", "parallelism", "expiresAt", "revealCount", "requireTouchID", "maxAgeDays", "t-1",
        )) {
            assertTrue(text.contains(survivor), "'$survivor' was stripped by a decode/encode cycle")
        }
        assertEquals(decoded, VaultFile.decode(text.toByteArray()))
    }

    /** Two keys with one name would make the file mean different things to different parsers. */
    @Test fun aBagEntryCannotShadowARealField() {
        val base = document(records = listOf(record(0)))
        val subject = base.copy(
            x = mapOf("kid" to JsonValue.of("attacker")),
            records = listOf(base.records[0].copy(x = mapOf("sealed" to JsonValue.of("attacker")))),
        )

        val text = String(VaultFile.encode(subject), Charsets.UTF_8)
        val decoded = VaultFile.decode(text.toByteArray())

        assertFalse(text.contains("attacker"))
        assertEquals("k-7f3a91c0", decoded.kid)
        assertEquals(record(0).sealed, decoded.records.first().sealed)
    }

    @Test fun arbitraryPassthroughBagsRoundTripUnchanged() {
        for (seed in longArrayOf(1, 2, 3, 5, 8, 13, 21, 34)) {
            val random = BagRandom(seed)
            val subject = document(
                x = random.bag(), kdfX = random.bag(),
                records = listOf(record(0, x = random.bag()), record(1, x = random.bag())),
            )

            val encoded = VaultFile.encode(subject)
            val decoded = VaultFile.decode(encoded)

            assertEquals(subject.x, decoded.x, "seed $seed")
            assertEquals(subject.kdf.x, decoded.kdf.x, "seed $seed")
            assertEquals(subject.records.map { it.x }, decoded.records.map { it.x }, "seed $seed")
            assertContentEquals(encoded, VaultFile.encode(decoded), "seed $seed")
        }
    }

    /** The one documented lossy edge: JSON has one number type, so `12.0` comes back as `12` and then stays put. */
    @Test fun anIntegralDoubleIsRewrittenAsAnIntegerAndThenStaysPut() {
        val base = document(records = listOf(record(0)))
        val subject = base.copy(
            records = listOf(base.records[0].copy(x = mapOf("whole" to JsonValue.of(12.0), "fractional" to JsonValue.of(12.5)))),
        )

        val once = VaultFile.decode(VaultFile.encode(subject))
        assertEquals(mapOf("whole" to JsonValue.of(12L), "fractional" to JsonValue.of(12.5)), once.records.first().x)

        val twice = VaultFile.decode(VaultFile.encode(once))
        assertEquals(once, twice, "the normalization must happen at most once")
    }

    /** Foundation's rules for a number in a bag: an integer when it is one and fits, a double otherwise. */
    @Test fun passthroughNumbersFollowFoundationsIntegerRule() {
        val json = """{"schemaVersion":1,"kid":"k","vaultSalt":"IiIi","kdf":{"alg":"a","iterations":1,"saltP":"VVVV"},
            "records":[],"n":{"max":9223372036854775807,"min":-9223372036854775808,"over":9223372036854775808,
            "big":18446744073709551616,"exact":9007199254740993,"exp":1e3,"frac":1.50,"negzero":-0,"one":1.0}}"""
        val n = VaultFile.decode(json.toByteArray()).x.getValue("n").objectOrNull!!

        assertEquals(JsonValue.of(Long.MAX_VALUE), n["max"])
        assertEquals(JsonValue.of(Long.MIN_VALUE), n["min"])
        assertEquals(JsonValue.of(9.223372036854775808E18), n["over"])
        assertEquals(JsonValue.of(1.8446744073709552E19), n["big"])
        // Beyond 2^53 and still exact: the digits are read as an integer, not through a double.
        assertEquals(JsonValue.of(9007199254740993L), n["exact"])
        assertEquals(JsonValue.of(1000L), n["exp"])
        assertEquals(JsonValue.of(1.5), n["frac"])
        assertEquals(JsonValue.of(0L), n["negzero"])
        assertEquals(JsonValue.of(1L), n["one"])
    }

    /** One unrepresentable value must not fail the whole load: the key is left out, the vault opens. */
    @Test fun anUnrepresentableBagValueIsDroppedWithoutFailingTheLoad() {
        val json = """{"schemaVersion":1,"kid":"k","vaultSalt":"IiIi","kdf":{"alg":"a","iterations":1,"saltP":"VVVV"},
            "records":[],"good":1,"badNumber":01,"badNested":{"a":[1e999]},"badString":"\q"}"""
        val decoded = VaultFile.decode(json.toByteArray())
        assertEquals(mapOf("good" to JsonValue.of(1L)), decoded.x)
    }

    /** What Foundation's reader tolerates in a file, this one tolerates: a byte order mark, a trailing comma, a duplicate key (first wins). */
    @Test fun foundationsJsonLeniencyIsKept() {
        val json = "﻿" + """{"schemaVersion":1,"kid":"first","kid":"second","vaultSalt":"IiIi",
            "kdf":{"alg":"a","iterations":1.0,"saltP":"VVVV",},"records":[],}"""
        val decoded = VaultFile.decode(json.toByteArray(Charsets.UTF_8))
        assertEquals("first", decoded.kid)
        assertEquals(1L, decoded.kdf.iterations)
    }

    // Version probe

    /** The probe runs before the decode and does not depend on it: a newer vault is never called corrupt. */
    @Test fun aNewerSchemaVersionIsReadOnlyEvenWhenTheRestOfTheFileIsUnintelligible() {
        val scratch = Scratch("too-new")
        try {
            scratch.put(
                """
                {
                  "schemaVersion": 99,
                  "kdf": "this is not an object",
                  "wrapPass": 12345,
                  "records": "not an array either",
                  "sealedEnvelope": {"v": 2}
                }
                """.trimIndent(),
            )
            val before = Files.getLastModifiedTime(scratch.vault.toPath())
            val bytesBefore = scratch.bytes()

            val outcome = scratch.vaultFile().load()

            assertEquals(99L, outcome.tooNewVersion)
            assertFalse(outcome.isCorrupt, "a newer file must not be mistaken for a damaged one")
            assertEquals(before, Files.getLastModifiedTime(scratch.vault.toPath()), "loading a newer vault touched it")
            assertContentEquals(bytesBefore, scratch.bytes())
            assertEquals(emptyList(), entries(scratch.quarantineFolder), "a newer vault was quarantined")
        } finally {
            scratch.destroy()
        }
    }

    @Test fun aDocumentFromANewerBuildCannotBeWrittenBack() {
        val scratch = Scratch("write-refused")
        try {
            assertFailsWith<VaultFileError.WriteRefused> {
                scratch.vaultFile().write(document(schemaVersion = VaultDocument.CURRENT_SCHEMA_VERSION + 1))
            }
            assertNull(scratch.bytes(), "the refused write created a file anyway")

            // The locked path enforces the same rule on what a transform returns.
            assertFailsWith<VaultFileError.WriteRefused> {
                scratch.vaultFile().update(1000) { document(schemaVersion = 2) }
            }
            assertNull(scratch.bytes())
        } finally {
            scratch.destroy()
        }
    }

    @Test fun aFileAtOrBelowThisSchemaVersionLoadsNormally() {
        val scratch = Scratch("current-version")
        try {
            scratch.vaultFile().write(document())

            assertEquals(document(), scratch.vaultFile().load().valueOrNull)
            assertNull(scratch.vaultFile().load().tooNewVersion)
        } finally {
            scratch.destroy()
        }
    }

    // Missing versus unreadable versus corrupt

    @Test fun noVaultYetIsMissingRatherThanCorrupt() {
        val scratch = Scratch("missing")
        try {
            assertTrue(scratch.vaultFile().load().isMissing)
            assertTrue(scratch.vaultFile().loadMetadata().isMissing)
        } finally {
            scratch.destroy()
        }
    }

    /** An I/O failure is not corruption: quarantining on a read error would move a good vault aside. */
    @Test fun anUnreadableVaultIsNotReportedAsCorrupt() {
        val scratch = Scratch("unreadable")
        try {
            // A directory where the file should be: reliably unreadable.
            Files.createDirectories(scratch.vault.toPath())

            val outcome = scratch.vaultFile().load()

            assertFalse(outcome.isCorrupt)
            assertFalse(outcome.isMissing)
            assertIs<VaultLoadOutcome.Unreadable>(outcome)
            assertIs<VaultFileError.Unreadable>(outcome.failure)
            assertIs<VaultLoadOutcome.Unreadable>(scratch.vaultFile().loadMetadata())
        } finally {
            scratch.destroy()
        }
    }

    /** A missing `records` array read as "empty vault" would be saved, turning damage into loss. */
    @Test fun aDocumentWithoutItsRecordsArrayIsCorruptRatherThanEmpty() {
        val scratch = Scratch("no-records")
        try {
            scratch.put(
                """
                {"schemaVersion": 1, "kid": "k", "vaultSalt": "s",
                 "kdf": {"alg": "a", "iterations": 1, "saltP": "p"},
                 "wrapPass": "wp", "wrapRecovery": "wr"}
                """.trimIndent(),
            )
            assertTrue(scratch.vaultFile().load().isCorrupt)
        } finally {
            scratch.destroy()
        }
    }

    /** Metadata may be damaged and the record still survives; the ciphertext is what cannot be retyped. */
    @Test fun damagedMetadataKeepsTheRecordButAMissingSealedBlobDoesNot() {
        val lenient = """
            {"schemaVersion": 1, "kid": "k", "vaultSalt": "s",
             "kdf": {"alg": "a", "iterations": 1, "saltP": "p"},
             "wrapPass": "wp", "wrapRecovery": "wr",
             "records": [{
               "id": "00000000-0000-4000-8000-000000000007",
               "name": 42, "keyword": ["not", "a", "string"], "tags": "work",
               "isEnabled": "yes", "isPinned": 1,
               "createdAt": "not a date", "updatedAt": {},
               "hlc": "nonsense",
               "sealed": "the irreplaceable part"
             }]}
        """.trimIndent()
        val only = VaultFile.decode(lenient.toByteArray()).records.first()

        assertEquals("the irreplaceable part", only.sealed)
        assertEquals(id(7), only.id)
        assertEquals("", only.name)
        assertEquals("", only.keyword)
        assertEquals(emptyList(), only.tags)
        assertTrue(only.isEnabled)
        assertFalse(only.isPinned)
        // The distant past, never a fabricated "now": an undated record must lose every merge.
        assertEquals(VaultTimestamp.DISTANT_PAST, only.createdAt)
        assertEquals(VaultTimestamp.DISTANT_PAST, only.updatedAt)
        assertEquals(Hlc.FOREIGN_DEVICE, only.hlc.device, "a damaged clock must fall back to foreign")

        val withoutSealed = lenient.replace("\"sealed\": \"the irreplaceable part\"", "\"revealCount\": 3")
        assertFailsWith<VaultDecodeException> { VaultFile.decode(withoutSealed.toByteArray()) }
    }

    // Quarantine

    /** A vault this build cannot read is moved aside intact: never deleted, never truncated, never replaced. */
    @Test fun aCorruptVaultIsQuarantinedIntactAndNeverOverwritten() {
        val scratch = Scratch("quarantine")
        try {
            val damaged = "{\"schemaVersion\": 1, \"kid\": \"k\", trunca".toByteArray()
            scratch.put(damaged)
            val before = Files.getLastModifiedTime(scratch.vault.toPath())
            val file = scratch.vaultFile()

            val outcome = file.load()
            assertTrue(outcome.isCorrupt)
            assertNotNull(outcome.failure)
            assertEquals(before, Files.getLastModifiedTime(scratch.vault.toPath()), "merely loading a damaged vault rewrote it")
            assertContentEquals(damaged, scratch.bytes())

            // A write over it is refused; only a deliberate quarantine removes it from the path.
            assertFailsWith<VaultFileError.WriteRefused> { file.update(1000) { document() } }
            assertContentEquals(damaged, scratch.bytes())

            val moved = file.quarantine("truncated JSON", at(0.0))

            assertContentEquals(damaged, Files.readAllBytes(moved.toPath()), "quarantine altered the bytes")
            assertEquals("vault-20260729-080000.json", moved.name)
            assertEquals("Quarantine", moved.parentFile.name)
            assertEquals("Vault", moved.parentFile.parentFile.name, "the vault was quarantined outside its own folder")
            assertFalse(scratch.vault.exists(), "quarantine left the damaged file in place")
            assertTrue(file.load().isMissing)

            val note = String(Files.readAllBytes(moved.toPath().resolveSibling("vault-20260729-080000.txt")), Charsets.UTF_8)
            assertTrue(note.contains("truncated JSON"))
            assertTrue(note.contains("NOT deleted"))
            assertTrue(note.contains("2026-07-29T08:00:00.000Z"))
        } finally {
            scratch.destroy()
        }
    }

    @Test fun quarantiningTwiceInTheSameSecondKeepsBothCopies() {
        val scratch = Scratch("quarantine-twice")
        try {
            scratch.put("first")
            val firstMove = scratch.vaultFile().quarantine("one", at(0.0))
            scratch.put("second")
            val secondMove = scratch.vaultFile().quarantine("two", at(0.0))

            assertFalse(firstMove == secondMove)
            assertEquals("vault-20260729-080000-2.json", secondMove.name)
            assertEquals("first", String(Files.readAllBytes(firstMove.toPath())))
            assertEquals("second", String(Files.readAllBytes(secondMove.toPath())))
        } finally {
            scratch.destroy()
        }
    }

    @Test fun quarantiningNothingIsAnError() {
        val scratch = Scratch("quarantine-nothing")
        try {
            assertFailsWith<VaultFileError.QuarantineFailed> { scratch.vaultFile().quarantine("nothing here", at(0.0)) }
        } finally {
            scratch.destroy()
        }
    }

    // Metadata-only decode

    /** The listing path never looks at `kdf` or the wraps: every one of them is unintelligible here. */
    @Test fun metadataOnlyDecodeNeedsNoKeyAndNoKDF() {
        val scratch = Scratch("metadata-only")
        try {
            scratch.put(
                """
                {
                  "schemaVersion": 1,
                  "kdf": "not an object at all",
                  "wrapPass": 42,
                  "wrapRecovery": {"unexpected": true},
                  "records": [
                    {"id": "00000000-0000-4000-8000-000000000000", "name": "AWS root password",
                     "keyword": "awsroot", "tags": ["work"], "isEnabled": true, "isPinned": true,
                     "createdAt": "2026-07-29T20:00:00.000Z", "updatedAt": "2026-07-29T20:00:00.500Z",
                     "hlc": "0000019a1b2c-0000-aabbccdd", "contentHash": "h", "sealed": "s"},
                    {"id": "00000000-0000-4000-8000-000000000001", "name": "Recovery codes",
                     "keyword": "codes", "sealed": "s2"}
                  ]
                }
                """.trimIndent(),
            )

            assertTrue(scratch.vaultFile().load().isCorrupt)

            val metadata = assertNotNull(scratch.vaultFile().loadMetadata().valueOrNull)
            assertEquals(1L, metadata.schemaVersion)
            assertFalse(metadata.isNewerThanThisBuild)
            assertEquals(listOf("AWS root password", "Recovery codes"), metadata.shells.map { it.name })
            assertEquals(listOf("awsroot", "codes"), metadata.shells.map { it.keyword })
            assertEquals(listOf("", ""), metadata.shells.map { it.content })
            assertEquals(listOf(true, false), metadata.shells.map { it.isPinned })
        } finally {
            scratch.destroy()
        }
    }

    /** Reading is safe at any schema version; only writing is version-gated. */
    @Test fun metadataOnlyDecodeReadsANewerVaultAndSaysSo() {
        val scratch = Scratch("metadata-newer")
        try {
            scratch.put(
                """
                {"schemaVersion": 99, "records": [
                  {"id": "00000000-0000-4000-8000-000000000000", "name": "From the future",
                   "keyword": "future", "sealed": "s", "quantumField": {"a": [1, 2, 3]}}
                ]}
                """.trimIndent(),
            )

            val metadata = assertNotNull(scratch.vaultFile().loadMetadata().valueOrNull)
            assertTrue(metadata.isNewerThanThisBuild)
            assertEquals(listOf("From the future"), metadata.shells.map { it.name })
            assertEquals(99L, scratch.vaultFile().load().tooNewVersion)
        } finally {
            scratch.destroy()
        }
    }

    // Shells

    /** A shell's content is empty, not a placeholder: an empty expansion is inert wherever a shell ends up. */
    @Test fun shellsCarryEmptyContentAndEveryPlaintextField() {
        val subject = record(
            3, name = "AWS root password", keyword = "  \\awsroot  ",
            tags = listOf("work", "prod"), isEnabled = false, isPinned = true, createdAt = 10.0, updatedAt = 20.0,
        )

        val shell = subject.shell

        assertEquals("", shell.content)
        assertEquals(subject.id, shell.id)
        assertEquals("AWS root password", shell.name)
        assertEquals("  \\awsroot  ", shell.keyword, "the shell must carry the keyword verbatim")
        assertEquals("awsroot", shell.normalizedKeyword)
        assertEquals(listOf("work", "prod"), shell.tags)
        assertFalse(shell.isEnabled)
        assertTrue(shell.isPinned)
        assertEquals(at(10.0), shell.createdAt)
        assertEquals(at(20.0), shell.updatedAt)
    }

    /** Tags are normalized on decode and left alone in memory, exactly the split `Snippet` has. */
    @Test fun tagsAreNormalizedWhereSnippetNormalizesThem() {
        val messy = record(0, tags = listOf("Work", "work", " prod ", "", "  "))
        assertEquals(listOf("Work", "work", " prod ", "", "  "), messy.tags)

        val decoded = VaultFile.decode(VaultFile.encode(document(records = listOf(messy))))
        assertEquals(listOf("Work", "prod"), decoded.records.first().tags)
    }

    @Test fun documentShellsAreOnePerRecordInFileOrder() {
        val subject = document(
            records = listOf(record(2, name = "second", keyword = "b"), record(1, name = "first", keyword = "a")),
        )

        assertEquals(listOf("second", "first"), subject.shells.map { it.name })
        assertTrue(subject.shells.all { it.content.isEmpty() })
        assertEquals("first", subject.record(id(1))?.name)
        assertNull(subject.record(id(99)))
    }

    // Writing

    @Test fun aWrittenVaultIsAtomicPrivateAndStagedOutsideItsOwnFolder() {
        val scratch = Scratch("write")
        try {
            scratch.vaultFile().write(document())

            assertEquals(
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
                Files.getPosixFilePermissions(scratch.vault.toPath()),
                "the vault must not be group- or world-readable",
            )
            assertEquals(listOf("vault.json"), entries(scratch.locations.vaultFolder), "the write left staging debris beside the vault")
            assertEquals(emptyList(), entries(scratch.locations.tmpFolder))
            assertEquals(document(), scratch.vaultFile().load().valueOrNull)
        } finally {
            scratch.destroy()
        }
    }

    /** `Vault/` may not exist yet on a device that has never used the feature. */
    @Test fun writingCreatesTheVaultFolderWhenItIsMissing() {
        val scratch = Scratch("mkdir")
        try {
            val nested = java.io.File(java.io.File(scratch.root, "Fresh"), "vault.json")
            val file = VaultFile(nested, scratch.locations.guard, scratch.locations.tmpFolder)

            file.write(document())

            assertEquals(document(), file.load().valueOrNull)
        } finally {
            scratch.destroy()
        }
    }

    // JSONValue (`JSONValueTests`)

    /** `true` must not become `1`, and `600000` must not become `600000.0`. */
    @Test fun scalarsKeepTheirJSONType() {
        val json = """{"t": true, "f": false, "i": 600000, "d": 12.5, "s": "1", "n": null}"""
        val decoded = LenientJson.passthrough(LenientJson.parse(json.toByteArray())).objectOrNull!!

        assertEquals(JsonValue.of(true), decoded["t"])
        assertEquals(JsonValue.of(false), decoded["f"])
        assertEquals(JsonValue.of(600_000L), decoded["i"])
        assertEquals(JsonValue.of(12.5), decoded["d"])
        assertEquals(JsonValue.of("1"), decoded["s"])
        assertEquals(JsonValue.Null, decoded["n"])

        val text = String(FoundationJsonWriter.prettyPrinted(JsonValue.Object(decoded)), Charsets.UTF_8)
        assertEquals(
            "{\"d\":12.5,\"f\":false,\"i\":600000,\"n\":null,\"s\":\"1\",\"t\":true}",
            text.replace("\n", "").replace(" ", ""),
        )
    }

    @Test fun nestingAndEmptyContainersSurvive() {
        val json = """{"a":[],"b":{},"c":[[],[{"d":[null,{"e":1}]}]]}"""
        val decoded = LenientJson.passthrough(LenientJson.parse(json.toByteArray()))
        val text = String(FoundationJsonWriter.prettyPrinted(decoded), Charsets.UTF_8)
        assertEquals(json, text.replace("\n", "").replace(" ", ""))
    }

    // The device-local conflict receipts kept in the document bag

    @Test fun conflictReceiptsAreReadStrictlyAndNeverGuessed() {
        val hash = "cd".repeat(32)
        val copy = Uuids.parse("ffffffff-ffff-4fff-bfff-ffffffffffff")!!
        val empty = document(records = emptyList())
        assertEquals(emptyMap(), empty.localConflictInstallReceipts)

        val recorded = empty.recordingLocalConflictInstallReceiptHashes(mapOf(copy to hash))
        assertEquals(mapOf(copy to hash), recorded.localConflictInstallReceipts)
        assertEquals(
            JsonValue.obj(hash to JsonValue.of("ffffffff-ffff-4fff-bfff-ffffffffffff")),
            recorded.x[VaultDocument.LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY],
        )
        // It survives the file.
        assertEquals(mapOf(copy to hash), VaultFile.decode(VaultFile.encode(recorded)).localConflictInstallReceipts)

        assertEquals(mapOf(copy to hash), recorded.retainingLocalConflictInstallReceipts(setOf(copy)).localConflictInstallReceipts)
        assertFalse(VaultDocument.LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY in recorded.retainingLocalConflictInstallReceipts(emptySet()).x)
        assertFalse(VaultDocument.LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY in recorded.removingLocalConflictInstallReceipts().x)

        // A newer version of the receipts, an uppercase id, a malformed hash or one copy id twice: unknown, not empty.
        val newer = empty.copy(x = mapOf("local.syncConflictC0Receipts.v2" to JsonValue.obj()))
        assertNull(newer.localConflictInstallReceipts)
        assertFailsWith<VaultDocument.MalformedConflictReceipts> { newer.recordingLocalConflictInstallReceiptHashes(mapOf(copy to hash)) }
        assertFalse(newer.removingLocalConflictInstallReceipts().x.keys.any { it.startsWith(VaultDocument.LOCAL_CONFLICT_INSTALL_RECEIPTS_PREFIX) })

        fun receipts(value: JsonValue) = empty.copy(x = mapOf(VaultDocument.LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY to value)).localConflictInstallReceipts
        assertNull(receipts(JsonValue.obj(hash to JsonValue.of("FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF"))))
        assertNull(receipts(JsonValue.obj("CD".repeat(32) to JsonValue.of("ffffffff-ffff-4fff-bfff-ffffffffffff"))))
        assertNull(receipts(JsonValue.obj(hash to JsonValue.of(1L))))
        assertNull(receipts(JsonValue.of("not an object")))
        assertNull(
            receipts(
                JsonValue.obj(
                    hash to JsonValue.of("ffffffff-ffff-4fff-bfff-ffffffffffff"),
                    "ab".repeat(32) to JsonValue.of("ffffffff-ffff-4fff-bfff-ffffffffffff"),
                ),
            ),
        )
        assertFailsWith<VaultDocument.MalformedConflictReceipts> {
            empty.recordingLocalConflictInstallReceiptHashes(mapOf(copy to "not a hash"))
        }
    }

    /** Swift's equality: text by canonical equivalence, timestamps as IEEE doubles. It decides whether the file is rewritten. */
    @Test fun equalityIsSwifts() {
        val composed = record(0, name = "Café")
        val decomposed = record(0, name = "Café")
        assertEquals(composed, decomposed)
        assertEquals(composed.hashCode(), decomposed.hashCode())
        assertEquals(record(0).copy(createdAt = 0.0), record(0).copy(createdAt = -0.0))
        assertFalse(record(0) == record(0, name = "other"))
        assertFalse(record(0) == record(0, sealed = "v1.other"))
        assertFalse(record(0).toString().contains("AWS"), "a record's name must not reach a log through toString")
        assertFalse(document().toString().contains("k-7f3a91c0"))
    }
}
