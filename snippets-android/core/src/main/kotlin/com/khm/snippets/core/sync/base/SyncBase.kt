package com.khm.snippets.core.sync.base

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.merge.ConflictCopies
import com.khm.snippets.core.sync.transport.SyncAccountIdentity
import com.khm.snippets.core.sync.transport.SyncCursor
import com.khm.snippets.core.sync.transport.SyncCursorKind
import com.khm.snippets.core.sync.transport.SyncDatasetIdentity
import com.khm.snippets.core.sync.transport.SyncRecordVersion
import com.khm.snippets.core.sync.transport.SyncSubmitOutcome
import com.khm.snippets.core.sync.transport.SyncSubmitResult
import com.khm.snippets.core.wire.SyncEnvelope
import java.util.AbstractMap.SimpleImmutableEntry
import java.util.Collections
import java.util.UUID

/**
 * The last state this device and the backend agreed on: the confirmed merge ancestor
 * (`SyncBase`, stored in a provider's `base.json`).
 *
 * Local changes are found by comparing the library with this value, and the difference
 * is recorded in the journal before the transport is used. Once a journal offer is
 * acknowledged this file is its durability fence: **the base must be durable before the
 * journal may forget the offer.**
 *
 * ## A value
 *
 * Immutable. Every operation returns a new base and leaves this one as it was; the
 * engine changes a copy, writes it, and only then publishes it (see [SyncBaseFile]).
 * Each operation copies the record map once, so apply a batch with the collection forms
 * ([recording], [recordingConfirmed], [foldingAccepted]), not one record at a time: a
 * loop of single-record calls over a 10 000-record page is quadratic.
 *
 * ## What the engine must uphold
 *
 * - **The base records what the backend said, never what was merged.** Recording the
 *   merged value would make the next comparison believe the backend has already seen
 *   this device's side of the merge.
 * - **An envelope and its record version change together** when they come from the same
 *   fetch or save ([recordingConfirmed]). [recording] alone is for ancestry that is not a
 *   server acknowledgement and leaves the version alone.
 * - **A record that was fetched and not applied is neither recorded nor passed by the
 *   cursor**, and the cursor ([adoptingCursor]) moves only after the journal no longer
 *   holds a stale offer.
 * - **Tombstones stay.** A deleted envelope is kept like any other record, for good:
 *   it is what stops a later comparison from reading "not in the library" as "new
 *   here". Nothing here ever drops one.
 * - **Absence is never a delete while [requiresNonDestructiveLibraryMerge] is set.**
 *
 * ## Compared with Swift
 *
 * This app reads and writes only [CURRENT_SCHEMA_VERSION], so the value has no
 * `schemaVersion` member and no `upgradeToCurrentSchema()`. The invariants Swift checks
 * when it encodes are enforced when a base is built, so an inconsistent base cannot
 * exist: the cursor and its kind are paired, the recovery mode is present exactly while
 * the fence is, and a reviewed recovery always has its review id.
 */
class SyncBase private constructor(
    private val confirmed: Map<UUID, Entry>,
    recordVersions: Map<UUID, SyncRecordVersion>,
    /** The backend position these envelopes correspond to. Opaque. */
    val cursor: SyncCursor?,
    /** The protocol family that issued [cursor]; present exactly when [cursor] is. */
    val cursorKind: SyncCursorKind?,
    /**
     * Once `true`, a missing journal is lost protocol state, not a first run. The engine
     * sets it only after `journal.json` is durable and before the first network
     * operation that can create an ambiguous offer.
     */
    val journalEstablished: Boolean,
    /**
     * The account scope that issued [cursor] and [recordVersions]. `null` for a backend
     * without accounts, and for a base that was never bound.
     */
    val accountIdentity: SyncAccountIdentity?,
    /**
     * The physical generation of the remote dataset. Kept apart from [accountIdentity]:
     * routine feed rotation must not look like an account switch, while a replaced
     * dataset must survive a relaunch and stop before anything is pushed.
     */
    val datasetIdentity: SyncDatasetIdentity?,
    /**
     * A crash-safe request to replace the transport's private progress before the next
     * data-plane call. Written only after surviving intent is durable; cleared only after
     * the transport reset succeeded ([completingTransportFullResync]).
     */
    val requiresTransportFullResync: Boolean,
    /**
     * A restored primary library is readable but may be incomplete. While this is `true`
     * the engine must reset to a full merge and must never infer a deletion from
     * absence against the old base. It is written before the quarantine halt is cleared.
     */
    val requiresNonDestructiveLibraryMerge: Boolean,
    /** Present exactly while [requiresNonDestructiveLibraryMerge] is `true`. */
    val nonDestructiveMergeMode: NonDestructiveMergeMode?,
    private val preRecovery: Map<UUID, Entry>?,
    /**
     * The random identity of one explicit Repair or Check Again. Present exactly for a
     * [NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT] fence. Two reviews of identical
     * bytes are still two authority epochs; a crash retry of one review keeps its id.
     */
    val nonDestructiveReviewId: UUID?,
) {

    enum class NonDestructiveMergeMode(val rawValue: String) {
        /**
         * Every absence is uncertain and must be recovered from the journal or the
         * backend, never read as a new local deletion.
         */
        INCOMPLETE_PRIMARY("incompletePrimary"),

        /**
         * [envelopes] is the exact primary snapshot accepted by Repair or Check Again.
         * Later changes to the library are authoritative local intent, even before the
         * first fetch.
         */
        REVIEWED_LOCAL_SNAPSHOT("reviewedLocalSnapshot");

        companion object {
            fun fromRawValue(rawValue: String): NonDestructiveMergeMode? = entries.firstOrNull { it.rawValue == rawValue }
        }
    }

    /** An envelope with the backend generation the same fetch or save returned for it. */
    data class Confirmation(val envelope: SyncEnvelope, val recordVersion: SyncRecordVersion?)

    /** The result of [foldingAccepted]. */
    class FoldedSubmission(
        val base: SyncBase,
        /** The ids whose acceptance was recorded, in the order the backend reported them. */
        val acceptedIds: Set<UUID>,
    )

    /** Every record as last agreed, tombstones included. Unmodifiable. */
    val envelopes: Map<UUID, SyncEnvelope> = EnvelopeView(confirmed)

    /**
     * The backend generation paired with each confirmed envelope. An entry may outlive
     * its envelope while a transport-key change is staged: the payload has to be sealed
     * again, and the generation is what stops that from overwriting an independent
     * remote edit. Unmodifiable.
     */
    val recordVersions: Map<UUID, SyncRecordVersion> = recordVersions

    /**
     * The readable confirmed ancestor from just before a checkpoint Repair. `null` means
     * the recovery cannot trust old absences; an empty map is a known-empty ancestor and
     * is not the same. Only a reviewed recovery has one.
     */
    val preRecoveryConfirmedEnvelopes: Map<UUID, SyncEnvelope>? = preRecovery?.let(::EnvelopeView)

    fun envelope(id: UUID): SyncEnvelope? = confirmed[id]?.envelope

    fun recordVersion(id: UUID): SyncRecordVersion? = recordVersions[id]

    /** Whether the fence is the reviewed kind, which is what gives the base a review id. */
    val isReviewedRecovery: Boolean
        get() = requiresNonDestructiveLibraryMerge &&
            nonDestructiveMergeMode == NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT

    /**
     * Whether the base holds anything that only means something inside the scope that
     * issued it: a cursor, an envelope or a record version. The engine adds the journal's
     * entries and dependencies to decide whether a checkpoint without a binding may be
     * bound silently.
     */
    val holdsCheckpointFacts: Boolean
        get() = cursor != null || confirmed.isNotEmpty() || recordVersions.isNotEmpty()

    // Ancestry

    /**
     * Updates ancestry without touching the record's backend generation (`record`): for
     * projection overlays and anything that is not a server acknowledgement.
     */
    fun recording(envelope: SyncEnvelope): SyncBase = recording(listOf(envelope))

    /** [recording] for a batch; a later envelope of the same id replaces an earlier one. */
    fun recording(envelopes: Iterable<SyncEnvelope>): SyncBase {
        val next = HashMap(confirmed)
        for (envelope in envelopes) put(next, envelope)
        return with(confirmed = next)
    }

    /**
     * Pairs the exact server payload with the generation the same fetch or save returned
     * (`recordConfirmed`). A `null` [recordVersion] removes a stale generation on
     * purpose; a transport that enforces compare-and-swap never confirms without one.
     */
    fun recordingConfirmed(envelope: SyncEnvelope, recordVersion: SyncRecordVersion?): SyncBase =
        recordingConfirmed(listOf(Confirmation(envelope, recordVersion)))

    /**
     * [recordingConfirmed] for a fetched page or a submission, in order: the last
     * confirmation of an id wins, as the backend's last generation does.
     */
    fun recordingConfirmed(confirmations: Iterable<Confirmation>): SyncBase {
        val nextConfirmed = HashMap(confirmed)
        val nextVersions = HashMap(recordVersions)
        for ((envelope, recordVersion) in confirmations) {
            put(nextConfirmed, envelope)
            if (recordVersion == null) nextVersions.remove(envelope.id) else nextVersions[envelope.id] = recordVersion
        }
        return with(confirmed = nextConfirmed, recordVersions = nextVersions)
    }

    /**
     * Records the accepted part of a submission (`SyncEngine`, after `submit`).
     *
     * Outcomes are matched to [offered] by id, never by position, and an outcome for an
     * id that was not offered is ignored, not trusted. Rejections change nothing here.
     * Only now is a record agreed: recording it before the backend accepted it would
     * make the next comparison skip it for good.
     *
     * The engine writes the returned base before the journal acknowledges
     * [FoldedSubmission.acceptedIds].
     */
    fun foldingAccepted(offered: Map<UUID, SyncEnvelope>, results: List<SyncSubmitResult>): FoldedSubmission {
        val accepted = ArrayList<Confirmation>()
        val acceptedIds = LinkedHashSet<UUID>()
        for (result in results) {
            val outcome = result.outcome as? SyncSubmitOutcome.Accepted ?: continue
            val envelope = offered[result.id] ?: continue
            accepted.add(Confirmation(envelope, outcome.recordVersion))
            acceptedIds.add(result.id)
        }
        val base = if (accepted.isEmpty()) this else recordingConfirmed(accepted)
        return FoldedSubmission(base, Collections.unmodifiableSet(acceptedIds))
    }

    fun removingRecordVersion(id: UUID): SyncBase {
        if (!recordVersions.containsKey(id)) return this
        return with(recordVersions = HashMap(recordVersions).apply { remove(id) })
    }

    /**
     * Keeps only the record versions of [ids]. A generation is a credential to replace
     * the remote record; one left behind without its envelope or journal entry would be
     * inherited by an unrelated record created later under the same id.
     */
    fun retainingRecordVersions(ids: Set<UUID>): SyncBase =
        with(recordVersions = recordVersions.filterKeys { it in ids })

    /**
     * Replaces every envelope by [transform]'s result and drops those it returns `null`
     * for. The result must keep the record's id.
     */
    fun mappingEnvelopes(transform: (SyncEnvelope) -> SyncEnvelope?): SyncBase {
        val next = HashMap<UUID, Entry>(confirmed.size * 2)
        for ((id, entry) in confirmed) {
            val mapped = transform(entry.envelope) ?: continue
            require(mapped.id == id) { "an envelope cannot change its id" }
            next[id] = if (mapped === entry.envelope) entry else Entry(mapped)
        }
        return with(confirmed = next)
    }

    // Checkpoint

    /**
     * Moves the fetch position (`adoptCursor`). `null` forgets it, and its kind with it;
     * a cursor without a kind is [SyncCursorKind.LEGACY].
     *
     * The engine calls this last in a round: after the fetched envelopes and the
     * resolved journal are durable, and only when nothing fetched was left unapplied.
     * The transport's `acknowledgeFetched` follows this write, never precedes it.
     */
    fun adoptingCursor(cursor: SyncCursor?, kind: SyncCursorKind?): SyncBase =
        with(cursor = Slot(cursor), cursorKind = Slot(kind))

    /** Records that `journal.json` exists and is durable. */
    fun establishingJournal(): SyncBase = if (journalEstablished) this else with(journalEstablished = true)

    /**
     * Binds the base to the scope the transport resolved before the round's first
     * data-plane call. The engine does this silently only for a base that holds no
     * checkpoint facts, or whose stored identity the transport names as a legacy
     * spelling of the same scope; every other difference is a halt.
     */
    fun binding(accountIdentity: SyncAccountIdentity?, datasetIdentity: SyncDatasetIdentity?): SyncBase =
        with(accountIdentity = Slot(accountIdentity), datasetIdentity = Slot(datasetIdentity))

    /** Sets or clears the request for a transport reset before the next data-plane call. */
    fun requiringTransportFullResync(required: Boolean = true): SyncBase =
        if (requiresTransportFullResync == required) this else with(requiresTransportFullResync = required)

    /** The transport reset succeeded. */
    fun completingTransportFullResync(): SyncBase = requiringTransportFullResync(false)

    // Recovery

    /**
     * The review id a Check Again must continue with: the id of a reviewed fence that is
     * already durable. A crash after the base was written and before the quarantine
     * marker was retired must resume the same review, not start a second one.
     */
    val resumableReviewId: UUID? get() = if (isReviewedRecovery) nonDestructiveReviewId else null

    /**
     * The base that commits a reviewed primary-library recovery (`SyncEngine`, Check
     * Again with a quarantine): [reviewed] becomes the ancestor as a witness of local
     * edits and deletions, not as backend confirmation, so every record version and the
     * cursor go; the reviewed fence is raised with [reviewId] (the quarantine marker's);
     * old confirmed absences are not kept as an ancestor, because a restored export may
     * be incomplete. The scope binding and [journalEstablished] stay.
     *
     * The engine writes this before it clears the quarantine halt and removes the marker.
     *
     * @throws IllegalArgumentException when an entry of [reviewed] is not keyed by its own id.
     */
    fun reviewingRecoveredPrimary(reviewed: Map<UUID, SyncEnvelope>, reviewId: UUID): SyncBase = build(
        confirmed = entries(reviewed, confirmed),
        recordVersions = emptyMap(),
        cursor = null,
        cursorKind = null,
        journalEstablished = journalEstablished,
        accountIdentity = accountIdentity,
        datasetIdentity = datasetIdentity,
        requiresTransportFullResync = false,
        requiresNonDestructiveLibraryMerge = true,
        nonDestructiveMergeMode = NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT,
        preRecovery = null,
        nonDestructiveReviewId = reviewId,
    )

    /**
     * The base that stages a change of the transport key (`SyncCoordinator`): every
     * record has to be sealed again, so the envelopes go (unless a recovery fence still
     * needs them as its reviewed snapshot) and the cursor goes, while the record versions
     * stay: a backend generation does not depend on the payload key, and it is what lets
     * the resealed value replace old ciphertext without overwriting an independent
     * remote edit. A full transport resync is requested, unless the fence already
     * implies one.
     *
     * The coordinator writes the journal first, then this.
     */
    fun stagingTransportRekey(): SyncBase = build(
        confirmed = if (requiresNonDestructiveLibraryMerge) confirmed else emptyMap(),
        recordVersions = recordVersions,
        cursor = null,
        cursorKind = null,
        journalEstablished = true,
        accountIdentity = accountIdentity,
        datasetIdentity = datasetIdentity,
        requiresTransportFullResync = !requiresNonDestructiveLibraryMerge,
        requiresNonDestructiveLibraryMerge = requiresNonDestructiveLibraryMerge,
        nonDestructiveMergeMode = nonDestructiveMergeMode,
        preRecovery = preRecovery,
        nonDestructiveReviewId = nonDestructiveReviewId,
    )

    // Derived

    /**
     * What this device has that the base has not seen (`pendingChanges(from:)`): every
     * record of [current] whose envelope hash differs from the base's, and a tombstone
     * for every live base record that [current] no longer holds. The engine itself
     * pushes what the journal says is pending; this is the base-only comparison.
     *
     * Compared by hash, not by clock: a record that is byte-identical to the base needs
     * no push however often it was saved again.
     *
     * Tombstone rules: a base record that is already a tombstone yields nothing; a live
     * one that is missing locally yields its own tombstone, with the base's clock and
     * origin and without `x`; and a live one for which [holdsUnresolvedContentConflict]
     * is `true` yields nothing, because a tombstone carries no content and the only copy
     * of a losing secure body may still be inside that envelope.
     *
     * @param holdsUnresolvedContentConflict the merge layer's test for a pending
     *   content-conflict extension (`SyncMerge.hasUnresolvedContentConflict`).
     * @return in ascending order of the id's uppercase text form (Swift's `uuidString`),
     *   so two runs push the same batch.
     */
    fun pendingChanges(
        current: Map<UUID, SyncEnvelope>,
        holdsUnresolvedContentConflict: (SyncEnvelope) -> Boolean = ConflictCopies::hasUnresolvedContentConflict,
    ): List<SyncEnvelope> {
        val pending = ArrayList<SyncEnvelope>()
        for ((id, candidate) in current) {
            val known = confirmed[id]
            if (known == null || known.hashOrNull() != hashOrNull(candidate)) pending.add(candidate)
        }
        for ((id, entry) in confirmed) {
            val known = entry.envelope
            if (known.deleted || current.containsKey(id)) continue
            if (holdsUnresolvedContentConflict(known)) continue
            pending.add(known.tombstoned(known.hlc, known.origin))
        }
        pending.sortBy { Uuids.uppercase(it.id) }
        return pending
    }

    /**
     * A stable local identity for an exact reviewed recovery snapshot, or `null` without
     * a reviewed fence (`nonDestructiveReviewFingerprint`). Journal entries are bound to
     * it. It holds no user text: lowercase hex SHA-256 over the review id, the ids and
     * envelope hashes of [envelopes], and those of [preRecoveryConfirmedEnvelopes] or
     * the word `unknown`.
     */
    fun nonDestructiveReviewFingerprint(): String? {
        if (!isReviewedRecovery) return null
        fun component(values: Map<UUID, Entry>): String =
            values.keys.map(Uuids::lowercase).sorted().joinToString("|") { key ->
                val hash = values.getValue(UUID.fromString(key)).hashOrNull() ?: "invalid"
                "${key.length}:$key${hash.length}:$hash"
            }
        val prior = preRecovery?.let(::component) ?: "unknown"
        val snapshot = "reviewed:${component(confirmed)}|prior:$prior"
        val material = nonDestructiveReviewId?.let { "review-id:${Uuids.lowercase(it)}|$snapshot" } ?: snapshot
        return SyncEnvelope.sha256Hex(Utf8.encode(material))
    }

    // Building

    /**
     * This base with some members replaced, and then put in order as [invoke] does: a
     * removed cursor takes its kind with it, a lowered fence its mode and review id.
     *
     * @throws IllegalArgumentException as [invoke].
     */
    fun copy(
        envelopes: Map<UUID, SyncEnvelope> = this.envelopes,
        recordVersions: Map<UUID, SyncRecordVersion> = this.recordVersions,
        cursor: SyncCursor? = this.cursor,
        cursorKind: SyncCursorKind? = this.cursorKind,
        journalEstablished: Boolean = this.journalEstablished,
        accountIdentity: SyncAccountIdentity? = this.accountIdentity,
        datasetIdentity: SyncDatasetIdentity? = this.datasetIdentity,
        requiresTransportFullResync: Boolean = this.requiresTransportFullResync,
        requiresNonDestructiveLibraryMerge: Boolean = this.requiresNonDestructiveLibraryMerge,
        nonDestructiveMergeMode: NonDestructiveMergeMode? = this.nonDestructiveMergeMode,
        preRecoveryConfirmedEnvelopes: Map<UUID, SyncEnvelope>? = this.preRecoveryConfirmedEnvelopes,
        nonDestructiveReviewId: UUID? = this.nonDestructiveReviewId,
    ): SyncBase = build(
        confirmed = if (envelopes === this.envelopes) confirmed else entries(envelopes, confirmed),
        recordVersions = if (recordVersions === this.recordVersions) recordVersions else frozen(recordVersions),
        cursor = cursor,
        cursorKind = cursorKind,
        journalEstablished = journalEstablished,
        accountIdentity = accountIdentity,
        datasetIdentity = datasetIdentity,
        requiresTransportFullResync = requiresTransportFullResync,
        requiresNonDestructiveLibraryMerge = requiresNonDestructiveLibraryMerge,
        nonDestructiveMergeMode = nonDestructiveMergeMode,
        preRecovery = when {
            preRecoveryConfirmedEnvelopes == null -> null
            preRecoveryConfirmedEnvelopes === this.preRecoveryConfirmedEnvelopes -> preRecovery
            else -> entries(preRecoveryConfirmedEnvelopes, preRecovery ?: emptyMap())
        },
        nonDestructiveReviewId = nonDestructiveReviewId,
    )

    // A replaced member, so that `null` can be a new value and not "unchanged".
    private class Slot<T>(val value: T)

    private fun with(
        confirmed: Map<UUID, Entry> = this.confirmed,
        recordVersions: Map<UUID, SyncRecordVersion> = this.recordVersions,
        cursor: Slot<SyncCursor?> = Slot(this.cursor),
        cursorKind: Slot<SyncCursorKind?> = Slot(this.cursorKind),
        journalEstablished: Boolean = this.journalEstablished,
        accountIdentity: Slot<SyncAccountIdentity?> = Slot(this.accountIdentity),
        datasetIdentity: Slot<SyncDatasetIdentity?> = Slot(this.datasetIdentity),
        requiresTransportFullResync: Boolean = this.requiresTransportFullResync,
    ): SyncBase = build(
        confirmed = confirmed,
        recordVersions = if (recordVersions === this.recordVersions) recordVersions else frozen(recordVersions),
        cursor = cursor.value,
        cursorKind = cursorKind.value,
        journalEstablished = journalEstablished,
        accountIdentity = accountIdentity.value,
        datasetIdentity = datasetIdentity.value,
        requiresTransportFullResync = requiresTransportFullResync,
        requiresNonDestructiveLibraryMerge = requiresNonDestructiveLibraryMerge,
        nonDestructiveMergeMode = nonDestructiveMergeMode,
        preRecovery = preRecovery,
        nonDestructiveReviewId = nonDestructiveReviewId,
    )

    // Encoding support for the codec

    /** `envelopes` as the file stores it: lowercase id to base64 of the canonical bytes. */
    @Throws(CanonicalJson.Failure::class)
    internal fun encodedEnvelopes(): Map<String, String> = encoded(confirmed)

    @Throws(CanonicalJson.Failure::class)
    internal fun encodedPreRecoveryEnvelopes(): Map<String, String>? = preRecovery?.let(::encoded)

    private fun encoded(values: Map<UUID, Entry>): Map<String, String> {
        val out = LinkedHashMap<String, String>(values.size * 2)
        for ((id, entry) in values) out[Uuids.lowercase(id)] = entry.encoded()
        return out
    }

    // Equality

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SyncBase) return false
        return cursor == other.cursor &&
            cursorKind == other.cursorKind &&
            journalEstablished == other.journalEstablished &&
            accountIdentity == other.accountIdentity &&
            datasetIdentity == other.datasetIdentity &&
            requiresTransportFullResync == other.requiresTransportFullResync &&
            requiresNonDestructiveLibraryMerge == other.requiresNonDestructiveLibraryMerge &&
            nonDestructiveMergeMode == other.nonDestructiveMergeMode &&
            nonDestructiveReviewId == other.nonDestructiveReviewId &&
            recordVersions == other.recordVersions &&
            envelopes == other.envelopes &&
            preRecoveryConfirmedEnvelopes == other.preRecoveryConfirmedEnvelopes
    }

    override fun hashCode(): Int =
        ((confirmed.size * 31 + recordVersions.size) * 31 + (cursor?.hashCode() ?: 0)) * 31 + journalEstablished.hashCode()

    /** Counts only: no id, no identity, no cursor value. */
    override fun toString(): String =
        "SyncBase(envelopes=${confirmed.size}, recordVersions=${recordVersions.size}, cursor=${cursor != null}, " +
            "journalEstablished=$journalEstablished, fence=$nonDestructiveMergeMode)"

    companion object {

        /**
         * Swift's schema 7. Its history, each step a fence an older build must stop at:
         * 2 account binding, 3 cursor kind and the full-resync request, 4 dataset
         * identity and the non-destructive merge fence, 5 the fence's mode, 6 the
         * pre-recovery ancestor, 7 the review id.
         */
        const val CURRENT_SCHEMA_VERSION: Long = 7

        /** The base of a device that has agreed on nothing yet. */
        val EMPTY: SyncBase = SyncBase()

        /** The key a record has in the file: its lowercase id (`SyncBase.key`). */
        fun key(id: UUID): String = Uuids.lowercase(id)

        /**
         * A base from its members (Swift's `init`), put in order the same way:
         * [cursorKind] is dropped without a [cursor] and defaults to
         * [SyncCursorKind.LEGACY] with one; [nonDestructiveMergeMode] is dropped without
         * the fence and defaults to [NonDestructiveMergeMode.INCOMPLETE_PRIMARY] with it;
         * [nonDestructiveReviewId] is dropped unless the fence is reviewed, and a reviewed
         * fence given without one gets a new random id.
         *
         * @throws IllegalArgumentException when an envelope is not keyed by its own id,
         *   or [preRecoveryConfirmedEnvelopes] is given without a reviewed fence (Swift
         *   refuses to encode that base).
         */
        operator fun invoke(
            envelopes: Map<UUID, SyncEnvelope> = emptyMap(),
            recordVersions: Map<UUID, SyncRecordVersion> = emptyMap(),
            cursor: SyncCursor? = null,
            cursorKind: SyncCursorKind? = null,
            journalEstablished: Boolean = false,
            accountIdentity: SyncAccountIdentity? = null,
            datasetIdentity: SyncDatasetIdentity? = null,
            requiresTransportFullResync: Boolean = false,
            requiresNonDestructiveLibraryMerge: Boolean = false,
            nonDestructiveMergeMode: NonDestructiveMergeMode? = null,
            preRecoveryConfirmedEnvelopes: Map<UUID, SyncEnvelope>? = null,
            nonDestructiveReviewId: UUID? = null,
        ): SyncBase = build(
            confirmed = entries(envelopes, emptyMap()),
            recordVersions = frozen(recordVersions),
            cursor = cursor,
            cursorKind = cursorKind,
            journalEstablished = journalEstablished,
            accountIdentity = accountIdentity,
            datasetIdentity = datasetIdentity,
            requiresTransportFullResync = requiresTransportFullResync,
            requiresNonDestructiveLibraryMerge = requiresNonDestructiveLibraryMerge,
            nonDestructiveMergeMode = nonDestructiveMergeMode,
            preRecovery = preRecoveryConfirmedEnvelopes?.let { entries(it, emptyMap()) },
            nonDestructiveReviewId = nonDestructiveReviewId,
        )

        /**
         * The base that replaces a checkpoint after a reviewed account change, checkpoint
         * repair or remote-data restore (`SyncEngine.resetTransportCheckpoint`): nothing
         * agreed, the journal established, bound to exactly the scope the preflight of
         * that round resolved.
         *
         * The engine writes the journal, resets the transport, writes this, and only then
         * clears the reviewed halt.
         */
        fun afterReviewedReset(accountIdentity: SyncAccountIdentity?, datasetIdentity: SyncDatasetIdentity?): SyncBase =
            SyncBase(journalEstablished = true, accountIdentity = accountIdentity, datasetIdentity = datasetIdentity)

        /**
         * The base that Repair writes over an unreadable or distrusted checkpoint
         * (`SyncCoordinator.repairUnreadableProtocolCheckpoint`).
         *
         * If [prior] already carries a reviewed fence, an earlier Repair committed its
         * base and crashed before its journal: that snapshot is kept as it is (only the
         * journal marker is set), because snapshotting [current] again would turn a
         * deletion made since then into an unknown absence under a new review.
         *
         * Otherwise [current] becomes the reviewed snapshot under [reviewId], bound to
         * [prior]'s scope, and the old confirmed ancestor is retained beside it: [prior]'s
         * envelopes, or its own retained ancestor when it was an unreviewed fence, or
         * nothing when there was no readable [prior].
         *
         * The coordinator writes this base first and the journal second.
         */
        fun repairingCheckpoint(prior: SyncBase?, current: Map<UUID, SyncEnvelope>, reviewId: UUID): SyncBase {
            if (prior != null && prior.isReviewedRecovery) return prior.establishingJournal()
            val retained = when {
                prior == null -> null
                prior.requiresNonDestructiveLibraryMerge -> prior.preRecovery
                else -> prior.confirmed
            }
            return build(
                confirmed = entries(current, prior?.confirmed ?: emptyMap()),
                recordVersions = emptyMap(),
                cursor = null,
                cursorKind = null,
                journalEstablished = true,
                accountIdentity = prior?.accountIdentity,
                datasetIdentity = prior?.datasetIdentity,
                requiresTransportFullResync = false,
                requiresNonDestructiveLibraryMerge = true,
                nonDestructiveMergeMode = NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT,
                preRecovery = retained,
                nonDestructiveReviewId = reviewId,
            )
        }

        private fun build(
            confirmed: Map<UUID, Entry>,
            recordVersions: Map<UUID, SyncRecordVersion>,
            cursor: SyncCursor?,
            cursorKind: SyncCursorKind?,
            journalEstablished: Boolean,
            accountIdentity: SyncAccountIdentity?,
            datasetIdentity: SyncDatasetIdentity?,
            requiresTransportFullResync: Boolean,
            requiresNonDestructiveLibraryMerge: Boolean,
            nonDestructiveMergeMode: NonDestructiveMergeMode?,
            preRecovery: Map<UUID, Entry>?,
            nonDestructiveReviewId: UUID?,
        ): SyncBase {
            val mode = if (requiresNonDestructiveLibraryMerge) {
                nonDestructiveMergeMode ?: NonDestructiveMergeMode.INCOMPLETE_PRIMARY
            } else {
                null
            }
            val reviewed = mode == NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT
            require(preRecovery == null || reviewed) { "a pre-recovery ancestor requires a reviewed recovery" }
            return SyncBase(
                confirmed = confirmed,
                recordVersions = recordVersions,
                cursor = cursor,
                cursorKind = if (cursor == null) null else (cursorKind ?: SyncCursorKind.LEGACY),
                journalEstablished = journalEstablished,
                accountIdentity = accountIdentity,
                datasetIdentity = datasetIdentity,
                requiresTransportFullResync = requiresTransportFullResync,
                requiresNonDestructiveLibraryMerge = requiresNonDestructiveLibraryMerge,
                nonDestructiveMergeMode = mode,
                preRecovery = preRecovery,
                nonDestructiveReviewId = if (reviewed) (nonDestructiveReviewId ?: UUID.randomUUID()) else null,
            )
        }

        private fun frozen(recordVersions: Map<UUID, SyncRecordVersion>): Map<UUID, SyncRecordVersion> =
            if (recordVersions.isEmpty()) emptyMap() else Collections.unmodifiableMap(HashMap(recordVersions))

        /** Entries for [envelopes], keeping the entry (and what it has already encoded) of an unchanged envelope. */
        private fun entries(envelopes: Map<UUID, SyncEnvelope>, known: Map<UUID, Entry>): Map<UUID, Entry> {
            if (envelopes.isEmpty()) return emptyMap()
            val out = HashMap<UUID, Entry>(envelopes.size * 2)
            for ((id, envelope) in envelopes) {
                require(envelope.id == id) { "a confirmed envelope is keyed by its own id" }
                val existing = known[id]
                out[id] = if (existing != null && existing.envelope === envelope) existing else Entry(envelope)
            }
            return out
        }

        private fun put(target: HashMap<UUID, Entry>, envelope: SyncEnvelope) {
            val existing = target[envelope.id]
            if (existing == null || existing.envelope !== envelope) target[envelope.id] = Entry(envelope)
        }

        private fun hashOrNull(envelope: SyncEnvelope): String? = try {
            envelope.envelopeHash()
        } catch (_: CanonicalJson.Failure) {
            null
        }
    }

    /**
     * One confirmed envelope with what has already been computed from it. An envelope is
     * immutable, so its canonical bytes and hash are worked out once and travel with it
     * through every copy of the base; a round that writes the base three times encodes
     * each unchanged record once, not three times.
     */
    private class Entry(val envelope: SyncEnvelope) {

        @Volatile
        private var encodedText: String? = null

        // A hash, or FAILED; null until asked.
        @Volatile
        private var hash: Any? = null

        fun encoded(): String {
            encodedText?.let { return it }
            val bytes = envelope.canonicalBytes()
            try {
                return Base64Std.encode(bytes).also { encodedText = it }
            } finally {
                bytes.fill(0)
            }
        }

        fun hashOrNull(): String? {
            val known = hash
            if (known != null) return known as? String
            val computed: Any = try {
                envelope.envelopeHash()
            } catch (_: CanonicalJson.Failure) {
                FAILED
            }
            hash = computed
            return computed as? String
        }

        private companion object {
            val FAILED = Any()
        }
    }

    /** A read-only map of envelopes over the entries, without copying them. */
    private class EnvelopeView(private val source: Map<UUID, Entry>) : AbstractMap<UUID, SyncEnvelope>() {

        override val size: Int get() = source.size

        override fun containsKey(key: UUID): Boolean = source.containsKey(key)

        override fun get(key: UUID): SyncEnvelope? = source[key]?.envelope

        override val entries: Set<Map.Entry<UUID, SyncEnvelope>> =
            object : AbstractSet<Map.Entry<UUID, SyncEnvelope>>() {
                override val size: Int get() = source.size

                override fun iterator(): Iterator<Map.Entry<UUID, SyncEnvelope>> {
                    val iterator = source.entries.iterator()
                    return object : Iterator<Map.Entry<UUID, SyncEnvelope>> {
                        override fun hasNext(): Boolean = iterator.hasNext()
                        override fun next(): Map.Entry<UUID, SyncEnvelope> =
                            iterator.next().let { SimpleImmutableEntry(it.key, it.value.envelope) }
                    }
                }
            }
    }
}
