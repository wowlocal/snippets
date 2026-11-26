package com.khm.snippets.core.state

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.FoundationJsonWriter
import java.util.UUID

/**
 * This device's relationship to the library, apart from the library itself: who it is,
 * which bytes it last wrote, whether sync has halted, and whether a move between
 * `snippets.json` and the vault was in flight (`SyncState` in `SyncStateFile.swift`,
 * stored in `Sync/state.json`).
 *
 * None of it is user data. Losing the file costs a new device identity and one full
 * reconcile. A quarantined primary library is fenced separately by
 * [LibraryQuarantineMarker], so losing this file cannot turn preserved data into a fresh
 * empty library. Nothing here may ever be used as crypto scope, for the same reason.
 *
 * The schema is this app's own. It keeps Swift's key names and its number,
 * [CURRENT_SCHEMA_VERSION]; Swift's `hlc`, `scopeID`, `backend`, `cursor` and
 * `lastSyncAt` have no reader or writer in production (they are set once by
 * `SyncState.fresh` and never read) and are not part of it. A halt's `detail` is typed
 * data ([HaltDetail]) instead of Swift's English sentence, its `at` is the double itself
 * instead of an ISO-8601 date, and a recovery claim names a launch instead of a host,
 * pid and process start time.
 *
 * Immutable. Every writer replaces the whole document, so every writer must hold the
 * library guard: see [SyncStateFile].
 */
data class SyncState(
    /** Eight lowercase hex digits, minted once per install ([Hlc.makeDeviceId]). */
    val deviceId: String,
    /**
     * Raised by every write of `snippets.json` through the library writer; a step of two
     * marks a write that found bytes it had not recorded (see
     * `core.library.LibraryGeneration`). Never negative: it wraps from [Long.MAX_VALUE]
     * to `0`, where Swift's `UInt64` wraps at 2^64.
     */
    val generation: Long = 0,
    /** The digest of the `snippets.json` bytes that produced [generation]: 64 lowercase hex digits. */
    val librarySha256: String? = null,
    /** The sticky safety stop, if any. */
    val halt: Halt? = null,
    /**
     * Set while a snippet is being moved into the vault, so a crash mid-move is
     * repairable at the next launch.
     */
    val promoting: UUID? = null,
    /** Set while a snippet is being moved out of the vault. */
    val demoting: UUID? = null,
) {

    init {
        require(Hlc.isCanonicalDeviceId(deviceId)) { "a device id is eight lowercase hex digits" }
        require(generation >= 0) { "a library generation is never negative" }
        require(librarySha256 == null || isLowercaseSha256(librarySha256)) { "a library digest is 64 lowercase hex digits" }
    }

    /** Names nothing a log should not hold: the device id is a stable identifier. */
    override fun toString(): String =
        "SyncState(generation=$generation, halt=${halt?.reason}, moving=${promoting != null || demoting != null})"

    companion object {

        /**
         * Swift's schema 4 added the quarantine marker and 5 the recovery claim. A build
         * that does not know the claim could run the same destructive review twice, which
         * is why this number is a fence and not a label.
         */
        const val CURRENT_SCHEMA_VERSION: Long = 5

        /**
         * A new identity with nothing recorded (`SyncState.fresh`). [deviceId] is
         * normalized with [Hlc.normalizedDevice].
         */
        fun fresh(deviceId: String = Hlc.makeDeviceId()): SyncState = SyncState(Hlc.normalizedDevice(deviceId))
    }
}

/**
 * The bytes of `Sync/state.json`.
 *
 * | key | type | |
 * |---|---|---|
 * | `schemaVersion` | integer | always [SyncState.CURRENT_SCHEMA_VERSION] |
 * | `deviceID` | string | eight lowercase hex digits |
 * | `generation` | integer | not negative |
 * | `librarySHA256` | string | optional; 64 lowercase hex digits |
 * | `halt` | object | optional: `reason`, `detail` (`code`, `arguments`), `at` (seconds since 2001), optional `recoveryContext`, optional `recoveryClaim` (`id`, `ownerID`, `launchID`) |
 * | `promoting`, `demoting` | string | optional; lowercase UUID |
 *
 * `recoveryContext` is `{"massDeletion":{"liveCount":…,"requestedDeletions":…,"batchFingerprint":…}}`
 * or `{"localLibraryQuarantine":{}}`, as Swift's synthesized coding writes it.
 *
 * The decoder is closed and stricter than Swift's synthesized one: an unknown key, an
 * explicit `null`, a wrong type or a value outside the format fails the document. Nothing
 * this app writes contains any of them, and each is how a damaged or foreign rewrite
 * would otherwise slip a changed halt past its reader.
 *
 * Output is deterministic: keys sorted, pretty-printed as Foundation's encoder would.
 */
object SyncStateCodec {

    /** What [read] made of the bytes. */
    sealed class ReadResult {
        data class Decoded(val state: SyncState) : ReadResult()

        /** The file says it has another schema. It must not be decoded, and never written over. */
        data class Unsupported(val version: Long) : ReadResult()

        data class Undecodable(val failure: StrictDecodeFailure) : ReadResult()
    }

    fun encode(state: SyncState): ByteArray = FoundationJsonWriter.prettyPrinted(document(state))

    /**
     * The version probe first, then the strict decode. The order is the point: a file
     * from another schema must land in [ReadResult.Unsupported] even when the rest of
     * it means nothing to this build.
     */
    fun read(data: ByteArray): ReadResult {
        val version = SchemaVersionProbe.probe(data)
        if (version != null && version != SyncState.CURRENT_SCHEMA_VERSION) return ReadResult.Unsupported(version)
        return try {
            ReadResult.Decoded(decode(data))
        } catch (failure: StrictDecodeFailure) {
            ReadResult.Undecodable(failure)
        }
    }

    /** A document of the current schema, or the reason it is not one. */
    @Throws(StrictDecodeFailure::class)
    fun decode(data: ByteArray): SyncState {
        val root = StrictObject(StrictObject.parseDocument(data), "", ROOT_KEYS)
        if (root.long("schemaVersion") != SyncState.CURRENT_SCHEMA_VERSION) {
            StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, "schemaVersion")
        }
        val deviceId = root.string("deviceID")
        if (!Hlc.isCanonicalDeviceId(deviceId)) StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, "deviceID")
        val generation = root.long("generation")
        if (generation < 0) StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, "generation")
        val digest = root.optionalString("librarySHA256")
        if (digest != null && !isLowercaseSha256(digest)) {
            StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, "librarySHA256")
        }
        return SyncState(
            deviceId = deviceId,
            generation = generation,
            librarySha256 = digest,
            halt = root.optional("halt")?.let(::halt),
            promoting = root.optionalLowercaseUuid("promoting"),
            demoting = root.optionalLowercaseUuid("demoting"),
        )
    }

    private val ROOT_KEYS = setOf("schemaVersion", "deviceID", "generation", "librarySHA256", "halt", "promoting", "demoting")
    private val HALT_KEYS = setOf("reason", "detail", "at", "recoveryContext", "recoveryClaim")
    private val DETAIL_KEYS = setOf("code", "arguments")
    private val CONTEXT_KEYS = setOf("massDeletion", "localLibraryQuarantine")
    private val MASS_DELETION_KEYS = setOf("liveCount", "requestedDeletions", "batchFingerprint")
    private val CLAIM_KEYS = setOf("id", "ownerID", "launchID")

    // Encoding

    private fun document(state: SyncState): JsonValue {
        val members = LinkedHashMap<String, JsonValue>()
        members["schemaVersion"] = JsonValue.of(SyncState.CURRENT_SCHEMA_VERSION)
        members["deviceID"] = JsonValue.of(state.deviceId)
        members["generation"] = JsonValue.of(state.generation)
        state.librarySha256?.let { members["librarySHA256"] = JsonValue.of(it) }
        state.halt?.let { members["halt"] = value(it) }
        state.promoting?.let { members["promoting"] = JsonValue.of(Uuids.lowercase(it)) }
        state.demoting?.let { members["demoting"] = JsonValue.of(Uuids.lowercase(it)) }
        return JsonValue.Object(members)
    }

    private fun value(halt: Halt): JsonValue {
        val members = LinkedHashMap<String, JsonValue>()
        members["reason"] = JsonValue.of(halt.reason.rawValue)
        members["detail"] = JsonValue.obj(
            "code" to JsonValue.of(halt.detail.code),
            "arguments" to JsonValue.Object(halt.detail.arguments.mapValues { JsonValue.of(it.value) }),
        )
        members["at"] = JsonValue.of(halt.at)
        when (val context = halt.recoveryContext) {
            null -> Unit
            is RecoveryContext.MassDeletion -> members["recoveryContext"] = JsonValue.obj(
                "massDeletion" to JsonValue.obj(
                    "liveCount" to JsonValue.of(context.liveCount),
                    "requestedDeletions" to JsonValue.of(context.requestedDeletions),
                    "batchFingerprint" to JsonValue.of(context.batchFingerprint),
                ),
            )
            RecoveryContext.LocalLibraryQuarantine -> members["recoveryContext"] = JsonValue.obj(
                "localLibraryQuarantine" to JsonValue.Object(emptyMap()),
            )
        }
        halt.recoveryClaim?.let { claim ->
            members["recoveryClaim"] = JsonValue.obj(
                "id" to JsonValue.of(Uuids.lowercase(claim.id)),
                "ownerID" to JsonValue.of(Uuids.lowercase(claim.ownerId)),
                "launchID" to JsonValue.of(Uuids.lowercase(claim.launchId)),
            )
        }
        return JsonValue.Object(members)
    }

    // Decoding

    private fun halt(value: JsonValue): Halt {
        val fields = StrictObject(value, "halt", HALT_KEYS)
        val reason = HaltReason.fromRawValue(fields.string("reason"))
            ?: StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, "halt.reason")
        return Halt(
            reason = reason,
            detail = detail(fields.required("detail")),
            at = fields.finiteDouble("at"),
            recoveryContext = fields.optional("recoveryContext")?.let(::context),
            recoveryClaim = fields.optional("recoveryClaim")?.let(::claim),
        )
    }

    private fun detail(value: JsonValue): HaltDetail {
        val fields = StrictObject(value, "halt.detail", DETAIL_KEYS)
        val arguments = fields.required("arguments").objectOrNull
            ?: StrictObject.fail(StrictDecodeFailure.Kind.WRONG_TYPE, "halt.detail.arguments")
        val decoded = LinkedHashMap<String, String>()
        for ((key, argument) in arguments) {
            if (argument.isNull) StrictObject.fail(StrictDecodeFailure.Kind.EXPLICIT_NULL, "halt.detail.arguments")
            decoded[key] = StrictObject.text(argument, "halt.detail.arguments")
        }
        return HaltDetail.exact(fields.string("code"), decoded)
            ?: StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, "halt.detail")
    }

    private fun context(value: JsonValue): RecoveryContext {
        val cases = StrictObject(value, "halt.recoveryContext", CONTEXT_KEYS)
        // Exactly one case, as Swift's synthesized enum coding requires.
        if (cases.size != 1) StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, "halt.recoveryContext")
        if (cases.contains("localLibraryQuarantine")) {
            StrictObject(cases.required("localLibraryQuarantine"), "halt.recoveryContext.localLibraryQuarantine", emptySet())
            return RecoveryContext.LocalLibraryQuarantine
        }
        val path = "halt.recoveryContext.massDeletion"
        val fields = StrictObject(cases.required("massDeletion"), path, MASS_DELETION_KEYS)
        val fingerprint = fields.string("batchFingerprint")
        if (!isLowercaseSha256(fingerprint)) StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, "$path.batchFingerprint")
        return RecoveryContext.MassDeletion(fields.int("liveCount"), fields.int("requestedDeletions"), fingerprint)
    }

    private fun claim(value: JsonValue): RecoveryClaim {
        val fields = StrictObject(value, "halt.recoveryClaim", CLAIM_KEYS)
        return RecoveryClaim(fields.lowercaseUuid("id"), fields.lowercaseUuid("ownerID"), fields.lowercaseUuid("launchID"))
    }
}
