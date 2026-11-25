package com.khm.snippets.core.sync.transport

import com.khm.snippets.core.wire.WireRecord
import kotlin.math.abs
import kotlin.math.truncate

/**
 * Why the backend would not take a record (`SyncRejection`).
 *
 * Typed, because each case has a different policy and policy chosen by matching on
 * message text breaks when a backend rewords its error:
 *
 * | Case | The engine, for a record in a `submit` result |
 * |---|---|
 * | [Conflict] | keeps the offer; merges [Conflict.remote] ahead of the fetch feed, or with `null` holds the cursor until a fetch delivers that id |
 * | [RateLimited] | keeps the offer; the round still succeeds |
 * | [AuthenticationRequired] | persists the accepted prefix, then stops and asks the user |
 * | [Permanent] | never retries the record; the round ends needing attention |
 *
 * A value, not a `Throwable`: Swift declares it an `Error` but never throws one. A
 * transport that must refuse a whole call throws [SyncTransportFailure.Rejected].
 */
sealed class SyncRejection {

    /**
     * The backend holds a different generation than the one this submission was built on.
     *
     * When the backend discloses its authoritative record, carrying it here matters: a
     * cursor may already be past that value, so a following delta fetch may be empty.
     * `null` means the transport could prove only that a conflict exists; the engine then
     * keeps the offer until it obtains the authoritative record.
     */
    data class Conflict(val remote: WireRecord?) : SyncRejection()

    /** Slow down. [retryAfter] is the backend's own number of seconds when it gives one. */
    class RateLimited(val retryAfter: Double) : SyncRejection() {
        // Swift compares the two doubles with `==`.
        override fun equals(other: Any?): Boolean =
            other is RateLimited &&
                (retryAfter == other.retryAfter || (retryAfter.isNaN() && other.retryAfter.isNaN()))

        override fun hashCode(): Int = if (retryAfter == 0.0) 0 else retryAfter.hashCode()
        override fun toString(): String = "RateLimited(retryAfter=$retryAfter)"
    }

    /** Credentials are missing, expired or insufficient. */
    data class AuthenticationRequired(val detail: String) : SyncRejection()

    /**
     * Retrying will never work: a record larger than the backend accepts, a malformed id,
     * a quota that is not time-based. [detail] may be a closed transport code that the
     * coordinator switches on (`git_key_required`, …); it is data, never localised.
     */
    data class Permanent(val detail: String) : SyncRejection()

    /**
     * Whether the engine should try this record again on its own.
     *
     * [AuthenticationRequired] is deliberately not retryable although a successful sign-in
     * makes it succeed: the retry has to come from the user, not from a timer.
     */
    val isRetryable: Boolean
        get() = when (this) {
            is Conflict, is RateLimited -> true
            is AuthenticationRequired, is Permanent -> false
        }

    /** Swift's `description`. English and unlocalised; the app phrases what the user sees. */
    val description: String
        get() = when (this) {
            is Conflict ->
                "the backend has a newer version of this snippet" + (remote?.let { " (${it.rev})" } ?: "")
            is RateLimited -> "the backend is rate-limiting; retry in ${roundedSeconds(retryAfter)}s"
            is AuthenticationRequired -> "the backend needs you to sign in again: $detail"
            is Permanent -> "the backend permanently refused this snippet: $detail"
        }

    private companion object {
        /**
         * `Int(seconds.rounded())`: half away from zero. Swift traps on a value that is not
         * finite or does not fit; this saturates, and prints 0 for not-a-number.
         */
        fun roundedSeconds(seconds: Double): Long {
            if (seconds.isNaN()) return 0
            val whole = truncate(seconds)
            val rounded = if (abs(seconds - whole) >= 0.5) whole + (if (seconds < 0) -1.0 else 1.0) else whole
            return rounded.toLong()
        }
    }
}

/**
 * A failure of the call itself, as opposed to a per-record rejection
 * (`SyncTransportFailure`). This is what a [SyncTransport] method throws.
 *
 * | Thrown | The engine |
 * |---|---|
 * | [Unreachable], [Rejected] with a conflict or a rate limit, any other exception | goes offline and backs off (`min(2^n, 300)` seconds) |
 * | [Rejected] with [SyncRejection.AuthenticationRequired] | needs authentication; no backoff, not sticky |
 * | [Rejected] with [SyncRejection.Permanent], [PushUnsupported] | needs attention; no backoff, not sticky |
 * | [AccountChanged], [CheckpointUnreadable], [RemoteDataReset] | enters the persisted halt of the same name, which only an explicit reviewed recovery leaves |
 *
 * `CancellationException` is not a failure and is never wrapped in one.
 *
 * Instances compare by case and payload, as the Swift enum does.
 */
sealed class SyncTransportFailure(message: String) : Exception(message) {

    /** No usable network, or the backend did not answer. */
    class Unreachable(val detail: String) : SyncTransportFailure("the sync backend could not be reached: $detail")

    /** The whole call was refused. Same taxonomy as a per-record rejection. */
    class Rejected(val rejection: SyncRejection) : SyncTransportFailure(rejection.description)

    /** The backend does not accept pushes and one was attempted anyway. A programming error, surfaced. */
    class PushUnsupported : SyncTransportFailure("this sync backend does not accept pushes")

    /**
     * The backend account changed after the round established its scope. Any response may
     * belong to a different private database and must be ignored wholesale.
     */
    class AccountChanged : SyncTransportFailure("the sync backend account changed during the operation")

    /**
     * The transport-private scheduler checkpoint cannot be authenticated or decoded. The
     * one safe recovery: after explicit review, durably capture local intent and replace
     * only that checkpoint ([SyncTransport.resetAfterCheckpointReview]).
     */
    class CheckpointUnreadable(val detail: String) :
        SyncTransportFailure("the sync scheduler checkpoint could not be read: $detail")

    /**
     * The backend reported physical loss or replacement of the remote dataset (Git: a
     * removed record file, a replaced manifest). Uploading the local cache on its own
     * would overwrite that decision, so recovery requires the explicit restore action
     * ([SyncTransport.resetAfterRemoteDataResetReview]).
     */
    class RemoteDataReset(val detail: String) : SyncTransportFailure("the remote sync data was reset: $detail")

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SyncTransportFailure || javaClass != other.javaClass) return false
        return when (this) {
            is Unreachable -> detail == (other as Unreachable).detail
            is Rejected -> rejection == (other as Rejected).rejection
            is CheckpointUnreadable -> detail == (other as CheckpointUnreadable).detail
            is RemoteDataReset -> detail == (other as RemoteDataReset).detail
            is PushUnsupported, is AccountChanged -> true
        }
    }

    override fun hashCode(): Int = when (this) {
        is Unreachable -> detail.hashCode()
        is Rejected -> rejection.hashCode()
        is CheckpointUnreadable -> detail.hashCode()
        is RemoteDataReset -> detail.hashCode()
        is PushUnsupported, is AccountChanged -> 0
    } * 31 + javaClass.hashCode()
}
