package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.wire.SyncEnvelope
import java.util.Collections

/**
 * Three-way merge of one record as it travels between devices
 * (`SyncMerge.mergeEnvelopeOutcome` in `SyncMerge.swift`). This decides what every device
 * converges to, so for every input it makes the decision the Swift code makes and builds
 * the same canonical bytes.
 *
 * With a common ancestor most conflicts are not conflicts: if only one side moved a
 * field away from the ancestor, that side is right and no clock is consulted. A clock is
 * needed only when both sides moved the same field. Three rules hold throughout:
 *
 * 1. **Absence is never a delete.** A missing side means "not seen yet". Deletions
 *    arrive as tombstones.
 * 2. **An edit beats a delete.** A tombstone survives only against a side that did not
 *    change since the ancestor.
 * 3. **A body both sides changed is never discarded.** The losing ordinary body becomes
 *    a conflict copy, the losing secure body a variant inside the survivor's `x`
 *    ([ConflictCopies]).
 *
 * The merge takes no device identity and reads no clock of its own. Which side is
 * "local" matters in exactly the ways listed at [merge].
 */
object EnvelopeMerge {

    /**
     * What a merge produced (`SyncMerge.EnvelopeOutcome`). A cross-device merge can
     * create an additional ordinary record; keeping it beside the survivor lets the
     * engine apply both in one library transaction and journal the copy as its own
     * create.
     */
    class Outcome(
        /** The merged record, a tombstone, or `null` when neither side has the record. */
        val survivor: SyncEnvelope?,
        conflictCopies: List<SyncEnvelope>,
    ) {
        /** Losing ordinary bodies as disabled records, sorted by id text. At most one today. */
        val conflictCopies: List<SyncEnvelope> = Collections.unmodifiableList(ArrayList(conflictCopies))

        /** Swift's `==`: envelopes compare as [SwiftSemantics.envelopesEqual], text by canonical equivalence. */
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Outcome) return false
            val mine = survivor
            val theirs = other.survivor
            if ((mine == null) != (theirs == null)) return false
            if (mine != null && theirs != null && !SwiftSemantics.envelopesEqual(mine, theirs)) return false
            if (conflictCopies.size != other.conflictCopies.size) return false
            return conflictCopies.indices.all { SwiftSemantics.envelopesEqual(conflictCopies[it], other.conflictCopies[it]) }
        }

        override fun hashCode(): Int = 31 * (survivor?.hashCode() ?: 0) + conflictCopies.size

        override fun toString(): String = "Outcome(survivor=$survivor, conflictCopies=${conflictCopies.size})"
    }

    /** See [ConflictCopies.MAXIMUM_WIRE_CANONICAL_BYTES]: no input and no output of [merge] is larger. */
    const val MAXIMUM_WIRE_CANONICAL_BYTES: Int = ConflictCopies.MAXIMUM_WIRE_CANONICAL_BYTES

    private const val VAULT_CONTENT_HASH = SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY
    private const val VAULT_KEY_ID = SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY

    /**
     * Merges [local] and [remote] against their common ancestor [base]. Each may be
     * absent. Every input and every output passes
     * [ConflictCopies.validateContentConflictExtensions].
     *
     * | local | remote | survivor |
     * |---|---|---|
     * | absent | absent | none |
     * | absent | R | R, whatever [base] says |
     * | L | absent | L |
     * | tombstone | tombstone | the higher-ranked one |
     * | tombstone T | live V (either order) | V when [base] is absent or V's envelope hash differs from [base]'s, else T |
     * | live | live, equal fields and same `secure` | the winner, with the union of both `x` |
     * | live | live, otherwise | a field-by-field merge |
     *
     * **Rank.** The higher clock wins. With equal clocks, the envelope whose canonical
     * bytes, taken without its `contentConflict.*` members, sort first as unsigned bytes
     * wins; if those are equal too, remote wins, except that two envelopes that are equal
     * as Swift compares them are decided for local.
     *
     * **Field merge.** Name, keyword and the two flags by [FieldMerge.mergeScalar], tags
     * by [FieldMerge.mergeTags], `createdAt` the earlier and `updatedAt` the later of the
     * two. The survivor takes the later clock and the winner's `origin`; its `x` is the
     * union of both bags with the winner's value on a shared key.
     *
     * **Body.** Bodies are compared by a content key, never by their bytes: the vault's
     * keyed hash and vault id for a secure record, the SHA-256 of the body otherwise, and
     * the representation is part of the key, so promoting a snippet into the vault while
     * the other side edits it is a conflict. Equal keys: the winner's body. One side
     * equals the ancestor: the other side's body. Otherwise the winner's body stays and
     * the loser is preserved. `secure`, `vaultContentHash` and `vaultKID` follow the
     * selected body, not the winner; an ordinary result carries neither vault member.
     *
     * **What does not depend on which side is local.** Swapping [local] and [remote]
     * gives the same survivor and copies as Swift compares envelopes (text fields by
     * canonical equivalence), the same failure, and the same conflict copies byte for
     * byte. The survivor's bytes differ in two corners only, both outside ordinary
     * input: a text field or a key of `x` that the two sides spell in different
     * normalization forms (the local spelling is kept where both agree), and `createdAt`
     * or `updatedAt` of `0.0` on one side and `-0.0` on the other (Swift's `min` keeps
     * its first argument on a tie, `max` its second). An exact rank tie (equal clocks,
     * envelopes that differ only in `contentConflict.*` members) takes the remote
     * argument on both peers, but the two survivors are then the same bytes.
     * `MergeAlgebraTest` checks this over generated triples and `MergeDifferentialTest`
     * against Swift.
     *
     * **Not a fixed point against its own input.** Merging the survivor over the side
     * it came from again (`merge(remote, survivor, remote)`) can reorder its tags, since
     * tags already in the ancestor keep the ancestor's order (see [FieldMerge.mergeTags]),
     * and can backfill a vault member the survivor lacks; Swift does the same.
     *
     * @throws MergeFailure.MismatchedIdentity when the inputs have different ids. Not in Swift.
     * @throws MergeFailure.MalformedContentConflict when an input or an output fails
     *   validation or is over the budget, or the losing body cannot be preserved (a
     *   secure loser without `vaultContentHash` or `vaultKID` among them).
     * @throws MergeFailure.UnresolvedContentConflictDeletion when a tombstone would win
     *   while the ancestor (or, without one, the live side) still carries a
     *   `contentConflict.*` member.
     * @throws MergeFailure.UnrepresentableConflictDate when a copy cannot be named. Not in Swift.
     * @throws CanonicalJson.Failure when an input cannot be written as canonical JSON.
     */
    @Throws(MergeFailure::class, CanonicalJson.Failure::class)
    fun merge(base: SyncEnvelope?, local: SyncEnvelope?, remote: SyncEnvelope?): Outcome {
        // Linux's order: identities are compared as the inputs are validated, so an input
        // that is both malformed and foreign reports whichever comes first.
        var id: java.util.UUID? = null
        for (envelope in arrayOf(base, local, remote)) {
            if (envelope == null) continue
            if (id != null && id != envelope.id) throw MergeFailure.MismatchedIdentity()
            id = envelope.id
            ConflictCopies.validateContentConflictExtensions(envelope)
        }

        if (local == null && remote == null) return Outcome(null, emptyList())
        // Absence is never a delete without an ancestor to prove it, and here not even then.
        if (local == null) return Outcome(remote, emptyList())
        if (remote == null) return Outcome(local, emptyList())

        // An explicit tombstone on one side loses to a real edit on the other: a
        // deletion is repeatable, an edit that a delete swallowed is gone.
        if (local.deleted && remote.deleted) {
            refuseDeletionIfConflictIsUnresolved(base)
            return Outcome(if (outranks(local, remote)) local else remote, emptyList())
        }
        if (local.deleted) {
            val survivor = if (changed(remote, base)) remote else local
            if (survivor.deleted) refuseDeletionIfConflictIsUnresolved(base ?: remote)
            return Outcome(survivor, emptyList())
        }
        if (remote.deleted) {
            val survivor = if (changed(local, base)) local else remote
            if (survivor.deleted) refuseDeletionIfConflictIsUnresolved(base ?: local)
            return Outcome(survivor, emptyList())
        }

        val localFields = local.fields ?: throw MergeFailure.MalformedContentConflict()
        val remoteFields = remote.fields ?: throw MergeFailure.MalformedContentConflict()

        if (localFields == remoteFields && local.secure == remote.secure) {
            val localWins = outranksOrEqual(local, remote)
            val winner = if (localWins) local else remote
            val mergedX = SwiftSemantics.merging(local.x, remote.x, preferFirst = localWins)
            if (local.secure) {
                // Both members describe the selected sealed body. Prefer the clock
                // winner, and let the other peer backfill a legacy missing member.
                val otherX = if (localWins) remote.x else local.x
                for (key in arrayOf(VAULT_CONTENT_HASH, VAULT_KEY_ID)) {
                    SwiftSemantics.set(mergedX, key, SwiftSemantics.get(winner.x, key) ?: SwiftSemantics.get(otherX, key))
                }
            } else {
                SwiftSemantics.set(mergedX, VAULT_CONTENT_HASH, null)
                SwiftSemantics.set(mergedX, VAULT_KEY_ID, null)
            }
            val survivor = SyncEnvelope(
                id = winner.id, hlc = winner.hlc, origin = winner.origin, secure = winner.secure,
                deleted = false, fields = winner.fields, x = mergedX,
            )
            ConflictCopies.validateContentConflictExtensions(survivor)
            return Outcome(survivor, emptyList())
        }

        // The clock normally gives a total order, device included. A restored or
        // hand-built record can still carry the same clock on both sides; the payload
        // rank closes that tie the same way on both peers.
        val localWins = outranksOrEqual(local, remote)
        val winner = if (localWins) local else remote
        val baseFields = base?.fields

        // Representation is part of content identity: plain bytes and a vault seal are
        // never interchanged because their digests happen to match.
        val localKey = contentKey(local, localFields)
        val remoteKey = contentKey(remote, remoteFields)
        val baseKey = if (base != null && baseFields != null) contentKey(base, baseFields) else null

        val contentSource: SyncEnvelope
        var conflictCopies: List<SyncEnvelope> = emptyList()
        var secureVariant: Pair<String, JsonValue>? = null
        if (FoundationText.canonicalEquals(localKey, remoteKey)) {
            contentSource = winner
        } else if (baseKey != null && FoundationText.canonicalEquals(baseKey, remoteKey)) {
            contentSource = local
        } else if (baseKey != null && FoundationText.canonicalEquals(baseKey, localKey)) {
            contentSource = remote
        } else {
            // Both bodies changed. An ordinary body becomes a normal record at once. A
            // vault seal cannot: it is bound to the source id, so its whole opaque
            // snapshot stays in the extension bag until a layer with the key can open it
            // under the source id and reseal it under the copy id.
            contentSource = winner
            val loser = if (localWins) remote else local
            if (loser.secure) {
                secureVariant = ConflictCopies.makeSecureContentConflictVariant(loser)
            } else {
                conflictCopies = listOf(ConflictCopies.makePlainContentConflictCopy(loser))
            }
        }
        val selectedFields = contentSource.fields ?: throw MergeFailure.MalformedContentConflict()

        val merged = SyncEnvelope.Fields(
            name = FieldMerge.mergeScalar(baseFields?.name, localFields.name, remoteFields.name, localWins),
            keyword = FieldMerge.mergeScalar(baseFields?.keyword, localFields.keyword, remoteFields.keyword, localWins),
            content = selectedFields.content,
            tags = FieldMerge.mergeTags(baseFields?.tags, localFields.tags, remoteFields.tags, localWins),
            isEnabled = FieldMerge.mergeScalar(baseFields?.isEnabled, localFields.isEnabled, remoteFields.isEnabled, localWins),
            isPinned = FieldMerge.mergeScalar(baseFields?.isPinned, localFields.isPinned, remoteFields.isPinned, localWins),
            createdAt = SwiftSemantics.min(localFields.createdAt, remoteFields.createdAt),
            updatedAt = SwiftSemantics.max(localFields.updatedAt, remoteFields.updatedAt),
        )

        val mergedX = SwiftSemantics.merging(local.x, remote.x, preferFirst = localWins)
        if (contentSource.secure) {
            // Both members belong to the selected sealed body, not to the whole-record
            // winner: one peer may only have renamed the snippet while the other changed
            // its secret.
            SwiftSemantics.set(mergedX, VAULT_CONTENT_HASH, SwiftSemantics.get(contentSource.x, VAULT_CONTENT_HASH))
            SwiftSemantics.set(mergedX, VAULT_KEY_ID, SwiftSemantics.get(contentSource.x, VAULT_KEY_ID))
        } else {
            SwiftSemantics.set(mergedX, VAULT_CONTENT_HASH, null)
            SwiftSemantics.set(mergedX, VAULT_KEY_ID, null)
        }
        if (secureVariant != null) SwiftSemantics.set(mergedX, secureVariant.first, secureVariant.second)

        val survivor = SyncEnvelope(
            id = local.id, hlc = SwiftSemantics.max(local.hlc, remote.hlc), origin = winner.origin,
            secure = contentSource.secure, deleted = false, fields = merged, x = mergedX,
        )
        ConflictCopies.validateContentConflictExtensions(survivor)
        for (copy in conflictCopies) ConflictCopies.validateContentConflictExtensions(copy)
        return Outcome(survivor, conflictCopies.sortedWith { first, second -> ConflictCopies.idOrder.compare(first.id, second.id) })
    }

    /**
     * Whether a side moved away from the ancestor: its envelope hash differs. With no
     * ancestor anything present counts as a change, which is the direction that keeps data.
     */
    private fun changed(envelope: SyncEnvelope, base: SyncEnvelope?): Boolean {
        if (base == null) return true
        return base.envelopeHash() != envelope.envelopeHash()
    }

    private fun contentKey(envelope: SyncEnvelope, fields: SyncEnvelope.Fields): String {
        if (envelope.secure) {
            val keyedHash = SwiftSemantics.get(envelope.x, VAULT_CONTENT_HASH)?.textOrNull
            if (keyedHash != null) {
                val vault = SwiftSemantics.get(envelope.x, VAULT_KEY_ID)?.textOrNull ?: "legacy"
                return "secure:$vault:$keyedHash"
            }
        }
        val digest = envelope.contentHash ?: SyncEnvelope.sha256Hex(fields.content)
        return if (envelope.secure) "secure:legacy:$digest" else "plain:$digest"
    }

    private fun outranksOrEqual(first: SyncEnvelope, second: SyncEnvelope): Boolean {
        if (SwiftSemantics.envelopesEqual(first, second)) return true
        return outranks(first, second)
    }

    private fun outranks(first: SyncEnvelope, second: SyncEnvelope): Boolean {
        if (first.hlc != second.hlc) return first.hlc > second.hlc

        val left = rankBytes(first)
        val right = rankBytes(second)
        val order = compareUnsigned(left, right)
        left.fill(0)
        right.fill(0)
        // Equal ranks: only the independently unionable conflict members were left out,
        // their keys are derived from their content, so choosing either side cannot
        // change a user field.
        return order < 0
    }

    private fun rankBytes(envelope: SyncEnvelope): ByteArray {
        val x = LinkedHashMap<String, JsonValue>()
        for ((key, value) in envelope.x) if (!ConflictCopies.isContentConflictExtension(key)) x[key] = value
        return SyncEnvelope(
            id = envelope.id, hlc = envelope.hlc, origin = envelope.origin, secure = envelope.secure,
            deleted = envelope.deleted, fields = envelope.fields, x = x, schemaVersion = envelope.schemaVersion,
        ).canonicalBytes()
    }

    // `Data.lexicographicallyPrecedes`: unsigned bytes, a proper prefix first.
    private fun compareUnsigned(first: ByteArray, second: ByteArray): Int {
        val common = minOf(first.size, second.size)
        for (index in 0 until common) {
            val difference = (first[index].toInt() and 0xFF) - (second[index].toInt() and 0xFF)
            if (difference != 0) return difference
        }
        return first.size - second.size
    }

    private fun refuseDeletionIfConflictIsUnresolved(envelope: SyncEnvelope?) {
        if (ConflictCopies.hasUnresolvedContentConflict(envelope)) throw MergeFailure.UnresolvedContentConflictDeletion()
    }
}
