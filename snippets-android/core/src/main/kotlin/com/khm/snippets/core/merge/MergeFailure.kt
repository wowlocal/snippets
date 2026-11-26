package com.khm.snippets.core.merge

/**
 * What the merge layer refuses. The first two are Swift's `SyncMerge.EnvelopeFailure`;
 * the other two exist only here and are stated at their declarations.
 *
 * Canonical JSON failures are not wrapped: where Swift lets a `CanonicalJSON.Failure`
 * escape from `mergeEnvelopeOutcome` (a number in `x` that is not finite, a body that is
 * not UTF-8), the same [com.khm.snippets.core.canonical.CanonicalJson.Failure] escapes here.
 *
 * The engine treats every one of these as "stop without applying anything"
 * (`localLibraryQuarantined` in Swift). No message carries any snippet text.
 *
 * Instances compare by case.
 */
sealed class MergeFailure(message: String) : Exception(message) {

    /**
     * `EnvelopeFailure.malformedContentConflict`: a reserved conflict member is not what
     * this build wrote or can preserve, an input or an output is over the wire budget, or
     * a losing body cannot be turned into a copy or a variant.
     */
    class MalformedContentConflict :
        MergeFailure("a content-conflict snapshot is malformed or cannot be preserved safely")

    /**
     * `EnvelopeFailure.unresolvedContentConflictDeletion`: a tombstone would win over a
     * record that still carries a losing body nobody has filed yet.
     */
    class UnresolvedContentConflictDeletion :
        MergeFailure("the unresolved content conflicts must be preserved before this record is deleted")

    /**
     * Base, local and remote do not all describe one record.
     *
     * **Not in Swift**, which merges such a triple as if the ids agreed (the survivor
     * takes the local id). Linux refuses it (`Failure::MismatchedIdentity` in
     * `snippets-linux/src/merge.rs`), and so does this port: every caller looks the three
     * up by one id, so a mismatch is a bug upstream and merging through it would file one
     * record's body under another's id.
     */
    class MismatchedIdentity : MergeFailure("the records to merge have different identities")

    /**
     * A conflict copy has to be named after its losing version's `updatedAt`, and that
     * time is outside the range this port formats: 1582-10-15 00:00 UTC to 9999-12-31
     * 23:59 UTC, or not a number.
     *
     * **Not in Swift**, whose `DateFormatter` prints something for these. Measured with
     * the merge differential (`tools/swift-interop/checks/merge-differential`): the
     * Julian calendar before the cutover (one millisecond before it is `1582-10-04
     * 23:59`; proleptic Gregorian 0001-01-01 is `0001-01-03`), five digits after 9999
     * (`10000-01-01 00:00`), and an empty stamp for ±10^15 s. None of
     * that is pinned by a vector, and the name is a synced field, so guessing would
     * publish bytes an Apple device might spell differently. Linux refuses too, for
     * values its date library cannot hold (`conflict_name` in `merge.rs`).
     */
    class UnrepresentableConflictDate :
        MergeFailure("the losing version's modification time cannot be written into a conflict-copy name")

    override fun equals(other: Any?): Boolean = other != null && other.javaClass == javaClass

    override fun hashCode(): Int = javaClass.hashCode()
}
