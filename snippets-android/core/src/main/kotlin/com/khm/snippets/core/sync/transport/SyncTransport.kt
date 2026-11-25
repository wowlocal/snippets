package com.khm.snippets.core.sync.transport

import com.khm.snippets.core.wire.WireRecord
import kotlinx.coroutines.flow.Flow

/**
 * Everything the engine needs from a backend, and nothing else (`SyncTransport` in
 * `snippets/Core/SyncTransport.swift`).
 *
 * Git, Snippets Cloud and the in-memory fake are interchangeable behind it, and the engine
 * is developed and proven against the fake. A transport deals in [WireRecord]s, so it
 * cannot see a name, a keyword, a tag or a body.
 *
 * ## Rules for every implementation
 *
 * - **Threads.** Any method may be called from any thread, and the engine calls from its
 *   one confined dispatcher. An implementation is thread-safe and main-safe: it moves
 *   blocking work to another dispatcher itself and never holds a blocking lock across a
 *   suspension.
 * - **Order.** The engine runs one round at a time and makes its calls one after another:
 *   [preflightScope] first, before it reads the library; then [submit] for what is
 *   pending; then [fetchChanges], repeated while a page says `hasMore`; then
 *   [acknowledgeFetched] once the new cursor is durable. The reset methods are called
 *   from an explicit recovery; [resetForLocalFullResync] is also called inside a round,
 *   after the preflight and before the first data-plane call. [shutdown] comes last. A
 *   transport must not rely on that order for safety: every call checks its own
 *   preconditions.
 * - **Failures.** A method reports a failed call by throwing a [SyncTransportFailure]; the
 *   table on that type says what the engine does with each case. Any other exception is
 *   treated like [SyncTransportFailure.Unreachable] (offline, back off). A partly accepted
 *   batch is not a failure; see [submit].
 * - **Cancellation.** Every method is cancellable and lets `CancellationException` out
 *   unchanged, never wrapped in a [SyncTransportFailure]: a cancelled round is not a
 *   failed round and must not cause a backoff. After a cancelled call nothing about its
 *   remote effect is known (a cancelled [submit] may or may not have stored records), and
 *   the transport's own state must still be consistent.
 * - **Repetition.** Every call may be repeated after a crash or an ambiguous failure. The
 *   per-method notes say what makes each repeat safe.
 */
interface SyncTransport {

    /**
     * Stable and human-readable (`"git"`, `"snippets-cloud"`, `"memory"`). It is persisted
     * in sync state and used in log lines; changing one strands every device that stored it.
     */
    val identifier: String

    /**
     * Whether the backend accepts [submit]. With `false`, a round that has anything
     * pending ends with [SyncTransportFailure.PushUnsupported].
     */
    val supportsPush: Boolean

    /**
     * Seconds between fetches when nothing else prompts one. Read by the coordinator. A
     * backend that can notify still sets a sane value, so a missed notification degrades
     * to slow and never to never.
     */
    val pollInterval: Double

    /**
     * How automatic rounds are paced on a backend where every round that carries a change
     * is expensive. `null`, the default, keeps the coordinator's ordinary short debounce
     * and lets every automatic trigger run. Read by the coordinator only.
     */
    val roundPacing: SyncRoundPacing? get() = null

    /**
     * Out-of-band hints, one long-lived stream per transport.
     *
     * Hot and single-consumer, like the `AsyncStream` it replaces: events are buffered
     * without limit until someone collects, each event reaches exactly one collector, and
     * a second collector takes events from the first. Collection ends when the transport
     * closes the stream; cancelling a collector does not close it. An event is a hint: the
     * consumer reacts by scheduling a round, never by trusting the event's content.
     */
    val events: Flow<SyncTransportEvent>

    /**
     * Resolves and establishes the account or database scope for the next round.
     *
     * `null` is for transports whose data is not account scoped. An account-aware
     * transport returns a stable opaque identity and scopes every later data-plane
     * response to it. Safe to repeat; the answer changes only when the scope does.
     *
     * @throws SyncTransportFailure when the account cannot be resolved (signed out,
     *   unreachable). That is never reported as a different or a missing identity.
     */
    suspend fun resolveAccountIdentity(): SyncAccountIdentity? = null

    /**
     * Resolves the scope and inspects the transport-private checkpoint binding, before
     * Core reads or projects local user data and before any data-plane call of the round.
     *
     * The default wraps [resolveAccountIdentity]; a transport that keeps a private
     * checkpoint or knows a dataset generation overrides it. A checkpoint problem is
     * returned in [SyncScopePreflight.checkpointIssue] beside the identity, not thrown, so
     * a reviewed reset stays bound to the scope that was current. Makes no change to
     * remote or local state and is safe to repeat.
     *
     * @throws SyncTransportFailure as [resolveAccountIdentity].
     */
    suspend fun preflightScope(): SyncScopePreflight = SyncScopePreflight(identity = resolveAccountIdentity())

    /**
     * Changes after [since]; everything the backend has when [since] is `null`.
     *
     * - Records come in backend order and the engine applies them in that order. A page
     *   may repeat a record or an id (at-least-once delivery).
     * - The call does not change remote state and may be repeated with the same cursor:
     *   the engine persists a returned cursor only after the page is applied, so after a
     *   crash it asks again from the older one and must be given at least the same changes.
     * - A deletion arrives as a record with `deleted == true`. A record is never removed
     *   from the feed to express a deletion.
     * - A cursor the backend cannot honour is never answered with an empty page, which
     *   would read as "nothing changed". The transport restarts the stream from the
     *   beginning: sending too much costs bandwidth, sending too little looks like
     *   deletions. When it knows the cursor was valid once and is not any more (expired,
     *   ahead of the backend), it says so with [SyncFetch.isFullResync], plus
     *   [SyncFetch.replacesPriorPages] when earlier pages of this same fetch are thereby
     *   obsolete.
     * - `hasMore` pages must end: the engine loops without a page limit.
     * - [SyncFetch.accountIdentity] and [SyncFetch.datasetIdentity] equal what
     *   [preflightScope] returned for this round.
     *
     * @throws SyncTransportFailure [SyncTransportFailure.Unreachable] when the backend did
     *   not answer; [SyncTransportFailure.Rejected] when it refused the call;
     *   [SyncTransportFailure.AccountChanged], [SyncTransportFailure.CheckpointUnreadable]
     *   or [SyncTransportFailure.RemoteDataReset] when the scope, the private checkpoint or
     *   the remote dataset is no longer the one the round started with.
     */
    suspend fun fetchChanges(since: SyncCursor?): SyncFetch

    /**
     * Pushes [records].
     *
     * - **Compare-and-swap per record.** Every update carries the
     *   [WireRecord.recordVersion] returned by the prior fetch or save of that record; a
     *   create carries `null`. The backend stores a record only if the generation it holds
     *   is exactly that one, and otherwise answers [SyncRejection.Conflict] without
     *   overwriting, with the record it holds when it can disclose it. A create for an id
     *   that exists is a conflict; so is an update for an id that does not.
     * - **Deletions are saves.** A tombstone is stored like any record and stays in the
     *   feed; the backend never physically deletes on a submit.
     * - **Result.** [SyncSubmission.results] has one entry per submitted record, in the
     *   submitted order. The engine matches by id. A batch that was partly stored returns
     *   normally with mixed outcomes; that is the common case under a rate limit, not an
     *   error. An accepted outcome carries the new generation, which the engine uses for
     *   the next update of that record.
     * - **Repetition.** After a failure, a cancellation or a crash the engine does not
     *   know which records were stored and submits again from its journal. The per-record
     *   check is what makes that safe: a replay of a write that did land carries a stale
     *   generation and comes back as a conflict to merge, never as a second write.
     * - [at] is what the engine had last read when it built the batch. A backend may use
     *   it as an additional feed-level precondition; it is never a substitute for the
     *   per-record generation.
     * - [SyncSubmission.accountIdentity] and [SyncSubmission.datasetIdentity] equal what
     *   [preflightScope] returned for this round.
     *
     * @throws SyncTransportFailure when the whole call failed and nothing can be said per
     *   record: [SyncTransportFailure.PushUnsupported] when [supportsPush] is `false`,
     *   otherwise as [fetchChanges].
     */
    suspend fun submit(records: List<WireRecord>, at: SyncCursor?): SyncSubmission

    /**
     * Discards transport-private state of the old account, once, after Core has durably
     * journaled all local intent from it and the user reviewed the account change.
     *
     * The expected values are the ones [preflightScope] returned when the change was
     * reviewed. An account-scoped transport proves they are still current at the reset
     * boundary and throws otherwise. The default is for accountless, stateless transports:
     * it does nothing when both are `null` and fails closed when either is not. Safe to
     * repeat after a crash between Core's write and this call.
     *
     * @throws SyncTransportFailure [SyncTransportFailure.AccountChanged] when
     *   [expectedIdentity] is not the current scope;
     *   [SyncTransportFailure.RemoteDataReset] when [expectedDatasetIdentity] is not the
     *   current dataset.
     */
    suspend fun resetAfterAccountReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?,
    ) {
        if (expectedIdentity != null) throw SyncTransportFailure.AccountChanged()
        if (expectedDatasetIdentity != null) throw SyncTransportFailure.RemoteDataReset("unexpected dataset scope")
    }

    /**
     * Replaces an unreadable transport-private checkpoint, once. Core calls it only after
     * a human review and after the latest local intent is durable. Same expected-scope
     * rule, default and repeat rule as [resetAfterAccountReview].
     *
     * @throws SyncTransportFailure as [resetAfterAccountReview].
     */
    suspend fun resetAfterCheckpointReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?,
    ) {
        if (expectedIdentity != null) throw SyncTransportFailure.AccountChanged()
        if (expectedDatasetIdentity != null) throw SyncTransportFailure.RemoteDataReset("unexpected dataset scope")
    }

    /**
     * Establishes authority to repopulate a remote dataset that was physically reset.
     * Core calls it only after the user chose this device as the recovery source and every
     * current local value is durable in the journal.
     *
     * The default always throws: a silent no-op would let Core clear its cursor and upload
     * local state although the transport never established that authority. A transport
     * that can prove the reset is safe overrides it, checks both expected values as
     * [resetAfterAccountReview] does, and stays safe to repeat.
     *
     * @throws SyncTransportFailure [SyncTransportFailure.RemoteDataReset] by default.
     */
    suspend fun resetAfterRemoteDataResetReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?,
    ) {
        throw SyncTransportFailure.RemoteDataReset("the selected transport cannot restore a reset remote library")
    }

    /**
     * Resets transport-private scheduler progress after a local crypto or projection
     * migration that already staged every surviving record in the durable journal. Same
     * expected-scope rule and default as [resetAfterAccountReview]. Core records its intent
     * before calling and calls again after a failure, so the reset is safe to repeat.
     *
     * @throws SyncTransportFailure as [resetAfterAccountReview], or
     *   [SyncTransportFailure.Unreachable] when the reset itself could not be completed.
     */
    suspend fun resetForLocalFullResync(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?,
    ) {
        if (expectedIdentity != null) throw SyncTransportFailure.AccountChanged()
        if (expectedDatasetIdentity != null) throw SyncTransportFailure.RemoteDataReset("unexpected dataset scope")
    }

    /**
     * Confirms that the fetch position [through] is now durable in Core's base, so a
     * transport that keeps its own inbox may drop what lies before it. Called after the
     * write, never before. May be called again with the same cursor, and with `null`; a
     * stateless transport needs no work, which is the default.
     *
     * @throws SyncTransportFailure when the transport's own state could not be updated.
     *   The cursor is already durable in Core, and the next round acknowledges again.
     */
    suspend fun acknowledgeFetched(through: SyncCursor?) {}

    /**
     * Stops backend-owned work and returns only when the transport can no longer mutate
     * local protocol state or keep a connection or scheduler alive for this scope.
     *
     * The coordinator awaits this barrier before it builds a replacement transport.
     * Idempotent, and it does not throw. A caller that needs the barrier to hold calls it
     * where it cannot be cancelled halfway. Inert and request-scoped transports keep the
     * default, which does nothing; calls made after shutdown are a programming error.
     */
    suspend fun shutdown() {}
}
