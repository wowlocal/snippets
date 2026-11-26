package com.khm.snippets.core.merge

import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText

/**
 * The per-field three-way rules shared by the local-file merge and the cross-device
 * merge (`mergeScalar` and `mergeTags` in `SyncMerge.swift`). Pure; no clock, no device
 * identity.
 *
 * When only one side moved a field away from the ancestor, that side is right and
 * [localWins] is never read. It decides only a field both sides changed, or a field with
 * no ancestor to say who changed it.
 */
object FieldMerge {

    /** `mergeScalar` for a flag. */
    fun mergeScalar(base: Boolean?, local: Boolean, remote: Boolean, localWins: Boolean): Boolean {
        if (local == remote) return local
        if (base != null && local == base) return remote
        if (base != null && remote == base) return local
        return if (localWins) local else remote
    }

    /**
     * `mergeScalar` for a text field. "Equal" is Swift's string equality, canonical
     * equivalence: `é` typed as one scalar and as `e` + U+0301 is the same name. The
     * result is always one of the two arguments, in its own spelling; when both sides
     * agree it is [local]'s.
     */
    fun mergeScalar(base: String?, local: String, remote: String, localWins: Boolean): String {
        if (FoundationText.canonicalEquals(local, remote)) return local
        if (base != null && FoundationText.canonicalEquals(local, base)) return remote
        if (base != null && FoundationText.canonicalEquals(remote, base)) return local
        return if (localWins) local else remote
    }

    /**
     * Three-way set merge of tags (`mergeTags`). A tag's identity is its
     * [SnippetTagging.filterKey], so `Work` and `work` are one tag.
     *
     * With an ancestor: the tags neither side removed stay in the ancestor's order, each
     * in the winning side's spelling (else the other side's, else the ancestor's); then
     * the tags either side added, in ascending key order, again in the winner's spelling
     * first. Without an ancestor nothing can prove a removal: the winner's list as it
     * stands, then what only the other side has. Either way the result goes through
     * [SnippetTagging.normalizedTags].
     *
     * ## The order of added tags
     *
     * Swift sorts the added keys with `Set<String>.sorted()`, that is with its string
     * `<`. This sorts them with [FoundationText.order], the scalar order of the
     * normalized keys. For keys in Normalization Form C, which is every key that comes
     * from text typed on a keyboard, the two are the same order, and the vectors and the
     * Swift differential check pin that. For some keys that Foundation's fold returns
     * unnormalized, Swift's `<` is not an order at all and two launches of one Apple
     * build can return the added tags in either order (see [FoundationText.compare]).
     *
     * ## Tag order does not always converge, in Swift either
     *
     * The tags that were already in [base] keep [base]'s order, even when only one side
     * reordered them. A device that merges the result of its own edit therefore keeps its
     * own order: two devices that added tags concurrently can end up holding the same
     * tags in two orders, and each merge of the other's version restores its own. The
     * shipping Swift engine rewrites such a record every round, for plain ASCII tags
     * (`base ["work"]`, one side `["work", "urgent"]`, the other `["work", "draft"]`;
     * the `converge` cases of `fixtures/merge/differential-sample.json`). This port
     * keeps that behaviour, because changing it would change synced bytes for ordinary
     * input. An order that differs between Swift and this function for unnormalized
     * keys is one more way into the same loop, not a new kind of failure.
     */
    fun mergeTags(base: List<String>?, local: List<String>, remote: List<String>, localWins: Boolean): List<String> {
        val localKeys = local.map(SnippetTagging::filterKey)
        val remoteKeys = remote.map(SnippetTagging::filterKey)

        val preferred = if (localWins) local else remote
        val preferredKeys = if (localWins) localKeys else remoteKeys
        val other = if (localWins) remote else local
        val otherKeys = if (localWins) remoteKeys else localKeys

        // With no ancestor everything counts as added, and sorting the whole list would
        // reorder every hand-ordered tag list on the first merge.
        if (base == null) {
            val have = preferredKeys.toHashSet()
            val combined = ArrayList<String>(preferred.size + other.size)
            combined.addAll(preferred)
            for (index in other.indices) if (otherKeys[index] !in have) combined.add(other[index])
            return SnippetTagging.normalizedTags(combined)
        }

        val baseKeys = base.map(SnippetTagging::filterKey)
        val baseSet = baseKeys.toHashSet()
        val localSet = localKeys.toHashSet()
        val remoteSet = remoteKeys.toHashSet()

        fun spelling(key: String): String? {
            val preferredIndex = preferredKeys.indexOf(key)
            if (preferredIndex >= 0) return preferred[preferredIndex]
            val otherIndex = otherKeys.indexOf(key)
            return if (otherIndex >= 0) other[otherIndex] else null
        }

        val ordered = ArrayList<String>(base.size + local.size + remote.size)
        // Kept: in the ancestor and on both sides, in the ancestor's order.
        for (index in base.indices) {
            val key = baseKeys[index]
            if (key in localSet && key in remoteSet) ordered.add(spelling(key) ?: base[index])
        }
        val added = HashSet<String>()
        for (key in localKeys) if (key !in baseSet) added.add(key)
        for (key in remoteKeys) if (key !in baseSet) added.add(key)
        for (key in added.sortedWith(FoundationText.order)) {
            ordered.add(spelling(key) ?: continue)
        }
        return SnippetTagging.normalizedTags(ordered)
    }
}
