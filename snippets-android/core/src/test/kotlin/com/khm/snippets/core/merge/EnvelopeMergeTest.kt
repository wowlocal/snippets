package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.merge.MergeFixtures.utf8
import com.khm.snippets.core.wire.SnippetCryptoSealer
import com.khm.snippets.core.wire.SyncEnvelope
import com.khm.snippets.core.wire.WireCodec
import com.khm.snippets.core.wire.WireIdentity
import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The cross-device merge, case by case.
 *
 * - `snippets-linux/src/merge_tests.rs`, every case but the two fixture ones (those are
 *   in `LinuxMergeFixturesTest`) and the deletion one (`DeletionSafetyTest`), under the
 *   Rust names in camel case. Like Rust's `checked_merge`, [checked] also demands that
 *   the mirrored merge gives the same bytes and that every output validates and reparses.
 * - The merge-level halves of `SyncConflictCopyTests`, `SyncConflictPayloadBudgetTests`,
 *   `SyncConflictOrderingTests` and `SyncRestoredConflictCopyTests`, under the Swift
 *   names. Their engine and projection halves belong to the journal and engine ports.
 */
class EnvelopeMergeTest {

    private val recordId = UUID.fromString("00000000-0000-4000-8000-000000000021")
    private fun foreign(wall: Long): Hlc = Hlc.of(wall, 0, Hlc.FOREIGN_DEVICE)
    private fun uuid128(value: Long): UUID = UUID(0, value)

    private fun record(wall: Long, body: String): SyncEnvelope = SyncEnvelope(
        id = recordId, hlc = Hlc.of(wall, 0, "aaaaaaa1"), origin = "aaaaaaa1", secure = false, deleted = false,
        fields = SyncEnvelope.Fields(
            name = "Public losing fixture", keyword = "fixture", content = utf8(body), tags = listOf("Work"),
            isEnabled = true, isPinned = true, createdAt = 0.0, updatedAt = 120.0,
        ),
    )

    private fun secure(wall: Long, body: String, hash: String, kid: String): SyncEnvelope = record(wall, body).copy(
        secure = true,
        x = linkedMapOf(
            SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY to JsonValue.Text(hash),
            SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY to JsonValue.Text(kid),
        ),
    )

    private fun SyncEnvelope.withFields(transform: (SyncEnvelope.Fields) -> SyncEnvelope.Fields): SyncEnvelope =
        SyncEnvelope(id, hlc, origin, secure, deleted, transform(fields!!), x, schemaVersion)

    private fun SyncEnvelope.with(key: String, value: JsonValue?): SyncEnvelope = withExtension(key, value)

    /** Rust's `tombstone(hlc, origin, true)`: the deletion carries the user's proof. */
    private fun SyncEnvelope.userDeletion(hlc: Hlc, origin: String): SyncEnvelope =
        tombstoned(hlc, origin).withExtension(
            SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY, JsonValue.array(JsonValue.Text(envelopeHash())),
        )

    private fun body(envelope: SyncEnvelope?): String? = envelope?.fields?.let { String(it.content, Charsets.UTF_8) }

    private fun merge(base: SyncEnvelope?, local: SyncEnvelope?, remote: SyncEnvelope?) = EnvelopeMerge.merge(base, local, remote)

    /** `checked_merge`: the mirrored peer gets the same bytes, and every output validates and reparses to itself. */
    private fun checked(base: SyncEnvelope?, local: SyncEnvelope, remote: SyncEnvelope): EnvelopeMerge.Outcome {
        val forward = merge(base, local, remote)
        val reverse = merge(base, remote, local)
        assertTrue(MergeFixtures.sameBytes(forward, reverse), "mirrored peers must preserve identical output")
        assertEquals(forward, reverse)
        for (envelope in listOfNotNull(forward.survivor) + forward.conflictCopies) {
            ConflictCopies.validateContentConflictExtensions(envelope)
            assertContentEquals(envelope.canonicalBytes(), MergeFixtures.reparsed(envelope).canonicalBytes())
        }
        return forward
    }

    private val keyring = SnippetCrypto.Keyring(ByteArray(32) { 0x11 }, ByteArray(32) { 0x22 })
    private fun context(scope: String, id: UUID) = SnippetCrypto.RecordContext(scopeId = scope, recordId = id)

    // snippets-linux/src/merge_tests.rs

    @Test fun independentMetadataAndBodyEditsCombineWithoutClockSkewLoss() {
        val base = record(1, "Original fictional text")
        val local = base.copy(hlc = foreign(1000)).withFields {
            it.copy(name = "Renamed on another device", isPinned = false, tags = listOf("WORK", "Local"), updatedAt = 200.0)
        }
        val remote = record(2, "Body edited independently").withFields {
            it.copy(keyword = "new-keyword", isEnabled = false, tags = listOf("Work", "Remote"), createdAt = -1.0)
        }
        val outcome = checked(base, local, remote)
        assertTrue(outcome.conflictCopies.isEmpty())
        val f = outcome.survivor!!.fields!!
        assertEquals("Renamed on another device", f.name)
        assertEquals("new-keyword", f.keyword)
        assertEquals("Body edited independently", String(f.content, Charsets.UTF_8))
        assertTrue(!f.isEnabled && !f.isPinned)
        assertEquals(listOf("WORK", "Local", "Remote"), f.tags)
        assertEquals(-1.0 to 200.0, f.createdAt to f.updatedAt)
    }

    @Test fun tagRemovalsWinAndNoAncestorKeepsPreferredHandOrder() {
        val base = record(1, "Same text").withFields { it.copy(tags = listOf("Work", "Discard", "Last")) }
        var local = record(2, "Same text").withFields { it.copy(tags = listOf("WORK", "Zulu", "Last")) }
        var remote = record(3, "Same text").withFields { it.copy(tags = listOf("Work", "Discard", "alpha")) }
        assertEquals(listOf("Work", "alpha", "Zulu"), checked(base, local, remote).survivor!!.fields!!.tags)
        remote = remote.withFields { it.copy(tags = listOf("Zulu", "Alpha")) }
        local = local.withFields { it.copy(tags = listOf("Extra", "Alpha")) }
        assertEquals(listOf("Zulu", "Alpha", "Extra"), checked(null, local, remote).survivor!!.fields!!.tags)
    }

    @Test fun absenceNeverDeletesAndExplicitDeleteYieldsToARealEdit() {
        val base = record(1, "Original")
        assertEquals(base, merge(base, null, base).survivor)
        assertEquals(base, merge(base, base, null).survivor)
        assertNull(merge(base, null, null).survivor)
        val delete = base.userDeletion(foreign(100), "bbbbbbb2")
        assertTrue(checked(base, delete, base).survivor!!.deleted)
        val edited = record(2, "Edited while deletion happened")
        assertEquals(edited, checked(base, delete, edited).survivor)
        assertEquals(base, checked(null, delete, base).survivor)
        val otherDelete = delete.copy(hlc = foreign(200))
        assertEquals(otherDelete, checked(base, delete, otherDelete).survivor)
    }

    @Test fun generatedCopyKeepsUnknownExtensionsButNeverNestedConflictCarriers() {
        val future = "contentConflict.v2.${"a".repeat(64)}"
        val loser = record(2, "Plain body")
            .with("futureMetadata", JsonValue.Text("Public future value"))
            .with("vaultKID", JsonValue.Text("obsolete-vault"))
            .with("vaultContentHash", JsonValue.Text("obsolete-hash"))
            .with(future, JsonValue.Integer(99))
        val outcome = checked(null, loser, record(3, "Other body"))
        val copy = outcome.conflictCopies.single()
        assertTrue("futureMetadata" in copy.x)
        assertFalse(future in copy.x)
        assertFalse("vaultKID" in copy.x)
        assertFalse("vaultContentHash" in copy.x)
        assertTrue(future in outcome.survivor!!.x)
    }

    @Test fun copyDisplayNameHandlesBlankLinesAndExtendedGraphemes() {
        val family = "👨‍👩‍👧‍👦"
        val loser = record(1, "\n \r\n ${family.repeat(51)}!\n").withFields { it.copy(name = "  ", updatedAt = -60.0) }
        val copy = ConflictCopies.makePlainContentConflictCopy(loser)
        assertEquals("${family.repeat(50)}… (conflict 2000-12-31 23:59 UTC)", copy.fields!!.name)
    }

    @Test fun secureSelectedBodyKeepsItsOwnKeyAndHashDespiteNewerMetadataClock() {
        val base = secure(1, "Fictional original seal", "same-original-hash", "vault-original")
        val metadata = base.copy(hlc = foreign(1000)).withFields { it.copy(name = "Renamed securely") }
        val edited = secure(2, "Fictional changed seal", "edited-hash", "vault-edited")
        val outcome = checked(base, metadata, edited)
        assertTrue(outcome.conflictCopies.isEmpty())
        val survivor = outcome.survivor!!
        assertEquals("Renamed securely", survivor.fields!!.name)
        assertEquals("Fictional changed seal", body(survivor))
        assertEquals("vault-edited", survivor.x["vaultKID"]?.textOrNull)
        assertEquals("edited-hash", survivor.x["vaultContentHash"]?.textOrNull)
    }

    @Test fun freshSecureNonceIsNotAnEditAndADifferentVaultIsAConflict() {
        val plaintext = utf8("Fictional public secret")
        val first = SnippetCrypto.seal(plaintext, context("fixture-vault", recordId), keyring)
        val second = SnippetCrypto.seal(plaintext, context("fixture-vault", recordId), keyring)
        assertNotEquals(first, second)
        val hash = SnippetCrypto.contentHash(plaintext, keyring)
        val a = secure(2, first, hash, "fixture-vault")
        val b = secure(3, second, hash, "fixture-vault")
        val outcome = checked(null, a, b)
        assertTrue(outcome.conflictCopies.isEmpty())
        assertFalse(ConflictCopies.hasUnresolvedContentConflict(outcome.survivor))
        val otherVault = SnippetCrypto.seal(plaintext, context("different-vault", recordId), keyring)
        val c = secure(4, otherVault, hash, "different-vault")
        assertEquals(1, ConflictCopies.secureContentConflictVariants(checked(null, b, c).survivor!!).size)
    }

    @Test fun secureLosingBytesStayUnderSourceAadUntilKeyAwareMaterialization() {
        val plaintext = utf8("Losing fictional secret")
        val sealed = SnippetCrypto.seal(plaintext, context("fixture-vault", recordId), keyring)
        val loser = secure(1, sealed, SnippetCrypto.contentHash(plaintext, keyring), "fixture-vault")
            .with("futurePrivateExtension", JsonValue.Text("Must not enter the mirrored snapshot"))
        val winner = secure(2, "Opaque newer seal", "newer-hash", "fixture-vault")
        val outcome = checked(null, loser, winner)
        assertTrue(outcome.conflictCopies.isEmpty())
        val survivor = outcome.survivor!!
        val v = ConflictCopies.secureContentConflictVariants(survivor).single()
        assertEquals(loser.id, v.sourceId)
        assertNotEquals(loser.id, v.copyId)
        assertFalse("futurePrivateExtension" in v.sourceExtensions)
        assertEquals(2, v.sourceExtensions.size)
        assertFailsWith<SnippetCrypto.Failure> { SnippetCrypto.open(sealed, context("fixture-vault", v.copyId), keyring) }
        assertContentEquals(plaintext, SnippetCrypto.open(sealed, context("fixture-vault", v.sourceId), keyring))
        val sealer = SnippetCryptoSealer(keyring, "fixture-wire")
        assertEquals(survivor, WireCodec.open(WireCodec.seal(survivor, sealer), sealer))
    }

    @Test fun representationChangesPreserveLosingPlainOrSecureBody() {
        val plain = record(1, "Plain original")
        val promoted = secure(2, "Opaque promoted seal", "secure-hash", "fixture-vault")
        val edited = record(3, "Plain independently edited")
        val winnerPlain = checked(plain, promoted, edited)
        val plainSurvivor = winnerPlain.survivor!!
        assertFalse(plainSurvivor.secure)
        assertEquals(1, ConflictCopies.secureContentConflictVariants(plainSurvivor).size)
        assertFalse("vaultKID" in plainSurvivor.x)
        val newerPromoted = promoted.copy(hlc = foreign(4))
        val winnerSecure = checked(plain, edited, newerPromoted)
        assertTrue(winnerSecure.survivor!!.secure)
        assertEquals("Plain independently edited", body(winnerSecure.conflictCopies.single()))
        val demoted = record(5, "Plain demoted")
        val secureEdit = secure(6, "Opaque edited seal", "other-hash", "fixture-vault")
        assertEquals(1, checked(promoted, demoted, secureEdit).conflictCopies.size)
    }

    @Test fun equalFieldsBackfillLegacyVaultExtensionsAndPlainRemovesStaleRouting() {
        val older = secure(1, "Same seal", "hash", "kid")
        val newer = older.copy(hlc = foreign(2)).with("vaultKID", null)
        assertEquals("kid", checked(null, older, newer).survivor!!.x["vaultKID"]?.textOrNull)
        val survivor = checked(null, older.copy(secure = false), newer.copy(secure = false)).survivor!!
        assertFalse("vaultKID" in survivor.x)
        assertFalse("vaultContentHash" in survivor.x)
    }

    @Test fun tieRankIgnoresUnionableVariantsAndDoesNotReverseSelectedBody() {
        val a = secure(2, "Seal A", "hash-a", "kid")
        val b = secure(2, "Seal B", "hash-b", "kid").withFields { it.copy(name = "Different name") }
        val initial = checked(null, a, b)
        val selected = body(initial.survivor)
        val (winner, losing) = if (selected == body(a)) a to b else b to a
        var carried = winner
        for ((key, value) in initial.survivor!!.x) {
            if (key.startsWith(ConflictCopies.CONTENT_CONFLICT_EXTENSION_PREFIX)) carried = carried.with(key, value)
        }
        val repeated = checked(null, carried, losing).survivor!!
        assertEquals(selected, body(repeated))
        assertEquals(1, ConflictCopies.secureContentConflictVariants(repeated).size)
        assertEquals(repeated, checked(null, repeated, repeated).survivor)
    }

    @Test fun independentlyCarriedVariantsUnionAndResolveOnlyExactUnderstoodValues() {
        val current = secure(3, "Current seal", "current", "kid")
        val carriedA = checked(null, secure(1, "Seal A", "a", "kid"), current).survivor!!
        val carriedB = checked(null, secure(2, "Seal B", "b", "kid"), current).survivor!!
        var union = checked(null, carriedA, carriedB).survivor!!
        assertEquals(2, ConflictCopies.secureContentConflictVariants(union).size)
        val future = "contentConflict.v2.${"c".repeat(64)}"
        union = union.with(future, JsonValue.Text("Opaque future fixture"))
        ConflictCopies.validateContentConflictExtensions(union)
        assertTrue(ConflictCopies.hasUnknownContentConflictVersion(union))
        val expected = union.x.filterKeys { it.startsWith(ConflictCopies.CONTENT_CONFLICT_V1_EXTENSION_PREFIX) }
        val resolved = assertNotNull(ConflictCopies.resolvingContentConflicts(union, expected))
        assertTrue(future in resolved.x)
        assertTrue(ConflictCopies.hasUnresolvedContentConflict(resolved))
        assertNull(ConflictCopies.resolvingContentConflicts(resolved, expected))
        val stale = LinkedHashMap(expected).also { it[it.keys.first()] = JsonValue.Null }
        assertNull(ConflictCopies.resolvingContentConflicts(union, stale))
        assertNull(ConflictCopies.resolvingContentConflicts(union, mapOf(future to JsonValue.Text("Opaque future fixture"))))
        assertNull(ConflictCopies.resolvingContentConflicts(union.tombstoned(foreign(9), "bbbbbbb2"), emptyMap()))
    }

    @Test fun malformedOrTamperedReservedValuesHaltBeforeSurvivorIsReturned() {
        val source = secure(1, "Losing seal", "hash-a", "kid")
        val winner = secure(2, "Winning seal", "hash-b", "kid")
        val valid = checked(null, source, winner).survivor!!
        val variant = ConflictCopies.secureContentConflictVariants(valid).single()
        val key = variant.extensionKey
        for (mutation in 0 until 11) {
            val members = LinkedHashMap(valid.x.getValue(key).objectOrNull!!)
            when (mutation) {
                0 -> members["extra"] = JsonValue.Bool(true)
                1 -> members["secure"] = JsonValue.Bool(false)
                2 -> members["version"] = JsonValue.Real(1.0)
                3 -> members["sourceID"] = JsonValue.Text(uuid128(99).toString())
                4 -> members["sourceHLC"] = JsonValue.Text("invalid")
                5 -> members["sourceOrigin"] = JsonValue.Text("AAAAAAA1")
                6 -> members["copyID"] = JsonValue.Text(uuid128(100).toString())
                7 -> members.remove("x")
                8 -> members["fields"] = JsonValue.Null
                9 -> members["copyID"] = JsonValue.Text(Uuids.uppercase(variant.copyId))
                else -> members["x"] = JsonValue.obj(
                    "vaultKID" to JsonValue.Text("kid"), "vaultContentHash" to JsonValue.Text("x".repeat(257)),
                )
            }
            val bad = valid.with(key, JsonValue.Object(members))
            assertFailsWith<MergeFailure.MalformedContentConflict>("mutation $mutation") { merge(null, bad, winner) }
        }
        for (badKey in listOf(
            "contentConflict.v1.bad", "contentConflict.v2.", "contentConflict.v1234.000", "contentConflict.vx.000",
            "contentConflict..000", "contentConflict.invalid",
        )) {
            assertFailsWith<MergeFailure.MalformedContentConflict>(badKey) {
                ConflictCopies.validateContentConflictExtensions(winner.with(badKey, JsonValue.Null))
            }
        }
        // A legacy secure loser without its keyed hash cannot form a variant: the survivor fails its own validation.
        assertFailsWith<MergeFailure.MalformedContentConflict> { merge(null, source.with("vaultContentHash", null), winner) }
        assertFailsWith<MergeFailure.MalformedContentConflict> { merge(null, source.with("vaultKID", null), winner) }
        assertFailsWith<MergeFailure.MismatchedIdentity> { merge(source, winner, winner.copy(id = uuid128(99))) }
    }

    @Test fun unresolvedAncestorBlocksTombstonesAndFutureVariantsRemainOpaque() {
        val clean = record(1, "Body")
        val deletion = clean.userDeletion(foreign(100), "bbbbbbb2")
        val base = clean.with("contentConflict.v002.${"f".repeat(64)}", JsonValue.Integer(2))
        ConflictCopies.validateContentConflictExtensions(base)
        assertTrue(ConflictCopies.hasUnknownContentConflictVersion(base))
        assertFailsWith<MergeFailure.UnresolvedContentConflictDeletion> { merge(base, deletion, base) }
        assertFailsWith<MergeFailure.UnresolvedContentConflictDeletion> { merge(base, deletion, deletion) }
        val corruptTombstone = deletion.copy(x = base.x)
        assertFailsWith<MergeFailure.MalformedContentConflict> { ConflictCopies.validateContentConflictExtensions(corruptTombstone) }
        val edited = record(101, "Real edit preserved")
        assertEquals(edited, checked(base, deletion, edited).survivor)
        // Without an ancestor the live side always counts as changed and survives, so
        // Swift's `base ?? live` fallback never reaches a tombstone.
        assertEquals(base, merge(null, deletion, base).survivor)
    }

    /**
     * Linux refuses the first pair (its decoder caps nodes); Swift and this port do not,
     * since nothing in the Swift merge counts nodes. Pinned from the Swift differential.
     */
    @Test fun variantCountAggregateAndGeneratedWireBudgetFailClosed() {
        val manyLocal = record(1, "Body").with("futureLeft", JsonValue.Array(List(50_000) { JsonValue.Null }))
        val manyRemote = record(2, "Body").with("futureRight", JsonValue.Array(List(50_000) { JsonValue.Null }))
        ConflictCopies.validateContentConflictExtensions(manyLocal)
        ConflictCopies.validateContentConflictExtensions(manyRemote)
        val union = merge(null, manyLocal, manyRemote).survivor!!
        assertTrue("futureLeft" in union.x && "futureRight" in union.x)

        var crowded = record(1, "Body")
        for (n in 0 until ConflictCopies.MAXIMUM_CONTENT_CONFLICT_VARIANT_COUNT) {
            crowded = crowded.with("contentConflict.v2.%064x".format(n), JsonValue.Null)
        }
        ConflictCopies.validateContentConflictExtensions(crowded)
        crowded = crowded.with("contentConflict.v2.%064x".format(ConflictCopies.MAXIMUM_CONTENT_CONFLICT_VARIANT_COUNT), JsonValue.Null)
        assertFailsWith<MergeFailure.MalformedContentConflict> { ConflictCopies.validateContentConflictExtensions(crowded) }

        val big = record(1, "Body").with(
            "contentConflict.v2.${"a".repeat(64)}", JsonValue.Text("x".repeat(ConflictCopies.MAXIMUM_CONTENT_CONFLICT_VARIANT_BYTES)),
        )
        big.canonicalBytes()
        assertFailsWith<MergeFailure.MalformedContentConflict> { ConflictCopies.validateContentConflictExtensions(big) }

        val local = record(2, "a".repeat(350_000))
        val remote = secure(1, "b".repeat(350_000), "hash", "kid")
        ConflictCopies.validateContentConflictExtensions(local)
        ConflictCopies.validateContentConflictExtensions(remote)
        assertFailsWith<MergeFailure.MalformedContentConflict> { merge(null, local, remote) }

        // The losing ordinary input fits; the copy's longer name and provenance do not.
        val empty = record(1, "")
        val overhead = empty.canonicalBytes().size
        val maximum = empty.withFields { it.copy(content = ByteArray(ConflictCopies.MAXIMUM_WIRE_CANONICAL_BYTES - overhead) { 'x'.code.toByte() }) }
        assertEquals(ConflictCopies.MAXIMUM_WIRE_CANONICAL_BYTES, maximum.canonicalBytes().size)
        ConflictCopies.validateContentConflictExtensions(maximum)
        assertFailsWith<MergeFailure.MalformedContentConflict> { merge(null, maximum, record(2, "Winner")) }
        // One byte more is refused as an input.
        val over = maximum.withFields { it.copy(content = it.content + 'x'.code.toByte()) }
        assertFailsWith<MergeFailure.MalformedContentConflict> { merge(null, over, null) }
    }

    @Test fun copyProvenanceIsNotDurabilityProofForAnArbitraryIdentifier() {
        val source = record(1, "Source")
        val copy = ConflictCopies.makePlainContentConflictCopy(source)
        assertTrue(ConflictCopies.hasValidConflictCopyIdentity(copy))
        var impostor = copy.copy(id = uuid128(100))
        assertFalse(ConflictCopies.hasValidConflictCopyIdentity(impostor))
        assertFalse(ConflictCopies.isMatchingPlainConflictCopy(impostor, copy))
        val fingerprint = ConflictCopies.conflictCopyProvenance(copy)!!.fingerprint
        assertTrue(ConflictCopies.matchesConflictCopyProvenance(copy, source.id, fingerprint))
        for (raw in listOf(
            JsonValue.Null,
            JsonValue.obj(
                "version" to JsonValue.Integer(2), "sourceID" to JsonValue.Text(source.id.toString()),
                "fingerprint" to JsonValue.Text(fingerprint),
            ),
            JsonValue.obj(
                "version" to JsonValue.Integer(1), "sourceID" to JsonValue.Text(source.id.toString()),
                "fingerprint" to JsonValue.Text(fingerprint.uppercase()),
            ),
        )) {
            impostor = impostor.with(ConflictCopies.PLAIN_CONFLICT_COPY_EXTENSION_KEY, raw)
            assertNull(ConflictCopies.conflictCopyProvenance(impostor))
        }
    }

    @Test fun metadataUsesCanonicalEquivalenceWhileBodyBytesStillPreserveAConflict() {
        val base = record(1, "Original").withFields { it.copy(name = "Café") }
        val local = base.copy(hlc = foreign(100)).withFields { it.copy(name = "Café") }
        val remote = record(2, "Changed").withFields { it.copy(name = "Renamed") }
        assertEquals("Renamed", checked(base, local, remote).survivor!!.fields!!.name)
        assertEquals(1, checked(null, record(1, "Café"), record(2, "Café")).conflictCopies.size)
    }

    @Test fun finiteOrdinaryEditMatrixNeverLosesABodyAndIsCommutative() {
        val base = record(1, "Ancestor")
        for (localBody in listOf("Ancestor", "L", "R", "")) {
            for (remoteBody in listOf("Ancestor", "L", "R", "")) {
                for (wall in listOf(2L, 3L)) {
                    val local = record(wall, localBody).withFields { it.copy(name = "Local name") }
                    val remote = record(2, remoteBody).withFields { it.copy(keyword = "remote-keyword") }
                    val result = checked(base, local, remote)
                    val bodies = MergeFixtures.bodies(result)
                    if (localBody != "Ancestor") assertTrue(localBody in bodies)
                    if (remoteBody != "Ancestor") assertTrue(remoteBody in bodies)
                    val fields = result.survivor!!.fields!!
                    assertEquals("Local name", fields.name)
                    assertEquals("remote-keyword", fields.keyword)
                }
            }
        }
    }

    // SyncConflictCopyTests (merge level)

    private val snippetId = UUID.fromString("00000000-0000-4000-8000-000000000012")
    private val vaultKid = "11111111-2222-4333-8444-555555555555"

    private fun conflictEnvelope(
        device: String,
        revision: Long,
        content: String,
        name: String = "Shared snippet",
        tags: List<String> = listOf("original"),
        isPinned: Boolean = false,
        clockDevice: String = device,
    ) = MergeFixtures.plainEnvelope(
        snippetId, revision, device, content, name = name, keyword = "shared", tags = tags, isPinned = isPinned,
        clockDevice = clockDevice,
    )

    private fun secureConflictEnvelope(device: String, revision: Long, sealed: String, contentHash: String) =
        MergeFixtures.secureEnvelope(
            snippetId, revision, device, sealed, contentHash, vaultKid = vaultKid,
            name = "Secure shared snippet", keyword = "secure-shared", tags = listOf("vault"),
        )

    @Test fun oppositeMergeOrdersDeriveTheSameConflictCopyID() {
        val ancestor = conflictEnvelope("aaaaaaa1", 100, "ancestor body")
        val a = conflictEnvelope("aaaaaaa1", 200, "body written on A")
        val b = conflictEnvelope("bbbbbbb2", 300, "body written on B")
        val onA = merge(ancestor, a, b)
        val onB = merge(ancestor, b, a)
        assertTrue(MergeFixtures.sameBytes(onA, onB))
        val copy = onA.conflictCopies.single()
        assertNotEquals(snippetId, copy.id)
        assertEquals("body written on A", body(copy))
        assertEquals("body written on B", body(onA.survivor))
    }

    @Test fun equalHLCConflictConvergesIdenticallyInOppositeSubmitOrders() {
        val ancestor = conflictEnvelope("aaaaaaa1", 100, "ancestor body")
        val a = conflictEnvelope("aaaaaaa1", 200, "body written on A", clockDevice = "cccccccc")
        val b = conflictEnvelope("bbbbbbb2", 200, "body written on B", clockDevice = "cccccccc")
        assertEquals(a.hlc, b.hlc)
        val onA = merge(ancestor, a, b)
        val onB = merge(ancestor, b, a)
        assertTrue(MergeFixtures.sameBytes(onA, onB), "the canonical rank decides an exact clock tie the same way on both")
        assertEquals(setOf("body written on A", "body written on B"), MergeFixtures.bodies(onA))
    }

    @Test fun independentFieldOnlyChangesStillMergeWithoutACopy() {
        val ancestor = conflictEnvelope("aaaaaaa1", 100, "unchanged body", name = "Original name")
        val renamedOnA = conflictEnvelope("aaaaaaa1", 200, "unchanged body", name = "Renamed on A")
        val classifiedOnB = conflictEnvelope(
            "bbbbbbb2", 300, "unchanged body", name = "Original name", tags = listOf("original", "mobile"), isPinned = true,
        )
        val outcome = checked(ancestor, renamedOnA, classifiedOnB)
        assertTrue(outcome.conflictCopies.isEmpty(), "independent fields are an ordinary merge, not a content conflict")
        val merged = outcome.survivor!!.fields!!
        assertEquals("Renamed on A", merged.name)
        assertEquals(listOf("original", "mobile"), merged.tags)
        assertTrue(merged.isPinned)
        assertEquals("unchanged body", String(merged.content, Charsets.UTF_8))
    }

    @Test fun concurrentDeleteAndUpdateKeepTheUpdateInEitherSubmitOrder() {
        val ancestor = conflictEnvelope("aaaaaaa1", 100, "ancestor body")
        val deletion = ancestor.tombstoned(Hlc.of(200, 0, "aaaaaaa1"), "aaaaaaa1")
        val update = conflictEnvelope("bbbbbbb2", 300, "body rescued from deletion")
        for ((local, remote) in listOf(deletion to update, update to deletion)) {
            val outcome = merge(ancestor, local, remote)
            assertEquals("body rescued from deletion", body(outcome.survivor))
            assertTrue(outcome.conflictCopies.isEmpty(), "delete-vs-update has only one user body")
        }
    }

    @Test fun anUncontestedDeleteStillDeletesInsteadOfCreatingACopy() {
        val ancestor = conflictEnvelope("aaaaaaa1", 100, "ancestor body")
        val deletion = ancestor.tombstoned(Hlc.of(200, 0, "aaaaaaa1"), "aaaaaaa1")
        val outcome = checked(ancestor, deletion, ancestor)
        assertTrue(outcome.survivor!!.deleted)
        assertTrue(outcome.conflictCopies.isEmpty())
    }

    private fun sealedVersion(text: String, device: String, revision: Long): SyncEnvelope {
        val plaintext = utf8(text)
        return secureConflictEnvelope(
            device, revision, SnippetCrypto.seal(plaintext, context(vaultKid, snippetId), keyring),
            SnippetCrypto.contentHash(plaintext, keyring),
        )
    }

    @Test fun unawareShallowMergeAndWireRoundTripUnionIndependentSecureVariants() {
        val sourceA = sealedVersion("opaque variant A", "aaaaaaa1", 200)
        val sourceB = sealedVersion("opaque variant B", "bbbbbbb2", 300)
        val variantA = ConflictCopies.makeSecureContentConflictVariant(sourceA)
        val variantB = ConflictCopies.makeSecureContentConflictVariant(sourceB)
        assertNotEquals(variantA.first, variantB.first)
        val survivor = sealedVersion("current secure winner", "aaaaaaa1", 400)
        val viewA = survivor.with(variantA.first, variantA.second)
        val viewB = survivor.with(variantB.first, variantB.second)
        val mergedAB = merge(survivor, viewA, viewB).survivor!!
        val mergedBA = merge(survivor, viewB, viewA).survivor!!
        assertEquals(mergedAB, mergedBA, "mirrored old clients must compute the same shallow union")
        assertEquals(variantA.second, mergedAB.x[variantA.first])
        assertEquals(variantB.second, mergedAB.x[variantB.first])
        assertEquals(
            listOf(variantA.first, variantB.first).sorted(),
            ConflictCopies.secureContentConflictVariants(mergedAB).map { it.extensionKey },
        )
        val roundTripped = MergeFixtures.reparsed(mergedAB)
        assertEquals(mergedAB, roundTripped)
        assertEquals(2, ConflictCopies.secureContentConflictVariants(roundTripped).size)
    }

    @Test fun laterSecureConflictUnionsANewVariantWithoutRecursiveEmbedding() {
        val historical = ConflictCopies.makeSecureContentConflictVariant(sealedVersion("historical losing secret", "aaaaaaa1", 150))
        val ancestor = sealedVersion("second ancestor", "aaaaaaa1", 300).with(historical.first, historical.second)
        val onA = sealedVersion("second edit A", "aaaaaaa1", 400).with(historical.first, historical.second)
        val onB = sealedVersion("second edit B", "bbbbbbb2", 500).with(historical.first, historical.second)
        val expectedNew = ConflictCopies.makeSecureContentConflictVariant(onA)
        val merged = merge(ancestor, onA, onB).survivor!!
        assertEquals(body(onB), body(merged))
        assertEquals(historical.second, merged.x[historical.first], "a later conflict must not overwrite an unresolved earlier one")
        assertEquals(expectedNew.second, merged.x[expectedNew.first])
        val variants = ConflictCopies.secureContentConflictVariants(merged)
        assertEquals(listOf(historical.first, expectedNew.first).sorted(), variants.map { it.extensionKey })
        assertTrue(variants.all { variant -> variant.sourceExtensions.keys.none(ConflictCopies::isContentConflictExtension) })
    }

    @Test fun secureContentConflictPreservesBothOpaqueCiphertextsAndTheirProvenance() {
        val ancestor = sealedVersion("ancestor secret", "aaaaaaa1", 100)
        val plaintextA = utf8("secret written on A")
        val sealedA = SnippetCrypto.seal(plaintextA, context(vaultKid, snippetId), keyring)
        val editA = secureConflictEnvelope("aaaaaaa1", 200, sealedA, SnippetCrypto.contentHash(plaintextA, keyring))
        val editB = sealedVersion("secret written on B", "bbbbbbb2", 300)
        val expected = ConflictCopies.makeSecureContentConflictVariant(editA)
        val outcome = checked(ancestor, editA, editB)
        val immediate = outcome.survivor!!
        assertEquals(body(editB), body(immediate), "the clock winner remains the ordinary secure envelope")
        assertTrue(outcome.conflictCopies.isEmpty(), "raw vault bytes must not be filed under a new id")
        assertEquals(expected.second, immediate.x[expected.first])
        val variant = ConflictCopies.secureContentConflictVariants(immediate).single()
        assertNotEquals(snippetId, variant.copyId)
        assertEquals(snippetId, variant.sourceId)
        assertEquals(editA.hlc, variant.sourceHlc)
        assertEquals(editA.origin, variant.sourceOrigin)
        assertEquals(editA.fields, variant.fields)
        assertEquals(sealedA, String(variant.fields.content, Charsets.UTF_8))
        assertEquals(SnippetCrypto.contentHash(plaintextA, keyring), variant.vaultContentHash)
        assertEquals(vaultKid, variant.vaultKeyId)
        assertFailsWith<SnippetCrypto.Failure> { SnippetCrypto.open(sealedA, context(vaultKid, variant.copyId), keyring) }
        // A second round over the result keeps exactly one variant.
        assertEquals(1, ConflictCopies.secureContentConflictVariants(checked(ancestor, immediate, editB).survivor!!).size)
    }

    // SyncConflictCopyVectorTests: see LinuxMergeFixturesTest.

    // SyncConflictPayloadBudgetTests (merge level)

    private val budgetSourceId = UUID.fromString("30000000-0000-4000-8000-000000000006")

    private fun budgetSealer(scope: String) = SnippetCryptoSealer(
        SnippetCrypto.Keyring(ByteArray(32) { 0x33 }, ByteArray(SnippetCrypto.SALT_BYTE_COUNT) { 0x55 }),
        scope,
    ) { ByteArray(SnippetCrypto.NONCE_BYTE_COUNT) { 0x77 } }

    private fun budgetEnvelope(revision: Long, device: String, secure: Boolean, content: ByteArray, x: Map<String, JsonValue> = emptyMap()) =
        SyncEnvelope(
            id = budgetSourceId, hlc = Hlc.of(revision, 0, device), origin = device, secure = secure, deleted = false,
            fields = SyncEnvelope.Fields(
                name = "x", keyword = "k", content = content, tags = emptyList(), isEnabled = true, isPinned = false,
                createdAt = 1.0, updatedAt = revision.toDouble(),
            ),
            x = x,
        )

    private fun opaqueSecure(revision: Long, device: String, content: ByteArray, hash: String) = budgetEnvelope(
        revision, device, true, content,
        mapOf("vaultContentHash" to JsonValue.Text(hash), "vaultKID" to JsonValue.Text("payload-budget-vault")),
    )

    private fun wireBytes(envelope: SyncEnvelope, sealer: SnippetCryptoSealer): Int = WireCodec.seal(envelope, sealer).blob.size

    @Test fun shippingEncodingPinsTheLastCloudKitSafePaddingBlock() {
        val sealer = budgetSealer("shipping-boundary")
        val identity = WireIdentity(budgetSourceId, "boundary", false)
        val lastSafe = sealer.seal(ByteArray(EnvelopeMerge.MAXIMUM_WIRE_CANONICAL_BYTES) { 0x61 }, identity)
        val next = sealer.seal(ByteArray(EnvelopeMerge.MAXIMUM_WIRE_CANONICAL_BYTES + 1) { 0x61 }, identity)
        assertEquals(899_796, lastSafe.size)
        assertEquals(900_138, next.size)
    }

    @Test fun fullCanonicalBudgetMatchesShippingBoundary() {
        assertEquals(674_815, EnvelopeMerge.MAXIMUM_WIRE_CANONICAL_BYTES)
        assertEquals(674_815, ConflictCopies.MAXIMUM_WIRE_CANONICAL_BYTES)
        assertTrue(ConflictCopies.MAXIMUM_CONTENT_CONFLICT_VARIANT_BYTES <= 512 * 1_024)
        assertEquals(128, ConflictCopies.MAXIMUM_CONTENT_CONFLICT_VARIANT_COUNT)
    }

    @Test fun individuallyShippableInputsCannotMergeIntoOversizedSecureVariantSurvivor() {
        val sealer = budgetSealer("aggregate-conflict")
        val ancestor = opaqueSecure(100, "aaaaaaa1", utf8("ancestor seal"), "ancestor-hash")
        val local = opaqueSecure(200, "aaaaaaa1", ByteArray(350_000) { 0x73 }, "local-large-secure-hash")
        val remote = budgetEnvelope(300, "bbbbbbb2", false, ByteArray(350_000) { 0x61 })
        assertTrue(wireBytes(local, sealer) <= 900_000)
        assertTrue(wireBytes(remote, sealer) <= 900_000)
        // Swift's suite accepts a reducer that rejects this output; Swift's own and this one both do.
        assertFailsWith<MergeFailure.MalformedContentConflict> { merge(ancestor, local, remote) }
    }

    @Test fun generatedPlainConflictCopyMustFitEvenWhenItsSourceInputFits() {
        val sealer = budgetSealer("plain-copy-boundary")
        var fitting = 0
        var oversized = 700_000
        while (fitting + 1 < oversized) {
            val candidate = fitting + (oversized - fitting) / 2
            if (wireBytes(budgetEnvelope(200, "aaaaaaa1", false, ByteArray(candidate) { 0x61 }), sealer) <= 900_000) {
                fitting = candidate
            } else {
                oversized = candidate
            }
        }
        val source = budgetEnvelope(200, "aaaaaaa1", false, ByteArray(fitting) { 0x61 })
        val ancestor = budgetEnvelope(100, "aaaaaaa1", false, ByteArray(8) { 0x61 }).let {
            SyncEnvelope(it.id, it.hlc, it.origin, it.secure, it.deleted, it.fields!!.copy(name = "ancestor"), it.x)
        }
        val secureWinner = opaqueSecure(300, "bbbbbbb2", utf8("small secure winner"), "secure-winner-hash")
        val outcome = try {
            merge(ancestor, source, secureWinner)
        } catch (_: MergeFailure.MalformedContentConflict) {
            return
        }
        assertTrue(wireBytes(outcome.conflictCopies.single(), sealer) <= 900_000)
    }

    // SyncConflictOrderingTests (merge level)

    @Test fun editedRemoteConflictCopyIsNotTreatedAsConcurrentWithItsGeneratedAncestor() {
        val ancestor = conflictEnvelope("aaaaaaa1", 100, "ancestor body")
        val generated = merge(
            ancestor, conflictEnvelope("aaaaaaa1", 200, "body written on A"), conflictEnvelope("bbbbbbb2", 300, "body written on B"),
        ).conflictCopies.single()
        val edited = SyncEnvelope(
            generated.id, Hlc.of(9_000, 0, "bbbbbbb2"), "bbbbbbb2", false, false,
            generated.fields!!.copy(name = "Renamed copy", content = utf8("edited copy body")), generated.x,
        )
        assertTrue(ConflictCopies.isMatchingPlainConflictCopy(edited, generated), "a user-edited copy still matches")
        val evolved = merge(generated, generated, edited)
        assertTrue(evolved.conflictCopies.isEmpty())
        assertEquals(edited, evolved.survivor)
    }

    @Test fun unrelatedRecordAtGeneratedCopyIDHaltsBeforeApplyInEitherArrivalOrder() {
        val ancestor = conflictEnvelope("aaaaaaa1", 100, "ancestor body")
        val generated = merge(
            ancestor, conflictEnvelope("aaaaaaa1", 200, "body written on A"), conflictEnvelope("bbbbbbb2", 300, "body written on B"),
        ).conflictCopies.single()
        val occupant = MergeFixtures.plainEnvelope(generated.id, 500, "bbbbbbb2", "unrelated body")
        assertFalse(ConflictCopies.isMatchingPlainConflictCopy(occupant, generated))
        assertFalse(ConflictCopies.isMatchingPlainConflictCopy(generated, occupant))
        assertFalse(ConflictCopies.hasValidConflictCopyIdentity(occupant))
        assertTrue(ConflictCopies.hasValidConflictCopyIdentity(generated))
    }

    // SyncRestoredConflictCopyTests (the merge layer's identity rules)

    @Test fun aCopyLeavingPrimaryLeavesOnlyItsIdentityBehind() {
        val copy = merge(
            conflictEnvelope("aaaaaaa1", 100, "ancestor body"), conflictEnvelope("aaaaaaa1", 200, "phone body"),
            conflictEnvelope("bbbbbbb2", 300, "mac body"),
        ).conflictCopies.single()
        val identity = assertNotNull(ConflictCopies.retainedCopyIdentity(copy))
        assertTrue(identity.deleted)
        assertFalse(identity.secure)
        assertNull(identity.fields, "no body or field survives the deletion")
        assertEquals(mapOf(ConflictCopies.PLAIN_CONFLICT_COPY_EXTENSION_KEY to copy.x.getValue(ConflictCopies.PLAIN_CONFLICT_COPY_EXTENSION_KEY)), identity.x)
        assertEquals(copy.hlc, identity.hlc)
        assertEquals(copy.origin, identity.origin)
        assertTrue(ConflictCopies.hasValidConflictCopyIdentity(identity))
        assertEquals(identity, ConflictCopies.retainedCopyIdentity(identity), "a retained identity carries itself forward")
        assertNull(ConflictCopies.retainedCopyIdentity(conflictEnvelope("aaaaaaa1", 400, "ordinary")))
    }

    @Test fun onlyAVerifiedPlainIdentityIsRetained() {
        val copy = merge(
            conflictEnvelope("aaaaaaa1", 100, "ancestor body"), conflictEnvelope("aaaaaaa1", 200, "phone body"),
            conflictEnvelope("bbbbbbb2", 300, "mac body"),
        ).conflictCopies.single()
        val provenance = copy.x.getValue(ConflictCopies.PLAIN_CONFLICT_COPY_EXTENSION_KEY)
        val forged = conflictEnvelope("aaaaaaa1", 500, "forged").with(ConflictCopies.PLAIN_CONFLICT_COPY_EXTENSION_KEY, provenance)
        assertFalse(ConflictCopies.hasValidConflictCopyIdentity(forged))
        val secureCopy = copy.copy(secure = true)
        val widened = ConflictCopies.retainedCopyIdentity(copy)!!.with("future", JsonValue.Bool(true))
        for (previous in listOf(forged, secureCopy, widened)) {
            assertNull(ConflictCopies.retainedCopyIdentity(previous), "${previous.id} must not be retained")
        }
    }

    // The vault carrier (brief 02, §4.3: the merge-side format)

    @Test fun aVariantIsMirroredIntoTheVaultAsPaddedBase64OfItsCanonicalBytes() {
        val loser = secure(1, "Losing seal", "hash-a", "kid")
        val (key, value) = ConflictCopies.makeSecureContentConflictVariant(loser)
        val carrierKey = ConflictCopies.opaqueCarrierKey(key)
        assertEquals("contentConflictOpaque.v1.v1.${key.removePrefix("contentConflict.v1.")}", carrierKey)
        val carrier = ConflictCopies.opaqueCarrierValue(value).textOrNull!!
        assertContentEquals(CanonicalJson.encode(value), java.util.Base64.getDecoder().decode(carrier))
        assertEquals(0, carrier.length % 4, "padded")
        assertFailsWith<IllegalArgumentException> { ConflictCopies.opaqueCarrierKey("vaultKID") }
    }
}
