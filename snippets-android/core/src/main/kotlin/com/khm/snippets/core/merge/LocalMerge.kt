package com.khm.snippets.core.merge

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.DeterministicUuid
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID

/**
 * Three-way merge of the snippet array in memory against what another writer put on disk,
 * and the rebase of an undo snapshot onto the result (`mergeLocal`, `rebaseSnapshot` and
 * their helpers in `SyncMerge.swift`). No clocks of its own, no device identity.
 *
 * The field rules are [FieldMerge]'s. What differs from the cross-device merge
 * ([EnvelopeMerge]): a record missing on one side **is** a deletion when the ancestor
 * proves it was there and the other side left it alone; the rank is `updatedAt` and then
 * a digest of the payload; and a merge that leaves two live snippets with one keyword
 * disables one of them.
 *
 * Nothing here is synced or hashed by another device, so only determinism matters, not
 * byte equality with another platform. It still follows the Swift code decision for
 * decision.
 */
object LocalMerge {

    /** What a merge produced (`SyncMerge.Outcome`). */
    class Outcome(
        snippets: List<Snippet>,
        conflictCopies: List<Snippet>,
        disabledByKeywordCollision: List<UUID>,
    ) {
        /** The merged library: surviving records in local order, then records only the other side had, then conflict copies by id text. */
        val snippets: List<Snippet> = Collections.unmodifiableList(ArrayList(snippets))

        /** Losing bodies of content conflicts, as disabled copies, sorted by id text. They are also in [snippets]. */
        val conflictCopies: List<Snippet> = Collections.unmodifiableList(ArrayList(conflictCopies))

        /** Records disabled because the merge left two live snippets sharing a keyword, in the order they were disabled. */
        val disabledByKeywordCollision: List<UUID> = Collections.unmodifiableList(ArrayList(disabledByKeywordCollision))

        /**
         * Whether the merge took an action the user should be told about. Not "did
         * anything change": an ordinary merge changes plenty and needs no announcement,
         * and the result must be persisted either way.
         */
        val needsUserAttention: Boolean
            get() = conflictCopies.isNotEmpty() || disabledByKeywordCollision.isNotEmpty()
    }

    /**
     * Whether two snippets are the same as far as the user is concerned: name, keyword,
     * content, tags and the two flags. `createdAt` and `updatedAt` are bookkeeping; a
     * save that only moved `updatedAt` is not an edit and must not outrank a deletion.
     */
    fun payloadEquals(first: Snippet, second: Snippet): Boolean =
        FoundationText.canonicalEquals(first.name, second.name) &&
            FoundationText.canonicalEquals(first.keyword, second.keyword) &&
            FoundationText.canonicalEquals(first.content, second.content) &&
            first.tags.size == second.tags.size &&
            first.tags.indices.all { FoundationText.canonicalEquals(first.tags[it], second.tags[it]) } &&
            first.isEnabled == second.isEnabled &&
            first.isPinned == second.isPinned

    /**
     * Merges the in-memory library against what another writer put on disk.
     *
     * @param base the library this process last saw on disk: the common ancestor.
     * @param local the library in memory.
     * @param remote the library on disk now.
     *
     * An id that occurs twice in one list counts once, as its first occurrence.
     *
     * @throws MergeFailure.UnrepresentableConflictDate when a conflict copy cannot be
     *   named. Not in Swift, which never fails here.
     */
    @Throws(MergeFailure::class)
    fun mergeLocal(base: List<Snippet>, local: List<Snippet>, remote: List<Snippet>): Outcome {
        val baseById = firstById(base)
        val localById = firstById(local)
        val remoteById = firstById(remote)

        val merged = HashMap<UUID, Snippet>()
        val conflictCopies = ArrayList<Snippet>()
        val ids = LinkedHashSet<UUID>(baseById.keys)
        ids.addAll(localById.keys)
        ids.addAll(remoteById.keys)
        for (id in ids) {
            val (survivor, copy) = mergeRecord(baseById[id], localById[id], remoteById[id])
            if (survivor != null) merged[id] = survivor
            if (copy != null) conflictCopies.add(copy)
        }
        // Swift walks a set here, so the order has to be made, not inherited.
        conflictCopies.sortWith { first, second -> ConflictCopies.idOrder.compare(first.id, second.id) }

        // Copies go in after the main pass, so a copy is never taken for an ancestor of
        // a record in it. A copy whose id is already taken replaces that record, as in Swift.
        for (copy in conflictCopies) merged[copy.id] = copy

        val ordered = orderedResult(merged, local, remote)

        // Only records this merge created or changed can be disabled. A duplicate
        // keyword that already existed in `local` and was not touched is the editor's
        // warning to show, not the merge's rule to enforce.
        val touched = HashSet<UUID>()
        for (copy in conflictCopies) touched.add(copy.id)
        for (record in ordered) {
            val mine = localById[record.id]
            if (mine == null || !payloadEquals(mine, record)) touched.add(record.id)
        }
        val disabled = resolveKeywordCollisionsInPlace(ordered, touched)

        return Outcome(ordered, conflictCopies, disabled)
    }

    /**
     * Rebases an undo or redo snapshot onto a merged library. **Not a merge**: an undo
     * entry is a stated intent, "put the library back to exactly this", not a competing
     * edit, and merging it would mint a conflict copy for a plain sequence of edits.
     *
     * Only what the snapshot changes relative to the state it was captured against is
     * replayed: records it deleted stay deleted, records it changed or re-added take its
     * value, and everything else is [merged]'s. A record the snapshot merely carries
     * along is never re-added, so undo cannot bring back a snippet that has since moved
     * into the vault.
     */
    fun rebaseSnapshot(snapshot: List<Snippet>, capturedAgainst: List<Snippet>, merged: List<Snippet>): List<Snippet> {
        val capturedById = firstById(capturedAgainst)
        val snapshotById = firstById(snapshot)

        // What this snapshot means, expressed against its own baseline.
        val changedByUndo = HashMap<UUID, Snippet>()
        for ((id, value) in snapshotById) {
            val captured = capturedById[id]
            if (captured == null || !payloadEquals(captured, value)) changedByUndo[id] = value
        }

        val out = ArrayList<Snippet>(merged.size)
        val emitted = HashSet<UUID>()
        for (record in merged) {
            if (record.id in capturedById && record.id !in snapshotById) continue   // deleted by the undo
            emitted.add(record.id)
            out.add(changedByUndo[record.id] ?: record)
        }
        // Records the undo brings back, not ones it merely carries along.
        for (record in snapshot) {
            if (record.id !in emitted && record.id in changedByUndo) out.add(record)
        }
        return out
    }

    /**
     * Resolves one record: the survivor, or `null` if it should not exist, and the losing
     * side as a conflict copy when both sides changed the content (`mergeRecord`).
     */
    @Throws(MergeFailure::class)
    fun mergeRecord(base: Snippet?, local: Snippet?, remote: Snippet?): Pair<Snippet?, Snippet?> {
        if (local == null && remote == null) return Pair(null, null)
        if (local == null) {
            // Missing locally. A deletion only if the ancestor proves we had it and the
            // other side left it untouched; otherwise the other side is ahead of us, or
            // edited what we deleted, and an edit beats a delete.
            return if (base != null && payloadEquals(base, remote!!)) Pair(null, null) else Pair(remote, null)
        }
        if (remote == null) {
            return if (base != null && payloadEquals(base, local)) Pair(null, null) else Pair(local, null)
        }
        if (payloadEquals(local, remote)) {
            // Same content on both sides. Keep the later timestamp so the record does
            // not appear to travel backwards.
            return Pair(
                local.copy(
                    createdAt = SwiftSemantics.min(local.createdAt, remote.createdAt),
                    updatedAt = SwiftSemantics.max(local.updatedAt, remote.updatedAt),
                ),
                null,
            )
        }

        val localWins = localOutranksRemote(local, remote)
        val (content, copy) = mergeContent(base, local, remote, localWins)
        val survivor = local.copy(
            name = FieldMerge.mergeScalar(base?.name, local.name, remote.name, localWins),
            keyword = FieldMerge.mergeScalar(base?.keyword, local.keyword, remote.keyword, localWins),
            isEnabled = FieldMerge.mergeScalar(base?.isEnabled, local.isEnabled, remote.isEnabled, localWins),
            isPinned = FieldMerge.mergeScalar(base?.isPinned, local.isPinned, remote.isPinned, localWins),
            tags = FieldMerge.mergeTags(base?.tags, local.tags, remote.tags, localWins),
            // Creation never moves forward and modification never moves backward.
            createdAt = SwiftSemantics.min(local.createdAt, remote.createdAt),
            updatedAt = SwiftSemantics.max(local.updatedAt, remote.updatedAt),
            content = content,
        )
        return Pair(survivor, copy)
    }

    /**
     * Which side outranks the other, computed the same way by both: the later
     * `updatedAt`, and on an exact tie the side whose [payloadDigest] is smaller. The
     * tie-break comes from the data, so mirrored inputs agree whichever process asks.
     */
    fun localOutranksRemote(local: Snippet, remote: Snippet): Boolean {
        if (local.updatedAt != remote.updatedAt) return local.updatedAt > remote.updatedAt
        return payloadDigest(local) < payloadDigest(remote)
    }

    /**
     * Lowercase hex SHA-256 of the six payload fields, each text field written as
     * `<UTF-8 byte count>:<text>` followed by U+0002 (name, keyword, content, then the
     * tags joined with U+0001), then `1` or `0` for enabled and for pinned.
     */
    fun payloadDigest(snippet: Snippet): String {
        val digest = MessageDigest.getInstance("SHA-256")
        for (field in arrayOf(snippet.name, snippet.keyword, snippet.content, snippet.tags.joinToString("\u0001"))) {
            val bytes = Utf8.encode(field)
            digest.update(Utf8.encode(bytes.size.toString()))
            digest.update(':'.code.toByte())
            digest.update(bytes)
            digest.update(2)
        }
        digest.update((if (snippet.isEnabled) '1' else '0').code.toByte())
        digest.update((if (snippet.isPinned) '1' else '0').code.toByte())
        return Bytes.toHex(digest.digest())
    }

    /**
     * The surviving content, and the losing side as a copy when both sides changed it
     * (`mergeContent`). Content is the one field that is never discarded.
     *
     * The copy's id is `deterministicUUID(local.id, "conflict|" + loser.content + "|" +
     * milliseconds since 1970 of loser.updatedAt)`, so repeating the merge mints the same
     * copy and copies never multiply.
     */
    @Throws(MergeFailure::class)
    fun mergeContent(base: Snippet?, local: Snippet, remote: Snippet, localWins: Boolean): Pair<String, Snippet?> {
        if (FoundationText.canonicalEquals(local.content, remote.content)) return Pair(local.content, null)
        if (base != null && FoundationText.canonicalEquals(base.content, local.content)) return Pair(remote.content, null)
        if (base != null && FoundationText.canonicalEquals(base.content, remote.content)) return Pair(local.content, null)

        val winner = if (localWins) local else remote
        val loser = if (localWins) remote else local
        val copy = loser.copy(
            id = conflictCopyId(local.id, loser),
            name = ConflictCopies.conflictName(loser.displayName, loser.updatedAt),
            // Two live snippets may never share a keyword, and the copy must never be
            // reachable by typing.
            keyword = "",
            isEnabled = false,
            isPinned = false,
            tags = SnippetTagging.normalizedTags(loser.tags + "conflict"),
        )
        return Pair(winner.content, copy)
    }

    /**
     * The id of the local-file conflict copy of [loser] in a record with id [recordId]:
     * `deterministicUUID(recordId, "conflict|" + loser.content + "|" + <milliseconds since
     * 1970 of loser.updatedAt, decimal>)`. Only this device mints it, so it need not
     * agree with another platform, but it must be stable: a second merge of the same
     * inputs must not mint a second copy.
     */
    fun conflictCopyId(recordId: UUID, loser: Snippet): UUID =
        DeterministicUuid.make(recordId, "conflict|${loser.content}|${AppleTime.hlcMillis(loser.updatedAt)}")

    /**
     * Disables the losers among enabled snippets that share a keyword, and returns the
     * new list and the ids disabled, in the order they were disabled
     * (`resolveKeywordCollisions`). The keyword itself is never cleared.
     *
     * Keywords are compared by [SnippetTagging.filterKey] of the sanitized keyword; an
     * empty one never collides. Records not in [touched] are walked first, so an
     * untouched record is the incumbent; two untouched records are left alone, because
     * their collision predates the merge. Otherwise the later `updatedAt` wins and an
     * exact tie goes to the smaller id text. With [touched] `null` every record counts
     * as touched.
     */
    fun resolveKeywordCollisions(snippets: List<Snippet>, touched: Set<UUID>? = null): Pair<List<Snippet>, List<UUID>> {
        val working = ArrayList(snippets)
        val disabled = resolveKeywordCollisionsInPlace(working, touched)
        return Pair(working, disabled)
    }

    private fun resolveKeywordCollisionsInPlace(snippets: MutableList<Snippet>, touched: Set<UUID>?): List<UUID> {
        val winners = HashMap<String, Int>()
        val disabled = ArrayList<UUID>()

        fun isTouched(index: Int): Boolean = touched == null || snippets[index].id in touched

        // Incumbents first: untouched records in array order, then touched ones.
        val order = snippets.indices.filter { !isTouched(it) } + snippets.indices.filter { isTouched(it) }

        for (index in order) {
            if (!snippets[index].isEnabled) continue
            val key = SnippetTagging.filterKey(snippets[index].normalizedKeyword)
            if (key.isEmpty()) continue

            val incumbent = winners[key]
            if (incumbent == null) {
                winners[key] = index
                continue
            }
            // Neither side is new: leave it to the editor's keyword warning.
            if (touched != null && !isTouched(index) && !isTouched(incumbent)) continue

            val challenger = snippets[index]
            val holder = snippets[incumbent]
            val challengerWins = if (challenger.updatedAt != holder.updatedAt) {
                challenger.updatedAt > holder.updatedAt
            } else {
                ConflictCopies.idOrder.compare(challenger.id, holder.id) < 0
            }
            val loser = if (challengerWins) incumbent else index
            snippets[loser] = snippets[loser].copy(isEnabled = false)
            disabled.add(snippets[loser].id)
            if (challengerWins) winners[key] = index
        }
        return disabled
    }

    /** Local order first, then anything only the other side had, then the rest (conflict copies) by id text. */
    private fun orderedResult(merged: Map<UUID, Snippet>, local: List<Snippet>, remote: List<Snippet>): MutableList<Snippet> {
        val ordered = ArrayList<Snippet>(merged.size)
        val emitted = HashSet<UUID>()
        for (snippet in local) {
            val survivor = merged[snippet.id] ?: continue
            if (emitted.add(snippet.id)) ordered.add(survivor)
        }
        for (snippet in remote) {
            val survivor = merged[snippet.id] ?: continue
            if (emitted.add(snippet.id)) ordered.add(survivor)
        }
        for (id in merged.keys.sortedWith(ConflictCopies.idOrder)) {
            if (emitted.add(id)) ordered.add(merged.getValue(id))
        }
        return ordered
    }

    private fun firstById(snippets: List<Snippet>): LinkedHashMap<UUID, Snippet> {
        val byId = LinkedHashMap<UUID, Snippet>(snippets.size * 2)
        for (snippet in snippets) if (!byId.containsKey(snippet.id)) byId[snippet.id] = snippet
        return byId
    }
}
