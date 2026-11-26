package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.merge.MergeFixtures.canonical
import com.khm.snippets.core.merge.MergeFixtures.parse
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.wire.SyncEnvelope
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The vectors the Swift merge emitted (`tools/swift-interop`): `L07-merge.json`, every
 * case, and `V13-secure-conflict.json`. Each Kotlin result is compared byte for byte with
 * what `SyncMerge`, `DeletionGuard` and `SyncDeletionSafety` produced.
 */
class SwiftMergeVectorsTest {

    private val l07 = SwiftVectors.cases("L07-merge")
    private val v13 = SwiftVectors.cases("V13-secure-conflict")

    private fun envelope(case: SwiftVectors.Case, key: String): SyncEnvelope? = case.stringOrNull(key)?.let(::parse)

    private fun failureName(failure: Throwable): String = when (failure) {
        is MergeFailure.MalformedContentConflict -> "SyncMerge.EnvelopeFailure.malformedContentConflict"
        is MergeFailure.UnresolvedContentConflictDeletion -> "SyncMerge.EnvelopeFailure.unresolvedContentConflictDeletion"
        else -> failure.javaClass.name
    }

    private fun snippet(case: SwiftVectors.Case): Snippet = Snippet(
        id = UUID.fromString(case.string("id")),
        name = case.string("name"),
        keyword = case.string("keyword"),
        content = String(case.bytes("contentUtf8Hex"), Charsets.UTF_8),
        tags = case.strings("tags"),
        isEnabled = case.boolean("isEnabled"),
        isPinned = case.boolean("isPinned"),
        createdAt = case.double("createdAt"),
        updatedAt = case.double("updatedAt"),
    )

    /** Every field, bit for bit: `Snippet.equals` would let `é` pass for `e` + U+0301. */
    private fun assertSameSnippets(expected: List<SwiftVectors.Case>, actual: List<Snippet>, label: String) {
        assertEquals(expected.size, actual.size, "$label: count")
        for (index in expected.indices) {
            val want = snippet(expected[index])
            val got = actual[index]
            val at = "$label[$index]"
            assertEquals(want.id, got.id, "$at id")
            assertEquals(want.name, got.name, "$at name")
            assertEquals(want.keyword, got.keyword, "$at keyword")
            assertEquals(want.content, got.content, "$at content")
            assertEquals(want.tags, got.tags, "$at tags")
            assertEquals(want.isEnabled, got.isEnabled, "$at isEnabled")
            assertEquals(want.isPinned, got.isPinned, "$at isPinned")
            assertEquals(want.createdAt.toRawBits(), got.createdAt.toRawBits(), "$at createdAt")
            assertEquals(want.updatedAt.toRawBits(), got.updatedAt.toRawBits(), "$at updatedAt")
        }
    }

    // L07

    @Test fun everyL07CaseIsOfAKindThisSuiteChecks() {
        val known = setOf(
            "merge-envelope", "conflict-copy", "mergeScalar", "mergeTags", "merge-local", "payloadDigest",
            "allowedDeletions", "evaluate", "evaluate-ids", "deletionFingerprint",
        )
        assertEquals(147, l07.size, "L07 case count")
        assertEquals(emptySet(), l07.map { it.kind }.toSet() - known, "unchecked kinds")
    }

    @Test fun threeWayMergeOutcomesMatchSwiftForEveryTriple() {
        val cases = l07.filter { it.kind == "merge-envelope" }
        assertEquals(44, cases.size)
        for (case in cases) {
            val base = envelope(case, "base")
            val local = envelope(case, "local")
            val remote = envelope(case, "remote")
            if (case.has("error")) {
                val failure = assertFailsWith<MergeFailure>(case.label) { EnvelopeMerge.merge(base, local, remote) }
                assertEquals(case.string("error"), failureName(failure), case.label)
                continue
            }
            val outcome = EnvelopeMerge.merge(base, local, remote)
            assertEquals(case.stringOrNull("survivor"), outcome.survivor?.let(::canonical), "${case.label}: survivor")
            assertEquals(case.stringOrNull("survivorHash"), outcome.survivor?.envelopeHash(), "${case.label}: survivor hash")
            assertEquals(
                case.array("conflictCopies").map { it.jsonPrimitive.content },
                outcome.conflictCopies.map(::canonical),
                "${case.label}: conflict copies",
            )
            val mirrored = EnvelopeMerge.merge(base, remote, local)
            assertEquals(
                case.boolean("mirroredGivesSameResult"), MergeFixtures.sameOutcome(outcome, mirrored),
                "${case.label}: mirrored",
            )
            // Stronger than Swift's `==`: for these inputs the mirrored bytes agree too.
            assertTrue(MergeFixtures.sameBytes(outcome, mirrored), "${case.label}: mirrored bytes")
        }
    }

    @Test fun plainConflictCopiesMatchSwiftByteForByte() {
        val cases = l07.filter { it.kind == "conflict-copy" }
        assertEquals(8, cases.size)
        for (case in cases) {
            val source = parse(case.string("source"))
            val copy = ConflictCopies.makePlainContentConflictCopy(source)
            assertEquals(case.string("copy"), canonical(copy), case.label)
            assertEquals(case.string("copyID"), Uuids.lowercase(copy.id), case.label)
            assertEquals(case.string("fingerprint"), ConflictCopies.conflictCopyProvenance(copy)?.fingerprint, case.label)
            assertEquals(case.string("fingerprint"), ConflictCopies.contentConflictFingerprint(source), case.label)
            assertEquals(case.string("copyName"), copy.fields?.name, case.label)
            assertTrue(ConflictCopies.hasValidConflictCopyIdentity(copy), case.label)
            assertTrue(ConflictCopies.isMatchingPlainConflictCopy(copy, candidate = copy), case.label)
        }
    }

    @Test fun mergeScalarMatchesSwift() {
        val cases = l07.filter { it.kind == "mergeScalar" }
        assertEquals(9, cases.size)
        for (case in cases) {
            val merged = FieldMerge.mergeScalar(
                case.stringOrNull("base"), case.string("local"), case.string("remote"), case.boolean("localWins"),
            )
            assertEquals(case.string("merged"), merged, case.label)
        }
    }

    @Test fun mergeTagsMatchesSwift() {
        val cases = l07.filter { it.kind == "mergeTags" }
        assertEquals(24, cases.size)
        for (case in cases) {
            val base = if (case.isNull("base")) null else case.strings("base")
            val merged = FieldMerge.mergeTags(base, case.strings("local"), case.strings("remote"), case.boolean("localWins"))
            assertEquals(case.strings("merged"), merged, case.label)
        }
    }

    @Test fun theLocalFileMergeMatchesSwift() {
        val cases = l07.filter { it.kind == "merge-local" }
        assertEquals(11, cases.size)
        for (case in cases) {
            val outcome = LocalMerge.mergeLocal(
                base = case.objects("base").map(::snippet),
                local = case.objects("local").map(::snippet),
                remote = case.objects("remote").map(::snippet),
            )
            assertSameSnippets(case.objects("snippets"), outcome.snippets, "${case.label} snippets")
            assertSameSnippets(case.objects("conflictCopies"), outcome.conflictCopies, "${case.label} copies")
            assertEquals(
                case.strings("disabledByKeywordCollision"), outcome.disabledByKeywordCollision.map(Uuids::lowercase),
                case.label,
            )
            assertEquals(case.boolean("needsUserAttention"), outcome.needsUserAttention, case.label)
        }
    }

    @Test fun payloadDigestMatchesSwift() {
        val cases = l07.filter { it.kind == "payloadDigest" }
        assertEquals(6, cases.size)
        for (case in cases) assertEquals(case.string("digest"), LocalMerge.payloadDigest(snippet(case.obj("snippet"))), case.label)
    }

    @Test fun allowedDeletionsAndItsBoundaryMatchSwift() {
        val cases = l07.filter { it.kind == "allowedDeletions" }
        assertEquals(24, cases.size)
        for (case in cases) {
            val live = case.int("liveCount")
            val allowed = DeletionGuard.allowedDeletions(live)
            assertEquals(case.int("allowedDeletions"), allowed, case.label)
            assertEquals(allowed, DeletionSafety.allowedDeletions(live), case.label)
            assertEquals(case.string("atLimit"), DeletionGuard.evaluate(live, allowed).isAllowed.toString(), case.label)
            assertEquals(case.string("oneOverLimit"), DeletionGuard.evaluate(live, allowed + 1).isAllowed.toString(), case.label)
        }
    }

    @Test fun deletionGuardDecisionsMatchSwift() {
        val cases = l07.filter { it.kind == "evaluate" }
        assertEquals(13, cases.size)
        for (case in cases) {
            val decision = DeletionGuard.evaluate(liveCount = case.int("liveCount"), deletions = case.int("deletions"))
            assertEquals(case.boolean("allowed"), decision.isAllowed, case.label)
            if (case.isNull("refusal")) {
                assertNull(decision.refusalOrNull, case.label)
                continue
            }
            val expected = case.obj("refusal")
            val refusal = assertNotNull(decision.refusalOrNull, case.label)
            assertEquals(expected.int("liveCount"), refusal.liveCount, case.label)
            assertEquals(expected.int("requestedDeletions"), refusal.requestedDeletions, case.label)
            assertEquals(expected.int("allowedDeletions"), refusal.allowedDeletions, case.label)
            assertEquals(expected.double("requestedFraction").toRawBits(), refusal.requestedFraction.toRawBits(), case.label)
            assertEquals(expected.string("description"), refusal.description, case.label)
        }
    }

    @Test fun deletionGuardDecisionsFromIdsMatchSwift() {
        val cases = l07.filter { it.kind == "evaluate-ids" }
        assertEquals(5, cases.size)
        for (case in cases) {
            val live = case.strings("live").map(UUID::fromString).toSet()
            val deleting = case.strings("deleting").map(UUID::fromString)
            assertEquals(case.boolean("allowed"), DeletionGuard.evaluate(live, deleting).isAllowed, case.label)

            val resulting = live - deleting.toSet()
            val facts = DeletionSafety.facts(live, resulting)
            if (case.isNull("facts")) {
                assertNull(facts, case.label)
            } else {
                val expected = case.obj("facts")
                assertEquals(
                    DeletionSafety.Review(
                        liveCount = expected.int("liveCount"),
                        requestedDeletions = expected.int("requestedDeletions"),
                        batchFingerprint = expected.string("batchFingerprint"),
                    ),
                    facts, case.label,
                )
            }
            assertEquals(case.boolean("reviewRequired"), DeletionSafety.review(live, resulting) != null, case.label)
        }
    }

    @Test fun deletionFingerprintsMatchSwift() {
        val cases = l07.filter { it.kind == "deletionFingerprint" }
        assertEquals(3, cases.size)
        for (case in cases) {
            val ids = case.strings("ids").map(UUID::fromString).toSet()
            assertEquals(case.string("fingerprint"), DeletionSafety.fingerprint(ids), case.label)
            assertEquals(
                case.string("fingerprint"),
                SyncEnvelope.sha256Hex(case.string("preimageText").toByteArray(Charsets.UTF_8)),
                "${case.label}: the vector's own preimage",
            )
        }
    }

    // V13

    private fun envelopeObject(case: SwiftVectors.Case, key: String): SyncEnvelope =
        SyncEnvelope.parse(case.obj(key).bytes("canonicalHex"))

    @Test fun everyV13CaseIsOfAKindThisSuiteChecks() {
        assertEquals(7, v13.size, "V13 case count")
        assertEquals(setOf("secure-conflict", "deterministic-uuid"), v13.map { it.kind }.toSet())
    }

    @Test fun secureConflictVariantsMatchSwiftByteForByte() {
        val cases = v13.filter { it.kind == "secure-conflict" }
        assertEquals(2, cases.size)
        for (case in cases) {
            val base = envelopeObject(case, "base")
            val local = envelopeObject(case, "local")
            val remote = envelopeObject(case, "remote")
            val loser = when (case.string("loser")) {
                "local" -> local
                "remote" -> remote
                else -> fail("${case.label}: unknown loser")
            }
            val expectedSurvivor = case.obj("survivor")
            val expected = case.obj("variant")

            // The merge: the loser becomes one member of the survivor's `x`, no record.
            val outcome = EnvelopeMerge.merge(base, local, remote)
            val survivor = assertNotNull(outcome.survivor, case.label)
            assertTrue(outcome.conflictCopies.isEmpty(), case.label)
            assertEquals(expectedSurvivor.string("canonicalHex"), MergeFixtures.hex(survivor.canonicalBytes()), "${case.label}: survivor")
            assertEquals(expectedSurvivor.string("envelopeHash"), survivor.envelopeHash(), "${case.label}: survivor hash")
            assertTrue(MergeFixtures.sameBytes(outcome, EnvelopeMerge.merge(base, remote, local)), "${case.label}: mirrored")

            // Key and value.
            val (key, value) = ConflictCopies.makeSecureContentConflictVariant(loser)
            assertEquals(expected.string("extensionKey"), key, case.label)
            assertEquals(expected.string("valueCanonical"), canonical(value), case.label)
            assertEquals(expected.string("valueCanonical"), canonical(assertNotNull(survivor.x[key])), case.label)

            // Fingerprint: the value without `copyID`.
            val fingerprint = expected.string("fingerprint")
            assertEquals(fingerprint, ConflictCopies.contentConflictFingerprint(loser), case.label)
            val withoutCopyId = LinkedHashMap(assertNotNull(value.objectOrNull))
            withoutCopyId.remove("copyID")
            val preimage = CanonicalJson.encode(JsonValue.Object(withoutCopyId))
            assertEquals(expected.string("fingerprintPreimageHex"), MergeFixtures.hex(preimage), case.label)
            assertEquals(fingerprint, SyncEnvelope.sha256Hex(preimage), case.label)

            // Copy id.
            val copyId = UUID.fromString(expected.string("copyID"))
            assertEquals(Uuids.lowercase(loser.id), expected.string("copyIDNamespace"), case.label)
            assertEquals("sync-content-conflict-v1|$fingerprint", expected.string("copyIDName"), case.label)
            assertEquals(copyId, ConflictCopies.copyId(loser.id, fingerprint), case.label)
            assertEquals(
                copyId,
                ConflictCopies.deterministicUuid(UUID.fromString(expected.string("copyIDNamespace")), expected.string("copyIDName")),
                case.label,
            )

            // Read back.
            val variant = ConflictCopies.secureContentConflictVariants(survivor).single()
            assertEquals(key, variant.extensionKey, case.label)
            assertEquals(fingerprint, variant.fingerprint, case.label)
            assertEquals(copyId, variant.copyId, case.label)
            assertEquals(loser.id, variant.sourceId, case.label)
            assertEquals(loser.hlc, variant.sourceHlc, case.label)
            assertEquals(loser.origin, variant.sourceOrigin, case.label)
            assertEquals(loser.fields, variant.fields, case.label)
            assertEquals(case.string("kid"), variant.vaultKeyId, case.label)
            assertEquals(loser.x[SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY]?.textOrNull, variant.vaultContentHash, case.label)
            assertTrue(ConflictCopies.hasUnresolvedContentConflict(survivor), case.label)

            // What the materializer will write, as far as the merge layer defines it:
            // the name's stamp and the provenance.
            val materialized = case.obj("materializedCopy")
            val storedName = variant.fields.name
            assertEquals(
                materialized.string("name"),
                ConflictCopies.conflictName(if (storedName.isEmpty()) "Untitled" else storedName, variant.fields.updatedAt),
                case.label,
            )
            assertEquals(materialized.string("id"), Uuids.lowercase(variant.copyId), case.label)
            assertEquals(materialized.string("hlc"), variant.sourceHlc.string, case.label)
            val provenance = assertNotNull(ConflictCopies.conflictCopyProvenance(loser.id, fingerprint).objectOrNull)
            assertEquals(fingerprint, provenance["fingerprint"]?.textOrNull, case.label)
            assertEquals(Uuids.lowercase(loser.id), provenance["sourceID"]?.textOrNull, case.label)
            assertEquals(1L, provenance["version"]?.longOrNull, case.label)

            // The vault carrier of the member.
            assertEquals("contentConflictOpaque.v1.v1.$fingerprint", ConflictCopies.opaqueCarrierKey(key), case.label)
        }
    }

    @Test fun deterministicUuidsMatchSwift() {
        val cases = v13.filter { it.kind == "deterministic-uuid" }
        assertEquals(5, cases.size)
        for (case in cases) {
            assertEquals(
                case.string("uuid"),
                Uuids.lowercase(ConflictCopies.deterministicUuid(UUID.fromString(case.string("namespace")), case.text("uuidName"))),
                case.label,
            )
        }
    }
}
