package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.wire.SyncEnvelope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The two cross-client merge fixtures of `snippets-linux/tests/fixtures`, copied to
 * `fixtures/linux/`: `merge-v1.json` (Rust `ordinary_conflict_copy_matches_independent_
 * snapshot_sha_and_uuid_v5`, `deletion_review_…`) and `conflict-copy-v1.json` (Rust
 * `canonical_conflict_copies_match_the_cross_client_vectors`, Swift
 * `SyncConflictCopyVectorTests`, both cases).
 */
class LinuxMergeFixturesTest {

    private fun fixture(name: String): JsonObject =
        Json.parseToJsonElement(javaClass.getResource("/fixtures/linux/$name")!!.readText()).jsonObject

    private fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.content

    private val recordId = UUID.fromString("00000000-0000-4000-8000-000000000021")

    private fun record(wall: Long, body: String) = SyncEnvelope(
        id = recordId, hlc = Hlc.of(wall, 0, "aaaaaaa1"), origin = "aaaaaaa1", secure = false, deleted = false,
        fields = SyncEnvelope.Fields(
            name = "Public losing fixture", keyword = "fixture", content = MergeFixtures.utf8(body), tags = listOf("Work"),
            isEnabled = true, isPinned = true, createdAt = 0.0, updatedAt = 120.0,
        ),
    )

    @Test fun ordinaryConflictCopyMatchesIndependentSnapshotShaAndUuidV5() {
        val reference = fixture("merge-v1.json")
        val loser = record(10, "Fictional lost body 🦀\n")
        val winner = record(11, "Winning fictional body")
        val snapshot = CanonicalJson.encodeToString(JsonValue.Object(ConflictCopies.contentConflictSnapshot(loser)))
        assertEquals(reference.text("snapshotCanonical"), snapshot)
        assertEquals(reference.text("fingerprint"), ConflictCopies.contentConflictFingerprint(loser))

        val outcome = EnvelopeMerge.merge(null, loser, winner)
        assertTrue(MergeFixtures.sameBytes(outcome, EnvelopeMerge.merge(null, winner, loser)))
        val copy = outcome.conflictCopies.single()
        assertEquals(reference.text("copyID"), Uuids.lowercase(copy.id))
        assertEquals(reference.text("fingerprint"), ConflictCopies.conflictCopyProvenance(copy)?.fingerprint)
        assertTrue(ConflictCopies.hasValidConflictCopyIdentity(copy))
        assertTrue(ConflictCopies.isMatchingPlainConflictCopy(copy, copy))
        val f = copy.fields!!
        assertContentEquals(loser.fields!!.content, f.content)
        assertEquals("Public losing fixture (conflict 2001-01-01 00:02 UTC)", f.name)
        assertTrue(f.keyword.isEmpty() && !f.isEnabled && !f.isPinned)
        assertEquals(listOf("Work", "conflict"), f.tags)
        assertTrue(MergeFixtures.sameBytes(outcome, EnvelopeMerge.merge(null, loser, winner)))
        val survivor = outcome.survivor!!
        assertTrue(EnvelopeMerge.merge(survivor, survivor, survivor).conflictCopies.isEmpty())
    }

    @Test fun deletionFingerprintMatchesTheLinuxFixture() {
        val reference = fixture("merge-v1.json")
        val ids = reference.getValue("deletionIDs").jsonArray.map { UUID.fromString(it.jsonPrimitive.content) }.toSet()
        assertEquals(reference.text("deletionFingerprint"), DeletionSafety.fingerprint(ids))
    }

    private fun vectors() = fixture("conflict-copy-v1.json").getValue("vectors").jsonArray.map { it.jsonObject }

    /** Rust `canonical_conflict_copies_match_the_cross_client_vectors` and Swift `plainCopiesReproduceTheLinuxBytesExactly`. */
    @Test fun plainCopiesReproduceTheLinuxBytesExactly() {
        val vectors = vectors()
        assertEquals(2, vectors.size)
        for (vector in vectors) {
            val source = MergeFixtures.parse(vector.text("source"))
            val expected = MergeFixtures.parse(vector.text("copy"))
            val copy = ConflictCopies.makePlainContentConflictCopy(source)
            assertContentEquals(expected.canonicalBytes(), copy.canonicalBytes(), vector.text("name"))
            assertEquals(vector.text("copy"), MergeFixtures.canonical(copy), "the fixture's own bytes")
            assertEquals(vector.text("copyID"), Uuids.lowercase(copy.id))
            val provenance = ConflictCopies.conflictCopyProvenance(copy)!!
            assertEquals(vector.text("fingerprint"), provenance.fingerprint)
            assertTrue(ConflictCopies.hasValidConflictCopyIdentity(copy))
            assertEquals(copy.id, ConflictCopies.copyId(source.id, provenance.fingerprint))
            val f = copy.fields!!
            assertTrue(!f.isEnabled && !f.isPinned && f.keyword.isEmpty())
            assertContentEquals(source.fields!!.content, f.content)
            assertEquals("race (conflict 2026-10-03 17:43 UTC)", f.name)
        }
    }

    @Test fun theEnvelopeMergeMintsTheSameCopyFromEitherSide() {
        val vector = vectors().first()
        val loser = MergeFixtures.parse(vector.text("source"))
        val snippet = loser.plainSnippet!!
        val winner = SyncEnvelope.plain(
            snippet.copy(content = "a newer concurrent body"), Hlc.of(loser.hlc.wallMs + 1_000, 0, "0a0b0c0d"), "0a0b0c0d",
        )
        val ancestor = SyncEnvelope.plain(snippet.copy(content = "the common ancestor"), Hlc.of(1, 0, "0a0b0c0d"), "0a0b0c0d")
        val asLocal = EnvelopeMerge.merge(ancestor, loser, winner)
        val asRemote = EnvelopeMerge.merge(ancestor, winner, loser)
        assertEquals(listOf(UUID.fromString(vector.text("copyID"))), asLocal.conflictCopies.map { it.id })
        assertEquals(asLocal.conflictCopies.map(MergeFixtures::canonical), asRemote.conflictCopies.map(MergeFixtures::canonical))
    }
}
