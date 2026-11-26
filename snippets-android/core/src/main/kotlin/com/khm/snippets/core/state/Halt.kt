package com.khm.snippets.core.state

import com.khm.snippets.core.crypto.Utf8
import java.util.Collections
import java.util.TreeMap
import java.util.UUID

/**
 * A user-visible way out of a sync safety condition (`SyncRecoveryAction`).
 *
 * Recovery is an explicit, validated operation: the engine accepts an action only while
 * it equals the action of the exact durable halt. Titles and explanations are the app's.
 */
enum class SyncRecoveryAction {
    APPLY_REMOTE_DELETIONS,

    /**
     * A mass-deletion halt without a [RecoveryContext] cannot authorize anything. It is
     * cleared for one fetch so the engine can persist the exact batch, and the
     * confirmation is then asked against those facts. This check deletes nothing.
     */
    REFRESH_DELETION_REVIEW,
    USE_CURRENT_ACCOUNT,
    REPAIR_CHECKPOINT,
    RESTORE_CLOUD_FROM_THIS_DEVICE,

    /**
     * Clears only an orphaned [RecoveryClaim]. The halt stays, and its original action
     * must be reviewed and confirmed again.
     */
    RECLAIM_RECOVERY,
    RETRY_SYNC,
    CHECK_AGAIN;

    /** Whether the app must ask before performing it (Swift: the action has a confirmation title). */
    val requiresConfirmation: Boolean
        get() = when (this) {
            APPLY_REMOTE_DELETIONS, USE_CURRENT_ACCOUNT, RESTORE_CLOUD_FROM_THIS_DEVICE, RECLAIM_RECOVERY -> true
            REFRESH_DELETION_REVIEW, REPAIR_CHECKPOINT, RETRY_SYNC, CHECK_AGAIN -> false
        }

    val isDestructiveConfirmation: Boolean get() = this == APPLY_REMOTE_DELETIONS
}

/**
 * Why sync stopped and refuses to resume without the user looking at it
 * (`SyncState.HaltReason`).
 *
 * Every reason is sticky. A persisted mass deletion or integrity failure never heals on
 * its own, because that would mean deleting or trusting the value that just failed
 * validation. Live backend and sign-in failures are not halts; they are the engine's
 * non-persisted needs-attention state.
 *
 * No case may ever be removed: a stored halt whose [rawValue] no longer decodes makes
 * `state.json` undecodable, an undecodable state file is started fresh, and a fresh
 * state has no halt.
 */
enum class HaltReason(val rawValue: String) {

    /** The remote asked to delete more than the deletion guard allows. */
    MASS_DELETION("massDeletion"),

    /**
     * The backend refused a record and will keep refusing it: a quota, a record that is
     * too large. Nothing is wrong with anybody's data, so the engine reports a new
     * refusal as its non-sticky needs-attention state; a persisted halt with this reason
     * is a legacy stop and offers [SyncRecoveryAction.RETRY_SYNC].
     */
    BACKEND_REFUSED("backendRefused"),

    /**
     * The confirmed cursor and record versions belong to another account, or to an
     * unknown one. Continuing would mix private libraries or suppress every local record
     * as already agreed.
     */
    ACCOUNT_CHANGED("accountChanged"),

    /** The transport's private checkpoint is missing, corrupt or incompatible. */
    CHECKPOINT_UNREADABLE("checkpointUnreadable"),

    /** The backend physically reset or replaced the remote data. */
    REMOTE_DATA_RESET("remoteDataReset"),

    /** Nothing raises this. Kept so that the vocabulary matches Swift's and stays closed. */
    MANIFEST_INTEGRITY_FAILED("manifestIntegrityFailed"),

    /**
     * `snippets.json`, or one of the protocol files, could not be read. Pushing now
     * would spread the damage to every other device.
     */
    LOCAL_LIBRARY_QUARANTINED("localLibraryQuarantined"),

    /** `Vault/vault.json` was unreadable or belongs to another vault. Secure records must not be touched. */
    VAULT_UNREADABLE("vaultUnreadable"),

    /** A file was written by a build with another schema. Never write over it. */
    SCHEMA_TOO_NEW("schemaTooNew");

    /** The action that reviews this reason, before claims and missing contexts are considered: see [Halt.recoveryAction]. */
    val recoveryAction: SyncRecoveryAction?
        get() = when (this) {
            MASS_DELETION -> SyncRecoveryAction.APPLY_REMOTE_DELETIONS
            ACCOUNT_CHANGED -> SyncRecoveryAction.USE_CURRENT_ACCOUNT
            CHECKPOINT_UNREADABLE -> SyncRecoveryAction.REPAIR_CHECKPOINT
            REMOTE_DATA_RESET -> SyncRecoveryAction.RESTORE_CLOUD_FROM_THIS_DEVICE
            BACKEND_REFUSED -> SyncRecoveryAction.RETRY_SYNC
            MANIFEST_INTEGRITY_FAILED, LOCAL_LIBRARY_QUARANTINED, VAULT_UNREADABLE -> SyncRecoveryAction.CHECK_AGAIN
            SCHEMA_TOO_NEW -> null
        }

    companion object {
        fun fromRawValue(rawValue: String): HaltReason? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * What exactly stopped sync, as data: a stable [code] and named [arguments] (a schema
 * version, a count, a transport's own closed code). Swift stores an English sentence
 * here; this core stores no sentences, and the app phrases the code.
 *
 * The value is part of the halt's identity, and a halt is a compare-and-swap token, so
 * it must read back exactly as written. [of] therefore bounds and repairs what it is
 * given. Never put a snippet's text, a path or an account identifier in an argument.
 */
class HaltDetail private constructor(val code: String, arguments: Map<String, String>) {

    /** Sorted by key, unmodifiable. */
    val arguments: Map<String, String> = Collections.unmodifiableMap(TreeMap(arguments))

    override fun equals(other: Any?): Boolean = other is HaltDetail && code == other.code && arguments == other.arguments
    override fun hashCode(): Int = code.hashCode() * 31 + arguments.hashCode()
    override fun toString(): String = "HaltDetail($code)"

    companion object {
        const val MAXIMUM_CODE_CHARACTERS = 128
        const val MAXIMUM_ARGUMENTS = 16
        const val MAXIMUM_ARGUMENT_CHARACTERS = 1_024

        /**
         * @param code 1…[MAXIMUM_CODE_CHARACTERS] characters of `a-z A-Z 0-9 _ . : -`.
         * @param arguments at most [MAXIMUM_ARGUMENTS], keys spelled like a code. A value
         *   longer than [MAXIMUM_ARGUMENT_CHARACTERS] is cut there, and an unpaired
         *   surrogate becomes U+FFFD (as when Swift creates a string), so that building a
         *   halt from a backend's words cannot fail.
         * @throws IllegalArgumentException for a malformed code or key, or too many arguments.
         */
        fun of(code: String, arguments: Map<String, String> = emptyMap()): HaltDetail {
            require(isCode(code)) { "a halt detail code is 1…$MAXIMUM_CODE_CHARACTERS characters of [A-Za-z0-9_.:-]" }
            require(arguments.size <= MAXIMUM_ARGUMENTS) { "a halt detail holds at most $MAXIMUM_ARGUMENTS arguments" }
            val bounded = TreeMap<String, String>()
            for ((key, value) in arguments) {
                require(isCode(key)) { "a halt detail argument name is spelled like a code" }
                bounded[key] = bounded(value)
            }
            return HaltDetail(code, bounded)
        }

        /** As [of] for a value read from disk: nothing is repaired, anything out of bounds is `null`. */
        internal fun exact(code: String, arguments: Map<String, String>): HaltDetail? {
            if (!isCode(code) || arguments.size > MAXIMUM_ARGUMENTS) return null
            for ((key, value) in arguments) {
                if (!isCode(key) || bounded(value) != value) return null
            }
            return HaltDetail(code, arguments)
        }

        private fun isCode(text: String): Boolean =
            text.isNotEmpty() && text.length <= MAXIMUM_CODE_CHARACTERS && text.all {
                it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '_' || it == '.' || it == ':' || it == '-'
            }

        private fun bounded(value: String): String {
            var end = minOf(value.length, MAXIMUM_ARGUMENT_CHARACTERS)
            // Never cut a surrogate pair in half.
            if (end < value.length && end > 0 && Character.isHighSurrogate(value[end - 1])) end -= 1
            return wellFormed(value.substring(0, end))
        }
    }
}

internal fun isLowercaseSha256(text: String): Boolean =
    text.length == 64 && text.all { it in '0'..'9' || it in 'a'..'f' }

/** [text] as a Swift `String` would hold it: an unpaired surrogate is U+FFFD. */
internal fun wellFormed(text: String): String =
    if (Utf8.encodeStrict(text) != null) text else String(Utf8.encode(text), Charsets.UTF_8)

/**
 * The facts a confirmation is bound to (`SyncState.Halt.RecoveryContext`). It never
 * holds snippet identifiers or content.
 */
sealed class RecoveryContext {

    /**
     * The exact deletion batch that was shown to the user. A reviewed deletion proceeds
     * only if the live count, the deletion count and the fingerprint of the id set all
     * still match.
     */
    data class MassDeletion(
        val liveCount: Int,
        val requestedDeletions: Int,
        /** Opaque: the 64 lowercase hex digits of a SHA-256 over the sorted ids that would be deleted. */
        val batchFingerprint: String,
    ) : RecoveryContext() {

        init {
            require(isLowercaseSha256(batchFingerprint)) { "a deletion batch fingerprint is 64 lowercase hex digits" }
        }

        override fun toString(): String = "MassDeletion(liveCount=$liveCount, requestedDeletions=$requestedDeletions)"
    }

    /**
     * The unreadable primary library was moved aside only after this became durable. A
     * missing `snippets.json` must then never be read as an empty library.
     */
    object LocalLibraryQuarantine : RecoveryContext() {
        override fun toString(): String = "LocalLibraryQuarantine"
    }
}

/**
 * Atomic ownership of one reviewed mutation attempt (`SyncState.Halt.RecoveryClaim`).
 *
 * The claim is written by compare-and-swap before any transport reset or destructive
 * apply begins. A second engine then reads a different [Halt] and cannot mint the same
 * one-shot authority.
 *
 * Swift identifies the claimant by host name, pid and process start time besides the
 * engine's [ownerId]. Android is one process whose pid is reused across launches, so the
 * claim carries the [launchId] instead: a random id made once per process launch. A
 * claim from another launch belongs to a process that no longer exists.
 */
data class RecoveryClaim(
    /** Names this attempt. A retry is a new claim with a new id. */
    val id: UUID,
    /** The engine instance that owns the attempt. */
    val ownerId: UUID,
    /** The process launch that engine lived in. */
    val launchId: UUID,
)

/** What a [RecoveryClaim] means to the engine that reads it. */
enum class RecoveryClaimDisposition {
    /** This engine wrote it. */
    OWNED_BY_THIS_ENGINE,

    /** Another engine of this launch wrote it and is still registered: it is working, offer nothing. */
    ACTIVE_IN_THIS_LAUNCH,

    /** An engine of this launch wrote it and has since been closed. */
    ABANDONED_IN_THIS_LAUNCH,

    /**
     * An earlier launch wrote it. Its one-shot authority died with that process; the
     * claim is cleared by an explicit [SyncRecoveryAction.RECLAIM_RECOVERY] and the
     * original action is confirmed again.
     */
    ABANDONED_BY_ANOTHER_LAUNCH,
}

/**
 * Who may own a [RecoveryClaim] in this process launch. One instance per launch, made by
 * the app with a fresh random [launchId] and handed to every engine it builds.
 *
 * Swift keeps a static table of weak engine references and lets deallocation decide
 * "abandoned". The JVM frees objects whenever it likes, so an engine [register]s when it
 * is built and must [deregister] when it is closed; a discarded engine that stays
 * registered would block its successor's recovery button.
 *
 * Thread-safe.
 */
class RecoveryClaimOwners(val launchId: UUID) {

    private val live = HashSet<UUID>()

    /** Registers an engine and returns its owner id. */
    fun register(ownerId: UUID = UUID.randomUUID()): UUID {
        synchronized(live) { live.add(ownerId) }
        return ownerId
    }

    /** The engine with this id has stopped for good. Harmless to repeat. */
    fun deregister(ownerId: UUID) {
        synchronized(live) { live.remove(ownerId) }
    }

    fun isLive(ownerId: UUID): Boolean = synchronized(live) { ownerId in live }

    /**
     * A new claim for the engine [ownerId] of this launch, which must be registered: a
     * claim of this launch therefore always names an engine that was live when it was
     * written, and [disposition] can tell "still working" from "closed since".
     *
     * @throws IllegalArgumentException when [ownerId] is not registered.
     */
    fun newClaim(ownerId: UUID, claimId: UUID = UUID.randomUUID()): RecoveryClaim {
        require(isLive(ownerId)) { "only a registered engine may claim a recovery" }
        return RecoveryClaim(claimId, ownerId, launchId)
    }

    /**
     * What [claim] means to the engine [askingOwnerId]. A query only; unlike Swift it
     * forgets nothing, so asking twice gives the same answer. (Swift drops a dead weak
     * entry on the first query, so its second query of the same claim answers "unknown
     * process" and offers a takeover the first did not.)
     */
    fun disposition(claim: RecoveryClaim, askingOwnerId: UUID): RecoveryClaimDisposition = when {
        claim.launchId != launchId -> RecoveryClaimDisposition.ABANDONED_BY_ANOTHER_LAUNCH
        claim.ownerId == askingOwnerId -> RecoveryClaimDisposition.OWNED_BY_THIS_ENGINE
        isLive(claim.ownerId) -> RecoveryClaimDisposition.ACTIVE_IN_THIS_LAUNCH
        else -> RecoveryClaimDisposition.ABANDONED_IN_THIS_LAUNCH
    }
}

/**
 * A persisted safety stop (`SyncState.Halt`).
 *
 * The whole value is a compare-and-swap token: recovery may replace or clear only the
 * exact halt it reviewed, never a newer one (see [SyncStateFile.updateHalt]). It reads
 * back from disk equal to what was written, whatever [at] is.
 *
 * @param at seconds since 2001; must be finite. Swift floors it to whole seconds because
 *   its file keeps ISO-8601 dates; this file keeps the double, so no rounding is needed.
 *   `-0.0` is stored as `0.0`, the value it reads back as.
 */
class Halt(
    val reason: HaltReason,
    val detail: HaltDetail,
    at: Double,
    /** Binds a confirmation to the facts shown to the user. */
    val recoveryContext: RecoveryContext? = null,
    /**
     * Present only while one engine owns the reviewed mutation attempt. A restart fence,
     * not reusable approval: an abandoned claim must be replaced by another explicit
     * action, by compare-and-swap, before work can resume.
     */
    val recoveryClaim: RecoveryClaim? = null,
) {

    init {
        require(at.isFinite()) { "a halt time must be finite" }
    }

    /** Seconds since 2001, finite. */
    val at: Double = if (at == 0.0) 0.0 else at

    fun copy(
        reason: HaltReason = this.reason,
        detail: HaltDetail = this.detail,
        at: Double = this.at,
        recoveryContext: RecoveryContext? = this.recoveryContext,
        recoveryClaim: RecoveryClaim? = this.recoveryClaim,
    ): Halt = Halt(reason, detail, at, recoveryContext, recoveryClaim)

    /** This halt owned by [claim] (`haltByClaimingRecovery`). */
    fun claimedBy(claim: RecoveryClaim): Halt = copy(recoveryClaim = claim)

    /** This halt with no owner: what [SyncRecoveryAction.RECLAIM_RECOVERY] writes. */
    fun withoutClaim(): Halt = copy(recoveryClaim = null)

    /**
     * The one action that may be offered for this halt (`SyncEngine.recoveryAction`).
     *
     * - A claim another live engine holds: nothing; that engine is working.
     * - A claim from another launch: [SyncRecoveryAction.RECLAIM_RECOVERY] only.
     * - A mass deletion without its [RecoveryContext]:
     *   [SyncRecoveryAction.REFRESH_DELETION_REVIEW], which grants no deletion authority.
     * - Otherwise the reason's own action; none for [HaltReason.SCHEMA_TOO_NEW].
     *
     * @param claimDisposition asked only when the halt carries a claim.
     */
    fun recoveryAction(claimDisposition: (RecoveryClaim) -> RecoveryClaimDisposition): SyncRecoveryAction? {
        recoveryClaim?.let { claim ->
            when (claimDisposition(claim)) {
                RecoveryClaimDisposition.OWNED_BY_THIS_ENGINE, RecoveryClaimDisposition.ABANDONED_IN_THIS_LAUNCH -> Unit
                RecoveryClaimDisposition.ACTIVE_IN_THIS_LAUNCH -> return null
                RecoveryClaimDisposition.ABANDONED_BY_ANOTHER_LAUNCH -> return SyncRecoveryAction.RECLAIM_RECOVERY
            }
        }
        if (reason == HaltReason.MASS_DELETION && recoveryContext == null) return SyncRecoveryAction.REFRESH_DELETION_REVIEW
        return reason.recoveryAction
    }

    // `at` compares as Swift's `Date ==` does, so 0.0 equals -0.0, which is also how it reads back from JSON.
    override fun equals(other: Any?): Boolean =
        this === other || (
            other is Halt && reason == other.reason && detail == other.detail && at == other.at &&
                recoveryContext == other.recoveryContext && recoveryClaim == other.recoveryClaim
            )

    override fun hashCode(): Int = (reason.hashCode() * 31 + detail.hashCode()) * 31 + (if (at == 0.0) 0 else at.hashCode())

    override fun toString(): String =
        "Halt(reason=$reason, detail=$detail, context=$recoveryContext, claimed=${recoveryClaim != null})"
}
