package com.khm.snippets.core.merge

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.wire.SyncEnvelope
import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Properties of the merge over thousands of generated triples ([MergeGenerator]), each
 * stated as Swift has it. Where a property one might expect does not hold, the test pins
 * what does hold, and `MergeDifferentialTest` shows that the shipping Swift merge gives
 * the same answers for the same derived triples:
 *
 * - **Mirror.** Swapping local and remote gives an outcome equal as Swift compares
 *   envelopes, the same failure, and conflict copies byte for byte. The survivor's bytes
 *   are equal too, except where the two sides spell one value differently: a text or an
 *   `x` key in another normalization form (where both agree, the local spelling is kept)
 *   and `0.0` against `-0.0` (Swift's `min` keeps its first argument, `max` its second).
 * - **Itself.** Merging an outcome with itself changes nothing but `schemaVersion`, which
 *   a live result always gets as 1, and the vault members a pass-through survivor
 *   (one side absent) carried on an ordinary record, which the rebuild drops.
 * - **Against the side it came from.** `merge(remote, survivor, remote)` is the survivor
 *   only up to tag order (the ancestor's order wins; `FieldMerge.mergeTags`), an exact
 *   clock tie (the rank may pick the other origin and `x` values), a zero's sign, a
 *   vault member backfilled from the remote, and the rebuild of [selfMerged]. This is the step that keeps two devices rewriting a record.
 * - **Copies** are a function of the losing version alone.
 * - **Nothing is lost**, nearly. Every changed body survives, as the survivor's, a copy's
 *   or a variant's, except that the plain copy of a body starting with U+FEFF holds it
 *   without that one U+FEFF (Swift builds the copy from `String(data:encoding:)`, which
 *   drops it). An edit beats a delete.
 * - **Failures** are only [MergeFailure]s; every output validates and fits the budget.
 */
class MergeAlgebraTest {

    private val triples = 5_000

    private inline fun forEachTriple(seed: Long, count: Int = triples, body: (Int, SyncEnvelope?, SyncEnvelope?, SyncEnvelope?) -> Unit) {
        val generator = MergeGenerator(seed)
        repeat(count) { index ->
            val (base, local, remote) = generator.triple()
            body(index, base, local, remote)
        }
    }

    private fun attempt(base: SyncEnvelope?, local: SyncEnvelope?, remote: SyncEnvelope?): Result<EnvelopeMerge.Outcome> =
        runCatching { EnvelopeMerge.merge(base, local, remote) }

    private fun bytes(envelope: SyncEnvelope?): String? = envelope?.let(MergeFixtures::canonical)

    /** Swift's `contentKey`, restated so the properties do not trust the code under test. */
    private fun contentKey(envelope: SyncEnvelope): String? {
        val fields = envelope.fields ?: return null
        if (envelope.secure) {
            val keyed = SwiftSemantics.get(envelope.x, SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY)?.textOrNull
            if (keyed != null) {
                val vault = SwiftSemantics.get(envelope.x, SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY)?.textOrNull ?: "legacy"
                return "secure:$vault:$keyed"
            }
        }
        val digest = SyncEnvelope.sha256Hex(fields.content)
        return if (envelope.secure) "secure:legacy:$digest" else "plain:$digest"
    }

    private fun texts(envelope: SyncEnvelope?): List<String> {
        if (envelope == null) return emptyList()
        val f = envelope.fields
        return listOfNotNull(f?.name, f?.keyword, envelope.origin) + (f?.tags ?: emptyList()) + envelope.x.keys
    }

    private fun spellsSomethingUnnormalized(vararg envelopes: SyncEnvelope?): Boolean =
        envelopes.any { e -> texts(e).any { FoundationText.nfc(it) != it } }

    private fun hasSignedZero(vararg envelopes: SyncEnvelope?): Boolean = envelopes.any { e ->
        val f = e?.fields
        f != null && (f.createdAt.toRawBits() == (-0.0).toRawBits() || f.updatedAt.toRawBits() == (-0.0).toRawBits())
    }

    @Test fun onlyDeclaredFailuresEscapeAndEveryOutputValidatesAndFitsTheBudget() {
        val failures = HashMap<String, Int>()
        var copies = 0
        var variants = 0
        forEachTriple(seed = 1) { index, base, local, remote ->
            val outcome = attempt(base, local, remote).getOrElse { failure ->
                if (failure !is MergeFailure || failure is MergeFailure.MismatchedIdentity) fail("triple $index: $failure")
                failures.merge(failure.javaClass.simpleName, 1, Int::plus)
                return@forEachTriple
            }
            val id = (local ?: remote)?.id
            outcome.survivor?.let { survivor ->
                assertEquals(id, survivor.id, "triple $index")
                variants += ConflictCopies.secureContentConflictVariants(survivor).size
            }
            for (envelope in listOfNotNull(outcome.survivor) + outcome.conflictCopies) {
                ConflictCopies.validateContentConflictExtensions(envelope)
                val canonical = envelope.canonicalBytes()
                assertTrue(canonical.size <= EnvelopeMerge.MAXIMUM_WIRE_CANONICAL_BYTES, "triple $index over budget")
                assertContentEquals(canonical, MergeFixtures.reparsed(envelope).canonicalBytes(), "triple $index reparses")
            }
            for (copy in outcome.conflictCopies) {
                copies += 1
                assertTrue(ConflictCopies.hasValidConflictCopyIdentity(copy))
                val f = copy.fields!!
                assertTrue(!copy.secure && !f.isEnabled && !f.isPinned && f.keyword.isEmpty(), "triple $index")
                assertTrue(f.tags.any { SnippetTagging.filterKey(it) == SnippetTagging.filterKey("conflict") }, "triple $index")
            }
            assertEquals(outcome.conflictCopies.sortedWith { a, b -> ConflictCopies.idOrder.compare(a.id, b.id) }, outcome.conflictCopies)
        }
        // The generator reaches every way a merge can end.
        for (kind in listOf("MalformedContentConflict", "UnresolvedContentConflictDeletion", "UnrepresentableConflictDate")) {
            assertTrue((failures[kind] ?: 0) > 0, "no $kind in $failures")
        }
        assertTrue(copies > 100, "only $copies copies")
        assertTrue(variants > 100, "only $variants variants")
    }

    @Test fun mirroredInputsGiveTheSameAnswerAsSwiftComparesItAndTheSameBytesWithoutSpellingCorners() {
        var identicalBytes = 0
        var cornerOnly = 0
        forEachTriple(seed = 2) { index, base, local, remote ->
            val forward = attempt(base, local, remote)
            val reverse = attempt(base, remote, local)
            assertEquals(forward.exceptionOrNull()?.javaClass, reverse.exceptionOrNull()?.javaClass, "triple $index failure")
            val a = forward.getOrNull() ?: return@forEachTriple
            val b = reverse.getOrThrow()
            assertEquals(a, b, "triple $index: Swift's == must hold for the mirror")
            assertEquals(a.conflictCopies.map(::bytes), b.conflictCopies.map(::bytes), "triple $index copies")
            if (bytes(a.survivor) == bytes(b.survivor)) {
                identicalBytes += 1
            } else {
                assertTrue(
                    spellsSomethingUnnormalized(local, remote) || hasSignedZero(local, remote),
                    "triple $index: mirrored bytes differ without a spelling corner",
                )
                cornerOnly += 1
            }
        }
        assertTrue(identicalBytes > triples / 2, "$identicalBytes")
        assertTrue(cornerOnly > 0, "the generator reaches the spelling corners")
    }

    /**
     * What merging [envelope] with itself gives: a tombstone stays as it is; a live
     * envelope is rebuilt, so it gets `schemaVersion` 1 and, when ordinary, loses any
     * vault member a pass-through left on it.
     */
    private fun selfMerged(envelope: SyncEnvelope): SyncEnvelope {
        if (envelope.deleted) return envelope
        val x = LinkedHashMap(envelope.x)
        if (!envelope.secure) {
            SwiftSemantics.set(x, SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY, null)
            SwiftSemantics.set(x, SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY, null)
        }
        return envelope.copy(schemaVersion = SyncEnvelope.CURRENT_SCHEMA_VERSION, x = x)
    }

    @Test fun mergingAnOutcomeWithItselfChangesNothingButTheSchemaVersionAndStaleRouting() {
        forEachTriple(seed = 3) { index, base, local, remote ->
            val survivor = attempt(base, local, remote).getOrNull()?.survivor ?: return@forEachTriple
            val expected = selfMerged(survivor)
            val again = EnvelopeMerge.merge(survivor, survivor, survivor)
            assertEquals(bytes(expected), bytes(again.survivor), "triple $index")
            assertTrue(again.conflictCopies.isEmpty(), "triple $index")
            // The ancestor does not matter when both sides agree, unless it blocks a deletion.
            val withBase = attempt(base, survivor, survivor)
            if (survivor.deleted && ConflictCopies.hasUnresolvedContentConflict(base)) {
                assertTrue(withBase.exceptionOrNull() is MergeFailure.UnresolvedContentConflictDeletion, "triple $index")
            } else {
                assertEquals(bytes(expected), bytes(withBase.getOrThrow().survivor), "triple $index")
            }
        }
    }

    @Test fun mergingTheOutcomeOverTheSideItCameFromHoldsOnlyUpToTagOrderAndClockTies() {
        var same = 0
        var tagOrderOnly = 0
        forEachTriple(seed = 4) { index, base, local, remote ->
            if (remote == null || local == null) return@forEachTriple
            val survivor = attempt(base, local, remote).getOrNull()?.survivor ?: return@forEachTriple
            val again = attempt(remote, survivor, remote).getOrNull() ?: return@forEachTriple
            assertTrue(again.conflictCopies.isEmpty(), "triple $index: no second copy")
            val result = again.survivor!!
            if (bytes(result) == bytes(survivor)) {
                same += 1
                return@forEachTriple
            }
            val tagsDiffer = result.fields?.tags != survivor.fields?.tags
            if (tagsDiffer) {
                assertEquals(survivor.fields!!.tags.sorted(), result.fields!!.tags.sorted(), "triple $index: only the order may change")
                if (survivor.hlc != remote.hlc) tagOrderOnly += 1
            }
            // A secure survivor without a vault member takes the remote's when the fields are
            // equal (Swift's legacy backfill).
            val backfilled = survivor.secure && listOf(SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY, SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY)
                .any { SwiftSemantics.get(survivor.x, it) == null && SwiftSemantics.get(remote.x, it) != null }
            val explained = tagsDiffer || survivor.hlc == remote.hlc || hasSignedZero(survivor, remote) || backfilled ||
                bytes(selfMerged(survivor)) != bytes(survivor) || spellsSomethingUnnormalized(survivor, remote)
            assertTrue(explained, "triple $index: unexplained difference")
        }
        assertTrue(same > 0)
        assertTrue(tagOrderOnly > 0, "the generator reaches the tag-order case")
    }

    @Test fun conflictCopiesAreAFunctionOfTheLosingVersionAlone() {
        forEachTriple(seed = 5) { index, base, local, remote ->
            val outcome = attempt(base, local, remote).getOrNull() ?: return@forEachTriple
            for (copy in outcome.conflictCopies) {
                val candidates = listOfNotNull(local, remote).filter { !it.deleted && !it.secure }
                val loser = candidates.firstOrNull { runCatching { bytes(ConflictCopies.makePlainContentConflictCopy(it)) }.getOrNull() == bytes(copy) }
                val source = assertNotNull(loser, "triple $index: the copy is not the copy of either side")
                assertEquals(ConflictCopies.copyId(source.id, ConflictCopies.contentConflictFingerprint(source)), copy.id)
                assertEquals(bytes(copy), bytes(EnvelopeMerge.merge(base, local, remote).conflictCopies.single()), "repeatable")
            }
        }
    }

    @Test fun noChangedBodyIsLostButALeadingByteOrderMarkAndAnEditBeatsADelete() {
        var bomCopies = 0
        forEachTriple(seed = 6) { index, base, local, remote ->
            val outcome = attempt(base, local, remote).getOrNull() ?: return@forEachTriple
            val survivor = outcome.survivor
            val keys = HashSet<String>()
            survivor?.let { s ->
                contentKey(s)?.let(keys::add)
                for (variant in ConflictCopies.secureContentConflictVariants(s)) {
                    contentKey(SyncEnvelope(variant.sourceId, variant.sourceHlc, variant.sourceOrigin, true, false, variant.fields, variant.sourceExtensions))
                        ?.let(keys::add)
                }
            }
            outcome.conflictCopies.forEach { copy -> contentKey(copy)?.let(keys::add) }
            // Equal fields with different vault labels are one body: its bytes are kept, the
            // winner's labels with it.
            val bodies = (listOfNotNull(survivor?.fields) + outcome.conflictCopies.mapNotNull { it.fields } +
                (survivor?.let { ConflictCopies.secureContentConflictVariants(it) }?.map { it.fields } ?: emptyList()))
            val baseKey = base?.let(::contentKey)
            for (side in listOfNotNull(local, remote)) {
                if (side.deleted) continue
                val key = contentKey(side)!!
                if (key == baseKey) continue
                // An unchanged side's body may be dropped; a changed one never.
                if (base != null && base.envelopeHash() == side.envelopeHash()) continue
                if (key in keys || bodies.any { it.contentEquals(side.fields!!) }) continue
                // Except for one thing Swift does as well: the copy of an ordinary body is
                // made from its text, and `String(data:encoding:)` drops one leading U+FEFF.
                val content = side.fields!!.content
                val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
                assertTrue(!side.secure && content.size >= 3 && content.copyOf(3).contentEquals(bom), "triple $index lost a body")
                val stripped = content.copyOfRange(3, content.size)
                assertTrue(
                    outcome.conflictCopies.any { it.fields!!.contentEquals(stripped) },
                    "triple $index: the copy holds the body without its byte order mark",
                )
                bomCopies += 1
            }
            val (tombstone, live) = when {
                local?.deleted == true && remote?.deleted == false -> local to remote
                remote?.deleted == true && local?.deleted == false -> remote to local
                else -> return@forEachTriple
            }
            if (base == null || base.envelopeHash() != live.envelopeHash()) {
                assertEquals(bytes(live), bytes(survivor), "triple $index: the edit must survive the delete")
            } else {
                assertEquals(bytes(tombstone), bytes(survivor), "triple $index: an uncontested delete stays")
            }
        }
        assertTrue(bomCopies > 0, "the generator reaches a losing body with a byte order mark")
    }

    /** Swift does not compare the ids; Linux and this port refuse. */
    @Test fun inputsOfDifferentRecordsAreRefused() {
        var refused = 0
        forEachTriple(seed = 7, count = 1_000) { _, base, local, remote ->
            // Identities are compared as the inputs are validated (Linux's order): the last
            // input present is moved to another record, after every other one has passed.
            if (listOfNotNull(base, local, remote).size < 2 || attempt(base, local, remote).isFailure) return@forEachTriple
            val other = UUID.fromString("99999999-0000-4000-8000-000000000099")
            val failure = when {
                remote != null -> attempt(base, local, remote.copy(id = other))
                else -> attempt(base, local!!.copy(id = other), null)
            }.exceptionOrNull()
            assertTrue(failure is MergeFailure.MismatchedIdentity, "$failure")
            refused += 1
        }
        assertTrue(refused > 100)
    }

    @Test fun theLocalFileMergeIsDeterministicAFixedPointAndLosesNoChangedBody() {
        val generator = MergeGenerator(8)
        repeat(3_000) { index ->
            val case = generator.localCase()
            val first = runCatching { LocalMerge.mergeLocal(case.base, case.local, case.remote) }.getOrElse { failure ->
                assertTrue(failure is MergeFailure.UnrepresentableConflictDate, "case $index: $failure")
                return@repeat
            }
            val second = LocalMerge.mergeLocal(case.base, case.local, case.remote)
            assertEquals(first.snippets.map(::snippetBytes), second.snippets.map(::snippetBytes), "case $index")
            assertEquals(first.disabledByKeywordCollision, second.disabledByKeywordCollision)
            val again = LocalMerge.mergeLocal(first.snippets, first.snippets, first.snippets)
            assertEquals(first.snippets.map(::snippetBytes), again.snippets.map(::snippetBytes), "case $index: fixed point")
            assertFalse(again.needsUserAttention)
            val produced = first.snippets.map { it.content }
            fun firstById(list: List<Snippet>) = list.distinctBy { it.id }
            val baseById = firstById(case.base).associateBy { it.id }
            for (side in listOf(firstById(case.local), firstById(case.remote))) {
                for (snippet in side) {
                    val ancestor = baseById[snippet.id]
                    if (ancestor != null && FoundationText.canonicalEquals(ancestor.content, snippet.content)) continue
                    assertTrue(produced.any { FoundationText.canonicalEquals(it, snippet.content) }, "case $index lost a body")
                }
            }
        }
    }

    private fun snippetBytes(snippet: Snippet): String = MergeDifferential.snippetJson(snippet).toString()

    /** Swift throws here and the engine halts; a legacy unstamped secure body has no valid variant. */
    @Test fun aSecureLoserWithoutItsKeyedHashStopsTheMerge() {
        val generator = MergeGenerator(9)
        var stopped = 0
        repeat(3_000) { index ->
            val (_, local, remote) = generator.triple()
            if (local == null || remote == null || local.deleted || remote.deleted || !local.secure) return@repeat
            val stripped = local.withExtension(SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY, null)
            val newer = remote.copy(hlc = Hlc.of(maxOf(local.hlc.wallMs, remote.hlc.wallMs) + 1, 0, "bbbbbbb2"))
            if (stripped.fields == newer.fields && stripped.secure == newer.secure) return@repeat
            if (contentKey(stripped) == contentKey(newer)) return@repeat
            val failure = attempt(null, stripped, newer).exceptionOrNull()
            assertTrue(failure is MergeFailure.MalformedContentConflict, "triple $index: $failure")
            stopped += 1
        }
        assertTrue(stopped > 20, "$stopped")
    }
}
